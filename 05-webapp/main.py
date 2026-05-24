# =============================================================================
# MAIN — AcierTech DBA Console · 05-webapp/main.py
#
# Application FastAPI principale.
# Lance avec : uvicorn main:app --host 0.0.0.0 --port 8080 --reload
#
# Architecture :
#   / (GET)          → dashboard.html  — vue synthèse globale
#   /cluster         → cluster.html    — état HA + réplication
#   /quality         → quality.html    — data quality IoT
#   /backups         → backups.html    — PRA & pgBackRest
#   /alerts          → alerts.html     — alertes Prometheus
#   /failover        → failover.html   — actions manuelles failover
#   /api/*           → endpoints JSON  — consommés par les templates + AJAX
# =============================================================================

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

import httpx
import orjson
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse

from config import settings
from db import close_pools, db_health_check, fetchall_ro, fetchone_ro, init_pools
from routers import alerts, backups, cluster, disaster, pipeline, quality
from tpl import templates

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
)
logger = logging.getLogger("aciertech.main")


# ── Lifespan (startup / shutdown) ─────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Gestion du cycle de vie de l'application :
    - Startup : ouvre les pools DB, crée le client HTTP partagé
    - Shutdown : ferme proprement les pools et le client HTTP
    """
    logger.info("=== AcierTech DBA Console v%s — Démarrage ===", settings.app_version)

    # Client HTTP unique partagé (Patroni, Prometheus, Grafana, etcd)
    app.state.http = httpx.AsyncClient(
        timeout=httpx.Timeout(
            connect=5.0,
            read=settings.patroni_timeout,
            write=5.0,
            pool=10.0,
        ),
        follow_redirects=True,
    )

    # Pools PostgreSQL
    try:
        await init_pools()
        logger.info("Pools PostgreSQL initialisés.")
    except Exception as exc:
        logger.error("Impossible d'initialiser les pools DB : %s", exc)
        logger.warning("L'application démarrera en mode dégradé (DB indisponible).")

    yield  # ← L'application tourne ici

    logger.info("=== Arrêt de l'application ===")
    await close_pools()
    await app.state.http.aclose()
    logger.info("Ressources libérées.")


# ── Application ───────────────────────────────────────────────────────────────

app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    description=(
        "Console d'administration PostgreSQL 16 HA — AcierTech Industries S.A. · "
        "Patroni 3 nœuds · 47 capteurs IoT · INF1620"
    ),
    lifespan=lifespan,
    # Désactiver la doc Swagger en production
    docs_url="/docs" if settings.debug else None,
    redoc_url="/redoc" if settings.debug else None,
    openapi_url="/openapi.json" if settings.debug else None,
    default_response_class=JSONResponse,
)

# ── Réponses JSON avec orjson (datetime, Decimal, bytes natifs) ───────────────
class ORJSONResponse(JSONResponse):
    media_type = "application/json"

    def render(self, content) -> bytes:
        return orjson.dumps(content, option=orjson.OPT_NON_STR_KEYS)

app.default_response_class = ORJSONResponse

# ── Templates (instance partagée définie dans tpl.py) ──────────────────────────
# Les globals Grafana et helpers sont injectés dans tpl.py

# ── Gestionnaires d'erreurs personnalisés ──────────────────────────────────────

@app.exception_handler(404)
async def not_found(request: Request, exc):
    ctx = await _get_cluster_context(request)
    return templates.TemplateResponse(
        "dashboard.html", {"request": request, "erreur": "Page introuvable", **ctx},
        status_code=404,
    )

@app.exception_handler(500)
async def server_error(request: Request, exc):
    ctx = await _get_cluster_context(request)
    return templates.TemplateResponse(
        "dashboard.html", {"request": request, "erreur": "Erreur interne du serveur", **ctx},
        status_code=500,
    )

# ── Inclure les routers ───────────────────────────────────────────────────────
app.include_router(cluster.router)
app.include_router(quality.router)
app.include_router(backups.router)
app.include_router(alerts.router)
app.include_router(disaster.router)
app.include_router(pipeline.router)


# ── Helper : récupère le statut cluster via Patroni (pour le contexte global) ─

async def _get_cluster_context(request: Request) -> dict:
    """
    Récupère l'état global du cluster pour injecter dans le contexte
    de chaque template (navbar status pill, KPIs hero, etc.).
    Retourne des valeurs par défaut en cas d'erreur pour ne pas bloquer le rendu.
    """
    ctx = {
        "cluster_status_text": "Indisponible",
        "cluster_status_class": "unknown",
        "active_alerts_count": 0,
        "total_sensors": 47,
        "valid_rate": "—",
        "replication_lag_ms": "—",
        "active_alerts": 0,
        "full_backup_age": "—",
        "repl_lag": "—",
        "connections": "—",
        "silent_sensors": 0,
    }

    # 1. Statut Patroni (essaie les 3 nœuds dans l'ordre)
    for node_idx in range(1, 4):
        try:
            url = settings.patroni_url(node_idx, "/cluster")
            resp = await request.app.state.http.get(url)
            if resp.status_code == 200:
                data = resp.json()
                members = data.get("members", [])
                running = sum(1 for m in members if m.get("state") == "running")
                leader = next(
                    (m for m in members if m.get("role") == "leader"), None
                )
                ctx["cluster_status_text"] = f"Cluster OK — {running}/{len(members)} nœuds"
                ctx["cluster_status_class"] = "" if running == len(members) else "warning"
                ctx["_patroni_data"] = data
                break
        except Exception:
            continue
    else:
        ctx["cluster_status_class"] = "critical"
        ctx["cluster_status_text"] = "Patroni indisponible"

    # 2. Comptage alertes Prometheus actives
    try:
        prom_url = f"{settings.prometheus_base_url}/api/v1/alerts"
        resp = await request.app.state.http.get(prom_url)
        if resp.status_code == 200:
            alerts_data = resp.json().get("data", {}).get("alerts", [])
            firing = [a for a in alerts_data if a.get("state") == "firing"]
            ctx["active_alerts_count"] = len(firing)
            ctx["active_alerts"] = len(firing)
    except Exception:
        pass

    # 3. Taux validation data quality (v_data_quality_dashboard)
    try:
        row = await fetchone_ro(
            """
            SELECT
                ROUND(AVG(valid_rate_pct)::numeric, 1) AS avg_rate,
                SUM(valid_count)    AS total_valid,
                SUM(total_readings) AS total_readings
            FROM dba_schema.v_data_quality_dashboard
            """
        )
        if row and row.get("total_readings"):
            ctx["valid_rate"] = str(row["avg_rate"])
    except Exception:
        pass

    # 4. Lag réplication max (v_replication_status)
    try:
        row = await fetchone_ro(
            """
            SELECT
                MAX(EXTRACT(EPOCH FROM lag_seconds))::numeric(8,3) AS max_lag_s
            FROM dba_schema.v_replication_status
            WHERE lag_seconds IS NOT NULL
            """
        )
        if row and row.get("max_lag_s") is not None:
            lag_s = float(row["max_lag_s"])
            ctx["replication_lag_ms"] = f"{lag_s * 1000:.0f}"
            ctx["repl_lag"] = f"{lag_s:.3f}"
    except Exception:
        pass

    # 5. Connexions actives
    try:
        row = await fetchone_ro(
            "SELECT COUNT(*) AS cnt FROM dba_schema.v_session_activity"
        )
        if row:
            ctx["connections"] = str(row["cnt"])
    except Exception:
        pass

    # 6. Capteurs silencieux
    try:
        row = await fetchone_ro(
            "SELECT COUNT(*) AS cnt FROM dba_schema.v_silent_sensors"
        )
        if row:
            ctx["silent_sensors"] = int(row["cnt"])
    except Exception:
        pass

    # 7. Âge dernier backup FULL
    try:
        row = await fetchone_ro(
            """
            SELECT
                ROUND(
                    EXTRACT(EPOCH FROM (NOW() - MAX(completed_at))) / 3600
                )::int AS age_h
            FROM dba_schema.backup_history
            WHERE backup_type = 'full' AND status = 'success'
            """
        )
        if row and row.get("age_h") is not None:
            age = int(row["age_h"])
            ctx["full_backup_age"] = (
                f"{age}h" if age < 48 else f"{age // 24}j"
            )
    except Exception:
        pass

    return ctx


# ── Routes HTML ───────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse, name="dashboard")
async def dashboard(request: Request):
    """
    Dashboard principal — vue synthèse globale.
    Agrège : Patroni, réplication, data quality, backup, alertes.
    """
    ctx = await _get_cluster_context(request)

    # Données supplémentaires pour le dashboard
    # Sensor types pour la grille (depuis v_data_quality_dashboard)
    try:
        sensor_rows = await fetchall_ro(
            """
            SELECT
                sensor_type,
                quality_level,
                COALESCE(total_readings,  0) AS total_readings,
                COALESCE(valid_count,     0) AS valid_count,
                COALESCE(quarantined_count,0) AS quarantined_count,
                COALESCE(valid_rate_pct,  0) AS valid_rate_pct,
                COALESCE(avg_quality_score,0) AS avg_quality_score,
                COALESCE(sensors_active,  0) AS sensors_active,
                COALESCE(sensors_silent,  0) AS sensors_silent
            FROM dba_schema.v_data_quality_dashboard
            ORDER BY sensor_type
            """
        )
        ctx["sensor_rows"] = sensor_rows
    except Exception:
        ctx["sensor_rows"] = []

    # Activité récente : 6 derniers événements pg_cron + backup_history
    try:
        activity = await fetchall_ro(
            """
            SELECT
                'cron'                       AS source,
                jobname                      AS label,
                status,
                start_time                   AS event_at,
                COALESCE(return_message,'')  AS detail
            FROM cron.job_run_details
            WHERE jobname LIKE 'aciertech_%'
              AND start_time >= NOW() - INTERVAL '24 hours'
            UNION ALL
            SELECT
                'backup'         AS source,
                backup_type      AS label,
                status,
                started_at       AS event_at,
                COALESCE(backup_label,'') AS detail
            FROM dba_schema.backup_history
            WHERE started_at >= NOW() - INTERVAL '7 days'
            ORDER BY event_at DESC
            LIMIT 8
            """
        )
        ctx["recent_activity"] = activity
    except Exception:
        ctx["recent_activity"] = []

    return templates.TemplateResponse(
        "dashboard.html", {"request": request, **ctx}
    )


@app.get("/failover", response_class=HTMLResponse, name="failover")
async def failover_page(request: Request):
    """Page démo failover — actions manuelles Patroni."""
    ctx = await _get_cluster_context(request)
    return templates.TemplateResponse(
        "failover.html", {"request": request, **ctx}
    )


# ── API : Health ──────────────────────────────────────────────────────────────

@app.get("/api/health", tags=["health"])
async def api_health(request: Request):
    """
    Endpoint de santé global — consommé par la navbar (status pill, refresh 15s).
    Vérifie : DB, Patroni, Prometheus.
    """
    db_status = await db_health_check()

    # Patroni
    patroni_ok = False
    patroni_label = "Patroni indisponible"
    for i in range(1, 4):
        try:
            resp = await request.app.state.http.get(
                settings.patroni_url(i, "/health"), timeout=3.0
            )
            if resp.status_code == 200:
                data = resp.json()
                role = data.get("role", "unknown")
                patroni_ok = True
                patroni_label = f"Cluster OK — leader: {data.get('scope','aciertech')}"
                break
        except Exception:
            continue

    # Prometheus
    prom_ok = False
    try:
        resp = await request.app.state.http.get(
            f"{settings.prometheus_base_url}/-/healthy", timeout=3.0
        )
        prom_ok = resp.status_code == 200
    except Exception:
        pass

    overall_ok = db_status["status"] == "ok" and patroni_ok

    return {
        "status":   "ok" if overall_ok else "warning" if db_status["status"] == "ok" else "critical",
        "label":    patroni_label if patroni_ok else "Dégradé",
        "db":       db_status,
        "patroni":  {"ok": patroni_ok, "label": patroni_label},
        "prometheus": {"ok": prom_ok},
        "version":  settings.app_version,
    }


@app.get("/api/health/db", tags=["health"])
async def api_health_db():
    """Vérifie uniquement la connectivité PostgreSQL."""
    return await db_health_check()