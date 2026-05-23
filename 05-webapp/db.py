# =============================================================================
# DB — AcierTech DBA Console · 05-webapp/db.py
#
# Gestion des pools de connexions PostgreSQL via psycopg3 (psycopg >= 3.2).
# Deux pools distincts :
#   pool_ro    → aciertech_ro via HAProxy :5001 (RO) — lectures de vues
#   pool_admin → postgres    via HAProxy :5000 (RW) — opérations admin
#
# Règles d'usage :
#   • pool_ro    : toutes les requêtes SELECT sur les vues dba_schema.*,
#                  iot_quarantine.*, cron.job_run_details
#   • pool_admin : fn_refresh_ai_view (autocommit=True obligatoire),
#                  pg_stat_activity détaillée, diagnostics avancés
#
# Contrainte critique (héritée de 01-infra pgbouncer pool_mode=transaction) :
#   La webapp se connecte DIRECTEMENT à HAProxy (pas pgBouncer :6432),
#   donc pas de restriction advisory locks / SET LOCAL / LISTEN.
#   Mais les requêtes doivent rester courtes (statement_timeout=30s).
# =============================================================================

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from typing import AsyncGenerator

import psycopg
import psycopg_pool
from psycopg.rows import dict_row

from config import settings

logger = logging.getLogger(__name__)

# ── Instances globales des pools ──────────────────────────────────────────────
# Initialisées dans le lifespan de main.py, None avant démarrage.

_pool_ro:    psycopg_pool.AsyncConnectionPool | None = None
_pool_admin: psycopg_pool.AsyncConnectionPool | None = None


# ── Initialisation / fermeture (appelées depuis main.py lifespan) ─────────────

async def init_pools() -> None:
    """
    Ouvre les deux pools de connexions au démarrage de l'application.
    À appeler dans le lifespan FastAPI (startup).
    Les deux pools sont initialisés en parallèle pour réduire le temps
    d'attente. Chaque pool a un timeout court (pg_pool_open_timeout)
    pour ne pas bloquer le démarrage si les bases sont indisponibles.
    """
    global _pool_ro, _pool_admin

    async def _open_pool(
        name: str,
        dsn: str,
        min_size: int,
        max_size: int,
        kwargs: dict | None = None,
    ) -> psycopg_pool.AsyncConnectionPool | None:
        try:
            pool = psycopg_pool.AsyncConnectionPool(
                conninfo=dsn,
                min_size=min_size,
                max_size=max_size,
                timeout=settings.pg_pool_timeout,
                kwargs=kwargs or {},
                name=name,
                open=False,
            )
            await asyncio.wait_for(
                pool.open(wait=True, timeout=settings.pg_pool_open_timeout),
                timeout=settings.pg_pool_open_timeout + 2.0,
            )
            logger.info("Pool %s ouvert — %d connexions min.", name, min_size)
            return pool
        except asyncio.TimeoutError:
            logger.warning("Pool %s : timeout d'ouverture — mode dégradé", name)
        except Exception as exc:
            logger.error("Échec pool %s : %s", name, exc)
        return None

    logger.info("Initialisation des pools PostgreSQL (timeout=%ss)...",
                settings.pg_pool_open_timeout)

    results = await asyncio.gather(
        _open_pool(
            "pool_ro", settings.dsn_ro,
            settings.pg_pool_min_size, settings.pg_pool_max_size,
            {"row_factory": dict_row, "autocommit": True},
        ),
        _open_pool(
            "pool_admin", settings.dsn_admin,
            1, 5,
            {"row_factory": dict_row},
        ),
        return_exceptions=True,
    )

    _pool_ro, _pool_admin = results[:2]
    if _pool_ro is None:
        logger.warning("L'application démarrera en mode dégradé (pool RO indisponible).")
    if _pool_admin is None:
        logger.warning("L'application démarrera en mode dégradé (pool ADMIN indisponible).")


async def close_pools() -> None:
    """Ferme proprement les pools. À appeler dans le lifespan (shutdown)."""
    global _pool_ro, _pool_admin
    if _pool_ro:
        await _pool_ro.close()
        logger.info("Pool RO fermé.")
    if _pool_admin:
        await _pool_admin.close()
        logger.info("Pool ADMIN fermé.")


# ── Context managers ──────────────────────────────────────────────────────────

@asynccontextmanager
async def get_ro_conn() -> AsyncGenerator[psycopg.AsyncConnection, None]:
    """
    Connexion RO depuis le pool (aciertech_ro).
    Usage :
        async with get_ro_conn() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SELECT ...")
    """
    if _pool_ro is None:
        raise RuntimeError("Pool RO non initialisé — appeler init_pools() d'abord.")
    async with _pool_ro.connection() as conn:
        yield conn


@asynccontextmanager
async def get_admin_conn(
    autocommit: bool = False,
) -> AsyncGenerator[psycopg.AsyncConnection, None]:
    """
    Connexion ADMIN depuis le pool (postgres).
    autocommit=True : obligatoire pour fn_refresh_ai_view
    (REFRESH MATERIALIZED VIEW CONCURRENTLY ne peut pas tourner dans une transaction).
    """
    if _pool_admin is None:
        raise RuntimeError("Pool ADMIN non initialisé — appeler init_pools() d'abord.")
    async with _pool_admin.connection() as conn:
        if autocommit:
            await conn.set_autocommit(True)
        yield conn


# ── Helpers de requêtes ───────────────────────────────────────────────────────

async def fetchall_ro(query: str, params: tuple = ()) -> list[dict]:
    """
    Exécute une requête SELECT via le pool RO et retourne toutes les lignes.
    Retourne une liste vide en cas d'erreur (log l'erreur sans propager).
    """
    try:
        async with get_ro_conn() as conn:
            async with conn.cursor() as cur:
                await cur.execute(query, params)
                return await cur.fetchall()
    except Exception as exc:
        logger.error("fetchall_ro erreur — query=%s err=%s", query[:80], exc)
        return []


async def fetchone_ro(query: str, params: tuple = ()) -> dict | None:
    """
    Exécute une requête SELECT via le pool RO et retourne la première ligne.
    Retourne None en cas d'erreur ou si aucun résultat.
    """
    try:
        async with get_ro_conn() as conn:
            async with conn.cursor() as cur:
                await cur.execute(query, params)
                return await cur.fetchone()
    except Exception as exc:
        logger.error("fetchone_ro erreur — query=%s err=%s", query[:80], exc)
        return None


async def execute_admin(
    query: str,
    params: tuple = (),
    autocommit: bool = False,
) -> bool:
    """
    Exécute une commande via le pool ADMIN (INSERT/UPDATE/CALL/REFRESH).
    Retourne True si succès, False sinon.
    """
    try:
        async with get_admin_conn(autocommit=autocommit) as conn:
            async with conn.cursor() as cur:
                await cur.execute(query, params)
        return True
    except Exception as exc:
        logger.error("execute_admin erreur — query=%s err=%s", query[:80], exc)
        return False


async def fetchone_admin(
    query: str,
    params: tuple = (),
    autocommit: bool = False,
) -> dict | None:
    """
    Exécute une requête via le pool ADMIN et retourne la première ligne.
    Utilisé pour fn_refresh_ai_view qui retourne une valeur.
    """
    try:
        async with get_admin_conn(autocommit=autocommit) as conn:
            async with conn.cursor() as cur:
                await cur.execute(query, params)
                return await cur.fetchone()
    except Exception as exc:
        logger.error("fetchone_admin erreur — query=%s err=%s", query[:80], exc)
        return None


# ── Health check DB ───────────────────────────────────────────────────────────

async def db_health_check() -> dict:
    """
    Vérifie la disponibilité de la base. Utilisé par GET /api/health.
    Retourne un dict avec statut et version PostgreSQL.
    """
    try:
        row = await fetchone_ro(
            "SELECT version(), current_database(), pg_is_in_recovery() AS is_replica, "
            "pg_postmaster_start_time() AS started_at"
        )
        if row:
            return {
                "status": "ok",
                "version": row.get("version", "")[:30],
                "database": row.get("current_database"),
                "is_replica": row.get("is_replica", False),
                "started_at": str(row.get("started_at", "")),
            }
    except Exception as exc:
        logger.error("db_health_check failed: %s", exc)
    return {"status": "error", "version": None, "database": None}