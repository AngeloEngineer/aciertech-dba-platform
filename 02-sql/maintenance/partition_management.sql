-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/maintenance/partition_management.sql
-- OBJET     : Stratégie de partitionnement mensuel de iot_raw.sensor_readings
-- STATUT    : OPTIONNEL / FUTUR — À appliquer quand le volume dépasse ~50M lignes
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- QUAND ACTIVER CE FICHIER ?
-- ──────────────────────────
--   Le partitionnement a un coût d'implémentation non nul (migration de données,
--   refonte des index, adaptation des triggers). Il devient rentable quand :
--
--     • iot_raw.sensor_readings dépasse ~50 millions de lignes  (~3-6 mois selon charge)
--     • Les VACUUM et ANALYZE durent > 30 minutes
--     • Les requêtes temporelles sur iot_raw (Z-score 1h, dashboards) montrent
--       des sequential scans malgré les index BRIN (voir EXPLAIN ANALYZE)
--     • La purge mensuelle des vieilles données via DELETE devient trop lente
--       (remplacée par DROP/DETACH TABLE partition = instantané)
--
-- STRATÉGIE CHOISIE : RANGE sur recorded_at, partitions MENSUELLES
-- ─────────────────────────────────────────────────────────────────
--   Alternatives considérées et écartées :
--   • HASH sur sensor_id : ne permet pas la purge temporelle par DROP partition
--   • LIST sur sensor_type : 7 valeurs seulement, partitions trop larges
--   • Partitions hebdomadaires : trop de partitions à gérer (> 52/an)
--
-- PLAN DE MIGRATION (table existante → table partitionnée)
-- ─────────────────────────────────────────────────────────
--   Ce script documente la procédure complète, exécutable en fenêtre de maintenance.
--   Durée estimée (50M lignes) : 20-45 min selon I/O disque.
--
-- COMPATIBILITÉ
-- ─────────────
--   ✓  PostgreSQL 16 (RANGE partitioning natif)
--   ✓  Patroni : le partitionnement est transparent pour la réplication physique
--   ✓  pgBouncer pool_mode=transaction : aucun impact
--   ✓  Triggers : trg_validate_sensor s'attache à la table parent et s'hérite
--      automatiquement sur les partitions en PG16
--   ✓  Index : les index sur la table parent sont recréés sur chaque partition
-- =============================================================================


-- =============================================================================
-- SECTION A : CRÉATION DE LA TABLE PARTITIONNÉE (nouvelle structure)
--
--   On crée iot_raw.sensor_readings_partitioned pendant que l'ancienne table
--   reste en production. Migration par copie + swap atomique.
-- =============================================================================

/*
-- ÉTAPE A1 : Table parent partitionnée (même structure que V002)
-- À adapter si V002 a été modifiée depuis.

CREATE TABLE IF NOT EXISTS iot_raw.sensor_readings_partitioned (
    id                BIGSERIAL,
    sensor_id         INTEGER         NOT NULL,
    sensor_type       VARCHAR(50)     NOT NULL,
    value             NUMERIC(10,4)   NOT NULL,
    unit              VARCHAR(20),
    recorded_at       TIMESTAMPTZ     NOT NULL,
    ingested_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    quality_score     SMALLINT,
    validation_status VARCHAR(20)     NOT NULL DEFAULT 'pending'
                        CHECK (validation_status IN ('pending','valid','quarantined','error')),
    raw_payload       JSONB,

    -- PK composite obligatoire pour le partitionnement RANGE
    -- (la colonne de partition doit faire partie de la PK)
    PRIMARY KEY (id, recorded_at)
)
PARTITION BY RANGE (recorded_at);

-- CHECK physiques (mêmes que V002)
ALTER TABLE iot_raw.sensor_readings_partitioned
    ADD CONSTRAINT chk_quality_score_range
        CHECK (quality_score BETWEEN 0 AND 100);
*/


-- =============================================================================
-- SECTION B : CRÉATION DES PARTITIONS MENSUELLES
--
--   Convention de nommage : sensor_readings_YYYY_MM
--   On crée N+2 mois d'avance pour éviter les écritures dans la partition default.
-- =============================================================================

/*
-- Fonction helper : crée une partition mensuelle si elle n'existe pas encore.
-- Appelée par pg_cron (JOB automatique, voir SECTION E).

CREATE OR REPLACE FUNCTION dba_schema.fn_create_monthly_partition(
    p_year  INTEGER,
    p_month INTEGER
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = iot_raw, dba_schema, pg_catalog
AS $fn$
DECLARE
    v_partition_name TEXT;
    v_start_date     DATE;
    v_end_date       DATE;
    v_sql            TEXT;
BEGIN
    v_start_date     := DATE_TRUNC('month', MAKE_DATE(p_year, p_month, 1));
    v_end_date       := v_start_date + INTERVAL '1 month';
    v_partition_name := FORMAT('sensor_readings_%s_%s',
                               TO_CHAR(v_start_date, 'YYYY'),
                               TO_CHAR(v_start_date, 'MM'));

    -- Ne rien faire si la partition existe déjà (idempotence)
    IF EXISTS (
        SELECT 1
        FROM   pg_class c
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        WHERE  n.nspname = 'iot_raw'
          AND  c.relname = v_partition_name
    ) THEN
        RAISE NOTICE 'Partition % existe déjà — skip.', v_partition_name;
        RETURN v_partition_name;
    END IF;

    v_sql := FORMAT(
        $sql$
        CREATE TABLE iot_raw.%I
            PARTITION OF iot_raw.sensor_readings_partitioned
            FOR VALUES FROM (%L) TO (%L);
        $sql$,
        v_partition_name,
        v_start_date::TIMESTAMPTZ,
        v_end_date::TIMESTAMPTZ
    );

    EXECUTE v_sql;

    -- Index BRIN sur recorded_at (hérité du parent, mais on le force explicitement
    -- pour contrôler les paramètres pages_per_range)
    EXECUTE FORMAT(
        'CREATE INDEX IF NOT EXISTS %I ON iot_raw.%I
         USING BRIN (recorded_at) WITH (pages_per_range = 32);',
        'idx_' || v_partition_name || '_recorded_at_brin',
        v_partition_name
    );

    -- Index partiel sur validation_status='valid' (pour le Z-score 1h)
    EXECUTE FORMAT(
        'CREATE INDEX IF NOT EXISTS %I ON iot_raw.%I (sensor_id, recorded_at)
         WHERE validation_status = ''valid'';',
        'idx_' || v_partition_name || '_valid',
        v_partition_name
    );

    RAISE NOTICE 'Partition % créée : [%, %[', v_partition_name, v_start_date, v_end_date;
    RETURN v_partition_name;
END;
$fn$;


-- Création des partitions initiales : mois en cours + 2 mois suivants
-- (À exécuter manuellement lors de la migration)
SELECT dba_schema.fn_create_monthly_partition(
    EXTRACT(YEAR  FROM NOW())::INTEGER,
    EXTRACT(MONTH FROM NOW())::INTEGER
);

SELECT dba_schema.fn_create_monthly_partition(
    EXTRACT(YEAR  FROM NOW() + INTERVAL '1 month')::INTEGER,
    EXTRACT(MONTH FROM NOW() + INTERVAL '1 month')::INTEGER
);

SELECT dba_schema.fn_create_monthly_partition(
    EXTRACT(YEAR  FROM NOW() + INTERVAL '2 months')::INTEGER,
    EXTRACT(MONTH FROM NOW() + INTERVAL '2 months')::INTEGER
);


-- Partition DEFAULT : absorbe tout ce qui ne rentre dans aucune partition nommée.
-- Obligatoire pour éviter les erreurs d'insertion hors-plage.
CREATE TABLE IF NOT EXISTS iot_raw.sensor_readings_default
    PARTITION OF iot_raw.sensor_readings_partitioned
    DEFAULT;
*/


-- =============================================================================
-- SECTION C : PROCÉDURE DE MIGRATION (table existante → partitionnée)
--
--   Principe : copie des données + swap des noms sous verrou court.
--   Fenêtre de maintenance recommandée : nuit (02h-04h), usine arrêtée.
-- =============================================================================

/*
-- C1 : Copie des données historiques dans la table partitionnée
--      (peut prendre 10-30 min selon volume — exécuter avant la fenêtre maintenance)
INSERT INTO iot_raw.sensor_readings_partitioned
    (id, sensor_id, sensor_type, value, unit, recorded_at,
     ingested_at, quality_score, validation_status, raw_payload)
SELECT
     id, sensor_id, sensor_type, value, unit, recorded_at,
     ingested_at, quality_score, validation_status, raw_payload
FROM iot_raw.sensor_readings
ORDER BY recorded_at;   -- ORDER BY facilite le remplissage séquentiel des partitions

-- C2 : Vérification du comptage avant swap
-- SELECT COUNT(*) FROM iot_raw.sensor_readings;
-- SELECT COUNT(*) FROM iot_raw.sensor_readings_partitioned;
-- Les deux doivent être égaux.

-- C3 : Swap atomique sous verrou exclusif (fenêtre de maintenance)
-- Durée du verrou : < 1 seconde (rename seulement)
BEGIN;
    LOCK TABLE iot_raw.sensor_readings IN ACCESS EXCLUSIVE MODE;

    -- Renommage de l'ancienne table en backup
    ALTER TABLE iot_raw.sensor_readings
        RENAME TO sensor_readings_pre_partition;

    -- La nouvelle table prend le nom officiel
    ALTER TABLE iot_raw.sensor_readings_partitioned
        RENAME TO sensor_readings;

    -- Rattachement du trigger (hérite automatiquement sur les partitions en PG16)
    -- Si le trigger a été créé sur l'ancienne table, le recréer sur la nouvelle.
    -- Voir trg_validate_sensor.sql — exécuter DROP + CREATE TRIGGER ici si besoin.
COMMIT;

-- C4 : Vérification post-swap
-- \d iot_raw.sensor_readings          → doit afficher "partitioned table"
-- SELECT COUNT(*) FROM iot_raw.sensor_readings;  → même chiffre qu'avant

-- C5 : Suppression de l'ancienne table (après validation en production, J+7 recommandé)
-- DROP TABLE iot_raw.sensor_readings_pre_partition;
*/


-- =============================================================================
-- SECTION D : DÉTACHEMENT ET ARCHIVAGE D'UNE PARTITION ANCIENNE
--
--   Remplacement du DELETE en masse par un DETACH + archive.
--   Instantané, sans verrou long, sans dead tuples.
-- =============================================================================

/*
-- Détacher la partition de janvier 2025 (exemple)
ALTER TABLE iot_raw.sensor_readings
    DETACH PARTITION iot_raw.sensor_readings_2025_01 CONCURRENTLY;
--  CONCURRENTLY : disponible PG14+, ne pose pas de verrou exclusif

-- Option 1 : Supprimer définitivement
-- DROP TABLE iot_raw.sensor_readings_2025_01;

-- Option 2 : Déplacer vers un schéma d'archive (données froides consultables)
-- ALTER TABLE iot_raw.sensor_readings_2025_01
--     SET SCHEMA archive;
-- (nécessite de créer le schéma 'archive' au préalable)
*/


-- =============================================================================
-- SECTION E : JOB pg_cron — Création automatique des partitions futures
--
--   À ajouter dans pg_cron_jobs.sql une fois le partitionnement activé.
--   Crée la partition du mois suivant le 25 de chaque mois à 01h00.
-- =============================================================================

/*
SELECT cron.unschedule('aciertech_create_next_partition')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_create_next_partition'
);

SELECT cron.schedule(
    'aciertech_create_next_partition',
    '0 1 25 * *',       -- le 25 de chaque mois à 01h00
    $$
    SELECT dba_schema.fn_create_monthly_partition(
        EXTRACT(YEAR  FROM NOW() + INTERVAL '1 month')::INTEGER,
        EXTRACT(MONTH FROM NOW() + INTERVAL '1 month')::INTEGER
    );
    $$
);
*/


-- =============================================================================
-- SECTION F : REQUÊTES DE SURVEILLANCE DES PARTITIONS
--   À exécuter manuellement pour auditer l'état du partitionnement.
-- =============================================================================

/*
-- Taille de chaque partition
SELECT
    n.nspname                               AS schema,
    c.relname                               AS partition_name,
    pg_size_pretty(pg_relation_size(c.oid)) AS size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    p.inhdetachpending                      AS detach_pending
FROM pg_class c
JOIN pg_namespace n     ON n.oid = c.relnamespace
JOIN pg_inherits i      ON i.inhrelid = c.oid
JOIN pg_class parent    ON parent.oid = i.inhparent
JOIN pg_namespace pn    ON pn.oid = parent.relnamespace
LEFT JOIN pg_partitioned_table p ON p.partrelid = parent.oid
WHERE pn.nspname = 'iot_raw'
  AND parent.relname = 'sensor_readings'
ORDER BY c.relname;


-- Nombre de lignes par partition (approximatif via pg_class.reltuples)
SELECT
    c.relname           AS partition_name,
    c.reltuples::BIGINT AS estimated_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_inherits i  ON i.inhrelid = c.oid
JOIN pg_class par   ON par.oid = i.inhparent
WHERE n.nspname  = 'iot_raw'
  AND par.relname = 'sensor_readings'
ORDER BY c.relname;
*/