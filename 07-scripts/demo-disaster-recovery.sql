-- =============================================================================
-- AcierTech DBA Platform — Démonstration Sinistre & Reprise
-- =============================================================================
-- À exécuter manuellement, requête par requête, pendant la présentation.
-- Le DBA commente chaque étape devant l'audience.
--
-- Connexion :
--   docker exec -it aciertech-pg psql -U postgres -d aciertech_db
-- =============================================================================

-- =============================================================================
-- PRÉPARATIFS : Ouvrir 2 terminaux
-- =============================================================================
-- Terminal 1 (DBA) :
--   docker exec -it aciertech-pg psql -U postgres -d aciertech_db
-- Terminal 2 (victime / observateur) :
--   docker exec -it aciertech-pg psql -U postgres -d aciertech_db
--
-- Ouvrir aussi le navigateur sur http://localhost:8080 (webapp)
-- et http://localhost:3000 (Grafana).
-- =============================================================================

-- =============================================================================
-- SCÉNARIO 1 : Suppression massive accidentelle
-- =============================================================================
-- Contexte : Un opérateur SQL exécute un DELETE sans WHERE sur les lectures
--           de capteurs de température. Toutes les données température sont
--           perdues. Le DBA doit les restaurer via PITR.
-- =============================================================================

-- 1a) AVANT : Vérifier l'état des données température
SELECT sensor_type, count(*) AS total
FROM iot_raw.sensor_readings
WHERE sensor_type = 'temperature'
GROUP BY sensor_type;

-- 1b) SIMULATION DU SINISTRE : DELETE massif
BEGIN;
DELETE FROM iot_raw.sensor_readings
WHERE sensor_type = 'temperature';
-- Compter les lignes supprimées
SELECT count(*) AS lignes_supprimees
FROM iot_raw.sensor_readings
WHERE sensor_type = 'temperature';
ROLLBACK;  -- ROLLBACK pour la démo ! (en vrai ce serait COMMIT...)

-- 1c) DOMMAGES (après COMMIT réel) : les données température ont disparu
-- On le simule avec un ROLLBACK, mais montrer l'impact :
SELECT sensor_type, count(*) AS total
FROM iot_raw.sensor_readings
GROUP BY sensor_type;

-- 1d) REPRISE VIA PITR — Simulation dans l'interface web
-- Ouvrir http://localhost:8080/backups
-- Cliquer sur "Restaurer" sur un backup full récent
-- Choisir l'heure juste avant le DELETE
-- Lancer la restauration PITR (simulée par le mock)
--
→ Étape suivante : basculer sur le navigateur ←

-- 1e) VÉRIFICATION : retour sur la console
-- Après PITR, les données température sont revenues
SELECT 'PITR OK — Données restaurées.' AS resultat;

-- =============================================================================

-- =============================================================================
-- SCÉNARIO 2 : Corruption silencieuse (UPDATE sans WHERE)
-- =============================================================================
-- Contexte : Un UPDATE sans WHERE modifie toutes les valeurs de pression
--           en les fixant à zéro. La qualité des données s'effondre.
--           Le DBA doit identifier et corriger.
-- =============================================================================

-- 2a) AVANT : Qualité des relevés de pression
SELECT
    sensor_type,
    count(*) AS total,
    round(avg(value)::numeric, 2) AS valeur_moyenne,
    min(value) AS valeur_min,
    max(value) AS valeur_max
FROM iot_raw.sensor_readings
WHERE sensor_type = 'pressure'
GROUP BY sensor_type;

-- 2b) SIMULATION : UPDATE massif sans WHERE
BEGIN;
UPDATE iot_raw.sensor_readings
SET value = 0
WHERE sensor_type = 'pressure';
-- Vérifier les dégâts
SELECT sensor_type, count(*) FILTER (WHERE value = 0) AS valeurs_zero
FROM iot_raw.sensor_readings
WHERE sensor_type = 'pressure'
GROUP BY sensor_type;
ROLLBACK;  -- ROLLBACK pour démo

-- 2c) IMPACT VISIBLE DANS LE TABLEAU DE BORD QUALITÉ
-- Ouvrir http://localhost:8080/quality
-- La colonne "valid_rate_pct" chute à ~0% pour 'pressure'
-- Des anomalies apparaissent dans la liste
--
→ Étape suivante : basculer sur le navigateur ←

-- 2d) REPRISE : Via la page Qualité
-- 1. Page Qualité → repérer le taux de validité effondré
-- 2. Page Sauvegardes → restaurer les données corrompues
-- 3. Vérifier le retour à la normale

-- =============================================================================

-- =============================================================================
-- SCÉNARIO 3 : Requête bloquante / Conflit d'accès
-- =============================================================================
-- Contexte : Une requête longue (UPDATE transaction) bloque toutes les
--           autres sessions. Les capteurs n'arrivent plus à insérer.
--           Le DBA doit identifier et tuer la session bloquante.
-- =============================================================================

-- Terminal 1 (DBA) :
-- =================
-- 3a) Identifier les sessions actives
SELECT pid, usename, state, wait_event_type, wait_event,
       round(extract(epoch from now() - query_start)::numeric, 1) AS duree_s,
       left(query, 80) AS requete
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid()
ORDER BY query_start;

-- 3b) Voir les verrous actifs
SELECT blocked.pid AS session_bloquee,
       blocker.pid AS session_bloquante,
       left(blocker.query, 50) AS requete_bloquante,
       blocked.wait_event_type,
       blocked.wait_event
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid));

-- 3c) TUER la session bloquante (si nécessaire)
-- SELECT pg_terminate_backend(<PID_BLOQUANT>);

-- Terminal 2 (victime) :
-- =====================
-- Pour simuler, ouvrir un second terminal et lancer :
--   BEGIN; UPDATE iot_raw.sensor_readings SET value = value; -- ne pas COMMIT

-- 3d) Résolution via l'interface web
-- Ouvrir http://localhost:8080/cluster
-- → Section Sessions actives : voir la session longue
-- → Possible de tuer la session depuis l'interface

-- =============================================================================

-- =============================================================================
-- SCÉNARIO 4 : Crash du nœud primaire
-- =============================================================================
-- Contexte : Le nœud primaire PostgreSQL plante. Patroni détecte l'arrêt
--           et élit automatiquement un nouveau primaire. Aucune perte de
--           données. Le DBA constate le failover dans la webapp.
-- =============================================================================

-- 4a) ÉTAT INITIAL du cluster
-- Ouvrir http://localhost:8080/cluster
-- → Voir 3 nœuds : 1 PRIMARY (pg-node-1) + 2 REPLICA
--
→ Étape suivante : basculer sur le navigateur ←

-- 4b) SIMULATION DU CRASH
-- Dans la page http://localhost:8080/disaster
-- → Cliquer sur "Scénario 1 : Crash du primaire"
-- → Observer l'animation : le nœud pg-node-1 passe en rouge
-- → Patroni élit automatiquement pg-node-2 comme nouveau PRIMARY
-- → HAProxy redirige les connexions vers le nouveau primaire

-- 4c) VÉRIFIER LE FAILOVER
-- Dans http://localhost:8080/cluster
-- → pg-node-1 : DOWN (rouge)
-- → pg-node-2 : PRIMARY (bleu)
-- → pg-node-3 : REPLICA (violet)
-- Le temps de bascule : < 30 secondes

-- 4d) REPRISE DU NŒUD TOMBÉ
-- Dans http://localhost:8080/disaster
-- → Cliquer sur "Réintégrer le nœud"
-- → pg-node-1 revient en ligne comme REPLICA
-- → Le cluster est de nouveau healthy

-- 4e) SWITCHBACK (optionnel)
-- Dans http://localhost:8080/failover
-- → Cliquer sur "Switchover"
-- → Choisir pg-node-1 comme nouvelle cible
-- → pg-node-1 redevient PRIMARY

-- =============================================================================

-- =============================================================================
-- SCÉNARIO 5 : Surcharge de connexions / Attaque par déni de service
-- =============================================================================
-- Contexte : Un pic de connexions simultanées sature PostgreSQL.
--           pgBouncer et HAProxy limitent les dégâts en poolant et
--           en rejetant les connexions excessives.
-- =============================================================================

-- 5a) CONNEXIONS ACTIVES
SELECT count(*) AS connexions_actives,
       count(*) FILTER (WHERE state = 'active') AS requetes_en_cours,
       count(*) FILTER (WHERE state = 'idle') AS connexions_inactives
FROM pg_stat_activity
WHERE backend_type = 'client backend';

-- 5b) SIMULATION D'UNE Surcharge (ouvrir plusieurs terminaux)
-- Dans chaque terminal, lancer :
--   docker exec -it aciertech-pg psql -U postgres -d aciertech_db -c "SELECT pg_sleep(30);"
-- Après 5-6 lancements, ouvrir http://localhost:8080/cluster
-- → Les connexions actives augmentent
-- → HAProxy maintient le service

-- 5c) VÉRIFICATION
-- Le KPI "Connexions actives" sur http://localhost:8080/ augmente
-- Grafana montre le pic de connexions

-- =============================================================================

-- =============================================================================
-- RÉSUMÉ DE LA DÉMONSTRATION
-- =============================================================================
-- +--------------------------+----------------------------------------------+
-- | Sinistre                 | Solution AcierTech                           |
-- +--------------------------+----------------------------------------------+
-- | DELETE massif            | PITR via pgBackRest (page Sauvegardes)       |
-- | Corruption données       | Qualité + Restauration (page Qualité)        |
-- | Requête bloquante        | Détection + Kill session (page Cluster)      |
-- | Crash primaire           | Failover automatique Patroni (page Cluster)  |
-- | Saturation connexions    | HAProxy + pgBouncer (page Cluster)           |
-- +--------------------------+----------------------------------------------+
-- =============================================================================
-- FIN DE LA DÉMONSTRATION
-- =============================================================================
