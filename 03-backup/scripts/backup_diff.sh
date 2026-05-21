#!/usr/bin/env bash
# ==============================================================================
# PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
# FICHIER   : 03-backup/scripts/backup_diff.sh
# OBJET     : Déclenchement d'un backup DIFF pgBackRest + log backup_history
# USAGE     : sudo -u postgres bash backup_diff.sh [--dry-run] [--no-log]
# PLANIFIÉ  : Lun-Sam 02h00 via crontab.aciertech
# AUTEUR    : DBA AcierTech / INF1620
# VERSION   : 1.0
# ==============================================================================
#
# DIFFÉRENTIEL vs INCRÉMENTAL
# ────────────────────────────
#   DIFF (type=diff) : backup relatif au dernier FULL uniquement.
#   INCR (type=incr) : backup relatif au dernier backup (FULL ou DIFF ou INCR).
#
#   Choix AcierTech → DIFF :
#     • Restauration plus simple : FULL + 1 DIFF seulement (pas de chaîne INCR)
#     • RTO plus court en cas d'incident
#     • Espace disque légèrement plus important qu'INCR, acceptable sur 6 jours
#
# SCHÉMA DE RÉTENTION RÉSULTANT
#   Dimanche    : FULL   (backup_full.sh)
#   Lun → Sam   : DIFF   (backup_diff.sh)
#   → 4 FULL conservés = 4 semaines
#   → WAL continu = PITR à la seconde près sur toute la période
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
readonly STANZA="aciertech"
readonly PGBACKREST_CONF="/etc/pgbackrest/pgbackrest.conf"
readonly PGUSER="${PGUSER:-postgres}"
readonly PGDATABASE="${PGDATABASE:-aciertech_db}"
readonly PG_CONNECT_HOST="${PG_CONNECT_HOST:-localhost}"
readonly PG_CONNECT_PORT="${PG_CONNECT_PORT:-5432}"

readonly LOG_DIR="/var/log/pgbackrest"
readonly LOG_FILE="${LOG_DIR}/backup_diff_$(date +%Y%m%d_%H%M%S).log"

DRY_RUN=false
NO_LOG=false

# ==============================================================================
# FONCTIONS (identiques à backup_full.sh — factorisables en lib commune)
# ==============================================================================
log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[${ts}] [${level}] $*" | tee -a "${LOG_FILE}"
}

die() {
    log "ERROR" "$*"
    db_log_backup "failed" 0 "" "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Commande manquante : $1"
}

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

db_log_backup() {
    local status="$1"
    local size_bytes="$2"
    local backup_label="$3"
    local error_msg="$4"

    [[ "${NO_LOG}" == "true" ]] && return 0

    local safe_error; safe_error=$(echo "${error_msg}" | sed "s/'/''/g" | head -c 500)
    local safe_label; safe_label=$(echo "${backup_label}" | sed "s/'/''/g")

    psql_exec "
        INSERT INTO dba_schema.backup_history (
            backup_type, backup_tool, stanza,
            started_at, completed_at, status,
            size_bytes, backup_label, repo_path, error_detail
        ) VALUES (
            'diff', 'pgbackrest', '${STANZA}',
            '${BACKUP_START_TS}', NOW(), '${status}',
            NULLIF(${size_bytes}, 0),
            NULLIF('${safe_label}', ''),
            '/var/lib/pgbackrest',
            NULLIF('${safe_error}', '')
        );" 2>>"${LOG_FILE}" \
    || log "WARN" "Impossible de loguer dans backup_history (non bloquant)"
}

get_last_backup_info() {
    local field="$1"   # 'size' ou 'label'
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
        if '${field}' == 'size':
            print(last.get('info', {}).get('size', 0))
        else:
            print(last.get('label', ''))
    else:
        print(0 if '${field}' == 'size' else '')
except Exception:
    print(0 if '${field}' == 'size' else '')
" 2>/dev/null || echo ""
}

# ==============================================================================
# VÉRIFICATION PRÉREQUIS : un FULL doit exister avant de lancer un DIFF
# ==============================================================================
check_full_exists() {
    local full_count
    full_count=$(pgbackrest --config="${PGBACKREST_CONF}" \
                            --stanza="${STANZA}" \
                            --output=json \
                            info 2>/dev/null \
                 | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    backups = data[0]['backup']
    print(sum(1 for b in backups if b.get('type') == 'full'))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

    if [[ "${full_count}" -eq 0 ]]; then
        log "WARN" "Aucun backup FULL trouvé dans la stanza ${STANZA}."
        log "WARN" "Un DIFF requiert au moins un FULL. Basculement en mode FULL."
        echo "full"
    else
        log "INFO" "Backup FULL de référence trouvé (${full_count} FULL dans le dépôt)."
        echo "diff"
    fi
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
log "INFO" " AcierTech — Backup DIFF pgBackRest"
log "INFO" " Stanza     : ${STANZA}"
log "INFO" " Start      : ${BACKUP_START_TS}"
log "INFO" " Dry-run    : ${DRY_RUN}"
log "INFO" "═══════════════════════════════════════════════════════"

require_cmd pgbackrest
require_cmd psql
require_cmd python3
[[ -f "${PGBACKREST_CONF}" ]] || die "Configuration introuvable : ${PGBACKREST_CONF}"

# --- Vérification stanza ---
log "INFO" "Vérification stanza ${STANZA}..."
pgbackrest --config="${PGBACKREST_CONF}" --stanza="${STANZA}" check \
    >>"${LOG_FILE}" 2>&1 \
    || die "pgbackrest check échoué."
log "INFO" "Stanza OK."

# --- Détermination du type effectif (diff → full si pas de FULL de référence) ---
EFFECTIVE_TYPE=$(check_full_exists)
log "INFO" "Type de backup effectif : ${EFFECTIVE_TYPE}"

if [[ "${DRY_RUN}" == "true" ]]; then
    log "INFO" "[DRY-RUN] Commande qui serait exécutée :"
    log "INFO" "  pgbackrest --config=${PGBACKREST_CONF} --stanza=${STANZA} --type=${EFFECTIVE_TYPE} backup"
    exit 0
fi

# --- Log démarrage ---
db_log_backup "running" 0 "" ""

# --- Lancement du backup ---
log "INFO" "Démarrage du backup ${EFFECTIVE_TYPE^^}..."
PGBACKREST_EXIT=0
pgbackrest \
    --config="${PGBACKREST_CONF}" \
    --stanza="${STANZA}" \
    --type="${EFFECTIVE_TYPE}" \
    --log-level-console=info \
    --log-level-file=detail \
    backup >> "${LOG_FILE}" 2>&1 || PGBACKREST_EXIT=$?

BACKUP_END_EPOCH=$(date +%s)
BACKUP_DURATION=$(( BACKUP_END_EPOCH - BACKUP_START_EPOCH ))

if [[ ${PGBACKREST_EXIT} -ne 0 ]]; then
    log "ERROR" "pgbackrest backup échoué (exit=${PGBACKREST_EXIT}). Voir ${LOG_FILE}"
    db_log_backup "failed" 0 "" "pgbackrest exit code ${PGBACKREST_EXIT}"
    exit 1
fi

# --- Métadonnées ---
BACKUP_SIZE=$(get_last_backup_info size)
BACKUP_LABEL=$(get_last_backup_info label)

log "INFO" "Backup ${EFFECTIVE_TYPE^^} terminé avec succès."
log "INFO" "  Label    : ${BACKUP_LABEL}"
log "INFO" "  Taille   : ${BACKUP_SIZE} octets ($(( ${BACKUP_SIZE:-0} / 1024 / 1024 )) MB)"
log "INFO" "  Durée    : ${BACKUP_DURATION}s"

db_log_backup "success" "${BACKUP_SIZE:-0}" "${BACKUP_LABEL}" ""
log "INFO" "Résultat enregistré dans dba_schema.backup_history."

log "INFO" "État du dépôt :"
pgbackrest --config="${PGBACKREST_CONF}" --stanza="${STANZA}" info \
    >> "${LOG_FILE}" 2>&1 || true

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " Backup ${EFFECTIVE_TYPE^^} terminé — durée : ${BACKUP_DURATION}s"
log "INFO" "═══════════════════════════════════════════════════════"

exit 0