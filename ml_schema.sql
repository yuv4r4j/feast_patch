-- ============================================================
-- PostgreSQL DDL — Machine Learning Workflow (17 tables)
-- Prerequisite: shared_infra_schema.sql (environment_config, compute_cluster_config)
-- Downstream: monitoring_schema.sql depends on ml_model_deployment, ml_scoring_run, ml_run_log
-- Scheduled via Airflow · PySpark + Snowpark
-- ============================================================

-- 1. ml_project
-- Top-level ML project definitions
CREATE TABLE ml_project (
    project_id          SERIAL PRIMARY KEY,
    project_name        VARCHAR(255) NOT NULL,
    business_domain     VARCHAR(255),
    objective           TEXT,                          -- business objective of the ML project
    owner_email         VARCHAR(255),
    team_email          VARCHAR(255),
    repo_url            VARCHAR(500),                  -- git repo for the ML code
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 2. ml_feature_store
-- Feature definitions used across ML models
CREATE TABLE ml_feature_store (
    feature_id          SERIAL PRIMARY KEY,
    project_id          INTEGER REFERENCES ml_project(project_id) ON DELETE SET NULL,
    feature_name        VARCHAR(255) NOT NULL,
    feature_group       VARCHAR(255),                  -- logical grouping of features
    compute_type        VARCHAR(50) NOT NULL CHECK (compute_type IN ('pyspark', 'snowpark')),
    source_query        TEXT,                          -- SQL or transformation logic
    source_table        VARCHAR(255),
    output_table        VARCHAR(255),                  -- materialized feature table
    data_type           VARCHAR(50),
    feature_description VARCHAR(500),
    refresh_frequency   VARCHAR(50),                   -- daily, hourly, realtime
    feature_source_type VARCHAR(50) DEFAULT 'in_house' CHECK (feature_source_type IN ('in_house', 'bureau')),
    bureau_name         VARCHAR(255),                  -- Experian, TransUnion, Equifax; NULL for in_house
    bureau_product_code VARCHAR(100),                  -- bureau product/report identifier
    bureau_version      VARCHAR(50),                   -- bureau data version or vintage
    bureau_metadata     JSONB,                         -- contract ref, SLA, update lag, field mapping
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    CONSTRAINT chk_bureau_fields CHECK (
        (feature_source_type = 'bureau' AND bureau_name IS NOT NULL)
        OR (feature_source_type = 'in_house')
    )
);

-- 3. ml_experiment
-- Experiment tracking for model training runs
CREATE TABLE ml_experiment (
    experiment_id       SERIAL PRIMARY KEY,
    project_id          INTEGER NOT NULL REFERENCES ml_project(project_id) ON DELETE CASCADE,
    experiment_name     VARCHAR(255) NOT NULL,
    compute_type        VARCHAR(50) NOT NULL CHECK (compute_type IN ('pyspark', 'snowpark')),
    script_path         VARCHAR(500),
    hyperparameters     JSONB,
    metrics             JSONB,                         -- accuracy, f1, rmse, etc.
    training_data_ref   VARCHAR(500),                  -- path or table used for training
    artifact_path       VARCHAR(500),                  -- model artifact storage path
    run_status          VARCHAR(50) CHECK (run_status IN ('pending', 'running', 'completed', 'failed')),
    run_date            TIMESTAMPTZ,
    duration_seconds    INTEGER,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 4. ml_model_registry
-- Versioned model registry with promotion tracking across environments
CREATE TABLE ml_model_registry (
    model_id            SERIAL PRIMARY KEY,
    project_id          INTEGER NOT NULL REFERENCES ml_project(project_id) ON DELETE RESTRICT,
    experiment_id       INTEGER REFERENCES ml_experiment(experiment_id) ON DELETE SET NULL,
    model_name          VARCHAR(255) NOT NULL,
    model_version       INTEGER NOT NULL,
    model_framework     VARCHAR(100),                  -- sklearn, xgboost, pytorch, snowml
    artifact_path       VARCHAR(500),
    model_stage         VARCHAR(50) NOT NULL CHECK (model_stage IN ('development', 'staging', 'production', 'archived')),
    promoted_from_env   VARCHAR(50),                   -- which SDLC env promoted it
    approval_status     VARCHAR(50) DEFAULT 'pending' CHECK (approval_status IN ('pending', 'approved', 'rejected')),
    approved_by         VARCHAR(255),
    approved_date       TIMESTAMPTZ,
    metrics_snapshot    JSONB,                         -- frozen metrics at registration time
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (model_name, model_version)
);

-- 5. ml_model_dependency
-- Model chaining: defines directed edges in the model dependency DAG
-- Model A's output becomes Model B's input
CREATE TABLE ml_model_dependency (
    model_id              INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE CASCADE,
    depends_on_model_id   INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE CASCADE,
    dependency_type       VARCHAR(50) DEFAULT 'output_as_input' CHECK (dependency_type IN ('output_as_input', 'feature_feed', 'ensemble')),
    output_column_mapping JSONB,                       -- maps upstream output cols to downstream input features
    execution_order       INTEGER,                     -- ordering hint within a chain
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255),
    PRIMARY KEY (model_id, depends_on_model_id),
    CHECK (model_id <> depends_on_model_id)
);

-- 6. ml_feature_model_map
-- Explicit mapping of which features each model consumes
CREATE TABLE ml_feature_model_map (
    model_id              INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE CASCADE,
    feature_id            INTEGER NOT NULL REFERENCES ml_feature_store(feature_id) ON DELETE RESTRICT,
    feature_role          VARCHAR(50) DEFAULT 'input' CHECK (feature_role IN ('input', 'target', 'auxiliary')),
    is_required           BOOLEAN DEFAULT TRUE,
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    PRIMARY KEY (model_id, feature_id)
);

-- 7. ml_pipeline_config
-- Airflow-scheduled ML pipeline definitions (training, scoring, retraining)
CREATE TABLE ml_pipeline_config (
    pipeline_id         SERIAL PRIMARY KEY,
    project_id          INTEGER NOT NULL REFERENCES ml_project(project_id) ON DELETE RESTRICT,
    model_id            INTEGER REFERENCES ml_model_registry(model_id) ON DELETE SET NULL,
    pipeline_name       VARCHAR(255) NOT NULL,
    pipeline_type       VARCHAR(50) NOT NULL CHECK (pipeline_type IN ('training', 'scoring', 'retraining', 'feature_refresh')),
    compute_type        VARCHAR(50) NOT NULL CHECK (compute_type IN ('pyspark', 'snowpark')),
    script_path         VARCHAR(500),
    entry_class         VARCHAR(255),
    input_config        JSONB,                         -- input tables, paths, feature refs
    output_config       JSONB,                         -- output tables, prediction paths
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 8. ml_pipeline_schedule
-- Airflow scheduling for ML pipelines per environment
CREATE TABLE ml_pipeline_schedule (
    schedule_id         SERIAL PRIMARY KEY,
    pipeline_id         INTEGER NOT NULL REFERENCES ml_pipeline_config(pipeline_id) ON DELETE CASCADE,
    environment_id      INTEGER NOT NULL REFERENCES environment_config(environment_id) ON DELETE RESTRICT,
    cluster_id          INTEGER REFERENCES compute_cluster_config(cluster_id) ON DELETE SET NULL,
    dag_id              VARCHAR(255) NOT NULL,
    cron_expression     VARCHAR(100),
    schedule_type       VARCHAR(50) CHECK (schedule_type IN ('daily', 'weekly', 'monthly', 'on_demand', 'event_driven')),
    timeout_minutes     INTEGER DEFAULT 180,
    retry_count         INTEGER DEFAULT 1,
    retry_delay_minutes INTEGER DEFAULT 10,
    dag_parameters      JSONB,
    notification_email  VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (pipeline_id, environment_id)
);

-- 9. ml_model_deployment
-- Tracks which model version is deployed in each environment
CREATE TABLE ml_model_deployment (
    deployment_id       SERIAL PRIMARY KEY,
    model_id            INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE RESTRICT,
    environment_id      INTEGER NOT NULL REFERENCES environment_config(environment_id) ON DELETE RESTRICT,
    deployment_status   VARCHAR(50) NOT NULL CHECK (deployment_status IN ('deploying', 'active', 'rolled_back', 'decommissioned')),
    endpoint_url        VARCHAR(500),                  -- scoring endpoint if real-time
    batch_output_table  VARCHAR(255),                  -- output table if batch scoring
    deployed_date       TIMESTAMPTZ,
    deployed_by         VARCHAR(255) NOT NULL,
    rollback_model_id   INTEGER REFERENCES ml_model_registry(model_id) ON DELETE SET NULL,
    monitoring_config   JSONB,                         -- drift detection, alerting thresholds
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (model_id, environment_id)
);

-- 10. ml_scoring_config
-- Detailed scoring configuration per deployment (batch or realtime)
CREATE TABLE ml_scoring_config (
    scoring_config_id     SERIAL PRIMARY KEY,
    deployment_id         INTEGER NOT NULL REFERENCES ml_model_deployment(deployment_id) ON DELETE CASCADE,
    scoring_type          VARCHAR(50) NOT NULL CHECK (scoring_type IN ('batch', 'realtime', 'mini_batch')),
    scoring_frequency     VARCHAR(50) NOT NULL CHECK (scoring_frequency IN ('daily', 'monthly', 'weekly', 'on_demand')),
    input_table           VARCHAR(255),                -- source table for batch scoring
    input_query           TEXT,                        -- optional SQL to select scoring population
    output_table          VARCHAR(255),                -- scored output destination
    output_format         VARCHAR(50) CHECK (output_format IN ('table', 'parquet', 'delta', 'csv')),
    score_column_name     VARCHAR(255),                -- primary score column name in output
    threshold_config      JSONB,                       -- decision thresholds: {"cutoff": 0.5, "bands": [...]}
    population_filter     TEXT,                        -- SQL WHERE clause to filter scoring population
    feature_snapshot      BOOLEAN DEFAULT TRUE,        -- snapshot input features alongside scores
    pre_scoring_checks    JSONB,                       -- data quality gates before scoring runs
    post_scoring_actions  JSONB,                       -- actions after scoring: notify, trigger downstream
    partition_columns     VARCHAR(500),                -- columns to partition output by
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255)
);

-- 11. ml_run_log
-- Unified run tracking for all ML pipeline types (training, scoring, retraining, monitoring)
-- Supports daily and monthly frequency via business_date + business_month
CREATE TABLE ml_run_log (
    run_id                SERIAL PRIMARY KEY,
    pipeline_id           INTEGER REFERENCES ml_pipeline_config(pipeline_id) ON DELETE SET NULL,
    schedule_id           INTEGER REFERENCES ml_pipeline_schedule(schedule_id) ON DELETE SET NULL,
    run_type              VARCHAR(50) NOT NULL CHECK (run_type IN ('training', 'scoring', 'retraining', 'feature_refresh', 'monitoring')),
    run_frequency         VARCHAR(50) NOT NULL CHECK (run_frequency IN ('daily', 'monthly', 'weekly', 'on_demand')),
    business_date         DATE NOT NULL,               -- logical business date this run covers
    business_month        VARCHAR(7),                  -- 'YYYY-MM' for monthly runs; NULL for daily
    dag_run_id            VARCHAR(255),                -- Airflow DAG run ID for traceability
    environment_id        INTEGER REFERENCES environment_config(environment_id) ON DELETE SET NULL,
    run_status            VARCHAR(50) NOT NULL CHECK (run_status IN ('queued', 'running', 'completed', 'failed', 'skipped')),
    start_ts              TIMESTAMPTZ,
    end_ts                TIMESTAMPTZ,
    duration_seconds      INTEGER,
    records_processed     BIGINT,
    records_scored        BIGINT,                      -- specific to scoring runs
    records_failed        BIGINT,
    error_message         TEXT,
    run_metadata          JSONB,                       -- spark app id, cluster info, memory usage
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CHECK (business_month ~ '^\d{4}-(0[1-9]|1[0-2])$' OR business_month IS NULL)
);

-- 12. ml_scoring_run
-- Per-execution scoring detail, linked to ml_run_log (header/detail pattern)
CREATE TABLE ml_scoring_run (
    scoring_run_id        SERIAL PRIMARY KEY,
    run_id                INTEGER NOT NULL REFERENCES ml_run_log(run_id) ON DELETE CASCADE,
    scoring_config_id     INTEGER NOT NULL REFERENCES ml_scoring_config(scoring_config_id) ON DELETE RESTRICT,
    model_id              INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE RESTRICT,
    model_version         INTEGER NOT NULL,
    input_row_count       BIGINT,
    scored_row_count      BIGINT,
    rejected_row_count    BIGINT,
    score_distribution    JSONB,                       -- histogram/percentile summary of scores
    threshold_applied     NUMERIC(10,6),               -- decision threshold used for this run
    positive_rate         NUMERIC(7,6) CHECK (positive_rate >= 0 AND positive_rate <= 1),
    output_table          VARCHAR(255),                -- actual output table written
    output_path           VARCHAR(500),                -- actual output path written
    feature_snapshot_path VARCHAR(500),                -- path to snapshotted input features
    upstream_scoring_run_id INTEGER REFERENCES ml_scoring_run(scoring_run_id) ON DELETE SET NULL, -- for model chaining
    quality_check_passed  BOOLEAN DEFAULT TRUE,        -- did pre-scoring checks pass?
    quality_check_details JSONB,                       -- detailed pre-scoring check results
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 13. ml_model_governance
-- SR 11-7 model risk management
CREATE TABLE ml_model_governance (
    governance_id         SERIAL PRIMARY KEY,
    model_id              INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE RESTRICT,
    model_risk_tier       VARCHAR(50) NOT NULL CHECK (model_risk_tier IN ('critical', 'high', 'medium', 'low')),
    model_use_case        VARCHAR(100) NOT NULL,       -- credit_decisioning, fraud_detection, pricing, AML, collections
    regulatory_framework  VARCHAR(100),                -- SR_11_7, ECOA, FCRA, BSA_AML
    validation_status     VARCHAR(50) NOT NULL DEFAULT 'pending' CHECK (validation_status IN ('pending', 'in_progress', 'validated', 'conditionally_approved', 'rejected')),
    last_validation_date  TIMESTAMPTZ,
    next_validation_due   DATE,
    independent_reviewer  VARCHAR(255),
    model_owner           VARCHAR(255) NOT NULL,
    model_developer       VARCHAR(255) NOT NULL,
    effective_date        DATE,
    sunset_date           DATE,
    documentation_path    VARCHAR(500),
    findings_count        INTEGER NOT NULL DEFAULT 0,
    open_findings_count   INTEGER NOT NULL DEFAULT 0,
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255),
    UNIQUE (model_id)
);

-- 14. ml_validation_finding
-- Regulatory validation findings
CREATE TABLE ml_validation_finding (
    finding_id            SERIAL PRIMARY KEY,
    governance_id         INTEGER NOT NULL REFERENCES ml_model_governance(governance_id) ON DELETE CASCADE,
    finding_type          VARCHAR(50) NOT NULL CHECK (finding_type IN ('conceptual_soundness', 'outcome_analysis', 'process_verification')),
    severity              VARCHAR(20) NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
    finding_description   TEXT NOT NULL,
    remediation_plan      TEXT,
    remediation_owner     VARCHAR(255),
    due_date              DATE,
    status                VARCHAR(50) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_remediation', 'closed', 'accepted')),
    closed_date           TIMESTAMPTZ,
    evidence_path         VARCHAR(500),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255)
);

-- 15. ml_approval_workflow
-- Multi-stage sign-off
CREATE TABLE ml_approval_workflow (
    approval_id           SERIAL PRIMARY KEY,
    model_id              INTEGER NOT NULL REFERENCES ml_model_registry(model_id) ON DELETE RESTRICT,
    approval_stage        VARCHAR(50) NOT NULL CHECK (approval_stage IN ('dev_signoff', 'validation_signoff', 'business_signoff', 'risk_committee', 'deployment_approval')),
    approver_role         VARCHAR(100) NOT NULL,       -- model_developer, model_validator, business_owner, risk_officer, cro
    approver_name         VARCHAR(255),
    approval_status       VARCHAR(50) NOT NULL DEFAULT 'pending' CHECK (approval_status IN ('pending', 'approved', 'rejected', 'conditional')),
    conditions            TEXT,
    approval_date         TIMESTAMPTZ,
    expiry_date           DATE,
    comments              TEXT,
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255)
);

-- 16. ml_feature_version
-- Immutable feature snapshots for reproducibility
CREATE TABLE ml_feature_version (
    feature_version_id    SERIAL PRIMARY KEY,
    feature_id            INTEGER NOT NULL REFERENCES ml_feature_store(feature_id) ON DELETE CASCADE,
    version_number        INTEGER NOT NULL,
    source_query_hash     VARCHAR(64),                 -- SHA-256 hash of transformation SQL
    source_data_version   VARCHAR(255),                -- business_date or snapshot timestamp
    snapshot_path         VARCHAR(500),
    snapshot_table        VARCHAR(255),
    row_count             BIGINT,
    schema_hash           VARCHAR(64),                 -- hash of output schema for drift detection
    is_immutable          BOOLEAN DEFAULT TRUE,
    valid_from            TIMESTAMPTZ NOT NULL,
    valid_to              TIMESTAMPTZ,
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    UNIQUE (feature_id, version_number)
);

-- 17. ml_scoring_feature_version
-- Links scoring runs to exact feature versions used
CREATE TABLE ml_scoring_feature_version (
    scoring_run_id        INTEGER NOT NULL REFERENCES ml_scoring_run(scoring_run_id) ON DELETE CASCADE,
    feature_version_id    INTEGER NOT NULL REFERENCES ml_feature_version(feature_version_id) ON DELETE RESTRICT,
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (scoring_run_id, feature_version_id)
);

-- ============================================================
-- INDEXES for high-volume tables
-- ============================================================

-- ml_run_log: queried by pipeline + date, environment + status
CREATE INDEX idx_run_log_pipeline_date ON ml_run_log (pipeline_id, business_date);
CREATE INDEX idx_run_log_env_status ON ml_run_log (environment_id, run_status);
CREATE INDEX idx_run_log_date_type ON ml_run_log (business_date, run_type);

-- ml_scoring_run: queried by model + date, and by run_id
CREATE INDEX idx_scoring_run_model ON ml_scoring_run (model_id, created_date);
CREATE INDEX idx_scoring_run_run ON ml_scoring_run (run_id);

-- ml_approval_workflow: queried by model + stage
CREATE INDEX idx_approval_model_stage ON ml_approval_workflow (model_id, approval_stage);

-- ml_validation_finding: queried by governance + status
CREATE INDEX idx_finding_governance ON ml_validation_finding (governance_id, status);

-- ============================================================
-- Additional FK indexes
-- ============================================================
CREATE INDEX idx_feature_store_project ON ml_feature_store(project_id);
CREATE INDEX idx_experiment_project ON ml_experiment(project_id);
CREATE INDEX idx_model_registry_project ON ml_model_registry(project_id);
CREATE INDEX idx_model_registry_experiment ON ml_model_registry(experiment_id);
CREATE INDEX idx_model_dep_depends_on ON ml_model_dependency(depends_on_model_id);
CREATE INDEX idx_feature_model_map_feature ON ml_feature_model_map(feature_id);
CREATE INDEX idx_pipeline_config_project ON ml_pipeline_config(project_id);
CREATE INDEX idx_pipeline_config_model ON ml_pipeline_config(model_id);
CREATE INDEX idx_pipeline_schedule_pipeline ON ml_pipeline_schedule(pipeline_id);
CREATE INDEX idx_pipeline_schedule_env ON ml_pipeline_schedule(environment_id);
CREATE INDEX idx_pipeline_schedule_cluster ON ml_pipeline_schedule(cluster_id);
CREATE INDEX idx_model_deployment_model ON ml_model_deployment(model_id);
CREATE INDEX idx_model_deployment_env ON ml_model_deployment(environment_id);
CREATE INDEX idx_model_deployment_rollback ON ml_model_deployment(rollback_model_id);
CREATE INDEX idx_scoring_config_deployment ON ml_scoring_config(deployment_id);
CREATE INDEX idx_run_log_schedule ON ml_run_log(schedule_id);
CREATE INDEX idx_run_log_env ON ml_run_log(environment_id);
CREATE INDEX idx_scoring_run_scoring_config ON ml_scoring_run(scoring_config_id);
CREATE INDEX idx_scoring_run_upstream ON ml_scoring_run(upstream_scoring_run_id);
CREATE INDEX idx_governance_model ON ml_model_governance(model_id);
CREATE INDEX idx_feature_version_feature ON ml_feature_version(feature_id);
CREATE INDEX idx_scoring_fv_feature_version ON ml_scoring_feature_version(feature_version_id);

-- Query pattern indexes
CREATE INDEX idx_model_registry_stage ON ml_model_registry(model_stage) WHERE is_active = 'Y';
CREATE INDEX idx_feature_store_source_type ON ml_feature_store(feature_source_type) WHERE is_active = 'Y';
CREATE INDEX idx_model_deployment_status ON ml_model_deployment(deployment_status);
CREATE INDEX idx_governance_validation_status ON ml_model_governance(validation_status) WHERE is_active = 'Y';
CREATE INDEX idx_finding_status ON ml_validation_finding(status);
CREATE INDEX idx_approval_status ON ml_approval_workflow(approval_status);
CREATE INDEX idx_run_log_business_month ON ml_run_log(business_month) WHERE business_month IS NOT NULL;
CREATE INDEX idx_feature_version_validity ON ml_feature_version(feature_id, valid_from, valid_to);

-- NOTE: Model monitoring tables are in monitoring_schema.sql (depends on this file)
