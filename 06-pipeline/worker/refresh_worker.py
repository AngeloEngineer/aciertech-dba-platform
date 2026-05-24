"""
Worker de rafraîchissement du pipeline Data-to-Model — AcierTech DBA

Exécute dba_schema.fn_refresh_ai_view() périodiquement pour rafraîchir
iot_clean.v_ai_feature_set en mode CONCURRENTLY.

Connexion en autocommit (obligatoire pour REFRESH CONCURRENTLY).
Fonctionne comme filet de sécurité si pg_cron n'est pas disponible.

Usage :
    python refresh_worker.py                     # toutes les 5 minutes
    python refresh_worker.py --interval 60       # toutes les 60 secondes
    python refresh_worker.py --once              # un seul cycle
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timezone

import psycopg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
)
logger = logging.getLogger("aciertech.pipeline.worker")

DSN = os.getenv(
    "PG_DSN",
    "postgresql://postgres:@pg-node-1:5000/aciertech_db",
)


def refresh_view() -> dict:
    """
    Appelle dba_schema.fn_refresh_ai_view() et retourne le résultat.
    La connexion est en autocommit (obligatoire pour REFRESH CONCURRENTLY).
    """
    conn = psycopg.connect(DSN, application_name="aciertech_pipeline_worker")
    conn.autocommit = True

    try:
        with conn.cursor() as cur:
            cur.execute("SELECT dba_schema.fn_refresh_ai_view()")
            conn.commit()
            logger.info("REFRESH CONCURRENTLY v_ai_feature_set terminé avec succès")
            return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}
    except Exception as exc:
        logger.error("Échec du refresh : %s", exc)
        return {"status": "error", "message": str(exc), "timestamp": datetime.now(timezone.utc).isoformat()}
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Worker de rafraîchissement de la vue IA")
    parser.add_argument("--interval", type=int, default=300, help="Intervalle en secondes (défaut: 300)")
    parser.add_argument("--once", action="store_true", help="Exécuter un seul cycle puis quitter")
    args = parser.parse_args()

    logger.info("DSN=%s", DSN.replace("postgresql://postgres:", "postgresql://postgres:****@"))
    logger.info("Intervalle=%ds, once=%s", args.interval, args.once)

    cycle = 0
    while True:
        cycle += 1
        logger.info("Cycle %d — Début refresh", cycle)
        result = refresh_view()
        logger.info("Cycle %d — Résultat : %s", cycle, result)

        if args.once:
            break

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
