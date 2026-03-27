"""
CPA XGBoost Inference Pipeline
Loads trained model, scores new accounts, applies budget factor, writes output
"""

import pandas as pd
import numpy as np
import json
import joblib
import logging
from datetime import datetime, timedelta
from io import BytesIO

from snowflake.snowpark.context import get_active_session
from snowflake.snowpark import functions as F

log = logging.getLogger("cpa_infer")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# ── config ──
REPORTING_DATE = "2026-03-02"
MODEL_STAGE = "@DB_RISK.RISK_SBX.CPA_MODEL_STAGE"
MODEL_NAME = "cpa_xgb_model"
OUTPUT_TABLE = "DB_RISK.RISK_SBX.CPA_FORECASTED_TABLE"
FACTOR_WARN_THRESHOLD = 0.20  # flag if budget factor off by more than 20%


def load_model(session):
    model_stream = session.file.get_stream(f"{MODEL_STAGE}/{MODEL_NAME}.joblib")
    model = joblib.load(BytesIO(model_stream.read()))

    meta_stream = session.file.get_stream(f"{MODEL_STAGE}/{MODEL_NAME}_metadata.json")
    metadata = json.loads(meta_stream.read().decode())

    log.info(f"loaded model | trained: {metadata.get('trained_at','?')} | CV MAE: {metadata.get('best_cv_mae','?')}")
    return model, metadata


def get_recent_source_avgs(session, n_months=3):
    """pull last few months of actuals to compute lag/rolling features for inference"""
    q = f"""
        SELECT CPA_SOURCE, CPA_AMOUNT, to_date(ACCOUNT_OPEN_MONTH, 'DDMONYYYY') as RPT_DATE
        FROM CSTONE_BIZ.RISK.PTI_FACT_CPA
        WHERE comment = 'actuals'
          AND to_date(ACCOUNT_OPEN_MONTH, 'DDMONYYYY') >= DATEADD('month', -{n_months + 3}, CURRENT_DATE())
        ORDER BY CPA_SOURCE, RPT_DATE
    """
    df = session.sql(q).to_pandas()
    df["RPT_DATE"] = pd.to_datetime(df["RPT_DATE"])

    monthly = (
        df.groupby(["CPA_SOURCE", pd.Grouper(key="RPT_DATE", freq="M")])["CPA_AMOUNT"]
        .mean().reset_index()
        .sort_values(["CPA_SOURCE", "RPT_DATE"])
    )

    for lag in [1, 2, 3]:
        monthly[f"CPA_LAG_{lag}"] = monthly.groupby("CPA_SOURCE")["CPA_AMOUNT"].shift(lag)

    monthly["CPA_ROLLING_3M_MEAN"] = (
        monthly.groupby("CPA_SOURCE")["CPA_AMOUNT"]
        .transform(lambda x: x.rolling(3, min_periods=1).mean())
    )
    monthly["CPA_ROLLING_3M_STD"] = (
        monthly.groupby("CPA_SOURCE")["CPA_AMOUNT"]
        .transform(lambda x: x.rolling(3, min_periods=1).std().fillna(0))
    )

    # keep most recent row per source
    return monthly.groupby("CPA_SOURCE").last().reset_index()


def build_inference_features(session, metadata):
    log.info("building inference features...")

    acct_df = session.table("DB_RISK.RISK_SBX.SOURCE_TABLE").to_pandas()
    acct_df.columns = [c.upper() for c in acct_df.columns]

    # align col names to what the model expects
    renames = {
        "ORIGINAL_CARD_NETWORK": "ORGINAL_CARD_NETWORK",
        "ORIGINAL_ANNUAL_FEE_CONFIG": "ORGINAL_ANNUAL_FEE_CONFIG",
        "SOURCE": "CPA_SOURCE",
        "ORIGINAL_BOARD_CHANNEL": "BOARD_CHANNEL",
    }
    acct_df.rename(columns={k: v for k, v in renames.items() if k in acct_df.columns}, inplace=True)

    # derive subchannel from board channel
    if "BOARD_CHANNEL" in acct_df.columns:
        acct_df["SUBCHANNEL_CODE"] = acct_df["BOARD_CHANNEL"].map({"DM": "PA", "WEB": "PQ"}).fillna("SECA")

    # temporal features for current period
    rpt = pd.to_datetime(REPORTING_DATE)
    acct_df["REPORTING_DATE"] = rpt
    acct_df["MONTH"] = rpt.month
    acct_df["QUARTER"] = rpt.quarter
    acct_df["YEAR"] = rpt.year
    acct_df["MONTHS_SINCE_START"] = (rpt.year - 2024) * 12 + rpt.month  # approx baseline

    # pull recent history for lags/rolling
    recent = get_recent_source_avgs(session, n_months=3)
    lag_roll_cols = ["CPA_LAG_1", "CPA_LAG_2", "CPA_LAG_3", "CPA_ROLLING_3M_MEAN", "CPA_ROLLING_3M_STD"]

    for col in lag_roll_cols:
        if col in recent.columns:
            acct_df = acct_df.merge(
                recent[["CPA_SOURCE", col]].drop_duplicates(),
                on="CPA_SOURCE", how="left",
            )
        else:
            acct_df[col] = 0.0

    # credit line bins
    if "ORIGINAL_CREDIT_LINE" in acct_df.columns:
        acct_df["CREDIT_LINE_BIN"] = pd.cut(
            acct_df["ORIGINAL_CREDIT_LINE"].fillna(0),
            bins=[0, 300, 500, 750, 1000, 2000, 5000, np.inf],
            labels=[0, 1, 2, 3, 4, 5, 6],
        ).astype(float)
    else:
        acct_df["CREDIT_LINE_BIN"] = 0.0

    # categoricals
    for c in metadata.get("categorical_cols", []):
        if c in acct_df.columns:
            acct_df[c] = acct_df[c].astype("category")

    # fill remaining nans
    for c in lag_roll_cols + ["CREDIT_LINE_BIN", "MONTHS_SINCE_START"]:
        if c in acct_df.columns:
            acct_df[c] = acct_df[c].fillna(0)

    log.info(f"inference rows: {len(acct_df):,}")
    return acct_df


def predict(model, acct_df, feature_cols):
    # handle any features that might be missing
    for c in feature_cols:
        if c not in acct_df.columns:
            log.warning(f"missing feature {c}, filling with 0")
            acct_df[c] = 0

    X = acct_df[feature_cols]
    preds = np.clip(model.predict(X), 0, None)
    acct_df["PRELIM_FORECAST_CPA"] = preds

    # track whether we had lag history for this source
    has_history = acct_df["CPA_LAG_1"].notna() & (acct_df["CPA_LAG_1"] > 0)
    acct_df["PREDICTION_QUALITY"] = np.where(has_history, "WITH_HISTORY", "NO_HISTORY")

    qual = acct_df["PREDICTION_QUALITY"].value_counts()
    for q, n in qual.items():
        log.info(f"  {q}: {n:,} ({n/len(acct_df):.1%})")

    log.info(f"predicted CPA range: [{preds.min():,.2f}, {preds.max():,.2f}] | mean: {preds.mean():,.2f}")
    return acct_df


def apply_budget_factor(session, acct_df):
    log.info("applying budget factor...")

    rpt = datetime.strptime(REPORTING_DATE, "%Y-%m-%d")
    last_day_prev = rpt.replace(day=1) - timedelta(days=1)

    asmp = session.table("CSTONE_BIZ.RISK.PTI_ASSUMPTIONS").to_pandas()
    asmp["SRC_REPORTING_DATE"] = pd.to_datetime(asmp["SRC_REPORTING_DATE"])

    match = asmp[asmp["SRC_REPORTING_DATE"] == pd.to_datetime(last_day_prev)]

    if match.empty:
        log.warning("no assumption row found — factor = 1.0")
        acct_df["MARKETING_FACTOR"] = 1.0
        acct_df["FINAL_FORECAST_CPA"] = acct_df["PRELIM_FORECAST_CPA"]
        return acct_df

    assumed = match["MARKETING_EXPENSE"].values[0]
    predicted = acct_df["PRELIM_FORECAST_CPA"].sum()

    if predicted == 0:
        log.error("predicted total is 0, cant compute factor")
        acct_df["MARKETING_FACTOR"] = 1.0
        acct_df["FINAL_FORECAST_CPA"] = 0.0
        return acct_df

    factor = assumed / predicted
    log.info(f"assumed: {assumed:,.2f} | predicted: {predicted:,.2f} | factor: {factor:.4f}")

    if abs(factor - 1.0) > FACTOR_WARN_THRESHOLD:
        log.warning(
            f"factor {factor:.4f} deviates {abs(factor-1.0):.1%} from 1.0 "
            f"(threshold {FACTOR_WARN_THRESHOLD:.0%}) — investigate before trusting output"
        )

    acct_df["MARKETING_FACTOR"] = factor
    acct_df["FINAL_FORECAST_CPA"] = acct_df["PRELIM_FORECAST_CPA"] * factor
    return acct_df


def write_output(session, acct_df):
    log.info(f"writing {len(acct_df):,} rows to {OUTPUT_TABLE}...")

    out = pd.DataFrame({
        "REPORTINGDATE": acct_df.get("REPORTINGDATE", pd.to_datetime(REPORTING_DATE)),
        "ACCOUNT_NUMBER_HK": acct_df["ACCOUNT_NUMBER_HK"],
        "CPA_SOURCE": acct_df["CPA_SOURCE"],
        "FINAL_FORECAST_CPA": acct_df["FINAL_FORECAST_CPA"],
        "PRELIM_FORECAST_CPA": acct_df["PRELIM_FORECAST_CPA"],
        "MARKETING_FACTOR": acct_df["MARKETING_FACTOR"],
        "PREDICTION_QUALITY": acct_df["PREDICTION_QUALITY"],
        "COMMENT": "forecast",
        "MODEL_NAME": MODEL_NAME,
        "LOAD_TS": datetime.utcnow(),
    })

    session.create_dataframe(out).write.mode("overwrite").save_as_table(OUTPUT_TABLE)
    log.info(f"total CPA: {out['FINAL_FORECAST_CPA'].sum():,.2f} | nulls: {out['FINAL_FORECAST_CPA'].isna().sum()}")
    return out


def run(session=None):
    if session is None:
        session = get_active_session()

    rpt = datetime.strptime(REPORTING_DATE, "%Y-%m-%d")
    start = (rpt.replace(day=1) - timedelta(days=1)).replace(day=1).strftime("%Y-%m-%d")
    end = (rpt.replace(day=1) - timedelta(days=1)).strftime("%Y-%m-%d")

    log.info(f"=== CPA INFERENCE | {REPORTING_DATE} | window {start} to {end} ===")

    model, metadata = load_model(session)
    features = metadata.get("feature_cols", [])

    # source table should already exist from the SQL cell
    ct = session.table("DB_RISK.RISK_SBX.SOURCE_TABLE").count()
    log.info(f"source table: {ct:,} accounts")

    acct_df = build_inference_features(session, metadata)
    acct_df = predict(model, acct_df, features)
    acct_df = apply_budget_factor(session, acct_df)
    out = write_output(session, acct_df)

    log.info("done.")
    return out


if __name__ == "__main__":
    run(get_active_session())
