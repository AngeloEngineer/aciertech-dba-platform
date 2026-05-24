"""
API d'exposition du pipeline Data-to-Model — AcierTech DBA

Point d'entrée dédié pour le système IA de maintenance prédictive.
Expose les features agrégées depuis iot_clean.v_ai_feature_set.

Usage :
    uvicorn api:app --host 0.0.0.0 --port 8100

Le système IA se connecte à ce service pour récupérer les features,
et non directement à PostgreSQL (séparation des responsabilités).
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

import asyncpg
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper()),
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
)
logger = logging.getLogger("aciertech.pipeline.exposition")

PG_DSN = os.getenv("PG_DSN", "postgresql://aciertech_ro:@pg-node-1:5001/aciertech_db")

app = FastAPI(
    title="AcierTech — Pipeline Data-to-Model (Exposition API)",
    version="1.0.0",
    description=(
        "API d'exposition des features agrégées pour le système IA "
        "de maintenance prédictive. Alimentée par iot_clean.v_ai_feature_set."
    ),
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with asyncpg.create_pool(PG_DSN, min_size=1, max_size=5) as pool:
        app.state.pool = pool
        yield


app.router.lifespan_context = lifespan


@app.get("/api/v1/health")
async def health():
    pool = getattr(app.state, "pool", None)
    if pool is None:
        return JSONResponse({"status": "error", "message": "Pool non initialisé"}, 503)
    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT version(), pg_is_in_recovery() AS is_replica"
            )
            return {
                "status": "ok",
                "version": row["version"][:40] if row else None,
                "is_replica": row["is_replica"] if row else None,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
    except Exception as exc:
        return JSONResponse({"status": "error", "message": str(exc)}, 503)


@app.get("/api/v1/info")
async def info():
    """Métadonnées du pipeline : vue, politique de rafraîchissement, dépendances."""
    return {
        "pipeline_name": "aciertech_data_to_model",
        "materialized_view": "iot_clean.v_ai_feature_set",
        "refresh_policy": "CONCURRENTLY toutes les 5 minutes (pg_cron ou worker)",
        "window_duration_hours": 24,
        "aggregation": "par minute et par capteur",
        "sensor_types": [
            "temperature", "pressure", "vibration", "current",
            "flow", "speed", "thickness", "weight",
        ],
        "version": "1.0.0",
    }


@app.get("/api/v1/features")
async def get_features(
    sensor_id: int | None = Query(None, ge=1, le=200),
    sensor_type: str | None = Query(None, pattern=r"^(temperature|pressure|vibration|current|flow|speed|thickness|weight)$"),
    since_minutes: int = Query(60, ge=5, le=1440),
    limit: int = Query(500, ge=1, le=5000),
):
    """
    Retourne le feature set agrégé pour le système IA.

    Paramètres :
    - sensor_id : filtre sur un capteur spécifique (optionnel)
    - sensor_type : filtre sur un type de capteur (optionnel)
    - since_minutes : fenêtre temporelle en minutes (défaut: 60, max: 1440)
    - limit : nombre max de lignes (défaut: 500, max: 5000)

    Retourne pour chaque bucket minute : avg, min, max, stddev,
    sample_count, avg_quality_score.
    """
    pool = getattr(app.state, "pool", None)
    if pool is None:
        raise HTTPException(503, "Base de données indisponible")

    where = ["recorded_at >= NOW() - make_interval(mins => $1)"]
    params = [since_minutes]
    idx = 2

    if sensor_id is not None:
        where.append(f"sensor_id = ${idx}")
        params.append(sensor_id)
        idx += 1
    if sensor_type is not None:
        where.append(f"sensor_type = ${idx}")
        params.append(sensor_type)
        idx += 1

    query = f"""
        SELECT
            sensor_id,
            sensor_type,
            time_bucket,
            avg_value,
            min_value,
            max_value,
            stddev_value,
            sample_count,
            avg_quality_score,
            window_start,
            window_end
        FROM iot_clean.v_ai_feature_set
        WHERE {' AND '.join(where)}
        ORDER BY time_bucket DESC, sensor_id
        LIMIT ${idx}
    """
    params.append(limit)

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *params)

    return {
        "features": [dict(r) for r in rows],
        "count": len(rows),
        "window_minutes": since_minutes,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/v1/features/{sensor_id:int}")
async def get_sensor_features(
    sensor_id: int,
    since_minutes: int = Query(120, ge=5, le=1440),
):
    """Raccourci pour récupérer les features d'un capteur spécifique."""
    return await get_features(
        sensor_id=sensor_id,
        since_minutes=since_minutes,
    )


@app.get("/api/v1/summary")
async def get_summary():
    """Résumé global du feature set pour le monitoring du pipeline."""
    pool = getattr(app.state, "pool", None)
    if pool is None:
        raise HTTPException(503, "Base de données indisponible")

    async with pool.acquire() as conn:
        summary = await conn.fetchrow("""
            SELECT
                COUNT(*)                                        AS total_buckets,
                COUNT(DISTINCT sensor_id)                       AS distinct_sensors,
                COUNT(DISTINCT sensor_type)                     AS distinct_types,
                MIN(time_bucket)                                AS oldest_bucket,
                MAX(time_bucket)                                AS newest_bucket,
                ROUND(AVG(sample_count)::numeric, 1)            AS avg_samples_per_bucket,
                ROUND(AVG(avg_quality_score)::numeric, 1)       AS global_avg_quality
            FROM iot_clean.v_ai_feature_set
        """)
        return dict(summary) if summary else {}
