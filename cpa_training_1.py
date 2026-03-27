"""
CPA XGBoost Training Pipeline
Trains model on N months of actuals, saves artifact to stage for inference pickup
"""

import pandas as pd
import numpy as np
import json
import joblib
import logging
from datetime import datetime, timedelta
from io import BytesIO

from snowflake.snowpark.context import get_active_session
from xgboost import XGBRegressor
from sklearn.model_selection import TimeSeriesSplit, RandomizedSearchCV
from sklearn.metrics import mean_absolute_error, mean_squared_error, mean_absolute_percentage_error

log = logging.getLogger("cpa_train")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# ── config ──
REPORTING_DATE = "2026-03-02"
LOOKBACK_MONTHS = 24
HOLDOUT_MONTHS = 2
CV_FOLDS = 5
N_ITER = 50
MODEL_STAGE = "@DB_RISK.RISK_SBX.CPA_MODEL_STAGE"
MODEL_NAME = "cpa_xgb_model"

CAT_COLS = ["CPA_SOURCE", "ORGINAL_ANNUAL_FEE_CONFIG", "ORGINAL_CARD_NETWORK", "SUBCHANNEL_CODE"]

FEATURES = [
    *CAT_COLS,
    "MONTH", "QUARTER", "YEAR", "MONTHS_SINCE_START",
    "CPA_LAG_1", "CPA_LAG_2", "CPA_LAG_3",
    "CPA_ROLLING_3M_MEAN", "CPA_ROLLING_3M_STD",
    "CREDIT_LINE_BIN",
]

TARGET = "CPA_AMOUNT"

PARAM_GRID = {
    "n_estimators": [100, 200, 300, 500],
    "max_depth": [3, 4, 5, 6],
    "learning_rate": [0.01, 0.05, 0.1],
    "subsample": [0.7, 0.8, 0.9],
    "colsample_bytree": [0.7, 0.8, 0.9],
    "min_child_weight": [1, 3, 5],
    "reg_alpha": [0, 0.1, 1.0],
    "reg_lambda": [1.0, 5.0, 10.0],
}


def get_actuals(session, lookback):
    q = f"""
        SELECT * FROM CSTONE_BIZ.RISK.PTI_FACT_CPA
        WHERE comment = 'actuals'
          AND to_date(ACCOUNT_OPEN_MONTH, 'DDMONYYYY') >= DATEADD('month', -{lookback}, CURRENT_DATE())
    """
    df = session.sql(q).to_pandas()
    df["REPORTING_DATE"] = pd.to_datetime(df["ACCOUNT_OPEN_MONTH"], format="%d%b%Y")
    df.drop(columns=["ACCOUNT_OPEN_MONTH"], inplace=True, errors="ignore")
    log.info(f"pulled {len(df):,} rows | {df['REPORTING_DATE'].min().date()} to {df['REPORTING_DATE'].max().date()}")
    return df


def build_features(df):
    df = df.copy()
    df["REPORTING_DATE"] = pd.to_datetime(df["REPORTING_DATE"])
    df = df.sort_values(["CPA_SOURCE", "REPORTING_DATE"]).reset_index(drop=True)

    # time
    df["MONTH"] = df["REPORTING_DATE"].dt.month
    df["QUARTER"] = df["REPORTING_DATE"].dt.quarter
    df["YEAR"] = df["REPORTING_DATE"].dt.year
    df["MONTHS_SINCE_START"] = (
        (df["REPORTING_DATE"].dt.year - df["REPORTING_DATE"].dt.year.min()) * 12
        + df["REPORTING_DATE"].dt.month
    )

    # lags per source — grouped so we dont leak across sources
    for lag in [1, 2, 3]:
        df[f"CPA_LAG_{lag}"] = df.groupby("CPA_SOURCE")[TARGET].shift(lag)

    # rolling stats per source
    for src, grp in df.groupby("CPA_SOURCE"):
        mask = df["CPA_SOURCE"] == src
        df.loc[mask, "CPA_ROLLING_3M_MEAN"] = grp[TARGET].rolling(3, min_periods=1).mean().values
        df.loc[mask, "CPA_ROLLING_3M_STD"] = grp[TARGET].rolling(3, min_periods=1).std().fillna(0).values

    # credit line buckets
    if "ORIGINAL_CREDIT_LINE" in df.columns:
        df["CREDIT_LINE_BIN"] = pd.cut(
            df["ORIGINAL_CREDIT_LINE"],
            bins=[0, 300, 500, 750, 1000, 2000, 5000, np.inf],
            labels=[0, 1, 2, 3, 4, 5, 6],
        ).astype(float)
    else:
        df["CREDIT_LINE_BIN"] = 0.0

    for c in CAT_COLS:
        if c in df.columns:
            df[c] = df[c].astype("category")

    before = len(df)
    df = df.dropna(subset=["CPA_LAG_1"])
    log.info(f"dropped {before - len(df):,} rows without lag history")
    return df


def temporal_split(df, holdout=2):
    """train on past, test on most recent N months — no shuffling"""
    df = df.sort_values("REPORTING_DATE")
    cutoff = df["REPORTING_DATE"].max() - pd.DateOffset(months=holdout)
    train = df[df["REPORTING_DATE"] <= cutoff].copy()
    test = df[df["REPORTING_DATE"] > cutoff].copy()
    log.info(f"train: {len(train):,} | test: {len(test):,}")
    if len(train) < 100:
        log.warning("training set looks thin — bump LOOKBACK_MONTHS?")
    return train, test


def fit_model(X_train, y_train):
    tscv = TimeSeriesSplit(n_splits=CV_FOLDS)
    base = XGBRegressor(
        enable_categorical=True,
        objective="reg:squarederror",
        tree_method="hist",
        random_state=42,
    )
    search = RandomizedSearchCV(
        base, PARAM_GRID,
        n_iter=N_ITER, cv=tscv,
        scoring="neg_mean_absolute_error",
        random_state=42, n_jobs=-1, verbose=0,
    )
    search.fit(X_train, y_train)
    log.info(f"best CV MAE: {-search.best_score_:,.4f}")
    log.info(f"best params: {search.best_params_}")
    return search


def evaluate(model, X_test, y_test, test_df):
    preds = np.clip(model.predict(X_test), 0, None)

    mae = mean_absolute_error(y_test, preds)
    rmse = np.sqrt(mean_squared_error(y_test, preds))
    mape = mean_absolute_percentage_error(y_test, preds)
    log.info(f"test MAE: {mae:,.4f} | RMSE: {rmse:,.4f} | MAPE: {mape:.2%}")

    # compare against naive baseline (just use last months cpa)
    if "CPA_LAG_1" in test_df.columns:
        baseline = mean_absolute_error(y_test, test_df["CPA_LAG_1"])
        log.info(f"baseline MAE (lag1): {baseline:,.4f} | improvement: {(baseline - mae) / baseline:.1%}")

    # per source breakdown
    eval_df = test_df.copy()
    eval_df["PRED"] = preds
    log.info(f"{'SOURCE':<16} {'MAE':>10} {'N':>8}")
    for src, grp in eval_df.groupby("CPA_SOURCE"):
        src_mae = mean_absolute_error(grp[TARGET], grp["PRED"])
        log.info(f"{str(src):<16} {src_mae:>10,.2f} {len(grp):>8,}")

    # feature importance top 6
    best = model.best_estimator_ if hasattr(model, "best_estimator_") else model
    imp = pd.Series(best.feature_importances_, index=FEATURES).sort_values(ascending=False)
    log.info("top features:")
    for f, v in imp.head(6).items():
        log.info(f"  {f:<25} {v:.4f}")

    return {"mae": mae, "rmse": rmse, "mape": mape}


def save_model(session, model, metrics):
    best = model.best_estimator_ if hasattr(model, "best_estimator_") else model

    buf = BytesIO()
    joblib.dump(best, buf)
    buf.seek(0)
    session.file.put_stream(buf, f"{MODEL_STAGE}/{MODEL_NAME}.joblib", auto_compress=False, overwrite=True)

    meta = {
        "model_name": MODEL_NAME,
        "trained_at": datetime.utcnow().isoformat(),
        "reporting_date": REPORTING_DATE,
        "lookback_months": LOOKBACK_MONTHS,
        "feature_cols": FEATURES,
        "categorical_cols": CAT_COLS,
        "target_col": TARGET,
        "best_params": model.best_params_ if hasattr(model, "best_params_") else {},
        "best_cv_mae": float(-model.best_score_) if hasattr(model, "best_score_") else None,
        "test_metrics": metrics,
    }
    meta_buf = BytesIO(json.dumps(meta, indent=2, default=str).encode())
    meta_buf.seek(0)
    session.file.put_stream(meta_buf, f"{MODEL_STAGE}/{MODEL_NAME}_metadata.json", auto_compress=False, overwrite=True)
    log.info(f"saved to {MODEL_STAGE}")
    return meta


def run(session=None):
    if session is None:
        session = get_active_session()

    log.info(f"=== CPA TRAINING | {REPORTING_DATE} | {LOOKBACK_MONTHS}mo lookback ===")

    raw = get_actuals(session, LOOKBACK_MONTHS)
    df = build_features(raw)
    train_df, test_df = temporal_split(df, HOLDOUT_MONTHS)

    avail = [c for c in FEATURES if c in train_df.columns]
    X_train, y_train = train_df[avail], train_df[TARGET]
    X_test, y_test = test_df[avail], test_df[TARGET]

    search = fit_model(X_train, y_train)
    metrics = evaluate(search, X_test, y_test, test_df)
    save_model(session, search, metrics)

    log.info("done.")
    return search


if __name__ == "__main__":
    run(get_active_session())
