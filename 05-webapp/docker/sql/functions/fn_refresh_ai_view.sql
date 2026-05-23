-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/functions/fn_refresh_ai_view.sql
-- OBJET     : Rafraîchissement de iot_clean.v_ai_feature_set (vue matérialisée)
-- DÉPEND DE : V003 (v_ai_feature_set + UNIQUE index pour CONCURRENT), V005
-- APPELÉ PAR: pg_cron toutes les 5 min (voir pg_cron_jobs.sql)
-- AUTEUR    : BILAKE & KPELOU / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- POURQUOI REFRESH CONCURRENTLY ?
-- ────────────────────────────────
--   Sans CONCURRENTLY : la vue est verrouillée (AccessExclusiveLock) pendant
--   tout le refresh. Inacceptable si le système IA lit la vue en continu.
--
--   Avec CONCURRENTLY : PostgreSQL crée une vue temporaire en parallèle et
--   effectue un swap atomique. Nécessite l'index UNIQUE sur v_ai_feature_set
--   (créé en V006 : idx_ai_feature_set_unique).
--   ⚠ CONCURRENTLY ne peut PAS s'exécuter dans une transaction explicite.
--      Cette fonction est donc à appeler HORS transaction (autocommit).
--      pg_cron exécute chaque tâche en autocommit → OK.
--      Worker Python : connection.autocommit = True avant l'appel.
--
-- MESURE DE DURÉE
-- ───────────────
--   On utilise clock_timestamp() (temps réel) et non now() (début de transaction)
--   pour obtenir une durée précise même si la fonction est appelée en milieu
--   de transaction longue.
--
-- COMPATIBILITÉ pgBouncer pool_mode=transaction
-- ─────────────────────────────────────────────
--   ✓  Pas d'advisory locks
--   ✓  Pas de SET LOCAL dans le corps
--   ✓  SECURITY DEFINER avec SET search_path (≠ SET LOCAL)
--   ⚠  REFRESH CONCURRENTLY interdit dans un bloc BEGIN/COMMIT explicite.
--      Si appelée via pgBouncer, utiliser le port direct HAProxy:5000 → pg
--      ou une connexion psql avec autocommit=on.
--      Voir pg_cron_jobs.sql pour la configuration correcte.
-- =============================================================================

CREATE OR REPLACE FUNCTION dba_schema.fn_refresh_ai_view()
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = dba_schema, iot_clean, pg_catalog
AS $$
DECLARE
    v_start_at     TIMESTAMPTZ := clock_timestamp();
    v_end_at       TIMESTAMPTZ;
    v_duration_ms  NUMERIC;
    v_before_count BIGINT;
    v_after_count  BIGINT;
BEGIN
    -- =========================================================================
    -- Vérification préalable : l'index UNIQUE requis pour CONCURRENTLY existe-t-il ?
    -- (Sécurité en cas de migration manquante — évite un message d'erreur cryptique)
    -- =========================================================================
    IF NOT EXISTS (
        SELECT 1
        FROM   pg_index     idx
        JOIN   pg_class     rel ON rel.oid = idx.indrelid
        JOIN   pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE  nsp.nspname  = 'iot_clean'
          AND  rel.relname  = 'v_ai_feature_set'
          AND  idx.indisunique = TRUE
    ) THEN
        RAISE EXCEPTION
            '[fn_refresh_ai_view] Index UNIQUE manquant sur iot_clean.v_ai_feature_set. '
            'REFRESH CONCURRENTLY impossible. Vérifiez V006 (idx_ai_feature_set_unique).';
    END IF;

    -- =========================================================================
    -- Snapshot du nombre de lignes avant refresh (pour journalisation delta)
    -- =========================================================================
    SELECT reltuples::BIGINT
    INTO   v_before_count
    FROM   pg_class c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  n.nspname = 'iot_clean'
      AND  c.relname = 'v_ai_feature_set';

    -- =========================================================================
    -- REFRESH MATERIALIZED VIEW CONCURRENTLY
    --
    -- ⚠ Cette instruction ne peut PAS être exécutée dans un bloc transactionnel.
    --   Elle doit être en autocommit. pg_cron gère cela nativement.
    --   Si cette fonction est appelée via un client Python :
    --       conn.autocommit = True
    --       cur.execute("SELECT dba_schema.fn_refresh_ai_view()")
    -- =========================================================================
    REFRESH MATERIALIZED VIEW CONCURRENTLY iot_clean.v_ai_feature_set;

    -- =========================================================================
    -- Mesure de durée et journalisation
    -- =========================================================================
    v_end_at      := clock_timestamp();
    v_duration_ms := ROUND(
        (EXTRACT(EPOCH FROM (v_end_at - v_start_at)) * 1000)::NUMERIC,
        2
    );

    -- Snapshot après refresh (pg_class.reltuples mis à jour par REFRESH)
    SELECT reltuples::BIGINT
    INTO   v_after_count
    FROM   pg_class c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  n.nspname = 'iot_clean'
      AND  c.relname = 'v_ai_feature_set';

    -- RAISE NOTICE → visible dans pg_log (log_min_messages = notice par défaut)
    -- et retourné au client appelant (pg_cron, psql, Python)
    RAISE NOTICE
        '[fn_refresh_ai_view] OK | durée=% ms | lignes avant=% après=% | terminé à %',
        v_duration_ms,
        COALESCE(v_before_count, -1),
        COALESCE(v_after_count,  -1),
        v_end_at;

    -- Alerte si le refresh dépasse 30 secondes (seuil arbitraire — à ajuster)
    -- Aide à détecter une dégradation des performances du pipeline clean
    IF v_duration_ms > 30000 THEN
        RAISE WARNING
            '[fn_refresh_ai_view] LENT : %ms > seuil 30 000ms. '
            'Vérifier la charge sur iot_clean.sensor_readings et les index.',
            v_duration_ms;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Journalisation de l'échec sans propager vers pg_cron
        -- (un refresh raté ne doit pas bloquer les autres tâches planifiées)
        RAISE WARNING
            '[fn_refresh_ai_view] ERREUR : % — % | started_at=%',
            SQLERRM,
            SQLSTATE,
            v_start_at;
        -- On re-raise quand même pour que pg_cron marque la tâche en erreur
        -- et que le DBA voit l'échec dans cron.job_run_details
        RAISE;
END;
$$;

-- Droits : EXECUTE uniquement pour postgres (pg_cron) et aciertech_app (worker)
REVOKE ALL ON FUNCTION dba_schema.fn_refresh_ai_view() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION dba_schema.fn_refresh_ai_view()
    TO aciertech_app;

COMMENT ON FUNCTION dba_schema.fn_refresh_ai_view() IS
'Rafraîchit iot_clean.v_ai_feature_set en mode CONCURRENTLY (pas de lock exclusif).
Nécessite un index UNIQUE sur la vue (V006 : idx_ai_feature_set_unique) et
doit être appelée HORS transaction (autocommit). pg_cron gère cela nativement.
Journalise durée + delta lignes via RAISE NOTICE. Alerte si durée > 30 s.
Compatible SECURITY DEFINER. NE PAS appeler via pgBouncer pool_mode=transaction.';