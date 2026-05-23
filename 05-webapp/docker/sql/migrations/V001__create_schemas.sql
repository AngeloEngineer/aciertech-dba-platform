-- =============================================================================
-- AcierTech Industries — Migration V001
-- Objet    : Création des 4 schémas de l'architecture Data Quality
-- Auteur   : INF1620 DBA PostgreSQL 16
-- Prérequis: Base aciertech_db créée (00_create_database.sh)
-- =============================================================================
-- ARCHITECTURE DES SCHÉMAS :
--
--   iot_raw        → Réception brute de tous les capteurs (avant validation)
--   iot_clean      → Données validées, prêtes pour le système IA
--   iot_quarantine → Données rejetées, en attente d'audit humain
--   dba_schema     → Administration : seuils, backups, migrations, métriques
--
-- FLUX :
--   Capteur IoT → iot_raw.sensor_readings (INSERT)
--                      ↓ trigger trg_validate_sensor
--            ┌──────────────────────┐
--            ↓ score ≥ 70           ↓ score < 70
--   iot_clean.sensor_readings   iot_quarantine.rejected_readings
--            ↓
--   Système IA (aciertech_ro, lecture seule)
-- =============================================================================

-- Schéma de réception brute — toutes les données IoT arrivent ici
CREATE SCHEMA IF NOT EXISTS iot_raw;
COMMENT ON SCHEMA iot_raw IS
  'Réception brute des mesures IoT. Toutes les données passent ici avant '
  'validation. Écritures via aciertech_app. Trigger de validation intégré.';

-- Schéma des données validées — alimentant le système IA
CREATE SCHEMA IF NOT EXISTS iot_clean;
COMMENT ON SCHEMA iot_clean IS
  'Données IoT validées (score qualité ≥ 70/100). Source unique pour le '
  'système IA de maintenance prédictive. Lecture seule pour aciertech_ro.';

-- Schéma de quarantaine — données rejetées pour audit
CREATE SCHEMA IF NOT EXISTS iot_quarantine;
COMMENT ON SCHEMA iot_quarantine IS
  'Données IoT rejetées par le pipeline de validation (score < 70/100 ou '
  'violation de contrainte physique absolue). Conservées pour audit DBA '
  'et recalibrage des capteurs. Correspond aux 12% aberrants initiaux.';

-- Schéma d'administration DBA
CREATE SCHEMA IF NOT EXISTS dba_schema;
COMMENT ON SCHEMA dba_schema IS
  'Administration DBA : seuils capteurs, historique backups, migration_history, '
  'métriques de qualité agrégées. Accès restreint : postgres + aciertech_app '
  'en lecture pour stats. JAMAIS exposé à aciertech_ro.';