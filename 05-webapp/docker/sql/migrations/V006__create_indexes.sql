-- =============================================================================
-- AcierTech Industries — Migration V006
-- Objet    : Index de performance
-- =============================================================================
-- RÈGLE CRITIQUE : Ce fichier s'exécute APRÈS les tables (V002-V005)
-- et AVANT les triggers (triggers/) et les vues (views/).
-- Un index absent au moment où le trigger commence à écrire = plans foireux
-- dès la première requête, et toute requête >1s est loggée (patroni.yml).
--
-- STRATÉGIE D'INDEXATION :
--   - iot_raw     : optimisé pour les INSERTs rapides + lookups trigger
--   - iot_clean   : optimisé pour les lectures analytiques du système IA
--   - iot_quarantine : optimisé pour les revues DBA et le monitoring
--   - dba_schema  : optimisé pour les lookups trigger (sensor_thresholds)
--
-- CONVENTION DE NOMMAGE :
--   idx_{schema}_{table}_{colonnes}[_{type}]
--   Exemples : idx_raw_sr_sensor_time, idx_clean_sr_sensor_time_brin
-- =============================================================================

-- =============================================================================
-- SCHÉMA iot_raw
-- =============================================================================

-- Index principal pour les lookups du trigger (Z-score sur fenêtre glissante 1h)
-- La fonction fn_compute_quality_score() exécute :
--   SELECT AVG(value), STDDEV(value) FROM iot_raw.sensor_readings
--   WHERE sensor_id = $1 AND sensor_type = $2
--   AND recorded_at >= NOW() - INTERVAL '1 hour'
--   AND validation_status = 'valid'
-- Sans cet index : Seq Scan sur des millions de lignes → dépassement 1s garanti
CREATE INDEX IF NOT EXISTS idx_raw_sr_sensor_type_time_status
    ON iot_raw.sensor_readings (sensor_id, sensor_type, recorded_at DESC)
    WHERE validation_status = 'valid';

COMMENT ON INDEX idx_raw_sr_sensor_type_time_status IS
    'Index partiel critique : supporte le calcul Z-score dans le trigger. '
    'Partiel sur validation_status=valid pour exclure les lignes pending/quarantined '
    'de l''index (gain de taille ~30%). Ordre DESC sur recorded_at = '
    'les données récentes sont en tête de l''index (fenêtre 1h du trigger).';

-- Index pour les requêtes de monitoring : "combien de données reçues par capteur ?"
CREATE INDEX IF NOT EXISTS idx_raw_sr_received_at
    ON iot_raw.sensor_readings (received_at DESC);

COMMENT ON INDEX idx_raw_sr_received_at IS
    'Supporte les requêtes de volume et de monitoring pgBouncer/Grafana '
    'sur les insertions récentes (dernières 5/60 minutes).';

-- Index pour le dashboard Data Quality (vue v_data_quality_dashboard)
-- Requête : WHERE received_at >= NOW() - INTERVAL '1 hour' GROUP BY sensor_type
CREATE INDEX IF NOT EXISTS idx_raw_sr_received_sensor_type
    ON iot_raw.sensor_readings (received_at DESC, sensor_type, validation_status);

-- Index pour retrouver rapidement les lignes 'pending' (nettoyage maintenance)
CREATE INDEX IF NOT EXISTS idx_raw_sr_pending
    ON iot_raw.sensor_readings (received_at)
    WHERE validation_status = 'pending';

COMMENT ON INDEX idx_raw_sr_pending IS
    'Index partiel pour détecter les lignes bloquées en statut pending '
    '(trigger échoué silencieusement). Requête de maintenance : '
    'SELECT COUNT(*) FROM iot_raw.sensor_readings WHERE validation_status=''pending'' '
    'AND received_at < NOW() - INTERVAL ''5 minutes''.';

-- BRIN index sur recorded_at pour les scans de plage temporelle large (rapports)
-- BRIN = très compact, idéal pour les données IoT insérées dans l'ordre chronologique
CREATE INDEX IF NOT EXISTS idx_raw_sr_recorded_at_brin
    ON iot_raw.sensor_readings USING BRIN (recorded_at)
    WITH (pages_per_range = 128);

COMMENT ON INDEX idx_raw_sr_recorded_at_brin IS
    'BRIN index pour les scans de plage temporelle sur les rapports historiques. '
    'Taille ~1000x plus petite qu''un B-tree équivalent. Efficace car les données '
    'IoT sont insérées dans l''ordre chronologique (corrélation physique élevée). '
    'Utiliser pour les requêtes: WHERE recorded_at BETWEEN $1 AND $2.';

-- Index pour ingestion_errors (résolution d'erreurs DBA)
CREATE INDEX IF NOT EXISTS idx_raw_errors_sensor_occurred
    ON iot_raw.ingestion_errors (sensor_id, occurred_at DESC)
    WHERE resolved = FALSE;

-- =============================================================================
-- SCHÉMA iot_clean
-- =============================================================================

-- Index principal pour les lectures analytiques du système IA
-- Requête IA type : WHERE sensor_id=$1 AND recorded_at >= NOW() - INTERVAL '24h'
CREATE INDEX IF NOT EXISTS idx_clean_sr_sensor_time
    ON iot_clean.sensor_readings (sensor_id, recorded_at DESC);

-- Index pour la vue matérialisée v_ai_feature_set (GROUP BY sensor_type, time_bucket)
CREATE INDEX IF NOT EXISTS idx_clean_sr_type_time
    ON iot_clean.sensor_readings (sensor_type, recorded_at DESC);

-- Index pour retrouver une ligne clean depuis sa ligne raw (jointure d'audit)
CREATE INDEX IF NOT EXISTS idx_clean_sr_original_id
    ON iot_clean.sensor_readings (original_id);

-- Index UNIQUE sur la vue matérialisée pour REFRESH CONCURRENT
-- Sans cet index UNIQUE, REFRESH MATERIALIZED VIEW CONCURRENTLY est impossible.
-- CONCURRENT = le refresh ne pose pas de verrou exclusif (IA peut lire pendant le refresh)
CREATE UNIQUE INDEX IF NOT EXISTS idx_clean_mv_ai_features_unique
    ON iot_clean.v_ai_feature_set (sensor_id, sensor_type, time_bucket);

COMMENT ON INDEX idx_clean_mv_ai_features_unique IS
    'Index UNIQUE obligatoire pour REFRESH MATERIALIZED VIEW CONCURRENTLY. '
    'Sans cet index, le refresh poserait un AccessExclusiveLock bloquant '
    'toutes les lectures du système IA pendant la durée du refresh (~30s). '
    'Avec CONCURRENTLY : refresh sans interruption de service.';

-- Index de la vue matérialisée pour les lectures IA par capteur
CREATE INDEX IF NOT EXISTS idx_clean_mv_ai_features_sensor_time
    ON iot_clean.v_ai_feature_set (sensor_id, time_bucket DESC);

-- =============================================================================
-- SCHÉMA iot_quarantine
-- =============================================================================

-- Index principal pour les revues DBA (non-revus en premier)
CREATE INDEX IF NOT EXISTS idx_quarantine_rejected_unreviewed
    ON iot_quarantine.rejected_readings (rejected_at DESC)
    WHERE reviewed = FALSE;

-- Index pour les analyses par capteur (identification capteurs défaillants)
CREATE INDEX IF NOT EXISTS idx_quarantine_rejected_sensor_time
    ON iot_quarantine.rejected_readings (sensor_id, rejected_at DESC);

-- Index pour les recherches par code de rejet (diagnostic Data Quality)
-- Utilise un index GIN sur le texte pour la recherche LIKE '%ZSCORE%'
CREATE INDEX IF NOT EXISTS idx_quarantine_rejected_reason_gin
    ON iot_quarantine.rejected_readings USING GIN (
        TO_TSVECTOR('simple', COALESCE(rejection_reason, ''))
    );

COMMENT ON INDEX idx_quarantine_rejected_reason_gin IS
    'Index GIN pour recherche de patterns dans rejection_reason. '
    'Requête DBA type : identifier tous les capteurs avec ZSCORE_OUTLIER '
    'sur les 24 dernières heures pour cibler les recalibrages.';

-- Index sur anomaly_log pour les dashboards Grafana (aggrégation par type)
CREATE INDEX IF NOT EXISTS idx_quarantine_anomaly_sensor_type_time
    ON iot_quarantine.anomaly_log (sensor_type, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_quarantine_anomaly_occurred_at_brin
    ON iot_quarantine.anomaly_log USING BRIN (occurred_at);

-- =============================================================================
-- SCHÉMA dba_schema
-- =============================================================================

-- Index sur sensor_thresholds : lookup critique du trigger
-- La fonction fn_compute_quality_score() fait :
--   SELECT * FROM dba_schema.sensor_thresholds WHERE sensor_id=$1 AND sensor_type=$2
-- Cet accès se produit pour CHAQUE INSERT dans iot_raw (~47 fois/seconde en prod)
-- La PK (sensor_id, sensor_type) couvre déjà ce cas, mais on ajoute un index
-- sur (sensor_type) seul pour les requêtes de type "tous les seuils température"
CREATE INDEX IF NOT EXISTS idx_dba_thresholds_type_active
    ON dba_schema.sensor_thresholds (sensor_type)
    WHERE is_active = TRUE;

-- Index sur backup_history pour les alertes Prometheus et le dashboard PRA
CREATE INDEX IF NOT EXISTS idx_dba_backup_history_type_status_completed
    ON dba_schema.backup_history (backup_type, status, completed_at DESC);

-- Index sur data_quality_snapshots pour les dashboards de tendance Grafana
CREATE INDEX IF NOT EXISTS idx_dba_quality_snapshots_time_type
    ON dba_schema.data_quality_snapshots (snapshot_at DESC, sensor_type);

-- Index sur sensor_registry pour le monitoring des capteurs silencieux
CREATE INDEX IF NOT EXISTS idx_dba_sensor_registry_active
    ON dba_schema.sensor_registry (sensor_type)
    WHERE is_active = TRUE;

-- migration_history : déjà indexée via PK (id) et UNIQUE (version)
-- Pas d'index supplémentaire nécessaire (table petite, accès rare)

-- =============================================================================
-- VÉRIFICATION (exécutée à la fin de la migration pour validation)
-- =============================================================================
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_indexes
    WHERE schemaname IN ('iot_raw', 'iot_clean', 'iot_quarantine', 'dba_schema')
      AND indexname LIKE 'idx_%';

    RAISE NOTICE 'V006 : % index applicatifs créés (hors PK/UK)', v_count;

    IF v_count < 15 THEN
        RAISE WARNING 'Nombre d''index inférieur à l''attendu (15 minimum). Vérifier les erreurs.';
    END IF;
END $$;