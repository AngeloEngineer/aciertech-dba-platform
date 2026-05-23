# =============================================================================
# ROUTER BACKUPS — AcierTech DBA Console · 05-webapp/routers/backups.py
#
# Plan de Reprise d'Activité — pgBackRest + PostgreSQL 16.
#
# Sources de données :
#   • dba_schema.backup_history       — historique complet (full/diff/pitr/test_restore)
#     Colonnes étendues (ALTER TABLE appliqué avant le 1er backup) :
#     id, backup_type, backup_tool, stanza, started_at, completed_at, status,
#     size_bytes, backup_label, pitr_target, repo_path, error_detail
#   • pg_stat_archiver                — statut archivage WAL (pg_stat_archiver)
#   • CLI pgbackrest info --output=json — état dépôt NFS, stanza, fenêtre PITR
#   • Scripts 03-backup/ via subprocess :
#       backup_full.sh  → backup FULL  (--dry-run supporté)
#       backup_diff.sh  → backup DIFF  (--dry-run supporté)
#       verify_backup.sh → vérification intégrité
#       test_restore.sh → 10 checks cohérence (sensor_registry=47, etc.)
#
# Contrainte sécurité :
#   Les scripts 03-backup/ sont exécutés en subprocess avec timeout.
#   Ils logent dans dba_schema.backup_history et poussent les métriques
#   vers Pushgateway (PUSHGATEWAY_URL=http://monitoring-server:9091).
# =============================================================================
 
from __future__ import annotations
 
import asyncio
import logging
import shlex
from datetime import datetime
from pathlib import Path
from typing import Literal
 
from fastapi import APIRouter, BackgroundTasks, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from config import settings
from db import fetchall_ro, fetchone_ro
from tpl import templates

logger = logging.getLogger("aciertech.backups")
router = APIRouter(prefix="", tags=["backups"])
 
 
# ── Modèles ───────────────────────────────────────────────────────────────────
 
class BackupTriggerRequest(BaseModel):
    dry_run: bool = Field(
        default=False,
        description="Simuler l'exécution sans écriture réelle (--dry-run)",
    )
    no_log: bool = Field(
        default=False,
        description="Ne pas insérer dans dba_schema.backup_history (--no-log)",
    )
 
class PITRRequest(BaseModel):
    target_type: Literal["time", "name", "immediate"] = Field(
        default="time",
        description="Type de cible PITR : time | name | immediate",
    )
    target: str | None = Field(
        default=None,
        description="Timestamp ISO UTC (type=time) ou label backup (type=name)",
        examples=["2025-05-20T14:30:00+00:00"],
    )
    node: str = Field(
        default="pg-node-1",
        description="Nœud cible de la restauration",
    )
    dry_run: bool = Field(
        default=True,
        description="Dry run obligatoire par défaut — forcer à False pour restaurer",
    )
 
class BackupActionResponse(BaseModel):
    success: bool
    action:  str
    dry_run: bool
    stdout:  str = ""
    stderr:  str = ""
    return_code: int = -1
    message: str = ""
 
 
# ── Route HTML ────────────────────────────────────────────────────────────────
 
@router.get("/backups", response_class=HTMLResponse, name="backups")
async def backups_page(request: Request):
    """
    Page backups.html — PRA & pgBackRest complet.
    Charge : historique, statut WAL, info pgbackrest, test restore.
    """
    history       = await _fetch_backup_history(days=8, limit=20)
    test_restore  = await _fetch_last_test_restore()
    pgb_info      = await _run_pgbackrest_info()
    pitr_range    = _compute_pitr_range(history)
 
    ctx = {
        "request":      request,
        "history":      history,
        "test_restore": test_restore or {},
        "pgb_info":     pgb_info,
        "pitr_range":   pitr_range,
        "grafana_backups_url": settings.grafana_iframe_url(
            settings.grafana_uid_backups
        ),
        # Valeurs pour les KPIs
        "last_full_age":      _age_hours(history, "full"),
        "last_diff_age":      _age_hours(history, "diff"),
        "full_count":         sum(
            1 for b in history
            if b.get("backup_type") == "full" and b.get("status") == "success"
        ),
        "verify_ok":          _last_status(history, "verify"),
        "test_restore_ok":    _last_status(history, "test_restore"),
    }
    return templates.TemplateResponse("backups.html", ctx)
 
 
# ── API : Historique ──────────────────────────────────────────────────────────
 
@router.get("/api/backups/history", tags=["backups"])
async def api_backup_history(days: int = 8, limit: int = 30):
    """
    Historique depuis dba_schema.backup_history.
    Colonnes étendues : size_bytes, pitr_target, repo_path, error_detail
    (ALTER TABLE appliqué par les scripts 03-backup/ avant le 1er backup).
    Types : full | diff | incr | pitr | test_restore | verify.
    """
    rows = await _fetch_backup_history(days=days, limit=limit)
    # Résumé
    success_full  = [b for b in rows if b.get("backup_type") == "full"  and b.get("status") == "success"]
    success_diff  = [b for b in rows if b.get("backup_type") == "diff"  and b.get("status") == "success"]
    return {
        "history":          rows,
        "count":            len(rows),
        "last_full_age_h":  _age_hours(rows, "full"),
        "last_diff_age_h":  _age_hours(rows, "diff"),
        "full_count":       len(success_full),
        "diff_count":       len(success_diff),
    }
 
 
async def _fetch_backup_history(days: int = 8, limit: int = 30) -> list[dict]:
    return await fetchall_ro(
        """
        SELECT
            id,
            backup_type,
            stanza,
            status,
            started_at,
            completed_at,
            ROUND(
                EXTRACT(EPOCH FROM (completed_at - started_at))
            )::int                                              AS duration_s,
            size_bytes,
            backup_label,
            notes
        FROM dba_schema.backup_history
        WHERE started_at >= NOW() - (%(d)s || ' days')::interval
        ORDER BY started_at DESC
        LIMIT %(l)s
        """,
        {"d": days, "l": limit},
    )
 
 
# ── API : Statut WAL ──────────────────────────────────────────────────────────
 
@router.get("/api/backups/wal", tags=["backups"])
async def api_wal_status():
    """
    Statut de l'archivage WAL depuis pg_stat_archiver.
    pgBackRest utilise archive-async=y (pgbackrest.conf 03-backup/).
    WAL compressé en zst level=6.
    """
    return await _fetch_wal_status()
 
 
async def _fetch_wal_status() -> dict | None:
    return await fetchone_ro(
        """
        SELECT
            archived_count,
            last_archived_wal,
            last_archived_time,
            failed_count,
            last_failed_wal,
            last_failed_time,
            stats_reset,
            -- Délai depuis le dernier WAL archivé (secondes)
            ROUND(
                EXTRACT(EPOCH FROM (NOW() - last_archived_time))
            )::int                        AS seconds_since_last_archive,
            -- Taux d'échec sur la session
            CASE
                WHEN archived_count + failed_count > 0
                THEN ROUND(
                    100.0 * failed_count / (archived_count + failed_count), 2
                )
                ELSE 0
            END                           AS failure_rate_pct
        FROM pg_stat_archiver
        """
    )
 
 
# ── API : Info pgBackRest (CLI) ───────────────────────────────────────────────
 
@router.get("/api/backups/pgbackrest-info", tags=["backups"])
async def api_pgbackrest_info():
    """
    Exécute `pgbackrest info --stanza=aciertech --output=json`.
    Retourne les métadonnées du dépôt NFS : taille, backups disponibles,
    timeline, fenêtre PITR, WAL disponibles.
    Configuré dans 03-backup/pgbackrest/pgbackrest.conf :
      repo1-path=/var/lib/pgbackrest · cipher=aes-256-cbc · compress=lz4
    """
    return await _run_pgbackrest_info()
 
 
async def _run_pgbackrest_info() -> dict:
    """Exécute pgbackrest info et parse le JSON."""
    import json as _json
    cmd = [
        settings.pgbackrest_bin,
        "info",
        f"--stanza={settings.pgbackrest_stanza}",
        f"--config={settings.pgbackrest_config}",
        "--output=json",
    ]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=20.0
        )
        if proc.returncode == 0:
            data = _json.loads(stdout.decode())
            return {"ok": True, "data": data, "error": None}
        err = stderr.decode().strip()
        logger.warning("pgbackrest info retcode=%d : %s", proc.returncode, err)
        return {"ok": False, "data": None, "error": err}
    except asyncio.TimeoutError:
        return {"ok": False, "data": None, "error": "Timeout (20s) pgbackrest info"}
    except FileNotFoundError:
        return {
            "ok": False,
            "data": None,
            "error": f"pgbackrest introuvable : {settings.pgbackrest_bin}",
        }
    except Exception as exc:
        return {"ok": False, "data": None, "error": str(exc)}
 
 
# ── API : Dernier test de restauration ───────────────────────────────────────
 
@router.get("/api/backups/test-restore", tags=["backups"])
async def api_test_restore():
    """
    Résultat du dernier test_restore.sh depuis dba_schema.backup_history.
    test_restore.sh effectue 10 checks (sensor_registry=47,
    sensor_thresholds=47, schémas, vue AI, fonctions DBA…).
    Métriques Prometheus associées :
      aciertech_backup_test_status{stanza, host} → 1=OK / 0=KO
    """
    return await _fetch_last_test_restore()
 
 
async def _fetch_last_test_restore() -> dict | None:
    return await fetchone_ro(
        """
        SELECT
            id,
            backup_type,
            status,
            started_at,
            completed_at,
            ROUND(
                EXTRACT(EPOCH FROM (completed_at - started_at))
            )::int                                              AS duration_s,
            backup_label
        FROM dba_schema.backup_history
        WHERE backup_type = 'restore_test'
        ORDER BY started_at DESC
        LIMIT 1
        """
    )
 
 
# ── API : Trigger backups (via scripts 03-backup/) ────────────────────────────
 
@router.post("/api/backups/trigger/diff", tags=["backups"])
async def api_trigger_diff(
    body: BackupTriggerRequest,
    background_tasks: BackgroundTasks,
):
    """
    Déclenche backup_diff.sh en arrière-plan.
    Le script bascule automatiquement en FULL s'il n'existe pas de FULL
    de référence dans la stanza.
    Config : backup-standby=y → backup depuis pg-node-2.
    Métriques poussées vers Pushgateway après exécution.
    """
    logger.info("Backup DIFF déclenché — dry_run=%s", body.dry_run)
    background_tasks.add_task(
        _run_backup_script, "backup_diff.sh", body.dry_run, body.no_log
    )
    return {
        "success": True,
        "action":  "backup_diff",
        "dry_run": body.dry_run,
        "message": (
            "[DRY RUN] Simulation backup DIFF lancée en arrière-plan."
            if body.dry_run
            else "Backup DIFF lancé en arrière-plan. "
                 "Résultat disponible dans dba_schema.backup_history."
        ),
    }
 
 
@router.post("/api/backups/trigger/full", tags=["backups"])
async def api_trigger_full(
    body: BackupTriggerRequest,
    background_tasks: BackgroundTasks,
):
    """
    Déclenche backup_full.sh en arrière-plan.
    Durée estimée : 30–45 minutes selon la taille de la base.
    Config : compress=lz4 level=3 · process-max=2 · backup-standby=y.
    """
    logger.warning("Backup FULL déclenché — dry_run=%s", body.dry_run)
    background_tasks.add_task(
        _run_backup_script, "backup_full.sh", body.dry_run, body.no_log
    )
    return {
        "success": True,
        "action":  "backup_full",
        "dry_run": body.dry_run,
        "message": (
            "[DRY RUN] Simulation backup FULL lancée en arrière-plan."
            if body.dry_run
            else "Backup FULL lancé en arrière-plan (~30-45 min). "
                 "Résultat dans dba_schema.backup_history."
        ),
    }
 
 
@router.post("/api/backups/trigger/verify", tags=["backups"])
async def api_trigger_verify(background_tasks: BackgroundTasks):
    """
    Déclenche verify_backup.sh (pgbackrest verify).
    Pousse les métriques aciertech_backup_verify_* vers Pushgateway
    ou écrit dans /var/lib/node_exporter/textfile_collector/pgbackrest.prom
    en fallback.
    """
    logger.info("Vérification backup déclenchée")
    background_tasks.add_task(_run_backup_script, "verify_backup.sh", False, False)
    return {
        "success": True,
        "action":  "verify",
        "message": "Vérification backup lancée en arrière-plan.",
    }
 
 
async def _run_backup_script(
    script_name: str,
    dry_run: bool = False,
    no_log: bool = False,
) -> BackupActionResponse:
    """
    Exécute un script de 03-backup/scripts/ en subprocess asyncio.
    Timeout 3600s (1h) pour le backup FULL.
    Les scripts attendent les variables d'environnement :
      PGBACKREST_STANZA, PUSHGATEWAY_URL, etc.
    """
    script_path = Path(settings.backup_scripts_dir) / script_name
    if not script_path.exists():
        logger.error("Script introuvable : %s", script_path)
        return BackupActionResponse(
            success=False, action=script_name, dry_run=dry_run,
            message=f"Script introuvable : {script_path}",
        )
 
    cmd = [str(script_path)]
    if dry_run:
        cmd.append("--dry-run")
    if no_log:
        cmd.append("--no-log")
 
    env = {
        "PGBACKREST_STANZA": settings.pgbackrest_stanza,
        "PGBACKREST_CONFIG": settings.pgbackrest_config,
        "PUSHGATEWAY_URL":   f"http://{settings.pushgateway_host}:{settings.pushgateway_port}",
        "PGHOST":            settings.pg_haproxy_host,
        "PGPORT":            str(settings.pg_haproxy_port_rw),
        "PGDATABASE":        settings.pg_database,
        "PGUSER":            settings.pg_user_admin,
        "PGPASSWORD":        settings.pg_password_admin,
        "PATH":              "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    }
 
    logger.info("Lancement subprocess : %s", " ".join(cmd))
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=3600.0
        )
        rc = proc.returncode or 0
        out = stdout.decode(errors="replace")
        err = stderr.decode(errors="replace")
        success = rc == 0
        logger.info(
            "Script %s terminé — rc=%d success=%s", script_name, rc, success
        )
        return BackupActionResponse(
            success=success, action=script_name, dry_run=dry_run,
            stdout=out[-2000:], stderr=err[-500:],
            return_code=rc,
            message="OK" if success else f"Erreur rc={rc}",
        )
    except asyncio.TimeoutError:
        logger.error("Timeout (3600s) script %s", script_name)
        return BackupActionResponse(
            success=False, action=script_name, dry_run=dry_run,
            message="Timeout après 3600s", return_code=-1,
        )
    except Exception as exc:
        logger.error("Erreur subprocess %s : %s", script_name, exc)
        return BackupActionResponse(
            success=False, action=script_name, dry_run=dry_run,
            message=str(exc), return_code=-1,
        )
 
 
# ── API : PITR (exécution contrôlée) ─────────────────────────────────────────
 
@router.post("/api/backups/pitr", tags=["backups"])
async def api_pitr(body: PITRRequest, background_tasks: BackgroundTasks):
    """
    Déclenche une restauration PITR via restore_pitr.sh.
    IMPORTANT : dry_run=True par défaut — mettre explicitement à False
    pour déclencher une vraie restauration.
    Le script :
      1. Arrête le cluster Patroni (SSH sur les 3 nœuds)
      2. Renomme le PGDATA courant (.pre_restore.TIMESTAMP)
      3. pgbackrest restore --type=time --target=<ISO UTC>
      4. --target-action=promote
      5. Démarre standalone pour vérification
      6. Ré-intègre Patroni (reinit standbys)
      7. Log dans dba_schema.backup_history (type='pitr')
    """
    if not body.dry_run:
        logger.critical(
            "RESTAURATION PITR RÉELLE — target=%s node=%s",
            body.target, body.node,
        )
    else:
        logger.info(
            "PITR dry run — target=%s node=%s", body.target, body.node
        )
 
    # Construction des arguments du script
    extra_args: list[str] = []
    if body.target_type == "time" and body.target:
        extra_args += ["--target", body.target]
    elif body.target_type == "name" and body.target:
        extra_args += ["--target-name", body.target]
    if body.node:
        extra_args += ["--node", body.node]
    if body.dry_run:
        extra_args.append("--dry-run")
 
    async def _run_pitr():
        script = Path(settings.backup_scripts_dir) / "restore_pitr.sh"
        env = {
            "PGBACKREST_STANZA": settings.pgbackrest_stanza,
            "PGBACKREST_CONFIG": settings.pgbackrest_config,
            "PGHOST":            settings.pg_haproxy_host,
            "PGPORT":            str(settings.pg_haproxy_port_rw),
            "PGDATABASE":        settings.pg_database,
            "PGUSER":            settings.pg_user_admin,
            "PGPASSWORD":        settings.pg_password_admin,
            "PATH":              "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        }
        cmd = [str(script)] + extra_args
        logger.info("PITR subprocess : %s", " ".join(cmd))
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env=env,
            )
            await asyncio.wait_for(proc.communicate(), timeout=7200.0)
        except Exception as exc:
            logger.error("Erreur PITR subprocess : %s", exc)
 
    background_tasks.add_task(_run_pitr)
 
    return {
        "success":    True,
        "action":     "pitr",
        "dry_run":    body.dry_run,
        "target":     body.target,
        "target_type": body.target_type,
        "node":       body.node,
        "message": (
            "[DRY RUN] Simulation PITR lancée."
            if body.dry_run
            else "RESTAURATION PITR LANCÉE — cluster Patroni sera arrêté."
        ),
    }
 
 
# ── Helpers calculs ───────────────────────────────────────────────────────────
 
def _age_hours(history: list[dict], backup_type: str) -> int | None:
    """Retourne l'âge en heures du dernier backup réussi d'un type donné."""
    for b in history:
        if b.get("backup_type") == backup_type and b.get("status") == "success":
            completed = b.get("completed_at")
            if completed:
                try:
                    delta = datetime.now(tz=completed.tzinfo) - completed
                    return int(delta.total_seconds() / 3600)
                except Exception:
                    pass
    return None
 
 
def _last_status(history: list[dict], backup_type: str) -> str:
    """Retourne le statut du dernier backup d'un type donné."""
    for b in history:
        if b.get("backup_type") == backup_type:
            return b.get("status", "unknown")
    return "unknown"
 
 
def _compute_pitr_range(history: list[dict]) -> dict:
    """
    Calcule la fenêtre PITR disponible à partir des backups FULL.
    Retourne oldest_full_at, newest_backup_at, pitr_weeks.
    """
    full_backups = [
        b for b in history
        if b.get("backup_type") == "full" and b.get("status") == "success"
    ]
    if not full_backups:
        return {"oldest_full_at": None, "newest_at": None, "pitr_weeks": 0}
 
    oldest = min(
        (b["started_at"] for b in full_backups if b.get("started_at")),
        default=None,
    )
    newest = max(
        (b["completed_at"] for b in history if b.get("completed_at")),
        default=None,
    )
    weeks = 0
    if oldest and newest:
        try:
            delta = newest - oldest
            weeks = round(delta.days / 7, 1)
        except Exception:
            pass
 
    return {
        "oldest_full_at": str(oldest) if oldest else None,
        "newest_at":      str(newest) if newest else None,
        "pitr_weeks":     weeks,
        "full_count":     len(full_backups),
    }
