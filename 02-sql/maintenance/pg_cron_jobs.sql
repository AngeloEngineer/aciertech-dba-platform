-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/maintenance/pg_cron_jobs.sql
-- OBJET     : Tâches planifiées pg_cron pour le cluster AcierTech
-- DÉPEND DE : Extension pg_cron (à installer dans postgresql.conf)
--             functions/fn_compute_quality_snapshot.sql
--             functions/fn_refresh_ai_view.sql
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- PRÉREQUIS POSTGRESQL.CONF
-- ─────────────────────────
--   shared_preload_libraries = 'pg_cron, pg_stat_statements'
--   cron.database_name = 'aciertech_db'
--   # pg_cron crée son schéma 'cron' dans aciertech_db au premier démarrage
--
-- INSTALLATION EXTENSION (à exécuter une seule fois en superuser)
-- ───────────────────────────────────────────────────────────────
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   -- pg_cron tourne avec le rôle postgres par défaut
--
-- IDEMPOTENCE
-- ───────────
--   Ce script utilise cron.unschedule() avant chaque cron.schedule() pour
--   garantir qu'une relance ne crée pas de doublons.
--   cron.unschedule() ne lève pas d'exception si le job n'existe pas
--   (depuis pg_cron >= 1.4 — vérifier la version installée).
--
-- COMPATIBILITÉ pool_mode=transaction
-- ────────────────────────────────────
--   pg_cron exécute chaque job en autocommit (connexion directe à PostgreSQL,
--   pas via pgBouncer). REFRESH CONCURRENTLY fonctionne donc sans restriction.
--   Les jobs appellent les fonctions via leur connexion propre sur port 5432.
--
-- SURVEILLANCE DES JOBS
-- ─────────────────────
--   SELECT * FROM cron.job;                  -- liste des jobs configurés
--   SELECT * FROM cron.job_run_details
--    ORDER BY start_time DESC LIMIT 50;      -- historique des exécutions
--   -- status : 'succeeded' | 'failed' | 'started' | 'running'
-- =============================================================================


-- =============================================================================
-- SÉCURITÉ PRÉALABLE : s'assurer que pg_cron est installé
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
    ) THEN
        RAISE EXCEPTION
            '[pg_cron_jobs] Extension pg_cron non installée. '
            'Ajouter pg_cron à shared_preload_libraries et redémarrer PostgreSQL, '
            'puis exécuter : CREATE EXTENSION pg_cron;';
    END IF;
END;
$$;


-- =============================================================================
-- JOB 1 : Snapshot qualité IoT — toutes les 5 minutes
-- =============================================================================
-- Suppression préalable (idempotence)
SELECT cron.unschedule('aciertech_quality_snapshot')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_quality_snapshot'
);

SELECT cron.schedule(
    'aciertech_quality_snapshot',           -- nom unique du job
    '*/5 * * * *',                          -- toutes les 5 minutes
    $$SELECT dba_schema.fn_compute_quality_snapshot(5);$$
);

-- Documentation du job
COMMENT ON COLUMN cron.job.jobid IS
'aciertech_quality_snapshot : agrège iot_raw → data_quality_snapshots toutes les 5 min.
Appelle fn_compute_quality_snapshot(5). Résultats dans cron.job_run_details.';


-- =============================================================================
-- JOB 2 : Refresh vue matérialisée IA — toutes les 5 minutes
--
-- ⚠ REFRESH CONCURRENTLY ne peut pas s'exécuter dans une transaction.
--   pg_cron exécute chaque job en autocommit → OK nativement.
--   Ne pas déplacer cet appel vers pgBouncer.
-- =============================================================================
SELECT cron.unschedule('aciertech_refresh_ai_view')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_refresh_ai_view'
);

SELECT cron.schedule(
    'aciertech_refresh_ai_view',
    '*/5 * * * *',                          -- toutes les 5 minutes
    $$SELECT dba_schema.fn_refresh_ai_view();$$
);


-- =============================================================================
-- JOB 3 : Purge iot_quarantine.rejected_readings — quotidienne à 02h00
--   Conserve 30 jours. Les anomalies récentes restent disponibles pour l'IA.
--   DELETE par batch de 10 000 pour éviter un verrou long sur la table.
-- =============================================================================
SELECT cron.unschedule('aciertech_purge_quarantine')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_purge_quarantine'
);

SELECT cron.schedule(
    'aciertech_purge_quarantine',
    '0 2 * * *',                            -- tous les jours à 02h00
    $$
    WITH deleted AS (
        DELETE FROM iot_quarantine.rejected_readings
        WHERE id IN (
            SELECT id
            FROM   iot_quarantine.rejected_readings
            WHERE  recorded_at < NOW() - INTERVAL '30 days'
            ORDER  BY recorded_at
            LIMIT  10000
        )
        RETURNING id
    )
    SELECT COUNT(*) AS rows_purged FROM deleted;
    $$
);


-- =============================================================================
-- JOB 4 : Purge iot_quarantine.anomaly_log — quotidienne à 02h15
--   Conserve 30 jours (cohérent avec rejected_readings).
--   Décalé de 15 min pour ne pas cumuler les I/O avec le job 3.
-- =============================================================================
SELECT cron.unschedule('aciertech_purge_anomaly_log')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_purge_anomaly_log'
);

SELECT cron.schedule(
    'aciertech_purge_anomaly_log',
    '15 2 * * *',
    $$
    WITH deleted AS (
        DELETE FROM iot_quarantine.anomaly_log
        WHERE id IN (
            SELECT id
            FROM   iot_quarantine.anomaly_log
            WHERE  detected_at < NOW() - INTERVAL '30 days'
            ORDER  BY detected_at
            LIMIT  10000
        )
        RETURNING id
    )
    SELECT COUNT(*) AS rows_purged FROM deleted;
    $$
);


-- =============================================================================
-- JOB 5 : Purge dba_schema.data_quality_snapshots — hebdomadaire le lundi à 03h00
--   Conserve 90 jours de snapshots (granularité 5 min = ~25 920 lignes/type/90j).
-- =============================================================================
SELECT cron.unschedule('aciertech_purge_quality_snapshots')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_purge_quality_snapshots'
);

SELECT cron.schedule(
    'aciertech_purge_quality_snapshots',
    '0 3 * * 1',                            -- lundi à 03h00
    $$
    DELETE FROM dba_schema.data_quality_snapshots
    WHERE snapshot_at < NOW() - INTERVAL '90 days';
    $$
);


-- =============================================================================
-- JOB 6 : Purge dba_schema.threshold_audit_log — mensuelle le 1er du mois à 03h30
--   Conserve 1 an (traçabilité réglementaire ISO maintenance industrielle).
-- =============================================================================
SELECT cron.unschedule('aciertech_purge_audit_log')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_purge_audit_log'
);

SELECT cron.schedule(
    'aciertech_purge_audit_log',
    '30 3 1 * *',                           -- 1er du mois à 03h30
    $$
    DELETE FROM dba_schema.threshold_audit_log
    WHERE changed_at < NOW() - INTERVAL '1 year';
    $$
);


-- =============================================================================
-- JOB 7 : Purge iot_raw.ingestion_errors — hebdomadaire le lundi à 02h30
--   Conserve 7 jours (diagnostic récent uniquement, volume potentiellement élevé).
-- =============================================================================
SELECT cron.unschedule('aciertech_purge_ingestion_errors')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_purge_ingestion_errors'
);

SELECT cron.schedule(
    'aciertech_purge_ingestion_errors',
    '30 2 * * 1',
    $$
    DELETE FROM iot_raw.ingestion_errors
    WHERE occurred_at < NOW() - INTERVAL '7 days';
    $$
);


-- =============================================================================
-- JOB 8 : Purge historique pg_cron lui-même — hebdomadaire le dimanche à 04h00
--   cron.job_run_details grossit indéfiniment si non purgé.
--   On conserve 14 jours d'historique d'exécution.
-- =============================================================================
SELECT cron.unschedule('aciertech_purge_cron_history')
WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'aciertech_purge_cron_history'
);

SELECT cron.schedule(
    'aciertech_purge_cron_history',
    '0 4 * * 0',                            -- dimanche à 04h00
    $$
    DELETE FROM cron.job_run_details
    WHERE end_time < NOW() - INTERVAL '14 days';
    $$
);


-- =============================================================================
-- VÉRIFICATION FINALE : afficher tous les jobs configurés
-- =============================================================================
SELECT
    jobid,
    jobname,
    schedule,
    command,
    active
FROM cron.job
WHERE jobname LIKE 'aciertech_%'
ORDER BY jobname;