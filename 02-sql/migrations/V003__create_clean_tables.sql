
-- =============================================================================
-- AcierTech Industries — Migration V003
-- Objet    : Tables du schéma iot_clean (données validées → alimentation IA)
-- =============================================================================
-- Ces tables ne reçoivent jamais d'INSERT direct applicatif.
-- Seul le trigger iot_raw.trg_validate_sensor y écrit, dans la même
-- transaction que l'INSERT dans iot_raw.sensor_readings.
-- Compatibilité pool_mode=transaction : OK (même transaction, même connexion).
-- =============================================================================
 
-- -----------------------------------------------------------------------------
-- Table des mesures validées — source unique pour le système IA
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iot_clean.sensor_readings (
    id              BIGSERIAL       PRIMARY KEY,
    original_id     BIGINT          NOT NULL,   -- référence iot_raw (sans FK pour perf)
    sensor_id       SMALLINT        NOT NULL,
    sensor_type     VARCHAR(20)     NOT NULL,
    value           NUMERIC(12, 4)  NOT NULL,
    unit            VARCHAR(10)     NOT NULL,
    recorded_at     TIMESTAMPTZ     NOT NULL,
    validated_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    quality_score   SMALLINT        NOT NULL,
 
    -- Sécurité : pas d'écritures directes possibles par les rôles applicatifs
    -- (contrôlé par les GRANT dans V007)
 
    CONSTRAINT chk_clean_quality_minimum
        CHECK (quality_score >= 70),   -- seules les données clean arrivent ici
 
    CONSTRAINT chk_clean_sensor_type
        CHECK (sensor_type IN (
            'temperature', 'pressure', 'vibration',
            'current', 'flow', 'speed', 'thickness', 'weight'
        )),
 
    CONSTRAINT chk_clean_sensor_id_positive
        CHECK (sensor_id BETWEEN 1 AND 200)
);
 
COMMENT ON TABLE iot_clean.sensor_readings IS
    'Données IoT validées par le pipeline de qualité (score ≥ 70/100). '
    'Source unique pour la vue matérialisée v_ai_feature_set qui alimente '
    'le système IA. Alimentée exclusivement par le trigger de validation. '
    'original_id permet de retrouver la ligne brute dans iot_raw en cas de doute.';
 
COMMENT ON COLUMN iot_clean.sensor_readings.original_id IS
    'ID de la ligne correspondante dans iot_raw.sensor_readings. '
    'Pas de FK déclarée intentionnellement (évite verrous partagés sur '
    'une table à fort taux d''écriture avec synchronous_commit=on). '
    'Jointure possible mais pas contrainte.';
 
-- -----------------------------------------------------------------------------
-- Vue matérialisée d'agrégation pour le système IA
-- Rafraîchie toutes les 5 minutes par fn_refresh_ai_view() (pg_cron ou worker)
-- Fenêtre : 24 dernières heures, agrégation par minute et par capteur
-- -----------------------------------------------------------------------------
-- NOTE : création ici en EMPTY (WITH NO DATA) pour que les index V006
-- puissent être créés dessus. Le premier REFRESH sera déclenché par
-- le script de démarrage ou pg_cron.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS iot_clean.v_ai_feature_set AS
SELECT
    sensor_id,
    sensor_type,
    DATE_TRUNC('minute', recorded_at)           AS time_bucket,
    AVG(value)                                  AS avg_value,
    MIN(value)                                  AS min_value,
    MAX(value)                                  AS max_value,
    STDDEV(value)                               AS stddev_value,
    COUNT(*)                                    AS sample_count,
    AVG(quality_score)::SMALLINT                AS avg_quality_score,
    MIN(recorded_at)                            AS window_start,
    MAX(recorded_at)                            AS window_end
FROM iot_clean.sensor_readings
WHERE recorded_at >= NOW() - INTERVAL '24 hours'
GROUP BY
    sensor_id,
    sensor_type,
    DATE_TRUNC('minute', recorded_at)
WITH NO DATA;
 
COMMENT ON MATERIALIZED VIEW iot_clean.v_ai_feature_set IS
    'Feature set agrégé par minute pour le système IA de maintenance prédictive. '
    'Fenêtre glissante 24h. Rafraîchissement : toutes les 5 minutes via pg_cron '
    'ou fn_refresh_ai_view(). Accessible en lecture seule par aciertech_ro. '
    'CONCURRENT REFRESH possible grâce à l''index unique sur (sensor_id, time_bucket).';
