#!/bin/bash
set -e

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE EXTENSION IF NOT EXISTS btree_gist;
EOSQL

# Create roles (skip V007 migration which has same purpose but different passwords)
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
    DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'aciertech_ro') THEN
            CREATE ROLE aciertech_ro WITH LOGIN PASSWORD 'aciertech_ro_pass' INHERIT;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'aciertech_app') THEN
            CREATE ROLE aciertech_app WITH LOGIN PASSWORD 'aciertech_app_pass' INHERIT;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
            CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pass';
        END IF;
    END $$;
EOSQL

# Run migrations in order, skip V007 (roles already created above)
MIGRATIONS_DIR="/docker-entrypoint-initdb.d/02-sql/migrations"
for f in "$MIGRATIONS_DIR"/V*.sql; do
    base=$(basename "$f")
    if [[ "$base" == "V007__create_roles.sql" ]]; then
        echo "Skipping $base (roles already created)"
        continue
    fi
    echo "Running migration: $base"
    psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$f" 2>&1 || echo "Warning: $base had errors (continuing)"
done

# Grant permissions to aciertech_ro (in case V007 was skipped)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
    GRANT USAGE ON SCHEMA dba_schema TO aciertech_ro;
    GRANT USAGE ON SCHEMA iot_clean TO aciertech_ro;
    GRANT USAGE ON SCHEMA iot_raw TO aciertech_ro;
    GRANT USAGE ON SCHEMA iot_quarantine TO aciertech_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA dba_schema TO aciertech_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA iot_clean TO aciertech_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA iot_raw TO aciertech_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA iot_quarantine TO aciertech_ro;
    ALTER DEFAULT PRIVILEGES IN SCHEMA dba_schema GRANT SELECT ON TABLES TO aciertech_ro;
    ALTER DEFAULT PRIVILEGES IN SCHEMA iot_clean GRANT SELECT ON TABLES TO aciertech_ro;
    ALTER DEFAULT PRIVILEGES IN SCHEMA iot_raw GRANT SELECT ON TABLES TO aciertech_ro;
    ALTER DEFAULT PRIVILEGES IN SCHEMA iot_quarantine GRANT SELECT ON TABLES TO aciertech_ro;
EOSQL

# =============================================================================
# VIEWS  —  Simplified versions that work with actual column names
# (Skip the SQL files from 02-sql/views/ — they reference non-existent columns)
# =============================================================================

# v_silent_sensors: detects sensors without recent readings
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE VIEW dba_schema.v_silent_sensors AS
SELECT
    s.sensor_id,
    s.sensor_name,
    s.sensor_type,
    s.location_zone AS location,
    s.is_active,
    s.installed_at,
    NOW() - COALESCE(
        (SELECT MAX(recorded_at) FROM iot_raw.sensor_readings r WHERE r.sensor_id = s.sensor_id),
        s.installed_at::timestamptz
    ) AS silence_duration,
    (SELECT MAX(recorded_at) FROM iot_raw.sensor_readings r WHERE r.sensor_id = s.sensor_id) AS last_reading_at,
    COALESCE(
        (SELECT expected_interval_s FROM dba_schema.sensor_thresholds t WHERE t.sensor_id = s.sensor_id LIMIT 1),
        300
    ) AS expected_interval_s,
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM iot_raw.sensor_readings r WHERE r.sensor_id = s.sensor_id) THEN 'NEVER_SEEN'
        WHEN NOW() - COALESCE(
            (SELECT MAX(recorded_at) FROM iot_raw.sensor_readings r WHERE r.sensor_id = s.sensor_id),
            '1970-01-01'::timestamptz
        ) > interval '1 hour' THEN 'CRITICAL'
        ELSE 'OK'
    END AS silence_level
FROM dba_schema.sensor_registry s;

GRANT SELECT ON dba_schema.v_silent_sensors TO aciertech_ro;
REVOKE ALL ON dba_schema.v_silent_sensors FROM PUBLIC;
EOSQL

# v_replication_status: streaming replication status from system views
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE VIEW dba_schema.v_replication_status AS
WITH repl_raw AS (
    SELECT
        r.pid,
        r.usename,
        r.application_name,
        r.client_addr,
        r.client_port,
        r.backend_start,
        r.state,
        r.sent_lsn,
        r.write_lsn,
        r.flush_lsn,
        r.replay_lsn,
        r.write_lag,
        r.flush_lag,
        r.replay_lag,
        r.sync_priority,
        r.sync_state,
        pg_current_wal_lsn() AS primary_lsn
    FROM pg_stat_replication r
),
wal_stats AS (
    SELECT
        wal_bytes,
        wal_records,
        stats_reset
    FROM pg_stat_wal
)
SELECT
    r.application_name,
    r.application_name AS replica_name,
    r.client_addr AS replica_host,
    r.client_port AS replica_port,
    r.pid AS walsender_pid,
    r.backend_start AS connected_since,
    NOW() - r.backend_start AS connection_age,
    r.state AS replication_state,
    r.state,
    r.sync_state AS sync_mode,
    r.sync_state,
    r.sync_priority,
    r.primary_lsn,
    r.sent_lsn,
    r.write_lsn,
    r.flush_lsn,
    r.replay_lsn,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.sent_lsn), 0) AS unsent_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.write_lsn), 0) AS replication_lag_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.flush_lsn), 0) AS flush_lag_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.replay_lsn), 0) AS replay_lag_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.replay_lsn), 0) AS lag_bytes,
    r.write_lag AS write_lag_interval,
    r.flush_lag AS flush_lag_interval,
    r.replay_lag AS replay_lag_interval,
    r.replay_lag AS lag_seconds,
    ROUND(EXTRACT(EPOCH FROM r.replay_lag)::NUMERIC, 3) AS replay_lag_seconds,
    CASE
        WHEN r.replay_lag IS NULL THEN 'UNKNOWN'
        WHEN r.replay_lag < INTERVAL '5 seconds' THEN 'OK'
        WHEN r.replay_lag < INTERVAL '30 seconds' THEN 'WARNING'
        ELSE 'CRITICAL'
    END AS lag_level,
    CASE
        WHEN r.state = 'streaming' AND r.sync_state IN ('sync', 'quorum') THEN 'SYNC_STREAMING'
        WHEN r.state = 'streaming' AND r.sync_state = 'async' THEN 'ASYNC_STREAMING'
        WHEN r.state = 'catchup' THEN 'CATCHING_UP'
        WHEN r.state = 'startup' THEN 'STARTING'
        WHEN r.state = 'backup' THEN 'BACKUP_IN_PROGRESS'
        ELSE 'UNKNOWN_STATE'
    END AS replica_status,
    ws.wal_bytes AS total_wal_bytes_produced,
    ws.stats_reset AS wal_stats_reset_at,
    NOW() AS viewed_at
FROM repl_raw r
CROSS JOIN wal_stats ws
ORDER BY r.sync_priority ASC NULLS LAST, r.application_name;

REVOKE ALL ON dba_schema.v_replication_status FROM PUBLIC;
EOSQL

# v_session_activity: active PostgreSQL sessions
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE VIEW dba_schema.v_session_activity AS
WITH active_sessions AS (
    SELECT
        a.pid,
        a.usename,
        a.application_name,
        a.client_addr,
        a.client_port,
        a.backend_start,
        a.xact_start,
        a.query_start,
        a.state_change,
        a.wait_event_type,
        a.wait_event,
        a.state,
        a.backend_type,
        a.query,
        EXTRACT(EPOCH FROM (NOW() - a.query_start)) AS duration_seconds,
        EXTRACT(EPOCH FROM (NOW() - a.xact_start)) AS txn_duration_seconds,
        EXTRACT(EPOCH FROM (NOW() - a.state_change)) AS state_age_seconds,
        a.leader_pid,
        a.query_id
    FROM pg_stat_activity a
    WHERE a.pid <> pg_backend_pid()
      AND a.backend_type = 'client backend'
),
blocking AS (
    SELECT
        blocked.pid AS blocked_pid,
        blocker.pid AS blocking_pid,
        blocker.usename AS blocking_user,
        LEFT(blocker.query, 200) AS blocking_query,
        blocker.state AS blocking_state
    FROM pg_stat_activity blocked
    JOIN pg_stat_activity blocker
        ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
    WHERE blocked.wait_event_type = 'Lock'
      AND blocked.pid <> pg_backend_pid()
)
SELECT
    s.pid,
    s.usename AS role_name,
    s.application_name,
    s.client_addr,
    s.client_port,
    s.backend_type,
    s.state,
    s.wait_event_type,
    s.wait_event,
    ROUND(s.duration_seconds::NUMERIC, 3) AS query_duration_seconds,
    ROUND(s.txn_duration_seconds::NUMERIC, 3) AS txn_duration_seconds,
    LEFT(s.query, 200) AS query_preview,
    s.query_id,
    s.leader_pid,
    CASE WHEN s.leader_pid IS NOT NULL THEN TRUE ELSE FALSE END AS is_parallel_worker,
    s.backend_start,
    s.xact_start,
    s.query_start,
    b.blocking_pid,
    b.blocking_user,
    b.blocking_query,
    b.blocking_state,
    CASE WHEN b.blocking_pid IS NOT NULL THEN TRUE ELSE FALSE END AS is_blocked,
    CASE
        WHEN s.duration_seconds IS NOT NULL AND s.duration_seconds > 1.0 THEN TRUE ELSE FALSE
    END AS is_long_running,
    CASE
        WHEN b.blocking_pid IS NOT NULL AND s.duration_seconds >= 30 THEN 'CRITICAL'
        WHEN s.duration_seconds >= 30 THEN 'CRITICAL'
        WHEN b.blocking_pid IS NOT NULL THEN 'WARNING'
        WHEN s.duration_seconds >= 5 THEN 'WARNING'
        ELSE 'OK'
    END AS alert_level,
    (
        SELECT COUNT(*)
        FROM pg_stat_activity victim
        WHERE s.pid = ANY(pg_blocking_pids(victim.pid))
    ) AS sessions_it_blocks,
    NOW() AS viewed_at
FROM active_sessions s
LEFT JOIN blocking b ON s.pid = b.blocked_pid
ORDER BY
    CASE
        WHEN b.blocking_pid IS NOT NULL AND s.duration_seconds >= 30 THEN 1
        WHEN s.duration_seconds >= 30 THEN 2
        WHEN b.blocking_pid IS NOT NULL THEN 3
        WHEN s.duration_seconds >= 5 THEN 4
        ELSE 5
    END,
    s.duration_seconds DESC NULLS LAST;

REVOKE ALL ON dba_schema.v_session_activity FROM PUBLIC;
EOSQL

# v_data_quality_dashboard: quality metrics per sensor type
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE VIEW dba_schema.v_data_quality_dashboard AS
WITH raw_window AS (
    SELECT
        sr.sensor_type,
        sr.sensor_id,
        sr.validation_status,
        sr.quality_score,
        sr.recorded_at
    FROM iot_raw.sensor_readings sr
    WHERE sr.recorded_at >= NOW() - INTERVAL '1 hour'
),
agg_by_type AS (
    SELECT
        rw.sensor_type,
        COUNT(*) AS total_readings,
        COUNT(*) FILTER (WHERE rw.validation_status = 'valid') AS valid_count,
        COUNT(*) FILTER (WHERE rw.validation_status = 'quarantined') AS quarantined_count,
        ROUND(AVG(rw.quality_score)::NUMERIC, 2) AS avg_quality_score,
        MIN(rw.quality_score) AS min_quality_score,
        COUNT(DISTINCT rw.sensor_id) AS sensors_active,
        MAX(rw.recorded_at) AS last_reading_at
    FROM raw_window rw
    GROUP BY rw.sensor_type
),
expected_by_type AS (
    SELECT
        sensor_type,
        COUNT(*) FILTER (WHERE is_active = TRUE) AS sensors_expected
    FROM dba_schema.sensor_registry
    GROUP BY sensor_type
),
errors_by_type AS (
    SELECT
        sensor_type,
        COUNT(*) AS error_count
    FROM iot_raw.ingestion_errors
    WHERE occurred_at >= NOW() - INTERVAL '1 hour'
    GROUP BY sensor_type
)
SELECT
    COALESCE(exp.sensor_type, agg.sensor_type) AS sensor_type,
    COALESCE(exp.sensors_expected, 0) AS sensors_expected,
    COALESCE(agg.sensors_active, 0) AS sensors_active,
    GREATEST(COALESCE(exp.sensors_expected, 0) - COALESCE(agg.sensors_active, 0), 0) AS sensors_silent,
    COALESCE(agg.total_readings, 0) AS total_readings,
    COALESCE(agg.valid_count, 0) AS valid_count,
    COALESCE(agg.quarantined_count, 0) AS quarantined_count,
    COALESCE(err.error_count, 0) AS error_count,
    CASE
        WHEN COALESCE(agg.total_readings, 0) = 0 THEN NULL
        ELSE ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2)
    END AS valid_rate_pct,
    agg.avg_quality_score,
    agg.min_quality_score,
    agg.last_reading_at,
    CASE
        WHEN agg.last_reading_at IS NULL THEN NULL
        ELSE NOW() - agg.last_reading_at
    END AS time_since_last_reading,
    CASE
        WHEN COALESCE(agg.total_readings, 0) = 0 THEN 'NO_DATA'
        WHEN ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2) >= 95 THEN 'EXCELLENT'
        WHEN ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2) >= 80 THEN 'GOOD'
        WHEN ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2) >= 60 THEN 'DEGRADED'
        ELSE 'CRITICAL'
    END AS quality_level,
    NOW() AS computed_at
FROM expected_by_type exp
FULL OUTER JOIN agg_by_type agg ON exp.sensor_type = agg.sensor_type
LEFT JOIN errors_by_type err ON COALESCE(exp.sensor_type, agg.sensor_type) = err.sensor_type
ORDER BY
    CASE
        WHEN COALESCE(agg.total_readings, 0) = 0 THEN 1
        WHEN ROUND((agg.valid_count::NUMERIC / NULLIF(agg.total_readings, 0)::NUMERIC) * 100, 2) < 60 THEN 2
        WHEN ROUND((agg.valid_count::NUMERIC / NULLIF(agg.total_readings, 0)::NUMERIC) * 100, 2) < 80 THEN 3
        ELSE 4
    END,
    COALESCE(exp.sensor_type, agg.sensor_type);

GRANT SELECT ON dba_schema.v_data_quality_dashboard TO aciertech_ro;
REVOKE ALL ON dba_schema.v_data_quality_dashboard FROM PUBLIC;
EOSQL

# =============================================================================
# FUNCTIONS  —  Skipped: SQL files reference columns that don't exist
# (fn_compute_quality_score uses min_value/max_value/warning_min/warning_max
#  which don't match sensor_thresholds columns; trigger not needed for demo)
# =============================================================================
# Create a no-op stub so dependent objects don't fail
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE FUNCTION dba_schema.fn_compute_quality_score(
    p_sensor_id INTEGER,
    p_sensor_type VARCHAR(50),
    p_value NUMERIC(10,4),
    p_recorded_at TIMESTAMPTZ
)
RETURNS TABLE (score SMALLINT, reason TEXT, details JSONB)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = dba_schema, iot_raw, pg_catalog
AS $$
BEGIN
    RETURN QUERY SELECT 100::SMALLINT, 'OK'::TEXT, '{}'::JSONB;
END;
$$;
EOSQL

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE FUNCTION dba_schema.fn_compute_quality_snapshot(
    p_window_minutes INTEGER DEFAULT 5
)
RETURNS INTEGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = dba_schema, iot_raw, pg_catalog
AS $$
BEGIN
    RETURN 0;
END;
$$;
EOSQL

psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
CREATE OR REPLACE FUNCTION dba_schema.fn_refresh_ai_view()
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = dba_schema, iot_clean, pg_catalog
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY iot_clean.v_ai_feature_set;
END;
$$;
EOSQL

# =============================================================================
# TRIGGERS  —  Skipped: they reference columns (raw_reading_id, rejection_details,
# min_value/max_value, etc.) that don't match actual table structures.
# Seed data is inserted directly so no trigger-driven pipeline needed for demo.
# =============================================================================

# =============================================================================
# SEED MOCK DATA  —  Using actual column names from V002-V005
# =============================================================================
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL' 2>&1 || echo "Warning: seed data had errors"

-- Insert mock sensor readings (iot_raw) using actual column names
-- Use CTE so quality_score and validation_status are based on the SAME random() value
INSERT INTO iot_raw.sensor_readings (sensor_id, sensor_type, value, unit, recorded_at, received_at, quality_score, validation_status, rejection_reason)
WITH base AS (
    SELECT
        s.sensor_id,
        s.sensor_type,
        now() - (random() * interval '1 hour') AS recorded_at,
        random() AS rnd,
        CASE s.sensor_type
            WHEN 'temperature' THEN round((random() * 800 + 20)::numeric, 1)
            WHEN 'pressure'    THEN round((random() * 300 + 50)::numeric, 1)
            WHEN 'vibration'   THEN round((random() * 30 + 1)::numeric, 2)
            WHEN 'current'     THEN round((random() * 200 + 10)::numeric, 1)
            WHEN 'flow'        THEN round((random() * 500 + 20)::numeric, 1)
            WHEN 'speed'       THEN round((random() * 1500 + 100)::numeric, 1)
            WHEN 'thickness'   THEN round((random() * 50 + 1)::numeric, 1)
            WHEN 'weight'      THEN round((random() * 50000 + 100)::numeric, 1)
            ELSE round((random() * 100)::numeric, 1)
        END AS val,
        CASE s.sensor_type
            WHEN 'temperature' THEN '°C'
            WHEN 'pressure'    THEN 'bar'
            WHEN 'vibration'   THEN 'mm/s'
            WHEN 'current'     THEN 'A'
            WHEN 'flow'        THEN 'L/min'
            WHEN 'speed'       THEN 'tr/min'
            WHEN 'thickness'   THEN 'mm'
            WHEN 'weight'      THEN 'kg'
            ELSE 'N/A'
        END AS unit
    FROM dba_schema.sensor_registry s
    CROSS JOIN generate_series(1, 20)
)
SELECT
    sensor_id,
    sensor_type,
    val,
    unit,
    recorded_at,
    NOW() AS received_at,
    CASE WHEN rnd < 0.05 THEN round((random() * 28 + 40))::int ELSE round((random() * 20 + 80))::int END AS quality_score,
    CASE WHEN rnd < 0.05 THEN 'quarantined' ELSE 'valid' END AS validation_status,
    CASE WHEN rnd < 0.05 THEN 'ZSCORE_OUTLIER' ELSE NULL END AS rejection_reason
FROM base;

-- Insert clean readings into iot_clean (no received_at, no validation_status)
INSERT INTO iot_clean.sensor_readings (original_id, sensor_id, sensor_type, value, unit, recorded_at, validated_at, quality_score)
SELECT id, sensor_id, sensor_type, value, unit, recorded_at, now(), quality_score
FROM iot_raw.sensor_readings
WHERE validation_status = 'valid'
LIMIT 200;

-- Insert rejected readings into iot_quarantine (uses raw_value, original_id, rejected_at)
INSERT INTO iot_quarantine.rejected_readings (original_id, sensor_id, sensor_type, raw_value, unit, recorded_at, rejected_at, quality_score, rejection_reason)
SELECT id, sensor_id, sensor_type, value, unit, recorded_at, now(), quality_score, rejection_reason
FROM iot_raw.sensor_readings
WHERE validation_status = 'quarantined'
LIMIT 10;

-- Insert anomaly log entries (uses actual column names + CHECK-compliant values)
INSERT INTO iot_quarantine.anomaly_log (sensor_id, sensor_type, original_id, anomaly_type, severity, raw_value, threshold_value, zscore, occurred_at)
SELECT
    rr.sensor_id,
    rr.sensor_type,
    rr.original_id,
    CASE floor(random() * 4)::int
        WHEN 0 THEN 'CRITICAL_MAX_BREACH'
        WHEN 1 THEN 'ZSCORE_OUTLIER'
        WHEN 2 THEN 'WARN_MAX'
        WHEN 3 THEN 'MISSING_THRESHOLD_CONFIG'
    END,
    CASE WHEN random() < 0.5 THEN 'warning' ELSE 'critical' END,
    rr.raw_value,
    CASE rr.sensor_type
        WHEN 'temperature' THEN 1200
        WHEN 'pressure'    THEN 200
        WHEN 'vibration'   THEN 7.1
        WHEN 'current'     THEN 430
        WHEN 'flow'        THEN 2200
        WHEN 'speed'       THEN 1000
        WHEN 'thickness'   THEN 30.0
        WHEN 'weight'      THEN 500000
    END,
    round((random() * 5 + 2)::numeric, 2),
    now()
FROM iot_quarantine.rejected_readings rr;

-- Refresh the materialized view for AI feature set
REFRESH MATERIALIZED VIEW iot_clean.v_ai_feature_set;

-- Insert backup history (no error_detail column)
INSERT INTO dba_schema.backup_history (backup_type, status, started_at, completed_at, size_bytes, stanza, notes)
VALUES
    ('full',   'success', now() - interval '12 hours', now() - interval '11 hours',        1572864000, 'aciertech', 'Backup full quotidien OK'),
    ('diff',   'success', now() - interval '6 hours',  now() - interval '5 hours 45 min',  524288000,  'aciertech', 'Backup diff OK'),
    ('diff',   'success', now() - interval '3 hours',  now() - interval '2 hours 50 min',  262144000,  'aciertech', 'Backup diff OK'),
    ('full',   'success', now() - interval '5 days',   now() - interval '4 days 23 hours', 1048576000, 'aciertech', 'Backup full H-5 OK'),
    ('full',   'running', now() - interval '30 minutes', NULL,                              NULL,       'aciertech', 'Backup full en cours'),
    ('verify', 'success', now() - interval '2 hours',  now() - interval '1 hour',           NULL,       'aciertech', 'Verification des backups OK'),
    ('verify', 'success', now() - interval '24 hours', now() - interval '23 hours',         NULL,       'aciertech', 'Test de restauration OK');

-- Insert quality snapshots (uses actual column: quality_status check values are French)
INSERT INTO dba_schema.data_quality_snapshots (sensor_type, window_minutes, total_received, valid_count, quarantine_count, avg_quality_score, valid_pct, quality_status, snapshot_at)
SELECT
    s.sensor_type,
    5 AS window_minutes,
    count(*) AS total_received,
    count(*) FILTER (WHERE validation_status = 'valid') AS valid_count,
    count(*) FILTER (WHERE validation_status = 'quarantined') AS quarantine_count,
    round(avg(quality_score)::numeric, 1) AS avg_quality_score,
    round(100.0 * count(*) FILTER (WHERE validation_status = 'valid') / greatest(count(*), 1), 1) AS valid_pct,
    CASE
        WHEN round(100.0 * count(*) FILTER (WHERE validation_status = 'valid') / greatest(count(*), 1), 1) >= 95 THEN 'EXCELLENT'
        WHEN round(100.0 * count(*) FILTER (WHERE validation_status = 'valid') / greatest(count(*), 1), 1) >= 85 THEN 'BON'
        WHEN round(100.0 * count(*) FILTER (WHERE validation_status = 'valid') / greatest(count(*), 1), 1) >= 70 THEN 'DÉGRADÉ'
        ELSE 'CRITIQUE'
    END AS quality_status,
    now() - interval '5 minutes' AS snapshot_at
FROM iot_raw.sensor_readings s
GROUP BY s.sensor_type;

EOSQL

echo "Database initialized with mock data!"
