-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/views/v_replication_status.sql
-- OBJET     : État de réplication streaming enrichi (Patroni 3-nœuds)
-- DÉPEND DE : pg_stat_replication (vue système), pg_stat_wal (PG16)
-- CONSOMMÉE : 04-monitoring/ (Grafana/alertes), 07-scripts/ (health-check)
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- CONTEXTE CLUSTER AcierTech
-- ──────────────────────────
--   Patroni : pg-node-1 (primary potentiel), pg-node-2, pg-node-3 (standbys)
--   Réplication : streaming synchrone possible (synchronous_commit=on)
--   HAProxy : port 5000 (RW → primary), port 5001 (RO → standbys)
--
-- COLONNES IMPORTANTES
-- ────────────────────
--   • application_name   : nom du nœud Patroni (configuré dans patroni.yml)
--   • state              : streaming | startup | catchup | backup
--   • sync_state         : sync | async | quorum | potential
--   • replication_lag_bytes : write_lsn - sent_lsn (backlog à envoyer)
--   • flush_lag_bytes       : write_lsn - flush_lsn (non encore durable)
--   • replay_lag_bytes      : write_lsn - replay_lsn (non encore appliqué)
--   • replay_lag_seconds    : lag en secondes (depuis pg_stat_replication)
--   • lag_level             : OK / WARNING / CRITICAL selon seuils opérationnels
--
-- SÉCURITÉ
-- ────────
--   Accessible uniquement à postgres (DBA, monitoring).
--   Ne PAS exposer à aciertech_ro : données internes cluster.
--   Grafana utilise un rôle dédié monitoring (voir 04-monitoring/).
-- =============================================================================

CREATE OR REPLACE VIEW dba_schema.v_replication_status AS
WITH

-- Données brutes pg_stat_replication (nœud courant uniquement = primary)
repl_raw AS (
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
        -- LSN courant du primary (pour calcul des deltas)
        pg_current_wal_lsn()        AS primary_lsn
    FROM pg_stat_replication r
),

-- WAL stats globales (PostgreSQL 16 : pg_stat_wal)
wal_stats AS (
    SELECT
        wal_bytes,
        wal_records,
        stats_reset
    FROM pg_stat_wal
)

SELECT
    -- Identification du nœud replica
    r.application_name                                              AS replica_name,
    r.client_addr                                                   AS replica_host,
    r.client_port                                                   AS replica_port,
    r.pid                                                           AS walsender_pid,

    -- Connectivité
    r.backend_start                                                 AS connected_since,
    NOW() - r.backend_start                                         AS connection_age,
    r.state                                                         AS replication_state,
    r.sync_state                                                    AS sync_mode,
    r.sync_priority,

    -- LSN positions (utile pour debug fin)
    r.primary_lsn                                                   AS primary_lsn,
    r.sent_lsn,
    r.write_lsn,
    r.flush_lsn,
    r.replay_lsn,

    -- Lag en octets (delta entre primary et chaque étape de réplication)
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.sent_lsn),   0)     AS unsent_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.write_lsn),  0)     AS replication_lag_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.flush_lsn),  0)     AS flush_lag_bytes,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.replay_lsn), 0)     AS replay_lag_bytes,

    -- Lag en temps (INTERVAL — directement depuis pg_stat_replication)
    r.write_lag                                                     AS write_lag_interval,
    r.flush_lag                                                     AS flush_lag_interval,
    r.replay_lag                                                    AS replay_lag_interval,

    -- Lag en secondes (extrait pour les alertes Grafana / seuils numériques)
    ROUND(EXTRACT(EPOCH FROM r.replay_lag)::NUMERIC, 3)            AS replay_lag_seconds,

    -- Niveau d'alerte lag
    --   OK       : replay_lag < 5s  (nominal cluster AcierTech)
    --   WARNING  : 5s ≤ lag < 30s   (surveillance renforcée)
    --   CRITICAL : lag ≥ 30s        (risque de perte de données en cas de failover)
    CASE
        WHEN r.replay_lag IS NULL
            THEN 'UNKNOWN'                          -- replica déconnecté ou en catchup
        WHEN r.replay_lag < INTERVAL '5 seconds'
            THEN 'OK'
        WHEN r.replay_lag < INTERVAL '30 seconds'
            THEN 'WARNING'
        ELSE 'CRITICAL'
    END                                                             AS lag_level,

    -- Statut global du nœud
    CASE
        WHEN r.state = 'streaming' AND r.sync_state IN ('sync', 'quorum')
            THEN 'SYNC_STREAMING'
        WHEN r.state = 'streaming' AND r.sync_state = 'async'
            THEN 'ASYNC_STREAMING'
        WHEN r.state = 'catchup'
            THEN 'CATCHING_UP'
        WHEN r.state = 'startup'
            THEN 'STARTING'
        WHEN r.state = 'backup'
            THEN 'BACKUP_IN_PROGRESS'
        ELSE 'UNKNOWN_STATE'
    END                                                             AS replica_status,

    -- WAL global (stats de production WAL sur ce primary)
    ws.wal_bytes                                                    AS total_wal_bytes_produced,
    ws.stats_reset                                                  AS wal_stats_reset_at,

    -- Horodatage de la vue
    NOW()                                                           AS viewed_at

FROM repl_raw r
CROSS JOIN wal_stats ws
ORDER BY r.sync_priority ASC NULLS LAST, r.application_name;

-- Droits : lecture réservée au DBA et au rôle monitoring Grafana
-- (NE PAS exposer à aciertech_ro)
REVOKE ALL  ON dba_schema.v_replication_status FROM PUBLIC;
-- GRANT SELECT ON dba_schema.v_replication_status TO monitoring_ro;
-- (décommenté dans 04-monitoring/ lors de la création du rôle)

COMMENT ON VIEW dba_schema.v_replication_status IS
'Vue enrichie de pg_stat_replication pour le cluster Patroni 3-nœuds AcierTech.
Expose : lag en octets et en secondes, niveaux d''alerte (OK/WARNING/CRITICAL),
statut de synchronisation (SYNC_STREAMING/ASYNC/CATCHING_UP), WAL stats PG16.
Réservée au DBA et au rôle monitoring Grafana. Utilisée par 04-monitoring/ et 07-scripts/.';