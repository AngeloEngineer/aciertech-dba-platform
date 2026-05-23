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

## Lancement rapide (Docker Compose — Windows & Linux)

La façon la plus simple de démarrer est via la stack Docker Compose dans `05-webapp/`.  
Tout est pré-intégré : PostgreSQL + mock-serveur + Grafana + console web.

### Prérequis

- **Docker Desktop** (WSL2 backend recommandé sur Windows)
- **Git**

### Étapes

```bash
# 1. Cloner le dépôt
git clone https://github.com/AngeloEngineer/aciertech-dba-platform.git
cd aciertech-dba-platform/05-webapp

# 2. Copier les variables d'environnement
cp .env.example docker/.env

# 3. Lancer la stack complète
docker compose up -d --build
```

### Accès

| Service     | URL                          |
|-------------|------------------------------|
| Webapp DBA  | http://localhost:8080        |
| Grafana     | http://localhost:3000        |

Grafana : `admin / admin`

> **Note pour Windows** : Le fichier `.gitattributes` force les fins de ligne LF pour les scripts shell, évitant les erreurs sous conteneur Linux.

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