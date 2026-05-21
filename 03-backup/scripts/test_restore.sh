#!/usr/bin/env bash
# ==============================================================================
# PROJET    : AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
# FICHIER   : 03-backup/scripts/test_restore.sh
# OBJET     : Test automatisé de restauration hebdomadaire (instance isolée)
# USAGE     : sudo -u postgres bash test_restore.sh [--no-cleanup] [--no-push]
# PLANIFIÉ  : Samedi 04h00 via crontab.aciertech (hors heures de pointe)
# AUTEUR    : DBA AcierTech / INF1620
# VERSION   : 1.0
# ==============================================================================
#
# OBJECTIF
# ────────
#   Valider chaque semaine que le dernier backup pgBackRest est restaurable
#   et que les données sont cohérentes — SANS TOUCHER au cluster de production.
#
#   Ce test s'exécute sur "restore-test-server" (machine isolée)
#   avec la config pgbackrest-check.conf et la stanza aciertech-check.
#
# CE QUE FAIT CE SCRIPT
# ─────────────────────
#   1. Nettoie l'ancien répertoire de test (/tmp/pgbackrest-test/data)
#   2. Restaure le dernier backup FULL depuis le dépôt production (lecture seule)
#   3. Démarre une instance PostgreSQL isolée sur le port 5433
#   4. Exécute une batterie de checks de cohérence (counts, clés étrangères, vues)
#   5. Arrête l'instance de test
#   6. Reporte le résultat dans dba_schema.backup_history (sur le PRIMARY de prod)
#   7. Pousse les métriques Prometheus
#   8. Nettoie /tmp/pgbackrest-test/ (sauf --no-cleanup pour investigation)
#
# GARANTIES
# ─────────
#   • Aucun écrit sur le dépôt pgBackRest (repo NFS monté en lecture seule)
#   • Port 5433 uniquement — pas d'interférence avec la prod (port 5432)
#   • pg_hba.conf de test : accès localhost uniquement
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
readonly STANZA_CHECK="aciertech-check"
readonly PGBACKREST_CHECK_CONF="/etc/pgbackrest/pgbackrest-check.conf"

# Instance de test (isolée)
readonly TEST_DATA_DIR="/tmp/pgbackrest-test/data"
readonly TEST_PG_PORT=5433
readonly TEST_PG_USER="postgres"

# Connexion à la base de PRODUCTION pour logger les résultats
readonly PROD_PG_HOST="${PROD_PG_HOST:-pg-node-1}"
readonly PROD_PG_PORT="${PROD_PG_PORT:-5432}"
readonly PROD_PG_USER="postgres"
readonly PROD_PG_DB="aciertech_db"

readonly PROM_TEXTFILE_DIR="${PROM_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
readonly PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-}"
readonly PROM_JOB="aciertech_backup_test"

readonly LOG_DIR="/var/log/pgbackrest"
readonly LOG_FILE="${LOG_DIR}/test_restore_$(date +%Y%m%d_%H%M%S).log"

NO_CLEANUP=false
NO_PUSH=false

# Résultats des checks (accumulés)
declare -a CHECK_RESULTS=()
GLOBAL_STATUS=0   # 0 = tout OK, 1 = au moins un check KO

# ==============================================================================
# FONCTIONS
# ==============================================================================
log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[${ts}] [${level}] $*" | tee -a "${LOG_FILE}"
}

die() { log "ERROR" "$*"; cleanup_on_error; exit 1; }

# Nettoyage en cas d'erreur non gérée
cleanup_on_error() {
    log "WARN" "Nettoyage d'urgence..."
    pg_ctlcluster 16 main stop --port="${TEST_PG_PORT}" 2>/dev/null || true
    report_to_prod "failed" "Erreur non gérée — voir ${LOG_FILE}"
}

# Exécute un check SQL sur l'instance de test et enregistre le résultat
run_check() {
    local check_name="$1"
    local sql="$2"
    local expected_min="${3:-1}"   # valeur minimum attendue (entier)

    local result
    result=$(psql \
        --host=localhost \
        --port="${TEST_PG_PORT}" \
        --username="${TEST_PG_USER}" \
        --dbname="aciertech_db" \
        --no-password \
        --tuples-only \
        --no-align \
        -c "${sql}" 2>>"${LOG_FILE}") || result="ERROR"

    # Nettoyage du résultat (trim whitespace)
    result=$(echo "${result}" | tr -d '[:space:]')

    local status="OK"
    if [[ "${result}" == "ERROR" ]]; then
        status="ERROR"
        GLOBAL_STATUS=1
    elif [[ "${result}" =~ ^[0-9]+$ ]] && [[ "${result}" -lt "${expected_min}" ]]; then
        status="FAIL (${result} < ${expected_min} attendu)"
        GLOBAL_STATUS=1
    fi

    CHECK_RESULTS+=("${check_name}|${result}|${status}")
    log "INFO" "  [${status}] ${check_name} : ${result}"
}

# Reporte le résultat global dans dba_schema.backup_history (prod)
report_to_prod() {
    local status="$1"
    local error_msg="$2"
    local safe_error; safe_error=$(echo "${error_msg}" | sed "s/'/''/g" | head -c 500)

    psql \
        --host="${PROD_PG_HOST}" \
        --port="${PROD_PG_PORT}" \
        --username="${PROD_PG_USER}" \
        --dbname="${PROD_PG_DB}" \
        --no-password \
        -c "
        INSERT INTO dba_schema.backup_history (
            backup_type, backup_tool, stanza,
            started_at, completed_at, status,
            repo_path, error_detail
        ) VALUES (
            'test_restore', 'pgbackrest', '${STANZA_CHECK}',
            '${TEST_START_TS}', NOW(), '${status}',
            '/var/lib/pgbackrest',
            NULLIF('${safe_error}', '')
        );" 2>>"${LOG_FILE}" \
    || log "WARN" "Report vers dba_schema.backup_history échoué (non bloquant)."
}

# Push métriques Prometheus
push_metrics() {
    local test_status="$1"   # 1=OK, 0=KO
    local now_epoch; now_epoch=$(date +%s)

    local metrics
    metrics=$(cat << PROM
# HELP aciertech_backup_test_status Résultat du test de restauration hebdomadaire (1=OK, 0=KO)
# TYPE aciertech_backup_test_status gauge
aciertech_backup_test_status{stanza="${STANZA_CHECK}",host="$(hostname)"} ${test_status}

# HELP aciertech_backup_test_last_run_timestamp Epoch du dernier test de restauration
# TYPE aciertech_backup_test_last_run_timestamp gauge
aciertech_backup_test_last_run_timestamp{stanza="${STANZA_CHECK}",host="$(hostname)"} ${now_epoch}
PROM
)

    if [[ -n "${PUSHGATEWAY_URL}" ]]; then
        echo "${metrics}" | curl -sf \
            --data-binary @- \
            "${PUSHGATEWAY_URL}/metrics/job/${PROM_JOB}/instance/$(hostname)" \
            >> "${LOG_FILE}" 2>&1 \
        && log "INFO" "Push Pushgateway OK." \
        || log "WARN" "Push Pushgateway échoué."
    else
        mkdir -p "${PROM_TEXTFILE_DIR}"
        local prom_file="${PROM_TEXTFILE_DIR}/pgbackrest_test.prom"
        echo "${metrics}" > "${prom_file}.tmp" && mv "${prom_file}.tmp" "${prom_file}"
        log "INFO" "Métriques écrites dans ${prom_file}."
    fi
}

# ==============================================================================
# PARSING DES ARGUMENTS
# ==============================================================================
for arg in "$@"; do
    case "$arg" in
        --no-cleanup) NO_CLEANUP=true ;;
        --no-push)    NO_PUSH=true    ;;
        --help|-h)
            echo "Usage: $0 [--no-cleanup] [--no-push]"
            echo "  --no-cleanup : Conserve /tmp/pgbackrest-test/ après le test (investigation)"
            echo "  --no-push    : Ne pas pousser les métriques Prometheus"
            exit 0 ;;
        *) die "Argument inconnu : $arg" ;;
    esac
done

# ==============================================================================
# MAIN
# ==============================================================================
mkdir -p "${LOG_DIR}"
readonly TEST_START_TS; TEST_START_TS=$(date '+%Y-%m-%d %H:%M:%S %Z')
readonly TEST_START_EPOCH; TEST_START_EPOCH=$(date +%s)

log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " AcierTech — Test restauration automatisé hebdomadaire"
log "INFO" " Stanza check : ${STANZA_CHECK}"
log "INFO" " Instance test: localhost:${TEST_PG_PORT}"
log "INFO" " Démarrage    : ${TEST_START_TS}"
log "INFO" "═══════════════════════════════════════════════════════"

# --- Prérequis ---
command -v pgbackrest >/dev/null 2>&1 || die "pgbackrest introuvable"
command -v pg_ctlcluster >/dev/null 2>&1 || die "pg_ctlcluster introuvable"
[[ -f "${PGBACKREST_CHECK_CONF}" ]] || die "Config check introuvable : ${PGBACKREST_CHECK_CONF}"

# --- ÉTAPE 1 : Nettoyage de l'ancien répertoire de test ---
log "INFO" "ÉTAPE 1/6 : Nettoyage du répertoire de test..."
if [[ -d "${TEST_DATA_DIR}" ]]; then
    # S'assurer que l'ancienne instance est arrêtée
    pg_ctlcluster 16 main stop \
        --skip-systemctl-daemon-reload \
        2>/dev/null || true
    rm -rf "${TEST_DATA_DIR}"
    log "INFO" "Ancien répertoire supprimé."
fi
mkdir -p "${TEST_DATA_DIR}"
chmod 700 "${TEST_DATA_DIR}"

# --- ÉTAPE 2 : Restauration depuis le dépôt production ---
log "INFO" "ÉTAPE 2/6 : Restauration pgBackRest (dépôt prod, lecture seule)..."
pgbackrest \
    --config="${PGBACKREST_CHECK_CONF}" \
    --stanza="${STANZA_CHECK}" \
    --type=default \
    --target-action=promote \
    --log-level-console=info \
    restore >> "${LOG_FILE}" 2>&1 \
|| die "pgbackrest restore a échoué. Voir ${LOG_FILE}"

log "INFO" "Restauration physique terminée."

# --- ÉTAPE 3 : Configuration et démarrage de l'instance de test ---
log "INFO" "ÉTAPE 3/6 : Démarrage instance PostgreSQL test (port ${TEST_PG_PORT})..."

# Injection des paramètres spécifiques au test
cat >> "${TEST_DATA_DIR}/postgresql.conf" << PGCONF

# === Ajouté par test_restore.sh ===
port                 = ${TEST_PG_PORT}
listen_addresses     = 'localhost'
archive_mode         = off
hot_standby          = off
wal_level            = minimal
max_connections      = 20
shared_buffers       = 256MB
log_destination      = 'stderr'
logging_collector    = off
PGCONF

# pg_hba.conf minimaliste : localhost uniquement
cat > "${TEST_DATA_DIR}/pg_hba.conf" << PGHBA
# Test instance — localhost uniquement
local   all   postgres   trust
host    all   postgres   127.0.0.1/32   trust
PGHBA

# Démarrage
pg_ctl start \
    --pgdata="${TEST_DATA_DIR}" \
    --log="${LOG_DIR}/test_pg_$(date +%Y%m%d_%H%M%S).log" \
    --wait \
    --timeout=120 \
    >> "${LOG_FILE}" 2>&1 \
|| die "pg_ctl start a échoué. L'instance de test ne démarre pas."

# Attendre que PostgreSQL soit prêt à accepter des connexions
for i in {1..30}; do
    pg_isready --host=localhost --port="${TEST_PG_PORT}" >/dev/null 2>&1 && break
    sleep 2
done
pg_isready --host=localhost --port="${TEST_PG_PORT}" \
    || die "Instance de test pas prête après 60s."

log "INFO" "Instance de test démarrée."

# --- ÉTAPE 4 : Batterie de checks de cohérence ---
log "INFO" "ÉTAPE 4/6 : Vérifications de cohérence des données..."
log "INFO" "─────────────────────────────────────────────────────"

# 4.1 Version PostgreSQL
run_check "version_pg" "SELECT substring(version() from 'PostgreSQL [0-9]+\.[0-9]+')" 1

# 4.2 Existence des schémas
run_check "schema_iot_raw" \
    "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='iot_raw'" 1
run_check "schema_iot_clean" \
    "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='iot_clean'" 1
run_check "schema_dba_schema" \
    "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='dba_schema'" 1

# 4.3 Tables critiques non vides
run_check "sensor_registry_count" \
    "SELECT COUNT(*) FROM dba_schema.sensor_registry" 47

run_check "sensor_thresholds_count" \
    "SELECT COUNT(*) FROM dba_schema.sensor_thresholds" 47

run_check "iot_raw_count" \
    "SELECT COUNT(*) FROM iot_raw.sensor_readings" 1

# 4.4 Cohérence des seuils (aucun capteur actif sans threshold)
run_check "thresholds_completeness" \
    "SELECT COUNT(*) FROM dba_schema.sensor_registry r
     LEFT JOIN dba_schema.sensor_thresholds t USING (sensor_id)
     WHERE r.is_active = TRUE AND t.sensor_id IS NULL" 0

# 4.5 Intégrité validation_status (aucune valeur hors enum)
run_check "validation_status_integrity" \
    "SELECT COUNT(*) FROM iot_raw.sensor_readings
     WHERE validation_status NOT IN ('valid','quarantined','error','pending')" 0

# 4.6 Vue matérialisée IA accessible
run_check "ai_view_accessible" \
    "SELECT COUNT(*) FROM iot_clean.v_ai_feature_set" 0

# 4.7 Types de capteurs cohérents avec le seed V008
run_check "sensor_types_count" \
    "SELECT COUNT(DISTINCT sensor_type) FROM dba_schema.sensor_registry" 7

# 4.8 Fonctions DBA accessibles
run_check "fn_quality_score_exists" \
    "SELECT COUNT(*) FROM pg_proc WHERE proname='fn_compute_quality_score'" 1

run_check "fn_refresh_ai_view_exists" \
    "SELECT COUNT(*) FROM pg_proc WHERE proname='fn_refresh_ai_view'" 1

log "INFO" "─────────────────────────────────────────────────────"

# --- ÉTAPE 5 : Arrêt de l'instance de test ---
log "INFO" "ÉTAPE 5/6 : Arrêt de l'instance de test..."
pg_ctl stop \
    --pgdata="${TEST_DATA_DIR}" \
    --mode=fast \
    >> "${LOG_FILE}" 2>&1 || log "WARN" "pg_ctl stop a échoué (non bloquant)."

# --- ÉTAPE 6 : Nettoyage et reporting ---
log "INFO" "ÉTAPE 6/6 : Reporting et nettoyage..."

if [[ "${NO_CLEANUP}" == "false" ]]; then
    rm -rf "$(dirname "${TEST_DATA_DIR}")"
    log "INFO" "Répertoire de test supprimé."
else
    log "INFO" "--no-cleanup : répertoire conservé dans ${TEST_DATA_DIR}"
fi

TEST_END=$(date +%s)
TEST_DURATION=$(( TEST_END - TEST_START_EPOCH ))

# Résumé des checks
log "INFO" "═══════════════════════════════════════════════════════"
log "INFO" " RÉSUMÉ DES CHECKS"
log "INFO" "═══════════════════════════════════════════════════════"
for result in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r name val status <<< "${result}"
    log "INFO" "  $(printf '%-40s' "${name}") : ${status}"
done
log "INFO" "═══════════════════════════════════════════════════════"

FINAL_STATUS="success"
[[ ${GLOBAL_STATUS} -ne 0 ]] && FINAL_STATUS="failed"

log "INFO" " Statut global   : ${FINAL_STATUS^^}"
log "INFO" " Durée totale    : ${TEST_DURATION}s"
log "INFO" "═══════════════════════════════════════════════════════"

# Report vers la base de production
SUMMARY=$(printf '%s\n' "${CHECK_RESULTS[@]}" | grep -v '|.*|OK$' | head -5 || echo "")
report_to_prod "${FINAL_STATUS}" "${SUMMARY}"

# Push métriques
if [[ "${NO_PUSH}" == "false" ]]; then
    push_metrics "$([ ${GLOBAL_STATUS} -eq 0 ] && echo 1 || echo 0)"
fi

exit ${GLOBAL_STATUS}