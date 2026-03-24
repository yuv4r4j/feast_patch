-- ============================================================
-- PostgreSQL DDL — Analytics Reporting Workflow
-- Prerequisite: shared_infra_schema.sql (environment_config, compute_cluster_config)
-- Scheduled via Airflow · PySpark + Snowpark
-- ============================================================

-- 1. report_group
-- Logical grouping of related reports (e.g., Finance Dashboards, Operations KPIs)
CREATE TABLE report_group (
    report_group_id     SERIAL PRIMARY KEY,
    group_name          VARCHAR(255) NOT NULL,
    business_domain     VARCHAR(255),
    owner_email         VARCHAR(255),
    description         VARCHAR(500),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (group_name)
);

-- 2. report_catalog
-- Registry of individual reports/dashboards/datasets
CREATE TABLE report_catalog (
    report_id           SERIAL PRIMARY KEY,
    report_group_id     INTEGER REFERENCES report_group(report_group_id) ON DELETE SET NULL,
    report_name         VARCHAR(255) NOT NULL,
    report_type         VARCHAR(50) NOT NULL CHECK (report_type IN ('dashboard', 'dataset', 'kpi', 'adhoc')),
    compute_type        VARCHAR(50) NOT NULL CHECK (compute_type IN ('pyspark', 'snowpark')),
    script_path         VARCHAR(500),                  -- path to .py script in repo
    entry_class         VARCHAR(255),                  -- main class or function name
    output_format       VARCHAR(50) NOT NULL CHECK (output_format IN ('table', 'view', 'parquet', 'csv', 'delta')),
    output_schema       VARCHAR(255),                  -- target schema/database
    output_table        VARCHAR(255),                  -- target table/view name
    output_path         VARCHAR(500),                  -- output file path if file-based
    description         VARCHAR(500),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (report_group_id, report_name)
);

-- 3. report_schedule
-- Airflow DAG scheduling configuration for reports
CREATE TABLE report_schedule (
    schedule_id         SERIAL PRIMARY KEY,
    report_id           INTEGER NOT NULL REFERENCES report_catalog(report_id) ON DELETE CASCADE,
    environment_id      INTEGER NOT NULL REFERENCES environment_config(environment_id) ON DELETE RESTRICT,
    cluster_id          INTEGER REFERENCES compute_cluster_config(cluster_id) ON DELETE SET NULL,
    dag_id              VARCHAR(255) NOT NULL,
    cron_expression     VARCHAR(100),                  -- airflow cron schedule
    schedule_type       VARCHAR(50) NOT NULL CHECK (schedule_type IN ('daily', 'weekly', 'monthly', 'event_driven')),
    start_date          TIMESTAMPTZ,
    end_date            TIMESTAMPTZ,
    timeout_minutes     INTEGER DEFAULT 120 CHECK (timeout_minutes > 0),
    retry_count         INTEGER DEFAULT 2 CHECK (retry_count >= 0),
    retry_delay_minutes INTEGER DEFAULT 5 CHECK (retry_delay_minutes > 0),
    dag_parameters      JSONB,                         -- extra airflow params
    notification_email  VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (report_id, environment_id),
    CONSTRAINT chk_cron_required CHECK (schedule_type = 'event_driven' OR cron_expression IS NOT NULL)
);

-- 4. report_data_source
-- Maps reports to their upstream data sources
CREATE TABLE report_data_source (
    report_id           INTEGER NOT NULL REFERENCES report_catalog(report_id) ON DELETE CASCADE,
    source_type         VARCHAR(50) NOT NULL CHECK (source_type IN ('table', 'view', 'feed', 'external')),
    source_schema       VARCHAR(255),
    source_table        VARCHAR(255),
    source_path         VARCHAR(500),
    feed_id             INTEGER,  -- FK to ingestion schema.feed_details(feed_id) if source_type='feed'
    zone                VARCHAR(50) CHECK (zone IN ('raw', 'refined', 'trusted', 'consumption')),
    description         VARCHAR(255),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    source_key          VARCHAR(255) NOT NULL DEFAULT '',  -- derived: source_table or source_path; DEFAULT '' allows composite PK rows with no natural source_key
    PRIMARY KEY (report_id, source_type, source_key)
);

-- 5. report_dependency
-- DAG dependencies between reports (must complete before downstream runs)
CREATE TABLE report_dependency (
    report_id           INTEGER NOT NULL REFERENCES report_catalog(report_id) ON DELETE CASCADE,
    depends_on_report_id INTEGER NOT NULL REFERENCES report_catalog(report_id) ON DELETE CASCADE,
    dependency_type     VARCHAR(50) DEFAULT 'hard' CHECK (dependency_type IN ('hard', 'soft')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (report_id, depends_on_report_id),
    CHECK (report_id <> depends_on_report_id)
);

-- 6. report_quality_check
-- Data quality validation rules for report outputs
CREATE TABLE report_quality_check (
    check_id            SERIAL PRIMARY KEY,
    report_id           INTEGER NOT NULL REFERENCES report_catalog(report_id) ON DELETE CASCADE,
    check_name          VARCHAR(255) NOT NULL,
    check_type          VARCHAR(50) NOT NULL CHECK (check_type IN ('row_count', 'null_check', 'freshness', 'custom_sql')),
    check_expression    TEXT,                          -- SQL or expression to evaluate
    threshold_value     NUMERIC CHECK (threshold_value >= 0),
    severity            VARCHAR(20) DEFAULT 'warning' CHECK (severity IN ('warning', 'error', 'critical')),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_report_schedule_env ON report_schedule (environment_id);
CREATE INDEX idx_report_data_source_zone ON report_data_source (zone);

-- Foreign key indexes
CREATE INDEX idx_report_catalog_group ON report_catalog(report_group_id);
CREATE INDEX idx_report_schedule_report ON report_schedule(report_id);
CREATE INDEX idx_report_schedule_cluster ON report_schedule(cluster_id);
CREATE INDEX idx_report_dependency_upstream ON report_dependency(depends_on_report_id);
CREATE INDEX idx_report_quality_check_report ON report_quality_check(report_id);
CREATE INDEX idx_report_data_source_feed ON report_data_source(feed_id);
