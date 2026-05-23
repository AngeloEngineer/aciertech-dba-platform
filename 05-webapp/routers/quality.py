# =============================================================================
# ROUTER QUALITY — AcierTech DBA Console · 05-webapp/routers/quality.py
#
# Métriques de qualité de données pour les 47 capteurs IoT.
#
# Sources de données :
#   • dba_schema.v_data_quality_dashboard  → agrégats par sensor_type / 1h glissante
#   • dba_schema.v_silent_sensors          → capteurs is_active sans émission > 3×intervalle
#   • iot_quarantine.anomaly_log            → codes anomalie (OUT_OF_RANGE, ZSCORE_ANOMALY…)
#   • iot_quarantine.rejected_readings      → lectures rejetées récentes
#   • dba_schema.data_quality_snapshots     → historique snapshots pg_cron */5min
#   • iot_raw.ingestion_errors             → erreurs d'ingestion
#   • cron.job_run_details                 → statut jobs pg_cron aciertech_*
#
# Action :
#   POST /api/quality/refresh-ai-view
#     → Appelle dba_schema.fn_refresh_ai_view()
#     → REFRESH MATERIALIZED VIEW CONCURRENTLY iot_clean.v_ai_feature_set
#     → REQUIERT autocommit=True (interdit dans une transaction explicite)
#     → pg_cron fait ce refresh toutes les 5min (aciertech_refresh_ai_view)
#
# Logique de scoring fn_compute_quality_score (définie en 02-sql/functions/) :
#   NO_THRESHOLD  → score 50
#   OUT_OF_RANGE  → score 0
#   WARNING_LOW   → score 75
#   WARNING_HIGH  → score 75
#   ZSCORE_ANOMALY → score 65 (fenêtre Z-score 1h sur iot_raw WHERE valid)
#   Combiné       → score 55
#   VALID         → score 100
# =============================================================================

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse

from config import settings
from db import fetchall_ro, fetchone_admin, fetchone_ro
from tpl import templates

logger = logging.getLogger("aciertech.quality")
router = APIRouter(prefix="", tags=["quality"])


# ── Route HTML ────────────────────────────────────────────────────────────────

@router.get("/quality", response_class=HTMLResponse, name="quality")
async def quality_page(request: Request):
    """
    Page quality.html — Data Quality IoT complète.
    Charge toutes les données côté serveur pour le premier rendu.
    """
    # 1. Dashboard global (v_data_quality_dashboard)
    dashboard_rows = await _fetch_dashboard()

    # 2. Résumé global
    summary = await fetchone_ro(
        """
        SELECT
            ROUND(AVG(valid_rate_pct)::numeric, 1)     AS avg_valid_rate,
            ROUND(AVG(avg_quality_score)::numeric, 1)  AS avg_score,
            SUM(total_readings)                         AS total_readings_1h,
            SUM(quarantined_count)                      AS total_quarantined_1h,
            SUM(error_count)                            AS total_errors_1h,
            SUM(sensors_active)                         AS total_sensors_active,
            SUM(sensors_silent)                         AS total_sensors_silent
        FROM dba_schema.v_data_quality_dashboard
        """
    )

    # 3. Capteurs silencieux (v_silent_sensors)
    silent_sensors = await _fetch_silent_sensors()
    silent_summary = await fetchone_ro(
        """
        SELECT
            COUNT(*) FILTER (WHERE silence_level = 'CRITICAL')   AS critical_count,
            COUNT(*) FILTER (WHERE silence_level = 'WARNING')    AS warning_count,
            COUNT(*) FILTER (WHERE silence_level = 'NEVER_SEEN') AS never_seen_count
        FROM dba_schema.v_silent_sensors
        """
    )

    # 4. Anomalies récentes (1h)
    anomalies = await _fetch_anomalies(limit=20)

    # 5. Statut refresh v_ai_feature_set (via pg_cron)
    ai_refresh = await _fetch_ai_refresh_status()

    ctx = {
        "request":         request,
        "dashboard_rows":  dashboard_rows,
        "summary":         summary or {},
        "silent_sensors":  silent_sensors,
        "silent_summary":  silent_summary or {},
        "anomalies":       anomalies,
        "ai_refresh":      ai_refresh,
        "grafana_quality_url": settings.grafana_iframe_url(
            settings.grafana_uid_quality
        ),
    }
    return templates.TemplateResponse("quality.html", ctx)


# ── API : Dashboard qualité ───────────────────────────────────────────────────

@router.get("/api/quality/dashboard", tags=["quality"])
async def api_quality_dashboard():
    """
    Métriques agrégées par sensor_type depuis v_data_quality_dashboard.
    Fenêtre 1h glissante — mis à jour par pg_cron aciertech_quality_snapshot (*/5min).
    Colonnes clés : valid_rate_pct, avg_quality_score, quality_level,
    sensors_active, sensors_silent.
    """
    rows = await _fetch_dashboard()
    summary = await fetchone_ro(
        """
        SELECT
            ROUND(AVG(valid_rate_pct)::numeric, 1)                  AS global_valid_rate,
            ROUND(AVG(avg_quality_score)::numeric, 1)               AS global_avg_score,
            SUM(total_readings)                                      AS total_readings_1h,
            SUM(valid_count)                                         AS total_valid_1h,
            SUM(quarantined_count)                                   AS total_quarantined_1h,
            SUM(error_count)                                         AS total_errors_1h,
            COUNT(DISTINCT sensor_type)                              AS sensor_type_count,
            COUNT(*) FILTER (WHERE quality_level = 'EXCELLENT')      AS excellent_count,
            COUNT(*) FILTER (WHERE quality_level = 'GOOD')           AS good_count,
            COUNT(*) FILTER (WHERE quality_level = 'DEGRADED')       AS degraded_count,
            COUNT(*) FILTER (WHERE quality_level IN ('CRITICAL','NO_DATA')) AS critical_count
        FROM dba_schema.v_data_quality_dashboard
        """
    )
    return {"sensor_types": rows, "summary": summary or {}}


async def _fetch_dashboard() -> list[dict]:
    return await fetchall_ro(
        """
        SELECT
            sensor_type,
            quality_level,
            COALESCE(total_readings,   0) AS total_readings,
            COALESCE(valid_count,      0) AS valid_count,
            COALESCE(quarantined_count,0) AS quarantined_count,
            COALESCE(error_count,      0) AS error_count,
            COALESCE(valid_rate_pct,   0) AS valid_rate_pct,
            ROUND(COALESCE(avg_quality_score, 0)::numeric, 1) AS avg_quality_score,
            COALESCE(sensors_active,   0) AS sensors_active,
            COALESCE(sensors_silent,   0) AS sensors_silent,
            last_reading_at
        FROM dba_schema.v_data_quality_dashboard
        ORDER BY sensor_type
        """
    )


@router.get("/api/quality/silent", tags=["quality"])
async def api_silent_sensors():
    """
    Capteurs silencieux depuis dba_schema.v_silent_sensors.
    Niveaux : NEVER_SEEN (jamais émis) / CRITICAL (>6×intervalle) /
    WARNING (>3×intervalle).
    Fallback expected_interval_s = 300s si NULL dans sensor_thresholds.
    """
    sensors = await _fetch_silent_sensors()
    counts = await fetchone_ro(
        """
        SELECT
            COUNT(*) FILTER (WHERE silence_level = 'CRITICAL')   AS critical,
            COUNT(*) FILTER (WHERE silence_level = 'WARNING')    AS warning,
            COUNT(*) FILTER (WHERE silence_level = 'NEVER_SEEN') AS never_seen,
            COUNT(*)                                              AS total
        FROM dba_schema.v_silent_sensors
        """
    )
    return {"sensors": sensors, "counts": counts or {}}


async def _fetch_silent_sensors() -> list[dict]:
    return await fetchall_ro(
        """
        SELECT
            sensor_id,
            sensor_name,
            sensor_type,
            location,
            silence_level,
            last_reading_at,
            EXTRACT(EPOCH FROM silence_duration)::int AS silence_duration_s,
            expected_interval_s
        FROM dba_schema.v_silent_sensors
        ORDER BY
            CASE silence_level
                WHEN 'CRITICAL'  THEN 1
                WHEN 'WARNING'   THEN 2
                WHEN 'NEVER_SEEN' THEN 3
                ELSE 4
            END,
            silence_duration DESC
        """
    )


@router.get("/api/quality/anomalies", tags=["quality"])
async def api_anomalies(limit: int = 50, window_minutes: int = 60):
    """
    Anomalies récentes depuis iot_quarantine.anomaly_log.
    Codes générés par trg_validate_sensor via FOREACH string_to_array(reason,'|') :
    OUT_OF_RANGE, WARNING_LOW, WARNING_HIGH, ZSCORE_ANOMALY, NO_THRESHOLD.
    """
    return {"anomalies": await _fetch_anomalies(limit=limit, window_minutes=window_minutes)}


async def _fetch_anomalies(
    limit: int = 50, window_minutes: int = 60
) -> list[dict]:
    return await fetchall_ro(
        """
        SELECT
            al.sensor_id,
            sr.sensor_name,
            sr.sensor_type,
            al.anomaly_type,
            al.occurred_at AS detected_at,
            rr.raw_value    AS rejected_value,
            rr.unit         AS unit
        FROM iot_quarantine.anomaly_log al
        LEFT JOIN dba_schema.sensor_registry sr
               ON sr.sensor_id = al.sensor_id
        LEFT JOIN iot_quarantine.rejected_readings rr
               ON rr.original_id = al.original_id
        WHERE al.occurred_at >= NOW() - (%(w)s || ' minutes')::interval
        ORDER BY al.occurred_at DESC
        LIMIT %(l)s
        """,
        {"w": window_minutes, "l": limit},
    )


@router.get("/api/quality/anomaly-stats", tags=["quality"])
async def api_anomaly_stats(window_minutes: int = 60):
    """
    Statistiques agrégées des anomalies par type et par sensor_type.
    Utile pour les graphes barres dans le dashboard Grafana + webapp.
    """
    by_type = await fetchall_ro(
        """
        SELECT
            anomaly_type,
            COUNT(*)                    AS count,
            COUNT(DISTINCT sensor_id)   AS distinct_sensors
        FROM iot_quarantine.anomaly_log
        WHERE occurred_at >= NOW() - (%(w)s || ' minutes')::interval
        GROUP BY anomaly_type
        ORDER BY count DESC
        """,
        {"w": window_minutes},
    )
    by_sensor_type = await fetchall_ro(
        """
        SELECT
            sr.sensor_type,
            al.anomaly_type,
            COUNT(*)                    AS count
        FROM iot_quarantine.anomaly_log al
        LEFT JOIN dba_schema.sensor_registry sr
               ON sr.sensor_id = al.sensor_id
        WHERE al.occurred_at >= NOW() - (%(w)s || ' minutes')::interval
        GROUP BY sr.sensor_type, al.anomaly_type
        ORDER BY sr.sensor_type, count DESC
        """,
        {"w": window_minutes},
    )
    return {
        "by_anomaly_type": by_type,
        "by_sensor_type":  by_sensor_type,
        "window_minutes":  window_minutes,
    }


@router.get("/api/quality/sensors", tags=["quality"])
async def api_sensors(sensor_type: str | None = None):
    """
    Liste des capteurs depuis dba_schema.sensor_registry + sensor_thresholds.
    Retourne les seuils ISO 10816-3 (vibrations) et zscore_threshold=2.5 (fours).
    """
    where = ""
    params: tuple = ()
    if sensor_type:
        where = "WHERE sr.sensor_type = %(t)s"
        params = ({"t": sensor_type},)

    return await fetchall_ro(
        f"""
        SELECT
            sr.sensor_id,
            sr.sensor_name,
            sr.sensor_type,
            sr.location_zone AS location,
            sr.is_active,
            sr.installed_at AS installation_date,
            st.critical_min AS min_value,
            st.critical_max AS max_value,
            st.warn_min AS warning_min,
            st.warn_max AS warning_max,
            st.zscore_threshold,
            st.expected_interval_s,
            st.unit
        FROM dba_schema.sensor_registry sr
        LEFT JOIN dba_schema.sensor_thresholds st
               ON st.sensor_id = sr.sensor_id
        {where}
        ORDER BY sr.sensor_type, sr.sensor_name
        """,
        params,
    )


@router.get("/api/quality/cron-jobs", tags=["quality"])
async def api_cron_jobs():
    """
    Statut des 8 jobs pg_cron aciertech_* (définis dans pg_cron_jobs.sql).
    Jobs : quality_snapshot, refresh_ai_view, purge_quarantine,
    purge_anomaly_log, purge_quality_snapshots, purge_audit_log,
    purge_ingestion_errors, purge_cron_history.
    """
    return await fetchall_ro(
        """
        SELECT
            j.jobname,
            j.schedule,
            j.command,
            j.active,
            d.status                                          AS last_status,
            d.start_time                                      AS last_start,
            d.end_time                                        AS last_end,
            ROUND(
                EXTRACT(EPOCH FROM (d.end_time - d.start_time))::numeric, 2
            )                                                 AS last_duration_s,
            d.return_message,
            -- Comptage 24h
            (
                SELECT COUNT(*)
                FROM cron.job_run_details d2
                WHERE d2.jobid = j.jobid
                  AND d2.status = 'failed'
                  AND d2.start_time >= NOW() - INTERVAL '24 hours'
            )                                                 AS failed_24h
        FROM cron.job j
        LEFT JOIN LATERAL (
            SELECT *
            FROM cron.job_run_details d
            WHERE d.jobid = j.jobid
            ORDER BY d.start_time DESC
            LIMIT 1
        ) d ON TRUE
        WHERE j.jobname LIKE 'aciertech_%'
        ORDER BY j.jobname
        """
    )


# ── API : Refresh v_ai_feature_set ───────────────────────────────────────────

@router.post("/api/quality/refresh-ai-view", tags=["quality"])
async def api_refresh_ai_view():
    """
    Déclenche manuellement dba_schema.fn_refresh_ai_view().
    Cette fonction exécute :
      REFRESH MATERIALIZED VIEW CONCURRENTLY iot_clean.v_ai_feature_set
    Contrainte absolue : connexion en AUTOCOMMIT (impossibilité de REFRESH
    CONCURRENTLY dans une transaction explicite).
    Le pool_admin est utilisé avec autocommit=True.
    La fonction retourne la durée en secondes et émet RAISE WARNING si > 30s.
    pg_cron fait ce refresh toutes les 5min (aciertech_refresh_ai_view).
    """
    logger.info("Refresh manuel v_ai_feature_set demandé")
    result = await fetchone_admin(
        # fn_refresh_ai_view() ne prend pas d'argument
        # Elle vérifie l'index UNIQUE (idx_ai_feature_set_unique, V006)
        # avant d'exécuter le REFRESH CONCURRENTLY
        "SELECT dba_schema.fn_refresh_ai_view() AS duration_s",
        autocommit=True,  # ← Obligatoire pour REFRESH CONCURRENTLY
    )
    if result is None:
        raise HTTPException(
            status_code=500,
            detail="fn_refresh_ai_view() a retourné NULL ou une erreur.",
        )
    duration = float(result.get("duration_s") or 0)
    warning = duration > 30.0
    logger.info(
        "Refresh v_ai_feature_set terminé en %.2fs %s",
        duration, "(WARNING > 30s)" if warning else "",
    )
    return {
        "success":    True,
        "duration_s": round(duration, 2),
        "warning":    warning,
        "message":    (
            f"REFRESH CONCURRENTLY terminé en {duration:.2f}s "
            + ("⚠ > 30s" if warning else "✓")
        ),
    }


# ── AI Refresh Status ──────────────────────────────────────────────────────

async def _fetch_ai_refresh_status() -> dict:
    """
    Retourne le statut du dernier refresh de iot_clean.v_ai_feature_set
    depuis cron.job_run_details (job aciertech_refresh_ai_view).
    Retourne un dict avec last_status, last_start, last_end, last_duration_s.
    """
    row = await fetchone_ro(
        """
        SELECT
            d.status               AS last_status,
            d.start_time            AS last_start,
            d.end_time              AS last_end,
            ROUND(
                EXTRACT(EPOCH FROM (d.end_time - d.start_time))::numeric, 2
            )                       AS last_duration_s,
            d.return_message,
            j.schedule,
            j.active                AS job_active
        FROM cron.job j
        LEFT JOIN LATERAL (
            SELECT *
            FROM cron.job_run_details
            WHERE jobid = j.jobid
            ORDER BY start_time DESC
            LIMIT 1
        ) d ON TRUE
        WHERE j.jobname = 'aciertech_refresh_ai_view'
        """
    )
    return row or {
        "last_status": None,
        "last_start": None,
        "last_end": None,
        "last_duration_s": None,
        "return_message": None,
        "schedule": "*/5 * * * *",
        "job_active": True,
    }


@router.get("/api/quality/ingestion-errors", tags=["quality"])
async def api_ingestion_errors(limit: int = 30):
    """
    Erreurs d'ingestion IoT depuis iot_raw.ingestion_errors.
    Ces erreurs sont loguées par trg_validate_sensor (EXCEPTION absorbée —
    jamais de RAISE pour ne pas bloquer l'ingestion).
    """
    return await fetchall_ro(
        """
        SELECT
            sensor_id,
            sensor_type,
            raw_payload AS raw_value,
            error_type  AS error_code,
            error_message,
            occurred_at
        FROM iot_raw.ingestion_errors
        WHERE occurred_at >= NOW() - INTERVAL '24 hours'
        ORDER BY occurred_at DESC
        LIMIT %(l)s
        """,
        {"l": limit},
    )