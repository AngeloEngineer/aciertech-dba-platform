-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/views/v_data_quality_dashboard.sql
-- OBJET     : Tableau de bord qualité IoT — agrégats par type capteur sur 1 heure
-- DÉPEND DE : iot_raw.sensor_readings (V002), dba_schema.sensor_registry (V005),
--             dba_schema.data_quality_snapshots (V005)
-- CONSOMMÉE : 05-webapp/ (dashboard opérateur), 04-monitoring/ (alertes Grafana)
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- CONTENU
-- ───────
--   Une ligne par sensor_type (7 types : temperature, pression, vibration,
--   courant, debit, vitesse, epaisseur).
--   Fenêtre glissante : [NOW() - 1h, NOW()[  sur iot_raw.sensor_readings
--
--   Colonnes clés :
--     • total_readings, valid_count, quarantined_count, error_count
--     • valid_rate_pct          : % mesures valides (0-100)
--     • avg_quality_score       : score moyen sur la fenêtre
--     • sensors_active          : capteurs ayant émis au moins 1 mesure
--     • sensors_silent          : capteurs attendus mais sans émission
--     • last_reading_at         : horodatage de la dernière mesure reçue
--     • quality_level           : label lisible (EXCELLENT/GOOD/DEGRADED/CRITICAL)
--
-- SÉCURITÉ
-- ────────
--   aciertech_ro : SELECT autorisé (dashboard lecture seule)
--   aciertech_app : pas d'accès (INSERT iot_raw seulement)
-- =============================================================================

CREATE OR REPLACE VIEW dba_schema.v_data_quality_dashboard AS
WITH

-- Fenêtre glissante 1h sur iot_raw
raw_window AS (
    SELECT
        sr.sensor_type,
        sr.sensor_id,
        sr.validation_status,
        sr.quality_score,
        sr.recorded_at
    FROM iot_raw.sensor_readings sr
    WHERE sr.recorded_at >= NOW() - INTERVAL '1 hour'
),

-- Agrégats par sensor_type
agg_by_type AS (
    SELECT
        rw.sensor_type,
        COUNT(*)                                                            AS total_readings,
        COUNT(*) FILTER (WHERE rw.validation_status = 'valid')             AS valid_count,
        COUNT(*) FILTER (WHERE rw.validation_status = 'quarantined')       AS quarantined_count,
        COUNT(*) FILTER (WHERE rw.validation_status = 'error')             AS error_count,
        ROUND(AVG(rw.quality_score)::NUMERIC, 2)                           AS avg_quality_score,
        MIN(rw.quality_score)                                               AS min_quality_score,
        COUNT(DISTINCT rw.sensor_id)                                        AS sensors_active,
        MAX(rw.recorded_at)                                                 AS last_reading_at
    FROM raw_window rw
    GROUP BY rw.sensor_type
),

-- Référentiel des capteurs attendus par type (depuis sensor_registry)
expected_by_type AS (
    SELECT
        sensor_type,
        COUNT(*) FILTER (WHERE is_active = TRUE)  AS sensors_expected
    FROM dba_schema.sensor_registry
    GROUP BY sensor_type
)

SELECT
    -- Identification
    COALESCE(exp.sensor_type, agg.sensor_type)          AS sensor_type,
    COALESCE(exp.sensors_expected, 0)                   AS sensors_expected,
    COALESCE(agg.sensors_active,   0)                   AS sensors_active,

    -- Capteurs silencieux : attendus mais sans émission dans la fenêtre
    GREATEST(
        COALESCE(exp.sensors_expected, 0)
        - COALESCE(agg.sensors_active, 0),
        0
    )                                                   AS sensors_silent,

    -- Compteurs de mesures
    COALESCE(agg.total_readings,    0)                  AS total_readings,
    COALESCE(agg.valid_count,       0)                  AS valid_count,
    COALESCE(agg.quarantined_count, 0)                  AS quarantined_count,
    COALESCE(agg.error_count,       0)                  AS error_count,

    -- Taux de validité (NULL si aucune mesure → pas de 0% trompeur)
    CASE
        WHEN COALESCE(agg.total_readings, 0) = 0 THEN NULL
        ELSE ROUND(
            (agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100,
            2
        )
    END                                                 AS valid_rate_pct,

    -- Scores
    agg.avg_quality_score,
    agg.min_quality_score,

    -- Dernière mesure reçue
    agg.last_reading_at,

    -- Âge de la dernière mesure (lisible pour le dashboard)
    CASE
        WHEN agg.last_reading_at IS NULL THEN NULL
        ELSE NOW() - agg.last_reading_at
    END                                                 AS time_since_last_reading,

    -- Label de qualité globale pour coloration du dashboard
    CASE
        WHEN COALESCE(agg.total_readings, 0) = 0
            THEN 'NO_DATA'
        WHEN ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2) >= 95
            THEN 'EXCELLENT'
        WHEN ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2) >= 80
            THEN 'GOOD'
        WHEN ROUND((agg.valid_count::NUMERIC / agg.total_readings::NUMERIC) * 100, 2) >= 60
            THEN 'DEGRADED'
        ELSE 'CRITICAL'
    END                                                 AS quality_level,

    -- Horodatage de calcul (pour cache-busting côté webapp)
    NOW()                                               AS computed_at

FROM expected_by_type exp
FULL OUTER JOIN agg_by_type agg
    ON exp.sensor_type = agg.sensor_type
ORDER BY
    -- Afficher d'abord les types les plus critiques
    CASE
        WHEN COALESCE(agg.total_readings, 0) = 0 THEN 1
        WHEN ROUND((agg.valid_count::NUMERIC / NULLIF(agg.total_readings, 0)::NUMERIC) * 100, 2) < 60 THEN 2
        WHEN ROUND((agg.valid_count::NUMERIC / NULLIF(agg.total_readings, 0)::NUMERIC) * 100, 2) < 80 THEN 3
        ELSE 4
    END,
    COALESCE(exp.sensor_type, agg.sensor_type);

-- Droits
GRANT SELECT ON dba_schema.v_data_quality_dashboard TO aciertech_ro;
REVOKE ALL    ON dba_schema.v_data_quality_dashboard FROM PUBLIC;

COMMENT ON VIEW dba_schema.v_data_quality_dashboard IS
'Tableau de bord qualité IoT : agrégats par sensor_type sur fenêtre glissante 1h.
Indique sensors_silent (capteurs attendus sans émission), valid_rate_pct,
avg_quality_score et quality_level (EXCELLENT/GOOD/DEGRADED/CRITICAL/NO_DATA).
Consommée par la webapp (05-webapp/) et Grafana (04-monitoring/).';