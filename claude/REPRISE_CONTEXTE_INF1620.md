# REPRISE DE CONTEXTE — INF1620 AcierTech DBA
# Colle ce fichier entier en premier message dans la nouvelle session.
# Formulation d'amorce : "Tu es l'auteur de ce projet DBA PostgreSQL.
# Reprends exactement là où on s'est arrêtés."

## QUI TU ES
Auteur du projet INF1620 — Formation DBA PostgreSQL 16 Haute Disponibilité.
Projet : AcierTech Industries S.A., usine de transformation d'acier à Lomé,
47 capteurs IoT, système IA de maintenance prédictive existant.
Tu connais chaque fichier produit, chaque décision technique, chaque justification.

## ÉTAT D'AVANCEMENT

### ✅ TERMINÉ — 01-infra/
Patroni (3 nœuds), etcd (3 nœuds), HAProxy (ports 5000 RW / 5001 RO / 7000 stats),
pgBouncer (pool_mode=transaction, port 6432).

### ✅ TERMINÉ — 02-sql/init/
- 00_create_database.sh : crée aciertech_db, rôle aciertech_ro (absent du bootstrap
  Patroni), extensions (pg_stat_statements, pgcrypto, btree_gist), révoque PUBLIC.
- 01_run_migrations.sh : exécuteur idempotent avec migration_history, checksum SHA-256,
  single-transaction, modes --dry-run et --from VXXX.

### ✅ TERMINÉ — 02-sql/migrations/
- V001 : 4 schémas (iot_raw, iot_clean, iot_quarantine, dba_schema)
- V002 : iot_raw.sensor_readings (CHECK physiques absolus, pas de FK vers thresholds),
         iot_raw.ingestion_errors
- V003 : iot_clean.sensor_readings, vue matérialisée v_ai_feature_set (WITH NO DATA)
- V004 : iot_quarantine.rejected_readings, iot_quarantine.anomaly_log
- V005 : dba_schema.sensor_thresholds (avec trigger updated_at),
         dba_schema.backup_history, dba_schema.data_quality_snapshots,
         dba_schema.sensor_registry
- V006 : Tous les index (BRIN sur temporels, partiel sur validation_status='valid',
         UNIQUE sur v_ai_feature_set pour REFRESH CONCURRENT, GIN sur rejection_reason)
- V007 : GRANT granulaires (aciertech_app=INSERT iot_raw, aciertech_ro=SELECT iot_clean),
         REVOKE PUBLIC, ALTER ROLE SET search_path (compatible pool_mode=transaction)
- V008 : Seed 47 capteurs dans sensor_registry + sensor_thresholds
         (15 temp, 8 pression, 8 vibration, 6 courant, 5 débit, 3 vitesse, 2 épaisseur)
         Seuils ISO 10816-3 pour vibrations, zscore_threshold=2.5 sur capteurs four.

### ⏳ À FAIRE — 02-sql/functions/
3 fichiers dans cet ordre (les triggers en dépendent) :
1. fn_compute_quality_score.sql
   - Signature : fn_compute_quality_score(p_sensor_id, p_sensor_type, p_value,
     p_recorded_at) RETURNS TABLE(score SMALLINT, reason TEXT, details JSONB)
   - Lookup dans dba_schema.sensor_thresholds (PK index = très rapide)
   - Calcul Z-score sur fenêtre 1h dans iot_raw WHERE validation_status='valid'
     (index idx_raw_sr_sensor_type_time_status existe pour ça)
   - Retourne score 0-100, codes raison, détails JSON pour anomaly_log
   - SECURITY DEFINER (s'exécute avec droits postgres même appelée par aciertech_app)
   - STABLE non, VOLATILE oui (lit iot_raw qui change)
   - Pas d'advisory locks, pas de SET LOCAL → compatible pool_mode=transaction

2. fn_compute_quality_snapshot.sql
   - Insère dans dba_schema.data_quality_snapshots toutes les 5 min
   - Agrège iot_raw sur la fenêtre écoulée par sensor_type
   - Appelée par pg_cron ou worker Python

3. fn_refresh_ai_view.sql
   - REFRESH MATERIALIZED VIEW CONCURRENTLY iot_clean.v_ai_feature_set
   - Loggue la durée dans dba_schema.backup_history (type='refresh') non,
     dans une table dédiée ou juste RAISE NOTICE
   - Appelée toutes les 5 min par pg_cron

### ⏳ À FAIRE — 02-sql/triggers/
2 fichiers (après functions/) :
1. trg_validate_sensor.sql
   - BEFORE INSERT sur iot_raw.sensor_readings
   - Appelle fn_compute_quality_score()
   - Met à jour NEW.quality_score et NEW.validation_status
   - Si score >= 70 : INSERT dans iot_clean.sensor_readings
   - Si score < 70  : INSERT dans iot_quarantine.rejected_readings
                    + INSERT dans iot_quarantine.anomaly_log (une ligne par anomalie)
   - EXCEPTION block : en cas d'erreur → loggue dans iot_raw.ingestion_errors,
     NE PAS faire RAISE (ne pas bloquer l'ingestion IoT)
   - SECURITY DEFINER sur la fonction sous-jacente

2. trg_audit_changes.sql
   - Trigger AFTER UPDATE/DELETE sur dba_schema.sensor_thresholds
   - Trace les modifications de seuils (qui a changé quoi, ancienne/nouvelle valeur)
   - Table cible : dba_schema.threshold_audit_log (à créer dans ce fichier)

### ⏳ À FAIRE — 02-sql/views/
4 fichiers :
1. v_data_quality_dashboard.sql — qualité par type capteur sur 1h
2. v_replication_status.sql     — pg_stat_replication enrichie
3. v_session_activity.sql       — sessions actives + requêtes longues
4. v_silent_sensors.sql         — capteurs sans données depuis > expected_interval_s

### ⏳ À FAIRE — 02-sql/maintenance/
3 fichiers :
1. vacuum_schedule.sql      — autovacuum par table (iot_raw plus agressif)
2. pg_cron_jobs.sql         — tâches planifiées (refresh vue, snapshots, nettoyage)
3. partition_management.sql — partitionnement mensuel iot_raw (optionnel/futur)

### ⏳ À FAIRE ENSUITE — 03-backup/, 04-monitoring/, 05-webapp/, 06-pipeline/, 07-scripts/

## CONTRAINTES TECHNIQUES ABSOLUES (à respecter sur tout SQL futur)
- pool_mode=transaction → INTERDIT : advisory locks, SET LOCAL, LISTEN/NOTIFY,
  tables temporaires persistantes entre statements
- synchronous_commit=on → triggers courts, pas de boucles longues dans BEFORE INSERT
- log_min_duration_statement=1000ms → tout SQL > 1s est loggué, les index V006 couvrent
- max_connections=200, PostgreSQL 16
- Utilisateurs : postgres (superuser), aciertech_app (INSERT iot_raw),
  aciertech_ro (SELECT iot_clean), replicator (réplication physique seulement)
- Base : aciertech_db
- pgBouncer port 6432 → HAProxy port 5000 → pg-node-1/2/3 port 5432
- Patroni API sur port 8008, etcd sur port 2379

## FICHIERS DE RÉFÉRENCE JOINTS PAR L'UTILISATEUR (à redemander si besoin)
- patroni-node1.yml : config cluster Patroni complète
- pgbouncer.ini : config pooler complète
- INF1620_Architecture_DBA_AcierTech.md : document d'architecture général

## PROCHAINE COMMANDE ATTENDUE
"Génère le contenu de 02-sql/functions/"
