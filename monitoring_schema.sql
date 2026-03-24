-- ============================================================
-- PostgreSQL DDL — Model Monitoring (13 tables)
-- Prerequisites: shared_infra_schema.sql, ml_schema.sql
-- Covers: drift detection, performance tracking, prediction logging,
--         alerting, data quality, retraining triggers, run tracking,
--         SLA tracking, cost tracking
-- ============================================================

-- 1. monitoring_policy
-- Defines what to monitor for each deployment and how often
CREATE TABLE monitoring_policy (
    policy_id           SERIAL PRIMARY KEY,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    policy_name         VARCHAR(255) NOT NULL,
    monitoring_type     VARCHAR(50) NOT NULL CHECK (monitoring_type IN ('drift', 'performance', 'data_quality', 'latency', 'volume')),
    schedule_cron       VARCHAR(100),                  -- how often monitoring runs
    dag_id              VARCHAR(255),                  -- airflow DAG for monitoring job
    compute_type        VARCHAR(50) NOT NULL CHECK (compute_type IN ('pyspark', 'snowpark')),
    lookback_window     VARCHAR(50),                   -- 1h, 24h, 7d — data window per check
    baseline_ref        VARCHAR(500),                  -- path/table for baseline distributions
    config              JSONB,                         -- type-specific thresholds and parameters
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255) NOT NULL,
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 2. monitoring_run
-- Tracks each monitoring execution, linked back to the scoring run it evaluates
CREATE TABLE monitoring_run (
    monitoring_run_id     SERIAL PRIMARY KEY,
    run_id                INTEGER REFERENCES ml_run_log(run_id) ON DELETE SET NULL,
    policy_id             INTEGER NOT NULL REFERENCES monitoring_policy(policy_id) ON DELETE CASCADE,
    deployment_id         INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    scoring_run_id        INTEGER REFERENCES ml_scoring_run(scoring_run_id) ON DELETE SET NULL,
    run_frequency         VARCHAR(50) NOT NULL CHECK (run_frequency IN ('daily', 'weekly', 'monthly', 'on_demand')),
    business_date         DATE NOT NULL,
    business_month        VARCHAR(7),                  -- 'YYYY-MM' for monthly runs
    run_status            VARCHAR(50) NOT NULL CHECK (run_status IN ('queued', 'running', 'completed', 'failed')),
    start_ts              TIMESTAMPTZ,
    end_ts                TIMESTAMPTZ,
    duration_seconds      INTEGER CHECK (duration_seconds >= 0),
    checks_total          INTEGER CHECK (checks_total >= 0),
    checks_passed         INTEGER CHECK (checks_passed >= 0),
    checks_failed         INTEGER CHECK (checks_failed >= 0),
    drift_detected        BOOLEAN DEFAULT FALSE,       -- summary flag
    performance_degraded  BOOLEAN DEFAULT FALSE,       -- summary flag
    alerts_triggered      INTEGER DEFAULT 0 CHECK (alerts_triggered >= 0),
    run_summary           JSONB,                       -- aggregated results
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_monitoring_run_ts_order CHECK (end_ts >= start_ts OR end_ts IS NULL OR start_ts IS NULL)
);

-- 3. data_drift_log
-- Per-feature statistical drift detection results
CREATE TABLE data_drift_log (
    drift_id            SERIAL PRIMARY KEY,
    monitoring_run_id   INTEGER NOT NULL REFERENCES monitoring_run(monitoring_run_id) ON DELETE CASCADE,
    policy_id           INTEGER NOT NULL REFERENCES monitoring_policy(policy_id) ON DELETE CASCADE,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    check_date          TIMESTAMPTZ NOT NULL,
    feature_name        VARCHAR(255) NOT NULL,
    drift_method        VARCHAR(100) NOT NULL CHECK (drift_method IN ('psi', 'ks_test', 'js_divergence', 'chi_squared', 'wasserstein')),
    drift_score         NUMERIC(10,6) CHECK (drift_score >= 0),
    drift_threshold     NUMERIC(10,6) CHECK (drift_threshold >= 0),
    drift_detected      BOOLEAN DEFAULT FALSE,
    baseline_stats      JSONB,                         -- mean, std, distribution bins at training time
    current_stats       JSONB,                         -- same stats for current window
    details             JSONB,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 4. concept_drift_log
-- Target/prediction distribution shift detection
CREATE TABLE concept_drift_log (
    concept_drift_id    SERIAL PRIMARY KEY,
    monitoring_run_id   INTEGER NOT NULL REFERENCES monitoring_run(monitoring_run_id) ON DELETE CASCADE,
    policy_id           INTEGER NOT NULL REFERENCES monitoring_policy(policy_id) ON DELETE CASCADE,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    check_date          TIMESTAMPTZ NOT NULL,
    detection_method    VARCHAR(100) NOT NULL CHECK (detection_method IN ('adwin', 'ddm', 'page_hinkley', 'eddm')),
    drift_score         NUMERIC(10,6) CHECK (drift_score >= 0),
    drift_threshold     NUMERIC(10,6) CHECK (drift_threshold >= 0),
    drift_detected      BOOLEAN DEFAULT FALSE,
    window_start        TIMESTAMPTZ,
    window_end          TIMESTAMPTZ,
    prediction_distribution JSONB,                     -- current prediction class/value distribution
    baseline_distribution   JSONB,                     -- expected distribution from training
    details             JSONB,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_concept_window_order CHECK (window_end >= window_start OR window_end IS NULL OR window_start IS NULL)
);

-- 5. model_performance_log
-- Periodic performance metric snapshots
CREATE TABLE model_performance_log (
    performance_id      SERIAL PRIMARY KEY,
    monitoring_run_id   INTEGER NOT NULL REFERENCES monitoring_run(monitoring_run_id) ON DELETE CASCADE,
    policy_id           INTEGER NOT NULL REFERENCES monitoring_policy(policy_id) ON DELETE CASCADE,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    check_date          TIMESTAMPTZ NOT NULL,
    metric_name         VARCHAR(100) NOT NULL,         -- accuracy, f1, precision, recall, rmse, mae, auc
    metric_value        NUMERIC(10,6),
    baseline_value      NUMERIC(10,6),                 -- value at training/registration time
    threshold_lower     NUMERIC(10,6),                 -- acceptable lower bound
    threshold_upper     NUMERIC(10,6),                 -- acceptable upper bound
    is_degraded         BOOLEAN DEFAULT FALSE,
    sample_size         INTEGER,                       -- number of labeled samples used
    evaluation_dataset  VARCHAR(500),                  -- path/table of ground truth used
    details             JSONB,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_threshold_order CHECK (threshold_upper >= threshold_lower OR threshold_upper IS NULL OR threshold_lower IS NULL)
);

-- 6. prediction_log
-- Stores prediction requests and outputs for audit and analysis
-- NOTE: Consider PARTITION BY RANGE (prediction_ts) for production at scale
CREATE TABLE prediction_log (
    prediction_id       BIGSERIAL PRIMARY KEY,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    prediction_ts       TIMESTAMPTZ NOT NULL,
    request_id          VARCHAR(255),                  -- correlation id for tracing
    input_features      JSONB,                         -- feature values sent to model
    prediction_output   JSONB,                         -- model output (class, probability, regression value)
    ground_truth        JSONB,                         -- actual label when available (joined later)
    ground_truth_ts     TIMESTAMPTZ,                   -- when ground truth was recorded
    latency_ms          INTEGER CHECK (latency_ms >= 0),
    model_version       INTEGER,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 7. data_quality_log
-- Input data quality checks for model scoring pipelines
CREATE TABLE data_quality_log (
    quality_id          SERIAL PRIMARY KEY,
    monitoring_run_id   INTEGER NOT NULL REFERENCES monitoring_run(monitoring_run_id) ON DELETE CASCADE,
    policy_id           INTEGER NOT NULL REFERENCES monitoring_policy(policy_id) ON DELETE CASCADE,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    check_date          TIMESTAMPTZ NOT NULL,
    check_type          VARCHAR(50) NOT NULL CHECK (check_type IN ('null_rate', 'outlier', 'schema_mismatch', 'volume', 'freshness')),
    feature_name        VARCHAR(255),                  -- null for table-level checks
    check_value         NUMERIC(10,6) CHECK (check_value >= 0),
    threshold_value     NUMERIC(10,6),
    is_failed           BOOLEAN DEFAULT FALSE,
    record_count        INTEGER,
    details             JSONB,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 8. alert_rule
-- Configurable alerting rules tied to monitoring policies
CREATE TABLE alert_rule (
    rule_id             SERIAL PRIMARY KEY,
    policy_id           INTEGER NOT NULL REFERENCES monitoring_policy(policy_id) ON DELETE CASCADE,
    rule_name           VARCHAR(255) NOT NULL,
    condition_type      VARCHAR(50) NOT NULL CHECK (condition_type IN ('threshold', 'consecutive_failures', 'trend', 'anomaly')),
    condition_config    JSONB NOT NULL,                -- metric, operator, value, window, count
    severity            VARCHAR(20) NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    notification_channel VARCHAR(50) CHECK (notification_channel IN ('email', 'slack', 'pagerduty', 'teams')),
    notification_target VARCHAR(500),                  -- email address, channel, webhook URL
    cooldown_minutes    INTEGER DEFAULT 60 CHECK (cooldown_minutes > 0),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255) NOT NULL,
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 9. alert_history
-- Log of all triggered alerts
CREATE TABLE alert_history (
    alert_id            SERIAL PRIMARY KEY,
    rule_id             INTEGER NOT NULL REFERENCES alert_rule(rule_id) ON DELETE CASCADE,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    triggered_date      TIMESTAMPTZ NOT NULL,
    severity            VARCHAR(20) NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    alert_summary       VARCHAR(500),
    alert_details       JSONB,                         -- full context: metric values, thresholds, affected features
    notification_sent   BOOLEAN DEFAULT FALSE,
    acknowledged        BOOLEAN DEFAULT FALSE,
    acknowledged_by     VARCHAR(255),
    acknowledged_date   TIMESTAMPTZ,
    resolved            BOOLEAN DEFAULT FALSE,
    resolved_date       TIMESTAMPTZ,
    resolution_notes    TEXT,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 10. retraining_trigger
-- Defines conditions under which a model should be retrained
CREATE TABLE retraining_trigger (
    trigger_id          SERIAL PRIMARY KEY,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    pipeline_id         INTEGER REFERENCES ml_pipeline_config(pipeline_id) ON DELETE RESTRICT,
    trigger_type        VARCHAR(50) NOT NULL CHECK (trigger_type IN ('drift_threshold', 'performance_decay', 'scheduled', 'manual')),
    trigger_config      JSONB NOT NULL,                -- conditions: metric thresholds, consecutive checks, etc.
    auto_retrain        BOOLEAN DEFAULT FALSE,         -- if true, kicks off pipeline automatically
    approval_required   BOOLEAN DEFAULT TRUE,          -- gate before auto-retrain in production
    last_triggered_date TIMESTAMPTZ,
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255) NOT NULL,
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 11. retraining_history
-- Log of all retraining events triggered by monitoring
CREATE TABLE retraining_history (
    retraining_id       SERIAL PRIMARY KEY,
    trigger_id          INTEGER NOT NULL REFERENCES retraining_trigger(trigger_id) ON DELETE CASCADE,
    deployment_id       INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE RESTRICT,
    triggered_date      TIMESTAMPTZ NOT NULL,
    trigger_reason      TEXT,                          -- human-readable cause
    trigger_metrics     JSONB,                         -- snapshot of metrics that caused the trigger
    pipeline_run_id     VARCHAR(255),                  -- airflow run id
    new_model_id        INTEGER REFERENCES ml_model_registry(model_id) ON DELETE SET NULL,
    retrain_status      VARCHAR(50) NOT NULL CHECK (retrain_status IN ('triggered', 'running', 'completed', 'failed', 'cancelled')),
    approved_by         VARCHAR(255),
    approved_date       TIMESTAMPTZ,
    completed_date      TIMESTAMPTZ,
    notes               TEXT,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 12. sla_definition
-- SLA targets for pipelines and scoring
CREATE TABLE sla_definition (
    sla_id                SERIAL PRIMARY KEY,
    entity_type           VARCHAR(50) NOT NULL CHECK (entity_type IN ('pipeline', 'report', 'feed', 'scoring', 'monitoring')),
    entity_id             INTEGER NOT NULL,
    environment_id        INTEGER NOT NULL REFERENCES environment_config(environment_id) ON DELETE RESTRICT,
    sla_type              VARCHAR(50) NOT NULL CHECK (sla_type IN ('completion_time', 'duration', 'freshness')),
    expected_completion_time TIME,                     -- e.g., 06:00:00 for "must complete by 6 AM"
    expected_completion_tz VARCHAR(50) DEFAULT 'UTC',
    max_duration_minutes  INTEGER CHECK (max_duration_minutes > 0),
    business_calendar     VARCHAR(50) DEFAULT 'calendar_days' CHECK (business_calendar IN ('business_days', 'calendar_days')),
    severity_if_breached  VARCHAR(20) NOT NULL CHECK (severity_if_breached IN ('info', 'warning', 'critical')),
    notification_channel  VARCHAR(50) CHECK (notification_channel IN ('email', 'slack', 'pagerduty', 'teams')),
    notification_target   VARCHAR(500),
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255) NOT NULL,
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255),
    UNIQUE (entity_type, entity_id, environment_id, sla_type)
);

-- 13. sla_breach_log
-- Actual SLA breaches
CREATE TABLE sla_breach_log (
    breach_id             SERIAL PRIMARY KEY,
    sla_id                INTEGER NOT NULL REFERENCES sla_definition(sla_id) ON DELETE CASCADE,
    run_id                INTEGER REFERENCES ml_run_log(run_id) ON DELETE SET NULL,
    breach_date           DATE NOT NULL,
    expected_value        VARCHAR(100),                -- e.g., "06:00:00" or "120 min"
    actual_value          VARCHAR(100),                -- e.g., "07:23:00" or "185 min"
    breach_duration_minutes INTEGER CHECK (breach_duration_minutes >= 0),
    business_impact       TEXT,
    resolution_notes      TEXT,
    acknowledged_by       VARCHAR(255),
    acknowledged_date     TIMESTAMPTZ,
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- INDEXES for high-volume tables
-- ============================================================

-- prediction_log: highest-volume table, queries always filter by deployment + time
CREATE INDEX idx_prediction_log_deploy_ts ON prediction_log (deployment_id, prediction_ts);
CREATE INDEX idx_prediction_log_request ON prediction_log (request_id);

-- monitoring_run: queried by deployment + date
CREATE INDEX idx_monitoring_run_deploy_date ON monitoring_run (deployment_id, business_date);

-- data_drift_log: queried by deployment + date and by monitoring run
CREATE INDEX idx_data_drift_deploy_date ON data_drift_log (deployment_id, check_date);
CREATE INDEX idx_data_drift_monrun ON data_drift_log (monitoring_run_id);

-- concept_drift_log
CREATE INDEX idx_concept_drift_deploy_date ON concept_drift_log (deployment_id, check_date);

-- model_performance_log
CREATE INDEX idx_perf_log_deploy_date ON model_performance_log (deployment_id, check_date);

-- data_quality_log
CREATE INDEX idx_quality_log_deploy_date ON data_quality_log (deployment_id, check_date);

-- alert_history: queried by deployment + date, by rule
CREATE INDEX idx_alert_hist_deploy_date ON alert_history (deployment_id, triggered_date);
CREATE INDEX idx_alert_hist_rule ON alert_history (rule_id, triggered_date);

-- sla_breach_log
CREATE INDEX idx_sla_breach_date ON sla_breach_log (sla_id, breach_date);

-- Additional FK indexes
CREATE INDEX idx_monitoring_policy_deployment ON monitoring_policy(deployment_id);
CREATE INDEX idx_monitoring_run_policy ON monitoring_run(policy_id);
CREATE INDEX idx_monitoring_run_scoring ON monitoring_run(scoring_run_id);
CREATE INDEX idx_monitoring_run_run ON monitoring_run(run_id);
CREATE INDEX idx_data_drift_policy ON data_drift_log(policy_id);
CREATE INDEX idx_concept_drift_monrun ON concept_drift_log(monitoring_run_id);
CREATE INDEX idx_concept_drift_policy ON concept_drift_log(policy_id);
CREATE INDEX idx_perf_log_monrun ON model_performance_log(monitoring_run_id);
CREATE INDEX idx_perf_log_policy ON model_performance_log(policy_id);
CREATE INDEX idx_quality_log_monrun ON data_quality_log(monitoring_run_id);
CREATE INDEX idx_quality_log_policy ON data_quality_log(policy_id);
CREATE INDEX idx_alert_rule_policy ON alert_rule(policy_id);
CREATE INDEX idx_retrain_trigger_deployment ON retraining_trigger(deployment_id);
CREATE INDEX idx_retrain_trigger_pipeline ON retraining_trigger(pipeline_id);
CREATE INDEX idx_retrain_hist_deployment ON retraining_history(deployment_id);
CREATE INDEX idx_retrain_hist_trigger ON retraining_history(trigger_id);
CREATE INDEX idx_retrain_hist_model ON retraining_history(new_model_id);
CREATE INDEX idx_sla_breach_run ON sla_breach_log(run_id);

-- Query pattern indexes
CREATE INDEX idx_alert_hist_unresolved ON alert_history(deployment_id, severity) WHERE resolved = FALSE;
CREATE INDEX idx_monitoring_run_status ON monitoring_run(run_status) WHERE run_status IN ('running', 'failed');
CREATE INDEX idx_retrain_hist_status ON retraining_history(retrain_status) WHERE retrain_status IN ('triggered', 'running');
