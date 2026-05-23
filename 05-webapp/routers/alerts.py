# =============================================================================
# ROUTER ALERTS — AcierTech DBA Console · 05-webapp/routers/alerts.py
#
# Alertes Prometheus actives et historique — AcierTech INF1620.
#
# Sources de données :
#   • Prometheus API :9090
#       GET /api/v1/alerts         → alertes en cours (state: firing|pending)
#       GET /api/v1/rules          → toutes les règles (groups + rules)
#       GET /api/v1/query          → instant query (métriques temps réel)
#   • Groupes de règles (définis dans 04-monitoring/prometheus/rules/) :
#       postgresql_alerts.yml   → PatroniNodeDown, ReplicationLag*, Connections*,
#                                  BlockedSessions*, LongRunningQuery, HighLockWaitCount,
#                                  DeadlocksDetected, CacheHitRateLow, PgBouncerPoolWaiting
#       backup_alerts.yml       → BackupVerifyFailed, BackupRestoreTestFailed,
#                                  BackupFullTooOld, BackupDiffTooOld,
#                                  BackupRepoSizeHigh, BackupFullCountLow,
#                                  BackupVerifyStale, WalArchiveFailing, WalArchiveDelayed
#       data_quality_alerts.yml → ValidationRateCritical, ValidationRateWarning,
#                                  QualityLevelCritical, AvgQualityScoreLow,
#                                  SensorNeverSeen, SensorSilenceCritical,
#                                  SensorSilenceWarning, ManySilentSensors,
#                                  QuarantineRateHigh, AnomalyLogSurge,
#                                  AIFeatureViewRefreshSlow, AIFeatureViewStale
#       node_alerts.yml         → HighCPUUsage, CriticalCPUUsage, HighLoadAverage,
#                                  HighMemoryUsage, CriticalMemoryUsage, SwapUsed,
#                                  PGDataDiskSpaceWarning/Critical, WALDiskSpaceWarning,
#                                  BackupNFSUnavailable, HighIOWait, DiskReadErrors,
#                                  NodeExporterDown, NetworkErrors,
#                                  PostgresExporterDown, PushgatewayDown
#   • Métriques backup via Pushgateway (aciertech_backup_*) — définies dans
#     03-backup/scripts/verify_backup.sh + test_restore.sh
# =============================================================================

from __future__ import annotations

import logging
from typing import Literal

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse

from config import settings
from tpl import templates

logger = logging.getLogger("aciertech.alerts")
router = APIRouter(prefix="", tags=["alerts"])


# ── Constantes ────────────────────────────────────────────────────────────────

# Mapping groupe de règles → catégorie métier
_RULE_GROUP_CATEGORY: dict[str, str] = {
    "patroni_cluster":         "Cluster HA",
    "replication_lag":         "Réplication",
    "pg_connections":          "Connexions",
    "pg_locks":                "Locks / Deadlocks",
    "pg_performance":          "Performances",
    "pgbackrest_backup_health":"Backup",
    "pgbackrest_wal":          "Archivage WAL",
    "data_quality_validation": "Data Quality",
    "silent_sensors":          "Capteurs silencieux",
    "quarantine_volume":       "Quarantaine IoT",
    "ai_feature_view":         "Vue IA",
    "node_cpu":                "CPU",
    "node_memory":             "Mémoire",
    "node_disk":               "Disques",
    "node_network":            "Réseau",
    "service_availability":    "Services",
}

# Ordre de sévérité pour le tri des alertes
_SEVERITY_ORDER: dict[str, int] = {
    "critical": 1,
    "warning":  2,
    "info":     3,
    "none":     4,
}


# ── Route HTML ────────────────────────────────────────────────────────────────

@router.get("/alerts", response_class=HTMLResponse, name="alerts")
async def alerts_page(request: Request):
    """
    Page alerts.html — Tableau de bord des alertes Prometheus.
    Charge : alertes firing, alertes pending, règles par groupe, métriques backup.
    """
    firing, pending, prom_ok = await _fetch_alerts(request)
    rules_by_group           = await _fetch_rules_by_group(request)
    backup_metrics           = await _fetch_backup_metrics(request)
    pg_metrics               = await _fetch_pg_key_metrics(request)

    # Comptages par sévérité
    severity_counts = _count_by_severity(firing)

    ctx = {
        "request":                    request,
        "prom_ok":                    prom_ok,
        "firing":                     firing,
        "pending":                    pending,
        "firing_count":               len(firing),
        "pending_count":              len(pending),
        "severity_counts":            severity_counts,
        "rules_by_group":             rules_by_group,
        "backup_metrics":             backup_metrics,
        "pg_metrics":                 pg_metrics,
        "rule_categories":            _RULE_GROUP_CATEGORY,
        "replication_lag_critical_s": settings.replication_lag_critical_s,
        "replication_lag_warning_s":  settings.replication_lag_warning_s,
    }
    return templates.TemplateResponse("alerts.html", ctx)


# ── API : Alertes actives ─────────────────────────────────────────────────────

@router.get("/api/alerts/active", tags=["alerts"])
async def api_alerts_active(
    request: Request,
    state: Literal["firing", "pending", "all"] = "all",
    severity: str | None = None,
):
    """
    Alertes actives depuis Prometheus /api/v1/alerts.
    Filtre optionnel par state (firing|pending) et severity (critical|warning|info).
    Retourne les alertes triées par sévérité puis par nom.
    """
    firing, pending, prom_ok = await _fetch_alerts(request)

    if state == "firing":
        result = firing
    elif state == "pending":
        result = pending
    else:
        result = firing + pending

    if severity:
        result = [
            a for a in result
            if a.get("labels", {}).get("severity", "").lower() == severity.lower()
        ]

    return {
        "ok":           prom_ok,
        "alerts":       result,
        "firing_count": len(firing),
        "pending_count": len(pending),
        "total":        len(result),
        "severity_counts": _count_by_severity(firing),
    }


async def _fetch_alerts(
    request: Request,
) -> tuple[list[dict], list[dict], bool]:
    """
    Appelle Prometheus /api/v1/alerts.
    Retourne (firing_alerts, pending_alerts, prometheus_reachable).
    """
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/api/v1/alerts",
            timeout=settings.prometheus_timeout,
        )
        resp.raise_for_status()
        all_alerts: list[dict] = resp.json().get("data", {}).get("alerts", [])
    except Exception as exc:
        logger.error("Prometheus /api/v1/alerts indisponible : %s", exc)
        return [], [], False

    firing  = sorted(
        [a for a in all_alerts if a.get("state") == "firing"],
        key=lambda a: (
            _SEVERITY_ORDER.get(a.get("labels", {}).get("severity", "none"), 99),
            a.get("labels", {}).get("alertname", ""),
        ),
    )
    pending = sorted(
        [a for a in all_alerts if a.get("state") == "pending"],
        key=lambda a: a.get("labels", {}).get("alertname", ""),
    )
    return firing, pending, True


# ── API : Règles ──────────────────────────────────────────────────────────────

@router.get("/api/alerts/rules", tags=["alerts"])
async def api_alerts_rules(request: Request):
    """
    Toutes les règles d'alerte chargées par Prometheus depuis :
      04-monitoring/prometheus/rules/*.yml
    Groupées par fichier/groupe avec état de santé de chaque règle.
    """
    groups = await _fetch_rules_by_group(request)
    total_rules  = sum(len(g.get("rules", [])) for g in groups)
    firing_rules = sum(
        1 for g in groups
        for r in g.get("rules", [])
        if r.get("state") == "firing"
    )
    return {
        "groups":       groups,
        "total_rules":  total_rules,
        "firing_rules": firing_rules,
        "group_count":  len(groups),
    }


async def _fetch_rules_by_group(request: Request) -> list[dict]:
    """
    Appelle Prometheus /api/v1/rules et enrichit chaque groupe
    avec la catégorie métier (depuis _RULE_GROUP_CATEGORY).
    """
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/api/v1/rules",
            timeout=settings.prometheus_timeout,
        )
        resp.raise_for_status()
        groups: list[dict] = resp.json().get("data", {}).get("groups", [])
    except Exception as exc:
        logger.error("Prometheus /api/v1/rules indisponible : %s", exc)
        return []

    # Enrichir chaque groupe avec sa catégorie métier
    for group in groups:
        group_name = group.get("name", "")
        group["category"] = _RULE_GROUP_CATEGORY.get(group_name, "Autre")
        # Compter les règles en firing dans ce groupe
        group["firing_count"] = sum(
            1 for r in group.get("rules", [])
            if r.get("state") == "firing"
        )

    return groups


# ── API : Métriques backup (Pushgateway / textfile collector) ─────────────────

@router.get("/api/alerts/backup-metrics", tags=["alerts"])
async def api_backup_metrics(request: Request):
    """
    Métriques pgBackRest depuis Prometheus (produites par 03-backup/scripts/).
    Ces métriques sont poussées par :
      verify_backup.sh → aciertech_backup_verify_*
      test_restore.sh  → aciertech_backup_test_*
    Via PUSHGATEWAY_URL=http://monitoring-server:9091
    ou textfile collector /var/lib/node_exporter/textfile_collector/pgbackrest.prom.
    NE PAS recréer ces métriques ici — elles sont définies dans 03-backup/.
    """
    return await _fetch_backup_metrics(request)


async def _fetch_backup_metrics(request: Request) -> dict:
    """
    Interroge Prometheus pour les métriques aciertech_backup_*.
    Retourne un dict structuré avec les valeurs actuelles.
    """
    metrics_to_fetch = {
        "verify_status":           "aciertech_backup_verify_status",
        "last_success_timestamp":  "aciertech_backup_last_success_timestamp",
        "full_count":              "aciertech_backup_full_count",
        "repo_size_bytes":         "aciertech_backup_repo_size_bytes",
        "oldest_full_age_hours":   "aciertech_backup_oldest_full_age_hours",
        "verify_last_run":         "aciertech_backup_verify_last_run_timestamp",
        "test_status":             "aciertech_backup_test_status",
        "test_last_run":           "aciertech_backup_test_last_run_timestamp",
    }

    result: dict = {}
    for key, metric in metrics_to_fetch.items():
        value = await _prometheus_instant_query(request, metric)
        result[key] = value

    # Dériver des champs lisibles
    if result.get("verify_status") is not None:
        result["verify_ok"] = result["verify_status"] == 1.0
    if result.get("test_status") is not None:
        result["test_ok"] = result["test_status"] == 1.0
    if result.get("repo_size_bytes") is not None:
        gb = result["repo_size_bytes"] / 1_073_741_824
        result["repo_size_gb"] = round(gb, 1)

    return result


# ── API : Métriques PostgreSQL clés ──────────────────────────────────────────

@router.get("/api/alerts/pg-metrics", tags=["alerts"])
async def api_pg_metrics(request: Request):
    """
    Métriques PostgreSQL temps réel depuis Prometheus.
    Utilisées pour le panneau de contexte de la page Alertes.
    """
    return await _fetch_pg_key_metrics(request)


async def _fetch_pg_key_metrics(request: Request) -> dict:
    """
    Interroge Prometheus pour les métriques PostgreSQL critiques.
    Toutes issues des exporters configurés dans 04-monitoring/.
    """
    queries = {
        # Réplication (aciertech_replication_lag_seconds — défini dans queries.yaml)
        "replication_lag_max_s":
            'max(aciertech_replication_lag_seconds)',

        # Connexions (pg_stat_database)
        "connections_active":
            f'pg_stat_database_numbackends{{datname="{settings.pg_database}"}}',

        # Cache hit (pg_stat_database)
        "cache_hit_ratio":
            (
                f'pg_stat_database_blks_hit{{datname="{settings.pg_database}"}}'
                f' / ('
                f'pg_stat_database_blks_hit{{datname="{settings.pg_database}"}}'
                f' + pg_stat_database_blks_read{{datname="{settings.pg_database}"}}'
                f' + 1)'
            ),

        # Sessions bloquées (aciertech_sessions_blocked_count — queries.yaml)
        "sessions_blocked":
            'max(aciertech_sessions_blocked_count)',

        # Deadlocks (pg_stat_database)
        "deadlocks_5m":
            f'increase(pg_stat_database_deadlocks{{datname="{settings.pg_database}"}}[5m])',

        # Taux validation IoT (aciertech_valid_rate_pct — queries.yaml)
        "quality_valid_rate_min":
            'min(aciertech_valid_rate_pct)',

        # Capteurs silencieux critiques (aciertech_critical_silent_sensors_count)
        "silent_sensors_critical":
            'max(aciertech_critical_silent_sensors_count)',

        # WAL archivage (pg_stat_archiver)
        "wal_failed_rate_5m":
            'rate(pg_stat_archiver_failed_count[5m])',

        # pgBouncer en attente (pool_mode=transaction — pgbouncer_exporter)
        "pgbouncer_waiting":
            f'pgbouncer_pools_cl_waiting{{database="{settings.pg_database}"}}',

        # Taux utilisation CPU nœuds PG
        "cpu_usage_max":
            '100 - (avg by(node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)',
    }

    results: dict = {}
    for key, query in queries.items():
        results[key] = await _prometheus_instant_query(request, query)

    # Dériver des statuts lisibles
    lag = results.get("replication_lag_max_s")
    if lag is not None:
        results["replication_lag_level"] = (
            "critical" if lag >= settings.replication_lag_critical_s
            else "warning" if lag >= settings.replication_lag_warning_s
            else "ok"
        )

    rate = results.get("quality_valid_rate_min")
    if rate is not None:
        results["quality_level"] = (
            "critical" if rate < settings.quality_rate_critical_pct
            else "warning" if rate < settings.quality_rate_warning_pct
            else "ok"
        )

    return results


# ── API : Query Prometheus instant ───────────────────────────────────────────

@router.get("/api/alerts/query", tags=["alerts"])
async def api_prometheus_query(request: Request, q: str):
    """
    Proxy vers Prometheus /api/v1/query.
    Paramètre ?q= : PromQL instant query.
    Utilisé par les graphes temps réel du dashboard d'alertes.
    """
    if not q.strip():
        raise HTTPException(status_code=400, detail="Paramètre 'q' requis.")
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/api/v1/query",
            params={"query": q},
            timeout=settings.prometheus_timeout,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Prometheus indisponible : {exc}",
        )


@router.get("/api/alerts/query-range", tags=["alerts"])
async def api_prometheus_query_range(
    request: Request,
    q: str,
    start: str,
    end: str,
    step: str = "60",
):
    """
    Proxy vers Prometheus /api/v1/query_range.
    Paramètres : q (PromQL), start (ISO/epoch), end (ISO/epoch), step (secondes).
    Utilisé par les graphes temporels (lag réplication, taux qualité, etc.).
    """
    if not q.strip():
        raise HTTPException(status_code=400, detail="Paramètre 'q' requis.")
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/api/v1/query_range",
            params={"query": q, "start": start, "end": end, "step": step},
            timeout=settings.prometheus_timeout,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Prometheus indisponible : {exc}",
        )


# ── API : Santé Prometheus ────────────────────────────────────────────────────

@router.get("/api/alerts/prometheus-health", tags=["alerts"])
async def api_prometheus_health(request: Request):
    """
    Vérifie la disponibilité de Prometheus et retourne ses métadonnées.
    """
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/-/healthy",
            timeout=5.0,
        )
        healthy = resp.status_code == 200
    except Exception:
        healthy = False

    build_info: dict = {}
    if healthy:
        try:
            resp = await request.app.state.http.get(
                f"{settings.prometheus_base_url}/api/v1/status/buildinfo",
                timeout=5.0,
            )
            build_info = resp.json().get("data", {})
        except Exception:
            pass

    return {
        "ok":         healthy,
        "url":        settings.prometheus_base_url,
        "build_info": build_info,
        "retention":  "15d",    # Configuré dans prometheus.yml (04-monitoring)
        "scrape_interval": "15s",
    }


# ── Helpers internes ──────────────────────────────────────────────────────────

async def _prometheus_instant_query(
    request: Request, query: str
) -> float | None:
    """
    Exécute une instant query Prometheus et retourne la valeur scalaire.
    Retourne None si Prometheus est indisponible ou si la métrique est absente.
    """
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/api/v1/query",
            params={"query": query},
            timeout=settings.prometheus_timeout,
        )
        if resp.status_code != 200:
            return None
        data = resp.json().get("data", {})
        result = data.get("result", [])
        if not result:
            return None
        # Prendre la première valeur (index 1 du tuple [timestamp, value])
        raw_value = result[0].get("value", [None, None])[1]
        if raw_value is None:
            return None
        return float(raw_value)
    except Exception as exc:
        logger.debug("Prometheus query '%s' échouée : %s", query[:60], exc)
        return None


def _count_by_severity(alerts: list[dict]) -> dict[str, int]:
    """
    Compte les alertes firing par sévérité.
    Sévérités définies dans les règles 04-monitoring/prometheus/rules/ :
    critical | warning | info.
    """
    counts: dict[str, int] = {"critical": 0, "warning": 0, "info": 0, "total": 0}
    for alert in alerts:
        sev = alert.get("labels", {}).get("severity", "info").lower()
        if sev in counts:
            counts[sev] += 1
        counts["total"] += 1
    return counts