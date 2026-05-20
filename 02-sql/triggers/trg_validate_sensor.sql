-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/triggers/trg_validate_sensor.sql
-- OBJET     : Validation et routage de chaque mesure IoT à l'insertion
-- DÉPEND DE : functions/fn_compute_quality_score.sql (doit être créée avant)
--             V002 (iot_raw.sensor_readings, iot_raw.ingestion_errors)
--             V003 (iot_clean.sensor_readings)
--             V004 (iot_quarantine.rejected_readings, iot_quarantine.anomaly_log)
-- ORDRE     : Créer ce fichier APRÈS 02-sql/functions/
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- FLUX DE DONNÉES
-- ───────────────
--
--   INSERT iot_raw.sensor_readings (aciertech_app)
--        │
--        ▼  BEFORE INSERT (ce trigger)
--   fn_compute_quality_score()
--        │
--        ├─ score >= 70 ──────────────────────────────► iot_clean.sensor_readings
--        │   NEW.validation_status = 'valid'              (INSERT dans AFTER ? Non :
--        │   NEW.quality_score     = score                 BEFORE → on modifie NEW
--        │                                                 puis INSERT iot_clean ici)
--        │
--        └─ score < 70 ───────────────────────────────► iot_quarantine.rejected_readings
--            NEW.validation_status = 'quarantined'     + iot_quarantine.anomaly_log
--            NEW.quality_score     = score               (1 ligne par code raison)
--
--   EXCEPTION (toute erreur non prévue)
--        └──────────────────────────────────────────► iot_raw.ingestion_errors
--             NEW est retourné tel quel (validation_status='error', score=NULL)
--             PAS de RAISE → l'INSERT iot_raw aboutit quand même
--
-- CONTRAINTES ABSOLUES RESPECTÉES
-- ────────────────────────────────
--   ✓  pool_mode=transaction : pas d'advisory lock, pas de SET LOCAL,
--      pas de table temporaire persistante
--   ✓  synchronous_commit=on : trigger court, pas de boucle sur N capteurs
--   ✓  SECURITY DEFINER sur fn_compute_quality_score : aciertech_app peut
--      déclencher le trigger sans droits direct sur iot_clean / iot_quarantine
--   ✓  BEFORE INSERT : on modifie NEW avant l'écriture physique dans iot_raw,
--      garantissant la cohérence validation_status / quality_score
-- =============================================================================

-- =============================================================================
-- PARTIE 1 : FONCTION TRIGGER
-- =============================================================================
CREATE OR REPLACE FUNCTION iot_raw.trg_fn_validate_sensor()
RETURNS TRIGGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER          -- s'exécute avec les droits postgres
SET search_path = iot_raw, iot_clean, iot_quarantine, dba_schema, pg_catalog
AS $$
DECLARE
    -- Résultat de fn_compute_quality_score
    v_score   SMALLINT;
    v_reason  TEXT;
    v_details JSONB;

    -- Décomposition des codes raisons pour anomaly_log (ex: 'WARNING_LOW|ZSCORE_ANOMALY')
    v_reason_codes TEXT[];
    v_code         TEXT;
BEGIN
    -- =========================================================================
    -- ÉTAPE 1 : Appel du moteur de scoring
    --   fn_compute_quality_score retourne un SETOF (1 ligne unique)
    -- =========================================================================
    SELECT qs.score, qs.reason, qs.details
    INTO   v_score, v_reason, v_details
    FROM   dba_schema.fn_compute_quality_score(
               NEW.sensor_id,
               NEW.sensor_type,
               NEW.value,
               NEW.recorded_at
           ) qs;

    -- =========================================================================
    -- ÉTAPE 2 : Mise à jour de NEW (colonne persistée dans iot_raw)
    -- =========================================================================
    NEW.quality_score := v_score;
    NEW.validation_status := CASE
        WHEN v_score >= 70 THEN 'valid'
        ELSE                    'quarantined'
    END;

    -- =========================================================================
    -- ÉTAPE 3A : Score >= 70 → copie dans iot_clean.sensor_readings
    --   On insère les colonnes métier uniquement (pas les colonnes de gestion
    --   interne à iot_raw comme ingestion_id si elle existe).
    --   ON CONFLICT DO NOTHING : protection contre une double-insertion
    --   rare mais possible en cas de retry côté IoT broker.
    -- =========================================================================
    IF v_score >= 70 THEN
        INSERT INTO iot_clean.sensor_readings (
            sensor_id,
            sensor_type,
            value,
            unit,
            recorded_at,
            quality_score,
            validation_status,
            raw_reading_id    -- FK vers iot_raw.sensor_readings.id (traçabilité)
        )
        VALUES (
            NEW.sensor_id,
            NEW.sensor_type,
            NEW.value,
            NEW.unit,
            NEW.recorded_at,
            NEW.quality_score,
            NEW.validation_status,
            NEW.id            -- NEW.id est disponible en BEFORE INSERT sur tables avec DEFAULT
        )
        ON CONFLICT DO NOTHING;

    -- =========================================================================
    -- ÉTAPE 3B : Score < 70 → quarantaine + anomaly_log
    -- =========================================================================
    ELSE
        -- 3B-1 : rejected_readings
        INSERT INTO iot_quarantine.rejected_readings (
            sensor_id,
            sensor_type,
            value,
            unit,
            recorded_at,
            quality_score,
            rejection_reason,   -- code(s) raison(s) : 'OUT_OF_RANGE', 'ZSCORE_ANOMALY', etc.
            rejection_details,  -- JSONB complet depuis fn_compute_quality_score
            raw_reading_id
        )
        VALUES (
            NEW.sensor_id,
            NEW.sensor_type,
            NEW.value,
            NEW.unit,
            NEW.recorded_at,
            NEW.quality_score,
            v_reason,
            v_details,
            NEW.id
        );

        -- 3B-2 : anomaly_log — une ligne par code raison individuel
        --   Permet des agrégations par type d'anomalie dans les vues et tableaux de bord
        v_reason_codes := string_to_array(v_reason, '|');

        FOREACH v_code IN ARRAY v_reason_codes
        LOOP
            INSERT INTO iot_quarantine.anomaly_log (
                sensor_id,
                sensor_type,
                recorded_at,
                anomaly_type,           -- code individuel : 'OUT_OF_RANGE', 'WARNING_HIGH', etc.
                quality_score,
                anomaly_details,        -- JSONB complet (même contenu, contexte par code)
                raw_reading_id,
                detected_at             -- horodatage de détection (≠ recorded_at)
            )
            VALUES (
                NEW.sensor_id,
                NEW.sensor_type,
                NEW.recorded_at,
                v_code,
                NEW.quality_score,
                v_details,
                NEW.id,
                clock_timestamp()       -- temps réel de détection, pas now()
            );
        END LOOP;
    END IF;

    -- Retour du NEW modifié → PostgreSQL l'utilise pour l'INSERT effectif dans iot_raw
    RETURN NEW;

-- =============================================================================
-- BLOC EXCEPTION : filet de sécurité — l'ingestion IoT ne doit JAMAIS être bloquée
--   Toute erreur non prévue (contrainte, type, réseau interne) est absorbée ici.
--   La mesure est quand même insérée dans iot_raw avec validation_status='error'.
--   Le DBA surveille iot_raw.ingestion_errors via v_data_quality_dashboard.
-- =============================================================================
EXCEPTION
    WHEN OTHERS THEN
        -- Marquage de la ligne comme en erreur avant insertion dans iot_raw
        NEW.validation_status := 'error';
        NEW.quality_score     := NULL;

        -- Log de l'erreur dans iot_raw.ingestion_errors
        BEGIN
            INSERT INTO iot_raw.ingestion_errors (
                sensor_id,
                sensor_type,
                raw_value,          -- valeur brute au moment de l'erreur
                recorded_at,
                error_code,
                error_message,
                error_context,      -- JSONB : NEW complet + stack partielle
                occurred_at
            )
            VALUES (
                NEW.sensor_id,
                NEW.sensor_type,
                NEW.value::TEXT,    -- cast TEXT : la valeur peut être hors-type
                NEW.recorded_at,
                SQLSTATE,
                SQLERRM,
                jsonb_build_object(
                    'sensor_id',    NEW.sensor_id,
                    'sensor_type',  NEW.sensor_type,
                    'value',        NEW.value,
                    'unit',         NEW.unit,
                    'recorded_at',  NEW.recorded_at,
                    'trigger',      'trg_validate_sensor',
                    'sqlstate',     SQLSTATE,
                    'sqlerrm',      SQLERRM
                ),
                clock_timestamp()
            );
        EXCEPTION
            WHEN OTHERS THEN
                -- Si même l'INSERT dans ingestion_errors échoue (ex: table pleine),
                -- on écrit dans pg_log via RAISE WARNING — dernier recours
                RAISE WARNING
                    '[trg_validate_sensor] IMPOSSIBLE de loguer dans ingestion_errors. '
                    'sensor_id=% sensor_type=% value=% | Erreur origine : % — %',
                    NEW.sensor_id, NEW.sensor_type, NEW.value,
                    SQLERRM, SQLSTATE;
        END;

        -- Pas de RAISE → NEW est retourné, l'INSERT dans iot_raw aboutit
        RETURN NEW;
END;
$$;

-- =============================================================================
-- PARTIE 2 : TRIGGER (attachement à la table)
-- =============================================================================
-- Suppression préalable si le trigger existe déjà (idempotence)
DROP TRIGGER IF EXISTS trg_validate_sensor ON iot_raw.sensor_readings;

CREATE TRIGGER trg_validate_sensor
    BEFORE INSERT                    -- BEFORE : on modifie NEW avant écriture physique
    ON iot_raw.sensor_readings
    FOR EACH ROW                     -- row-level : 1 appel par mesure IoT
    EXECUTE FUNCTION iot_raw.trg_fn_validate_sensor();

-- =============================================================================
-- PARTIE 3 : DROITS
-- =============================================================================
-- La fonction trigger ne s'appelle qu'automatiquement via le trigger.
-- aciertech_app INSERT sur iot_raw.sensor_readings → trigger s'active.
-- Pas de GRANT EXECUTE direct nécessaire (PostgreSQL l'exécute avec les droits
-- du trigger qui sont ceux du SECURITY DEFINER = postgres).
REVOKE ALL ON FUNCTION iot_raw.trg_fn_validate_sensor() FROM PUBLIC;

-- =============================================================================
-- COMMENTAIRES
-- =============================================================================
COMMENT ON FUNCTION iot_raw.trg_fn_validate_sensor() IS
'Fonction trigger BEFORE INSERT sur iot_raw.sensor_readings.
Appelle fn_compute_quality_score(), met à jour NEW.quality_score et
NEW.validation_status, puis route vers iot_clean (score >= 70) ou
iot_quarantine (score < 70, avec anomaly_log par code raison).
EXCEPTION absorbée : log dans iot_raw.ingestion_errors sans RAISE,
pour ne jamais bloquer l''ingestion IoT. SECURITY DEFINER = droits postgres.
Compatible pool_mode=transaction.';

COMMENT ON TRIGGER trg_validate_sensor ON iot_raw.sensor_readings IS
'Déclenche trg_fn_validate_sensor() avant chaque INSERT dans iot_raw.sensor_readings.
Point d''entrée unique du pipeline de qualité IoT AcierTech.';