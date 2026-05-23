# =============================================================================
# ROUTER CLUSTER — AcierTech DBA Console · 05-webapp/routers/cluster.py
#
# État HA Patroni — 3 nœuds PostgreSQL 16 avec réplication streaming.
#
# Sources de données :
#   • Patroni REST API (port 8008) — topologie, santé, switchover/failover
#   • dba_schema.v_replication_status — lag, état, LSN par standby
#   • dba_schema.v_session_activity — connexions actives
#   • etcd API (port 2379) — santé des 3 membres
#   • HAProxy stats (port 7000) — statut des backends
#
# Endpoints POST (proxy vers Patroni) :
#   POST /api/cluster/switchover → contrôlé
#   POST /api/cluster/failover   → forcé
#   POST /api/cluster/reinit     → réinitialisation standby
#   POST /api/cluster/pause      → suspend auto-failover
#   POST /api/cluster/resume     → reprend auto-failover
# =============================================================================

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse

from config import settings
from db import fetchall_ro, fetchone_ro
from tpl import templates

logger = logging.getLogger("aciertech.cluster")
router = APIRouter(prefix="", tags=["cluster"])


# ── Route HTML ────────────────────────────────────────────────────────────────

@router.get("/cluster", response_class=HTMLResponse, name="cluster")
async def cluster_page(request: Request):
    """
    Page cluster.html — topologie HA, réplication, HAProxy, etcd.
    """
    members, pause_mode = await _fetch_patroni_topology(request)
    replication_rows = await _fetch_replication_status()
    etcd_members = await _fetch_etcd_health(request)
    session_summary = await _fetch_session_summary()

    # Compute replication_lag_ms from replication data
    lag_s = 0.0
    if replication_rows:
        lag_values = [
            r.get("lag_seconds") or r.get("replay_lag", "0")
            for r in replication_rows
        ]
        lag_s = max((float(v) for v in lag_values if v is not None), default=0.0)

    ctx = {
        "request":               request,
        "members":               members,
        "pause_mode":            pause_mode,
        "replication_rows":      replication_rows,
        "replication_lag_ms":    f"{lag_s * 1000:.0f}",
        "cluster_status_text":   "Patroni — 3 nœuds HA",
        "cluster_status_class":  "success",
        "active_alerts_count":   0,
        "total_sensors":         47,
        "valid_rate":            "—",
        "session_summary":       session_summary,
        "etcd_members":          etcd_members,
        "grafana_cluster_url":   settings.grafana_iframe_url(
            settings.grafana_uid_cluster
        ),
    }
    return templates.TemplateResponse("cluster.html", ctx)


# ── API : Topologie ───────────────────────────────────────────────────────────

@router.get("/api/cluster/topology", tags=["cluster"])
async def api_cluster_topology(request: Request):
    """
    Topologie complète du cluster Patroni depuis GET /cluster.
    Retourne la liste des membres avec rôle, état, host, timeline.
    """
    members, pause_mode = await _fetch_patroni_topology(request)
    leader = next((m for m in members if m.get("role") == "leader"), None)
    return {
        "members":       members,
        "leader":        leader,
        "pause_mode":    pause_mode,
        "member_count":  len(members),
        "running_count": sum(1 for m in members if m.get("state") == "running"),
    }


async def _fetch_patroni_topology(request: Request) -> tuple[list, bool | None]:
    """
    Interroge Patroni API /cluster sur les 3 nœuds.
    Retourne la liste des membres enrichis host + api_url.
    """
    for node_idx in range(1, 4):
        try:
            url = settings.patroni_url(node_idx, "/cluster")
            resp = await request.app.state.http.get(url, timeout=settings.patroni_timeout)
            if resp.status_code == 200:
                data = resp.json()
                members = data.get("members", [])
                pause_mode = data.get("pause", False)
                for m in members:
                    if "host" not in m:
                        m["host"] = m.get("addr", "").split(":")[0] if m.get("addr") else f"pg-node-{node_idx}"
                    if "api_url" not in m:
                        m["api_url"] = f":{settings.patroni_port}"
                return members, pause_mode
        except Exception as exc:
            logger.debug("Patroni nœud %d indisponible : %s", node_idx, exc)
            continue
    return [], None


# ── API : Réplication ─────────────────────────────────────────────────────────

@router.get("/api/cluster/replication", tags=["cluster"])
async def api_cluster_replication():
    """
    État de la réplication depuis v_replication_status.
    Retourne les standbys avec lag, LSN, sync_state.
    """
    rows = await _fetch_replication_status()
    return {"replicas": rows, "count": len(rows)}


async def _fetch_replication_status() -> list[dict]:
    """
    Interroge dba_schema.v_replication_status pour les métriques
    de réplication streaming des standbys.
    """
    rows = await fetchall_ro(
        """
        SELECT
            application_name    AS name,
            state,
            sync_state,
            ROUND(
                EXTRACT(EPOCH FROM lag_seconds)::numeric, 3
            )                   AS lag_s,
            lag_bytes,
            sent_lsn,
            replay_lsn,
            CASE
                WHEN lag_seconds IS NULL THEN 'unknown'
                WHEN lag_seconds < INTERVAL '5 seconds'  THEN 'ok'
                WHEN lag_seconds < INTERVAL '30 seconds' THEN 'warning'
                ELSE 'critical'
            END                 AS lag_level
        FROM dba_schema.v_replication_status
        ORDER BY application_name
        """
    )
    return rows or []


# ── API : Sessions / connexions ───────────────────────────────────────────────

@router.get("/api/cluster/sessions", tags=["cluster"])
async def api_cluster_sessions():
    """
    Résumé des sessions actives/idle depuis v_session_activity.
    """
    return await _fetch_session_summary()


async def _fetch_session_summary() -> dict:
    """
    Compte les connexions par état depuis dba_schema.v_session_activity.
    Retourne active, idle, idle_in_transaction, total.
    """
    row = await fetchone_ro(
        """
        SELECT
            COUNT(*)                                        AS total,
            COUNT(*) FILTER (WHERE state = 'active')        AS active,
            COUNT(*) FILTER (WHERE state = 'idle')          AS idle,
            COUNT(*) FILTER (WHERE state = 'idle in transaction'
                             OR wait_event IS NOT NULL)     AS waiting
        FROM dba_schema.v_session_activity
        """
    )
    return row or {"total": 0, "active": 0, "idle": 0, "waiting": 0}


# ── API : etcd Health ─────────────────────────────────────────────────────────

@router.get("/api/cluster/etcd-health", tags=["cluster"])
async def api_etcd_health(request: Request):
    """
    Vérifie la santé des 3 membres etcd (port 2379).
    Retourne l'état, le rôle et la version pour chaque nœud.
    """
    return {"members": await _fetch_etcd_health(request)}


async def _fetch_etcd_health(request: Request) -> list[dict]:
    """
    Interroge GET /health sur chaque nœud etcd (port 2379).
    Retourne la liste des membres avec leur état.
    """
    members = []
    for node_idx in range(1, 4):
        hosts = {1: settings.pg_node1_host, 2: settings.pg_node2_host, 3: settings.pg_node3_host}
        host = hosts.get(node_idx, settings.pg_node1_host)
        name = f"pg-node-{node_idx}"
        try:
            url = settings.etcd_url(node_idx)
            resp = await request.app.state.http.get(url, timeout=settings.etcd_timeout)
            ok = resp.status_code == 200
            data = resp.json() if ok else {}
            members.append({
                "node": name,
                "host": host,
                "ok": ok,
                "role": data.get("role", "UNKNOWN") if ok else "—",
                "version": data.get("etcdVersion", "—") if ok else "—",
            })
        except Exception as exc:
            logger.debug("etcd %s health check failed : %s", name, exc)
            members.append({
                "node": name,
                "host": host,
                "ok": False,
                "role": "—",
                "version": "—",
            })
    return members


# ── API : HAProxy Stats ───────────────────────────────────────────────────────

@router.get("/api/cluster/haproxy-stats", tags=["cluster"])
async def api_haproxy_stats(request: Request):
    """
    Statistiques HAProxy depuis /stats;csv sur pg-node-1 (port 7000).
    Retourne les backends postgresql-primary et postgresql-replica.
    """
    try:
        auth = (settings.haproxy_stats_user, settings.haproxy_stats_password)
        resp = await request.app.state.http.get(
            settings.haproxy_stats_url, auth=auth, timeout=5.0
        )
        if resp.status_code != 200:
            return {"ok": False, "error": f"HAProxy stats HTTP {resp.status_code}"}
        raw = resp.text
        lines = [l.strip() for l in raw.split("\n") if l.strip() and not l.startswith("#")]
        backends = {}
        for line in lines:
            parts = line.split(",")
            if len(parts) >= 18:
                pxname = parts[0].strip("# ")
                svname = parts[1]
                status = parts[17]
                if pxname not in backends:
                    backends[pxname] = []
                backends[pxname].append({"server": svname, "status": status})
        return {"ok": True, "backends": backends}
    except Exception as exc:
        logger.warning("HAProxy stats request failed : %s", exc)
        return {"ok": False, "error": str(exc)}


# ── API : Switchover contrôlé ─────────────────────────────────────────────────

@router.post("/api/cluster/switchover", tags=["cluster"])
async def api_cluster_switchover(request: Request, body: dict | None = None):
    """
    Basculement contrôlé via Patroni POST /switchover.
    Corps optionnel : {"leader": "pg-node-2", "member": "pg-node-2"}
    """
    target = (body or {}).get("leader") or (body or {}).get("member", "")
    payload = {"leader": target} if target else {}

    for node_idx in range(1, 4):
        try:
            url = settings.patroni_url(node_idx, "/switchover")
            resp = await request.app.state.http.post(
                url, json=payload, timeout=settings.patroni_timeout
            )
            if resp.status_code in (200, 202):
                data = resp.json()
                logger.warning("Switchover vers %s accepté (%s)", target, node_idx)
                return {"success": True, "message": data.get("message", "Switchover initié")}
        except Exception as exc:
            logger.warning("Patroni %d switchover failed: %s", node_idx, exc)
            continue

    raise HTTPException(status_code=502, detail="Switchover impossible — Patroni injoignable")


# ── API : Failover forcé ──────────────────────────────────────────────────────

@router.post("/api/cluster/failover", tags=["cluster"])
async def api_cluster_failover(request: Request):
    """
    Failover forcé via Patroni POST /failover.
    Utiliser uniquement si le PRIMARY est définitivement perdu.
    """
    for node_idx in range(1, 4):
        try:
            url = settings.patroni_url(node_idx, "/failover")
            resp = await request.app.state.http.post(url, timeout=settings.patroni_timeout)
            if resp.status_code in (200, 202):
                data = resp.json()
                logger.critical("FAILOVER FORCÉ accepté (%s)", node_idx)
                return {"success": True, "message": data.get("message", "Failover initié")}
        except Exception as exc:
            logger.warning("Patroni %d failover failed: %s", node_idx, exc)
            continue

    raise HTTPException(status_code=502, detail="Failover impossible — Patroni injoignable")


# ── API : Réinitialisation standby ────────────────────────────────────────────

@router.post("/api/cluster/reinit", tags=["cluster"])
async def api_cluster_reinit(request: Request, body: dict):
    """
    Réinitialise un standby via Patroni POST /reinitialize.
    Corps requis : {"member": "pg-node-2"}
    """
    member = body.get("member", "")
    if not member:
        raise HTTPException(status_code=400, detail="Paramètre 'member' requis")

    for node_idx in range(1, 4):
        try:
            url = settings.patroni_url(node_idx, f"/reinitialize")
            resp = await request.app.state.http.post(
                url, json={"member": member}, timeout=settings.patroni_timeout
            )
            if resp.status_code in (200, 202):
                logger.warning("Réinitialisation %s acceptée", member)
                return {"success": True, "message": f"Réinitialisation de {member} initiée"}
        except Exception as exc:
            logger.warning("Patroni %d reinit failed: %s", node_idx, exc)
            continue

    raise HTTPException(status_code=502, detail="Réinitialisation impossible")


# ── API : Pause / Resume auto-failover ────────────────────────────────────────

@router.post("/api/cluster/pause", tags=["cluster"])
async def api_cluster_pause(request: Request):
    """
    Suspend l'auto-failover Patroni via PATCH /config.
    Utile pendant les fenêtres de maintenance.
    """
    return await _patch_patroni_config(request, {"pause": True})


@router.post("/api/cluster/resume", tags=["cluster"])
async def api_cluster_resume(request: Request):
    """
    Reprend l'auto-failover Patroni via PATCH /config.
    """
    return await _patch_patroni_config(request, {"pause": False})


async def _patch_patroni_config(request: Request, payload: dict) -> dict:
    """
    Envoie une requête PATCH /config à Patroni pour modifier la configuration
    dynamique (pause/resume principalement).
    """
    for node_idx in range(1, 4):
        try:
            url = settings.patroni_url(node_idx, "/config")
            resp = await request.app.state.http.patch(
                url, json=payload, timeout=settings.patroni_timeout
            )
            if resp.status_code in (200, 204):
                action = "pause" if payload.get("pause") else "resume"
                logger.warning("Auto-failover %s (%s)", action, node_idx)
                return {"success": True, "message": f"Auto-failover {action} effectué"}
        except Exception as exc:
            logger.warning("Patroni %d PATCH config failed: %s", node_idx, exc)
            continue

    raise HTTPException(status_code=502, detail="Patroni config injoignable")
