"""
Générateur de données IoT pour le pipeline Data-to-Model — AcierTech DBA

Simule l'ingestion de données capteurs avec un taux d'aberration réglable.
Les données transitent par iot_raw → trigger validation → iot_clean / quarantaine.

Usage :
    python generate_features.py                          # défaut: 47 capteurs, 12% erreurs
    python generate_features.py --sensors 10 --cycles 5
    python generate_features.py --anomaly-rate 0.25       # 25% d'aberrations
"""

from __future__ import annotations

import argparse
import logging
import os
import random
import sys
import time
from datetime import datetime, timezone

import psycopg

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s — %(message)s",
)
logger = logging.getLogger("aciertech.pipeline.simulation")

DSN = os.getenv(
    "PG_DSN",
    "postgresql://aciertech_app:@pg-node-1:5000/aciertech_db",
)

SENSOR_TYPES = {
    "temperature": {"unit": "°C", "min": 20.0, "max": 150.0, "anomaly_min": 250, "anomaly_max": 500},
    "pressure":    {"unit": "bar", "min": 0.0, "max": 100.0, "anomaly_min": 200, "anomaly_max": 400},
    "vibration":   {"unit": "mm/s", "min": 0.0, "max": 25.0, "anomaly_min": 50, "anomaly_max": 100},
    "current":     {"unit": "A", "min": 0.0, "max": 500.0, "anomaly_min": 800, "anomaly_max": 2000},
    "flow":        {"unit": "L/min", "min": 0.0, "max": 500.0, "anomaly_min": 1000, "anomaly_max": 3000},
    "speed":       {"unit": "RPM", "min": 0.0, "max": 3000.0, "anomaly_min": 5000, "anomaly_max": 15000},
    "thickness":   {"unit": "mm", "min": 0.5, "max": 50.0, "anomaly_min": 100, "anomaly_max": 300},
    "weight":      {"unit": "kg", "min": 0.0, "max": 5000.0, "anomaly_min": 10000, "anomaly_max": 50000},
}


def generate_reading(
    sensor_id: int,
    sensor_type: str,
    anomaly_rate: float = 0.12,
) -> dict:
    info = SENSOR_TYPES[sensor_type]
    is_anomaly = random.random() < anomaly_rate
    if is_anomaly:
        value = round(random.uniform(info["anomaly_min"], info["anomaly_max"]), 2)
    else:
        value = round(random.uniform(info["min"], info["max"]), 2)
    return {
        "sensor_id": sensor_id,
        "sensor_type": sensor_type,
        "value": value,
        "unit": info["unit"],
        "recorded_at": datetime.now(timezone.utc),
    }


def fetch_sensors(conn) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute("""
            SELECT sensor_id, sensor_type
            FROM dba_schema.sensor_registry
            WHERE is_active = TRUE
            ORDER BY sensor_id
        """)
        return [{"sensor_id": r[0], "sensor_type": r[1]} for r in cur.fetchall()]


def main():
    parser = argparse.ArgumentParser(description="Génère des données IoT pour le pipeline Data-to-Model")
    parser.add_argument("--sensors", type=int, default=0, help="Nombre de capteurs à simuler (0 = tous)")
    parser.add_argument("--cycles", type=int, default=3, help="Nombre de cycles d'ingestion")
    parser.add_argument("--anomaly-rate", type=float, default=0.12, help="Taux d'aberrations (défaut: 0.12)")
    parser.add_argument("--delay", type=float, default=1.0, help="Délai entre cycles en secondes")
    args = parser.parse_args()

    logger.info("Connexion à %s", DSN)
    conn = psycopg.connect(DSN, application_name="aciertech_pipeline_simulation")
    sensors = fetch_sensors(conn)

    if args.sensors > 0:
        sensors = sensors[:args.sensors]

    if not sensors:
        logger.warning("Aucun capteur actif trouvé dans dba_schema.sensor_registry")
        sys.exit(1)

    logger.info(
        "Démarrage génération : %d capteurs, %d cycles, taux aberrations=%.0f%%",
        len(sensors), args.cycles, args.anomaly_rate * 100,
    )

    total_ok = 0
    total_anomaly = 0

    for cycle in range(1, args.cycles + 1):
        readings = []
        for s in sensors:
            reading = generate_reading(
                s["sensor_id"], s["sensor_type"],
                anomaly_rate=args.anomaly_rate,
            )
            readings.append(reading)
            if reading["value"] > SENSOR_TYPES[s["sensor_type"]]["max"]:
                total_anomaly += 1
            else:
                total_ok += 1

        with conn.cursor() as cur:
            for r in readings:
                cur.execute(
                    """
                    INSERT INTO iot_raw.sensor_readings
                        (sensor_id, sensor_type, value, unit, recorded_at)
                    VALUES (%(sensor_id)s, %(sensor_type)s, %(value)s, %(unit)s, %(recorded_at)s)
                    """,
                    r,
                )
        conn.commit()

        logger.info(
            "Cycle %d/%d : %d lectures insérées dans iot_raw (trigger → routage automatique)",
            cycle, args.cycles, len(readings),
        )
        time.sleep(args.delay)

    conn.close()

    logger.info("=" * 50)
    logger.info("Génération terminée")
    logger.info("  Lectures normales    : %d", total_ok)
    logger.info("  Aberrations injectées: %d (%.1f%%)", total_anomaly, total_anomaly / (total_ok + total_anomaly) * 100 if (total_ok + total_anomaly) > 0 else 0)
    logger.info("  Total                : %d", total_ok + total_anomaly)
    logger.info("=" * 50)
    logger.info("Vérifier dans la console DBA :")
    logger.info("  http://localhost:8080/quality")
    logger.info("  http://localhost:8080/pipeline")


if __name__ == "__main__":
    main()
