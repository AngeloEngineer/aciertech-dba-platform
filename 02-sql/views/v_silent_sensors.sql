-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/views/v_silent_sensors.sql
-- OBJET     : Détection des capteurs silencieux (aucune donnée reçue depuis trop longtemps)
-- DÉPEND DE : dba_schema.sensor_registry (V005),
--             dba_schema.sensor_thresholds (V005 — expected_interval_s),
--             iot_raw.sensor_readings (V002)
-- CONSOMMÉE : 04-monitoring/ (alertes PagerDuty/Grafana), 05-webapp/ (dashboard)
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- LOGIQUE DE DÉTECTION
-- ────────────────────
--   Un capteur est dit "silencieux" si :
--     NOW() - dernière_mesure_reçue > expected_interval_s * silence_tolerance_factor
--
--   silence_tolerance_factor = 3 (par défaut) :
--     → On tolère 3 intervalles manqués avant d'alerter.
--     → Ex : capteur vibration toutes 30s → alerte si silence > 90s
--     → Évite les faux positifs sur micro-coupures réseau IoT normales.
--
--   Un capteur qui n'a JAMAIS émis depuis l'activation de la base est aussi détecté
--   (last_reading_at IS NULL + is_active = TRUE).
--
-- COLONNES CLÉS
-- ─────────────
--   • silence_duration      : durée depuis la dernière mesure (INTERVAL)
--   • silence_seconds       : idem en secondes (pour seuils Grafana)
--   • expected_interval_s   : fréquence attendue depuis sensor_thresholds
--   • silence_ratio         : silence_seconds / expected_interval_s
--                             (1.0 = exactement 1 intervalle manqué)
--   • alert_level           : WARNING / CRITICAL / NEVER_SEEN
--   • sensor_location       : localisation physique (depuis sensor_registry)
--
-- CAS PARTICULIERS
-- ────────────────
--   - Capteur sans threshold configuré : expected_interval_s NULL →
--     on utilise une valeur par défaut de 300s (5 min) pour ne pas masquer le silence.
--   - Capteur is_active = FALSE : exclu de la vue (maintenance planifiée).
-- =============================================================================

CREATE OR REPLACE VIEW dba_schema.v_silent_sensors AS
WITH

-- Dernière mesure reçue par capteur (tous statuts confondus : valid/quarantined/error)
last_seen AS (
    SELECT
        sensor_id,
        MAX(recorded_at)    AS last_reading_at,
        COUNT(*)            AS total_readings_ever
    FROM iot_raw.sensor_readings
    GROUP BY sensor_id
),

-- Jointure capteur + seuil + dernière mesure
sensor_status AS (
    SELECT
        reg.sensor_id,
        reg.sensor_name,
        reg.sensor_type,
        reg.location                                    AS sensor_location,
        reg.installation_date,
        reg.is_active,

        -- Intervalle attendu (fallback 300s si non configuré)
        COALESCE(thr.expected_interval_s, 300)          AS expected_interval_s,
        thr.unit                                        AS measurement_unit,

        -- Dernière activité
        ls.last_reading_at,
        COALESCE(ls.total_readings_ever, 0)             AS total_readings_ever,

        -- Durée du silence
        CASE
            WHEN ls.last_reading_at IS NULL THEN NULL   -- jamais émis
            ELSE NOW() - ls.last_reading_at
        END                                             AS silence_duration,

        CASE
            WHEN ls.last_reading_at IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (NOW() - ls.last_reading_at))
        END                                             AS silence_seconds

    FROM dba_schema.sensor_registry reg
    LEFT JOIN dba_schema.sensor_thresholds thr USING (sensor_id)
    LEFT JOIN last_seen ls USING (sensor_id)
    WHERE reg.is_active = TRUE      -- on exclut les capteurs en maintenance
),

-- Tolérance : on n'alerte qu'après 3 intervalles manqués
silence_tolerance_factor AS (
    SELECT 3 AS factor
)

SELECT
    s.sensor_id,
    s.sensor_name,
    s.sensor_type,
    s.sensor_location,
    s.installation_date,

    -- Intervalle de référence
    s.expected_interval_s,
    s.measurement_unit,

    -- Dernière activité
    s.last_reading_at,
    s.total_readings_ever,

    -- Durée du silence
    s.silence_duration,
    ROUND(s.silence_seconds::NUMERIC, 0)::INTEGER       AS silence_seconds,

    -- Ratio silence / intervalle (combien d'intervalles ont été manqués)
    CASE
        WHEN s.silence_seconds IS NULL THEN NULL
        ELSE ROUND(
            (s.silence_seconds / s.expected_interval_s)::NUMERIC,
            2
        )
    END                                                 AS silence_ratio,

    -- Seuil d'alerte effectif (en secondes)
    s.expected_interval_s * stf.factor                  AS alert_threshold_seconds,

    -- Niveau d'alerte
    CASE
        WHEN s.last_reading_at IS NULL
            THEN 'NEVER_SEEN'       -- capteur actif mais n'a jamais émis
        WHEN s.silence_seconds > s.expected_interval_s * stf.factor * 2
            THEN 'CRITICAL'         -- silence > 6x l'intervalle → probable panne matérielle
        WHEN s.silence_seconds > s.expected_interval_s * stf.factor
            THEN 'WARNING'          -- silence > 3x l'intervalle → investigation requise
        ELSE NULL                   -- NULL = capteur vivant (exclu du résultat final)
    END                                                 AS alert_level,

    NOW()                                               AS checked_at

FROM sensor_status s
CROSS JOIN silence_tolerance_factor stf

-- On ne retourne que les capteurs effectivement silencieux ou jamais vus
WHERE
    -- Jamais émis
    s.last_reading_at IS NULL
    OR
    -- Silence dépassant le seuil de tolérance (3x expected_interval_s)
    s.silence_seconds > s.expected_interval_s * stf.factor

ORDER BY
    -- Priorité : NEVER_SEEN puis CRITICAL puis WARNING,
    -- puis silence_ratio décroissant (les plus silencieux d'abord)
    CASE
        WHEN s.last_reading_at IS NULL                                              THEN 1
        WHEN s.silence_seconds > s.expected_interval_s * stf.factor * 2            THEN 2
        ELSE 3
    END,
    silence_ratio DESC NULLS LAST,
    s.sensor_type,
    s.sensor_id;

-- Droits
GRANT SELECT ON dba_schema.v_silent_sensors TO aciertech_ro;
REVOKE ALL    ON dba_schema.v_silent_sensors FROM PUBLIC;

COMMENT ON VIEW dba_schema.v_silent_sensors IS
'Détecte les capteurs IoT actifs sans émission depuis plus de 3×expected_interval_s.
Niveaux : NEVER_SEEN (jamais émis), CRITICAL (>6× intervalle), WARNING (>3× intervalle).
Capteurs is_active=FALSE exclus (maintenance planifiée).
Fallback 300s si expected_interval_s NULL dans sensor_thresholds.
Consommée par 04-monitoring/ (alertes) et 05-webapp/ (dashboard opérateur).';