#!/usr/bin/env bash
# ==============================================================================
# PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
# FICHIER   : 03-backup/scripts/backup_full.sh
# OBJET     : Déclenchement d'un backup FULL pgBackRest + log backup_history
# USAGE     : sudo -u postgres bash backup_full.sh [--dry-run] [--no-log]
# PLANIFIÉ  : Dimanche 02h00 via crontab.aciertech
# AUTEUR    : DBA AcierTech / INF1620
# VERSION   : 1.0
# ==============================================================================
#
# CE QUE FAIT CE SCRIPT
# ─────────────────────
#   1. Vérifie que pgBackRest est installé et que la stanza est accessible
#   2. Détecte le primary Patroni courant (via Patroni API :8008)
#   3. Lance pgbackrest backup --type=full --stanza=aciertech
#      (pgBackRest lit depuis le standby grâce à backup-standby=y dans .conf)
#   4. Récupère les métadonnées du backup terminé (taille, durée, label)
#   5. Logue le résultat dans dba_schema.backup_history via psql
#   6. Retourne 0 si succès, 1 si échec (utilisable par cron + monitoring)
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION — à adapter à l'environnement
# ==============================================================================
readonly STANZA="aciertech"
readonly PGBACKREST_CONF="/etc/pgbackrest/pgbackrest.conf"
readonly PGPORT="${PGPORT:-5432}"
readonly PGUSER="${PGUSER:-postgres}"
readonly PGDATABASE="${PGDATABASE:-aciertech_db}"
# HAProxy RW → toujours le primary (port 5000 → pgBouncer contourne, on va direct)
readonly PG_CONNECT_HOST="${PG_CONNECT_HOST:-localhost}"
readonly PG_CONNECT_PORT="${PG_CONNECT_PORT:-5432}"

# Patroni API pour détecter le primary avant backup
readonly PATRONI_API_HOST="${PATRONI_API_HOST:-localhost}"
readonly PATRONI_API_PORT="${PATRONI_API_PORT:-8008}"

# Logging
readonly LOG_DIR="/var/log/pgbackrest"
readonly LOG_FILE="${LOG_DIR}/backup_full_$(date +%Y%m%d_%H%M%S).log"
readonly SCRIPT_NAME="backup_full.sh"

# Flags
DRY_RUN=false
NO_LOG=false

# ==============================================================================
# FONCTIONS UTILITAIRES
# ==============================================================================
log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[${ts}] [${level}] $*" | tee -a "${LOG_FILE}"
}

die() {
    log "ERROR" "$*"
    # Log échec dans backup_history même en cas d'erreur critique
    db_log_backup "failed" 0 "" "$*"
    exit 1
}

# Vérifie qu'une commande existe
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Commande manquante : $1"
}

# Exécute une requête SQL sur aciertech_db (connexion directe PostgreSQL)
psql_exec() {
    psql \
        --host="${PG_CONNECT_HOST}" \
        --port="${PG_CONNECT_PORT}" \
        --username="${PGUSER}" \
        --dbname="${PGDATABASE}" \
        --no-password \
        --tuples-only \
        --no-align \
        -c "$1" 2>>"${LOG_FILE}"
}

# Logue le résultat du backup dans dba_schema.backup_history
db_log_backup() {
    local status="$1"        # 'success' | 'failed' | 'running'
    local size_bytes="$2"    # 0 si inconnu
    local backup_label="$3"  # label pgBackRest (ex: 20250315-020000F)
    local error_msg="$4"     # vide si succès

    [[ "${NO_LOG}" == "true" ]] && return 0

    # Nettoyage du message d'erreur pour SQL
    local safe_error; safe_error=$(echo "${error_msg}" | sed "s/'/''/g" | head -c 500)
    local safe_label; safe_label=$(echo "${backup_label}" | sed "s/'/''/g")

    psql_exec "
        INSERT INTO dba_schema.backup_history (
            backup_type,
            backup_tool,
            stanza,
            started_at,
            completed_at,
            status,
            size_bytes,
            backup_label,
            repo_path,
            error_detail
        ) VALUES (
            'full',
            'pgbackrest',
            '${STANZA}',
            '${BACKUP_START_TS}',
            NOW(),
            '${status}',
            NULLIF(${size_bytes}, 0),
            NULLIF('${safe_label}', ''),
            '/var/lib/pgbackrest',
            NULLIF('${safe_error}', '')
        );" 2>>"${LOG_FILE}" || log "WARN" "Impossible de loguer dans backup_history (non bloquant)"
}

# Récupère la taille du dernier backup depuis pgbackrest info
get_last_backup_size() {
    pgbackrest --config="${PGBACKREST_CONF}" \
               --stanza="${STANZA}" \
               --output=json \
               info 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    backups = data[0]['backup']
    if backups:
        last = backups[-1]
        print(last.get('info', {}).get('size', 0))
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

# Récupère le label du dernier backup
get_last_backup_label() {
    pgbackrest --config="${PGBACKREST_CONF}" \
               --stanza="${STANZA}" \
               --output=json \
               info 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    backups = data[0]['backup']
    if backups:
        print(backups[-1].get('label', ''))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# ==============================================================================
# PARSING DES ARGUMENTS
# ==============================================================================
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true  ;;
        --no-log)  NO_LOG=true   ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--no-log]"
            echo "  --dry-run  : Simule le backup sans l'exécuter"
            echo "  --no-log   : Ne pas écrire dans dba_schema.backup_history"
            exit 0
            ;;
        *) die "Argument inconnu : $arg" ;;
    esac
done

# ==============================================================================
# MAIN
# ==============================================================================
mkdir -p "${LOG_DIR}"
readonly BACKUP_START_TS; BACKUP_START_TS=$(date '+%Y-%m-%d %H:%M:%S %Z')
readonly BACKUP_START_EPOCH; BACKUP_START_EPOCH=$(date +%s)

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " AcierTech — Backup FULL pgBackRest"
log "INFO" " Stanza     : ${STANZA}"
log "INFO" " Start      : ${BACKUP_START_TS}"
log "INFO" " Dry-run    : ${DRY_RUN}"
log "INFO" "═══════════════════════════════════════════════════════"

# --- Prérequis ---
require_cmd pgbackrest
require_cmd psql
require_cmd python3

[[ -f "${PGBACKREST_CONF}" ]] || die "Fichier de configuration introuvable : ${PGBACKREST_CONF}"

# --- Vérification de la stanza ---
log "INFO" "Vérification de la stanza ${STANZA}..."
pgbackrest --config="${PGBACKREST_CONF}" \
           --stanza="${STANZA}" \
           check >>"${LOG_FILE}" 2>&1 \
    || die "pgbackrest check a échoué. Vérifier la stanza et la configuration."
log "INFO" "Stanza OK."

# --- Vérification que le primary Patroni est joignable ---
log "INFO" "Vérification du cluster Patroni via ${PATRONI_API_HOST}:${PATRONI_API_PORT}..."
PATRONI_ROLE=$(curl -sf "http://${PATRONI_API_HOST}:${PATRONI_API_PORT}/patroni" \
               | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role','unknown'))" \
               2>/dev/null) || PATRONI_ROLE="unknown"
log "INFO" "Rôle Patroni du nœud courant : ${PATRONI_ROLE}"

# --- Dry-run mode ---
if [[ "${DRY_RUN}" == "true" ]]; then
    log "INFO" "[DRY-RUN] Commande qui serait exécutée :"
    log "INFO" "  pgbackrest --config=${PGBACKREST_CONF} --stanza=${STANZA} --type=full backup"
    log "INFO" "[DRY-RUN] Aucune action effectuée."
    exit 0
fi

# --- Lancement du backup FULL ---
log "INFO" "Démarrage du backup FULL..."
db_log_backup "running" 0 "" ""

PGBACKREST_EXIT=0
pgbackrest \
    --config="${PGBACKREST_CONF}" \
    --stanza="${STANZA}" \
    --type=full \
    --log-level-console=info \
    --log-level-file=detail \
    backup >> "${LOG_FILE}" 2>&1 || PGBACKREST_EXIT=$?

BACKUP_END_EPOCH=$(date +%s)
BACKUP_DURATION=$(( BACKUP_END_EPOCH - BACKUP_START_EPOCH ))

if [[ ${PGBACKREST_EXIT} -ne 0 ]]; then
    log "ERROR" "pgbackrest backup a échoué (exit=${PGBACKREST_EXIT}). Consulter ${LOG_FILE}"
    db_log_backup "failed" 0 "" "pgbackrest exit code ${PGBACKREST_EXIT}"
    exit 1
fi

# --- Récupération des métadonnées ---
BACKUP_SIZE=$(get_last_backup_size)
BACKUP_LABEL=$(get_last_backup_label)

log "INFO" "Backup FULL terminé avec succès."
log "INFO" "  Label    : ${BACKUP_LABEL}"
log "INFO" "  Taille   : ${BACKUP_SIZE} octets ($(( BACKUP_SIZE / 1024 / 1024 )) MB)"
log "INFO" "  Durée    : ${BACKUP_DURATION}s"

# --- Log en base ---
db_log_backup "success" "${BACKUP_SIZE}" "${BACKUP_LABEL}" ""
log "INFO" "Résultat enregistré dans dba_schema.backup_history."

# --- Affichage de l'état du dépôt ---
log "INFO" "État du dépôt après backup :"
pgbackrest --config="${PGBACKREST_CONF}" \
           --stanza="${STANZA}" \
           info >> "${LOG_FILE}" 2>&1 || true

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " Backup FULL terminé — durée totale : ${BACKUP_DURATION}s"
log "INFO" "═══════════════════════════════════════════════════════"

exit 0