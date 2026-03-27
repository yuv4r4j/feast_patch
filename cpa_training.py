"""
CPA Forecasting — Training Pipeline
=====================================
Trains an XGBoost model to predict Cost Per Acquisition (CPA) amounts
using temporal features, lag features, and categorical attributes.

Environment: Snowflake Snowpark Notebook / Python 3.10+
Dependencies: snowflake-snowpark-python, xgboost, scikit-learn, pandas, numpy, joblib

Usage:
    1. Set REPORTING_DATE and LOOKBACK_MONTHS in the config section
    2. Run in a Snowflake Notebook or as a stored procedure
    3. Model artifact is saved to a Snowflake stage for inference pickup
"""

import pandas as pd
import numpy as np
import json
import logging
import joblib
from datetime import datetime, timedelta
from io import BytesIO

from snowflake.snowpark.context import get_active_session
from snowflake.snowpark import functions as F

from xgboost import XGBRegressor
from sklearn.model_selection import TimeSeriesSplit, RandomizedSearchCV
from sklearn.metrics import (
    mean_absolute_error,
    mean_squared_error,
    mean_absolute_percentage_error,
)

# ──────────────────────────────────────────────
# CONFIG
# ──────────────────────────────────────────────
REPORTING_DATE = "2026-03-02"
LOOKBACK_MONTHS = 24          # training history depth
HOLDOUT_MONTHS = 2            # most recent months held out for validation
CV_FOLDS = 5                  # TimeSeriesSplit folds
RANDOM_SEARCH_ITER = 50       # number of hyperparameter combos to try
RANDOM_STATE = 42
MODEL_STAGE = "@DB_RISK.RISK_SBX.CPA_MODEL_STAGE"
MODEL_NAME = "cpa_xgb_model"

# ──────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────
logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)s  %(message)s")
log = logging.getLogger("cpa_training")


# ══════════════════════════════════════════════
# 1. DATA EXTRACTION
# ══════════════════════════════════════════════
def extract_training_data(session, lookback_months: int) -> pd.DataFrame:
    """Pull N months of CPA actuals from the fact table."""
    log.info(f"Extracting {lookback_months} months of CPA actuals...")

    query = f"""
        SELECT *
        FROM CSTONE_BIZ.RISK.PTI_FACT_CPA
        WHERE comment = 'actuals'
          AND to_date(ACCOUNT_OPEN_MONTH, 'DDMONYYYY')
              >= DATEADD('month', -{lookback_months}, CURRENT_DATE())
    """
    sf_df = session.sql(query)
    df = sf_df.to_pandas()

    # Normalise date column
    df["REPORTING_DATE"] = pd.to_datetime(df["ACCOUNT_OPEN_MONTH"], format="%d%b%Y")
    df.drop(columns=["ACCOUNT_OPEN_MONTH"], inplace=True, errors="ignore")

    log.info(f"  Rows extracted   : {len(df):,}")
    log.info(f"  Date range       : {df['REPORTING_DATE'].min().date()} → {df['REPORTING_DATE'].max().date()}")
    log.info(f"  Unique months    : {df['REPORTING_DATE'].dt.to_period('M').nunique()}")
    return df


# ══════════════════════════════════════════════
# 2. FEATURE ENGINEERING
# ══════════════════════════════════════════════
CATEGORICAL_COLS = [
    "CPA_SOURCE",
    "ORGINAL_ANNUAL_FEE_CONFIG",
    "ORGINAL_CARD_NETWORK",
    "SUBCHANNEL_CODE",
]

FEATURE_COLS = [
    # categoricals
    *CATEGORICAL_COLS,
    # temporal
    "MONTH",
    "QUARTER",
    "YEAR",
    "MONTHS_SINCE_START",
    # lags
    "CPA_LAG_1",
    "CPA_LAG_2",
    "CPA_LAG_3",
    # rolling
    "CPA_ROLLING_3M_MEAN",
    "CPA_ROLLING_3M_STD",
    # credit line bin
    "CREDIT_LINE_BIN",
]

TARGET_COL = "CPA_AMOUNT"


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Engineer temporal, lag, rolling, and categorical features.
    Groups lags/rolling by CPA_SOURCE to prevent cross-source leakage.
    """
    df = df.copy()
    df["REPORTING_DATE"] = pd.to_datetime(df["REPORTING_DATE"])
    df = df.sort_values(["CPA_SOURCE", "REPORTING_DATE"]).reset_index(drop=True)

    # ── Temporal features ──
    df["MONTH"] = df["REPORTING_DATE"].dt.month
    df["QUARTER"] = df["REPORTING_DATE"].dt.quarter
    df["YEAR"] = df["REPORTING_DATE"].dt.year
    min_year = df["REPORTING_DATE"].dt.year.min()
    df["MONTHS_SINCE_START"] = (
        (df["REPORTING_DATE"].dt.year - min_year) * 12 + df["REPORTING_DATE"].dt.month
    )

    # ── Lag features (per source) ──
    for lag in [1, 2, 3]:
        df[f"CPA_LAG_{lag}"] = df.groupby("CPA_SOURCE")[TARGET_COL].shift(lag)

    # ── Rolling features (per source) ──
    for src, grp in df.groupby("CPA_SOURCE"):
        mask = df["CPA_SOURCE"] == src
        df.loc[mask, "CPA_ROLLING_3M_MEAN"] = (
            grp[TARGET_COL].rolling(3, min_periods=1).mean().values
        )
        df.loc[mask, "CPA_ROLLING_3M_STD"] = (
            grp[TARGET_COL].rolling(3, min_periods=1).std().fillna(0).values
        )

    # ── Credit line binning ──
    if "ORIGINAL_CREDIT_LINE" in df.columns:
        df["CREDIT_LINE_BIN"] = pd.cut(
            df["ORIGINAL_CREDIT_LINE"],
            bins=[0, 300, 500, 750, 1000, 2000, 5000, np.inf],
            labels=[0, 1, 2, 3, 4, 5, 6],
        ).astype(float)
    else:
        df["CREDIT_LINE_BIN"] = 0.0

    # ── Categorical encoding ──
    for col in CATEGORICAL_COLS:
        if col in df.columns:
            df[col] = df[col].astype("category")

    # ── Drop rows where lags are unavailable ──
    before = len(df)
    df = df.dropna(subset=["CPA_LAG_1"])
    log.info(f"  Dropped {before - len(df):,} rows without lag history")

    return df


# ══════════════════════════════════════════════
# 3. TEMPORAL SPLIT
# ══════════════════════════════════════════════
def temporal_split(df: pd.DataFrame, holdout_months: int = 2):
    """
    Split into train / test using a temporal cutoff.
    No shuffling — train on the past, validate on the future.
    """
    df = df.sort_values("REPORTING_DATE")
    cutoff = df["REPORTING_DATE"].max() - pd.DateOffset(months=holdout_months)

    train = df[df["REPORTING_DATE"] <= cutoff].copy()
    test = df[df["REPORTING_DATE"] > cutoff].copy()

    log.info(f"  Train : {len(train):>8,} rows  |  {train['REPORTING_DATE'].min().date()} → {train['REPORTING_DATE'].max().date()}")
    log.info(f"  Test  : {len(test):>8,} rows  |  {test['REPORTING_DATE'].min().date()} → {test['REPORTING_DATE'].max().date()}")

    if len(train) < 100:
        log.warning("  ⚠ Training set is very small — consider increasing LOOKBACK_MONTHS")
    return train, test


# ══════════════════════════════════════════════
# 4. MODEL TRAINING WITH CV + TUNING
# ══════════════════════════════════════════════
PARAM_SPACE = {
    "n_estimators": [100, 200, 300, 500],
    "max_depth": [3, 4, 5, 6],
    "learning_rate": [0.01, 0.05, 0.1],
    "subsample": [0.7, 0.8, 0.9],
    "colsample_bytree": [0.7, 0.8, 0.9],
    "min_child_weight": [1, 3, 5],
    "reg_alpha": [0, 0.1, 1.0],
    "reg_lambda": [1.0, 5.0, 10.0],
}


def train_model(X_train, y_train):
    """
    Train XGBRegressor with RandomizedSearchCV + TimeSeriesSplit.
    Returns the fitted search object (best estimator accessible via .best_estimator_).
    """
    log.info("Training XGBoost with RandomizedSearchCV...")
    log.info(f"  Features       : {X_train.shape[1]}")
    log.info(f"  Training rows  : {X_train.shape[0]:,}")
    log.info(f"  CV folds       : {CV_FOLDS}")
    log.info(f"  Search iter    : {RANDOM_SEARCH_ITER}")

    tscv = TimeSeriesSplit(n_splits=CV_FOLDS)

    base_model = XGBRegressor(
        enable_categorical=True,
        objective="reg:squarederror",
        random_state=RANDOM_STATE,
        tree_method="hist",
    )

    search = RandomizedSearchCV(
        base_model,
        param_distributions=PARAM_SPACE,
        n_iter=RANDOM_SEARCH_ITER,
        cv=tscv,
        scoring="neg_mean_absolute_error",
        random_state=RANDOM_STATE,
        verbose=0,
        n_jobs=-1,
    )

    search.fit(X_train, y_train)

    log.info(f"  Best CV MAE    : {-search.best_score_:,.4f}")
    log.info(f"  Best params    : {json.dumps(search.best_params_, indent=2)}")
    return search


# ══════════════════════════════════════════════
# 5. EVALUATION
# ══════════════════════════════════════════════
def evaluate_model(model, X_test, y_test, test_df):
    """
    Compute out-of-sample metrics overall and per CPA_SOURCE.
    Returns a dict of metrics for logging.
    """
    y_pred = model.predict(X_test)
    y_pred = np.clip(y_pred, 0, None)  # CPA cannot be negative

    overall = {
        "mae": mean_absolute_error(y_test, y_pred),
        "rmse": np.sqrt(mean_squared_error(y_test, y_pred)),
        "mape": mean_absolute_percentage_error(y_test, y_pred),
    }

    log.info("=" * 50)
    log.info("OUT-OF-SAMPLE EVALUATION")
    log.info("=" * 50)
    log.info(f"  MAE  : {overall['mae']:>12,.4f}")
    log.info(f"  RMSE : {overall['rmse']:>12,.4f}")
    log.info(f"  MAPE : {overall['mape']:>12.2%}")

    # ── Naive baseline comparison (predict last known CPA) ──
    if "CPA_LAG_1" in test_df.columns:
        baseline_mae = mean_absolute_error(y_test, test_df["CPA_LAG_1"])
        log.info(f"  Baseline MAE (lag-1 naive) : {baseline_mae:>12,.4f}")
        improvement = (baseline_mae - overall["mae"]) / baseline_mae * 100
        log.info(f"  Improvement over baseline  : {improvement:>11.1f}%")
        overall["baseline_mae"] = baseline_mae
        overall["improvement_pct"] = improvement

    # ── Per-source breakdown ──
    log.info("")
    log.info("  Per-Source Breakdown:")
    log.info(f"  {'SOURCE':<16} {'MAE':>10} {'MAPE':>10} {'N':>8}")
    log.info(f"  {'-'*16} {'-'*10} {'-'*10} {'-'*8}")

    source_metrics = {}
    eval_df = test_df.copy()
    eval_df["PRED"] = y_pred

    for src, grp in eval_df.groupby("CPA_SOURCE"):
        src_mae = mean_absolute_error(grp[TARGET_COL], grp["PRED"])
        src_mape = mean_absolute_percentage_error(grp[TARGET_COL], grp["PRED"])
        log.info(f"  {str(src):<16} {src_mae:>10,.2f} {src_mape:>9.1%} {len(grp):>8,}")
        source_metrics[str(src)] = {"mae": src_mae, "mape": src_mape, "n": len(grp)}

    overall["per_source"] = source_metrics

    # ── Feature importance ──
    best = model.best_estimator_ if hasattr(model, "best_estimator_") else model
    importance = pd.Series(
        best.feature_importances_, index=FEATURE_COLS
    ).sort_values(ascending=False)

    log.info("")
    log.info("  Feature Importance (top 8):")
    for feat, imp in importance.head(8).items():
        bar = "█" * int(imp * 50)
        log.info(f"    {feat:<25} {imp:.4f}  {bar}")

    return overall


# ══════════════════════════════════════════════
# 6. MODEL PERSISTENCE
# ══════════════════════════════════════════════
def save_model(session, model, metrics: dict, feature_cols: list):
    """
    Serialise model + metadata and upload to a Snowflake stage.
    """
    log.info(f"Saving model to {MODEL_STAGE}/{MODEL_NAME}...")

    best = model.best_estimator_ if hasattr(model, "best_estimator_") else model

    # ── Serialise model ──
    model_buffer = BytesIO()
    joblib.dump(best, model_buffer)
    model_buffer.seek(0)

    # ── Metadata ──
    metadata = {
        "model_name": MODEL_NAME,
        "trained_at": datetime.utcnow().isoformat(),
        "reporting_date": REPORTING_DATE,
        "lookback_months": LOOKBACK_MONTHS,
        "holdout_months": HOLDOUT_MONTHS,
        "feature_cols": feature_cols,
        "categorical_cols": CATEGORICAL_COLS,
        "target_col": TARGET_COL,
        "best_params": model.best_params_ if hasattr(model, "best_params_") else {},
        "best_cv_mae": float(-model.best_score_) if hasattr(model, "best_score_") else None,
        "test_metrics": {
            k: v for k, v in metrics.items() if k != "per_source"
        },
    }
    meta_buffer = BytesIO(json.dumps(metadata, indent=2, default=str).encode())
    meta_buffer.seek(0)

    # ── Upload to stage ──
    session.file.put_stream(
        model_buffer, f"{MODEL_STAGE}/{MODEL_NAME}.joblib", auto_compress=False, overwrite=True
    )
    session.file.put_stream(
        meta_buffer, f"{MODEL_STAGE}/{MODEL_NAME}_metadata.json", auto_compress=False, overwrite=True
    )

    log.info("  Model and metadata saved successfully.")
    return metadata


# ══════════════════════════════════════════════
# 7. MAIN ORCHESTRATOR
# ══════════════════════════════════════════════
def run_training_pipeline(session=None):
    """End-to-end training pipeline."""
    if session is None:
        session = get_active_session()

    log.info("=" * 60)
    log.info("CPA FORECASTING — TRAINING PIPELINE")
    log.info(f"Reporting date   : {REPORTING_DATE}")
    log.info(f"Lookback         : {LOOKBACK_MONTHS} months")
    log.info("=" * 60)

    # Step 1: Extract
    raw_df = extract_training_data(session, LOOKBACK_MONTHS)

    # Step 2: Feature engineering
    log.info("Building features...")
    df = build_features(raw_df)
    log.info(f"  Final feature matrix : {df.shape}")

    # Step 3: Temporal split
    log.info("Splitting train / test...")
    train_df, test_df = temporal_split(df, HOLDOUT_MONTHS)

    available_features = [c for c in FEATURE_COLS if c in train_df.columns]
    X_train = train_df[available_features]
    y_train = train_df[TARGET_COL]
    X_test = test_df[available_features]
    y_test = test_df[TARGET_COL]

    # Step 4: Train
    search = train_model(X_train, y_train)

    # Step 5: Evaluate
    metrics = evaluate_model(search, X_test, y_test, test_df)

    # Step 6: Save
    metadata = save_model(session, search, metrics, available_features)

    log.info("")
    log.info("✓ Training pipeline complete.")
    log.info(f"  Model artifact : {MODEL_STAGE}/{MODEL_NAME}.joblib")
    log.info(f"  Test MAE       : {metrics['mae']:,.4f}")
    if "improvement_pct" in metrics:
        log.info(f"  vs Baseline    : {metrics['improvement_pct']:+.1f}%")
    log.info("=" * 60)

    return search, metadata


# ──────────────────────────────────────────────
# ENTRY POINT
# ──────────────────────────────────────────────
if __name__ == "__main__":
    session = get_active_session()
    model, metadata = run_training_pipeline(session)
