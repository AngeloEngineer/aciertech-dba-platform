-- =============================================================================
-- AcierTech Industries — Migration V005
-- Objet    : Tables du schéma dba_schema (administration et référentiel DBA)
-- =============================================================================
-- NOTE : dba_schema.migration_history a déjà été créée par
-- 02-sql/init/01_run_migrations.sh (bootstrap nécessaire).
-- Ce fichier crée les autres tables d'administration.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table de référence des seuils opérationnels par capteur
-- Source de vérité pour le trigger de validation et le scoring qualité
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dba_schema.sensor_thresholds (
    sensor_id           SMALLINT        NOT NULL,
    sensor_type         VARCHAR(20)     NOT NULL,
    sensor_name         VARCHAR(100)    NOT NULL,   -- libellé humain lisible
    location            VARCHAR(100),               -- localisation physique dans l'usine
    unit                VARCHAR(10)     NOT NULL,

    -- Seuils opérationnels (alertes métier, pas limites physiques absolues)
    warn_min            NUMERIC(12, 4),
    warn_max            NUMERIC(12, 4),
    critical_min        NUMERIC(12, 4),
    critical_max        NUMERIC(12, 4),

    -- Facteur de détection statistique (multiple d'écart-type)
    -- 3.0 = règle 3-sigma (0.3% de faux positifs attendus)
    zscore_threshold    NUMERIC(4, 2)   NOT NULL DEFAULT 3.0,

    -- Fréquence d'envoi attendue du capteur (pour détecter les capteurs silencieux)
    expected_interval_s INTEGER         NOT NULL DEFAULT 60,

    -- Statut opérationnel
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    calibrated_at       DATE,
    notes               TEXT,

    -- Métadonnées
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    PRIMARY KEY (sensor_id, sensor_type),

    CONSTRAINT chk_thresholds_warn_coherence
        CHECK (warn_min IS NULL OR warn_max IS NULL OR warn_min < warn_max),

    CONSTRAINT chk_thresholds_critical_coherence
        CHECK (critical_min IS NULL OR critical_max IS NULL OR critical_min < critical_max),

    CONSTRAINT chk_thresholds_warn_inside_critical
        CHECK (
            warn_min IS NULL OR critical_min IS NULL OR warn_min >= critical_min
        ),

    CONSTRAINT chk_thresholds_zscore_positive
        CHECK (zscore_threshold > 0),

    CONSTRAINT chk_thresholds_interval_positive
        CHECK (expected_interval_s > 0 AND expected_interval_s <= 86400),

    CONSTRAINT chk_thresholds_sensor_type
        CHECK (sensor_type IN (
            'temperature', 'pressure', 'vibration',
            'current', 'flow', 'speed', 'thickness', 'weight'
        ))
);

COMMENT ON TABLE dba_schema.sensor_thresholds IS
    'Référentiel des seuils opérationnels pour les 47 capteurs IoT. '
    'Alimenté par V008__seed_thresholds.sql. Consulté par fn_compute_quality_score() '
    'lors de chaque validation. Mise à jour par le DBA lors des recalibrages. '
    'CRITIQUE : un capteur sans entrée ici reçoit le code MISSING_THRESHOLD_CONFIG '
    'et un score de 50 (dégradé mais pas rejeté pour éviter la perte de données).';

-- Trigger pour maintenir updated_at à jour
CREATE OR REPLACE FUNCTION dba_schema.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sensor_thresholds_updated_at
    BEFORE UPDATE ON dba_schema.sensor_thresholds
    FOR EACH ROW
    EXECUTE FUNCTION dba_schema.set_updated_at();

-- -----------------------------------------------------------------------------
-- Table d'historique des sauvegardes pgBackRest
-- Alimentée par le script 03-backup/scripts/verify_backup.sh
-- via INSERT direct (rôle postgres) ou via pushgateway Prometheus
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dba_schema.backup_history (
    id              SERIAL          PRIMARY KEY,
    backup_label    VARCHAR(100),
    backup_type     VARCHAR(10)     NOT NULL,
    stanza          VARCHAR(50)     NOT NULL DEFAULT 'aciertech',
    status          VARCHAR(20)     NOT NULL,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    duration_s      INTEGER,
    size_bytes      BIGINT,
    wal_start       VARCHAR(50),
    wal_stop        VARCHAR(50),
    verify_status   VARCHAR(20)     DEFAULT 'not_verified',
    verify_at       TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_backup_type
        CHECK (backup_type IN ('full', 'diff', 'incr', 'verify', 'restore_test')),

    CONSTRAINT chk_backup_status
        CHECK (status IN ('running', 'success', 'failed', 'expired')),

    CONSTRAINT chk_backup_verify_status
        CHECK (verify_status IN ('not_verified', 'success', 'failed', 'partial'))
);

COMMENT ON TABLE dba_schema.backup_history IS
    'Historique des sauvegardes pgBackRest (full, diff, verify, restore_test). '
    'Alimenté par 03-backup/scripts/verify_backup.sh. '
    'Consulté par le dashboard Grafana PRA et la console DBA. '
    'L''alerte Prometheus BackupTooOld compare NOW() - MAX(completed_at) '
    'WHERE backup_type=''full'' AND status=''success''.';

-- -----------------------------------------------------------------------------
-- Table d'agrégation de la qualité des données (snapshot toutes les 5 minutes)
-- Permet d'afficher des tendances sans requête lourde sur iot_raw
-- Alimentée par fn_compute_quality_snapshot() via pg_cron
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dba_schema.data_quality_snapshots (
    id              BIGSERIAL       PRIMARY KEY,
    snapshot_at     TIMESTAMPTZ     NOT NULL DEFAULT DATE_TRUNC('minute', NOW()),
    sensor_type     VARCHAR(20)     NOT NULL,
    window_minutes  SMALLINT        NOT NULL DEFAULT 5,
    total_received  INTEGER         NOT NULL DEFAULT 0,
    valid_count     INTEGER         NOT NULL DEFAULT 0,
    quarantine_count INTEGER        NOT NULL DEFAULT 0,
    avg_quality_score NUMERIC(5,2),
    valid_pct       NUMERIC(5, 2),
    quality_status  VARCHAR(15)     NOT NULL DEFAULT 'UNKNOWN',

    CONSTRAINT chk_snapshot_sensor_type
        CHECK (sensor_type IN (
            'temperature', 'pressure', 'vibration',
            'current', 'flow', 'speed', 'thickness', 'weight', 'ALL'
        )),

    CONSTRAINT chk_snapshot_quality_status
        CHECK (quality_status IN ('EXCELLENT', 'BON', 'DÉGRADÉ', 'CRITIQUE', 'UNKNOWN')),

    CONSTRAINT chk_snapshot_pct_range
        CHECK (valid_pct IS NULL OR valid_pct BETWEEN 0 AND 100),

    -- Évite les doublons de snapshot pour le même créneau et le même type
    CONSTRAINT uq_snapshot_time_type
        UNIQUE (snapshot_at, sensor_type, window_minutes)
);

COMMENT ON TABLE dba_schema.data_quality_snapshots IS
    'Snapshots de qualité des données agrégés par tranche de 5 minutes et '
    'par type de capteur. Alimenté par fn_compute_quality_snapshot() via pg_cron. '
    'Permet aux dashboards Grafana d''afficher les tendances sur 24h/7j '
    'sans scanner iot_raw (qui peut contenir des millions de lignes). '
    'Rétention : 30 jours (nettoyage via pg_cron).';

-- -----------------------------------------------------------------------------
-- Table de registre des capteurs actifs
-- Source de vérité pour le monitoring "capteur silencieux"
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dba_schema.sensor_registry (
    sensor_id           SMALLINT        PRIMARY KEY,
    sensor_name         VARCHAR(100)    NOT NULL,
    sensor_type         VARCHAR(20)     NOT NULL,
    location_zone       VARCHAR(50),
    location_detail     VARCHAR(100),
    manufacturer        VARCHAR(50),
    model               VARCHAR(50),
    serial_number       VARCHAR(50),
    installed_at        DATE,
    last_calibration    DATE,
    next_calibration    DATE,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    notes               TEXT,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_registry_sensor_type
        CHECK (sensor_type IN (
            'temperature', 'pressure', 'vibration',
            'current', 'flow', 'speed', 'thickness', 'weight'
        ))
);

COMMENT ON TABLE dba_schema.sensor_registry IS
    'Registre physique des 47 capteurs IoT de l''usine. '
    'Référence pour le monitoring des capteurs silencieux (absence de données). '
    'La vue v_silent_sensors joint cette table avec iot_raw.sensor_readings '
    'pour détecter les capteurs qui n''ont pas émis depuis leur expected_interval_s.';