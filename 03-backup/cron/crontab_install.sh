#!/usr/bin/env bash
# ==============================================================================
# PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
# FICHIER   : 03-backup/cron/crontab_install.sh
# OBJET     : Installation complète de l'environnement backup sur un nœud
# USAGE     : sudo bash crontab_install.sh [--node-type primary|standby|test]
#                                          [--dry-run]
# AUTEUR    : DBA AcierTech / INF1620
# VERSION   : 1.0
# ==============================================================================
#
# CE QUE FAIT CE SCRIPT
# ─────────────────────
#   1. Vérifie les prérequis (pgBackRest installé, version PG, utilisateur postgres)
#   2. Crée les répertoires nécessaires (/opt/aciertech/, /var/log/pgbackrest/, etc.)
#   3. Copie les scripts backup dans /opt/aciertech/03-backup/scripts/
#   4. Copie les configs pgBackRest dans /etc/pgbackrest/
#   5. Installe la crontab pour l'utilisateur postgres
#      (avec ou sans le job test_restore selon --node-type)
#   6. Configure logrotate pour /var/log/pgbackrest/
#   7. Vérifie la connectivité pgBackRest (pgbackrest info)
#
# TYPES DE NŒUDS
# ──────────────
#   primary|standby : nœuds Patroni de production
#                     → crontab SANS test_restore (commenté)
#   test            : restore-test-server
#                     → crontab AVEC test_restore activé
#                     → pgbackrest-check.conf installé
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BACKUP_SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
readonly PGBACKREST_CONF_DIR="${SCRIPT_DIR}/../pgbackrest"

readonly INSTALL_SCRIPTS_DIR="/opt/aciertech/03-backup/scripts"
readonly PGBACKREST_ETC_DIR="/etc/pgbackrest"
readonly LOG_DIR="/var/log/pgbackrest"
readonly PROM_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

readonly STANZA="aciertech"
readonly PGBACKREST_MIN_VERSION="2.49"

NODE_TYPE="primary"   # défaut
DRY_RUN=false

# ==============================================================================
# FONCTIONS
# ==============================================================================
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

die() { log "ERROR" "$*"; exit 1; }

run_or_dry() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY-RUN" "$*"
    else
        eval "$@"
    fi
}

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "Ce script doit être exécuté en root (sudo bash $0)"
}

check_pgbackrest_version() {
    local installed_version
    installed_version=$(pgbackrest version 2>/dev/null | grep -oP '\d+\.\d+' | head -1) \
        || die "pgBackRest non installé. Installer : apt install pgbackrest"

    log "INFO" "pgBackRest version installée : ${installed_version}"

    # Comparaison de version simple
    if ! python3 -c "
import sys
v1 = tuple(int(x) for x in '${installed_version}'.split('.'))
v2 = tuple(int(x) for x in '${PGBACKREST_MIN_VERSION}'.split('.'))
sys.exit(0 if v1 >= v2 else 1)
" 2>/dev/null; then
        die "pgBackRest ${PGBACKREST_MIN_VERSION}+ requis, installé : ${installed_version}"
    fi
    log "INFO" "Version pgBackRest OK."
}

check_postgresql() {
    if ! command -v pg_lsclusters >/dev/null 2>&1; then
        die "PostgreSQL 16 non trouvé. Installer : apt install postgresql-16"
    fi

    local pg_version
    pg_version=$(pg_lsclusters | awk 'NR>1 {print $1}' | head -1)
    log "INFO" "Version PostgreSQL détectée : ${pg_version}"
    [[ "${pg_version}" == "16" ]] || log "WARN" "Version PG ${pg_version} détectée — attendu 16."
}

# ==============================================================================
# PARSING DES ARGUMENTS
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-type)
            NODE_TYPE="$2"
            [[ "${NODE_TYPE}" =~ ^(primary|standby|test)$ ]] \
                || die "--node-type doit être primary, standby ou test"
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            cat << 'HELP'
Usage: crontab_install.sh [OPTIONS]

OPTIONS:
  --node-type primary|standby|test   Type du nœud (défaut: primary)
  --dry-run                          Simule sans modifier le système

EXEMPLES:
  sudo bash crontab_install.sh --node-type primary
  sudo bash crontab_install.sh --node-type test --dry-run
HELP
            exit 0 ;;
        *) die "Argument inconnu : $1" ;;
    esac
done

# ==============================================================================
# MAIN
# ==============================================================================
log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " AcierTech — Installation backup pgBackRest"
log "INFO" " Nœud type : ${NODE_TYPE}"
log "INFO" " Dry-run   : ${DRY_RUN}"
log "INFO" "═══════════════════════════════════════════════════════"

check_root
check_pgbackrest_version
check_postgresql

# --- ÉTAPE 1 : Création des répertoires ---
log "INFO" "ÉTAPE 1/7 : Création des répertoires..."
for dir in \
    "${INSTALL_SCRIPTS_DIR}" \
    "${PGBACKREST_ETC_DIR}" \
    "${LOG_DIR}" \
    "${PROM_TEXTFILE_DIR}"
do
    run_or_dry "mkdir -p '${dir}'"
done

run_or_dry "chown -R postgres:postgres '${LOG_DIR}'"
run_or_dry "chmod 750 '${LOG_DIR}'"
run_or_dry "chown -R postgres:postgres '${INSTALL_SCRIPTS_DIR}'"

# Répertoire lock pgBackRest
run_or_dry "mkdir -p /run/pgbackrest"
run_or_dry "chown postgres:postgres /run/pgbackrest"

log "INFO" "Répertoires créés."

# --- ÉTAPE 2 : Copie des scripts ---
log "INFO" "ÉTAPE 2/7 : Copie des scripts dans ${INSTALL_SCRIPTS_DIR}..."
for script in backup_full.sh backup_diff.sh verify_backup.sh restore_pitr.sh test_restore.sh; do
    if [[ -f "${BACKUP_SCRIPTS_DIR}/${script}" ]]; then
        run_or_dry "cp '${BACKUP_SCRIPTS_DIR}/${script}' '${INSTALL_SCRIPTS_DIR}/'"
        run_or_dry "chmod 750 '${INSTALL_SCRIPTS_DIR}/${script}'"
        run_or_dry "chown postgres:postgres '${INSTALL_SCRIPTS_DIR}/${script}'"
        log "INFO" "  ✓ ${script}"
    else
        log "WARN" "  ✗ ${script} non trouvé dans ${BACKUP_SCRIPTS_DIR}/ (à copier manuellement)"
    fi
done

# --- ÉTAPE 3 : Copie de la configuration pgBackRest ---
log "INFO" "ÉTAPE 3/7 : Copie des configs pgBackRest..."

if [[ -f "${PGBACKREST_CONF_DIR}/pgbackrest.conf" ]]; then
    run_or_dry "cp '${PGBACKREST_CONF_DIR}/pgbackrest.conf' '${PGBACKREST_ETC_DIR}/'"
    run_or_dry "chmod 640 '${PGBACKREST_ETC_DIR}/pgbackrest.conf'"
    run_or_dry "chown postgres:postgres '${PGBACKREST_ETC_DIR}/pgbackrest.conf'"
    log "INFO" "  ✓ pgbackrest.conf"
fi

if [[ "${NODE_TYPE}" == "test" ]]; then
    if [[ -f "${PGBACKREST_CONF_DIR}/pgbackrest-check.conf" ]]; then
        run_or_dry "cp '${PGBACKREST_CONF_DIR}/pgbackrest-check.conf' '${PGBACKREST_ETC_DIR}/'"
        run_or_dry "chmod 640 '${PGBACKREST_ETC_DIR}/pgbackrest-check.conf'"
        run_or_dry "chown postgres:postgres '${PGBACKREST_ETC_DIR}/pgbackrest-check.conf'"
        log "INFO" "  ✓ pgbackrest-check.conf (nœud test)"
    fi
fi

# --- ÉTAPE 4 : Clé de chiffrement ---
log "INFO" "ÉTAPE 4/7 : Vérification de la clé de chiffrement..."
if [[ ! -f "${PGBACKREST_ETC_DIR}/repo-cipher.key" ]]; then
    log "WARN" "Clé de chiffrement absente : ${PGBACKREST_ETC_DIR}/repo-cipher.key"
    log "WARN" "Générer et déployer la clé AVANT d'utiliser pgBackRest :"
    log "WARN" "  Sur backup-server :"
    log "WARN" "    openssl rand -base64 48 > ${PGBACKREST_ETC_DIR}/repo-cipher.key"
    log "WARN" "    chmod 400 ${PGBACKREST_ETC_DIR}/repo-cipher.key"
    log "WARN" "  Puis distribuer sur tous les nœuds via scp ou Ansible."
else
    run_or_dry "chmod 400 '${PGBACKREST_ETC_DIR}/repo-cipher.key'"
    run_or_dry "chown postgres:postgres '${PGBACKREST_ETC_DIR}/repo-cipher.key'"
    log "INFO" "  ✓ Clé de chiffrement présente."
fi

# --- ÉTAPE 5 : Installation de la crontab postgres ---
log "INFO" "ÉTAPE 5/7 : Installation de la crontab postgres..."

# Générer la crontab adaptée au type de nœud
CRONTAB_TMP=$(mktemp)
cp "${SCRIPT_DIR}/crontab.aciertech" "${CRONTAB_TMP}"

if [[ "${NODE_TYPE}" == "test" ]]; then
    # Activer test_restore sur le nœud test (décommenter la ligne)
    sed -i 's/^# 0 4 \* \* 6/0 4 * * 6/' "${CRONTAB_TMP}"
    # Désactiver backup_full et backup_diff (pas de backup depuis le nœud test)
    sed -i 's|^0 2 \* \* 0|# 0 2 * * 0|' "${CRONTAB_TMP}"
    sed -i 's|^0 2 \* \* 1-6|# 0 2 * * 1-6|' "${CRONTAB_TMP}"
    log "INFO" "  → Mode test : test_restore activé, backup_full/diff désactivés."
else
    log "INFO" "  → Mode ${NODE_TYPE} : crontab standard (test_restore commenté)."
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN" "Crontab qui serait installée pour postgres :"
    cat "${CRONTAB_TMP}"
else
    sudo -u postgres crontab "${CRONTAB_TMP}"
    log "INFO" "  ✓ Crontab installée pour l'utilisateur postgres."
    sudo -u postgres crontab -l | grep -c '^[^#]' | xargs -I{} log "INFO" "    {} tâches actives."
fi
rm -f "${CRONTAB_TMP}"

# --- ÉTAPE 6 : Configuration logrotate ---
log "INFO" "ÉTAPE 6/7 : Configuration logrotate..."
cat > /tmp/pgbackrest_logrotate << 'LOGROTATE'
/var/log/pgbackrest/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    su postgres postgres
    create 640 postgres postgres
    postrotate
        # Pas de signal nécessaire — pgBackRest ouvre/ferme ses logs à chaque run
        true
    endscript
}
LOGROTATE

run_or_dry "cp /tmp/pgbackrest_logrotate /etc/logrotate.d/pgbackrest"
run_or_dry "chmod 644 /etc/logrotate.d/pgbackrest"
log "INFO" "  ✓ logrotate configuré."

# --- ÉTAPE 7 : Vérification finale ---
log "INFO" "ÉTAPE 7/7 : Vérification pgBackRest..."
if [[ "${DRY_RUN}" == "false" ]]; then
    if sudo -u postgres pgbackrest \
            --config="${PGBACKREST_ETC_DIR}/pgbackrest.conf" \
            --stanza="${STANZA}" \
            info >/dev/null 2>&1; then
        log "INFO" "  ✓ pgbackrest info OK — stanza accessible."
    else
        log "WARN" "  ✗ pgbackrest info a échoué."
        log "WARN" "    Causes possibles :"
        log "WARN" "    1. Stanza pas encore initialisée → pgbackrest --stanza=${STANZA} stanza-create"
        log "WARN" "    2. NFS non monté → vérifier /etc/fstab"
        log "WARN" "    3. SSH non configuré entre nœuds"
    fi
else
    log "DRY-RUN" "sudo -u postgres pgbackrest --stanza=${STANZA} info"
fi

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " Installation terminée — Type : ${NODE_TYPE}"
log "INFO" ""
log "INFO" " PROCHAINES ÉTAPES MANUELLES :"
log "INFO" " 1. Distribuer la clé de chiffrement si pas encore fait"
log "INFO" " 2. Configurer SSH sans mot de passe (postgres↔backup-server)"
log "INFO" " 3. Monter le NFS : /etc/fstab → backup-server:/export/pgbackrest"
log "INFO" " 4. Initialiser la stanza :"
log "INFO" "    sudo -u postgres pgbackrest --stanza=${STANZA} stanza-create"
log "INFO" " 5. Vérifier : sudo -u postgres pgbackrest --stanza=${STANZA} check"
log "INFO" " 6. Lancer le premier FULL manuellement :"
log "INFO" "    sudo -u postgres bash ${INSTALL_SCRIPTS_DIR}/backup_full.sh"
log "INFO" "═══════════════════════════════════════════════════════"

exit 0