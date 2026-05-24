"""
ROUTER PIPELINE — AcierTech DBA Console · 05-webapp/routers/pipeline.py

Pipeline Data-to-Model : état du feature set IA, historique des rafraîchissements,
statistiques de couverture et exposition pour le système IA.

Sources :
  • iot_clean.v_ai_feature_set  → features agrégées par minute/capteur
  • cron.job_run_details         → historique refresh (job aciertech_refresh_ai_view)
  • iot_clean.sensor_readings   → stats brutes du pipeline
  • iot_quarantine.rejected_readings → volume rejeté (goulot d'étranglement)

Actions :
  POST /api/pipeline/refresh   → déclenche manuellement fn_refresh_ai_view()
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse

from config import settings
from db import fetchall_ro, fetchone_admin, fetchone_ro
from tpl import templates

logger = logging.getLogger("aciertech.pipeline")
router = APIRouter(prefix="", tags=["pipeline"])


# ── Route HTML ─────────────────────────────────────────────────────────────────

@router.get("/pipeline", response_class=HTMLResponse, name="pipeline")
async def pipeline_page(request: Request):
    """Page pipeline.html — Dashboard Data-to-Model."""
    feature_summary = await _fetch_feature_summary()
    refresh_history = await _fetch_refresh_history(limit=20)
    pipeline_kpis = await _fetch_pipeline_kpis()
    coverage = await _fetch_coverage()

    ctx = {
        "request": request,
        "feature_summary": feature_summary or {},
        "refresh_history": refresh_history or [],
        "kpis": pipeline_kpis or {},
        "coverage": coverage or [],
        "grafana_pipeline_url": settings.grafana_iframe_url(
            "aciertech-pg-performance",
            "&var-metric=aciertech_ai_view_refresh"
        ),
    }
    return templates.TemplateResponse("pipeline.html", ctx)


# ── API : Feature set summary ──────────────────────────────────────────────────

@router.get("/api/pipeline/features", tags=["pipeline"])
async def api_pipeline_features():
    """Feature set agrégé depuis iot_clean.v_ai_feature_set."""
    summary = await _fetch_feature_summary()
    recent = await fetchall_ro("""
        SELECT
            sensor_type,
            time_bucket,
            avg_value::numeric(10,2)  AS avg_value,
            min_value::numeric(10,2)  AS min_value,
            max_value::numeric(10,2)  AS max_value,
            sample_count,
            avg_quality_score
        FROM iot_clean.v_ai_feature_set
        WHERE time_bucket >= NOW() - INTERVAL '30 minutes'
        ORDER BY time_bucket DESC, sensor_type
        LIMIT 300
    """)
    return {
        "summary": summary or {},
        "recent": recent,
        "sensor_count": 47,
    }


@router.get("/api/pipeline/health", tags=["pipeline"])
async def api_pipeline_health():
    """Métriques de santé du pipeline Data-to-Model."""
    pool_ro_ok = True
    try:
        result = await fetchone_ro("SELECT 1 AS ok")
        if not result:
            pool_ro_ok = False
    except Exception:
        pool_ro_ok = False

    refresh = await fetchone_ro("""
        SELECT
            d.status               AS last_status,
            d.start_time            AS last_start,
            d.end_time              AS last_end,
            ROUND(
                EXTRACT(EPOCH FROM (d.end_time - d.start_time))::numeric, 2
            )                       AS last_duration_s,
            (
                SELECT COUNT(*)
                FROM cron.job_run_details
                WHERE jobid = d.jobid
                  AND status = 'failed'
                  AND start_time >= NOW() - INTERVAL '24 hours'
            )                       AS failures_24h
        FROM cron.job j
        LEFT JOIN LATERAL (
            SELECT *
            FROM cron.job_run_details
            WHERE jobid = j.jobid
            ORDER BY start_time DESC
            LIMIT 1
        ) d ON TRUE
        WHERE j.jobname = 'aciertech_refresh_ai_view'
    """)

    view_status = await fetchone_ro("""
        SELECT
            (SELECT COUNT(*) FROM iot_clean.v_ai_feature_set)  AS estimated_rows,
            pg_size_pretty(pg_total_relation_size(c.oid))    AS total_size,
            pg_size_pretty(pg_relation_size(c.oid))          AS table_size
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'iot_clean'
          AND c.relname = 'v_ai_feature_set'
    """)

    return {
        "database": {"ok": pool_ro_ok},
        "materialized_view": {
            "name": "iot_clean.v_ai_feature_set",
            "rows": view_status.get("estimated_rows") if view_status else None,
            "total_size": view_status.get("total_size") if view_status else None,
            "table_size": view_status.get("table_size") if view_status else None,
        },
        "refresh": refresh or {"last_status": None, "failures_24h": 0},
        "sensors_total": 47,
    }


@router.get("/api/pipeline/refresh-history", tags=["pipeline"])
async def api_pipeline_refresh_history(limit: int = 20):
    """Historique des rafraîchissements de v_ai_feature_set."""
    return {"history": await _fetch_refresh_history(limit=limit)}


@router.post("/api/pipeline/refresh", tags=["pipeline"])
async def api_pipeline_refresh():
    """Déclenche manuellement un REFRESH CONCURRENTLY de v_ai_feature_set."""
    logger.info("Refresh manuel du pipeline Data-to-Model demandé")
    result = await fetchone_admin(
        "SELECT dba_schema.fn_refresh_ai_view() AS duration_s",
        autocommit=True,
    )
    if result is None:
        raise HTTPException(
            status_code=500,
            detail="fn_refresh_ai_view() a retourné NULL",
        )
    duration = float(result.get("duration_s") or 0)
    logger.info("Refresh pipeline terminé en %.2fs", duration)
    return {
        "success": True,
        "duration_s": round(duration, 2),
        "message": f"Rafraîchissement terminé en {duration:.2f}s",
    }


# ── Helpers ────────────────────────────────────────────────────────────────────

async def _fetch_feature_summary() -> dict | None:
    return await fetchone_ro("""
        SELECT
            COUNT(*)                                             AS total_buckets,
            COUNT(DISTINCT sensor_id)                            AS distinct_sensors,
            COUNT(DISTINCT sensor_type)                          AS distinct_types,
            MIN(time_bucket)                                     AS oldest_bucket,
            MAX(time_bucket)                                     AS newest_bucket,
            ROUND(AVG(avg_value)::numeric, 2)                    AS global_avg_value,
            ROUND(AVG(avg_quality_score)::numeric, 1)            AS global_avg_quality
        FROM iot_clean.v_ai_feature_set
    """)


async def _fetch_refresh_history(limit: int = 20) -> list[dict]:
    return await fetchall_ro("""
        SELECT
            'aciertech_refresh_ai_view' AS job_name,
            status,
            start_time  AS started_at,
            end_time    AS completed_at,
            ROUND(
                EXTRACT(EPOCH FROM (end_time - start_time))::numeric, 2
            )           AS duration_s,
            return_message
        FROM cron.job_run_details
        WHERE jobname = 'aciertech_refresh_ai_view'
        ORDER BY start_time DESC
        LIMIT %(l)s
    """, {"l": limit})


async def _fetch_pipeline_kpis() -> dict | None:
    return await fetchone_ro("""
        SELECT
            (SELECT COUNT(*) FROM iot_clean.sensor_readings
             WHERE validated_at >= NOW() - INTERVAL '1 hour')
                                                         AS readings_1h,
            (SELECT COUNT(*) FROM iot_clean.sensor_readings
             WHERE validated_at >= NOW() - INTERVAL '24 hours')
                                                         AS readings_24h,
            COALESCE(
                (SELECT ROUND(
                    100.0 * (
                        SELECT COUNT(*) FROM iot_clean.sensor_readings
                        WHERE validated_at >= NOW() - INTERVAL '1 hour'
                    ) / NULLIF(
                        (SELECT COUNT(*) FROM iot_raw.sensor_readings
                         WHERE received_at >= NOW() - INTERVAL '1 hour'),
                    0), 1)
                ), 0
            )                                               AS pipeline_yield_pct,
            COALESCE(
                (SELECT COUNT(*) FROM iot_quarantine.rejected_readings
                 WHERE rejected_at >= NOW() - INTERVAL '1 hour')
            )                                               AS rejected_1h
    """)


async def _fetch_coverage() -> list[dict]:
    return await fetchall_ro("""
        SELECT
            sr.sensor_type,
            COUNT(DISTINCT sr.sensor_id)                     AS total_sensors,
            COUNT(DISTINCT av.sensor_id)                      AS active_in_features,
            ROUND(
                100.0 * COUNT(DISTINCT av.sensor_id)
                / NULLIF(COUNT(DISTINCT sr.sensor_id), 0), 1
            )                                                 AS coverage_pct
        FROM dba_schema.sensor_registry sr
        LEFT JOIN iot_clean.v_ai_feature_set av
               ON av.sensor_id = sr.sensor_id
              AND av.time_bucket >= NOW() - INTERVAL '30 minutes'
        WHERE sr.is_active = TRUE
        GROUP BY sr.sensor_type
        ORDER BY sr.sensor_type
    """)
