"""
CPA Forecasting — Inference Pipeline
======================================
Loads the trained XGBoost model and generates CPA predictions for
new accounts in the current reporting period.

Environment: Snowflake Snowpark Notebook / Python 3.10+
Dependencies: snowflake-snowpark-python, xgboost, scikit-learn, pandas, numpy, joblib

Usage:
    1. Ensure training pipeline has run and saved a model to the stage
    2. Set REPORTING_DATE to the current period
    3. Run in a Snowflake Notebook or as a stored procedure
    4. Predictions are written to the output table
"""

import pandas as pd
import numpy as np
import json
import logging
import joblib
from io import BytesIO
from datetime import datetime, timedelta

from snowflake.snowpark.context import get_active_session
from snowflake.snowpark import Session, Window, functions as F
from snowflake.snowpark.functions import (
    sum as sf_sum, col, avg, coalesce, is_null, row_number, lit,
)
from snowflake.snowpark.types import *

# ──────────────────────────────────────────────
# CONFIG
# ──────────────────────────────────────────────
REPORTING_DATE = "2026-03-02"
MODEL_STAGE = "@DB_RISK.RISK_SBX.CPA_MODEL_STAGE"
MODEL_NAME = "cpa_xgb_model"
OUTPUT_TABLE = "DB_RISK.RISK_SBX.CPA_FORECASTED_TABLE"
BUDGET_FACTOR_THRESHOLD = 0.20  # warn if factor deviates >20% from 1.0

# ──────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────
logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)s  %(message)s")
log = logging.getLogger("cpa_inference")


# ══════════════════════════════════════════════
# 1. LOAD MODEL & METADATA
# ══════════════════════════════════════════════
def load_model(session):
    """Download model artifact and metadata from Snowflake stage."""
    log.info(f"Loading model from {MODEL_STAGE}/{MODEL_NAME}...")

    # ── Download model ──
    model_stream = session.file.get_stream(f"{MODEL_STAGE}/{MODEL_NAME}.joblib")
    model = joblib.load(BytesIO(model_stream.read()))

    # ── Download metadata ──
    meta_stream = session.file.get_stream(f"{MODEL_STAGE}/{MODEL_NAME}_metadata.json")
    metadata = json.loads(meta_stream.read().decode())

    log.info(f"  Model trained at : {metadata.get('trained_at', 'unknown')}")
    log.info(f"  Training MAE     : {metadata.get('best_cv_mae', 'N/A')}")
    log.info(f"  Features         : {len(metadata.get('feature_cols', []))}")

    return model, metadata


# ══════════════════════════════════════════════
# 2. SOURCE ASSIGNMENT (new accounts)
# ══════════════════════════════════════════════
def create_source_table(session, start_date: str, end_date: str):
    """
    Run the source assignment SQL for new accounts in the reporting period.
    This creates DB_RISK.RISK_SBX.SOURCE_TABLE as a temp table.
    """
    log.info(f"Assigning sources for {start_date} → {end_date}...")

    # NOTE: The full SQL with CASE WHEN logic is kept in the SQL cell of the notebook.
    # Here we call it as a stored procedure or run the SQL directly.
    # For brevity, we assume SOURCE_TABLE already exists from the SQL cell.
    # If running standalone, uncomment and execute the full SQL here.

    count = session.table("DB_RISK.RISK_SBX.SOURCE_TABLE").count()
    log.info(f"  New accounts with sources : {count:,}")
    return count


# ══════════════════════════════════════════════
# 3. BUILD INFERENCE FEATURES
# ══════════════════════════════════════════════
def build_inference_features(session, metadata: dict) -> pd.DataFrame:
    """
    Build the same feature set for new accounts that the model expects.
    For lag/rolling features, we pull recent actuals as reference.
    """
    log.info("Building inference features...")

    # ── Pull new accounts ──
    acct_df = session.table("DB_RISK.RISK_SBX.SOURCE_TABLE").to_pandas()
    acct_df.columns = [c.upper() for c in acct_df.columns]

    # Standardise column names to match training schema
    col_map = {
        "ORIGINAL_CARD_NETWORK": "ORGINAL_CARD_NETWORK",
        "ORIGINAL_ANNUAL_FEE_CONFIG": "ORGINAL_ANNUAL_FEE_CONFIG",
        "ORIGINAL_CREDIT_LINE": "ORIGINAL_CREDIT_LINE",
        "SOURCE": "CPA_SOURCE",
        "ORIGINAL_BOARD_CHANNEL": "BOARD_CHANNEL",
    }
    acct_df.rename(columns={k: v for k, v in col_map.items() if k in acct_df.columns}, inplace=True)

    # ── Derive SUBCHANNEL_CODE from BOARD_CHANNEL ──
    channel_map = {"DM": "PA", "WEB": "PQ"}
    if "BOARD_CHANNEL" in acct_df.columns:
        acct_df["SUBCHANNEL_CODE"] = acct_df["BOARD_CHANNEL"].map(channel_map).fillna("SECA")

    # ── Temporal features for the reporting period ──
    report_dt = pd.to_datetime(REPORTING_DATE)
    acct_df["REPORTING_DATE"] = report_dt
    acct_df["MONTH"] = report_dt.month
    acct_df["QUARTER"] = report_dt.quarter
    acct_df["YEAR"] = report_dt.year
    # MONTHS_SINCE_START — use same baseline as training
    # This is approximate; exact value depends on training data min date
    acct_df["MONTHS_SINCE_START"] = (report_dt.year - 2024) * 12 + report_dt.month

    # ── Lag / rolling features from recent actuals ──
    log.info("  Computing lag features from recent actuals...")
    recent_actuals = _get_recent_source_averages(session, n_months=3)

    for lag in [1, 2, 3]:
        lag_col = f"CPA_LAG_{lag}"
        if lag_col in recent_actuals.columns:
            acct_df = acct_df.merge(
                recent_actuals[["CPA_SOURCE", lag_col]].drop_duplicates(),
                on="CPA_SOURCE",
                how="left",
            )
        else:
            acct_df[lag_col] = np.nan

    for roll_col in ["CPA_ROLLING_3M_MEAN", "CPA_ROLLING_3M_STD"]:
        if roll_col in recent_actuals.columns:
            acct_df = acct_df.merge(
                recent_actuals[["CPA_SOURCE", roll_col]].drop_duplicates(),
                on="CPA_SOURCE",
                how="left",
            )
        else:
            acct_df[roll_col] = 0.0

    # ── Credit line binning ──
    if "ORIGINAL_CREDIT_LINE" in acct_df.columns:
        acct_df["CREDIT_LINE_BIN"] = pd.cut(
            acct_df["ORIGINAL_CREDIT_LINE"].fillna(0),
            bins=[0, 300, 500, 750, 1000, 2000, 5000, np.inf],
            labels=[0, 1, 2, 3, 4, 5, 6],
        ).astype(float)
    else:
        acct_df["CREDIT_LINE_BIN"] = 0.0

    # ── Categorical encoding (must match training) ──
    cat_cols = metadata.get("categorical_cols", [])
    for c in cat_cols:
        if c in acct_df.columns:
            acct_df[c] = acct_df[c].astype("category")

    # ── Fill remaining NaNs in numeric features ──
    numeric_features = [
        "CPA_LAG_1", "CPA_LAG_2", "CPA_LAG_3",
        "CPA_ROLLING_3M_MEAN", "CPA_ROLLING_3M_STD",
        "CREDIT_LINE_BIN", "MONTHS_SINCE_START",
    ]
    for c in numeric_features:
        if c in acct_df.columns:
            acct_df[c] = acct_df[c].fillna(0)

    log.info(f"  Inference rows   : {len(acct_df):,}")
    log.info(f"  Feature columns  : {len(metadata.get('feature_cols', []))}")

    return acct_df


def _get_recent_source_averages(session, n_months: int = 3) -> pd.DataFrame:
    """
    Pull the last N months of actuals and compute per-source lag/rolling stats.
    These serve as the 'most recent history' for inference-time features.
    """
    query = f"""
        SELECT CPA_SOURCE, CPA_AMOUNT, to_date(ACCOUNT_OPEN_MONTH, 'DDMONYYYY') as RPT_DATE
        FROM CSTONE_BIZ.RISK.PTI_FACT_CPA
        WHERE comment = 'actuals'
          AND to_date(ACCOUNT_OPEN_MONTH, 'DDMONYYYY')
              >= DATEADD('month', -{n_months + 3}, CURRENT_DATE())
        ORDER BY CPA_SOURCE, RPT_DATE
    """
    df = session.sql(query).to_pandas()
    df["RPT_DATE"] = pd.to_datetime(df["RPT_DATE"])

    # Compute monthly averages per source
    monthly = (
        df.groupby(["CPA_SOURCE", pd.Grouper(key="RPT_DATE", freq="M")])["CPA_AMOUNT"]
        .mean()
        .reset_index()
        .sort_values(["CPA_SOURCE", "RPT_DATE"])
    )

    # Build lag features from monthly averages
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

    # Keep only the most recent row per source
    latest = monthly.groupby("CPA_SOURCE").last().reset_index()
    return latest


# ══════════════════════════════════════════════
# 4. PREDICTION
# ══════════════════════════════════════════════
def predict_cpa(model, acct_df: pd.DataFrame, feature_cols: list) -> pd.DataFrame:
    """
    Generate CPA predictions and track match quality.
    """
    log.info("Generating predictions...")

    available = [c for c in feature_cols if c in acct_df.columns]
    missing = set(feature_cols) - set(available)
    if missing:
        log.warning(f"  Missing features (filled with 0): {missing}")
        for c in missing:
            acct_df[c] = 0

    X = acct_df[feature_cols]
    preds = model.predict(X)
    preds = np.clip(preds, 0, None)  # CPA cannot be negative

    acct_df["PRELIM_FORECAST_CPA"] = preds

    # ── Track prediction confidence ──
    # Accounts with lag history get higher confidence
    has_lag = acct_df["CPA_LAG_1"].notna() & (acct_df["CPA_LAG_1"] > 0)
    acct_df["PREDICTION_QUALITY"] = np.where(has_lag, "MODEL_WITH_HISTORY", "MODEL_NO_HISTORY")

    quality_dist = acct_df["PREDICTION_QUALITY"].value_counts()
    log.info("  Prediction quality distribution:")
    for qual, cnt in quality_dist.items():
        log.info(f"    {qual:<25} {cnt:>8,} ({cnt/len(acct_df):.1%})")

    log.info(f"  Predicted CPA range : [{preds.min():,.2f}, {preds.max():,.2f}]")
    log.info(f"  Predicted CPA mean  : {preds.mean():,.2f}")

    return acct_df


# ══════════════════════════════════════════════
# 5. BUDGET FACTOR APPLICATION
# ══════════════════════════════════════════════
def apply_budget_factor(session, acct_df: pd.DataFrame) -> pd.DataFrame:
    """
    Scale predictions to match the budget assumption from PTI_ASSUMPTIONS.
    Logs a warning if the scaling factor deviates significantly from 1.0.
    """
    log.info("Applying budget scaling factor...")

    # ── Get assumption ──
    report_dt = pd.to_datetime(REPORTING_DATE)
    last_day = (report_dt.replace(day=1) - timedelta(days=1))

    asmp_df = session.table("CSTONE_BIZ.RISK.PTI_ASSUMPTIONS").to_pandas()
    asmp_df["SRC_REPORTING_DATE"] = pd.to_datetime(asmp_df["SRC_REPORTING_DATE"])

    # Find the matching assumption row
    asmp_row = asmp_df[
        asmp_df["SRC_REPORTING_DATE"] == pd.to_datetime(last_day)
    ]

    if asmp_row.empty:
        log.warning("  No matching assumption found — skipping budget factor.")
        acct_df["MARKETING_FACTOR"] = 1.0
        acct_df["FINAL_FORECAST_CPA"] = acct_df["PRELIM_FORECAST_CPA"]
        return acct_df

    budget_assumed = asmp_row["MARKETING_EXPENSE"].values[0]
    budget_predicted = acct_df["PRELIM_FORECAST_CPA"].sum()

    if budget_predicted == 0:
        log.error("  Total predicted CPA is 0 — cannot compute factor.")
        acct_df["MARKETING_FACTOR"] = 1.0
        acct_df["FINAL_FORECAST_CPA"] = 0.0
        return acct_df

    factor = budget_assumed / budget_predicted

    log.info(f"  Budget assumed   : {budget_assumed:>14,.2f}")
    log.info(f"  Budget predicted : {budget_predicted:>14,.2f}")
    log.info(f"  Scaling factor   : {factor:>14.4f}")

    # ── Sanity check ──
    deviation = abs(factor - 1.0)
    if deviation > BUDGET_FACTOR_THRESHOLD:
        log.warning(
            f"  ⚠ FACTOR ALERT: Scaling factor {factor:.4f} deviates "
            f"{deviation:.1%} from 1.0 (threshold: {BUDGET_FACTOR_THRESHOLD:.0%}). "
            f"Model predictions may be unreliable — investigate root cause."
        )
    else:
        log.info(f"  Factor within acceptable range (±{BUDGET_FACTOR_THRESHOLD:.0%})")

    acct_df["MARKETING_FACTOR"] = factor
    acct_df["FINAL_FORECAST_CPA"] = acct_df["PRELIM_FORECAST_CPA"] * factor

    log.info(f"  Final CPA range  : [{acct_df['FINAL_FORECAST_CPA'].min():,.2f}, {acct_df['FINAL_FORECAST_CPA'].max():,.2f}]")
    log.info(f"  Final CPA total  : {acct_df['FINAL_FORECAST_CPA'].sum():,.2f}")

    return acct_df


# ══════════════════════════════════════════════
# 6. OUTPUT — WRITE TO SNOWFLAKE
# ══════════════════════════════════════════════
def write_output(session, acct_df: pd.DataFrame):
    """
    Write final forecasted CPAs to the output table.
    Includes lineage columns for auditability.
    """
    log.info(f"Writing {len(acct_df):,} rows to {OUTPUT_TABLE}...")

    output_cols = {
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
    }
    output_df = pd.DataFrame(output_cols)

    sf_df = session.create_dataframe(output_df)
    sf_df.write.mode("overwrite").save_as_table(OUTPUT_TABLE)

    log.info(f"  Written successfully to {OUTPUT_TABLE}")

    # ── Summary stats ──
    log.info("")
    log.info("  OUTPUT SUMMARY:")
    log.info(f"    Total accounts         : {len(output_df):,}")
    log.info(f"    Total forecasted CPA   : {output_df['FINAL_FORECAST_CPA'].sum():,.2f}")
    log.info(f"    Mean forecasted CPA    : {output_df['FINAL_FORECAST_CPA'].mean():,.2f}")
    log.info(f"    Null CPA count         : {output_df['FINAL_FORECAST_CPA'].isna().sum()}")

    # ── Quality distribution ──
    qual_dist = output_df["PREDICTION_QUALITY"].value_counts()
    log.info("    Prediction quality:")
    for qual, cnt in qual_dist.items():
        log.info(f"      {qual:<25} {cnt:>8,} ({cnt/len(output_df):.1%})")

    return output_df


# ══════════════════════════════════════════════
# 7. MAIN ORCHESTRATOR
# ══════════════════════════════════════════════
def run_inference_pipeline(session=None):
    """End-to-end inference pipeline."""
    if session is None:
        session = get_active_session()

    report_dt = datetime.strptime(REPORTING_DATE, "%Y-%m-%d")
    first_day_current = report_dt.replace(day=1)
    last_day_prev = first_day_current - timedelta(days=1)
    first_day_prev = last_day_prev.replace(day=1)
    start_date = first_day_prev.strftime("%Y-%m-%d")
    end_date = last_day_prev.strftime("%Y-%m-%d")

    log.info("=" * 60)
    log.info("CPA FORECASTING — INFERENCE PIPELINE")
    log.info(f"Reporting date   : {REPORTING_DATE}")
    log.info(f"Account window   : {start_date} → {end_date}")
    log.info(f"Model            : {MODEL_STAGE}/{MODEL_NAME}")
    log.info("=" * 60)

    # Step 1: Load model
    model, metadata = load_model(session)
    feature_cols = metadata.get("feature_cols", [])

    # Step 2: Source assignment (assumes SQL cell has run)
    create_source_table(session, start_date, end_date)

    # Step 3: Build inference features
    acct_df = build_inference_features(session, metadata)

    # Step 4: Predict
    acct_df = predict_cpa(model, acct_df, feature_cols)

    # Step 5: Apply budget factor
    acct_df = apply_budget_factor(session, acct_df)

    # Step 6: Write output
    output_df = write_output(session, acct_df)

    log.info("")
    log.info("✓ Inference pipeline complete.")
    log.info("=" * 60)

    return output_df


# ──────────────────────────────────────────────
# ENTRY POINT
# ──────────────────────────────────────────────
if __name__ == "__main__":
    session = get_active_session()
    results = run_inference_pipeline(session)
