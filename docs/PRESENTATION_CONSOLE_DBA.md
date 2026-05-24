# Console DBA AcierTech — Présentation de l'Application Web

> **Projet INF1620** — Formation DBA PostgreSQL 16 Haute Disponibilité
> AcierTech Industries S.A. — Lomé, Togo

---

## Accès

| Point d'accès | URL | Identifiants |
|---|---|---|
| Console DBA (webapp) | http://localhost:8080 | — |
| Grafana (intégré dans la console) | *Tous les graphiques sont visibles depuis la console* | — |
| Grafana (accès direct) | http://localhost:3000 | `admin / admin` |
| PostgreSQL | `localhost:5433` | `postgres / postgres` |

---

## Sommaire des pages

| Page | URL | Description |
|---|---|---|
| Tableau de bord | `/` | Vue synthèse du cluster + Grafana Performance PostgreSQL |
| Cluster | `/cluster` | Topologie Patroni 3 nœuds, réplication, sessions, etcd |
| Qualité | `/quality` | Pipeline qualité IoT : taux validation, anomalies, capteurs silencieux |
| Sauvegardes | `/backups` | PRA : historique pgBackRest, restauration PITR, vérifications |
| Pipeline | `/pipeline` | Data-to-Model : feature set IA, flux, rendement, exposition API |
| Contrôle | `/failover` | Actions manuelles Patroni : switchover, failover, reinit, pause |
| Alertes | `/alerts` | Alertes Prometheus : règles, sévérité, métriques Pushgateway |
| Simulation | `/disaster` | Simulation de sinistres : crash primaire, split-brain, saturation |

---

## 1. Tableau de bord (`/`)

**Rôle** : Page d'accueil — vue d'ensemble du système.

**Indicateurs clés (KPIs)** :
- État du cluster (OK / Dégradé / Critique)
- Qualité des données (taux de validation % sur 1h)
- Âge de la dernière sauvegarde FULL
- Lag de réplication (secondes / millisecondes)
- Connexions actives (via HAProxy)
- Capteurs silencieux (détection d'absence d'émission)

**Composants** :
- Topologie des 3 nœuds PostgreSQL avec rôle (PRIMARY / REPLICA) et lag
- Grille qualité des 7 types de capteurs avec barres de progression
- Activité récente (jobs pg_cron, sauvegardes, événements)
- Stack technique (PostgreSQL 16, Patroni, pgBackRest, etc.)

**Iframe Grafana intégré** :
- `aciertech-pg-performance` — Performance PostgreSQL (cache hit ratio, TPS, connexions)

---

## 2. Cluster (`/cluster`)

**Rôle** : Surveillance temps réel du cluster HA Patroni.

**Sections** :

- **Topologie HA** — Visualisation des 3 nœuds (PRIMARY + 2 REPLICA) avec lag de réplication, timeline, état de santé
- **Réplication** — Tableau détaillé : LSN, lag en octets/secondes, mode sync, état du WAL archiving
- **Sessions actives** — Liste des sessions clients avec détection des requêtes longues (>5s) et des blocages (via `pg_blocking_pids`)
- **Santé etcd** — Statut du cluster de consensus Raft (3 membres, leader, termes)
- **Statistiques HAProxy** — Métriques de routage : connexions, montée en charge, état des backends

**Iframe Grafana intégré** :
- `aciertech-cluster-ha` — Tableaux de bord HA : état Patroni, lag, connexions

---

## 3. Qualité des données (`/quality`)

**Rôle** : Pipeline de validation des données IoT des 47 capteurs.

**Pipeline** :
```
Capteurs IoT → iot_raw (brut)
                 → Trigger trg_validate_sensor
                    → score ≥ 70 → iot_clean (données propres → IA)
                    → score < 70 → iot_quarantine (rejet → audit)
```

**Sections** :
- **Résumé qualité** — Taux de validation global, score moyen, volume nettoyé vs rejeté
- **Grille par type de capteur** — Pour chaque type : total, valide, rejeté, taux, niveau (EXCELLENT / BON / DÉGRADÉ / CRITIQUE / NO_DATA)
- **Anomalies récentes** — Dernières anomalies détectées (ZSCORE_OUTLIER, OUT_OF_RANGE, etc.)
- **Capteurs silencieux** — Capteurs actifs sans émission récente (CRITICAL / WARNING / NEVER_SEEN)
- **Statut des jobs pg_cron** — 8 jobs planifiés : quality_snapshot, refresh_ai_view, purge_*, etc.

**Mécanisme de scoring** :
- `NO_THRESHOLD` → 50 | `OUT_OF_RANGE` → 0 | `WARNING_LOW/HIGH` → 75
- `ZSCORE_ANOMALY` → 65 | score combiné → 55 | `VALID` → 100
- Fenêtre Z-score : 1h glissante sur `iot_raw` pour détection statistique

**Iframe Grafana intégré** :
- `aciertech-data-quality` — Qualité des données IoT (taux par type, anomalies)

---

## 4. Sauvegardes & PRA (`/backups`)

**Rôle** : Gestion des sauvegardes pgBackRest et restauration PITR.

**Stratégie de rétention** :
- FULL → chaque dimanche 02:00 (rétention 4 semaines)
- DIFF → chaque jour 02:00 (rétention 7 jours)
- WAL archiving → continu (toutes les 5 minutes max)
- Vérification d'intégrité → hebdomadaire (SHA-256)

**Sections** :
- **Graphique de rétention** — Visualisation des backups disponibles avec leur statut
- **Tableau des sauvegardes** — Historique complet : type, statut, taille, durée, vérification
- **Restauration PITR** — Interface interactive pour choisir un point de restauration
- **Tests de restauration** — Résultats des tests hebdomadaires (10 vérifications de cohérence)
- **Statut WAL archiving** — Dernier WAL archivé, âge, taille totale

**RPO / RTO** :
- RPO : < 5 minutes (WAL archiving) / quasi-zéro (réplication synchrone)
- RTO : < 30s (failover Patroni) / 15-30 min (PITR complet)

**Iframe Grafana intégré** :
- `aciertech-pra-backups` — Sauvegardes & PRA (espace backup, âge, historique)

---

## 5. Pipeline Data-to-Model (`/pipeline`)

**Rôle** : Exposition du feature set agrégé pour le système IA de maintenance prédictive.

**Flux** :
```
47 Capteurs IoT → iot_raw (validation)
                  → iot_clean (score ≥ 70)
                     → v_ai_feature_set (vue matérialisée, REFRESH CONCURRENTLY 5min)
                        → API /api/v1/features → système IA
```

**Indicateurs clés** :
- Buckets feature (fenêtre 24h, agrégation minute)
- Capteurs actifs dans le feature set / 47
- Score qualité moyen des features
- Rendement pipeline (clean / raw)
- Volume rejeté (quarantaine)

**Couverture par type de capteur** :
- Tableau détaillant pour chaque type : total, actifs dans features, couverture %

**API d'exposition (port 8100)** :
- `GET /api/v1/features` — Feature set complet (filtres : sensor_id, sensor_type, since_minutes)
- `GET /api/v1/features/{id}` — Features d'un capteur spécifique
- `GET /api/v1/summary` — Résumé global (buckets, capteurs, qualité)
- `GET /api/v1/health` — Santé du service
- `GET /api/v1/info` — Métadonnées du pipeline

**Worker de rafraîchissement** :
- pg_cron : `aciertech_refresh_ai_view` toutes les 5 minutes
- Worker Python de secours (`06-pipeline/worker/refresh_worker.py`)
- Refresh manuel via le bouton "Actualiser" dans l'interface

**Iframe Grafana intégré** :
- `aciertech-pg-performance?var-metric=aciertech_ai_view_refresh` — Monitoring du refresh

---

## 6. Contrôle du cluster (`/failover`)

**Rôle** : Actions manuelles sur le cluster Patroni (réservé DBA).

**Actions disponibles** :

| Action | Description | Risque |
|---|---|---|
| **Switchover** | Basculement contrôlé vers un réplica | Aucun (zéro perte) |
| **Failover forcé** | Promotion d'urgence d'un réplica | Perte possible si PRIMARY actif |
| **Réinitialisation** | Réplication complète depuis le PRIMARY | Temps d'arrêt du réplica |
| **Pause / Reprise** | Suspendre/reprendre le failover auto | Fenêtre de maintenance |

**Sécurité** :
- Double confirmation requise (saisie `CONFIRM` ou `FAILOVER-FORCE`)
- Journal d'événements en direct
- Bannière "Production" avec animation d'alerte

**Iframe Grafana intégré** :
- `aciertech-cluster-ha` — Visualisation de l'impact en temps réel

---

## 7. Alertes (`/alerts`)

**Rôle** : Surveillance des alertes Prometheus et métriques Pushgateway.

**Sources d'alertes** :
- Prometheus Alertmanager (alerte actives)
- Règles Prometheus (4 groupes : cluster, data quality, node, réplication)
- Pushgateway (métriques personnalisées des scripts backup)

**Compteurs de sévérité** :
- Critique (rouge) — Action immédiate requise
- Avertissement (jaune) — Surveillance renforcée
- En attente (violet) — Condition détectée, durées non dépassées
- Info (bleu) — Information

**Groupes de règles** :
- **Patroni Cluster** — Nœud DOWN, quorum etcd perdu, absence de PRIMARY
- **Réplication** — Lag >30s (critique), >5s (avertissement)
- **Connexions** — Saturation >85% (avertissement), >95% (critique)
- **Qualité données** — Taux validation bas, capteurs silencieux, vue IA périmée
- **Nœud** — CPU, RAM, disque, swap, I/O

**Iframe Grafana intégré** :
- `aciertech-pg-performance` — Contexte temporel des métriques en alerte

---

## 8. Simulation de sinistres (`/disaster`)

**Rôle** : Démonstration interactive de scénarios de sinistre et reprise.

**Scénarios disponibles** :

| Scénario | Effet simulé | Reprise |
|---|---|---|
| Crash du nœud primaire | pg-node-1 → DOWN, failover automatique | Patroni élit pg-node-2, réintégration |
| Split-brain | Deux nœuds se déclarent PRIMARY | Réconciliation via etcd quorum |
| Partition réseau | Isolement d'un nœud du cluster | Resynchronisation WAL au retour |
| Saturation ressource | CPU/MEM à 95% sur le PRIMARY | Délestage via HAProxy |

**Indicateurs de statut** :
- État cluster avant/pendant/après
- Timeline, LSN, connexions
- Journal des événements en direct
- Latence de bascule mesurée

**Iframe Grafana intégré** :
- `aciertech-cluster-ha` — Visualisation de l'impact sur les métriques

---

## Architecture Technique

### Stack logicielle

| Composant | Technologie | Rôle |
|---|---|---|
| Backend | FastAPI (Python 3.12) | API REST (uvicorn, asynchrone) |
| Frontend | Jinja2 + CSS personnalisé | Templates sans build step |
| Base de données | PostgreSQL 16 | Stockage ACID |
| HA | Patroni + etcd + HAProxy | Orchestration, consensus, routage |
| Sauvegarde | pgBackRest | PITR, WAL archiving, vérification |
| Monitoring | Prometheus + Grafana | Métriques, alertes, dashboards |
| Pooling | pgBouncer | Gestion des connexions |

### Schémas de données

```
iot_raw         → Réception brute des 47 capteurs (contraintes CHECK physiques)
iot_clean       → Données validées (score ≥ 70) — alimentation IA
iot_quarantine  → Données rejetées (score < 70) — audit trail
dba_schema      → Administration : seuils, registre, backups, snapshots qualité
```

### APIs exposées

| Groupe | Endpoints | Utilisation |
|---|---|---|
| Santé | `/api/health`, `/api/health/db` | Status pill navbar |
| Cluster | `/api/cluster/topology`, `/replication`, `/sessions`, `/etcd-health`, `/haproxy-stats` | Page Cluster |
| Qualité | `/api/quality/dashboard`, `/silent`, `/anomalies`, `/anomaly-stats`, `/sensors`, `/cron-jobs`, `/refresh-ai-view` | Page Qualité |
| Sauvegardes | `/api/backups/history`, `/wal-status`, `/verify`, `/restore` | Page Sauvegardes |
| Pipeline | `/api/pipeline/health`, `/features`, `/refresh-history`, `POST /refresh` | Page Pipeline |
| Alertes | `/api/alerts/active`, `/rules`, `/pushgateway` | Page Alertes |
| Simulation | `/api/disaster/scenarios`, `/start`, `/status`, `/reset` | Page Simulation |
| Contrôle | `POST /api/cluster/switchover`, `/failover`, `/reinit`, `/pause`, `/resume` | Page Contrôle |

---

## Déploiement

### Prérequis
- Docker & Docker Compose
- Git
- Navigateur moderne

### Démarrage rapide

```bash
git clone https://github.com/AngeloEngineer/aciertech-dba-platform.git
cd aciertech-dba-platform/05-webapp
cp .env.example docker/.env
docker compose up -d --build
```

### Vérification
```bash
# Toutes les pages doivent répondre en HTTP 200
for p in / /cluster /quality /backups /pipeline /failover /alerts /disaster; do
  curl -s -o /dev/null -w "GET $p → %{http_code}\n" http://localhost:8080$p
done
```

---

## Structure du dépôt

```
aciertech-dba/
├── 01-infra/           # Patroni, etcd, HAProxy, pgBouncer (configs)
├── 02-sql/             # Migrations V001-V008, fonctions, vues, triggers
├── 03-backup/          # pgBackRest conf, scripts FULL/DIFF/PITR/verify
├── 04-monitoring/      # Prometheus, Grafana, exporters, règles d'alerte
├── 05-webapp/          # Application FastAPI + Docker Compose stack
│   ├── routers/        # 7 routeurs : cluster, quality, backups, pipeline, alerts, disaster
│   ├── templates/      # 8 pages HTML + base.html (thème dark Google AI Studio)
│   ├── config.py       # Paramètres centralisés (pydantic-settings)
│   ├── db.py           # Pools PostgreSQL (RO + ADMIN) via psycopg3
│   ├── tpl.py          # Templates Jinja2 avec helpers Grafana
│   └── main.py         # Application FastAPI (lifespan, routes, middlewares)
├── 06-pipeline/        # Pipeline Data-to-Model
│   ├── exposition/     # API FastAPI pour le système IA (port 8100)
│   ├── worker/         # Worker de rafraîchissement v_ai_feature_set
│   └── simulation/     # Générateur de données IoT
├── 07-scripts/         # Scripts de démonstration sinistres
├── docs/               # Documentation complète
└── claude/             # Contexte de continuité (INF1620)
```

---

*Document généré pour la présentation du projet INF1620 — AcierTech Industries S.A.*
