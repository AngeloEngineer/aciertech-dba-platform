from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

from config import settings
from tpl import templates

logger = logging.getLogger("aciertech.disaster")
router = APIRouter(prefix="", tags=["disaster"])


@router.get("/disaster", response_class=HTMLResponse, name="disaster")
async def disaster_page(request: Request):
    """Simulation de sinistre — page démo interactive."""
    from main import _get_cluster_context
    ctx = await _get_cluster_context(request)
    ctx["request"] = request
    return templates.TemplateResponse("disaster.html", ctx)


@router.get("/api/disaster/status")
async def api_disaster_status(request: Request):
    """État courant du simulateur de sinistre."""
    try:
        resp = await request.app.state.http.get(
            f"http://mock-server:8008/api/disaster/status", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/crash-primary")
async def api_disaster_crash_primary(request: Request):
    """Simule un crash du nœud primaire."""
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/crash-primary", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/crash-replica")
async def api_disaster_crash_replica(request: Request):
    """Simule un crash d'un réplica."""
    try:
        body = await request.json()
    except Exception:
        body = {"node": "pg-node-3"}
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/crash-replica",
            json=body, timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/data-corruption")
async def api_disaster_data_corruption(request: Request):
    """Simule une corruption de données."""
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/data-corruption", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/failover")
async def api_disaster_failover(request: Request):
    """Force un failover vers un réplica sain."""
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/failover", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/switchover")
async def api_disaster_switchover(request: Request):
    """Basculement planifié."""
    try:
        body = await request.json()
    except Exception:
        body = {"node": "pg-node-2"}
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/switchover",
            json=body, timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/reinit")
async def api_disaster_reinit(request: Request):
    """Réinitialise un nœud."""
    try:
        body = await request.json()
    except Exception:
        body = {"node": "pg-node-3"}
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/reinit",
            json=body, timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/pause")
async def api_disaster_pause(request: Request):
    """Suspend l'auto-failover."""
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/pause", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/resume")
async def api_disaster_resume(request: Request):
    """Reprend l'auto-failover."""
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/resume", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/pitr-restore")
async def api_disaster_pitr_restore(request: Request):
    """Simule une restauration PITR."""
    try:
        body = await request.json()
    except Exception:
        body = {"target_timestamp": "2026-05-23T00:00:00Z"}
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/pitr-restore",
            json=body, timeout=10.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/api/disaster/reset")
async def api_disaster_reset(request: Request):
    """Réinitialise le cluster à l'état sain."""
    try:
        resp = await request.app.state.http.post(
            f"http://mock-server:8008/api/disaster/reset", timeout=5.0
        )
        return resp.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))
