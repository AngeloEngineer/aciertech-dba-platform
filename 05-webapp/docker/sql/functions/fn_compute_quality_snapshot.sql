-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/functions/fn_compute_quality_snapshot.sql
-- OBJET     : Agrégation qualité IoT → dba_schema.data_quality_snapshots
-- DÉPEND DE : V005 (data_quality_snapshots), V006 (index iot_raw)
-- APPELÉ PAR: pg_cron toutes les 5 min (voir pg_cron_jobs.sql)
--             ou worker Python de pipeline (06-pipeline/)
-- AUTEUR    : BILAKE & KPELOU / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- COMPORTEMENT
-- ────────────
--   - Calcule des agrégats par sensor_type sur la fenêtre [NOW()-p_window_minutes, NOW()[
--   - Insère UNE ligne par sensor_type dans data_quality_snapshots
--   - Si aucune donnée dans la fenêtre : insère une ligne avec compteurs à 0
--     pour chaque type connu dans sensor_registry (visibilité du silence capteur)
--   - Retourne le nombre de lignes insérées
--   - RAISE NOTICE pour chaque exécution → visible dans pg_log si
--     log_min_messages <= NOTICE (valeur par défaut)
--
-- COMPATIBILITÉ pgBouncer pool_mode=transaction
-- ─────────────────────────────────────────────
--   ✓  Pas d'advisory locks
--   ✓  Pas de SET LOCAL dans le corps
--   ✓  Transaction unique (INSERT + GET DIAGNOSTICS)
--   ✓  SET search_path au niveau OPTION de la fonction
-- =============================================================================

CREATE OR REPLACE FUNCTION dba_schema.fn_compute_quality_snapshot(
    p_window_minutes INTEGER DEFAULT 5
)
RETURNS INTEGER      -- nombre de lignes insérées dans data_quality_snapshots
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = dba_schema, iot_raw, pg_catalog
AS $$
DECLARE
    v_snapshot_at   TIMESTAMPTZ := clock_timestamp();  -- timestamp stable pour tout le call
    v_window_start  TIMESTAMPTZ;
    v_rows_inserted INTEGER     := 0;
BEGIN
    -- Validation de l'argument (plage raisonnable : 1 à 60 minutes)
    IF p_window_minutes IS NULL OR p_window_minutes < 1 OR p_window_minutes > 60 THEN
        RAISE EXCEPTION
            '[fn_compute_quality_snapshot] p_window_minutes doit être entre 1 et 60, reçu : %',
            p_window_minutes;
    END IF;

    v_window_start := v_snapshot_at - (p_window_minutes || ' minutes')::INTERVAL;

    -- =========================================================================
    -- INSERTION PRINCIPALE
    --
    -- On utilise un LEFT JOIN depuis sensor_registry pour garantir une ligne
    -- par sensor_type même si aucune mesure n'est arrivée dans la fenêtre
    -- (détection de silence capteur dans la vue v_data_quality_dashboard).
    --
    -- Agrégats calculés :
    --   • total_readings       : toutes mesures dans la fenêtre
    --   • valid_count          : validation_status = 'valid'
    --   • quarantined_count    : validation_status = 'quarantined'
    --   • error_count          : validation_status = 'error'
    --   • avg_quality_score    : moyenne des scores (NUMERIC 5,2)
    --   • min/max_quality_score: extrêmes des scores
    --   • valid_rate           : ratio valid/total (0.00 si total=0)
    -- =========================================================================
    INSERT INTO dba_schema.data_quality_snapshots (
        snapshot_at,
        sensor_type,
        window_start,
        window_end,
        total_readings,
        valid_count,
        quarantined_count,
        error_count,
        avg_quality_score,
        min_quality_score,
        max_quality_score,
        valid_rate
    )
    SELECT
        v_snapshot_at                                                    AS snapshot_at,
        reg.sensor_type                                                  AS sensor_type,
        v_window_start                                                   AS window_start,
        v_snapshot_at                                                    AS window_end,

        -- Compteurs : COALESCE car LEFT JOIN peut ramener NULL si aucune donnée
        COALESCE(agg.total_readings,    0)                               AS total_readings,
        COALESCE(agg.valid_count,       0)                               AS valid_count,
        COALESCE(agg.quarantined_count, 0)                               AS quarantined_count,
        COALESCE(agg.error_count,       0)                               AS error_count,

        -- Scores : NULL si aucune donnée (≠ 0, qui serait trompeur)
        agg.avg_quality_score                                            AS avg_quality_score,
        agg.min_quality_score                                            AS min_quality_score,
        agg.max_quality_score                                            AS max_quality_score,

        -- Taux de validité : 0.00 si aucune mesure, NULL non souhaité ici
        CASE
            WHEN COALESCE(agg.total_readings, 0) = 0 THEN 0.00
            ELSE ROUND(
                (COALESCE(agg.valid_count, 0)::NUMERIC
                 / agg.total_readings::NUMERIC) * 100,
                2
            )
        END                                                              AS valid_rate

    FROM (
        -- Liste de référence des types de capteurs connus
        -- DISTINCT ON sensor_type depuis sensor_registry
        SELECT DISTINCT sensor_type
        FROM   dba_schema.sensor_registry
        WHERE  is_active = TRUE
    ) reg
    LEFT JOIN (
        -- Agrégats fenêtrés depuis iot_raw
        -- Index idx_raw_sr_sensor_type_time_status couvre cette requête
        SELECT
            sr.sensor_type,
            COUNT(*)                                                      AS total_readings,
            COUNT(*) FILTER (WHERE sr.validation_status = 'valid')        AS valid_count,
            COUNT(*) FILTER (WHERE sr.validation_status = 'quarantined')  AS quarantined_count,
            COUNT(*) FILTER (WHERE sr.validation_status = 'error')        AS error_count,
            ROUND(AVG(sr.quality_score)::NUMERIC, 2)                      AS avg_quality_score,
            MIN(sr.quality_score)::SMALLINT                               AS min_quality_score,
            MAX(sr.quality_score)::SMALLINT                               AS max_quality_score
        FROM iot_raw.sensor_readings sr
        WHERE sr.recorded_at >= v_window_start
          AND sr.recorded_at  < v_snapshot_at
        GROUP BY sr.sensor_type
    ) agg ON reg.sensor_type = agg.sensor_type;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;

    RAISE NOTICE
        '[fn_compute_quality_snapshot] snapshot_at=% fenêtre=[%, %[ (%min) → % lignes insérées',
        v_snapshot_at,
        v_window_start,
        v_snapshot_at,
        p_window_minutes,
        v_rows_inserted;

    RETURN v_rows_inserted;

EXCEPTION
    WHEN OTHERS THEN
        -- Ne pas propager l'erreur vers pg_cron (évite l'arrêt du job)
        -- L'erreur est visible dans pg_log via RAISE WARNING
        RAISE WARNING
            '[fn_compute_quality_snapshot] ERREUR snapshot_at=% : % — %',
            v_snapshot_at,
            SQLERRM,
            SQLSTATE;
        RETURN -1;  -- valeur sentinelle → le worker Python peut alerter sur -1
END;
$$;

-- Droits : seuls postgres et le worker Python (via aciertech_app ou rôle dédié)
REVOKE ALL ON FUNCTION dba_schema.fn_compute_quality_snapshot(INTEGER) FROM PUBLIC;

-- pg_cron tourne avec le rôle propriétaire de la tâche (postgres par défaut)
-- Si un worker Python tourne avec aciertech_app, on lui accorde EXECUTE
GRANT EXECUTE ON FUNCTION dba_schema.fn_compute_quality_snapshot(INTEGER)
    TO aciertech_app;

COMMENT ON FUNCTION dba_schema.fn_compute_quality_snapshot(INTEGER) IS
'Agrège les mesures IoT de la fenêtre écoulée (défaut 5 min) par sensor_type
et insère une ligne par type dans dba_schema.data_quality_snapshots.
Utilise un LEFT JOIN depuis sensor_registry pour détecter les silences capteur.
Retourne le nombre de lignes insérées (-1 en cas d''erreur non bloquante).
Appelée par pg_cron toutes les 5 min. Compatible pool_mode=transaction.';