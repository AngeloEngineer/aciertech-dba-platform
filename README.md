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

La stack Docker Compose pré-intègre tout : **PostgreSQL 16 + mock-serveur + Grafana + console web**.  
Aucune installation manuelle de PostgreSQL, Patroni, Prometheus ou Grafana n'est nécessaire.

### Prérequis

- [Docker Desktop](https://docs.docker.com/desktop/) (WSL2 backend sur Windows)
- [Git](https://git-scm.com/)

### Étapes (Windows & Linux identiques)

```bash
# 1. Cloner le dépôt (GitHub token non requis pour le clone)
git clone https://github.com/AngeloEngineer/aciertech-dba-platform.git
cd aciertech-dba-platform/05-webapp

# 2. Lancer la stack (le fichier docker/.env est déjà pré-configuré)
docker compose up -d --build
```

> ⚠️ **Ne pas copier `.env.example` vers `docker/.env`** — le `docker/.env` fourni dans le dépôt contient déjà les bonnes valeurs pour l'exécution sous Docker. Le `.env.example` est réservé à un déploiement natif sans Docker.

### Accès

| Service          | URL                          | Identifiant              |
|------------------|------------------------------|--------------------------|
| Console DBA      | http://localhost:8080        | —                        |
| Grafana          | http://localhost:3000        | `admin / admin`          |

> Les graphiques Grafana sont intégrés **directement** dans chaque page de la console DBA. Pas besoin d'aller sur Grafana séparément.

### Vérification

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080    # → 200
```

### Pipeline Data-to-Model (optionnel)

Le pipeline d'exposition IA se lance avec un fichier Compose supplémentaire :

```bash
docker compose -f docker-compose.yml -f ../06-pipeline/docker-compose.pipeline.yml up -d --build
```

### Redémarrage après reboot

```bash
cd ~/aciertech-dba-platform/05-webapp && docker compose up -d
```

### Arrêt

```bash
docker compose down
# Pour tout supprimer (volumes inclus — perd les données)
docker compose down -v
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