# INF1620 — Architecture DBA Industrielle
## AcierTech Industries S.A. — Plateforme PostgreSQL Haute Disponibilité
### Document de Conception Technique — Projet de Fin de Formation

---

## 0. Reformulation du Problème

### Situation initiale (état zéro)

AcierTech Industries S.A. exploite 47 capteurs IoT industriels qui produisent en continu des mesures critiques (température, pression, vibrations, courant, débit). Ces données alimentent un modèle d'IA de maintenance prédictive déjà en production. Cependant, l'infrastructure de données sous-jacente est dans un état catastrophique :

- Un serveur PostgreSQL unique, sans réplication, sans failover
- Aucune politique de sauvegarde définie ni exécutée
- 12 % de données aberrantes contaminant le flux d'alimentation du modèle IA
- Aucune supervision, aucune alerte, aucune visibilité opérationnelle
- Risque d'arrêt de production complet en cas de panne matérielle

### Conséquences métier concrètes

Une panne du serveur PostgreSQL entraîne l'arrêt immédiat de l'alimentation du modèle IA. Sans données, le système de maintenance prédictive devient aveugle. Les équipes de maintenance passent alors en mode réactif pur, ce qui coûte en moyenne 3 à 5 fois plus cher qu'une intervention préventive planifiée. Les données aberrantes non filtrées génèrent des faux positifs qui déclenchent des alertes maintenance inutiles et usent prématurément les équipes terrain.

### Ce que ce projet accomplit

Ce projet transforme une infrastructure fragile et opaque en une plateforme DBA industrielle résiliente. Le résultat est un système capable de garantir la continuité de l'alimentation des données, la qualité du flux IoT, la restauration rapide après incident, et la visibilité complète de l'état du cluster en temps réel. L'IA de maintenance prédictive n'est pas le sujet — mais elle bénéficiera directement d'une fondation de données digne d'un environnement de production industrielle.

---

## 1. Architecture Haute Disponibilité PostgreSQL

### 1.1 Vue d'ensemble de l'architecture

L'architecture cible repose sur un cluster PostgreSQL à 3 nœuds orchestré par Patroni, avec etcd comme gestionnaire de consensus distribué, HAProxy comme point d'entrée intelligent et pgBouncer comme gestionnaire de connexions. Voici la topologie complète :

```
┌─────────────────────────────────────────────────────────────────┐
│                    COUCHE APPLICATIVE                           │
│    Application IoT  │  Système IA  │  Console DBA Web          │
└──────────────┬──────────────────────────────┬───────────────────┘
               │                              │
               ▼                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    COUCHE ROUTAGE                               │
│              HAProxy  (port 5000 R/W  │  port 5001 R/O)        │
└──────────────┬───────────────────────────────┬─────────────────┘
               │                               │
               ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                 COUCHE POOLING CONNEXIONS                       │
│     pgBouncer Primary               pgBouncer Replica          │
│     (port 6432)                     (port 6433)                │
└──────────────┬───────────────────────────────┬─────────────────┘
               │                               │
               ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    COUCHE DONNÉES                               │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌───────────────┐  │
│  │  pg-node-1      │  │  pg-node-2      │  │  pg-node-3   │  │
│  │  PRIMARY        │  │  REPLICA        │  │  REPLICA     │  │
│  │  PostgreSQL 16  │  │  PostgreSQL 16  │  │  PostgreSQL  │  │
│  │  Patroni Agent  │  │  Patroni Agent  │  │  Patroni     │  │
│  │  port 5432      │  │  port 5432      │  │  port 5432   │  │
│  └────────┬────────┘  └────────▲────────┘  └──────▲───────┘  │
│           │    Streaming WAL   │                   │          │
│           └────────────────────┴───────────────────┘          │
└─────────────────────────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────────┐
│               COUCHE CONSENSUS DISTRIBUÉ                        │
│        etcd Cluster  (3 nœuds, quorum majority)                │
│     etcd-1 :2379  │  etcd-2 :2379  │  etcd-3 :2379            │
└─────────────────────────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────────┐
│                  COUCHE STOCKAGE / PRA                         │
│           WAL Archive  →  pgBackRest  →  Backup Store          │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 Rôle exact de chaque composant

**PostgreSQL 16** est le moteur de base de données relationnel. Il gère la persistance, les transactions ACID, la réplication WAL, les triggers, les contraintes et les vues matérialisées. La version 16 apporte des améliorations significatives sur la réplication logique, le parallélisme et les performances des requêtes analytiques.

**Patroni** est l'orchestrateur de haute disponibilité. Il surveille l'état de santé de chaque instance PostgreSQL, gère les élections de leader via etcd, exécute le failover automatique et expose une API REST permettant à HAProxy de connaître à tout moment quel nœud est primaire. Patroni remplace avantageusement les solutions manuelles de failover car il fournit un consensus fort avant toute promotion de réplica.

**etcd** est le magasin de configuration distribué qui sert de source de vérité pour le cluster Patroni. Il implémente l'algorithme Raft pour garantir un consensus distribué sans split-brain. Sans etcd en bonne santé, Patroni ne peut pas effectuer de failover. C'est pourquoi on déploie un cluster etcd à 3 nœuds pour tolérer la perte d'un nœud (quorum = 2/3).

**HAProxy** est le load balancer qui route le trafic applicatif. Il expose deux ports distincts : le port 5000 pour les connexions lecture-écriture (routées exclusivement vers le primaire via health check sur l'API Patroni) et le port 5001 pour les connexions lecture seule (distribuées sur les réplicas). HAProxy interroge l'endpoint `/master` et `/replica` de Patroni toutes les 2 secondes pour maintenir sa table de routage à jour.

**pgBouncer** est le pooler de connexions. PostgreSQL ouvre un processus OS par connexion client, ce qui devient coûteux à grande échelle. pgBouncer maintient un pool de connexions persistantes vers PostgreSQL et les réutilise pour les connexions applicatives éphémères. Pour un projet IoT avec 47 capteurs plus l'application IA, cela évite la saturation du processus postmaster.

### 1.3 Workflow complet de failover

Voici le séquencement exact d'un failover automatique lors d'une panne du nœud primaire :

```
T+0s   → pg-node-1 (PRIMARY) tombe (crash OS, panne réseau, OOM killer)
T+2s   → Patroni sur pg-node-2 et pg-node-3 détectent l'absence de heartbeat
T+4s   → Patroni tente de prendre le lock de leader dans etcd
T+6s   → etcd accorde le lock à pg-node-2 (plus à jour en LSN)
T+6s   → pg-node-2 exécute pg_ctl promote
T+7s   → HAProxy interroge Patroni : /master répond 200 sur pg-node-2
T+7s   → HAProxy bascule le trafic écriture vers pg-node-2
T+8s   → pg-node-3 se reconnecte en streaming replication vers pg-node-2
T+10s  → Le système est pleinement opérationnel avec le nouveau primaire
```

Le RTO de cette architecture est inférieur à 30 secondes dans des conditions normales. Les connexions applicatives en cours sont interrompues pendant la bascule (pgBouncer gère la reconnexion automatique), mais aucune transaction validée n'est perdue grâce à la réplication synchrone configurée sur au moins un réplica.

### 1.4 Stratégie anti-SPOF

Chaque composant est analysé comme point de défaillance potentiel :

Le nœud PostgreSQL unique est éliminé par la réplication streaming à 3 nœuds. Le gestionnaire de haute disponibilité lui-même (Patroni) n'est pas un SPOF car chaque nœud PostgreSQL embarque son propre agent Patroni. Le consensus distribué (etcd) tolère la perte d'un nœud sur trois. HAProxy est le seul composant qui reste en single instance dans cette architecture locale — en production réelle, il serait doublé avec Keepalived et une VIP. Pour le projet de démonstration, HAProxy unique est acceptable avec documentation de cette limitation. pgBouncer peut être doublé si nécessaire mais n'est pas critique pour la démo.

### 1.5 Métriques critiques à surveiller sur le cluster HA

Les métriques de réplication à suivre en priorité sont le lag de réplication (en octets et en secondes), le statut de chaque slot de réplication, le nombre de connexions sur chaque nœud, le temps de réponse de l'API Patroni et l'état du quorum etcd.

---

## 2. PRA et Stratégie de Sauvegarde

### 2.1 Outil retenu : pgBackRest

pgBackRest est l'outil de référence pour la sauvegarde PostgreSQL en environnement de production. Il gère nativement les sauvegardes FULL, DIFF, INCR, le WAL archiving, la compression, la vérification d'intégrité et la restauration PITR. Il est préféré à pg_dump pour ce projet car pg_dump ne permet pas de PITR et ne peut pas gérer la continuité du WAL archiving.

### 2.2 Stratégie de rétention complète

```
┌─────────────────────────────────────────────────────────────────┐
│                  POLITIQUE DE SAUVEGARDE                       │
│                                                                 │
│  FULL backup        →  Chaque dimanche à 02:00                 │
│  DIFF backup        →  Chaque jour (lun-sam) à 02:00           │
│  WAL archiving      →  Continu (toutes les 5 minutes max)      │
│                                                                 │
│  Rétention FULL     →  4 semaines (4 sauvegardes FULL)         │
│  Rétention WAL      →  7 jours (permet PITR sur 7 jours)      │
│                                                                 │
│  Stockage backup    →  /backup/pgbackrest/ (disque local)      │
│  Vérification       →  Checksum SHA-256 automatique            │
│  Test restauration  →  Hebdomadaire (samedi à 04:00)           │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 Configuration pgBackRest essentielle

```ini
# /etc/pgbackrest/pgbackrest.conf

[global]
repo1-path=/backup/pgbackrest
repo1-retention-full=4
repo1-retention-diff=7
compress-type=lz4
process-max=2
log-level-console=info
log-level-file=detail
archive-async=y
archive-push-queue-max=4GB

[global:archive-push]
compress-level=3

[aciertech]
pg1-path=/var/lib/postgresql/16/main
pg1-port=5432
pg1-socket-path=/var/run/postgresql
```

### 2.4 Workflow PITR complet

La restauration PITR (Point-In-Time Recovery) est la capacité la plus puissante de pgBackRest. Voici le scénario concret pour AcierTech :

Scénario : corruption de données à 14h37 un mercredi. La dernière DIFF backup date du matin. On souhaite restaurer au point juste avant la corruption.

```bash
# Étape 1 : Identifier le point de restauration
pgbackrest --stanza=aciertech info

# Étape 2 : Arrêter PostgreSQL
systemctl stop postgresql@16-main

# Étape 3 : Restaurer le backup + WAL jusqu'à 14:36:59
pgbackrest --stanza=aciertech \
  --type=time \
  --target="2024-01-17 14:36:59" \
  --target-action=promote \
  restore

# Étape 4 : Démarrer PostgreSQL (il applique les WAL automatiquement)
systemctl start postgresql@16-main

# Étape 5 : Vérifier l'état
psql -c "SELECT pg_last_xact_replay_timestamp();"
```

### 2.5 Estimation RPO/RTO

**RPO (Recovery Point Objective)** : La perte de données maximale acceptable est de 5 minutes. Le WAL archiving est configuré pour archiver au maximum toutes les 5 minutes via `archive_timeout = 300`. En pratique, avec la réplication synchrone, le RPO effectif est proche de zéro pour les transactions validées.

**RTO (Recovery Time Objective)** : La cible est de 30 secondes pour un failover automatique Patroni, et de 15 à 30 minutes pour une restauration PITR complète depuis backup (variable selon la taille des données et le nombre de WAL à rejouer).

### 2.6 Script de vérification automatique des sauvegardes

```bash
#!/bin/bash
# /opt/aciertech/scripts/verify_backup.sh
# Exécuté chaque nuit à 03:00 via cron

LOGFILE="/var/log/aciertech/backup_verify.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] Début vérification backup pgBackRest" >> $LOGFILE

# Vérification d'intégrité complète
pgbackrest --stanza=aciertech verify >> $LOGFILE 2>&1
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "[$DATE] ALERTE : Vérification backup ÉCHOUÉE (code $EXIT_CODE)" >> $LOGFILE
  # Envoi alerte vers Prometheus pushgateway
  echo 'pgbackrest_verify_status{stanza="aciertech"} 0' | \
    curl --data-binary @- http://localhost:9091/metrics/job/pgbackrest
else
  echo "[$DATE] Vérification backup OK" >> $LOGFILE
  echo 'pgbackrest_verify_status{stanza="aciertech"} 1' | \
    curl --data-binary @- http://localhost:9091/metrics/job/pgbackrest
fi

# Métadonnées backup vers table PostgreSQL
psql -U postgres -d aciertech_db -c "
INSERT INTO dba_schema.backup_history 
  (backup_date, backup_type, status, size_bytes, verify_status)
VALUES 
  (NOW(), 'verify', 'completed', 0, $EXIT_CODE = 0)
;"
```

---

## 3. Data Quality Industrielle

### 3.1 Pourquoi la qualité des données est critique pour l'IA

Le modèle de maintenance prédictive d'AcierTech est entraîné et alimenté par les mesures IoT. Un modèle de machine learning est fondamentalement dépendant de la distribution statistique de ses données d'entrée. Une valeur aberrante non détectée (par exemple, un capteur de température indiquant 9999°C suite à une déconnexion) peut déclencher une fausse alerte de surchauffe critique, mobiliser des équipes de maintenance inutilement, et, pire, faire manquer une vraie anomalie noyée dans le bruit. Les 12 % de données aberrantes identifiés dans la base initiale signifient qu'environ 1 mesure sur 8 envoyée au modèle est potentiellement invalide. Cette contamination mine la confiance dans les prédictions et peut conduire à des décisions opérationnelles incorrectes.

### 3.2 Architecture des schémas de données

```sql
-- Schéma de réception brute (toutes les données arrivent ici)
CREATE SCHEMA IF NOT EXISTS iot_raw;

-- Schéma des données validées (propres, prêtes pour l'IA)
CREATE SCHEMA IF NOT EXISTS iot_clean;

-- Schéma de quarantaine (données invalides, pour audit)
CREATE SCHEMA IF NOT EXISTS iot_quarantine;

-- Schéma d'administration DBA
CREATE SCHEMA IF NOT EXISTS dba_schema;
```

### 3.3 Table de réception et contraintes CHECK

```sql
-- Table de réception brute des mesures IoT
CREATE TABLE iot_raw.sensor_readings (
    id               BIGSERIAL PRIMARY KEY,
    sensor_id        INTEGER NOT NULL,
    sensor_type      VARCHAR(50) NOT NULL,
    value            NUMERIC(12, 4) NOT NULL,
    unit             VARCHAR(20) NOT NULL,
    recorded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    received_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    quality_score    SMALLINT DEFAULT NULL,
    validation_status VARCHAR(20) DEFAULT 'pending',

    -- Contraintes de plage physique absolue (valeurs impossibles)
    CONSTRAINT chk_temperature_absolute 
        CHECK (sensor_type != 'temperature' OR value BETWEEN -50 AND 2000),
    CONSTRAINT chk_pressure_absolute 
        CHECK (sensor_type != 'pressure' OR value BETWEEN 0 AND 500),
    CONSTRAINT chk_vibration_absolute 
        CHECK (sensor_type != 'vibration' OR value BETWEEN 0 AND 1000),
    CONSTRAINT chk_current_absolute 
        CHECK (sensor_type != 'current' OR value BETWEEN 0 AND 10000),
    CONSTRAINT chk_timestamp_not_future 
        CHECK (recorded_at <= NOW() + INTERVAL '5 minutes'),
    CONSTRAINT chk_timestamp_not_ancient 
        CHECK (recorded_at >= '2020-01-01')
);

-- Table des seuils opérationnels par capteur et par type
CREATE TABLE dba_schema.sensor_thresholds (
    sensor_id        INTEGER NOT NULL,
    sensor_type      VARCHAR(50) NOT NULL,
    warn_min         NUMERIC(12, 4),
    warn_max         NUMERIC(12, 4),
    critical_min     NUMERIC(12, 4),
    critical_max     NUMERIC(12, 4),
    stddev_factor    NUMERIC(4, 2) DEFAULT 3.0,
    PRIMARY KEY (sensor_id, sensor_type)
);

-- Table de quarantaine pour les données invalides
CREATE TABLE iot_quarantine.rejected_readings (
    id               BIGSERIAL PRIMARY KEY,
    original_id      BIGINT,
    sensor_id        INTEGER,
    sensor_type      VARCHAR(50),
    raw_value        NUMERIC(12, 4),
    rejection_reason VARCHAR(200),
    quality_score    SMALLINT,
    rejected_at      TIMESTAMPTZ DEFAULT NOW(),
    reviewed         BOOLEAN DEFAULT FALSE
);

-- Table des données propres validées (alimentant l'IA)
CREATE TABLE iot_clean.sensor_readings (
    id               BIGSERIAL PRIMARY KEY,
    original_id      BIGINT NOT NULL REFERENCES iot_raw.sensor_readings(id),
    sensor_id        INTEGER NOT NULL,
    sensor_type      VARCHAR(50) NOT NULL,
    value            NUMERIC(12, 4) NOT NULL,
    unit             VARCHAR(20) NOT NULL,
    recorded_at      TIMESTAMPTZ NOT NULL,
    quality_score    SMALLINT NOT NULL,
    validated_at     TIMESTAMPTZ DEFAULT NOW()
);
```

### 3.4 Trigger PL/pgSQL de validation et scoring

```sql
CREATE OR REPLACE FUNCTION iot_raw.validate_and_route_reading()
RETURNS TRIGGER AS $$
DECLARE
    v_threshold     dba_schema.sensor_thresholds%ROWTYPE;
    v_score         SMALLINT := 100;
    v_reason        TEXT := '';
    v_mean          NUMERIC;
    v_stddev        NUMERIC;
    v_zscore        NUMERIC;
BEGIN
    -- Récupération des seuils pour ce capteur
    SELECT * INTO v_threshold
    FROM dba_schema.sensor_thresholds
    WHERE sensor_id = NEW.sensor_id 
      AND sensor_type = NEW.sensor_type;

    -- ===== SCORING QUALITÉ =====

    -- 1. Vérification seuil critique bas
    IF v_threshold.critical_min IS NOT NULL 
       AND NEW.value < v_threshold.critical_min THEN
        v_score := v_score - 60;
        v_reason := v_reason || 'CRITICAL_MIN_BREACH;';
    END IF;

    -- 2. Vérification seuil critique haut
    IF v_threshold.critical_max IS NOT NULL 
       AND NEW.value > v_threshold.critical_max THEN
        v_score := v_score - 60;
        v_reason := v_reason || 'CRITICAL_MAX_BREACH;';
    END IF;

    -- 3. Détection statistique via Z-score (fenêtre glissante 1h)
    SELECT AVG(value), STDDEV(value)
    INTO v_mean, v_stddev
    FROM iot_raw.sensor_readings
    WHERE sensor_id = NEW.sensor_id
      AND sensor_type = NEW.sensor_type
      AND recorded_at >= NOW() - INTERVAL '1 hour'
      AND validation_status = 'valid';

    IF v_mean IS NOT NULL AND v_stddev IS NOT NULL AND v_stddev > 0 THEN
        v_zscore := ABS((NEW.value - v_mean) / v_stddev);
        IF v_zscore > COALESCE(v_threshold.stddev_factor, 3.0) THEN
            v_score := v_score - 30;
            v_reason := v_reason || 
                format('ZSCORE_OUTLIER(z=%.2f);', v_zscore);
        END IF;
    END IF;

    -- 4. Vérification seuil avertissement
    IF v_threshold.warn_min IS NOT NULL 
       AND NEW.value < v_threshold.warn_min THEN
        v_score := LEAST(v_score, v_score - 10);
        v_reason := v_reason || 'WARN_MIN;';
    END IF;

    IF v_threshold.warn_max IS NOT NULL 
       AND NEW.value > v_threshold.warn_max THEN
        v_score := LEAST(v_score, v_score - 10);
        v_reason := v_reason || 'WARN_MAX;';
    END IF;

    -- Clamp du score entre 0 et 100
    v_score := GREATEST(0, LEAST(100, v_score));

    -- Mise à jour du score et statut sur la ligne en cours
    NEW.quality_score := v_score;

    -- ===== ROUTAGE =====

    IF v_score >= 70 THEN
        -- Données propres → iot_clean
        NEW.validation_status := 'valid';
        INSERT INTO iot_clean.sensor_readings 
            (original_id, sensor_id, sensor_type, value, unit, 
             recorded_at, quality_score)
        VALUES 
            (NEW.id, NEW.sensor_id, NEW.sensor_type, NEW.value, 
             NEW.unit, NEW.recorded_at, v_score);

    ELSE
        -- Données invalides → quarantaine
        NEW.validation_status := 'quarantined';
        INSERT INTO iot_quarantine.rejected_readings 
            (original_id, sensor_id, sensor_type, raw_value, 
             rejection_reason, quality_score)
        VALUES 
            (NEW.id, NEW.sensor_id, NEW.sensor_type, NEW.value, 
             v_reason, v_score);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_sensor_reading
    BEFORE INSERT ON iot_raw.sensor_readings
    FOR EACH ROW
    EXECUTE FUNCTION iot_raw.validate_and_route_reading();
```

### 3.5 Vue de tableau de bord qualité des données

```sql
-- Vue pour le monitoring de la qualité en temps réel
CREATE OR REPLACE VIEW dba_schema.v_data_quality_dashboard AS
WITH stats_last_hour AS (
    SELECT
        sensor_type,
        COUNT(*) AS total_readings,
        COUNT(*) FILTER (WHERE validation_status = 'valid') AS valid_count,
        COUNT(*) FILTER (WHERE validation_status = 'quarantined') AS quarantine_count,
        ROUND(AVG(quality_score), 1) AS avg_quality_score,
        ROUND(
            100.0 * COUNT(*) FILTER (WHERE validation_status = 'valid') 
            / NULLIF(COUNT(*), 0), 2
        ) AS valid_pct
    FROM iot_raw.sensor_readings
    WHERE received_at >= NOW() - INTERVAL '1 hour'
    GROUP BY sensor_type
)
SELECT
    sensor_type,
    total_readings,
    valid_count,
    quarantine_count,
    avg_quality_score,
    valid_pct,
    CASE
        WHEN valid_pct >= 95 THEN 'EXCELLENT'
        WHEN valid_pct >= 85 THEN 'BON'
        WHEN valid_pct >= 70 THEN 'DÉGRADÉ'
        ELSE 'CRITIQUE'
    END AS quality_status
FROM stats_last_hour
ORDER BY valid_pct ASC;
```

---

## 4. Monitoring & Observabilité

### 4.1 Stack de monitoring retenue

La stack de monitoring est composée de trois éléments complémentaires. Prometheus collecte les métriques toutes les 15 secondes depuis postgres_exporter, node_exporter, HAProxy exporter et le pushgateway pour les métriques applicatives personnalisées. Grafana interroge Prometheus pour construire des dashboards temps réel et évaluer les alertes. postgres_exporter expose plus de 200 métriques PostgreSQL natives sous forme de métriques Prometheus.

### 4.2 Configuration postgres_exporter

```yaml
# /etc/postgres_exporter/queries.yaml
# Requêtes personnalisées pour AcierTech

pg_replication:
  query: |
    SELECT
      client_addr,
      state,
      sent_lsn - write_lsn AS write_lag_bytes,
      sent_lsn - flush_lsn AS flush_lag_bytes,
      sent_lsn - replay_lsn AS replay_lag_bytes,
      EXTRACT(EPOCH FROM write_lag) AS write_lag_seconds,
      EXTRACT(EPOCH FROM flush_lag) AS flush_lag_seconds,
      EXTRACT(EPOCH FROM replay_lag) AS replay_lag_seconds
    FROM pg_stat_replication;
  metrics:
    - client_addr:
        usage: "LABEL"
    - replay_lag_bytes:
        usage: "GAUGE"
        description: "Réplication lag en octets"
    - replay_lag_seconds:
        usage: "GAUGE"
        description: "Réplication lag en secondes"

pg_data_quality:
  query: |
    SELECT
      sensor_type,
      COUNT(*) FILTER (WHERE validation_status = 'valid') AS valid_count,
      COUNT(*) FILTER (WHERE validation_status = 'quarantined') AS quarantine_count,
      ROUND(AVG(quality_score), 1) AS avg_score
    FROM iot_raw.sensor_readings
    WHERE received_at >= NOW() - INTERVAL '5 minutes'
    GROUP BY sensor_type;
  metrics:
    - sensor_type:
        usage: "LABEL"
    - valid_count:
        usage: "GAUGE"
    - quarantine_count:
        usage: "GAUGE"
    - avg_score:
        usage: "GAUGE"

pg_long_running_queries:
  query: |
    SELECT
      COUNT(*) AS count,
      MAX(EXTRACT(EPOCH FROM (NOW() - query_start))) AS max_duration_seconds
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query_start < NOW() - INTERVAL '30 seconds'
      AND query NOT LIKE '%pg_stat%';
  metrics:
    - count:
        usage: "GAUGE"
    - max_duration_seconds:
        usage: "GAUGE"
```

### 4.3 Dashboards Grafana recommandés

Quatre dashboards couvrent l'ensemble des besoins de supervision DBA pour ce projet :

**Dashboard 1 — État du Cluster HA** : Ce dashboard présente en première ligne l'état Patroni de chaque nœud (PRIMARY / REPLICA / OFFLINE) sous forme de panneaux colorés (vert/rouge), le lag de réplication en temps réel avec seuil d'alerte à 30 secondes, l'état du quorum etcd, et le routage HAProxy actif.

**Dashboard 2 — Performance PostgreSQL** : Ce dashboard affiche le cache hit ratio (cible > 95 %), le nombre de connexions actives vs maximum configuré, les transactions par seconde (TPS), les requêtes les plus lentes (top 10 par durée moyenne), les locks en attente et le taux de deadlocks.

**Dashboard 3 — Data Quality IoT** : Ce dashboard montre le pourcentage de données valides par type de capteur sur les 24 dernières heures, le volume de données en quarantaine avec tendance, le score qualité moyen par capteur, et un histogramme de distribution des scores de qualité.

**Dashboard 4 — PRA et Sauvegardes** : Ce dashboard présente l'âge du dernier backup FULL réussi, l'âge du dernier WAL archivé, le statut de la dernière vérification d'intégrité (via pushgateway), l'espace disque utilisé par les backups et un historique des événements de sauvegarde.

### 4.4 Alertes prioritaires Prometheus

```yaml
# /etc/prometheus/rules/aciertech_alerts.yml
groups:
  - name: aciertech_postgresql
    rules:

    - alert: ReplicationLagCritical
      expr: pg_replication_replay_lag_seconds > 60
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Lag de réplication critique ({{ $value }}s)"

    - alert: PrimaryNodeDown
      expr: patroni_master_mode == 0
      for: 30s
      labels:
        severity: critical
      annotations:
        summary: "Aucun nœud primaire détecté dans le cluster"

    - alert: DataQualityDegraded
      expr: |
        (pg_data_quality_valid_count / 
         (pg_data_quality_valid_count + pg_data_quality_quarantine_count)) < 0.85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Qualité des données dégradée sur {{ $labels.sensor_type }}"

    - alert: BackupTooOld
      expr: time() - pgbackrest_last_backup_timestamp > 86400 * 2
      for: 1h
      labels:
        severity: critical
      annotations:
        summary: "Aucun backup réussi depuis plus de 48h"

    - alert: CacheHitRatioLow
      expr: pg_stat_bgwriter_buffers_hit_ratio < 0.90
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Cache hit ratio insuffisant ({{ $value | humanizePercentage }})"

    - alert: TooManyConnections
      expr: |
        pg_stat_activity_count / pg_settings_max_connections > 0.85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Saturation des connexions PostgreSQL ({{ $value | humanizePercentage }})"
```

---

## 5. Application Web DBA Console

### 5.1 Stack technique recommandée

Pour un DBA sans expertise frontend souhaitant une solution démontrable rapidement, la stack suivante est optimale :

**Backend** : FastAPI (Python) avec SQLAlchemy pour les requêtes PostgreSQL et httpx pour appeler l'API Patroni et Prometheus. FastAPI génère automatiquement une documentation interactive et est trivial à déployer.

**Frontend** : HTML/CSS/JavaScript vanille avec le framework Tailwind CSS via CDN. Pas de build step, pas de node_modules, pas de webpack. Une seule page HTML par dashboard.

**Intégration Grafana** : Embedding par iframe avec Grafana configuré en mode `allow_embedding = true`. C'est la méthode la plus rapide et la plus maintenable pour intégrer Grafana dans une application DBA interne.

### 5.2 Architecture de l'application

```
/opt/aciertech/webapp/
├── main.py                    # FastAPI app principale
├── routers/
│   ├── cluster.py             # État Patroni, HAProxy
│   ├── quality.py             # Métriques Data Quality
│   ├── backups.py             # Historique pgBackRest
│   └── metrics.py             # Proxy Prometheus API
├── templates/
│   ├── base.html              # Layout principal
│   ├── dashboard.html         # Vue d'ensemble
│   ├── cluster.html           # État du cluster HA
│   ├── quality.html           # Data Quality
│   └── backups.html           # PRA et backups
├── static/
│   └── aciertech.css          # Styles personnalisés
└── requirements.txt
```

### 5.3 Intégration Grafana par iframe (approche recommandée)

```python
# Configuration dans main.py
GRAFANA_BASE_URL = "http://localhost:3000"

# URLs des dashboards Grafana à embarquer
GRAFANA_DASHBOARDS = {
    "cluster_ha": f"{GRAFANA_BASE_URL}/d/cluster-ha/état-cluster-ha?orgId=1&kiosk",
    "performance": f"{GRAFANA_BASE_URL}/d/pg-perf/performance-postgresql?orgId=1&kiosk",
    "data_quality": f"{GRAFANA_BASE_URL}/d/data-quality/qualité-données-iot?orgId=1&kiosk",
    "backups": f"{GRAFANA_BASE_URL}/d/backups/pra-sauvegardes?orgId=1&kiosk",
}
```

```ini
# /etc/grafana/grafana.ini - Configuration pour l'embedding
[security]
allow_embedding = true
cookie_samesite = disabled

[auth.anonymous]
enabled = true
org_name = AcierTech
org_role = Viewer
```

### 5.4 Endpoint FastAPI pour l'état du cluster

```python
# routers/cluster.py
import httpx
from fastapi import APIRouter

router = APIRouter()

PATRONI_URLS = {
    "pg-node-1": "http://localhost:8008",
    "pg-node-2": "http://localhost:8009",
    "pg-node-3": "http://localhost:8010",
}

@router.get("/api/cluster/status")
async def get_cluster_status():
    nodes = []
    async with httpx.AsyncClient(timeout=2.0) as client:
        for node_name, url in PATRONI_URLS.items():
            try:
                resp = await client.get(f"{url}/patroni")
                data = resp.json()
                nodes.append({
                    "name": node_name,
                    "role": data.get("role", "unknown"),
                    "state": data.get("state", "unknown"),
                    "timeline": data.get("timeline", 0),
                    "lag": data.get("replication", {}).get("lag", 0),
                    "healthy": resp.status_code == 200,
                })
            except Exception:
                nodes.append({
                    "name": node_name,
                    "healthy": False,
                    "role": "unreachable",
                })
    return {"nodes": nodes, "timestamp": "now"}
```

---

## 6. Pipeline Data-to-Model

### 6.1 Philosophie de ce volet

Ce volet ne développe pas de modèle IA. Il démontre que l'administration PostgreSQL est le facteur déterminant de la fiabilité du système de maintenance prédictive. La qualité de la prédiction est directement corrélée à la qualité de l'administration de la base de données.

### 6.2 Comment les données propres sont exposées au système IA

```sql
-- Vue matérialisée actualisée toutes les 5 minutes
-- Exposée au système IA via connexion dédiée en lecture seule
CREATE MATERIALIZED VIEW iot_clean.v_ai_feature_set AS
SELECT
    sensor_id,
    sensor_type,
    DATE_TRUNC('minute', recorded_at) AS time_bucket,
    AVG(value)                         AS avg_value,
    MIN(value)                         AS min_value,
    MAX(value)                         AS max_value,
    STDDEV(value)                      AS stddev_value,
    COUNT(*)                           AS sample_count,
    AVG(quality_score)                 AS avg_quality,
    MIN(recorded_at)                   AS window_start,
    MAX(recorded_at)                   AS window_end
FROM iot_clean.sensor_readings
WHERE recorded_at >= NOW() - INTERVAL '24 hours'
GROUP BY sensor_id, sensor_type, DATE_TRUNC('minute', recorded_at)
WITH DATA;

-- Refresh automatique via pg_cron ou worker Python
CREATE INDEX ON iot_clean.v_ai_feature_set (sensor_id, time_bucket DESC);

-- Rôle lecture seule dédié au système IA
CREATE ROLE ai_readonly WITH LOGIN PASSWORD 'ai_secure_pwd';
GRANT CONNECT ON DATABASE aciertech_db TO ai_readonly;
GRANT USAGE ON SCHEMA iot_clean TO ai_readonly;
GRANT SELECT ON iot_clean.v_ai_feature_set TO ai_readonly;
```

### 6.3 Démonstration de l'impact DBA sur l'IA

Le tableau suivant illustre comment les défaillances DBA se traduisent en problèmes opérationnels pour l'IA de maintenance prédictive :

| Défaillance DBA | Impact sur l'IA | Conséquence métier |
|---|---|---|
| Panne du primaire sans failover | Alimentation stoppée | Arrêt de la prédiction, maintenance aveugle |
| Données aberrantes non filtrées | Faux positifs | Interventions inutiles, coûts opérationnels |
| Lag de réplication > 5min | Features décalées | Prédictions sur données périmées |
| Backup absent | Perte définitive sur incident | Réentraînement du modèle impossible |
| Connexions saturées | Timeout d'ingestion | Lacunes temporelles dans les séries |
| Cache hit ratio faible | Requêtes features lentes | Latence d'inférence inacceptable |

---

## 7. Plan d'Implémentation — Une Semaine

### Roadmap jour par jour

**Jour 1 — Socle Infrastructure**
Installer PostgreSQL 16, Docker, configurer les 3 conteneurs PostgreSQL, démarrer le cluster etcd à 3 nœuds. Objectif : 3 instances PostgreSQL qui démarrent et se connectent entre elles.

**Jour 2 — Haute Disponibilité**
Installer et configurer Patroni sur chaque nœud, vérifier l'élection du leader dans etcd, configurer HAProxy avec les health checks sur l'API Patroni, installer pgBouncer. Objectif : tester un `patronictl switchover` manuel réussi.

**Jour 3 — Data Quality**
Créer les schémas `iot_raw`, `iot_clean`, `iot_quarantine`, déployer le trigger de validation, configurer les seuils pour les 47 types de capteurs, écrire un script Python de simulation d'ingestion IoT avec 12 % de données aberrantes. Objectif : voir les données se router automatiquement entre clean et quarantaine.

**Jour 4 — PRA et Sauvegardes**
Installer pgBackRest, configurer le stanza `aciertech`, exécuter le premier backup FULL, vérifier le WAL archiving, tester une restauration PITR sur une instance temporaire. Objectif : restauration PITR réussie et documentée.

**Jour 5 — Monitoring**
Déployer Prometheus et Grafana via Docker Compose, installer postgres_exporter et node_exporter, créer les 4 dashboards Grafana, configurer les alertes Prometheus. Objectif : tous les dashboards affichent des données réelles.

**Jour 6 — Application Web**
Développer l'application FastAPI, intégrer les endpoints de statut cluster, qualité données et backups, embarquer les dashboards Grafana par iframe. Objectif : console DBA fonctionnelle et accessible sur http://localhost:8080.

**Jour 7 — Tests et Répétition de Soutenance**
Exécuter le scénario de failover en conditions de démonstration, restaurer un backup PITR en live, vérifier tous les dashboards, préparer les slides de soutenance, répéter le storytelling 2 fois.

### Docker Compose pour environnement local

```yaml
# docker-compose.yml — Infrastructure complète AcierTech
version: '3.8'

services:
  etcd1:
    image: quay.io/coreos/etcd:v3.5.9
    container_name: etcd1
    environment:
      ETCD_NAME: etcd1
      ETCD_DATA_DIR: /etcd-data
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd1:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd1:2380
      ETCD_INITIAL_CLUSTER: etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380
      ETCD_INITIAL_CLUSTER_STATE: new
    networks: [aciertech]

  etcd2:
    image: quay.io/coreos/etcd:v3.5.9
    container_name: etcd2
    environment:
      ETCD_NAME: etcd2
      ETCD_DATA_DIR: /etcd-data
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd2:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd2:2380
      ETCD_INITIAL_CLUSTER: etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380
      ETCD_INITIAL_CLUSTER_STATE: new
    networks: [aciertech]

  etcd3:
    image: quay.io/coreos/etcd:v3.5.9
    container_name: etcd3
    environment:
      ETCD_NAME: etcd3
      ETCD_DATA_DIR: /etcd-data
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd3:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd3:2380
      ETCD_INITIAL_CLUSTER: etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380
      ETCD_INITIAL_CLUSTER_STATE: new
    networks: [aciertech]

  prometheus:
    image: prom/prometheus:v2.48.0
    container_name: prometheus
    ports: ["9090:9090"]
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./monitoring/rules:/etc/prometheus/rules
    networks: [aciertech]

  grafana:
    image: grafana/grafana:10.2.0
    container_name: grafana
    ports: ["3000:3000"]
    environment:
      GF_SECURITY_ALLOW_EMBEDDING: "true"
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana/dashboards:/etc/grafana/provisioning/dashboards
    networks: [aciertech]

  haproxy:
    image: haproxy:2.8
    container_name: haproxy
    ports:
      - "5000:5000"    # Lecture-Écriture (primaire)
      - "5001:5001"    # Lecture seule (réplicas)
      - "7000:7000"    # Stats HAProxy
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg
    networks: [aciertech]

volumes:
  grafana_data:

networks:
  aciertech:
    driver: bridge
```

### Estimation d'utilisation des ressources

```
Composant          RAM estimée    CPU (idle)
─────────────────────────────────────────────
pg-node-1 (natif)  512 MB         faible
pg-node-2 (natif)  512 MB         faible
pg-node-3 (natif)  512 MB         faible
etcd (x3 Docker)   300 MB total   minimal
HAProxy (Docker)    50 MB          minimal
pgBouncer (natif)   30 MB          minimal
Prometheus          200 MB         faible
Grafana             250 MB         faible
App Web FastAPI      80 MB          minimal
─────────────────────────────────────────────
TOTAL              ~2.5 GB / 8 GB  ✅ Compatible
```

PostgreSQL est installé nativement sur l'OS (pas en Docker) pour des raisons de performance et de simplicité de configuration Patroni. Les services d'infrastructure (etcd, HAProxy, Prometheus, Grafana) sont en Docker.

---

## 8. Erreurs à Éviter

**Ne pas confondre réplication et sauvegarde.** La réplication streaming protège contre la panne d'un nœud mais pas contre une suppression accidentelle ou une corruption logique de données. La sauvegarde pgBackRest est indispensable même avec Patroni.

**Ne pas configurer `synchronous_commit = off` sans comprendre les implications.** Ce paramètre améliore les performances mais introduit un risque de perte de données lors d'un failover. Pour ce projet, maintenir `synchronous_commit = on` avec un réplica synchrone.

**Ne pas oublier de tester la restauration PITR.** Une sauvegarde non testée est une sauvegarde dont on ne connaît pas le statut réel. Le test de restauration hebdomadaire est non négociable.

**Ne pas exposer HAProxy sans authentification sur les stats.** Le port 7000 (stats HAProxy) doit être protégé en production. Pour la démo locale, c'est acceptable.

**Ne pas nommer les slots de réplication sans les monitorer.** Un slot de réplication inactif accumule du WAL indéfiniment et peut saturer le disque. Monitorer `pg_replication_slots` est impératif.

**Ne pas sous-estimer le temps de configuration Patroni.** La première configuration Patroni prend plus de temps qu'attendu. Prévoire une demi-journée complète et suivre un guide officiel à la lettre.

---

## 9. Livrables du Projet

Les livrables concrets à préparer pour la soutenance sont les suivants :

Le premier livrable est le dépôt de code complet sur Git, organisé par modules (infra, sql, monitoring, webapp, scripts), avec un README d'installation et un script d'initialisation automatisé.

Le deuxième livrable est la démonstration de failover en direct : tuer le conteneur pg-node-1, montrer le basculement automatique sous 30 secondes dans Patroni, vérifier que l'application IoT continue d'ingérer des données sans intervention.

Le troisième livrable est la démonstration PITR : injecter une corruption délibérée dans la base à un instant T, exécuter la restauration pgBackRest vers T-1 minute, montrer les données restaurées dans psql.

Le quatrième livrable est le tableau de bord Data Quality : montrer en direct le script d'ingestion IoT avec données aberrantes, observer le routage automatique clean/quarantaine dans les dashboards Grafana et dans la console web.

Le cinquième livrable est le document d'architecture technique (ce présent document), comprenant les schémas, les choix justifiés, le RPO/RTO chiffré et la roadmap d'implémentation.

---

## 10. Storytelling de Soutenance

### Arc narratif recommandé (20 minutes)

**Acte 1 — Le Problème (3 minutes)** : Présenter AcierTech comme une usine avec 47 capteurs, un système IA en production, mais une infrastructure de données qui tient par miracle. Un seul serveur, aucun backup, 12 % de données corrompues. La question n'est pas "si" ça va tomber, c'est "quand". Montrer le schéma "avant" : un serveur seul avec une flèche directe vers l'IA.

**Acte 2 — La Solution Architecture (5 minutes)** : Présenter le schéma d'architecture cible. Expliquer le rôle de chaque composant en une phrase. Insister sur le fait que chaque composant répond à un risque métier précis. Patroni répond au SPOF. pgBackRest répond à la perte de données. Le trigger de validation répond aux 12 % de données aberrantes. postgres_exporter répond à l'opacité opérationnelle.

**Acte 3 — La Démonstration (10 minutes)** : Montrer en direct le cluster Patroni en état nominal dans la console web. Exécuter le failover : tuer le primaire, montrer la bascule automatique, l'application continue de fonctionner. Montrer le dashboard Data Quality avec des données en direct. Déclencher une restauration PITR sur une instance de test. Montrer les alertes Prometheus dans Grafana.

**Acte 4 — L'Impact Métier (2 minutes)** : Conclure avec les chiffres. RTO passé de "inconnu et probablement jours" à moins de 30 secondes. RPO passé de "toutes les données depuis le dernier dump manuel" à moins de 5 minutes. Taux de données valides passé de 88 % à plus de 95 %. L'IA de maintenance prédictive est maintenant alimentée par une infrastructure fiable, monitorée et récupérable.

### Le message central à retenir pour le jury

"Mon rôle de DBA n'est pas de faire marcher PostgreSQL. Mon rôle est de faire en sorte que PostgreSQL ne soit jamais un facteur limitant pour le business. Ce projet démontre que l'administration de bases de données est une discipline d'ingénierie à part entière, qui commence par l'architecture et se termine par la démonstration que le système résiste à ce qu'on ne voulait pas."

---

## 11. Comment Rester Crédible comme DBA Senior

Maîtriser le vocabulaire exact : parler de LSN (Log Sequence Number) et non de "numéro de log", de WAL (Write-Ahead Log) et non de "journal", de PITR et non de "restauration à un moment précis", de slot de réplication et non de "connexion de réplication".

Connaître les paramètres PostgreSQL critiques par cœur : `max_connections`, `shared_buffers`, `wal_level`, `archive_mode`, `archive_command`, `synchronous_standby_names`, `hot_standby`, `wal_keep_size`.

Être capable d'expliquer pourquoi Patroni utilise etcd plutôt qu'un fichier partagé : le consensus distribué via Raft empêche le split-brain, situation où deux nœuds se croient simultanément primaires et acceptent des écritures divergentes.

Savoir expliquer la différence entre réplication physique (streaming WAL, bit à bit, utilisée ici) et réplication logique (réplication de changements SQL, utilisée pour des cas spéciaux comme la migration vers une nouvelle version majeure de PostgreSQL).

Connaître les commandes de diagnostic de base sur le bout des doigts :

```sql
-- État du cluster de réplication
SELECT * FROM pg_stat_replication;

-- Lag de réplication en secondes
SELECT NOW() - pg_last_xact_replay_timestamp() AS replication_lag;

-- Sessions actives et requêtes longues
SELECT pid, state, query_start, query 
FROM pg_stat_activity 
WHERE state = 'active' 
ORDER BY query_start ASC;

-- Locks en attente
SELECT * FROM pg_locks WHERE NOT granted;

-- Cache hit ratio
SELECT 
  SUM(heap_blks_hit) / NULLIF(SUM(heap_blks_hit + heap_blks_read), 0) AS cache_hit_ratio
FROM pg_statio_user_tables;
```

Ce projet, exécuté proprement en une semaine, démontre une maîtrise opérationnelle concrète de PostgreSQL en environnement de production. C'est exactement ce qu'un jury de formation DBA cherche à valider.

---

*Document généré pour le projet INF1620 — Formation DBA PostgreSQL Haute Disponibilité*
*AcierTech Industries S.A. — Lomé, Togo*
*Révision 1.0*
