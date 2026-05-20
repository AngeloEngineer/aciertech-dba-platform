-- =============================================================================
-- PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
-- FICHIER   : 02-sql/triggers/trg_audit_changes.sql
-- OBJET     : Audit des modifications de seuils capteur (qui, quoi, quand)
-- DÉPEND DE : V005 (dba_schema.sensor_thresholds)
-- CRÉE      : dba_schema.threshold_audit_log (table d'audit dans ce fichier)
-- AUTEUR    : DBA AcierTech / INF1620
-- VERSION   : 1.0 — PostgreSQL 16
-- =============================================================================
--
-- POURQUOI AUDITER sensor_thresholds ?
-- ─────────────────────────────────────
--   Les seuils pilotent directement le classement des mesures IoT et les alertes
--   de maintenance prédictive. Une modification erronée (ex: warning_max vibration
--   porté trop haut sur un laminoir) peut masquer des anomalies critiques.
--   L'audit complet (OLD / NEW, rôle, timestamp exact) permet :
--     • Traçabilité réglementaire (maintenance industrielle ISO)
--     • Retour arrière manuel si nécessaire (les valeurs OLD sont stockées)
--     • Corrélation avec des incidents machines dans le temps
--
-- DESIGN DE L'AUDIT
-- ─────────────────
--   • Trigger AFTER UPDATE OR DELETE (pas INSERT : on veut les changements)
--   • Une ligne par colonne modifiée (granularité maximale pour les requêtes)
--     → comparaison textuelle après CAST pour couvrir tous les types
--   • Capture de current_user (rôle DB) + session_user (rôle de connexion)
--   • JSONB pour old_value / new_value : homogène, requêtable, extensible
--
-- COMPATIBILITÉ pgBouncer pool_mode=transaction
-- ─────────────────────────────────────────────
--   ✓  Pas d'advisory locks
--   ✓  Pas de SET LOCAL
--   ✓  AFTER trigger : pas de modification de NEW, lecture seule OLD/NEW
--   ✓  SET search_path au niveau OPTION de la fonction
-- =============================================================================


-- =============================================================================
-- PARTIE 1 : TABLE D'AUDIT
-- =============================================================================
CREATE TABLE IF NOT EXISTS dba_schema.threshold_audit_log (
    audit_id        BIGSERIAL       PRIMARY KEY,

    -- Contexte de l'opération
    operation       CHAR(1)         NOT NULL CHECK (operation IN ('U', 'D')),
                                    -- 'U' = UPDATE, 'D' = DELETE

    -- Identifiant du seuil modifié
    sensor_id       INTEGER         NOT NULL,   -- FK logique vers sensor_thresholds
    sensor_type     VARCHAR(50)     NOT NULL,   -- dénormalisé pour lisibilité de l'audit

    -- Colonne modifiée (une ligne par champ changé)
    column_name     TEXT            NOT NULL,

    -- Valeurs avant/après
    old_value       JSONB,          -- NULL pour INSERT (non utilisé ici), valeur avant pour UPDATE/DELETE
    new_value       JSONB,          -- NULL pour DELETE

    -- Contexte de session
    changed_by      TEXT            NOT NULL DEFAULT current_user,
                                    -- rôle PostgreSQL actif (ex: postgres, aciertech_app)
    session_user_db TEXT            NOT NULL DEFAULT session_user,
                                    -- rôle de connexion (utile si SET ROLE a été utilisé)
    application_name TEXT,          -- pg_stat_activity.application_name (outil / service)
    client_addr     INET,           -- IP du client pour traçabilité réseau

    -- Horodatage
    changed_at      TIMESTAMPTZ     NOT NULL DEFAULT clock_timestamp(),

    -- Contexte additionnel libre
    audit_note      TEXT            -- commentaire éventuel (non utilisé par le trigger,
                                    -- peut être renseigné manuellement par le DBA)
);

-- Index pour les requêtes d'audit courantes
CREATE INDEX IF NOT EXISTS idx_audit_log_sensor_id
    ON dba_schema.threshold_audit_log (sensor_id, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at
    ON dba_schema.threshold_audit_log (changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_log_changed_by
    ON dba_schema.threshold_audit_log (changed_by, changed_at DESC);

-- Rétention : pas de partitionnement pour cette table (volume faible attendu).
-- Une purge manuelle ou par pg_cron suffira (voir pg_cron_jobs.sql).

COMMENT ON TABLE dba_schema.threshold_audit_log IS
'Journal d''audit des modifications (UPDATE/DELETE) sur dba_schema.sensor_thresholds.
Une ligne par colonne modifiée. Alimenté par trg_audit_threshold_changes.
Sert à la traçabilité réglementaire et à la corrélation incidents/seuils.';

COMMENT ON COLUMN dba_schema.threshold_audit_log.operation     IS 'U=UPDATE, D=DELETE';
COMMENT ON COLUMN dba_schema.threshold_audit_log.column_name   IS 'Nom de la colonne modifiée dans sensor_thresholds';
COMMENT ON COLUMN dba_schema.threshold_audit_log.old_value     IS 'Valeur avant modification (JSONB pour homogénéité des types)';
COMMENT ON COLUMN dba_schema.threshold_audit_log.new_value     IS 'Valeur après modification. NULL pour DELETE.';
COMMENT ON COLUMN dba_schema.threshold_audit_log.changed_by    IS 'Rôle PostgreSQL actif au moment de l''opération (current_user)';
COMMENT ON COLUMN dba_schema.threshold_audit_log.session_user_db IS 'Rôle de connexion (session_user) — diffère de changed_by si SET ROLE';


-- =============================================================================
-- PARTIE 2 : FONCTION TRIGGER
-- =============================================================================
CREATE OR REPLACE FUNCTION dba_schema.trg_fn_audit_threshold_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = dba_schema, pg_catalog
AS $$
DECLARE
    -- Colonnes de sensor_thresholds à auditer
    -- On exclut : sensor_id (PK, jamais modifiée), updated_at (gérée par son propre trigger)
    v_audited_columns TEXT[] := ARRAY[
        'sensor_type',
        'min_value',
        'max_value',
        'warning_min',
        'warning_max',
        'zscore_threshold',
        'expected_interval_s',
        'unit',
        'description'
    ];

    v_col           TEXT;
    v_old_val       TEXT;
    v_new_val       TEXT;
    v_has_changes   BOOLEAN := FALSE;

    -- Contexte de session (capturé une fois pour toutes les lignes d'audit)
    v_app_name      TEXT;
    v_client_addr   INET;
BEGIN
    -- Capture du contexte de session depuis pg_stat_activity
    -- (clock_timestamp() garantit la valeur au moment du trigger, pas du début de txn)
    SELECT application_name, client_addr
    INTO   v_app_name, v_client_addr
    FROM   pg_stat_activity
    WHERE  pid = pg_backend_pid();

    -- =========================================================================
    -- CAS 1 : DELETE — on trace toutes les valeurs OLD (état complet supprimé)
    -- =========================================================================
    IF TG_OP = 'DELETE' THEN
        FOREACH v_col IN ARRAY v_audited_columns
        LOOP
            -- Extraction de la valeur OLD par nom de colonne dynamique via hstore
            -- Alternative portable (pas besoin d'extension hstore) : CASE explicite
            v_old_val := CASE v_col
                WHEN 'sensor_type'         THEN OLD.sensor_type::TEXT
                WHEN 'min_value'           THEN OLD.min_value::TEXT
                WHEN 'max_value'           THEN OLD.max_value::TEXT
                WHEN 'warning_min'         THEN OLD.warning_min::TEXT
                WHEN 'warning_max'         THEN OLD.warning_max::TEXT
                WHEN 'zscore_threshold'    THEN OLD.zscore_threshold::TEXT
                WHEN 'expected_interval_s' THEN OLD.expected_interval_s::TEXT
                WHEN 'unit'                THEN OLD.unit::TEXT
                WHEN 'description'         THEN OLD.description::TEXT
            END;

            INSERT INTO dba_schema.threshold_audit_log (
                operation, sensor_id, sensor_type,
                column_name, old_value, new_value,
                changed_by, session_user_db,
                application_name, client_addr
            )
            VALUES (
                'D',
                OLD.sensor_id,
                OLD.sensor_type,
                v_col,
                to_jsonb(v_old_val),
                NULL,               -- DELETE : pas de new_value
                current_user,
                session_user,
                v_app_name,
                v_client_addr
            );
        END LOOP;

        RETURN OLD;
    END IF;

    -- =========================================================================
    -- CAS 2 : UPDATE — on ne trace QUE les colonnes effectivement modifiées
    --   Comparaison TEXT après CAST : couvre tous les types numériques / textes
    --   IS DISTINCT FROM : gère les NULL (NULL != NULL est TRUE ici, comme attendu)
    -- =========================================================================
    IF TG_OP = 'UPDATE' THEN
        FOREACH v_col IN ARRAY v_audited_columns
        LOOP
            v_old_val := CASE v_col
                WHEN 'sensor_type'         THEN OLD.sensor_type::TEXT
                WHEN 'min_value'           THEN OLD.min_value::TEXT
                WHEN 'max_value'           THEN OLD.max_value::TEXT
                WHEN 'warning_min'         THEN OLD.warning_min::TEXT
                WHEN 'warning_max'         THEN OLD.warning_max::TEXT
                WHEN 'zscore_threshold'    THEN OLD.zscore_threshold::TEXT
                WHEN 'expected_interval_s' THEN OLD.expected_interval_s::TEXT
                WHEN 'unit'                THEN OLD.unit::TEXT
                WHEN 'description'         THEN OLD.description::TEXT
            END;

            v_new_val := CASE v_col
                WHEN 'sensor_type'         THEN NEW.sensor_type::TEXT
                WHEN 'min_value'           THEN NEW.min_value::TEXT
                WHEN 'max_value'           THEN NEW.max_value::TEXT
                WHEN 'warning_min'         THEN NEW.warning_min::TEXT
                WHEN 'warning_max'         THEN NEW.warning_max::TEXT
                WHEN 'zscore_threshold'    THEN NEW.zscore_threshold::TEXT
                WHEN 'expected_interval_s' THEN NEW.expected_interval_s::TEXT
                WHEN 'unit'                THEN NEW.unit::TEXT
                WHEN 'description'         THEN NEW.description::TEXT
            END;

            -- N'insérer une ligne que si la valeur a réellement changé
            IF v_old_val IS DISTINCT FROM v_new_val THEN
                v_has_changes := TRUE;

                INSERT INTO dba_schema.threshold_audit_log (
                    operation, sensor_id, sensor_type,
                    column_name, old_value, new_value,
                    changed_by, session_user_db,
                    application_name, client_addr
                )
                VALUES (
                    'U',
                    NEW.sensor_id,
                    NEW.sensor_type,
                    v_col,
                    to_jsonb(v_old_val),
                    to_jsonb(v_new_val),
                    current_user,
                    session_user,
                    v_app_name,
                    v_client_addr
                );
            END IF;
        END LOOP;

        -- Si aucune colonne auditée n'a changé (ex: UPDATE qui ne touche qu'updated_at),
        -- on ne génère aucune ligne d'audit — comportement attendu.
        IF NOT v_has_changes THEN
            RAISE NOTICE
                '[trg_audit_threshold_changes] UPDATE sur sensor_id=% : '
                'aucune colonne auditée modifiée, pas de ligne insérée.',
                NEW.sensor_id;
        END IF;

        RETURN NEW;
    END IF;

    -- Cas non couvert (ne devrait pas arriver avec FOR EACH ROW UPDATE OR DELETE)
    RETURN NULL;

EXCEPTION
    WHEN OTHERS THEN
        -- L'audit ne doit JAMAIS bloquer une modification de seuil opérationnelle.
        -- On logue dans pg_log et on laisse passer l'opération.
        RAISE WARNING
            '[trg_audit_threshold_changes] ERREUR lors de l''audit sensor_id=% op=% : % — %',
            COALESCE(OLD.sensor_id::TEXT, NEW.sensor_id::TEXT),
            TG_OP,
            SQLERRM,
            SQLSTATE;

        -- On retourne le bon enregistrement selon l'opération
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        ELSE
            RETURN NEW;
        END IF;
END;
$$;


-- =============================================================================
-- PARTIE 3 : TRIGGER (attachement à la table)
-- =============================================================================
DROP TRIGGER IF EXISTS trg_audit_threshold_changes ON dba_schema.sensor_thresholds;

CREATE TRIGGER trg_audit_threshold_changes
    AFTER UPDATE OR DELETE          -- AFTER : OLD et NEW sont tous deux disponibles
    ON dba_schema.sensor_thresholds
    FOR EACH ROW
    EXECUTE FUNCTION dba_schema.trg_fn_audit_threshold_changes();

-- =============================================================================
-- PARTIE 4 : DROITS
-- =============================================================================
-- La table d'audit est en lecture pour aciertech_ro (consultation dashboards)
-- Écriture exclusivement via le trigger (SECURITY DEFINER = postgres)
REVOKE ALL ON TABLE dba_schema.threshold_audit_log FROM PUBLIC;
GRANT SELECT ON dba_schema.threshold_audit_log TO aciertech_ro;

-- La fonction trigger n'est pas appelable directement
REVOKE ALL ON FUNCTION dba_schema.trg_fn_audit_threshold_changes() FROM PUBLIC;

-- La séquence BIGSERIAL est utilisée en interne par le trigger (droits postgres)
GRANT USAGE ON SEQUENCE dba_schema.threshold_audit_log_audit_id_seq TO postgres;

COMMENT ON FUNCTION dba_schema.trg_fn_audit_threshold_changes() IS
'Fonction trigger AFTER UPDATE OR DELETE sur dba_schema.sensor_thresholds.
Insère une ligne dans threshold_audit_log par colonne effectivement modifiée.
Capture : current_user, session_user, application_name, client_addr.
Ne bloque jamais l''opération source (EXCEPTION absorbée avec RAISE WARNING).
SECURITY DEFINER. Compatible pool_mode=transaction.';

COMMENT ON TRIGGER trg_audit_threshold_changes ON dba_schema.sensor_thresholds IS
'Audit complet des modifications de seuils capteur. Alimenté trg_fn_audit_threshold_changes().
Une ligne par colonne modifiée dans dba_schema.threshold_audit_log.';