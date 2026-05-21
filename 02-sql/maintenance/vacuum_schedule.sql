-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/maintenance/vacuum_schedule.sql
-- OBJET     : Paramétrage autovacuum par table (storage parameters ALTER TABLE)
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- POURQUOI UN RÉGLAGE PAR TABLE ?
-- ────────────────────────────────
--   Les paramètres globaux postgresql.conf sont des compromis pour l'ensemble
--   de la base. AcierTech a un profil très hétérogène :
--
--   • iot_raw.sensor_readings  : ~47 capteurs × fréquence variable ≈ plusieurs
--     milliers d'INSERT/heure. Table la plus active de la base. Beaucoup de
--     dead tuples (UPDATE sur validation_status via trigger). Autovacuum agressif.
--
--   • iot_clean.sensor_readings : INSERT uniquement (depuis trigger), pas d'UPDATE.
--     Moins de dead tuples. Autovacuum modéré.
--
--   • iot_quarantine.*         : volume bien plus faible (< 30% des mesures en
--     conditions normales). Autovacuum standard.
--
--   • dba_schema.sensor_thresholds : 47 lignes, rarement modifiées.
--     Autovacuum quasi inutile — on garde les defaults pour ne pas surcharger.
--
--   • dba_schema.threshold_audit_log : INSERT-only (triggers audit), jamais UPDATE.
--     Pas de dead tuples, autovacuum scale_factor élevé.
--
-- PARAMÈTRES CLÉS
-- ───────────────
--   autovacuum_vacuum_scale_factor    : % de dead tuples/total pour déclencher VACUUM
--   autovacuum_analyze_scale_factor   : % de tuples modifiés pour déclencher ANALYZE
--   autovacuum_vacuum_cost_delay      : pause entre pages nettoyées (ms) — 0 = max speed
--   autovacuum_vacuum_threshold       : nb minimum de dead tuples avant déclenchement
--   autovacuum_analyze_threshold      : nb minimum de modifications avant ANALYZE
--   autovacuum_freeze_max_age         : âge XID avant VACUUM anti-wraparound forcé
--
-- IDEMPOTENCE
-- ───────────
--   ALTER TABLE ... SET (storage_parameters) est idempotent.
--   Ce script peut être rejoué sans effet de bord.
-- =============================================================================


-- =============================================================================
-- 1. iot_raw.sensor_readings
--    Profil : INSERT massif + UPDATE (validation_status via trigger BEFORE INSERT)
--    Objectif : vider les dead tuples rapidement, stats fraîches pour le planificateur
-- =============================================================================
ALTER TABLE iot_raw.sensor_readings SET (

    -- Déclencher VACUUM dès 2% de dead tuples (défaut PostgreSQL = 20%)
    -- Justification : table volumineuse, 2% représente déjà des milliers de tuples
    autovacuum_vacuum_scale_factor    = 0.02,

    -- ANALYZE dès 1% de modifications (défaut = 20%)
    -- Maintient les statistiques fraîches pour le planificateur (critiques pour
    -- les index partiels sur validation_status utilisés par fn_compute_quality_score)
    autovacuum_analyze_scale_factor   = 0.01,

    -- Pas de pause entre pages nettoyées (défaut = 2ms)
    -- Acceptable car les INSERT IoT sont continus ; on préfère un VACUUM rapide
    -- plutôt qu'un VACUUM long qui accumule du lag
    autovacuum_vacuum_cost_delay      = 0,

    -- Seuil absolu bas : déclencher VACUUM même avec peu de dead tuples
    -- (utile en début de vie de la table ou après un TRUNCATE partiel)
    autovacuum_vacuum_threshold       = 100,

    -- ANALYZE dès 50 lignes modifiées (défaut = 50, on garde)
    autovacuum_analyze_threshold      = 50,

    -- Anti-wraparound : forcer VACUUM après 100M transactions
    -- (défaut = 200M — on divise par 2 pour sécuriser l'usine 24/7)
    autovacuum_freeze_max_age         = 100000000
);


-- =============================================================================
-- 2. iot_clean.sensor_readings
--    Profil : INSERT uniquement (depuis trigger), pas d'UPDATE/DELETE.
--    Dead tuples quasi nuls. On optimise surtout l'ANALYZE pour le planificateur.
-- =============================================================================
ALTER TABLE iot_clean.sensor_readings SET (

    -- VACUUM peu fréquent : pas de dead tuples (pas d'UPDATE)
    autovacuum_vacuum_scale_factor    = 0.10,

    -- ANALYZE modéré : la table grossit régulièrement
    autovacuum_analyze_scale_factor   = 0.05,

    -- Légère pause : table moins critique que iot_raw
    autovacuum_vacuum_cost_delay      = 2,

    autovacuum_vacuum_threshold       = 500,
    autovacuum_analyze_threshold      = 100,

    -- Anti-wraparound standard
    autovacuum_freeze_max_age         = 150000000
);


-- =============================================================================
-- 3. iot_quarantine.rejected_readings
--    Profil : INSERT uniquement (depuis trigger), volume < 30% en nominal.
--    Données potentiellement purgées périodiquement (pg_cron_jobs.sql).
--    DELETE fréquents lors des purges → dead tuples lors des nettoyages.
-- =============================================================================
ALTER TABLE iot_quarantine.rejected_readings SET (

    -- Agressif en scale_factor pour absorber les purges périodiques
    autovacuum_vacuum_scale_factor    = 0.05,
    autovacuum_analyze_scale_factor   = 0.05,
    autovacuum_vacuum_cost_delay      = 2,
    autovacuum_vacuum_threshold       = 200,
    autovacuum_analyze_threshold      = 100,
    autovacuum_freeze_max_age         = 150000000
);


-- =============================================================================
-- 4. iot_quarantine.anomaly_log
--    Profil : INSERT uniquement (plusieurs lignes par mesure rejetée).
--    Volume potentiellement élevé si la qualité des capteurs se dégrade.
--    Purge périodique prévue (pg_cron_jobs.sql) → DELETE en masse.
-- =============================================================================
ALTER TABLE iot_quarantine.anomaly_log SET (

    autovacuum_vacuum_scale_factor    = 0.05,
    autovacuum_analyze_scale_factor   = 0.05,
    autovacuum_vacuum_cost_delay      = 2,
    autovacuum_vacuum_threshold       = 200,
    autovacuum_analyze_threshold      = 100,
    autovacuum_freeze_max_age         = 150000000
);


-- =============================================================================
-- 5. dba_schema.data_quality_snapshots
--    Profil : INSERT toutes les 5 min (fn_compute_quality_snapshot), pas d'UPDATE.
--    Purge des vieux snapshots par pg_cron → DELETE périodiques.
-- =============================================================================
ALTER TABLE dba_schema.data_quality_snapshots SET (

    autovacuum_vacuum_scale_factor    = 0.05,
    autovacuum_analyze_scale_factor   = 0.05,
    autovacuum_vacuum_cost_delay      = 2,
    autovacuum_vacuum_threshold       = 100,
    autovacuum_analyze_threshold      = 50,
    autovacuum_freeze_max_age         = 150000000
);


-- =============================================================================
-- 6. dba_schema.threshold_audit_log
--    Profil : INSERT-only (trigger audit), rarement purgée.
--    Dead tuples quasi nuls. Autovacuum très permissif.
-- =============================================================================
ALTER TABLE dba_schema.threshold_audit_log SET (

    autovacuum_vacuum_scale_factor    = 0.20,
    autovacuum_analyze_scale_factor   = 0.10,
    autovacuum_vacuum_cost_delay      = 10,
    autovacuum_vacuum_threshold       = 1000,
    autovacuum_analyze_threshold      = 500,
    autovacuum_freeze_max_age         = 200000000
);


-- =============================================================================
-- 7. dba_schema.sensor_thresholds
--    Profil : 47 lignes, UPDATE occasionnel (réglages opérateur).
--    Table minuscule — autovacuum par défaut suffit amplement.
--    On ne surcharge pas inutilement le catalogue.
-- =============================================================================
-- Aucune modification : paramètres PostgreSQL par défaut conservés.
-- (pas d'ALTER TABLE ici = documentation explicite du choix)


-- =============================================================================
-- 8. iot_raw.ingestion_errors
--    Profil : INSERT en cas d'erreur trigger (rare en nominal).
--    Si nombreux → problème grave détecté ailleurs. Pas de réglage spécifique.
-- =============================================================================
-- Paramètres par défaut conservés.


-- =============================================================================
-- VÉRIFICATION POST-APPLICATION
-- Afficher les storage parameters effectifs pour toutes les tables réglées.
-- À exécuter manuellement en psql après le script pour audit.
-- =============================================================================
/*
SELECT
    n.nspname                                   AS schema,
    c.relname                                   AS table_name,
    c.reloptions                                AS storage_parameters
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('iot_raw', 'iot_clean', 'iot_quarantine', 'dba_schema')
  AND c.relkind = 'r'
  AND c.reloptions IS NOT NULL
ORDER BY n.nspname, c.relname;
*/


-- =============================================================================
-- NOTE : VACUUM MANUEL DE RÉFÉRENCE
-- À exécuter après un chargement initial massif (V008 seed) ou une migration.
-- Ne pas inclure dans l'automatisation — réservé au DBA.
-- =============================================================================
/*
VACUUM (VERBOSE, ANALYZE) iot_raw.sensor_readings;
VACUUM (VERBOSE, ANALYZE) iot_clean.sensor_readings;
VACUUM (VERBOSE, ANALYZE) iot_quarantine.rejected_readings;
VACUUM (VERBOSE, ANALYZE) iot_quarantine.anomaly_log;
VACUUM (VERBOSE, ANALYZE) dba_schema.data_quality_snapshots;
*/