-- ============================================================
-- PostgreSQL DDL — Shared Infrastructure (7 tables)
-- Covers: infrastructure, lineage, classification, audit, and retention
-- Must be applied BEFORE analytics_schema.sql and ml_schema.sql
-- ============================================================

-- 1. environment_config
-- Maps SDLC environments (dev/sit/uat/prod) to deployment layers (development/staging/production)
CREATE TABLE environment_config (
    environment_id      SERIAL PRIMARY KEY,
    environment_name    VARCHAR(50) NOT NULL,          -- dev, sit, uat, prod
    deployment_layer    VARCHAR(50) NOT NULL,          -- development, staging, production
    warehouse_type      VARCHAR(50) NOT NULL,          -- snowflake, spark, both
    connection_details  JSONB,                         -- host, port, credentials ref, catalog
    storage_root_path   VARCHAR(500),                  -- s3/adls/gcs base path per env
    snowflake_account   VARCHAR(255),
    snowflake_database  VARCHAR(255),
    snowflake_warehouse VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255) NOT NULL,
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (environment_name, deployment_layer),
    CHECK (deployment_layer IN ('development', 'staging', 'production')),
    CHECK (warehouse_type IN ('snowflake', 'spark', 'both'))
);

-- 2. compute_cluster_config
-- PySpark / Snowpark compute resource definitions per environment
CREATE TABLE compute_cluster_config (
    cluster_id          SERIAL PRIMARY KEY,
    environment_id      INTEGER NOT NULL REFERENCES environment_config(environment_id) ON DELETE RESTRICT,
    cluster_name        VARCHAR(255) NOT NULL,
    compute_type        VARCHAR(50) NOT NULL,          -- pyspark, snowpark
    cluster_size        VARCHAR(50),                   -- small, medium, large, xlarge
    num_executors       INTEGER CHECK (num_executors > 0),
    executor_memory     VARCHAR(20),
    executor_cores      INTEGER CHECK (executor_cores > 0),
    driver_memory       VARCHAR(20),
    snowpark_warehouse_size VARCHAR(50),               -- xsmall, small, medium, etc.
    auto_scale_enabled  BOOLEAN DEFAULT FALSE,
    min_nodes           INTEGER CHECK (min_nodes >= 0),
    max_nodes           INTEGER CHECK (max_nodes >= 1),
    spark_config        JSONB,                         -- additional spark.conf overrides
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255) NOT NULL,
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    UNIQUE (environment_id, cluster_name),
    CHECK (compute_type IN ('pyspark', 'snowpark')),
    CHECK (max_nodes >= min_nodes OR min_nodes IS NULL OR max_nodes IS NULL)
);

-- 3. promotion_audit_log
-- Tracks promotion of reports and models across SDLC environments
CREATE TABLE promotion_audit_log (
    audit_id            SERIAL PRIMARY KEY,
    entity_type         VARCHAR(50) NOT NULL,          -- report, model, pipeline, feature, feed
    entity_id           INTEGER NOT NULL,
    from_environment_id INTEGER REFERENCES environment_config(environment_id) ON DELETE SET NULL,
    to_environment_id   INTEGER NOT NULL REFERENCES environment_config(environment_id) ON DELETE RESTRICT,
    promotion_status    VARCHAR(50) NOT NULL,          -- requested, approved, promoted, rejected, rolled_back
    requested_by        VARCHAR(255) NOT NULL,
    approved_by         VARCHAR(255),
    promotion_date      TIMESTAMPTZ,
    rollback_date       TIMESTAMPTZ,
    notes               TEXT,
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CHECK (entity_type IN ('report', 'model', 'pipeline', 'feature', 'feed')),
    CHECK (promotion_status IN ('requested', 'approved', 'promoted', 'rejected', 'rolled_back'))
);

-- 4. data_lineage_edge
-- End-to-end lineage graph
CREATE TABLE data_lineage_edge (
    edge_id               SERIAL PRIMARY KEY,
    upstream_entity_type  VARCHAR(50) NOT NULL,        -- source, feed, contract, feature, model, scoring_output, report
    upstream_entity_id    INTEGER NOT NULL,
    downstream_entity_type VARCHAR(50) NOT NULL,
    downstream_entity_id  INTEGER NOT NULL,
    relationship_type     VARCHAR(50) NOT NULL,        -- produces, consumes, transforms, feeds
    transformation_logic  TEXT,
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255),
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255),
    UNIQUE (upstream_entity_type, upstream_entity_id, downstream_entity_type, downstream_entity_id, relationship_type),
    CHECK (upstream_entity_type IN ('source', 'feed', 'contract', 'feature', 'model', 'scoring_output', 'report')),
    CHECK (downstream_entity_type IN ('source', 'feed', 'contract', 'feature', 'model', 'scoring_output', 'report')),
    CHECK (relationship_type IN ('produces', 'consumes', 'transforms', 'feeds'))
);

-- 5. data_classification
-- PII/sensitivity classification
CREATE TABLE data_classification (
    classification_id     SERIAL PRIMARY KEY,
    entity_type           VARCHAR(50) NOT NULL,        -- feed, feature, table, column
    entity_id             INTEGER NOT NULL,
    entity_name           VARCHAR(255),
    classification_level  VARCHAR(50) NOT NULL,        -- public, internal, confidential, restricted
    contains_pii          BOOLEAN DEFAULT FALSE,
    pii_type              VARCHAR(100),                -- SSN, DOB, account_number, name, address, email
    data_residency        VARCHAR(50),                 -- US, EU, global
    retention_days        INTEGER CHECK (retention_days > 0),
    encryption_required   BOOLEAN DEFAULT FALSE,
    masking_rule          VARCHAR(255),                -- mask_last4, full_mask, tokenize, hash
    regulatory_scope      VARCHAR(255),                -- GLBA, SOX, GDPR, CCPA, FCRA
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255) NOT NULL,
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255),
    UNIQUE (entity_type, entity_id),
    CHECK (entity_type IN ('feed', 'feature', 'table', 'column')),
    CHECK (classification_level IN ('public', 'internal', 'confidential', 'restricted'))
);

-- 6. change_audit_log
-- CDC / history tracking for regulated tables
CREATE TABLE change_audit_log (
    audit_id              SERIAL PRIMARY KEY,
    table_name            VARCHAR(255) NOT NULL,
    record_id             VARCHAR(255) NOT NULL,       -- PK value(s) of the changed row
    operation             VARCHAR(10) NOT NULL,        -- INSERT, UPDATE, DELETE
    old_values            JSONB,
    new_values            JSONB,
    changed_by            VARCHAR(255) NOT NULL,
    changed_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    change_reason         TEXT,
    session_id            VARCHAR(255),                -- application session for traceability
    CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    CHECK (
        (operation = 'INSERT' AND new_values IS NOT NULL) OR
        (operation = 'DELETE' AND old_values IS NOT NULL) OR
        (operation = 'UPDATE' AND old_values IS NOT NULL AND new_values IS NOT NULL)
    )
);

-- 7. data_retention_policy
-- Retention and purge rules per table
CREATE TABLE data_retention_policy (
    retention_id          SERIAL PRIMARY KEY,
    table_name            VARCHAR(255) NOT NULL,
    retention_days        INTEGER NOT NULL CHECK (retention_days > 0),
    partition_column      VARCHAR(255),                -- column used for age-based deletion
    purge_strategy        VARCHAR(50) NOT NULL,        -- delete, archive, anonymize
    archive_target        VARCHAR(500),                -- s3 path or archive table
    regulatory_basis      VARCHAR(255),                -- legal/regulatory reason for retention period
    is_active             CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by            VARCHAR(255) NOT NULL,
    updated_date          TIMESTAMPTZ,
    updated_by            VARCHAR(255),
    UNIQUE (table_name),
    CHECK (purge_strategy IN ('delete', 'archive', 'anonymize'))
);

-- ============================================================
-- Indexes
-- ============================================================

-- Foreign key indexes
CREATE INDEX idx_compute_cluster_env ON compute_cluster_config(environment_id);
CREATE INDEX idx_promotion_audit_from_env ON promotion_audit_log(from_environment_id);
CREATE INDEX idx_promotion_audit_to_env ON promotion_audit_log(to_environment_id);

-- Query pattern indexes
CREATE INDEX idx_lineage_upstream ON data_lineage_edge(upstream_entity_type, upstream_entity_id);
CREATE INDEX idx_lineage_downstream ON data_lineage_edge(downstream_entity_type, downstream_entity_id);
CREATE INDEX idx_classification_level ON data_classification(classification_level) WHERE is_active = 'Y';
CREATE INDEX idx_classification_pii ON data_classification(contains_pii) WHERE contains_pii = TRUE AND is_active = 'Y';
CREATE INDEX idx_change_audit_table ON change_audit_log(table_name, changed_at);
CREATE INDEX idx_change_audit_changed_at ON change_audit_log(changed_at);
CREATE INDEX idx_promotion_audit_entity ON promotion_audit_log(entity_type, entity_id);
CREATE INDEX idx_promotion_audit_status ON promotion_audit_log(promotion_status) WHERE promotion_status IN ('requested', 'approved');
