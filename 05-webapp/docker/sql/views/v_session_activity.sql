-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/views/v_session_activity.sql
-- OBJET     : Sessions PostgreSQL actives — requêtes longues et blocages
-- DÉPEND DE : pg_stat_activity, pg_locks, pg_stat_statements (extension V001)
-- CONSOMMÉE : 04-monitoring/ (Grafana), 07-scripts/ (kill-session, alertes)
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- CONTEXTE
-- ────────
--   max_connections=200, log_min_duration_statement=1000ms
--   pgBouncer pool_mode=transaction → les connexions sont très courtes ;
--   une session bloquée > 5s est anormale, > 30s est critique.
--
-- COLONNES CLÉS
-- ─────────────
--   • duration_seconds   : durée de la requête en cours
--   • wait_event_type    : Lock / LWLock / IO / Client / etc.
--   • blocking_pid       : PID du processus bloquant (si lock wait)
--   • blocking_query     : requête du bloquant (tronquée à 200 chars)
--   • is_long_running    : TRUE si durée > log_min_duration_statement (1s)
--   • alert_level        : OK / WARNING (>5s) / CRITICAL (>30s)
--   • query_preview      : début de la requête (200 chars) pour diagnostic rapide
--
-- SÉCURITÉ
-- ────────
--   Réservée au DBA et au rôle monitoring.
--   pg_stat_activity masque les requêtes des autres rôles si pas superuser ;
--   ici SECURITY DEFINER n'est pas applicable aux vues → utiliser pg_monitor.
--   Le rôle monitoring devra avoir : GRANT pg_monitor TO monitoring_ro;
-- =============================================================================

CREATE OR REPLACE VIEW dba_schema.v_session_activity AS
WITH

-- Sessions actives ou en attente (on exclut notre propre pg_backend_pid)
active_sessions AS (
    SELECT
        a.pid,
        a.usename,
        a.application_name,
        a.client_addr,
        a.client_port,
        a.backend_start,
        a.xact_start,
        a.query_start,
        a.state_change,
        a.wait_event_type,
        a.wait_event,
        a.state,
        a.backend_type,
        a.query,
        -- Durée de la requête courante en secondes (NULL si idle)
        EXTRACT(EPOCH FROM (NOW() - a.query_start))     AS duration_seconds,
        -- Durée depuis le début de la transaction
        EXTRACT(EPOCH FROM (NOW() - a.xact_start))      AS txn_duration_seconds,
        -- Durée depuis le changement d'état
        EXTRACT(EPOCH FROM (NOW() - a.state_change))    AS state_age_seconds,
        a.leader_pid,       -- PG16 : PID du leader pour les workers parallèles
        a.query_id          -- PG16 : query_id depuis pg_stat_statements
    FROM pg_stat_activity a
    WHERE a.pid <> pg_backend_pid()         -- on s'exclut soi-même
      AND a.backend_type = 'client backend' -- on exclut walsender, autovacuum, etc.
),

-- Identification des blocages (lock waits)
blocking AS (
    SELECT
        blocked.pid                                             AS blocked_pid,
        blocker.pid                                             AS blocking_pid,
        blocker.usename                                         AS blocking_user,
        LEFT(blocker.query, 200)                                AS blocking_query,
        blocker.state                                           AS blocking_state
    FROM pg_stat_activity blocked
    JOIN pg_stat_activity blocker
        ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
    WHERE blocked.wait_event_type = 'Lock'
      AND blocked.pid <> pg_backend_pid()
)

SELECT
    -- Identification
    s.pid,
    s.usename                                                   AS role_name,
    s.application_name,
    s.client_addr,
    s.client_port,
    s.backend_type,

    -- État
    s.state,
    s.wait_event_type,
    s.wait_event,

    -- Durées (arrondies à 3 décimales)
    ROUND(s.duration_seconds::NUMERIC,     3)                  AS query_duration_seconds,
    ROUND(s.txn_duration_seconds::NUMERIC, 3)                  AS txn_duration_seconds,

    -- Requête en cours (tronquée pour la vue — full dans pg_stat_activity)
    LEFT(s.query, 200)                                          AS query_preview,

    -- PG16 : lien vers pg_stat_statements si pg_stat_statements.track=all
    s.query_id,

    -- Parallélisme PG16 : workers d'une requête parallèle
    s.leader_pid,
    CASE WHEN s.leader_pid IS NOT NULL
        THEN TRUE ELSE FALSE
    END                                                         AS is_parallel_worker,

    -- Timestamps de référence
    s.backend_start,
    s.xact_start,
    s.query_start,

    -- Blocage
    b.blocking_pid,
    b.blocking_user,
    b.blocking_query,
    b.blocking_state,
    CASE WHEN b.blocking_pid IS NOT NULL THEN TRUE ELSE FALSE
    END                                                         AS is_blocked,

    -- Drapeaux de surveillance
    CASE
        WHEN s.duration_seconds IS NOT NULL
         AND s.duration_seconds > 1.0      -- log_min_duration_statement = 1000ms
        THEN TRUE ELSE FALSE
    END                                                         AS is_long_running,

    -- Niveau d'alerte
    --   OK       : durée < 5s, pas de blocage
    --   WARNING  : 5s ≤ durée < 30s  OU  session bloquée
    --   CRITICAL : durée ≥ 30s  OU  bloquant d'autres sessions
    CASE
        WHEN b.blocking_pid IS NOT NULL AND s.duration_seconds >= 30
            THEN 'CRITICAL'
        WHEN s.duration_seconds >= 30
            THEN 'CRITICAL'
        WHEN b.blocking_pid IS NOT NULL
            THEN 'WARNING'
        WHEN s.duration_seconds >= 5
            THEN 'WARNING'
        ELSE 'OK'
    END                                                         AS alert_level,

    -- Comptage des sessions bloquées par ce PID (si ce PID est lui-même un bloquant)
    (
        SELECT COUNT(*)
        FROM   pg_stat_activity victim
        WHERE  s.pid = ANY(pg_blocking_pids(victim.pid))
    )                                                           AS sessions_it_blocks,

    NOW()                                                       AS viewed_at

FROM active_sessions s
LEFT JOIN blocking b ON s.pid = b.blocked_pid
ORDER BY
    -- Priorité d'affichage : CRITICAL d'abord, puis durée décroissante
    CASE
        WHEN b.blocking_pid IS NOT NULL AND s.duration_seconds >= 30 THEN 1
        WHEN s.duration_seconds >= 30                                 THEN 2
        WHEN b.blocking_pid IS NOT NULL                               THEN 3
        WHEN s.duration_seconds >= 5                                  THEN 4
        ELSE 5
    END,
    s.duration_seconds DESC NULLS LAST;

-- Droits : DBA uniquement via pg_monitor
-- Le rôle monitoring Grafana doit avoir : GRANT pg_monitor TO monitoring_ro;
REVOKE ALL ON dba_schema.v_session_activity FROM PUBLIC;
-- GRANT SELECT ON dba_schema.v_session_activity TO monitoring_ro;

COMMENT ON VIEW dba_schema.v_session_activity IS
'Sessions PostgreSQL actives enrichies : durée requête/transaction, détection de
blocages (blocking_pid, blocking_query), niveau d''alerte (OK/WARNING/CRITICAL),
support PG16 (leader_pid, query_id). Seuils : WARNING > 5s, CRITICAL > 30s.
Nécessite GRANT pg_monitor au rôle monitoring pour voir les requêtes des autres rôles.
Compatible pool_mode=transaction (lecture de pg_stat_activity, pas de locks).';