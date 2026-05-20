# AcierTech DBA Platform — INF1620

> Plateforme PostgreSQL 16 industrielle hautement disponible
> pour une usine de transformation d'acier (47 capteurs IoT, Lomé).

## Architecture

| Composant | Rôle |
|---|---|
| PostgreSQL 16 × 3 nœuds | Moteur principal |
| Patroni + etcd | Failover automatique < 30s |
| HAProxy | Routage R/W splits |
| pgBouncer | Pooling (pool_mode=transaction) |
| pgBackRest | PITR, RPO < 5min |
| Prometheus + Grafana | Observabilité complète |
| FastAPI | Console DBA web |

## Compétences DBA démontrées

- Haute disponibilité PostgreSQL (Patroni, etcd, HAProxy)
- PRA avec PITR (pgBackRest, RPO < 5min, RTO < 30s)
- Data Quality pipeline (triggers PL/pgSQL, scoring, quarantaine)
- Monitoring avancé (postgres_exporter, dashboards Grafana)
- Optimisation (index BRIN, index partiels, pool_mode=transaction)

## Stack technique

`PostgreSQL 16` `Patroni` `etcd` `HAProxy` `pgBouncer`
`pgBackRest` `Prometheus` `Grafana` `FastAPI` `Docker`
`PL/pgSQL` `Python` `Linux systemd` `POP!_OS 24.04`

## Lancement rapide

```bash
# 1. Copier les variables d'environnement
cp .env.example .env

# 2. Démarrer l'infrastructure (etcd, HAProxy, Prometheus, Grafana)
docker-compose up -d

# 3. Initialiser la base
sudo -u postgres bash 02-sql/init/00_create_database.sh
bash 02-sql/init/01_run_migrations.sh

# 4. Vérifier le cluster
patronictl -c 01-infra/patroni/patroni-node1.yml list
```

## Structure du projet

aciertech-dba/
├── 01-infra/        # Patroni, etcd, HAProxy, pgBouncer
├── 02-sql/          # Migrations, triggers, vues, fonctions
├── 03-backup/       # pgBackRest, scripts PRA, PITR
├── 04-monitoring/   # Prometheus, Grafana, alertes
├── 05-webapp/       # Console DBA FastAPI
├── 06-pipeline/     # Simulateur IoT, exposition IA
├── 07-scripts/      # Installation, opérations, diagnostics
└── docs/            # Architecture, runbooks, soutenance

## Contexte formation

Projet de fin de formation dans l'unité d'enseignement INF1620.
Objectif : transformer une infrastructure fragile (SPOF, 0 backup,
12% données aberrantes) en plateforme industrielle résiliente.

---
*Projet de fin de formation — INF1620: Administration de base données*