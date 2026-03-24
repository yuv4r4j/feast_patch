-- ============================================================
-- PostgreSQL DDL generated from ERD diagram
-- ============================================================

-- 1. source_details
CREATE TABLE source_details (
    source_id           SERIAL PRIMARY KEY,
    source_name         VARCHAR(255) NOT NULL UNIQUE,
    business_unit       VARCHAR(255),
    business_owner      VARCHAR(255),
    email_id            VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    department_name     VARCHAR(255)
);

-- 2. target_details
CREATE TABLE target_details (
    target_id           SERIAL PRIMARY KEY,
    target_detail_name  VARCHAR(255) NOT NULL UNIQUE,
    business_unit       VARCHAR(255),
    business_owner      VARCHAR(255),
    email_id            VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    department_name     VARCHAR(255)
);

-- 3. feed_group_details
CREATE TABLE feed_group_details (
    feed_group_id       SERIAL PRIMARY KEY,
    source_id           INTEGER REFERENCES source_details(source_id) ON DELETE RESTRICT,
    feed_group_name     VARCHAR(255) NOT NULL,
    is_all_feed_required INTEGER DEFAULT 0 CHECK (is_all_feed_required IN (0, 1)),
    notification_email_id VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    feed_group_type     VARCHAR(50),
    table_load_setting  JSONB,
    feed_description    VARCHAR(500),
    dev_user_email      VARCHAR(255),
    target_id           INTEGER REFERENCES target_details(target_id) ON DELETE RESTRICT,
    UNIQUE (source_id, feed_group_name)
);

-- 4. feed_details
CREATE TABLE feed_details (
    feed_id             SERIAL PRIMARY KEY,
    feed_name           VARCHAR(255) NOT NULL,
    feed_group_id       INTEGER NOT NULL REFERENCES feed_group_details(feed_group_id) ON DELETE RESTRICT,
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    start_date          TIMESTAMPTZ,
    smb_connection_name VARCHAR(255),
    tag_name            VARCHAR(500),
    filter_column_name  VARCHAR(255),
    table_load_type     VARCHAR(100),
    UNIQUE (feed_group_id, feed_name)
);

-- 5. template_details
CREATE TABLE template_details (
    template_id         SERIAL PRIMARY KEY,
    template_name       VARCHAR(255) NOT NULL UNIQUE,
    template_desc       TEXT,
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 6. contract_details
CREATE TABLE contract_details (
    contract_id                 SERIAL PRIMARY KEY,
    contract_type               VARCHAR(50) NOT NULL CHECK (contract_type IN ('file', 'rdbms', 'api', 'streaming')),
    feed_group_id               INTEGER NOT NULL REFERENCES feed_group_details(feed_group_id) ON DELETE RESTRICT,
    feed_id                     INTEGER NOT NULL REFERENCES feed_details(feed_id) ON DELETE CASCADE,
    file_name_pattern           VARCHAR(500),
    file_format                 VARCHAR(255) NOT NULL CHECK (file_format IN ('csv', 'parquet', 'avro', 'json', 'fixed_width', 'orc', 'xml')),
    source_path                 VARCHAR(500),
    raw_path                    VARCHAR(500),
    transient_path              VARCHAR(500),
    rejected_path               VARCHAR(500),
    src_connection_details      JSONB,
    ingestion_frequency         VARCHAR(100),
    soft_fail                   BOOLEAN DEFAULT FALSE,
    poke_interval_in_sec        VARCHAR(50),
    timeout_in_min              VARCHAR(50),
    watermark_details           TEXT,
    load_type                   VARCHAR(50) CHECK (load_type IN ('full', 'incremental', 'cdc')),
    is_compressed               INTEGER DEFAULT 0 CHECK (is_compressed IN (0, 1)),
    compressed_format           VARCHAR(50),
    is_encrypted                INTEGER DEFAULT 0 CHECK (is_encrypted IN (0, 1)),
    template_id                 INTEGER REFERENCES template_details(template_id) ON DELETE SET NULL,
    created_date                TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by                  VARCHAR(255),
    updated_date                TIMESTAMPTZ,
    updated_by                  VARCHAR(255),
    file_pattern_lineage        VARCHAR(500),
    rdbms_source_catalog_lineage VARCHAR(255),
    rdbms_source_schema_lineage  VARCHAR(255),
    rdbms_source_table_lineage   VARCHAR(255),
    s3_transient_path           VARCHAR(500),
    CONSTRAINT chk_compressed_consistency CHECK ((is_compressed = 1 AND compressed_format IS NOT NULL) OR (is_compressed = 0))
);

-- 7. schema_details (composite PK: schema_id, schema_version)
CREATE TABLE schema_details (
    schema_id                   INTEGER NOT NULL,
    schema_version              INTEGER NOT NULL,
    contract_id                 INTEGER NOT NULL REFERENCES contract_details(contract_id) ON DELETE CASCADE,
    header_details              CHAR(1) CHECK (header_details IN ('Y', 'N')),
    record_length               INTEGER,
    row_delimiter               VARCHAR(20),
    column_delimiter            VARCHAR(20),
    start_date                  TIMESTAMPTZ,
    end_date                    TIMESTAMPTZ,
    is_active                   CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date                TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by                  VARCHAR(255),
    updated_date                TIMESTAMPTZ,
    updated_by                  VARCHAR(255),
    schema_json                 JSONB,
    external_table              VARCHAR(255),
    footer_details              CHAR(1) CHECK (footer_details IN ('Y', 'N')),
    encoding_details            VARCHAR(100),
    is_table_created            CHAR(1) DEFAULT 'N' CHECK (is_table_created IN ('Y', 'N')),
    no_file_alert               CHAR(1) DEFAULT 'Y' CHECK (no_file_alert IN ('Y', 'N')),
    direct_load                 CHAR(1) CHECK (direct_load IN ('Y', 'N')),
    is_trusted_validation       CHAR(1) DEFAULT 'Y' CHECK (is_trusted_validation IN ('Y', 'N')),
    view_script                 TEXT,
    trusted_table               VARCHAR(255),
    view_name_reporting_date    VARCHAR(255),
    is_trusted_created          CHAR(1) DEFAULT 'N' CHECK (is_trusted_created IN ('Y', 'N')),
    filter_criteria             TEXT,
    schema_sql                  TEXT,
    trusted_partition_columns   TEXT,
    file_pattern_reporting_date VARCHAR(255),
    date_format_reporting_date  VARCHAR(100),
    data_name_reporting_date    VARCHAR(255),
    is_apps_validation          CHAR(1) DEFAULT 'N' CHECK (is_apps_validation IN ('Y', 'N')),
    is_cloud_consumption_created CHAR(1) DEFAULT 'N' CHECK (is_cloud_consumption_created IN ('Y', 'N')),
    data_vault_type             VARCHAR(50),
    target_table                VARCHAR(255),
    cz_view_script              TEXT,
    is_apps_created             CHAR(1) DEFAULT 'N' CHECK (is_apps_created IN ('Y', 'N')),
    PRIMARY KEY (schema_id, schema_version)
);

-- 8. fdm_parser_reference
CREATE TABLE fdm_parser_reference (
    feed_group_id       INTEGER REFERENCES feed_group_details(feed_group_id) ON DELETE CASCADE,
    copybook_name       VARCHAR(255),
    layout_name         VARCHAR(255),
    record_length       INTEGER,
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 9. spark_submit_setting (composite PK: feed_group_id, feed_id)
CREATE TABLE spark_submit_setting (
    feed_group_id       INTEGER REFERENCES feed_group_details(feed_group_id) ON DELETE CASCADE,
    feed_id             INTEGER REFERENCES feed_details(feed_id) ON DELETE CASCADE,
    exec_instances      INTEGER,
    exec_mem            VARCHAR(20),
    exec_cores          INTEGER,
    exec_size           VARCHAR(20),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    PRIMARY KEY (feed_group_id, feed_id)
);

-- 10. target_type_details
CREATE TABLE target_type_details (
    cz_load_target_id   SERIAL PRIMARY KEY,
    expectation_suite_name VARCHAR(255),
    load_target         VARCHAR(255),
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255)
);

-- 11. feed_target_mapping
CREATE TABLE feed_target_mapping (
    feed_id             INTEGER REFERENCES feed_details(feed_id) ON DELETE CASCADE,
    cz_load_target_id   INTEGER REFERENCES target_type_details(cz_load_target_id) ON DELETE CASCADE,
    is_active           CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y', 'N')),
    created_date        TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by          VARCHAR(255),
    updated_date        TIMESTAMPTZ,
    updated_by          VARCHAR(255),
    PRIMARY KEY (feed_id, cz_load_target_id)
);

-- 12. ge_error_threshold
CREATE TABLE ge_error_threshold (
    feed_id                 INTEGER REFERENCES feed_details(feed_id) ON DELETE CASCADE,
    error_threshold         NUMERIC(5,2) CHECK (error_threshold >= 0 AND error_threshold <= 100),
    custom_error_threshold  NUMERIC(5,2) CHECK (custom_error_threshold >= 0 AND custom_error_threshold <= 100),
    created_date            TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by              VARCHAR(255),
    updated_date            TIMESTAMPTZ,
    updated_by              VARCHAR(255)
);

-- 13. ge_validation_ref (composite PK: feed_id, validation_zone, validation_type)
CREATE TABLE ge_validation_ref (
    feed_id                 INTEGER NOT NULL REFERENCES feed_details(feed_id) ON DELETE CASCADE,
    validation_zone         VARCHAR(50) NOT NULL CHECK (validation_zone IN ('raw', 'refined', 'trusted', 'consumption')),
    validation_type         VARCHAR(100) NOT NULL CHECK (validation_type IN ('pre_load', 'post_load', 'reconciliation')),
    expectation_suite_name  VARCHAR(255),
    checkpoint_name         VARCHAR(255),
    created_date            TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by              VARCHAR(255),
    updated_date            TIMESTAMPTZ,
    updated_by              VARCHAR(255),
    PRIMARY KEY (feed_id, validation_zone, validation_type)
);

-- 14. custom_expectations_store
CREATE TABLE custom_expectations_store (
    expectation_suite_name  VARCHAR(255) PRIMARY KEY,
    value                   JSONB,
    created_date            TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by              VARCHAR(255),
    updated_date            TIMESTAMPTZ,
    updated_by              VARCHAR(255)
);

-- 15. ge_expectations_store
CREATE TABLE ge_expectations_store (
    expectation_suite_name  VARCHAR(255) PRIMARY KEY,
    expectations            JSONB,
    created_date            TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by              VARCHAR(255),
    updated_date            TIMESTAMPTZ,
    updated_by              VARCHAR(255)
);

-- ============================================================
-- Foreign key indexes
-- ============================================================
CREATE INDEX idx_feed_group_details_source_id ON feed_group_details(source_id);
CREATE INDEX idx_feed_group_details_target_id ON feed_group_details(target_id);
CREATE INDEX idx_feed_details_feed_group_id ON feed_details(feed_group_id);
CREATE INDEX idx_contract_details_feed_group_id ON contract_details(feed_group_id);
CREATE INDEX idx_contract_details_feed_id ON contract_details(feed_id);
CREATE INDEX idx_contract_details_template_id ON contract_details(template_id);
CREATE INDEX idx_schema_details_contract_id ON schema_details(contract_id);
CREATE INDEX idx_fdm_parser_reference_feed_group_id ON fdm_parser_reference(feed_group_id);
CREATE INDEX idx_spark_submit_setting_feed_id ON spark_submit_setting(feed_id);
CREATE INDEX idx_feed_target_mapping_cz_load_target_id ON feed_target_mapping(cz_load_target_id);
CREATE INDEX idx_ge_error_threshold_feed_id ON ge_error_threshold(feed_id);

-- Query pattern indexes
CREATE INDEX idx_schema_details_contract_active ON schema_details(contract_id, is_active) WHERE is_active = 'Y';
CREATE INDEX idx_feed_details_active ON feed_details(feed_group_id) WHERE is_active = 'Y';
CREATE INDEX idx_feed_group_details_active ON feed_group_details(source_id) WHERE is_active = 'Y';
