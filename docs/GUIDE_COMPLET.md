# Guide complet de la plateforme AcierTech DBA Console

```
AcierTech Industries S.A. — INF1620 Formation DBA PostgreSQL 16 HA
Plateforme de supervision et d'administration de bases de données
47 capteurs IoT · 3 nœuds PostgreSQL · Réplication streaming · PRA intégré
```

---

## Table des matières

1. [Présentation du projet](#1-présentation-du-projet)
2. [Architecture de la plateforme](#2-architecture-de-la-plateforme)
3. [Le pipeline de qualité IoT](#3-le-pipeline-de-qualité-iot)
4. [Fonctionnalités de l'application web](#4-fonctionnalités-de-lapplication-web)
5. [Volet administration de bases de données](#5-volet-administration-de-bases-de-données)
6. [Cas d'utilisation métier](#6-cas-dutilisation-métier)
7. [Guide de personnalisation SQL](#7-guide-de-personnalisation-sql)

---

## 1. Présentation du projet

### 1.1 Contexte

AcierTech Industries est une aciérie basée à Lomé, équipée de **47 capteurs IoT** répartis en 7 types (température, pression, vibration, courant, débit, vitesse, épaisseur). Ces capteurs émettent des mesures en continu. La plateforme doit :

1. **Ingérer** les 47 flux de données en temps réel
2. **Valider** chaque mesure (seuils physiques + statistiques)
3. **Router** les données propres (≥ 70/100) vers le système IA et les aberrantes vers la quarantaine
4. **Surveiller** l'ensemble avec des alertes Prometheus et des dashboards Grafana
5. **Garantir** la haute disponibilité (PRA) avec Patroni, etcd, HAProxy

### 1.2 Stack technique

| Composant | Rôle | Version |
|---|---|---|
| **PostgreSQL** | Base de données principale | 16 |
| **Patroni** | Haute disponibilité (3 nœuds) | 3 |
| **etcd** | Stockage de configuration distribué | 3 membres |
| **HAProxy** | Équilibrage de charge (RW:5000 / RO:5001) | 2.x |
| **pgBouncer** | Pool de connexions transactionnel | — |
| **pgBackRest** | Sauvegarde et PITR | — |
| **Prometheus** | Métriques et alertes | — |
| **Grafana** | Dashboards (4 tableaux de bord) | 11.3.0 |
| **FastAPI** | Application web (console DBA) | Python 3.12 |
| **pg_cron** | Planification de tâches (8 jobs) | — |

### 1.3 Architecture des fichiers

```
aciertech-dba/
├── 01-infra/           # Patroni, etcd, HAProxy, pgBouncer
├── 02-sql/             # Migrations, fonctions, vues, triggers, maintenance
├── 03-backup/          # pgBackRest conf, scripts (full, diff, verify, PITR)
├── 04-monitoring/      # Prometheus, Grafana, exporters
├── 05-webapp/          # Application web FastAPI + templates + Docker Compose
├── 06-pipeline/        # Simulateur IoT et exposition IA (à venir)
├── 07-scripts/         # Scripts DBA (à venir)
└── docs/               # Documentation
```

---

## 2. Architecture de la plateforme

### 2.1 Schéma de l'infrastructure

```
                    ┌──────────────┐
                    │   Internet   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   HAProxy    │──────── Port 5000 (RW → Primary)
                    │  (3 nœuds)   │──────── Port 5001 (RO → Standbys)
                    └──────┬───────┘──────── Port 7000 (Stats)
                           │
              ┌────────────┼────────────┐
              │            │            │
       ┌──────▼──────┐ ┌──▼────────┐ ┌──▼────────┐
       │  pg-node-1   │ │ pg-node-2  │ │ pg-node-3  │
       │  PostgreSQL  │ │ PostgreSQL │ │ PostgreSQL │
       │  Patroni     │ │ Patroni    │ │ Patroni    │
       │  pgBouncer   │ │ pgBouncer  │ │ pgBouncer  │
       └──────┬───────┘ └─────┬──────┘ └─────┬──────┘
              │               │               │
              └───────┬───────┴───────┬───────┘
                      │               │
                 ┌────▼────┐    ┌────▼────┐
                 │  etcd   │    │  etcd   │
                 │ nœud 1  │    │ nœud 2  │── etcd nœud 3
                 └─────────┘    └─────────┘
```

### 2.2 Rôles PostgreSQL

| Rôle | Droits | Usage |
|---|---|---|
| **postgres** | Superuser | Administration DBA, migrations, pg_cron |
| **aciertech_app** | INSERT iot_raw + SELECT sensor_thresholds | Application IoT (écriture données brutes) |
| **aciertech_ro** | SELECT iot_clean + dba_schema.v_data_quality_dashboard | Webapp (lecture dashboard) |
| **monitoring_ro** | pg_monitor + SELECT dba_schema.v_replication_status | Grafana et scripts supervision |
| **replicator** | Réplication streaming | Patroni (réplication entre nœuds) |

### 2.3 Flux réseau

| Port | Service | Usage |
|---|---|---|
| 5432 | PostgreSQL | Connexion directe (réservé postgres + pg_cron) |
| 5000 | HAProxy RW | Connexions écriture → PRIMARY |
| 5001 | HAProxy RO | Connexions lecture → réplicas |
| 6432 | pgBouncer | Pool de connexions (transaction) |
| 8008 | Patroni API | REST API (topologie, switchover, failover) |
| 2379 | etcd | API cluster etcd |
| 7000 | HAProxy Stats | Page stats CSV |
| 9090 | Prometheus | API métriques |
| 3000 | Grafana | Dashboards (admin/admin) |
| 9091 | Pushgateway | Métriques push (scripts backup) |
| 8080 | Webapp | Console DBA AcierTech |

---

## 3. Le pipeline de qualité IoT

C'est le cœur du projet : le pipeline de validation des 47 capteurs.

### 3.1 Architecture des schémas

```
                    iot_raw.sensor_readings (INSERT)
                              │
                              ▼
              ┌─── trg_validate_sensor (BEFORE INSERT) ───┐
              │                │                            │
              │        fn_compute_quality_score()            │
              │                │                            │
              │         ┌──────┴──────┐                     │
              │         │ score ≥ 70  │ score < 70          │
              │         ▼             ▼                      │
              │    iot_clean    iot_quarantine               │
              │    sensor_readings  rejected_readings        │
              │                      + anomaly_log           │
              ▼                                              ▼
    iot_raw.validation_status = 'valid'   validation_status = 'quarantined'
```

### 3.2 Schéma V001 : Les 4 schémas

```sql
-- Schéma de réception brute — toutes les données IoT arrivent ici
CREATE SCHEMA iot_raw;

-- Schéma des données validées — alimentant le système IA
CREATE SCHEMA iot_clean;

-- Schéma de quarantaine — données rejetées pour audit (score < 70/100)
CREATE SCHEMA iot_quarantine;

-- Schéma d'administration DBA
CREATE SCHEMA dba_schema;
```

**Pourquoi 4 schémas ?**

Cette séparation permet une isolation stricte des données :

- `iot_raw` : point d'entrée unique, réception brute sans perte (même les données invalides sont conservées)
- `iot_clean` : données validées garanties ≥ 70/100, seul schéma exposé au système IA
- `iot_quarantine` : données rejetées visibles pour audit DBA, avec logs d'anomalies détaillés
- `dba_schema` : administration pure (seuils, backups, métriques)

### 3.3 V002 : Table des mesures brutes

La table `iot_raw.sensor_readings` est la table d'entrée centrale :

```sql
CREATE TABLE iot_raw.sensor_readings (
    id                BIGSERIAL     PRIMARY KEY,
    sensor_id         SMALLINT      NOT NULL,
    sensor_type       VARCHAR(20)   NOT NULL,
    value             NUMERIC(12,4) NOT NULL,
    unit              VARCHAR(10)   NOT NULL,
    recorded_at       TIMESTAMPTZ   NOT NULL,
    received_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    quality_score     SMALLINT      DEFAULT NULL,
    validation_status VARCHAR(15)   NOT NULL DEFAULT 'pending',
    rejection_reason  TEXT          DEFAULT NULL,

    -- Limites physiques absolues (CHECK)
    CONSTRAINT chk_raw_temperature_absolute
        CHECK (sensor_type <> 'temperature' OR value BETWEEN -50 AND 2500),
    CONSTRAINT chk_raw_pressure_absolute
        CHECK (sensor_type <> 'pressure' OR value BETWEEN 0 AND 700),
    -- ... etc. pour chaque type de capteur
);
```

**Particularités :**

1. **Limites physiques absolues** : des CHECK contraignent les valeurs à des plages physiquement possibles (ex : température entre -50°C et 2500°C). Un capteur qui retourne 9999°C est défaillant, la mesure est rejetée avant même le trigger.

2. **Pas de FK vers sensor_thresholds** : volontairement pas de clé étrangère pour éviter les verrous partagés sur une table à fort taux d'écriture avec `synchronous_commit=on`.

3. **received_at ≠ recorded_at** : la différence permet de détecter les décalages d'horloge des capteurs IoT (problème fréquent en milieu industriel).

### 3.4 V003 : Table des données clean + vue IA

```sql
-- Seules les données avec score ≥ 70 arrivent ici
CREATE TABLE iot_clean.sensor_readings (
    original_id   BIGINT        NOT NULL,  -- référence iot_raw
    sensor_id     SMALLINT      NOT NULL,
    value         NUMERIC(12,4) NOT NULL,
    quality_score SMALLINT      NOT NULL,
    CONSTRAINT chk_clean_quality_minimum
        CHECK (quality_score >= 70)
);
```

**La vue matérialisée IA :**

```sql
CREATE MATERIALIZED VIEW iot_clean.v_ai_feature_set AS
SELECT
    sensor_id,
    sensor_type,
    DATE_TRUNC('minute', recorded_at)  AS time_bucket,
    AVG(value)   AS avg_value,
    MIN(value)   AS min_value,
    MAX(value)   AS max_value,
    STDDEV(value) AS stddev_value,
    COUNT(*)     AS sample_count,
    AVG(quality_score)::SMALLINT AS avg_quality_score
FROM iot_clean.sensor_readings
WHERE recorded_at >= NOW() - INTERVAL '24 hours'
GROUP BY sensor_id, sensor_type, DATE_TRUNC('minute', recorded_at)
WITH NO DATA;  -- Créée vide, index créés en V006, puis REFRESH par pg_cron
```

**Pourquoi une vue matérialisée ?**
- Agrège 24h de données par minute pour 47 capteurs → ~67 000 lignes
- INDEX UNIQUE sur `(sensor_id, time_bucket)` permet `REFRESH CONCURRENTLY`
- pg_cron rafraîchit toutes les 5 minutes (job `aciertech_refresh_ai_view`)

### 3.5 V004 : Tables de quarantaine

```sql
-- Données rejetées avec possibilité de révision humaine
CREATE TABLE iot_quarantine.rejected_readings (
    quality_score    SMALLINT NOT NULL,
    rejection_reason TEXT     NOT NULL,  -- 'OUT_OF_RANGE;ZSCORE_ANOMALY' etc.
    reviewed         BOOLEAN  NOT NULL DEFAULT FALSE,
    reviewed_by      TEXT,
    review_action    VARCHAR(20),  -- 'confirmed_reject' | 'reinject' | 'recalibrate_sensor'
    CONSTRAINT chk_quarantine_quality_max CHECK (quality_score < 70)
);

-- Log fin : une ligne par code anomalie
-- Permet les agrégations par type dans Grafana
CREATE TABLE iot_quarantine.anomaly_log (
    anomaly_type VARCHAR(50) NOT NULL,  -- OUT_OF_RANGE, WARNING_LOW, ZSCORE_ANOMALY...
    severity     VARCHAR(10) NOT NULL,  -- 'warning' | 'critical'
    zscore       NUMERIC(6,3),         -- score Z calculé
    original_id  BIGINT NOT NULL       -- référence iot_raw
);
```

### 3.6 V005 : Tables d'administration DBA

**sensor_thresholds** : le référentiel des seuils opérationnels.

```sql
CREATE TABLE dba_schema.sensor_thresholds (
    sensor_id           SMALLINT NOT NULL,
    sensor_type         VARCHAR(20) NOT NULL,
    sensor_name         VARCHAR(100) NOT NULL,
    location            VARCHAR(100),
    unit                VARCHAR(10) NOT NULL,
    warn_min            NUMERIC(12,4),      -- seuil d'avertissement bas
    warn_max            NUMERIC(12,4),      -- seuil d'avertissement haut
    critical_min        NUMERIC(12,4),      -- seuil critique bas
    critical_max        NUMERIC(12,4),      -- seuil critique haut
    zscore_threshold    NUMERIC(4,2) NOT NULL DEFAULT 3.0,  -- règle 3-sigma
    expected_interval_s INTEGER NOT NULL DEFAULT 60,         -- fréquence d'émission attendue
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (sensor_id, sensor_type)
);
```

Les contraintes CHECK garantissent la cohérence des seuils :
```sql
CONSTRAINT chk_thresholds_warn_inside_critical
    CHECK (warn_min >= critical_min)  -- la zone warning est DANS la zone critique
```

**backup_history** : historique des sauvegardes pgBackRest :
```sql
CREATE TABLE dba_schema.backup_history (
    backup_type  VARCHAR(10) NOT NULL,  -- 'full' | 'diff' | 'incr' | 'verify' | 'restore_test'
    status       VARCHAR(20) NOT NULL,  -- 'running' | 'success' | 'failed'
    duration_s   INTEGER,
    size_bytes   BIGINT,
    wal_start    VARCHAR(50),
    wal_stop     VARCHAR(50),
    verify_status VARCHAR(20) DEFAULT 'not_verified'
);
```

**data_quality_snapshots** : snapshots qualité toutes les 5 minutes :
```sql
CREATE TABLE dba_schema.data_quality_snapshots (
    snapshot_at      TIMESTAMPTZ NOT NULL DEFAULT DATE_TRUNC('minute', NOW()),
    sensor_type      VARCHAR(20) NOT NULL,
    total_received   INTEGER NOT NULL,
    valid_count      INTEGER NOT NULL,
    quarantine_count INTEGER NOT NULL,
    avg_quality_score NUMERIC(5,2),
    valid_pct        NUMERIC(5,2),
    quality_status   VARCHAR(15) NOT NULL DEFAULT 'UNKNOWN',
    UNIQUE (snapshot_at, sensor_type, window_minutes)  -- pas de doublons
);
```

**sensor_registry** : registre physique des 47 capteurs :
```sql
CREATE TABLE dba_schema.sensor_registry (
    sensor_id       SMALLINT PRIMARY KEY,
    sensor_name     VARCHAR(100) NOT NULL,
    sensor_type     VARCHAR(20) NOT NULL,
    location_zone   VARCHAR(50),       -- 'HAUT-FOURNEAU', 'LAMINOIR', 'COKERIE'...
    manufacturer    VARCHAR(50),
    model           VARCHAR(50),
    serial_number   VARCHAR(50),
    installed_at    DATE,
    last_calibration DATE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);
```

### 3.7 V008 : Les 47 capteurs IoT

Le fichier `V008__seed_thresholds.sql` insère les 47 capteurs avec leurs seuils opérationnels. Exemple pour le capteur de température `TEMP-001` (Haut-fourneau n°1) :

```sql
-- Capteur (sensor_id=1) : Température du haut-fourneau n°1
INSERT INTO dba_schema.sensor_registry (sensor_id, sensor_name, sensor_type,
    location_zone, location_detail, manufacturer, model, serial_number, installed_at)
VALUES (1, 'TEMP-001', 'temperature', 'HAUT-FOURNEAU', 'Haute voute hot-blast',
        'ThermoSys', 'TH-2000', 'T-2024-0001', '2024-01-15');

-- Ses seuils (température de four : normale 1200-1600°C)
INSERT INTO dba_schema.sensor_thresholds (sensor_id, sensor_type, sensor_name,
    location, unit, warn_min, warn_max, critical_min, critical_max, zscore_threshold,
    expected_interval_s)
VALUES (1, 'temperature', 'TEMP-001', 'HAUT-FOURNEAU', '°C',
        1200, 1600,    -- warning : en dessous de 1200 ou au-dessus de 1600
        800, 2000,     -- critique : en dessous de 800 ou au-dessus de 2000
        2.5,           -- zscore threshold plus strict (fours, grande inertie thermique)
        30);           -- attendu toutes les 30 secondes
```

**Vue d'ensemble des capteurs :**

| IDs | Type | Capteurs | Localisation |
|---|---|---|---|
| 1–15 | temperature | TEMP-001 à TEMP-015 | Haut-fourneau, laminoir, cokerie, coulée continue |
| 16–23 | pressure | PRESS-001 à PRESS-008 | Circuit hydraulique, vapeur, air comprimé |
| 24–31 | vibration | VIB-001 à VIB-008 | Moteurs, pompes, ventilateurs |
| 32–37 | current | CURR-001 à CURR-006 | Transformateurs, moteurs électriques |
| 38–42 | flow | FLOW-001 à FLOW-005 | Circuit de refroidissement, gaz |
| 43–45 | speed | SPEED-001 à SPEED-003 | Laminoir, ventilateurs |
| 46–47 | thickness | THK-001 à THK-002 | Laminoir (qualité produit) |

### 3.8 Moteur de scoring : fn_compute_quality_score

Cette fonction est le cerveau du pipeline. Elle est appelée par le trigger `trg_validate_sensor` pour chaque INSERT dans `iot_raw.sensor_readings`.

**Arbre de décision :**

```
Entrée : sensor_id, sensor_type, value, recorded_at
    │
    ├─ Étape 1 : Récupération des seuils (PK lookup)
    │   ├─ Trouvé → continue
    │   └─ NON TROUVÉ → score=50 (NO_THRESHOLD), RETURN
    │
    ├─ Étape 2 : Vérification bornes physiques (critical_min/max)
    │   ├─ Dans les bornes → continue
    │   └─ HORS BORNES → score=0 (OUT_OF_RANGE), GOTO build_result
    │
    ├─ Étape 3 : Vérification seuils warning (warn_min/max)
    │   ├─ OK → continue
    │   └─ DÉPASSÉ → score=75 (WARNING_LOW ou WARNING_HIGH)
    │
    ├─ Étape 4 : Calcul Z-score sur fenêtre 1h
    │   ├─ Fenêtre insuffisante (< 10 points) → skip
    │   ├─ σ=0 → skip (capteur stable)
    │   ├─ Z ≤ threshold → OK
    │   └─ Z > threshold → score=65 (ZSCORE_ANOMALY)
    │                        ou score=55 si combiné avec un WARNING
    │
    └─ build_result : construction JSONB de sortie
```

**Code clé** (extrait de `fn_compute_quality_score.sql`) :

```sql
CREATE OR REPLACE FUNCTION dba_schema.fn_compute_quality_score(
    p_sensor_id   INTEGER,
    p_sensor_type VARCHAR(50),
    p_value       NUMERIC(10,4),
    p_recorded_at TIMESTAMPTZ
) RETURNS TABLE (score SMALLINT, reason TEXT, details JSONB)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = dba_schema, iot_raw, pg_catalog
AS $$
DECLARE
    v_thresh   dba_schema.sensor_thresholds%ROWTYPE;
    v_score    SMALLINT := 100;
    v_reason   TEXT     := 'OK';
    v_details  JSONB    := '{}'::JSONB;
    v_reasons  TEXT[]   := ARRAY[]::TEXT[];
    v_mean     NUMERIC;
    v_stddev   NUMERIC;
    v_zscore   NUMERIC;
    v_window_count BIGINT;
BEGIN
    -- Étape 1 : lookup seuils
    SELECT * INTO v_thresh
    FROM dba_schema.sensor_thresholds
    WHERE sensor_id = p_sensor_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 50::SMALLINT, 'NO_THRESHOLD',
            jsonb_build_object('sensor_id', p_sensor_id, ...);
        RETURN;
    END IF;

    -- Étape 2 : bornes physiques
    IF p_value < v_thresh.min_value OR p_value > v_thresh.max_value THEN
        v_score := 0;
        v_reasons := array_append(v_reasons, 'OUT_OF_RANGE');
        GOTO build_result;
    END IF;

    -- Étape 3 : seuils warning
    IF v_thresh.warning_min IS NOT NULL AND p_value < v_thresh.warning_min THEN
        v_score := LEAST(v_score, 75);
        v_reasons := array_append(v_reasons, 'WARNING_LOW');
    END IF;

    -- Étape 4 : Z-score sur fenêtre 1h
    SELECT AVG(sr.value), STDDEV_SAMP(sr.value), COUNT(*)
    INTO v_mean, v_stddev, v_window_count
    FROM iot_raw.sensor_readings sr
    WHERE sr.sensor_id = p_sensor_id
      AND sr.validation_status = 'valid'
      AND sr.recorded_at >= p_recorded_at - INTERVAL '1 hour'
      AND sr.recorded_at < p_recorded_at;

    IF v_window_count >= 10 AND v_stddev > 0 THEN
        v_zscore := ABS((p_value - v_mean) / v_stddev);
        IF v_zscore > v_thresh.zscore_threshold THEN
            v_score := LEAST(v_score, CASE WHEN v_score < 100 THEN 55 ELSE 65 END);
            v_reasons := array_append(v_reasons, 'ZSCORE_ANOMALY');
        END IF;
    END IF;

    <<build_result>>
    v_reason := CASE WHEN array_length(v_reasons, 1) IS NULL
                    THEN 'OK'
                    ELSE array_to_string(v_reasons, '|')
               END;

    RETURN QUERY SELECT v_score, v_reason, v_details;
END;
$$;
```

### 3.9 Trigger de validation : trg_validate_sensor

Le trigger `BEFORE INSERT ON iot_raw.sensor_readings` est le point d'entrée unique du pipeline.

**Flux complet :**

```sql
CREATE OR REPLACE FUNCTION iot_raw.trg_fn_validate_sensor()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_score   SMALLINT;
    v_reason  TEXT;
    v_details JSONB;
    v_reason_codes TEXT[];
    v_code         TEXT;
BEGIN
    -- Étape 1 : calcul du score
    SELECT qs.score, qs.reason, qs.details
    INTO v_score, v_reason, v_details
    FROM dba_schema.fn_compute_quality_score(
        NEW.sensor_id, NEW.sensor_type, NEW.value, NEW.recorded_at
    ) qs;

    -- Étape 2 : mise à jour de la ligne iot_raw
    NEW.quality_score := v_score;
    NEW.validation_status := CASE WHEN v_score >= 70 THEN 'valid'
                                  ELSE 'quarantined'
                             END;

    -- Étape 3a : score ≥ 70 → copie dans iot_clean
    IF v_score >= 70 THEN
        INSERT INTO iot_clean.sensor_readings (...) VALUES (...);

    -- Étape 3b : score < 70 → quarantaine + anomaly_log
    ELSE
        INSERT INTO iot_quarantine.rejected_readings (...) VALUES (...);

        -- Une ligne par code anomalie (FOREACH)
        v_reason_codes := string_to_array(v_reason, '|');
        FOREACH v_code IN ARRAY v_reason_codes LOOP
            INSERT INTO iot_quarantine.anomaly_log (...) VALUES (...);
        END LOOP;
    END IF;

    RETURN NEW;

EXCEPTION WHEN OTHERS THEN
    -- Filet de sécurité : jamais bloquer l'ingestion IoT
    NEW.validation_status := 'error';
    INSERT INTO iot_raw.ingestion_errors (...) VALUES (...);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_sensor
    BEFORE INSERT ON iot_raw.sensor_readings
    FOR EACH ROW
    EXECUTE FUNCTION iot_raw.trg_fn_validate_sensor();
```

### 3.10 Vues métier

**v_data_quality_dashboard** : agrégation par type de capteur sur fenêtre 1h glissante.

```sql
CREATE OR REPLACE VIEW dba_schema.v_data_quality_dashboard AS
WITH raw_window AS (
    SELECT * FROM iot_raw.sensor_readings
    WHERE recorded_at >= NOW() - INTERVAL '1 hour'
)
SELECT
    sensor_type,
    COUNT(*) AS total_readings,
    COUNT(*) FILTER (WHERE validation_status = 'valid') AS valid_count,
    ROUND((valid_count::NUMERIC / total_readings::NUMERIC) * 100, 2) AS valid_rate_pct,
    sensors_active,
    (sensors_expected - sensors_active) AS sensors_silent,
    CASE
        WHEN valid_rate_pct >= 95 THEN 'EXCELLENT'
        WHEN valid_rate_pct >= 80 THEN 'GOOD'
        WHEN valid_rate_pct >= 60 THEN 'DEGRADED'
        ELSE 'CRITICAL'
    END AS quality_level
FROM raw_window
GROUP BY sensor_type;
```

**v_replication_status** : état enrichi de `pg_stat_replication` avec niveaux d'alerte.

```sql
CREATE OR REPLACE VIEW dba_schema.v_replication_status AS
SELECT
    r.application_name AS replica_name,
    r.state             AS replication_state,
    r.sync_state        AS sync_mode,
    GREATEST(pg_wal_lsn_diff(r.primary_lsn, r.sent_lsn), 0) AS unsent_bytes,
    ROUND(EXTRACT(EPOCH FROM r.replay_lag)::NUMERIC, 3) AS replay_lag_seconds,
    CASE
        WHEN r.replay_lag < INTERVAL '5 seconds'  THEN 'OK'
        WHEN r.replay_lag < INTERVAL '30 seconds' THEN 'WARNING'
        ELSE 'CRITICAL'
    END AS lag_level
FROM pg_stat_replication r;
```

**v_session_activity** : sessions actives avec détection de blocages.

```sql
CREATE OR REPLACE VIEW dba_schema.v_session_activity AS
SELECT
    a.pid, a.usename, a.state, a.query_start,
    EXTRACT(EPOCH FROM (NOW() - a.query_start)) AS duration_seconds,
    b.blocking_pid,
    LEFT(b.query, 200) AS blocking_query,
    CASE
        WHEN b.blocking_pid IS NOT NULL THEN TRUE ELSE FALSE
    END AS is_blocked,
    CASE
        WHEN duration_seconds >= 30 OR b.blocking_pid IS NOT NULL THEN 'CRITICAL'
        WHEN duration_seconds >= 5 THEN 'WARNING'
        ELSE 'OK'
    END AS alert_level
FROM pg_stat_activity a
LEFT JOIN pg_stat_activity blocker ON ...
WHERE a.backend_type = 'client backend';
```

**v_silent_sensors** : capteurs n'ayant pas émis depuis `expected_interval_s × 3`.

```sql
CREATE OR REPLACE VIEW dba_schema.v_silent_sensors AS
SELECT
    reg.sensor_id, reg.sensor_name, reg.sensor_type,
    COALESCE(thr.expected_interval_s, 300) AS expected_interval_s,
    ls.last_reading_at,
    EXTRACT(EPOCH FROM (NOW() - ls.last_reading_at)) AS silence_seconds,
    CASE
        WHEN ls.last_reading_at IS NULL THEN 'NEVER_SEEN'
        WHEN silence_seconds > expected_interval_s * 6 THEN 'CRITICAL'
        WHEN silence_seconds > expected_interval_s * 3 THEN 'WARNING'
    END AS silence_level
FROM dba_schema.sensor_registry reg
LEFT JOIN dba_schema.sensor_thresholds thr USING (sensor_id)
LEFT JOIN (
    SELECT sensor_id, MAX(recorded_at) AS last_reading_at
    FROM iot_raw.sensor_readings GROUP BY sensor_id
) ls USING (sensor_id)
WHERE reg.is_active = TRUE
  AND (ls.last_reading_at IS NULL
       OR silence_seconds > expected_interval_s * 3);
```

### 3.11 Maintenance : 8 jobs pg_cron

| Job | Planification | Commande |
|---|---|---|
| aciertech_quality_snapshot | `*/5 * * * *` | `fn_compute_quality_snapshot(5)` |
| aciertech_refresh_ai_view | `*/5 * * * *` | `fn_refresh_ai_view()` (REFRESH CONCURRENTLY) |
| aciertech_purge_quarantine | `0 2 * * *` | DELETE rejected_readings > 30 jours (batch 10k) |
| aciertech_purge_anomaly_log | `15 2 * * *` | DELETE anomaly_log > 30 jours |
| aciertech_purge_quality_snapshots | `0 3 * * 1` | DELETE snapshots > 90 jours |
| aciertech_purge_audit_log | `30 3 1 * *` | DELETE audit_log > 1 an |
| aciertech_purge_ingestion_errors | `30 2 * * 1` | DELETE ingestion_errors > 7 jours |
| aciertech_purge_cron_history | `0 4 * * 0` | DELETE cron.job_run_details > 14 jours |

### 3.12 Indexation (V006)

Les index sont créés dans `V006__create_indexes.sql` :

```sql
-- Index principal : couvre le Z-score (V002 V006)
CREATE INDEX idx_raw_sr_sensor_type_time_status
    ON iot_raw.sensor_readings (sensor_id, recorded_at, validation_status)
    WHERE validation_status = 'valid';

-- BRIN pour scans temporels sur 24h (V002)
CREATE INDEX idx_raw_sr_recorded_at_brin
    ON iot_raw.sensor_readings USING BRIN (recorded_at)
    WITH (pages_per_range = 32);

-- GIN sur rejection_reason dans anomaly_log (V004)
CREATE INDEX idx_anomaly_log_rejection_reason_gin
    ON iot_quarantine.anomaly_log USING GIN (to_tsvector('french', anomaly_type));

-- UNIQUE pour REFRESH CONCURRENTLY de v_ai_feature_set (V003)
CREATE UNIQUE INDEX idx_ai_feature_set_unique
    ON iot_clean.v_ai_feature_set (sensor_id, time_bucket);
```

---

## 4. Fonctionnalités de l'application web

### 4.1 Accès

- **App web** : http://localhost:8080/
- **Grafana** : http://localhost:3000/ (admin / admin)

### 4.2 Page d'accueil — Tableau de bord

**URL** : `/` ou `/dashboard`

**Ce qui est affiché :**

- **6 KPIs** : État du cluster, Qualité des données, Dernière FULL, Lag réplication, Connexions actives, Capteurs silencieux
- **Topologie des serveurs** : carte live des 3 nœuds PostgreSQL avec leur rôle (PRIMARY/REPLICA) et leur lag
- **Qualité des capteurs** : grille des 7 types avec barres de progression
- **Activité récente** : 8 dernières entrées (pg_cron + backups) en temps réel
- **Stack technique** : résumé des composants installés

**Données consommées :**
- `_get_cluster_context()` dans `main.py` appelle 7 endpoints asynchrones (Patroni, Prometheus, v_data_quality_dashboard, v_replication_status, v_session_activity, v_silent_sensors, backup_history)
- `fetchall_ro()` via le pool `aciertech_ro` sur HAProxy :5001

### 4.3 Page Cluster

**URL** : `/cluster`

**Ce qui est affiché :**

- **Topologie live** : cartes des 3 nœuds (PRIMARY/REPLICA) avec timeline, port, état de santé, lag
- **Statut réplication** : tableau complet avec LSN, sync_state, lag en octets/secondes, niveau d'alerte
- **HAProxy** : ports RW:5000, RO:5001, Stats:7000
- **pgBouncer** : clients actifs/inactifs, serveurs actifs/inactifs
- **etcd** : 3 membres avec rôle (LEADER/FOLLOWER) et état de santé
- **Grafana iframe** : dashboard Cluster & Réplication

**Données consommées :**
- `Patroni REST API :8008 /cluster` → topologie, pause_mode
- `v_replication_status` → lag, sync_state, LSN
- `v_session_activity` → résumé connexions
- `HAProxy :7000 /stats;csv` → statut backends
- `etcd :2379 /health` → santé des 3 membres

### 4.4 Page Qualité

**URL** : `/quality`

**Ce qui est affiché :**

- **6 KPIs** : Taux global, Score moyen, Mis en quarantaine (1h), Capteurs silencieux, Lectures totales, Dernier rafraîchissement IA
- **Légende des scores** : 100 VALID → 0 OUT_OF_RANGE
- **Qualité par type de capteur** : 7 lignes avec barres de progression, compteurs valides/quarantaine/silencieux
- **Anomalies récentes** : 20 dernières anomalies (code, score, valeur, détecté)
- **Capteurs silencieux** : breakdown CRITIQUE/ATTENTION/JAMAIS VU avec durée de silence

**Données consommées :**
- `v_data_quality_dashboard` → agrégats par type
- `v_silent_sensors` → capteurs silencieux
- `anomaly_log` → anomalies récentes
- `cron.job_run_details` → statut refresh IA
- `ingestion_errors` → erreurs d'ingestion

**Action disponible :**
- `Rafraîchir vue IA` → POST `/api/quality/refresh-ai-view` → `fn_refresh_ai_view()` avec autocommit

### 4.5 Page Sauvegardes

**URL** : `/backups`

**Ce qui est affiché :**

- **6 KPIs** : Statut vérification, Test restauration, Dernière FULL, Dépôt, Fenêtre PITR, Chiffrement
- **Calendrier** : 3 cartes (FULL / DIFF / Verify+Test) avec horaire, script, compression, durée moyenne
- **Historique** : timeline des backups avec type, durée, taille, statut
- **Fenêtre PITR** : âge PITR, granularité 15min, compression WAL, chiffrement AES-256
- **Restauration PITR** : formulaire complet (type de cible, horodatage, nœud) avec test à blanc
- **Test restauration** : 5 vérifications post-restauration

**Actions disponibles :**
- `Run PITR (dry-run/test)` → POST `/api/backups/pitr` avec validation CONFIRM
- `Re-run test` → POST `/api/backups/trigger/verify`

### 4.6 Page Alertes

**URL** : `/alerts`

**Ce qui est affiché :**

- **Bannière** : Prometheus disponible/indisponible, alertes critiques en cours
- **4 compteurs** : Critique, Avertissement, En attente, Info
- **Tableau des alertes actives** : sévérité, nom, catégorie, labels (node/instance/stanza), description, depuis
- **Métriques sauvegarde** : statut vérification, test, âge FULL, taille dépôt (via Pushgateway Prometheus)
- **Métriques PostgreSQL clés** : Lag réplication, Cache hit ratio, Sessions bloquées, Deadlocks, Taux validation IoT, Silencieux critiques
- **Règles par groupe** : 4 groupes de règles Prometheus avec état des alertes

**Données consommées :**
- `Prometheus API :9090 /api/v1/alerts` → alertes actives
- `Prometheus API :9090 /api/v1/rules` → règles par groupe
- `Prometheus API :9090 /api/v1/query` → métriques sauvegarde et PG

**Polling automatique :** le tableau des alertes se rafraîchit toutes les 30 secondes en AJAX.

### 4.7 Page Contrôle (Failover)

**URL** : `/failover`

**Ce qui est affiché :**

- **Bannière d'avertissement** : page de contrôle critique
- **Topologie live** : les 3 nœuds avec timeline, connexions, lag, santé
- **Journal d'événements** : terminal en direct qui logue toutes les actions (initialisation, basculement, etc.)

**Actions disponibles :**

| Action | Endpoint | Description |
|---|---|---|
| Basculement contrôlé | POST `/api/cluster/switchover` | Transfert planifié du PRIMARY vers un réplica (zéro perte) |
| Forcer le failover | POST `/api/cluster/failover` | Failover d'urgence (perte possible si PRIMARY encore actif) |
| Réinitialiser réplica | POST `/api/cluster/reinit` | Réinitialise PGDATA complète d'un standby |
| Pause auto-failover | POST `/api/cluster/pause` | Suspend le failover automatique Patroni (maintenance) |
| Reprendre auto-failover | POST `/api/cluster/resume` | Reprend le failover automatique |

Chaque action ouvre une modale de confirmation avec saisie d'un mot de confirmation
(« CONFIRM », « FAILOVER-FORCE » ou « REINIT »).

**Données consommées :**
- `Patroni REST API :8008` pour toutes les actions POST
- `Patroni /cluster` pour la topologie
- JavaScript `toLocaleTimeString('fr-FR')` pour les timestamps

### 4.8 Page Simulation de sinistre

**URL** : `/disaster`

**3 scénarios interactifs :**

| Scénario | Boutons | Effet |
|---|---|---|
| 1 — Panne du nœud primaire | Crash primaire → Failover → pg-node-2 | Le PRIMARY tombe, les écritures échouent, le failover promeut un nouveau leader |
| 2 — Panne d'un réplica | Crash réplica → Réinitialiser node-3 | Un standby perd la connectivité, le lag spike, réinitialisation complète |
| 3 — Corruption + PITR | Déclencher corruption → Lancer restauration PITR | Corruption de `sensor_data`, valid_rate → 8%, PITR restaure l'état sain |

**Fonctionnalités live :**
- Bannière de santé qui passe de « Cluster sain » à « Cluster dégradé »
- Topologie live qui met à jour les statuts des nœuds (running → err)
- Chronologie des événements en direct
- Les alertes Prometheus et le compteur de la navbar se mettent à jour
- API REST : 10 endpoints mockés (`/api/disaster/*`)

**Backend mocké :** `mock-server.py` maintient un état global `DISASTER` qui force les endpoints Patroni/Prometheus/etcd à retourner des réponses dégradées :
```python
# Exemple : état dégradé pendant un crash primaire
DISASTER = {
    "active": True,
    "scenario": "primary_crash",
    "nodes": {
        "pg-node-1": "down",
        "pg-node-2": "running",
        "pg-node-3": "running"
    },
    "leader": "pg-node-2",         # après failover
    "replication_lag_ms": 45000,    # lag artificiel
    "backups_valid": False,         # sauvegardes marquées invalides
    "alerts_count": 3               # alertes générées
}
```

---

## 5. Volet administration de bases de données

### 5.1 Qu'est-ce qu'un DBA dans ce contexte ?

Le DBA AcierTech est responsable de :

1. **L'infrastructure HA** : Patroni 3 nœuds, etcd, HAProxy, pgBouncer
2. **Le pipeline qualité** : validation des 47 capteurs IoT
3. **La sauvegarde et le PRA** : pgBackRest, PITR, tests de restauration
4. **La supervision** : Prometheus + Grafana
5. **Les performances** : indexation, vacuum, analyse des requêtes lentes
6. **La sécurité** : rôles, droits, audit des modifications de seuils

### 5.2 Comment le SQL supporte le travail DBA

**1. Migration versionnée** (V001 à V008)

Les migrations sont exécutées par `01_run_migrations.sh` qui suit les migrations appliquées dans `dba_schema.migration_history` :

```sql
-- dba_schema.migration_history stocke les checksums SHA-256
CREATE TABLE dba_schema.migration_history (
    version     VARCHAR(20) PRIMARY KEY,
    filename    VARCHAR(255) NOT NULL,
    checksum    VARCHAR(64)  NOT NULL,  -- SHA-256
    applied_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    duration_ms INTEGER,
    success     BOOLEAN                  NOT NULL DEFAULT TRUE
);
```

**2. Audit des modifications de seuils**

Le trigger `trg_audit_changes` sur `sensor_thresholds` journalise chaque modification :

```sql
CREATE TABLE dba_schema.threshold_audit_log (
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    changed_by    TEXT,                    -- current_user
    session_info  TEXT,                    -- application_name, client_addr
    action        VARCHAR(10) NOT NULL,    -- 'UPDATE' | 'DELETE'
    sensor_id     SMALLINT,
    column_name   TEXT,                    -- 'warn_min', 'zscore_threshold'...
    old_value     JSONB,                   -- ancienne valeur
    new_value     JSONB,                   -- nouvelle valeur
    change_context JSONB                   -- contexte complet de session
);
```

**3. Partitionnement (pour > 50M lignes)**

Quand `iot_raw.sensor_readings` dépasse 50 millions de lignes, `partition_management.sql` propose une migration vers un partitionnement mensuel :

```sql
-- Fonction helper : création d'une partition mensuelle
CREATE OR REPLACE FUNCTION dba_schema.fn_create_monthly_partition(
    p_year_month DATE  -- ex: '2024-12-01'
) RETURNS TEXT AS $$
DECLARE
    v_partition_name TEXT;
    v_start_date     TEXT;
    v_end_date       TEXT;
BEGIN
    v_partition_name := 'iot_raw.sensor_readings_'
                        || TO_CHAR(p_year_month, 'YYYY_MM');
    v_start_date     := TO_CHAR(p_year_month, 'YYYY-MM-DD"T"00:00:00"Z"');
    v_end_date       := TO_CHAR(p_year_month + INTERVAL '1 month',
                                'YYYY-MM-DD"T"00:00:00"Z"');

    EXECUTE format(
        'CREATE TABLE %s (LIKE iot_raw.sensor_readings INCLUDING ALL)',
        v_partition_name
    );
    EXECUTE format(
        'ALTER TABLE iot_raw.sensor_readings ATTACH PARTITION %s '
        || 'FOR VALUES FROM (%L) TO (%L)',
        v_partition_name, v_start_date, v_end_date
    );
    RETURN v_partition_name;
END;
$$ LANGUAGE plpgsql;
```

**4. Réglage autovacuum** (`vacuum_schedule.sql`)

```sql
-- iot_raw : écriture intense, vacuum agressif
ALTER TABLE iot_raw.sensor_readings SET (
    autovacuum_vacuum_scale_factor = 0.02,    -- déclenche plus tôt
    autovacuum_vacuum_cost_delay = 0,         -- pas de throttling
    autovacuum_analyze_scale_factor = 0.01    -- statistiques fraîches
);

-- dba_schema.threshold_audit_log : rarement modifié, vacuum permissif
ALTER TABLE dba_schema.threshold_audit_log SET (
    autovacuum_vacuum_scale_factor = 0.2,     -- seulement quand 20% de dead tuples
    autovacuum_vacuum_cost_delay = 20         -- I/O light
);
```

**5. Le DBA peut surveiller en temps réel :**

```sql
-- État réplication
SELECT * FROM dba_schema.v_replication_status;

-- Sessions bloquées
SELECT * FROM dba_schema.v_session_activity
WHERE is_blocked = TRUE OR alert_level = 'CRITICAL';

-- Capteurs silencieux
SELECT * FROM dba_schema.v_silent_sensors
WHERE silence_level IN ('CRITICAL', 'NEVER_SEEN');

-- Qualité globale des données
SELECT * FROM dba_schema.v_data_quality_dashboard;

-- Statut des jobs pg_cron
SELECT jobname, schedule, active,
       d.status AS last_status,
       d.start_time AS last_start
FROM cron.job j
LEFT JOIN LATERAL (
    SELECT * FROM cron.job_run_details
    WHERE jobid = j.jobid ORDER BY start_time DESC LIMIT 1
) d ON TRUE
WHERE j.jobname LIKE 'aciertech_%';
```

**6. Alertes Prometheus**

Les 4 règles d'alerte Prometheus surveillent :

| Alerte | Seuil | Règle PromQL |
|---|---|---|
| AcierTechClusterDegraded | Patroni indisponible | `patroni_health != 1` |
| AcierTechReplicationLagHigh | Lag > 30s | `replication_lag_seconds > 30` |
| AcierTechQualityDegraded | Taux valide < 80% | `sensor_quality_valid_rate < 80` |
| AcierTechBackupTooOld | Pas de FULL depuis > 48h | `(time() - backup_full_timestamp) > 172800` |

---

## 6. Cas d'utilisation métier

### 6.1 Supervision quotidienne

**Problème :** L'opérateur veut savoir si tout va bien en un coup d'œil.

**Solution :** La page **Tableau de bord** (http://localhost:8080/) donne 6 KPIs + la topologie + la qualité par type. La sidebar affiche le statut global du cluster avec un point vert/orange/rouge. Les alertes sont visibles via la cloche dans la topbar.

### 6.2 Détection d'un capteur défaillant

**Problème :** Un capteur de vibration (VIB-004) n'émet plus depuis 10 minutes.

**Solution :** La page **Qualité** (http://localhost:8080/quality) montre dans « Capteurs silencieux » le capteur avec son niveau (WARNING ou CRITICAL). Le DBA peut :
1. Voir la durée exacte du silence
2. Voir l'intervalle attendu (30s) et le ratio silence/intervalle
3. Aller dans Grafana pour visualiser la courbe
4. Déclencher une maintenance via le formulaire PRA

**SQL sous-jacent :**
```sql
-- Ce qu'affiche la page Qualité
SELECT sensor_name, sensor_type, silence_duration, silence_level
FROM dba_schema.v_silent_sensors
WHERE silence_level IN ('CRITICAL', 'WARNING')
ORDER BY silence_level, silence_duration DESC;
```

### 6.3 Analyse d'une dégradation de qualité

**Problème :** Le taux de validation global est passé de 94% à 82%.

**Solution :** La page **Tableau de bord** montre la baisse sur le KPI « Qualité des données ». Le DBA clique sur **Qualité** pour voir le breakdown :
- Le type `vibration` est passé en « DEGRADED »
- La page « Alertes » montre `AcierTechQualityDegraded` en état `firing`
- Les anomalies récentes montrent 15 `ZSCORE_ANOMALY` sur VIB-004 en 1h

**SQL sous-jacent :**
```sql
-- Voir la qualité par type
SELECT sensor_type, valid_rate_pct, quality_level, avg_quality_score
FROM dba_schema.v_data_quality_dashboard
ORDER BY valid_rate_pct;

-- Voir les anomalies récentes sur VIB-004
SELECT anomaly_type, occurred_at, raw_value, zscore
FROM iot_quarantine.anomaly_log
JOIN dba_schema.sensor_registry USING (sensor_id)
WHERE sensor_name = 'VIB-004'
  AND occurred_at >= NOW() - INTERVAL '1 hour';
```

### 6.4 Basculement planifié du PRIMARY

**Problème :** Maintenance sur pg-node-1 (le PRIMARY). Il faut basculer sur pg-node-2 sans perte de données.

**Solution :** Aller sur **Contrôle** (http://localhost:8080/failover), choisir `pg-node-2` dans la liste déroulante, cliquer sur « Lancer le basculement », confirmer. Le cluster reste disponible tout au long de l'opération.

**Logique Patroni sous-jacente :**
```python
POST /api/cluster/switchover
→ Proxy vers Patroni POST /switchover sur :8008
→ Patroni promeut le standby, modifie l'offset du cluster dans etcd
→ HAProxy est mis à jour (RW maintenant vers pg-node-2)
```

### 6.5 Test de la PRA (Plan de Reprise d'Activité)

**Problème :** L'auditeur veut une preuve que la restauration PITR fonctionne.

**Solution :** Aller sur **Sauvegardes** (http://localhost:8080/backups), cliquer sur « Test restauration ». La page montre 5 vérifications post-restauration :
- `sensor_registry = 47` ✓
- `sensor_thresholds = 47` ✓
- `Schémas DBA présents` ✓
- `Vue IA fonctionnelle` ✓
- `Fonctions DBA` ✓

### 6.6 Simulation de catastrophe en démo client

**Problème :** Présenter le projet à un client. Il faut montrer que le système réagit à un crash.

**Solution :** Aller sur **Simulation** (http://localhost:8080/disaster). 3 scénarios permettent de :
1. Crasher le PRIMARY → montrer le cluster degraded, les alertes qui s'allument
2. Lancer le failover → montrer la promotion d'un réplica, le rétablissement
3. Corrompre les données → montrer l'effondrement du valid_rate (94% → 8%), les anomalies qui explosent
4. Lancer PITR → montrer la récupération complète

**Comment ça marche :** Le `mock-server.py` expose des endpoints dynamiques. Quand un sinistre est actif, tous les endpoints Patroni, Prometheus, HAProxy et etcd retournent des réponses dégradées. L'app web, qui ne fait que consommer ces endpoints, affiche naturellement l'état dégradé.

---

## 7. Guide de personnalisation SQL

Cette section explique comment modifier les fichiers SQL pour démontrer des compétences avancées.

### 7.1 Ajouter une nouvelle fonction de scoring

**Exemple :** Ajouter une détection de dérive lente (slow drift) en complément du Z-score :

```sql
-- Dans 02-sql/functions/fn_compute_quality_score.sql
-- Après le calcul du Z-score, ajouter :

-- Étape 4b : Détection de dérive lente (moyenne mobile 1h vs moyenne historique 24h)
DECLARE
    v_hist_mean NUMERIC;
BEGIN
    SELECT AVG(value) INTO v_hist_mean
    FROM iot_raw.sensor_readings
    WHERE sensor_id = p_sensor_id
      AND validation_status = 'valid'
      AND recorded_at >= p_recorded_at - INTERVAL '24 hours'
      AND recorded_at < p_recorded_at;

    IF v_hist_mean IS NOT NULL AND v_mean IS NOT NULL THEN
        -- Si la moyenne 1h dévie de plus de 20% de la moyenne 24h
        IF ABS(v_mean - v_hist_mean) / NULLIF(v_hist_mean, 0) > 0.20 THEN
            v_score := LEAST(v_score, 60);
            v_reasons := array_append(v_reasons, 'SLOW_DRIFT');
            v_details := v_details || jsonb_build_object(
                'slow_drift', jsonb_build_object(
                    'mean_1h',  ROUND(v_mean::NUMERIC, 4),
                    'mean_24h', ROUND(v_hist_mean::NUMERIC, 4),
                    'drift_pct', ROUND((ABS(v_mean - v_hist_mean)
                        / NULLIF(v_hist_mean, 0) * 100)::NUMERIC, 2)
                )
            );
        END IF;
    END IF;
```

**Pour tester :**
```sql
-- Insérer une mesure avec une valeur dérivante lente
INSERT INTO iot_raw.sensor_readings (sensor_id, sensor_type, value, unit, recorded_at)
VALUES (1, 'temperature', 1450.0, '°C', NOW());

-- Vérifier le score
SELECT * FROM dba_schema.fn_compute_quality_score(1, 'temperature', 1450.0, NOW());
```

### 7.2 Créer une nouvelle vue pour le monitoring

**Exemple :** Vue de santé globale du pipeline IoT :

```sql
-- Dans 02-sql/views/v_iot_pipeline_health.sql
CREATE OR REPLACE VIEW dba_schema.v_iot_pipeline_health AS
WITH metrics AS (
    SELECT
        COUNT(*)                                                       AS total_1h,
        COUNT(*) FILTER (WHERE validation_status = 'valid')           AS valid_1h,
        COUNT(*) FILTER (WHERE validation_status = 'quarantined')     AS quarantined_1h,
        COUNT(*) FILTER (WHERE validation_status = 'error')           AS errors_1h,
        ROUND(AVG(quality_score)::NUMERIC, 1)                         AS avg_score_1h,
        COUNT(DISTINCT sensor_id)                                      AS active_sensors_1h
    FROM iot_raw.sensor_readings
    WHERE recorded_at >= NOW() - INTERVAL '1 hour'
),
throughput AS (
    SELECT
        COUNT(*)::NUMERIC / 3600 AS reads_per_second
    FROM iot_raw.sensor_readings
    WHERE received_at >= NOW() - INTERVAL '5 minutes'
),
silent AS (
    SELECT COUNT(*) AS silent_count
    FROM dba_schema.v_silent_sensors
    WHERE silence_level = 'CRITICAL'
)
SELECT
    m.total_1h,
    m.valid_1h,
    m.quarantined_1h,
    m.errors_1h,
    m.avg_score_1h,
    m.active_sensors_1h,
    ROUND((m.valid_1h::NUMERIC / NULLIF(m.total_1h, 0)) * 100, 2) AS valid_rate_pct,
    ROUND(t.reads_per_second, 1)                                   AS ingestion_rate_Hz,
    s.silent_count,
    CASE
        WHEN m.total_1h = 0 THEN 'NO_DATA'
        WHEN (m.valid_1h::NUMERIC / m.total_1h) >= 0.95 THEN 'EXCELLENT'
        WHEN (m.valid_1h::NUMERIC / m.total_1h) >= 0.80 THEN 'GOOD'
        WHEN (m.valid_1h::NUMERIC / m.total_1h) >= 0.60 THEN 'DEGRADED'
        ELSE 'CRITICAL'
    END AS pipeline_health
FROM metrics m, throughput t, silent s;

COMMENT ON VIEW dba_schema.v_iot_pipeline_health IS
'Santé globale du pipeline IoT AcierTech : débit d''ingestion (Hz),
taux de validation, score moyen, capteurs silencieux critiques.
Vue consolidée pour le dashboard Grafana principal.';
```

### 7.3 Ajouter une fonction de maintenance

**Exemple :** Fonction qui liste les capteurs nécessitant un recalibrage urgent :

```sql
-- Dans 02-sql/functions/fn_sensors_needing_calibration.sql
CREATE OR REPLACE FUNCTION dba_schema.fn_sensors_needing_calibration()
RETURNS TABLE (
    sensor_id       SMALLINT,
    sensor_name     VARCHAR(100),
    sensor_type     VARCHAR(20),
    location_zone   VARCHAR(50),
    days_since_last_cal INT,
    anomaly_count_7d    BIGINT,
    silence_level       VARCHAR(20),
    priority            VARCHAR(10)
)
LANGUAGE plpgsql STABLE
SET search_path = dba_schema, iot_quarantine, pg_catalog
AS $$
BEGIN
    RETURN QUERY
    SELECT
        sr.sensor_id,
        sr.sensor_name,
        sr.sensor_type,
        sr.location_zone,
        (NOW()::DATE - sr.last_calibration)::INT AS days_since_last_cal,
        COALESCE(al.anomaly_count, 0)             AS anomaly_count_7d,
        COALESCE(vs.silence_level::VARCHAR(20), 'NORMAL') AS silence_level,
        CASE
            WHEN vs.silence_level = 'CRITICAL' THEN 'URGENT'
            WHEN (NOW()::DATE - sr.last_calibration) > 365 THEN 'PLANIFIER'
            WHEN al.anomaly_count > 50 THEN 'URGENT'
            WHEN al.anomaly_count > 10 THEN 'SURVEILLER'
            ELSE 'NORMAL'
        END AS priority
    FROM dba_schema.sensor_registry sr
    LEFT JOIN (
        SELECT sensor_id, COUNT(*) AS anomaly_count
        FROM iot_quarantine.anomaly_log
        WHERE occurred_at >= NOW() - INTERVAL '7 days'
        GROUP BY sensor_id
    ) al ON al.sensor_id = sr.sensor_id
    LEFT JOIN dba_schema.v_silent_sensors vs ON vs.sensor_id = sr.sensor_id
    WHERE sr.is_active = TRUE
    ORDER BY days_since_last_cal DESC, anomaly_count DESC;
END;
$$;
```

**Test :**
```sql
SELECT * FROM dba_schema.fn_sensors_needing_calibration()
WHERE priority IN ('URGENT', 'PLANIFIER');
```

### 7.4 Modifier les seuils d'alerte

**Exemple :** Ajuster le seuil des alertes dans Prometheus (`04-monitoring/prometheus/rules/`).

Dans `rules/aciertech_alerts.yml`, modifier les seuils :

```yaml
groups:
  - name: aciertech_backup
    rules:
      - alert: AcierTechBackupTooOld
        expr: (time() - backup_full_timestamp) > 172800  # 48h → changer pour 24h
        for: 1h
        labels:
          severity: critical
```

Pour appliquer :
```bash
# Recharger les règles Prometheus sans redémarrage
curl -X POST http://localhost:9090/-/reload
```

### 7.5 Ajouter un graphique Grafana

**Pour ajouter un nouveau panneau à un dashboard existant :**

1. Éditer le JSON du dashboard dans `04-monitoring/grafana/dashboards/`
2. Ajouter un panneau avec la target PromQL :

```yaml
{
  "datasource": "Prometheus",
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 80 },
          { "color": "red", "value": 60 }
        ]
      }
    }
  },
  "targets": [{
    "expr": "sensor_quality_valid_rate{sensor_type=\"vibration\"}",
    "legendFormat": "Vibration {{sensor_type}}"
  }],
  "title": "Taux validation - Vibration"
}
```

3. Redémarrer Grafana : `docker compose restart grafana`

### 7.6 Ajouter un endpoint API à la webapp

**Exemple :** Un endpoint pour lister les capteurs par zone de l'usine :

```python
# Dans 05-webapp/routers/quality.py

@router.get("/api/quality/by-zone", tags=["quality"])
async def api_quality_by_zone():
    """
    Qualité des données regroupée par zone géographique de l'usine.
    Zones : HAUT-FOURNEAU, LAMINOIR, COKERIE, COULÉE CONTINUE...
    """
    rows = await fetchall_ro("""
        SELECT
            sr.location_zone,
            COUNT(DISTINCT sr.sensor_id) AS sensor_count,
            ROUND(AVG(dq.valid_rate_pct)::numeric, 1) AS avg_valid_rate,
            ROUND(AVG(dq.avg_quality_score)::numeric, 1) AS avg_score,
            COUNT(DISTINCT vs.sensor_id) AS silent_sensors
        FROM dba_schema.sensor_registry sr
        LEFT JOIN dba_schema.v_data_quality_dashboard dq ON dq.sensor_type = sr.sensor_type
        LEFT JOIN dba_schema.v_silent_sensors vs ON vs.sensor_id = sr.sensor_id
        WHERE sr.is_active = TRUE
        GROUP BY sr.location_zone
        ORDER BY sr.location_zone
    """)
    return {"zones": rows}
```

Puis l'appeler : http://localhost:8080/api/quality/by-zone

### 7.7 Jouer avec le mode dégradé

Dans `docker/mock-server.py`, la variable `DISASTER` force tous les endpoints à retourner
des réponses dégradées. Exemple pour un test local :

```python
# Activer manuellement un mode « haute température » sur tous les capteurs
DISASTER["scenario"] = "heat_wave"
DISASTER["description"] = "Vague de chaleur — tous les capteurs température > 1800°C"
DISASTER["_adjust_for_disaster"] = lambda m: modify_value(m, 1.5)
```

L'app web et Prometheus reflètent immédiatement le changement.

---

## Références

| Sujet | Fichier | Chemin |
|---|---|---|
| Migrations SQL (V001–V008) | `V00*__*.sql` | `02-sql/migrations/` |
| Fonctions PL/pgSQL | `fn_*.sql` | `02-sql/functions/` |
| Vues métier | `v_*.sql` | `02-sql/views/` |
| Triggers | `trg_*.sql` | `02-sql/triggers/` |
| Maintenance & pg_cron | `*.sql` | `02-sql/maintenance/` |
| Scripts init DB | `*.sh` | `02-sql/init/` |
| Routes webapp | `main.py`, `routers/*.py` | `05-webapp/` |
| Templates HTML | `*.html` | `05-webapp/templates/` |
| Docker Compose | `docker-compose.yml` | `05-webapp/` |
| Mock server | `mock-server.py` | `05-webapp/docker/` |
| Règles Prometheus | `aciertech_*.yml` | `04-monitoring/prometheus/rules/` |
| Dashboards Grafana | `*.json` | `04-monitoring/grafana/dashboards/` |
| Scripts backup | `backup_*.sh` | `03-backup/scripts/` |
| Configuration Patroni | `patroni.yml` | `01-infra/patroni/` |
| Configuration HAProxy | `haproxy.cfg` | `01-infra/haproxy/` |
