#!/usr/bin/env bash
# =============================================================================
# AcierTech Industries — Initialisation base de données
# Fichier  : 02-sql/init/00_create_database.sh
# Rôle     : Créer aciertech_db + utilisateur aciertech_ro (absent du bootstrap
#            Patroni) + extensions requises
# Exécution: Une seule fois, sur le nœud PRIMAIRE, après bootstrap Patroni
# Prérequis: Patroni UP, pg-node-1 PRIMARY confirmé via patronictl list
# =============================================================================
# Usage :
#   sudo -u postgres bash /opt/aciertech/02-sql/init/00_create_database.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — à aligner avec .env si utilisé
# ---------------------------------------------------------------------------
PG_BIN="/usr/lib/postgresql/16/bin"
PG_HOST="127.0.0.1"
PG_PORT="5432"
PG_SUPERUSER="postgres"
TARGET_DB="aciertech_db"
LOG_FILE="/var/log/aciertech/init_database.log"

# Couleurs pour la lisibilité console
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $1${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

# ---------------------------------------------------------------------------
# Prérequis
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
log "=== Début initialisation AcierTech DB ==="

# Vérifier que PostgreSQL répond
"$PG_BIN/pg_isready" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" \
  || err "PostgreSQL ne répond pas sur $PG_HOST:$PG_PORT — Patroni UP ?"

# Vérifier que ce nœud est bien le primaire (protection anti-accident)
IS_PRIMARY=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -tAc \
  "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END;")
[[ "$IS_PRIMARY" == "primary" ]] \
  || err "Ce nœud est un RÉPLICA ($IS_PRIMARY). Exécuter uniquement sur le primaire."
log "Nœud primaire confirmé"

# ---------------------------------------------------------------------------
# Création de la base aciertech_db
# Note : Patroni crée postgres/replicator/aciertech_app lors du bootstrap.
#        On crée ici la base et les objets complémentaires.
# ---------------------------------------------------------------------------
DB_EXISTS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -tAc \
  "SELECT 1 FROM pg_database WHERE datname = '$TARGET_DB';")

if [[ "$DB_EXISTS" == "1" ]]; then
  warn "Base '$TARGET_DB' déjà existante — création ignorée"
else
  psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" <<SQL
    CREATE DATABASE aciertech_db
      OWNER     = postgres
      ENCODING  = 'UTF8'
      LC_COLLATE = 'fr_FR.UTF-8'
      LC_CTYPE   = 'fr_FR.UTF-8'
      TEMPLATE  = template0;

    COMMENT ON DATABASE aciertech_db IS
      'AcierTech Industries — Base IoT principale. INF1620 DBA PostgreSQL 16 HA.';
SQL
  log "Base '$TARGET_DB' créée"
fi

# ---------------------------------------------------------------------------
# Création de l'utilisateur aciertech_ro
# ABSENT du bootstrap patroni-node1.yml → à créer ici obligatoirement
# Rôle : lecture seule pour le système IA + reporting + console DBA
# ---------------------------------------------------------------------------
RO_EXISTS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname = 'aciertech_ro';")

if [[ "$RO_EXISTS" == "1" ]]; then
  warn "Rôle 'aciertech_ro' déjà existant — création ignorée"
else
  # Mot de passe à externaliser dans .env en production
  RO_PASSWORD="${ACIERTECH_RO_PASSWORD:-ro_strong_password_here}"
  psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" <<SQL
    CREATE ROLE aciertech_ro
      WITH LOGIN
           NOSUPERUSER
           NOCREATEDB
           NOCREATEROLE
           NOINHERIT
           CONNECTION LIMIT 20
      PASSWORD '$RO_PASSWORD';

    COMMENT ON ROLE aciertech_ro IS
      'Lecture seule — système IA de maintenance prédictive + reporting DBA.
       pool_mode=transaction compatible : pas de SET, pas de LISTEN.';
SQL
  log "Rôle 'aciertech_ro' créé (CONNECTION LIMIT 20)"
fi

# ---------------------------------------------------------------------------
# Extensions requises (installées dans aciertech_db)
# ---------------------------------------------------------------------------
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d "$TARGET_DB" <<'SQL'

  -- pg_stat_statements : indispensable pour identifier les requêtes lentes
  -- (log_min_duration_statement=1000ms dans patroni.yml)
  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

  -- pgcrypto : hachage éventuel de données sensibles capteurs
  CREATE EXTENSION IF NOT EXISTS pgcrypto;

  -- pg_cron : planification des tâches de maintenance dans PostgreSQL
  -- (refresh vues matérialisées, nettoyage quarantaine, stats)
  -- Nécessite shared_preload_libraries='pg_cron' — voir note ci-dessous
  -- CREATE EXTENSION IF NOT EXISTS pg_cron;

  -- btree_gist : index GiST sur types scalaires (utile pour exclusion constraints)
  CREATE EXTENSION IF NOT EXISTS btree_gist;

SQL

log "Extensions installées : pg_stat_statements, pgcrypto, btree_gist"
warn "pg_cron commenté : ajouter 'pg_cron' dans shared_preload_libraries via Patroni DCS puis redémarrer"

# ---------------------------------------------------------------------------
# Connexion pgBouncer : accorder CONNECT à aciertech_ro sur aciertech_db
# (les GRANT de schémas seront faits dans V007__create_roles.sql)
# ---------------------------------------------------------------------------
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d "$TARGET_DB" <<'SQL'
  -- Révoquer le CONNECT public par défaut (sécurité)
  REVOKE CONNECT ON DATABASE aciertech_db FROM PUBLIC;

  -- Accorder explicitement aux rôles applicatifs
  GRANT CONNECT ON DATABASE aciertech_db TO aciertech_app;
  GRANT CONNECT ON DATABASE aciertech_db TO aciertech_ro;
  GRANT CONNECT ON DATABASE aciertech_db TO postgres;
SQL

log "Droits CONNECT sur aciertech_db configurés"
log "=== Initialisation terminée. Lancer 01_run_migrations.sh ==="