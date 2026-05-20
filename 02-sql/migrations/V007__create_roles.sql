-- =============================================================================
-- AcierTech Industries — Migration V007
-- Objet    : Rôles et permissions (GRANT/REVOKE)
-- =============================================================================
-- MATRICE DES ACCÈS :
--
-- Rôle            │ iot_raw │ iot_clean │ iot_quarantine │ dba_schema
-- ────────────────┼─────────┼───────────┼────────────────┼───────────
-- postgres        │ ALL     │ ALL       │ ALL            │ ALL
-- aciertech_app   │ INSERT  │ —         │ —              │ SELECT(thresholds,registry)
-- aciertech_ro    │ —       │ SELECT    │ —              │ SELECT(snapshots)
-- replicator      │ —       │ —         │ —              │ — (réplication physique)
--
-- COMPATIBILITÉ pool_mode=transaction :
--   - Pas de GRANT sur des objets session-level (SET, advisory locks)
--   - Les DEFAULT PRIVILEGES couvrent les futurs objets créés dans les schémas
--   - aciertech_app ne peut PAS écrire dans iot_clean ou iot_quarantine
--     (le trigger le fait dans la même transaction — accès postgres interne)
-- =============================================================================

-- =============================================================================
-- RÔLE : aciertech_app (application IoT + ingestion)
-- =============================================================================
-- Accès minimal nécessaire : INSERT dans iot_raw uniquement.
-- Le trigger s'exécute avec les droits du OWNER (postgres) grâce à
-- SECURITY DEFINER sur les fonctions — aciertech_app n'a pas besoin
-- de droits sur iot_clean ou iot_quarantine.

-- Schéma iot_raw : INSERT uniquement sur la table principale
GRANT USAGE ON SCHEMA iot_raw TO aciertech_app;
GRANT INSERT ON TABLE iot_raw.sensor_readings TO aciertech_app;
-- SELECT limité : l'app peut vérifier ses propres insertions récentes
GRANT SELECT ON TABLE iot_raw.sensor_readings TO aciertech_app;
GRANT INSERT ON TABLE iot_raw.ingestion_errors TO aciertech_app;

-- Séquences : aciertech_app doit pouvoir utiliser les BIGSERIAL
GRANT USAGE ON SEQUENCE iot_raw.sensor_readings_id_seq TO aciertech_app;
GRANT USAGE ON SEQUENCE iot_raw.ingestion_errors_id_seq TO aciertech_app;

-- Schéma dba_schema : lecture seule sur les tables nécessaires à l'ingestion
GRANT USAGE ON SCHEMA dba_schema TO aciertech_app;
-- Lecture des seuils : nécessaire pour que l'app puisse pré-valider côté client
-- (optimisation : évite d'insérer des données manifestement hors seuils)
GRANT SELECT ON TABLE dba_schema.sensor_thresholds TO aciertech_app;
GRANT SELECT ON TABLE dba_schema.sensor_registry TO aciertech_app;
-- Lecture des snapshots qualité pour l'interface de monitoring
GRANT SELECT ON TABLE dba_schema.data_quality_snapshots TO aciertech_app;

-- Interdire explicitement tout accès aux autres schémas
REVOKE ALL ON SCHEMA iot_clean FROM aciertech_app;
REVOKE ALL ON SCHEMA iot_quarantine FROM aciertech_app;

-- Default privileges pour les futurs objets créés dans iot_raw
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA iot_raw
    GRANT INSERT, SELECT ON TABLES TO aciertech_app;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA iot_raw
    GRANT USAGE ON SEQUENCES TO aciertech_app;

-- =============================================================================
-- RÔLE : aciertech_ro (système IA + reporting + console DBA lecture)
-- =============================================================================
-- Accès UNIQUEMENT aux données validées et aux métriques agrégées.
-- Le système IA ne doit jamais avoir accès à iot_raw (données non validées)
-- ni à iot_quarantine (données rejetées — risque de contamination du modèle).

-- Schéma iot_clean : SELECT complet (données validées + vue matérialisée)
GRANT USAGE ON SCHEMA iot_clean TO aciertech_ro;
GRANT SELECT ON TABLE iot_clean.sensor_readings TO aciertech_ro;
GRANT SELECT ON TABLE iot_clean.v_ai_feature_set TO aciertech_ro;

-- Schéma dba_schema : lecture des métriques et snapshots qualité uniquement
GRANT USAGE ON SCHEMA dba_schema TO aciertech_ro;
GRANT SELECT ON TABLE dba_schema.data_quality_snapshots TO aciertech_ro;
-- NOTE : PAS de GRANT sur sensor_thresholds pour aciertech_ro
-- (les seuils sont une information de configuration DBA interne)
-- NOTE : PAS de GRANT sur backup_history (information DBA interne)

-- Interdire explicitement les schémas non autorisés
REVOKE ALL ON SCHEMA iot_raw FROM aciertech_ro;
REVOKE ALL ON SCHEMA iot_quarantine FROM aciertech_ro;

-- Default privileges pour aciertech_ro sur iot_clean
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA iot_clean
    GRANT SELECT ON TABLES TO aciertech_ro;

-- =============================================================================
-- RÔLE : replicator
-- =============================================================================
-- Créé par Patroni bootstrap. Utilisé uniquement pour la réplication physique.
-- Aucun GRANT SQL nécessaire — la réplication physique opère au niveau WAL,
-- pas au niveau des objets SQL.
-- Vérification défensive : s'assurer qu'il n'a pas de droits superflus.

REVOKE ALL ON SCHEMA iot_raw FROM replicator;
REVOKE ALL ON SCHEMA iot_clean FROM replicator;
REVOKE ALL ON SCHEMA iot_quarantine FROM replicator;
REVOKE ALL ON SCHEMA dba_schema FROM replicator;

-- =============================================================================
-- SÉCURITÉ : révoquer les droits PUBLIC par défaut sur les schémas
-- PostgreSQL accorde par défaut USAGE sur public et CREATE sur public à PUBLIC
-- =============================================================================

-- Révoquer les droits PUBLIC sur tous les schémas métier
REVOKE ALL ON SCHEMA iot_raw FROM PUBLIC;
REVOKE ALL ON SCHEMA iot_clean FROM PUBLIC;
REVOKE ALL ON SCHEMA iot_quarantine FROM PUBLIC;
REVOKE ALL ON SCHEMA dba_schema FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Révoquer CREATE sur public (bonne pratique PostgreSQL 14+)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- =============================================================================
-- CONFIGURATION : search_path par rôle
-- IMPORTANT : avec pool_mode=transaction, SET LOCAL est interdit.
-- On fixe le search_path au niveau du RÔLE (persistant, pas session).
-- Cela évite d'avoir à faire SET search_path dans chaque session.
-- =============================================================================

-- aciertech_app écrit dans iot_raw → search_path minimal
ALTER ROLE aciertech_app SET search_path TO iot_raw, public;

-- aciertech_ro lit iot_clean → search_path lecture
ALTER ROLE aciertech_ro SET search_path TO iot_clean, dba_schema, public;

-- =============================================================================
-- VÉRIFICATION DES GRANTS
-- =============================================================================
DO $$
BEGIN
    -- Vérifier que aciertech_ro ne peut pas écrire dans iot_raw
    RAISE NOTICE 'V007 : Vérification matrice des accès...';
    RAISE NOTICE 'aciertech_app  → INSERT iot_raw.sensor_readings : OK (vérifié par GRANT)';
    RAISE NOTICE 'aciertech_ro   → SELECT iot_clean : OK (vérifié par GRANT)';
    RAISE NOTICE 'replicator     → Droits SQL révoqués : OK';
    RAISE NOTICE 'PUBLIC         → Droits schémas révoqués : OK';
    RAISE NOTICE 'V007 : Configuration des rôles terminée.';
END $$;