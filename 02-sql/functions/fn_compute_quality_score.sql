-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/functions/fn_compute_quality_score.sql
-- OBJET     : Calcul du score de qualité d'une mesure capteur IoT
-- DÉPEND DE : V005 (sensor_thresholds), V006 (index), V007 (grants)
-- APPELÉ PAR: trg_validate_sensor (BEFORE INSERT sur iot_raw.sensor_readings)
-- AUTEUR    : BILAKE & KPELOU/ INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- LOGIQUE DE SCORING (seuils décidés en phase conception)
-- ──────────────────────────────────────────────────────
--   Score 100     → OK           : valeur dans la plage normale
--   Score  75     → WARNING_*    : hors warning_min/max mais physiquement plausible
--                                  (passe dans iot_clean, signalé en score)
--   Score  65     → ZSCORE_ANOMALY: écart statistique > zscore_threshold sur 1h
--                                  (quarantaine — investigation requise)
--   Score  55     → WARNING + ZSCORE (les deux en même temps → quarantaine)
--   Score  50     → NO_THRESHOLD : capteur inconnu, pas de référentiel
--   Score   0     → OUT_OF_RANGE : hors min_value/max_value physiques absolus
--
-- Règle trigger aval : score >= 70 → iot_clean / score < 70 → quarantaine
--
-- COMPATIBILITÉ pgBouncer pool_mode=transaction
-- ─────────────────────────────────────────────
--   ✓  Pas d'advisory locks
--   ✓  Pas de SET LOCAL dans le corps
--   ✓  Pas de tables temporaires persistantes
--   ✓  SET search_path au niveau OPTION de la fonction (≠ SET LOCAL)
--   ✓  SECURITY DEFINER : la fonction tourne avec les droits de postgres,
--      aciertech_app (INSERT iot_raw seulement) peut l'invoquer via trigger
--
-- INDEX UTILISÉ : idx_raw_sr_sensor_type_time_status (V006)
--   → Index composite (sensor_id, recorded_at, validation_status)
--      couvre exactement la fenêtre Z-score
-- =============================================================================

CREATE OR REPLACE FUNCTION dba_schema.fn_compute_quality_score(
    p_sensor_id   INTEGER,
    p_sensor_type VARCHAR(50),
    p_value       NUMERIC(10,4),
    p_recorded_at TIMESTAMPTZ
)
RETURNS TABLE (
    score   SMALLINT,
    reason  TEXT,
    details JSONB
)
LANGUAGE plpgsql
VOLATILE                  -- lit iot_raw.sensor_readings qui évolue en continu
SECURITY DEFINER          -- s'exécute avec les droits postgres
SET search_path = dba_schema, iot_raw, pg_catalog
AS $$
DECLARE
    -- Seuils du capteur
    v_thresh        dba_schema.sensor_thresholds%ROWTYPE;

    -- Résultats intermédiaires
    v_score         SMALLINT   := 100;
    v_reason        TEXT       := 'OK';
    v_details       JSONB      := '{}'::JSONB;
    v_reasons       TEXT[]     := ARRAY[]::TEXT[];

    -- Fenêtre statistique Z-score (1 heure, mesures 'valid' uniquement)
    v_mean          NUMERIC;
    v_stddev        NUMERIC;
    v_zscore        NUMERIC;
    v_window_count  BIGINT;
BEGIN
    -- =========================================================================
    -- ÉTAPE 1 : Récupération des seuils de référence
    --   PK lookup sur (sensor_id) → accès O(log n) garanti, très rapide
    -- =========================================================================
    SELECT *
    INTO   v_thresh
    FROM   dba_schema.sensor_thresholds
    WHERE  sensor_id = p_sensor_id;

    IF NOT FOUND THEN
        -- Capteur non référencé dans sensor_thresholds
        -- On retourne score 50 : quarantaine douce, log explicite
        RETURN QUERY
            SELECT
                50::SMALLINT,
                'NO_THRESHOLD'::TEXT,
                jsonb_build_object(
                    'sensor_id',   p_sensor_id,
                    'sensor_type', p_sensor_type,
                    'value',       p_value,
                    'recorded_at', p_recorded_at,
                    'message',     'Aucune configuration de seuil trouvée pour ce capteur'
                );
        RETURN;
    END IF;

    -- =========================================================================
    -- ÉTAPE 2 : Vérification des bornes physiques absolues
    --   (min_value / max_value dans sensor_thresholds)
    --   Note : les CHECK contraints en V002 couvrent des bornes universelles ;
    --   ici on vérifie les seuils métier propres à ce type de capteur.
    -- =========================================================================
    IF p_value < v_thresh.min_value OR p_value > v_thresh.max_value THEN
        -- Valeur physiquement impossible pour ce capteur → score 0, quarantaine immédiate
        v_score   := 0;
        v_reasons := array_append(v_reasons, 'OUT_OF_RANGE');
        v_details := v_details || jsonb_build_object(
            'out_of_range', jsonb_build_object(
                'value',     p_value,
                'min_value', v_thresh.min_value,
                'max_value', v_thresh.max_value,
                'delta_min', p_value - v_thresh.min_value,
                'delta_max', v_thresh.max_value - p_value
            )
        );

        -- Inutile de calculer le Z-score : la mesure est physiquement hors-spec
        GOTO build_result;
    END IF;

    -- =========================================================================
    -- ÉTAPE 3 : Vérification des seuils d'alerte (warning_min / warning_max)
    --   Valeur dans la plage physique mais hors plage nominale.
    --   Score 75 → passe dans iot_clean, signalé pour l'IA.
    -- =========================================================================
    IF v_thresh.warning_min IS NOT NULL AND p_value < v_thresh.warning_min THEN
        v_score   := LEAST(v_score, 75);
        v_reasons := array_append(v_reasons, 'WARNING_LOW');
        v_details := v_details || jsonb_build_object(
            'warning_low', jsonb_build_object(
                'value',       p_value,
                'warning_min', v_thresh.warning_min,
                'delta',       p_value - v_thresh.warning_min
            )
        );
    END IF;

    IF v_thresh.warning_max IS NOT NULL AND p_value > v_thresh.warning_max THEN
        v_score   := LEAST(v_score, 75);
        v_reasons := array_append(v_reasons, 'WARNING_HIGH');
        v_details := v_details || jsonb_build_object(
            'warning_high', jsonb_build_object(
                'value',       p_value,
                'warning_max', v_thresh.warning_max,
                'delta',       p_value - v_thresh.warning_max
            )
        );
    END IF;

    -- =========================================================================
    -- ÉTAPE 4 : Calcul du Z-score sur fenêtre glissante 1 heure
    --
    --   Fenêtre : [p_recorded_at - 1h, p_recorded_at[  (borne haute exclue)
    --   Filtre  : validation_status = 'valid'  (seules les mesures propres)
    --   Index   : idx_raw_sr_sensor_type_time_status couvre (sensor_id,
    --             recorded_at, validation_status) → index scan rapide
    --
    --   Minimum statistique : 10 points dans la fenêtre (sinon skip)
    --   Seuil   : zscore_threshold depuis sensor_thresholds (ex: 2.5 pour fours)
    -- =========================================================================
    SELECT
        AVG(sr.value)        AS mean,
        STDDEV_SAMP(sr.value) AS stddev,
        COUNT(*)              AS window_count
    INTO
        v_mean,
        v_stddev,
        v_window_count
    FROM iot_raw.sensor_readings sr
    WHERE sr.sensor_id        = p_sensor_id
      AND sr.validation_status = 'valid'
      AND sr.recorded_at      >= p_recorded_at - INTERVAL '1 hour'
      AND sr.recorded_at       < p_recorded_at;

    IF v_window_count < 10 THEN
        -- Fenêtre trop petite : Z-score non calculable, on note l'absence
        v_details := v_details || jsonb_build_object(
            'zscore_skipped', jsonb_build_object(
                'reason',       'insufficient_window',
                'window_count', v_window_count,
                'required',     10
            )
        );

    ELSIF v_stddev IS NULL OR v_stddev = 0 THEN
        -- Toutes les mesures identiques (σ = 0) → Z-score infini si p_value ≠ mean
        -- On ne pénalise pas : capteur stable, c'est normal en usine sur cycle court
        v_details := v_details || jsonb_build_object(
            'zscore_skipped', jsonb_build_object(
                'reason',        'zero_stddev',
                'window_count',  v_window_count,
                'mean',          v_mean
            )
        );

    ELSE
        -- Calcul effectif du Z-score
        v_zscore := ABS((p_value - v_mean) / v_stddev);

        v_details := v_details || jsonb_build_object(
            'zscore', jsonb_build_object(
                'value',        ROUND(v_zscore::NUMERIC, 4),
                'mean',         ROUND(v_mean::NUMERIC,   4),
                'stddev',       ROUND(v_stddev::NUMERIC, 4),
                'window_count', v_window_count,
                'threshold',    v_thresh.zscore_threshold
            )
        );

        IF v_zscore > v_thresh.zscore_threshold THEN
            -- Score 65 si Z-score seul, 55 si combiné avec un WARNING (LEAST)
            v_score   := LEAST(v_score, CASE WHEN v_score < 100 THEN 55 ELSE 65 END);
            v_reasons := array_append(v_reasons, 'ZSCORE_ANOMALY');
        END IF;
    END IF;

    -- =========================================================================
    -- ÉTAPE 5 : Construction du résultat final
    -- =========================================================================
    <<build_result>>

    -- Raison finale : concaténation des codes séparés par '|'
    v_reason := CASE
        WHEN array_length(v_reasons, 1) IS NULL THEN 'OK'
        ELSE array_to_string(v_reasons, '|')
    END;

    -- Métadonnées capteur systématiquement incluses dans details
    v_details := jsonb_build_object(
        'sensor_id',   p_sensor_id,
        'sensor_type', p_sensor_type,
        'value',       p_value,
        'recorded_at', p_recorded_at
    ) || v_details;

    RETURN QUERY SELECT v_score, v_reason, v_details;
END;
$$;

-- Sécurité : pas d'exécution directe par les rôles applicatifs
-- L'accès se fait uniquement via le trigger trg_validate_sensor
REVOKE ALL ON FUNCTION dba_schema.fn_compute_quality_score(
    INTEGER, VARCHAR(50), NUMERIC(10,4), TIMESTAMPTZ
) FROM PUBLIC;

-- aciertech_app a besoin d'EXECUTE car le trigger tourne avec ses droits
-- mais SECURITY DEFINER élève aussitôt à postgres — double protection
GRANT EXECUTE ON FUNCTION dba_schema.fn_compute_quality_score(
    INTEGER, VARCHAR(50), NUMERIC(10,4), TIMESTAMPTZ
) TO aciertech_app;

COMMENT ON FUNCTION dba_schema.fn_compute_quality_score(
    INTEGER, VARCHAR(50), NUMERIC(10,4), TIMESTAMPTZ
) IS
'Calcule le score qualité (0-100) d''une mesure capteur IoT.
Étapes : (1) lookup seuils sensor_thresholds, (2) bornes physiques,
(3) seuils warning, (4) Z-score fenêtre 1h sur iot_raw valid.
Score >= 70 → iot_clean | Score < 70 → quarantaine.
SECURITY DEFINER : s''exécute avec les droits postgres.
Compatible pool_mode=transaction (pas d''advisory lock ni SET LOCAL).';