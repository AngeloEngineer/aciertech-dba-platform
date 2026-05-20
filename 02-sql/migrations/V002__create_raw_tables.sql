-- =============================================================================
-- AcierTech Industries — Migration V002
-- Objet    : Tables du schéma iot_raw (réception brute capteurs IoT)
-- =============================================================================
-- DÉCISIONS DE CONCEPTION :
--
-- 1. Les contraintes CHECK ici sont des LIMITES PHYSIQUES ABSOLUES
--    (valeurs physiquement impossibles → rejet immédiat avant trigger).
--    Les seuils opérationnels (warn/critical) vivent dans dba_schema.sensor_thresholds.
--
-- 2. PAS de FK vers dba_schema.sensor_thresholds sur cette table.
--    Raison : avec synchronous_commit=on, chaque INSERT attend la confirmation
--    du réplica. Ajouter un lookup FK sur chaque ligne capteur multiplierait
--    les round-trips. Le trigger fait ce lookup en mémoire avec un cache local.
--
-- 3. validation_status DEFAULT 'pending' → mis à jour atomiquement par le trigger
--    dans la même transaction (compatible pool_mode=transaction).
--
-- 4. Colonne received_at séparée de recorded_at pour détecter les décalages
--    réseau/horloge des capteurs (fréquent sur IoT industriel).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table principale de réception des mesures IoT
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iot_raw.sensor_readings (
    id                  BIGSERIAL       PRIMARY KEY,
    sensor_id           SMALLINT        NOT NULL,
    sensor_type         VARCHAR(20)     NOT NULL,
    value               NUMERIC(12, 4)  NOT NULL,
    unit                VARCHAR(10)     NOT NULL,
    recorded_at         TIMESTAMPTZ     NOT NULL,
    received_at         TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    quality_score       SMALLINT        DEFAULT NULL,
    validation_status   VARCHAR(15)     NOT NULL DEFAULT 'pending',
    rejection_reason    TEXT            DEFAULT NULL,

    -- -------------------------------------------------------------------------
    -- Contraintes de domaine : valeurs
    -- -------------------------------------------------------------------------
    CONSTRAINT chk_raw_sensor_id_positive
        CHECK (sensor_id BETWEEN 1 AND 200),

    CONSTRAINT chk_raw_sensor_type_known
        CHECK (sensor_type IN (
            'temperature', 'pressure', 'vibration',
            'current', 'flow', 'speed', 'thickness', 'weight'
        )),

    CONSTRAINT chk_raw_validation_status
        CHECK (validation_status IN ('pending', 'valid', 'quarantined')),

    CONSTRAINT chk_raw_quality_score_range
        CHECK (quality_score IS NULL OR quality_score BETWEEN 0 AND 100),

    -- -------------------------------------------------------------------------
    -- Limites physiques absolues par type de capteur
    -- Ces valeurs sont physiquement impossibles dans une aciérie →
    -- rejet sans même consulter les seuils opérationnels.
    -- Un capteur retournant 9999°C est défaillant, pas dangereux.
    -- -------------------------------------------------------------------------

    -- Température : -273°C (zéro absolu) à 3500°C (point fusion tungstène)
    -- En pratique aciérie : jamais < -50 ni > 2500
    CONSTRAINT chk_raw_temperature_absolute
        CHECK (sensor_type <> 'temperature'
               OR value BETWEEN -50 AND 2500),

    -- Pression : ne peut pas être négative, max 700 bar (presse industrielle max)
    CONSTRAINT chk_raw_pressure_absolute
        CHECK (sensor_type <> 'pressure'
               OR value BETWEEN 0 AND 700),

    -- Vibration : toujours positive, max 500 mm/s (ISO 10816 : arrêt machine > 45)
    CONSTRAINT chk_raw_vibration_absolute
        CHECK (sensor_type <> 'vibration'
               OR value BETWEEN 0 AND 500),

    -- Courant électrique : toujours positif, max 15000 A (transformateur industriel)
    CONSTRAINT chk_raw_current_absolute
        CHECK (sensor_type <> 'current'
               OR value BETWEEN 0 AND 15000),

    -- Débit : toujours positif, max 10000 L/min
    CONSTRAINT chk_raw_flow_absolute
        CHECK (sensor_type <> 'flow'
               OR value BETWEEN 0 AND 10000),

    -- Vitesse rotation : toujours positive, max 20000 tr/min
    CONSTRAINT chk_raw_speed_absolute
        CHECK (sensor_type <> 'speed'
               OR value BETWEEN 0 AND 20000),

    -- Épaisseur : positive, max 600 mm (produit sidérurgique épais)
    CONSTRAINT chk_raw_thickness_absolute
        CHECK (sensor_type <> 'thickness'
               OR value BETWEEN 0 AND 600),

    -- Poids : positif, max 500000 kg (bobine acier max ~30t, structure 500t)
    CONSTRAINT chk_raw_weight_absolute
        CHECK (sensor_type <> 'weight'
               OR value BETWEEN 0 AND 500000),

    -- -------------------------------------------------------------------------
    -- Contraintes temporelles
    -- -------------------------------------------------------------------------

    -- Refus des timestamps dans le futur (tolérance 2 min pour décalage NTP)
    CONSTRAINT chk_raw_timestamp_not_future
        CHECK (recorded_at <= NOW() + INTERVAL '2 minutes'),

    -- Refus des données trop anciennes (avant le démarrage du projet)
    CONSTRAINT chk_raw_timestamp_not_ancient
        CHECK (recorded_at >= TIMESTAMPTZ '2024-01-01 00:00:00+00'),

    -- Cohérence : received_at ne peut pas précéder recorded_at de plus de 10 min
    -- (détecte les capteurs avec horloge déréglée dans l'autre sens)
    CONSTRAINT chk_raw_received_after_recorded
        CHECK (received_at >= recorded_at - INTERVAL '10 minutes')
);

COMMENT ON TABLE iot_raw.sensor_readings IS
    'Point d''entrée unique de toutes les mesures des 47 capteurs IoT. '
    'Le trigger trg_validate_sensor route chaque ligne vers iot_clean '
    'ou iot_quarantine selon le score de qualité calculé. '
    'Ne jamais lire directement pour alimenter l''IA — utiliser iot_clean.';

COMMENT ON COLUMN iot_raw.sensor_readings.quality_score IS
    'Score 0-100 calculé par fn_compute_quality_score(). '
    'NULL = trigger pas encore exécuté (état transitoire). '
    'Seuil de routage : ≥70 → clean, <70 → quarantine.';

COMMENT ON COLUMN iot_raw.sensor_readings.received_at IS
    'Horodatage d''arrivée dans PostgreSQL. Différence avec recorded_at '
    'permet de détecter les latences réseau et dérives d''horloge capteurs.';

-- -----------------------------------------------------------------------------
-- Table de log des événements d'ingestion (erreurs de format, rejets CHECK)
-- Alimentée par le gestionnaire d'exceptions du trigger
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS iot_raw.ingestion_errors (
    id              BIGSERIAL       PRIMARY KEY,
    sensor_id       SMALLINT,
    sensor_type     VARCHAR(20),
    raw_payload     TEXT,           -- payload brut JSON si disponible
    error_type      VARCHAR(50)     NOT NULL,
    error_message   TEXT            NOT NULL,
    occurred_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    resolved        BOOLEAN         NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE iot_raw.ingestion_errors IS
    'Erreurs d''ingestion qui ne passent pas les CHECK de la table principale '
    '(violences de contraintes physiques absolues, types inconnus...). '
    'Ces lignes ne passent même pas par le trigger.';