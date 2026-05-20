#!/usr/bin/env bash
# =============================================================================
# AcierTech Industries — Exécuteur de migrations SQL
# Fichier  : 02-sql/init/01_run_migrations.sh
# Rôle     : Exécuter les fichiers V*.sql dans l'ordre, de façon idempotente,
#            avec journalisation dans la table dba_schema.migration_history
# Exécution: Après 00_create_database.sh, sur le nœud PRIMAIRE
# =============================================================================
# Usage :
#   bash /opt/aciertech/02-sql/init/01_run_migrations.sh
#   bash /opt/aciertech/02-sql/init/01_run_migrations.sh --dry-run
#   bash /opt/aciertech/02-sql/init/01_run_migrations.sh --from V005
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_ROOT="$(dirname "$SCRIPT_DIR")"           # 02-sql/
MIGRATIONS_DIR="$SQL_ROOT/migrations"
PG_HOST="127.0.0.1"
PG_PORT="5432"
PG_USER="postgres"
TARGET_DB="aciertech_db"
LOG_FILE="/var/log/aciertech/migrations.log"
DRY_RUN=false
FROM_VERSION=""

# Couleurs
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $*${NC}" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}" | tee -a "$LOG_FILE"; }
err()    { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}" | tee -a "$LOG_FILE"; exit 1; }
info()   { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ $*${NC}" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Parsing arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --from)      FROM_VERSION="$2"; shift 2 ;;
    *) err "Argument inconnu : $1" ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"
[[ "$DRY_RUN" == true ]] && warn "=== MODE DRY-RUN : aucune modification appliquée ==="
log "=== Début exécution migrations AcierTech ==="

# ---------------------------------------------------------------------------
# Prérequis : nœud primaire uniquement
# ---------------------------------------------------------------------------
IS_PRIMARY=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" -tAc \
  "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END;")
[[ "$IS_PRIMARY" == "primary" ]] \
  || err "Ce nœud est un RÉPLICA. Migrations uniquement sur le primaire."

# ---------------------------------------------------------------------------
# Création de la table de suivi des migrations (idempotente)
# Placée dans dba_schema — créée ici en bootstrap minimal si le schéma
# n'existe pas encore (V001 le recréera proprement avec commentaires)
# ---------------------------------------------------------------------------
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" <<'SQL'
  CREATE SCHEMA IF NOT EXISTS dba_schema;

  CREATE TABLE IF NOT EXISTS dba_schema.migration_history (
    id              SERIAL PRIMARY KEY,
    version         VARCHAR(10)  NOT NULL UNIQUE,   -- ex: V001
    filename        VARCHAR(200) NOT NULL,
    checksum        VARCHAR(64)  NOT NULL,           -- SHA-256 du fichier
    applied_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    applied_by      TEXT         NOT NULL DEFAULT current_user,
    duration_ms     INTEGER,
    status          VARCHAR(20)  NOT NULL DEFAULT 'success'
      CHECK (status IN ('success', 'failed', 'skipped'))
  );
SQL

log "Table dba_schema.migration_history prête"

# ---------------------------------------------------------------------------
# Fonction de vérification si une migration a déjà été appliquée
# ---------------------------------------------------------------------------
is_applied() {
  local version="$1"
  local result
  result=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" -tAc \
    "SELECT COUNT(*) FROM dba_schema.migration_history
     WHERE version = '$version' AND status = 'success';")
  [[ "$result" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Exécution des migrations dans l'ordre V001, V002, ...
# ---------------------------------------------------------------------------
MIGRATION_FILES=$(find "$MIGRATIONS_DIR" -maxdepth 1 -name 'V*.sql' | sort)

if [[ -z "$MIGRATION_FILES" ]]; then
  err "Aucun fichier V*.sql trouvé dans $MIGRATIONS_DIR"
fi

APPLIED=0
SKIPPED=0
FAILED=0

for filepath in $MIGRATION_FILES; do
  filename=$(basename "$filepath")
  # Extraire la version : V001__create_schemas.sql → V001
  version=$(echo "$filename" | grep -oP '^V\d+')

  # Filtre --from
  if [[ -n "$FROM_VERSION" && "$version" < "$FROM_VERSION" ]]; then
    info "IGNORÉ (< $FROM_VERSION) : $filename"
    continue
  fi

  # Vérification idempotence
  if is_applied "$version"; then
    info "DÉJÀ APPLIQUÉ : $filename"
    ((SKIPPED++)) || true
    continue
  fi

  # Calcul checksum
  CHECKSUM=$(sha256sum "$filepath" | awk '{print $1}')

  info "APPLICATION : $filename"
  [[ "$DRY_RUN" == true ]] && { warn "  [dry-run] serait appliqué"; continue; }

  START_MS=$(date +%s%3N)

  # Exécution dans une transaction — si erreur, la migration est annulée
  if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" \
       --single-transaction \
       --set ON_ERROR_STOP=on \
       -f "$filepath" >> "$LOG_FILE" 2>&1; then

    END_MS=$(date +%s%3N)
    DURATION=$((END_MS - START_MS))

    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" -c \
      "INSERT INTO dba_schema.migration_history
         (version, filename, checksum, duration_ms, status)
       VALUES ('$version', '$filename', '$CHECKSUM', $DURATION, 'success');" \
      >> "$LOG_FILE" 2>&1

    log "  ✔ $filename appliqué en ${DURATION}ms"
    ((APPLIED++)) || true

  else
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" -c \
      "INSERT INTO dba_schema.migration_history
         (version, filename, checksum, status)
       VALUES ('$version', '$filename', '$CHECKSUM', 'failed');" \
      >> "$LOG_FILE" 2>&1 || true

    err "ÉCHEC migration $filename — voir $LOG_FILE pour le détail"
    ((FAILED++)) || true
    break   # Arrêt immédiat : les migrations suivantes dépendraient d'un état cassé
  fi
done

# ---------------------------------------------------------------------------
# Récapitulatif
# ---------------------------------------------------------------------------
echo ""
log "=== Récapitulatif migrations ==="
log "  Appliquées : $APPLIED"
info "  Ignorées   : $SKIPPED (déjà appliquées)"
[[ "$FAILED" -gt 0 ]] && err "  Échouées   : $FAILED" || log "  Échouées   : 0"

log "=== Migrations terminées. État final ==="
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$TARGET_DB" \
  -c "SELECT version, filename, applied_at, duration_ms, status
      FROM dba_schema.migration_history
      ORDER BY version;" 2>&1 | tee -a "$LOG_FILE"