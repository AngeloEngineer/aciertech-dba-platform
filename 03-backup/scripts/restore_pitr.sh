#!/usr/bin/env bash
# ==============================================================================
# PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
# FICHIER   : 03-backup/scripts/restore_pitr.sh
# OBJET     : Restauration PITR pgBackRest avec gestion cluster Patroni
# USAGE     : sudo -u postgres bash restore_pitr.sh --target "YYYY-MM-DD HH:MM:SS+TZ"
#                                                   [--target-name <label>]
#                                                   [--dry-run]
#                                                   [--node pg-node-1]
# AUTEUR    : DBA AcierTech / INF1620
# VERSION   : 1.0
# ==============================================================================
#
# ⚠⚠⚠  SCRIPT DE PRODUCTION — À EXÉCUTER AVEC EXTRÊME PRUDENCE  ⚠⚠⚠
#
# CE QUE FAIT CE SCRIPT
# ─────────────────────
#   1. Validation des arguments et confirmation interactive obligatoire
#   2. Arrêt du cluster Patroni sur TOUS les nœuds (patronictl pause + stop PG)
#   3. Sauvegarde du pg_data courant (renommage en pg_data.pre_restore.TIMESTAMP)
#   4. Restauration pgBackRest avec --type=time --target="..."
#   5. Démarrage de l'instance en mode standalone (sans Patroni) pour validation
#   6. Vérification post-restauration (connexion, count tables clés)
#   7. Ré-intégration dans Patroni (patronictl resume + reinitialize des standbys)
#   8. Log dans dba_schema.backup_history (type='pitr')
#
# MODES
# ─────
#   --target "2025-03-15 03:00:00+00"  : PITR à un timestamp précis
#   --target-name "20250315-020000F"   : restauration d'un backup par label
#   --dry-run                          : affiche les commandes sans exécuter
#   --node pg-node-X                   : nœud cible de la restauration
#                                        (défaut : pg-node-1, futur primary)
#
# PRÉREQUIS
# ─────────
#   - Accès SSH sans mot de passe depuis ce script vers tous les nœuds Patroni
#   - patronictl installé et configuré (PATRONI_ETCD_URL dans l'environnement)
#   - L'opérateur DBA est physiquement présent ou en astreinte (pas d'auto-restore)
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
readonly STANZA="aciertech"
readonly PGBACKREST_CONF="/etc/pgbackrest/pgbackrest.conf"
readonly PGUSER="postgres"
readonly PGDATABASE="aciertech_db"
readonly PG_DATA="/var/lib/postgresql/16/main"
readonly PG_PORT=5432

# Nœuds du cluster (pour l'arrêt/redémarrage coordonné)
readonly PATRONI_NODES=("pg-node-1" "pg-node-2" "pg-node-3")
readonly PATRONI_CLUSTER_NAME="aciertech-cluster"
readonly PATRONI_API_PORT=8008

readonly LOG_DIR="/var/log/pgbackrest"
readonly LOG_FILE="${LOG_DIR}/restore_pitr_$(date +%Y%m%d_%H%M%S).log"

# Timeout d'attente pour les opérations Patroni (secondes)
readonly PATRONI_TIMEOUT=120

# ==============================================================================
# VARIABLES INITIALISÉES PAR LES ARGUMENTS
# ==============================================================================
TARGET_TIME=""
TARGET_NAME=""
TARGET_NODE="pg-node-1"
DRY_RUN=false

# ==============================================================================
# FONCTIONS
# ==============================================================================
log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[${ts}] [${level}] $*" | tee -a "${LOG_FILE}"
}

die() {
    log "ERROR" "$*"
    log "ERROR" "RESTAURATION ABANDONNÉE. Vérifier l'état du cluster manuellement."
    log "ERROR" "Commande de diagnostic : patronictl -c /etc/patroni/patroni.yml list"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Commande manquante : $1"
}

confirm() {
    local prompt="$1"
    local response
    echo ""
    echo "⚠  ${prompt}"
    echo -n "   Tapez 'CONFIRMER' pour continuer : "
    read -r response
    [[ "${response}" == "CONFIRMER" ]] || die "Restauration annulée par l'opérateur."
}

run_or_dry() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY-RUN" "  → $*"
    else
        log "EXEC" "  → $*"
        eval "$@" >> "${LOG_FILE}" 2>&1
    fi
}

# Arrête PostgreSQL sur un nœud distant via SSH
stop_pg_on_node() {
    local node="$1"
    log "INFO" "Arrêt PostgreSQL sur ${node}..."
    run_or_dry "ssh postgres@${node} 'patronictl -c /etc/patroni/patroni.yml pause --wait 2>/dev/null; pg_ctlcluster 16 main stop -m fast || true'"
}

# Redémarre Patroni sur un nœud
start_patroni_on_node() {
    local node="$1"
    log "INFO" "Démarrage Patroni sur ${node}..."
    run_or_dry "ssh postgres@${node} 'sudo systemctl start patroni'"
}

# Vérifie la connexion post-restauration
verify_restored_instance() {
    log "INFO" "Vérification de l'instance restaurée sur ${TARGET_NODE}:${PG_PORT}..."

    local check_result
    check_result=$(psql \
        --host="${TARGET_NODE}" \
        --port="${PG_PORT}" \
        --username="${PGUSER}" \
        --dbname="${PGDATABASE}" \
        --no-password \
        --tuples-only \
        --no-align \
        -c "
        SELECT
            'iot_raw_count'   AS check_name,
            COUNT(*)::TEXT    AS result
        FROM iot_raw.sensor_readings
        UNION ALL
        SELECT
            'iot_clean_count',
            COUNT(*)::TEXT
        FROM iot_clean.sensor_readings
        UNION ALL
        SELECT
            'pg_version',
            version()
        LIMIT 1;
        " 2>>"${LOG_FILE}") || { log "WARN" "Connexion post-restore impossible."; return 1; }

    log "INFO" "Résultats de vérification :"
    echo "${check_result}" | while IFS= read -r line; do
        log "INFO" "  ${line}"
    done
    return 0
}

# Log PITR dans backup_history
db_log_pitr() {
    local status="$1"
    local error_msg="$2"
    local safe_error; safe_error=$(echo "${error_msg}" | sed "s/'/''/g" | head -c 500)
    local safe_target; safe_target=$(echo "${TARGET_TIME}" | sed "s/'/''/g")

    psql \
        --host="${TARGET_NODE}" \
        --port="${PG_PORT}" \
        --username="${PGUSER}" \
        --dbname="${PGDATABASE}" \
        --no-password \
        -c "
        INSERT INTO dba_schema.backup_history (
            backup_type, backup_tool, stanza,
            started_at, completed_at, status,
            pitr_target, backup_label, repo_path, error_detail
        ) VALUES (
            'pitr', 'pgbackrest', '${STANZA}',
            '${RESTORE_START_TS}', NOW(), '${status}',
            NULLIF('${safe_target}', '')::TIMESTAMPTZ,
            NULLIF('${TARGET_NAME}', ''),
            '/var/lib/pgbackrest',
            NULLIF('${safe_error}', '')
        );" 2>>"${LOG_FILE}" \
    || log "WARN" "Impossible de loguer dans backup_history."
}

# ==============================================================================
# PARSING DES ARGUMENTS
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_TIME="$2"; shift 2 ;;
        --target-name)
            TARGET_NAME="$2"; shift 2 ;;
        --node)
            TARGET_NODE="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --help|-h)
            cat << 'HELP'
Usage: restore_pitr.sh --target "YYYY-MM-DD HH:MM:SS+TZ" [OPTIONS]

OPTIONS:
  --target "TIMESTAMP"   Timestamp cible de restauration (ex: "2025-03-15 03:00:00+00")
  --target-name "LABEL"  Label de backup pgBackRest (alternatif à --target)
  --node "pg-node-X"     Nœud cible de restauration (défaut: pg-node-1)
  --dry-run              Affiche les commandes sans les exécuter

EXEMPLES:
  # PITR à une heure précise
  bash restore_pitr.sh --target "2025-03-15 03:00:00+00"

  # Restauration d'un backup spécifique par label
  bash restore_pitr.sh --target-name "20250315-020000F"

  # Dry-run pour vérifier les commandes
  bash restore_pitr.sh --target "2025-03-15 03:00:00+00" --dry-run
HELP
            exit 0 ;;
        *)
            die "Argument inconnu : $1" ;;
    esac
done

# Validation : au moins --target ou --target-name requis
if [[ -z "${TARGET_TIME}" && -z "${TARGET_NAME}" ]]; then
    die "Argument --target ou --target-name obligatoire."
fi

# ==============================================================================
# MAIN
# ==============================================================================
mkdir -p "${LOG_DIR}"
readonly RESTORE_START_TS; RESTORE_START_TS=$(date '+%Y-%m-%d %H:%M:%S %Z')
readonly RESTORE_START_EPOCH; RESTORE_START_EPOCH=$(date +%s)
readonly BACKUP_PRE_RESTORE="${PG_DATA}.pre_restore.$(date +%Y%m%d_%H%M%S)"

log "INFO" "╔══════════════════════════════════════════════════════╗"
log "INFO" "║    AcierTech — RESTAURATION PITR pgBackRest         ║"
log "INFO" "╚══════════════════════════════════════════════════════╝"
log "INFO" "  Stanza       : ${STANZA}"
log "INFO" "  Target time  : ${TARGET_TIME:-N/A}"
log "INFO" "  Target name  : ${TARGET_NAME:-N/A}"
log "INFO" "  Nœud cible   : ${TARGET_NODE}"
log "INFO" "  Dry-run      : ${DRY_RUN}"
log "INFO" "  Démarrage    : ${RESTORE_START_TS}"
log "INFO" "  Log          : ${LOG_FILE}"

require_cmd pgbackrest
require_cmd patronictl
require_cmd psql

# --- Confirmation obligatoire (sauf dry-run) ---
if [[ "${DRY_RUN}" == "false" ]]; then
    echo ""
    log "WARN" "╔══════════════════════════════════════════════════════╗"
    log "WARN" "║                 ⚠  ATTENTION  ⚠                     ║"
    log "WARN" "║  Cette opération va :                                ║"
    log "WARN" "║  1. ARRÊTER le cluster Patroni (indisponibilité)     ║"
    log "WARN" "║  2. REMPLACER le pg_data de ${TARGET_NODE}           ║"
    log "WARN" "║  3. SUPPRIMER les données post-${TARGET_TIME}        ║"
    log "WARN" "╚══════════════════════════════════════════════════════╝"
    confirm "Confirmez-vous la restauration PITR sur ${TARGET_NODE} vers ${TARGET_TIME:-${TARGET_NAME}} ?"
fi

# --- Arrêt coordonné du cluster Patroni ---
log "INFO" "ÉTAPE 1/7 : Arrêt du cluster Patroni..."
for node in "${PATRONI_NODES[@]}"; do
    stop_pg_on_node "${node}" || log "WARN" "Arrêt sur ${node} a retourné une erreur (peut être déjà arrêté)."
done
log "INFO" "Attente de l'arrêt complet (${PATRONI_TIMEOUT}s max)..."
[[ "${DRY_RUN}" == "false" ]] && sleep 10

# --- Sauvegarde du pg_data courant ---
log "INFO" "ÉTAPE 2/7 : Sauvegarde du répertoire de données courant..."
run_or_dry "mv '${PG_DATA}' '${BACKUP_PRE_RESTORE}'"
log "INFO" "pg_data sauvegardé dans : ${BACKUP_PRE_RESTORE}"

# --- Construction de la commande pgbackrest restore ---
log "INFO" "ÉTAPE 3/7 : Construction de la commande de restauration..."
RESTORE_CMD="pgbackrest --config=${PGBACKREST_CONF} --stanza=${STANZA}"

if [[ -n "${TARGET_TIME}" ]]; then
    RESTORE_CMD="${RESTORE_CMD} --type=time --target='${TARGET_TIME}'"
elif [[ -n "${TARGET_NAME}" ]]; then
    RESTORE_CMD="${RESTORE_CMD} --type=name --target='${TARGET_NAME}'"
fi

# target-action=promote : l'instance démarre seule après recovery (Patroni reprend ensuite)
RESTORE_CMD="${RESTORE_CMD} --target-action=promote"
RESTORE_CMD="${RESTORE_CMD} --recovery-option=recovery_target_inclusive=true"
RESTORE_CMD="${RESTORE_CMD} restore"

log "INFO" "ÉTAPE 4/7 : Restauration pgBackRest..."
log "INFO" "Commande : ${RESTORE_CMD}"
run_or_dry "${RESTORE_CMD}"

# --- Configuration PostgreSQL pour démarrage standalone ---
log "INFO" "ÉTAPE 5/7 : Configuration PostgreSQL standalone pour validation..."
if [[ "${DRY_RUN}" == "false" ]]; then
    cat >> "${PG_DATA}/postgresql.conf" << PGCONF

# --- Ajouté par restore_pitr.sh pour validation standalone ---
archive_mode = off
hot_standby = off
PGCONF

    # Démarrage standalone (sans Patroni) pour vérification
    pg_ctlcluster 16 main start -- -p ${PG_PORT}
    sleep 15   # laisser le recovery se terminer
fi

# --- Vérification post-restauration ---
log "INFO" "ÉTAPE 6/7 : Vérification de l'instance restaurée..."
VERIFY_OK=true
if [[ "${DRY_RUN}" == "false" ]]; then
    verify_restored_instance || VERIFY_OK=false
fi

if [[ "${VERIFY_OK}" == "false" ]]; then
    log "ERROR" "Vérification post-restauration échouée."
    log "ERROR" "L'instance standalone est maintenue pour investigation."
    log "ERROR" "Ancien pg_data disponible dans : ${BACKUP_PRE_RESTORE}"
    db_log_pitr "failed" "Vérification post-restauration échouée"
    exit 1
fi

log "INFO" "Vérification OK — données cohérentes."

# --- Ré-intégration Patroni ---
log "INFO" "ÉTAPE 7/7 : Ré-intégration dans le cluster Patroni..."
if [[ "${DRY_RUN}" == "false" ]]; then
    # Arrêt du mode standalone avant de remettre Patroni
    pg_ctlcluster 16 main stop -m fast || true
    sleep 5

    # Démarrage Patroni sur le nœud primaire (devient le nouveau primary)
    start_patroni_on_node "${TARGET_NODE}"
    sleep 20

    # Réinitialisation des standbys (ils doivent cloner depuis le nouveau primary)
    for node in "${PATRONI_NODES[@]}"; do
        if [[ "${node}" != "${TARGET_NODE}" ]]; then
            log "INFO" "Réinitialisation du standby ${node}..."
            run_or_dry "patronictl -c /etc/patroni/patroni.yml reinit ${PATRONI_CLUSTER_NAME} ${node} --force" || \
                log "WARN" "Reinit ${node} a échoué — à relancer manuellement."
            start_patroni_on_node "${node}"
        fi
    done

    # Reprise du cluster (pause → resume)
    sleep 15
    run_or_dry "patronictl -c /etc/patroni/patroni.yml resume ${PATRONI_CLUSTER_NAME}"
fi

# --- Log final ---
RESTORE_END=$(date +%s)
RESTORE_DURATION=$(( RESTORE_END - RESTORE_START_EPOCH ))
db_log_pitr "success" ""

log "INFO" "╔══════════════════════════════════════════════════════╗"
log "INFO" "║  RESTAURATION PITR TERMINÉE AVEC SUCCÈS             ║"
log "INFO" "╚══════════════════════════════════════════════════════╝"
log "INFO" "  Durée totale   : ${RESTORE_DURATION}s"
log "INFO" "  Target atteint : ${TARGET_TIME:-${TARGET_NAME}}"
log "INFO" "  Backup pré-restore : ${BACKUP_PRE_RESTORE}"
log "INFO" ""
log "INFO" "  ACTIONS POST-RESTORE MANUELLES :"
log "INFO" "  1. Vérifier : patronictl -c /etc/patroni/patroni.yml list"
log "INFO" "  2. Vérifier la réplication : psql -c 'SELECT * FROM dba_schema.v_replication_status'"
log "INFO" "  3. Informer les équipes IoT et IA du retour en production"
log "INFO" "  4. Supprimer ${BACKUP_PRE_RESTORE} après validation (J+7 recommandé)"

exit 0