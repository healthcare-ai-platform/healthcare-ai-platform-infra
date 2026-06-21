-- =============================================================================
-- warehouse_schema.sql
-- Local Redshift-equivalent schema (PostgreSQL 16)
--
-- Mirror this on real Redshift for staging/prod.
-- Tables use a simple star schema: facts + dimensions.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_tenants (
    tenant_id   UUID        PRIMARY KEY,
    name        TEXT        NOT NULL,
    plan        TEXT,
    status      TEXT,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dim_patients (
    patient_id  UUID        PRIMARY KEY,
    tenant_id   UUID        NOT NULL,
    gender      TEXT,
    age_band    TEXT,       -- '0-17', '18-34', '35-54', '55-64', '65+'
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dim_facilities (
    facility_id UUID        PRIMARY KEY,
    tenant_id   UUID        NOT NULL,
    name        TEXT        NOT NULL,
    type        TEXT,
    city        TEXT,
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------------

-- One row per document through the pipeline
CREATE TABLE IF NOT EXISTS fact_documents (
    document_id          UUID        PRIMARY KEY,
    tenant_id            UUID        NOT NULL,
    facility_id          UUID,
    patient_id           UUID,
    report_type          TEXT,
    source               TEXT,
    final_status         TEXT,
    created_at           TIMESTAMPTZ,
    loaded_at            TIMESTAMPTZ,
    processing_time_mins NUMERIC(10, 2),  -- loaded_at - created_at
    date_key             DATE            -- partition / sort key
);

CREATE INDEX IF NOT EXISTS idx_fact_docs_tenant   ON fact_documents(tenant_id, date_key);
CREATE INDEX IF NOT EXISTS idx_fact_docs_status   ON fact_documents(final_status, date_key);

-- One row per extracted test result
CREATE TABLE IF NOT EXISTS fact_report_results (
    result_id   UUID        PRIMARY KEY,
    report_id   UUID        NOT NULL,
    document_id UUID        NOT NULL,
    patient_id  UUID        NOT NULL,
    tenant_id   UUID        NOT NULL,
    facility_id UUID,
    test_name   TEXT        NOT NULL,
    flag        TEXT,
    confidence  NUMERIC(5, 4),
    report_date DATE,
    created_at  TIMESTAMPTZ,
    date_key    DATE
);

CREATE INDEX IF NOT EXISTS idx_fact_results_tenant  ON fact_report_results(tenant_id, date_key);
CREATE INDEX IF NOT EXISTS idx_fact_results_patient ON fact_report_results(patient_id);
CREATE INDEX IF NOT EXISTS idx_fact_results_flag    ON fact_report_results(flag, date_key);

-- ---------------------------------------------------------------------------
-- Pre-aggregated views (replace with Redshift Materialized Views in prod)
-- ---------------------------------------------------------------------------

-- KPI summary per day per tenant
CREATE OR REPLACE VIEW agg_daily_kpis AS
SELECT
    date_key,
    tenant_id,
    COUNT(*)                                                        AS total_docs,
    COUNT(*) FILTER (WHERE final_status = 'loaded')                 AS loaded_docs,
    COUNT(*) FILTER (WHERE final_status = 'failed')                 AS failed_docs,
    ROUND(
        COUNT(*) FILTER (WHERE final_status = 'loaded')::numeric
        / NULLIF(COUNT(*), 0) * 100,
    2)                                                              AS success_pct,
    ROUND(AVG(processing_time_mins) FILTER (WHERE final_status = 'loaded'), 2)
                                                                    AS avg_processing_mins
FROM fact_documents
GROUP BY date_key, tenant_id;

-- Extraction flag breakdown per day
CREATE OR REPLACE VIEW agg_flag_summary AS
SELECT
    date_key,
    tenant_id,
    test_name,
    flag,
    COUNT(*)                        AS result_count,
    ROUND(AVG(confidence)::numeric, 4) AS avg_confidence
FROM fact_report_results
GROUP BY date_key, tenant_id, test_name, flag;

-- Pipeline funnel per day
CREATE OR REPLACE VIEW agg_pipeline_funnel AS
SELECT
    date_key,
    tenant_id,
    final_status  AS stage,
    COUNT(*)      AS doc_count
FROM fact_documents
GROUP BY date_key, tenant_id, final_status;

COMMIT;
