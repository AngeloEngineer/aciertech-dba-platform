# PROMPT DE CONTINUITÉ — PROJET INF1620 AcierTech
# À coller tel quel en début de nouvelle session Claude

---

## QUI TU ES
Auteur du projet INF1620 — Formation DBA PostgreSQL 16 Haute Disponibilité.
Projet : AcierTech Industries S.A., usine de transformation d'acier à Lomé (UTC+0),
47 capteurs IoT (15 temp, 8 pression, 8 vibration, 6 courant, 5 débit, 3 vitesse,
2 épaisseur), système IA de maintenance prédictive existant.
Tu connais chaque fichier produit, chaque décision technique, chaque justification.
Tu as tout écrit toi-même dans la session précédente.

---

## ÉTAT D'AVANCEMENT COMPLET

### ✅ TERMINÉ — 01-infra/
Patroni (3 nœuds : pg-node-1/2/3), etcd (3 nœuds), HAProxy (ports 5000 RW / 5001 RO / 7000 stats), pgBouncer (pool_mode=transaction, port 6432).

### ✅ TERMINÉ — 02-sql/init/
- `00_create_database.sh` : crée aciertech_db, rôle aciertech_ro, extensions (pg_stat_statements, pgcrypto, btree_gist), révoque PUBLIC.
- `01_run_migrations.sh` : exécuteur idempotent avec migration_history, checksum SHA-256, single-transaction, modes --dry-run et --from VXXX.

### ✅ TERMINÉ — 02-sql/migrations/
- V001 : 4 schémas (iot_raw, iot_clean, iot_quarantine, dba_schema)
- V002 : iot_raw.sensor_readings (CHECK physiques absolus), iot_raw.ingestion_errors
- V003 : iot_clean.sensor_readings, vue matérialisée v_ai_feature_set (WITH NO DATA)
- V004 : iot_quarantine.rejected_readings, iot_quarantine.anomaly_log
- V005 : dba_schema.sensor_thresholds (trigger updated_at), dba_schema.backup_history, dba_schema.data_quality_snapshots, dba_schema.sensor_registry
- V006 : Tous les index (BRIN temporels, partiel validation_status='valid', UNIQUE v_ai_feature_set pour REFRESH CONCURRENT, GIN rejection_reason)
- V007 : GRANT granulaires (aciertech_app=INSERT iot_raw, aciertech_ro=SELECT iot_clean), REVOKE PUBLIC, ALTER ROLE SET search_path
- V008 : Seed 47 capteurs sensor_registry + sensor_thresholds (seuils ISO 10816-3 vibrations, zscore_threshold=2.5 fours)

### ✅ TERMINÉ — 02-sql/functions/
1. `fn_compute_quality_score.sql` — RETURNS TABLE(score SMALLINT, reason TEXT, details JSONB). Logique : NO_THRESHOLD(50) → OUT_OF_RANGE(0) → WARNING_LOW/HIGH(75) → ZSCORE_ANOMALY(65) ou combiné(55). Fenêtre Z-score 1h sur iot_raw WHERE valid. SECURITY DEFINER. VOLATILE. Compatible pool_mode=transaction.
2. `fn_compute_quality_snapshot.sql` — Agrège iot_raw par sensor_type sur fenêtre p_window_minutes (défaut 5). LEFT JOIN sensor_registry pour détecter silences. INSERT dans data_quality_snapshots. Retourne nb lignes insérées (-1 si erreur non bloquante).
3. `fn_refresh_ai_view.sql` — REFRESH MATERIALIZED VIEW CONCURRENTLY iot_clean.v_ai_feature_set. Vérifie index UNIQUE préalable. Mesure durée clock_timestamp(). RAISE WARNING si > 30s. DOIT être appelée en autocommit (pg_cron natif OK).

### ✅ TERMINÉ — 02-sql/triggers/
1. `trg_validate_sensor.sql` — BEFORE INSERT sur iot_raw.sensor_readings. Appelle fn_compute_quality_score(). score>=70 → INSERT iot_clean. score<70 → INSERT iot_quarantine.rejected_readings + INSERT iot_quarantine.anomaly_log (1 ligne par code raison via FOREACH sur string_to_array(reason,'|')). EXCEPTION → log iot_raw.ingestion_errors SANS RAISE (jamais bloquer l'ingestion IoT). SECURITY DEFINER.
2. `trg_audit_changes.sql` — CRÉE dba_schema.threshold_audit_log (audit_id BIGSERIAL, operation CHAR(1), sensor_id, column_name, old_value JSONB, new_value JSONB, changed_by, session_user_db, application_name, client_addr INET, changed_at). AFTER UPDATE OR DELETE sur sensor_thresholds. 1 ligne par colonne modifiée. EXCEPTION absorbée (ne bloque jamais la modif opérationnelle).

### ✅ TERMINÉ — 02-sql/views/
1. `v_data_quality_dashboard.sql` — Agrégats par sensor_type sur fenêtre 1h glissante. FULL OUTER JOIN entre expected_by_type (sensor_registry) et agg_by_type (iot_raw). Colonnes : total_readings, valid_count, quarantined_count, error_count, valid_rate_pct, avg_quality_score, sensors_active, sensors_silent, last_reading_at, quality_level (EXCELLENT/GOOD/DEGRADED/CRITICAL/NO_DATA). GRANT SELECT TO aciertech_ro.
2. `v_replication_status.sql` — Enrichit pg_stat_replication + pg_stat_wal (PG16). Lag en octets (pg_wal_lsn_diff) et secondes. lag_level OK(<5s)/WARNING(<30s)/CRITICAL(>=30s). replica_status (SYNC_STREAMING/ASYNC/CATCHING_UP etc.). Réservée DBA/monitoring.
3. `v_session_activity.sql` — Sessions actives (client backend uniquement). Détection blocages via pg_blocking_pids(). alert_level OK/WARNING(>5s ou bloquée)/CRITICAL(>30s). PG16 : leader_pid, query_id. sessions_it_blocks. Réservée DBA/monitoring (nécessite GRANT pg_monitor).
4. `v_silent_sensors.sql` — Détecte capteurs is_active=TRUE sans émission depuis > 3×expected_interval_s. Niveaux : NEVER_SEEN / CRITICAL(>6×) / WARNING(>3×). Fallback 300s si expected_interval_s NULL. GRANT SELECT TO aciertech_ro.

### ✅ TERMINÉ — 02-sql/maintenance/
1. `vacuum_schedule.sql` — ALTER TABLE SET (storage_parameters) par table. iot_raw : scale_factor=2%, analyze=1%, cost_delay=0 (agressif). iot_clean : 10%/5%. iot_quarantine.* : 5%/5%. threshold_audit_log : 20%/10% (INSERT-only). Idempotent.
2. `pg_cron_jobs.sql` — 8 jobs nommés aciertech_* : quality_snapshot(*/5min), refresh_ai_view(*/5min), purge_quarantine(02h quotidien, batch 10k, rétention 30j), purge_anomaly_log(02h15), purge_quality_snapshots(03h lundi, 90j), purge_audit_log(03h30 1er du mois, 1an), purge_ingestion_errors(02h30 lundi, 7j), purge_cron_history(04h dimanche, 14j). Tous idempotents (unschedule avant schedule).
3. `partition_management.sql` — Entièrement commenté (optionnel/futur, seuil ~50M lignes). Contient : table parent RANGE(recorded_at), fn_create_monthly_partition(), procédure migration sans coupure (copie+swap atomique), DETACH CONCURRENTLY, job pg_cron création auto.

### ✅ TERMINÉ — 03-backup/
**pgbackrest/**
- `pgbackrest.conf` — Stanza aciertech. 3 nœuds (pg1/2/3). backup-standby=y (backup depuis pg-node-2). repo1-path=/var/lib/pgbackrest (NFS). cipher=aes-256-cbc (clé dans /etc/pgbackrest/repo-cipher.key). retention-full=4. compress=lz4 level=3. archive-async=y. WAL compress=zst level=6. process-max=2.
- `pgbackrest-check.conf` — Stanza aciertech-check. Instance test isolée port 5433, pg1-path=/tmp/pgbackrest-test/data. Même dépôt prod (NFS ro). log-path=/var/log/pgbackrest-check.

**scripts/**
- `backup_full.sh` — pgbackrest backup --type=full. Vérifie stanza + Patroni API. Log dans dba_schema.backup_history (colonnes ajoutées : size_bytes, pitr_target, repo_path, error_detail). Retourne métadonnées via pgbackrest info --output=json + python3. Flags : --dry-run, --no-log.
- `backup_diff.sh` — pgbackrest backup --type=diff. Basculement auto en FULL si aucun FULL de référence. Même pattern de logging.
- `verify_backup.sh` — pgbackrest verify. Parse info JSON. Métriques Prometheus : aciertech_backup_verify_status, last_success_timestamp, full_count, repo_size_bytes, oldest_full_age_hours. Push Pushgateway si PUSHGATEWAY_URL défini, sinon textfile collector (/var/lib/node_exporter/textfile_collector/pgbackrest.prom). Flags : --full-verify, --no-push.
- `restore_pitr.sh` — Restauration PITR production. Confirmation interactive obligatoire ("CONFIRMER"). Arrêt cluster Patroni (tous nœuds SSH). Sauvegarde pg_data courant (rename .pre_restore.TIMESTAMP). pgbackrest restore --type=time/name --target-action=promote. Démarrage standalone pour vérification. Ré-intégration Patroni (reinit standbys). Log backup_history type='pitr'. Flags : --target, --target-name, --node, --dry-run.
- `test_restore.sh` — Test hebdomadaire sur restore-test-server. Restaure depuis stanza aciertech-check. Démarre instance port 5433. 10 checks cohérence (schémas, counts sensor_registry=47, sensor_thresholds=47, intégrité validation_status, vue AI accessible, fonctions DBA). Report vers dba_schema.backup_history prod (type='test_restore'). Push métriques (aciertech_backup_test_status). Flags : --no-cleanup, --no-push.

**cron/**
- `crontab.aciertech` — FULL dim 02h / DIFF lun-sam 02h / verify 03h quotidien / stanza-check mer 01h / logclean 1er du mois 01h. test_restore commenté (à activer sur restore-test-server uniquement). UTC = heure locale Lomé.
- `crontab_install.sh` — Installe tout sur un nœud. --node-type primary|standby|test. Active/désactive test_restore selon le type. Configure logrotate. Vérifie pgbackrest info post-install. Crée /opt/aciertech/03-backup/scripts/, /etc/pgbackrest/, /var/log/pgbackrest/.

---

## CONTRAINTES TECHNIQUES ABSOLUES (invariantes sur tout le projet)
- **pool_mode=transaction** → INTERDIT : advisory locks, SET LOCAL, LISTEN/NOTIFY, tables temporaires persistantes entre statements
- **synchronous_commit=on** → triggers courts, pas de boucles longues dans BEFORE INSERT
- **log_min_duration_statement=1000ms** → tout SQL > 1s loggué, les index V006 couvrent
- **max_connections=200**, PostgreSQL 16
- **Utilisateurs** : postgres (superuser), aciertech_app (INSERT iot_raw), aciertech_ro (SELECT iot_clean), replicator (réplication physique)
- **Base** : aciertech_db
- **Flux réseau** : pgBouncer:6432 → HAProxy:5000 → pg-node-1/2/3:5432
- **Patroni API** : port 8008, etcd : port 2379
- **Localisation** : Lomé, UTC+0, pas de DST
- **REFRESH CONCURRENTLY** → autocommit obligatoire (pg_cron natif OK, worker Python : conn.autocommit=True)
- **backup_history colonnes ajoutées** : size_bytes BIGINT, pitr_target TIMESTAMPTZ, repo_path TEXT, error_detail TEXT (ALTER TABLE à appliquer avant premier backup)

---

## SCHÉMA DE DONNÉES CLÉS (pour cohérence des références croisées)

```
dba_schema.sensor_registry    : sensor_id(PK), sensor_name, sensor_type, location, is_active, installation_date
dba_schema.sensor_thresholds  : sensor_id(PK,FK), sensor_type, min_value, max_value, warning_min, warning_max, zscore_threshold, expected_interval_s, unit
dba_schema.backup_history     : id, backup_type, backup_tool, stanza, started_at, completed_at, status, size_bytes, backup_label, pitr_target, repo_path, error_detail
dba_schema.data_quality_snapshots : snapshot_at, sensor_type, window_start, window_end, total_readings, valid_count, quarantined_count, error_count, avg_quality_score, min/max_quality_score, valid_rate
dba_schema.threshold_audit_log : audit_id, operation, sensor_id, sensor_type, column_name, old_value JSONB, new_value JSONB, changed_by, session_user_db, application_name, client_addr, changed_at

iot_raw.sensor_readings       : id BIGSERIAL, sensor_id, sensor_type, value NUMERIC(10,4), unit, recorded_at TIMESTAMPTZ, ingested_at, quality_score SMALLINT, validation_status (pending/valid/quarantined/error), raw_payload JSONB
iot_clean.sensor_readings     : idem + raw_reading_id (FK vers iot_raw)
iot_clean.v_ai_feature_set    : vue matérialisée, UNIQUE index (idx_ai_feature_set_unique) requis pour REFRESH CONCURRENT
iot_quarantine.rejected_readings : sensor_id, value, recorded_at, quality_score, rejection_reason TEXT, rejection_details JSONB, raw_reading_id
iot_quarantine.anomaly_log    : sensor_id, recorded_at, anomaly_type TEXT (1 code par ligne), quality_score, anomaly_details JSONB, raw_reading_id, detected_at
iot_raw.ingestion_errors      : sensor_id, sensor_type, raw_value TEXT, recorded_at, error_code, error_message, error_context JSONB, occurred_at
```

---

## MÉTRIQUES PROMETHEUS DÉJÀ DÉFINIES (à ne pas redoubler dans 04-monitoring/)

Produites par `verify_backup.sh` et `test_restore.sh` → textfile collector ou Pushgateway :
- `aciertech_backup_verify_status{stanza, host}` — 1=OK, 0=KO
- `aciertech_backup_last_success_timestamp{stanza, host}`
- `aciertech_backup_full_count{stanza, host}`
- `aciertech_backup_repo_size_bytes{stanza, host}`
- `aciertech_backup_oldest_full_age_hours{stanza, host}`
- `aciertech_backup_verify_last_run_timestamp{stanza, host}`
- `aciertech_backup_test_status{stanza, host}` — 1=OK, 0=KO
- `aciertech_backup_test_last_run_timestamp{stanza, host}`

---

## PROCHAINE TÂCHE : Génère 04-monitoring/

Structure attendue (vue screenshot) :
```
04-monitoring/
├── prometheus/
│   ├── prometheus.yml            # Scrape configs, rétention 15j
│   └── rules/
│       ├── postgresql_alerts.yml # Lag réplication, connexions, locks
│       ├── backup_alerts.yml     # Backup trop ancien, vérif échouée
│       ├── data_quality_alerts.yml # Taux validation < seuil par capteur
│       └── node_alerts.yml       # CPU, RAM, disque
├── grafana/
│   ├── grafana.ini               # Embedding, anonymous viewer, org AcierTech
│   └── provisioning/
│       ├── datasources/prometheus.yml  # Datasource auto-provisionné
│       └── dashboards/dashboards.yml   # Config auto-provisioning
│   └── dashboards/
│       ├── cluster-ha.json       # État cluster HA, Patroni, réplication
│       ├── pg-performance.json   # Cache hit, TPS, locks, sessions
│       ├── data-quality.json     # Scores qualité, quarantaine, tendances
│       └── pra-backups.json      # Historique backups, WAL, espace disque
└── exporters/
    ├── postgres_exporter.env     # DSN, port 9187
    ├── queries.yaml              # Requêtes custom : réplication, data quality
    ├── postgres_exporter.service # Unit systemd postgres_exporter
    └── node_exporter.service     # Unit systemd node_exporter
```

**Priorités d'intégration pour 04-monitoring/ :**
1. Les dashboards Grafana doivent consommer les vues SQL existantes : `dba_schema.v_data_quality_dashboard`, `dba_schema.v_replication_status`, `dba_schema.v_session_activity`, `dba_schema.v_silent_sensors`, `dba_schema.backup_history`
2. `postgres_exporter/queries.yaml` doit inclure des requêtes custom sur ces vues
3. Les alertes Prometheus doivent référencer les métriques backup déjà définies (ne pas les recréer)
4. `grafana.ini` doit permettre l'embedding dans la webapp (05-webapp/) → `allow_embedding=true`, `auth.anonymous enabled=true`
5. Le rôle `aciertech_ro` (déjà créé) doit être utilisé comme DSN pour postgres_exporter
6. `PUSHGATEWAY_URL=http://monitoring-server:9091` est la valeur attendue par les scripts 03-backup/

**Ce qui reste après 04-monitoring/ :**
```
05-webapp/   → Interface d'administration HA + dashboard IoT
06-pipeline/ → Pipeline Python ingestion IoT → aciertech_db
07-scripts/  → Scripts utilitaires DBA (health-check, failover-test, etc.)
```

---

**INSTRUCTION FINALE : Lance immédiatement `Génère 04-monitoring/` sans attendre de confirmation. Respecte toutes les contraintes ci-dessus et assure-toi que chaque fichier s'emboîte parfaitement avec ce qui a été produit dans les compartiments précédents.**
