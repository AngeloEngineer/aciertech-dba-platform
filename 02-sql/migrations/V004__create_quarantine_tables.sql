-- =============================================================================
-- AcierTech Industries — Migration V004
-- Objet    : Tables du schéma iot_quarantine (données rejetées + log anomalies)
-- =============================================================================
-- RÔLE OPÉRATIONNEL DE CE SCHÉMA :
--
-- Les 12% de données aberrantes identifiés dans l'infrastructure initiale
-- atterrissent ici plutôt que d'être silencieusement supprimées.
-- Avantages :
--   1. Traçabilité complète : on sait pourquoi chaque mesure a été rejetée
--   2. Recalibrage capteurs : pattern de rejet → capteur défaillant identifiable
--   3. Audit DBA : preuve que le pipeline fonctionne (pas de donnée perdue)
--   4. Rétroaction : une donnée quarantinée peut être corrigée manuellement
--      et réinjectée dans iot_clean si le rejet était un faux positif
--
-- NETTOYAGE : les données quarantinées sont conservées 90 jours puis
-- archivées/supprimées par la tâche de maintenance (maintenance/pg_cron_jobs.sql)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table principale de quarantaine
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iot_quarantine.rejected_readings (
    id                  BIGSERIAL       PRIMARY KEY,
    original_id         BIGINT          NOT NULL,   -- référence iot_raw.sensor_readings.id
    sensor_id           SMALLINT,
    sensor_type         VARCHAR(20),
    raw_value           NUMERIC(12, 4),
    unit                VARCHAR(10),
    recorded_at         TIMESTAMPTZ,
    rejected_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    quality_score       SMALLINT        NOT NULL,
    rejection_reason    TEXT            NOT NULL,   -- codes séparés par ';'

    -- État de révision humaine
    reviewed            BOOLEAN         NOT NULL DEFAULT FALSE,
    reviewed_by         TEXT            DEFAULT NULL,
    reviewed_at         TIMESTAMPTZ     DEFAULT NULL,
    review_action       VARCHAR(20)     DEFAULT NULL,

    CONSTRAINT chk_quarantine_quality_max
        CHECK (quality_score < 70),   -- cohérence : seules les données non-clean ici

    CONSTRAINT chk_quarantine_review_action
        CHECK (review_action IS NULL
               OR review_action IN ('confirmed_reject', 'reinject', 'recalibrate_sensor'))
);

COMMENT ON TABLE iot_quarantine.rejected_readings IS
    'Données IoT rejetées par le pipeline de validation (score qualité < 70/100). '
    'Conservées 90 jours pour audit et recalibrage des capteurs défaillants. '
    'rejection_reason contient les codes d''anomalie séparés par '';'' '
    '(ex: ZSCORE_OUTLIER;WARN_MAX). '
    'reviewed=TRUE indique qu''un DBA a examiné et statué sur la ligne.';

COMMENT ON COLUMN iot_quarantine.rejected_readings.rejection_reason IS
    'Codes de rejet concaténés, générés par fn_compute_quality_score(). '
    'Codes possibles : CRITICAL_MIN_BREACH, CRITICAL_MAX_BREACH, '
    'ZSCORE_OUTLIER(z=X.XX), WARN_MIN, WARN_MAX, TIMESTAMP_DRIFT. '
    'Plusieurs codes possibles pour une même mesure.';

COMMENT ON COLUMN iot_quarantine.rejected_readings.review_action IS
    'Action décidée après révision humaine : '
    'confirmed_reject = rejet confirmé (donnée réellement aberrante), '
    'reinject = réinjection dans iot_clean (faux positif du pipeline), '
    'recalibrate_sensor = alerte maintenance capteur nécessaire.';

-- -----------------------------------------------------------------------------
-- Table de log des anomalies détectées par le pipeline
-- Grain plus fin que rejected_readings : une mesure peut générer
-- plusieurs entrées ici (une par type d'anomalie détecté)
-- Utilisée pour les dashboards Grafana et les alertes Prometheus
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iot_quarantine.anomaly_log (
    id              BIGSERIAL       PRIMARY KEY,
    sensor_id       SMALLINT        NOT NULL,
    sensor_type     VARCHAR(20)     NOT NULL,
    anomaly_type    VARCHAR(50)     NOT NULL,
    severity        VARCHAR(10)     NOT NULL,
    raw_value       NUMERIC(12, 4),
    threshold_value NUMERIC(12, 4), -- seuil qui a été dépassé
    zscore          NUMERIC(6, 3),  -- z-score calculé (si anomalie statistique)
    occurred_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    original_id     BIGINT          NOT NULL, -- référence iot_raw

    CONSTRAINT chk_anomaly_type_known
        CHECK (anomaly_type IN (
            'CRITICAL_MIN_BREACH',
            'CRITICAL_MAX_BREACH',
            'WARN_MIN',
            'WARN_MAX',
            'ZSCORE_OUTLIER',
            'TIMESTAMP_DRIFT',
            'MISSING_THRESHOLD_CONFIG'
        )),

    CONSTRAINT chk_anomaly_severity
        CHECK (severity IN ('warning', 'critical'))
);

COMMENT ON TABLE iot_quarantine.anomaly_log IS
    'Log détaillé des anomalies détectées, une entrée par type d''anomalie. '
    'Alimenté par fn_compute_quality_score() via le trigger de validation. '
    'Source pour les dashboards Grafana (panel Data Quality) et les '
    'alertes Prometheus via postgres_exporter custom queries. '
    'Nettoyage automatique : lignes > 30 jours supprimées par pg_cron.';