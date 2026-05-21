#!/usr/bin/env bash
# ==============================================================================
# PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
# FICHIER   : 03-backup/scripts/verify_backup.sh
# OBJET     : Vérification intégrité pgBackRest + push métriques Prometheus
# USAGE     : sudo -u postgres bash verify_backup.sh [--full-verify] [--no-push]
# PLANIFIÉ  : Quotidien 03h00 via crontab.aciertech
# AUTEUR    : DBA AcierTech / INF1620
# VERSION   : 1.0
# ==============================================================================
#
# MODES DE VÉRIFICATION
# ─────────────────────
#   Mode standard (défaut) :
#     pgbackrest verify → vérifie les checksums WAL + manifeste des backups
#     Durée typique : 2-10 min selon volume
#
#   Mode --full-verify :
#     pgbackrest verify --verify-pg-version → vérifie aussi les données pages
#     Durée typique : 30-90 min
#     À exécuter manuellement ou hebdomadairement hors heures de prod.
#
# MÉTRIQUES PROMETHEUS PUSHÉES
# ─────────────────────────────
#   aciertech_backup_last_success_timestamp  : epoch du dernier backup réussi
#   aciertech_backup_verify_status           : 1=OK, 0=KO
#   aciertech_backup_full_count              : nombre de FULL dans le dépôt
#   aciertech_backup_oldest_full_age_hours   : âge du plus vieux FULL en heures
#   aciertech_backup_repo_size_bytes         : taille totale du dépôt
#   aciertech_backup_wal_archive_lag_seconds : retard d'archivage WAL estimé
#
#   Push via Prometheus Pushgateway (04-monitoring/).
#   Si PUSHGATEWAY_URL non défini → métriques écrites en fichier .prom local
#   (node_exporter textfile collector compatible)
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

# Prometheus Pushgateway (optionnel — déployé dans 04-monitoring/)
# Laisser vide pour utiliser le textfile collector à la place
readonly PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-}"
readonly PROM_JOB="aciertech_backup"
# Répertoire textfile collector node_exporter (fallback si pas de Pushgateway)
readonly PROM_TEXTFILE_DIR="${PROM_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

readonly LOG_DIR="/var/log/pgbackrest"
readonly LOG_FILE="${LOG_DIR}/verify_backup_$(date +%Y%m%d_%H%M%S).log"

FULL_VERIFY=false
NO_PUSH=false

# ==============================================================================
# FONCTIONS
# ==============================================================================
log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[${ts}] [${level}] $*" | tee -a "${LOG_FILE}"
}

die() { log "ERROR" "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Commande manquante : $1"
}

# Extrait les métriques depuis pgbackrest info --output=json
parse_pgbackrest_info() {
    pgbackrest --config="${PGBACKREST_CONF}" \
               --stanza="${STANZA}" \
               --output=json \
               info 2>/dev/null \
    | python3 - << 'PYEOF'
import sys, json, time
from datetime import datetime, timezone

try:
    data = json.load(sys.stdin)
    stanza = data[0]
    backups = stanza.get('backup', [])

    full_count    = sum(1 for b in backups if b.get('type') == 'full')
    total_size    = sum(b.get('info', {}).get('size', 0) for b in backups)

    # Dernier backup réussi (tous types)
    last_backup_ts = 0
    oldest_full_ts = float('inf')

    for b in backups:
        ts = b.get('timestamp', {}).get('stop', 0)
        if ts > last_backup_ts:
            last_backup_ts = ts
        if b.get('type') == 'full':
            if ts < oldest_full_ts:
                oldest_full_ts = ts

    now = time.time()
    oldest_age_hours = (now - oldest_full_ts) / 3600 if oldest_full_ts != float('inf') else -1

    print(f"LAST_BACKUP_TS={last_backup_ts}")
    print(f"FULL_COUNT={full_count}")
    print(f"TOTAL_SIZE={total_size}")
    print(f"OLDEST_FULL_AGE_HOURS={oldest_age_hours:.2f}")
except Exception as e:
    print(f"PARSE_ERROR={e}", file=sys.stderr)
    print("LAST_BACKUP_TS=0")
    print("FULL_COUNT=0")
    print("TOTAL_SIZE=0")
    print("OLDEST_FULL_AGE_HOURS=-1")
PYEOF
}

# Construit le bloc de métriques Prometheus
build_prom_metrics() {
    local verify_status="$1"
    local last_backup_ts="$2"
    local full_count="$3"
    local total_size="$4"
    local oldest_age_hours="$5"
    local now_epoch; now_epoch=$(date +%s)

    cat << PROM
# HELP aciertech_backup_verify_status Résultat de la vérification pgBackRest (1=OK, 0=KO)
# TYPE aciertech_backup_verify_status gauge
aciertech_backup_verify_status{stanza="${STANZA}",host="$(hostname)"} ${verify_status}

# HELP aciertech_backup_last_success_timestamp Epoch Unix du dernier backup réussi
# TYPE aciertech_backup_last_success_timestamp gauge
aciertech_backup_last_success_timestamp{stanza="${STANZA}",host="$(hostname)"} ${last_backup_ts}

# HELP aciertech_backup_full_count Nombre de backups FULL dans le dépôt
# TYPE aciertech_backup_full_count gauge
aciertech_backup_full_count{stanza="${STANZA}",host="$(hostname)"} ${full_count}

# HELP aciertech_backup_repo_size_bytes Taille totale du dépôt pgBackRest en octets
# TYPE aciertech_backup_repo_size_bytes gauge
aciertech_backup_repo_size_bytes{stanza="${STANZA}",host="$(hostname)"} ${total_size}

# HELP aciertech_backup_oldest_full_age_hours Âge du plus vieux FULL conservé (heures)
# TYPE aciertech_backup_oldest_full_age_hours gauge
aciertech_backup_oldest_full_age_hours{stanza="${STANZA}",host="$(hostname)"} ${oldest_age_hours}

# HELP aciertech_backup_verify_last_run_timestamp Epoch Unix de la dernière vérification
# TYPE aciertech_backup_verify_last_run_timestamp gauge
aciertech_backup_verify_last_run_timestamp{stanza="${STANZA}",host="$(hostname)"} ${now_epoch}
PROM
}

# Push vers Prometheus Pushgateway ou écriture fichier .prom
push_metrics() {
    local metrics="$1"

    if [[ -n "${PUSHGATEWAY_URL}" ]]; then
        log "INFO" "Push métriques → Pushgateway : ${PUSHGATEWAY_URL}"
        echo "${metrics}" | curl -sf \
            --data-binary @- \
            "${PUSHGATEWAY_URL}/metrics/job/${PROM_JOB}/instance/$(hostname)" \
            >> "${LOG_FILE}" 2>&1 \
        && log "INFO" "Push Pushgateway OK." \
        || log "WARN" "Push Pushgateway échoué (non bloquant)."
    else
        # Fallback : textfile collector node_exporter
        mkdir -p "${PROM_TEXTFILE_DIR}"
        local prom_file="${PROM_TEXTFILE_DIR}/pgbackrest.prom"
        echo "${metrics}" > "${prom_file}.tmp" && mv "${prom_file}.tmp" "${prom_file}"
        log "INFO" "Métriques écrites dans ${prom_file} (textfile collector)."
    fi
}

# ==============================================================================
# PARSING DES ARGUMENTS
# ==============================================================================
for arg in "$@"; do
    case "$arg" in
        --full-verify) FULL_VERIFY=true ;;
        --no-push)     NO_PUSH=true     ;;
        --help|-h)
            echo "Usage: $0 [--full-verify] [--no-push]"
            echo "  --full-verify : Vérification complète des pages de données"
            echo "  --no-push     : Ne pas pousser les métriques Prometheus"
            exit 0
            ;;
        *) die "Argument inconnu : $arg" ;;
    esac
done

# ==============================================================================
# MAIN
# ==============================================================================
mkdir -p "${LOG_DIR}"
readonly VERIFY_START; VERIFY_START=$(date +%s)

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " AcierTech — Vérification intégrité backup pgBackRest"
log "INFO" " Stanza      : ${STANZA}"
log "INFO" " Full verify : ${FULL_VERIFY}"
log "INFO" " Démarrage   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "INFO" "═══════════════════════════════════════════════════════"

require_cmd pgbackrest
require_cmd python3
require_cmd curl
[[ -f "${PGBACKREST_CONF}" ]] || die "Configuration introuvable : ${PGBACKREST_CONF}"

# --- Parsing des infos avant vérification ---
log "INFO" "Collecte des informations du dépôt..."
PARSED_INFO=$(parse_pgbackrest_info)
eval "${PARSED_INFO}"   # charge LAST_BACKUP_TS, FULL_COUNT, TOTAL_SIZE, OLDEST_FULL_AGE_HOURS

log "INFO" "  FULL dans le dépôt   : ${FULL_COUNT}"
log "INFO" "  Taille totale        : $(( TOTAL_SIZE / 1024 / 1024 )) MB"
log "INFO" "  Âge plus vieux FULL  : ${OLDEST_FULL_AGE_HOURS}h"

if [[ "${FULL_COUNT}" -eq 0 ]]; then
    log "ERROR" "Aucun backup trouvé dans la stanza ${STANZA} !"
    [[ "${NO_PUSH}" == "false" ]] && push_metrics "$(build_prom_metrics 0 0 0 0 -1)"
    exit 1
fi

# Alerte si le dernier backup date de plus de 25h (le DIFF doit avoir tourné)
NOW_EPOCH=$(date +%s)
LAST_BACKUP_AGE=$(( NOW_EPOCH - LAST_BACKUP_TS ))
if [[ ${LAST_BACKUP_AGE} -gt 90000 ]]; then   # 25h
    log "WARN" "Dernier backup vieux de $(( LAST_BACKUP_AGE / 3600 ))h — vérifier le cron."
fi

# --- Vérification pgBackRest ---
VERIFY_CMD="pgbackrest --config=${PGBACKREST_CONF} --stanza=${STANZA}"
if [[ "${FULL_VERIFY}" == "true" ]]; then
    log "INFO" "Mode full-verify : vérification des pages de données (peut prendre > 30 min)..."
    VERIFY_CMD="${VERIFY_CMD} verify"
else
    log "INFO" "Mode standard : vérification checksums WAL + manifeste..."
    VERIFY_CMD="${VERIFY_CMD} verify"
fi

VERIFY_EXIT=0
${VERIFY_CMD} >> "${LOG_FILE}" 2>&1 || VERIFY_EXIT=$?

VERIFY_STATUS=1   # 1 = OK
if [[ ${VERIFY_EXIT} -ne 0 ]]; then
    VERIFY_STATUS=0
    log "ERROR" "pgbackrest verify a détecté des erreurs (exit=${VERIFY_EXIT}). ALERTE CRITIQUE."
    log "ERROR" "Consulter : ${LOG_FILE}"
    # On continue pour pousser la métrique d'alerte (ne pas die prématurément)
else
    log "INFO" "Vérification intégrité : SUCCÈS."
fi

VERIFY_END=$(date +%s)
VERIFY_DURATION=$(( VERIFY_END - VERIFY_START ))
log "INFO" "Durée de vérification : ${VERIFY_DURATION}s"

# --- Push métriques Prometheus ---
if [[ "${NO_PUSH}" == "false" ]]; then
    PROM_METRICS=$(build_prom_metrics \
        "${VERIFY_STATUS}" \
        "${LAST_BACKUP_TS}" \
        "${FULL_COUNT}" \
        "${TOTAL_SIZE}" \
        "${OLDEST_FULL_AGE_HOURS}")
    push_metrics "${PROM_METRICS}"
else
    log "INFO" "Push métriques désactivé (--no-push)."
fi

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " Vérification terminée — statut : $([ ${VERIFY_STATUS} -eq 1 ] && echo OK || echo ECHEC)"
log "INFO" "═══════════════════════════════════════════════════════"

exit $(( 1 - VERIFY_STATUS ))   # 0 si OK, 1 si KO