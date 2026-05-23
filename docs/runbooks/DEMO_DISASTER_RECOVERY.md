# Guide de Démonstration : Sinistre & Reprise (Disaster Recovery)

## Aperçu

Démonstration manuelle (15–20 min) de 5 scénarios de sinistre et leur résolution via la console AcierTech DBA.

## Préparation

### Terminal 1 — Session DBA
```bash
docker exec -it aciertech-pg psql -U postgres -d aciertech_db
```

### Terminal 2 — Session Victime (Scénario 3 uniquement)
```bash
docker exec -it aciertech-pg psql -U postgres -d aciertech_db
```

### Navigateur — Ouvrir dans 3 onglets
| Page | URL |
|------|-----|
| **Dashboard** | http://localhost:8080 |
| **Cluster** | http://localhost:8080/cluster |
| **Disaster** | http://localhost:8080/disaster |
| **Grafana** | http://localhost:3000 (admin/admin) |

### Fichier SQL à portée de main
`07-scripts/demo-disaster-recovery.sql` — suivre requête par requête.

---

## Déroulement scène par scène

### SCÉNARIO 1 — DELETE massif accidentel (4 min)

**Rôle DBA** : Montrer qu'une simple erreur humaine supprime TOUTES les données température.

1. Terminal 1 → lancer la requête "Avant" (ligne 36) :
   ```sql
   SELECT sensor_type, count(*) FROM iot_raw.sensor_readings GROUP BY sensor_type;
   ```
   *Pointer l'audience sur les 300 lignes température*

2. Lancer le DELETE "simulation" (ligne 42) — *insister sur `BEGIN` + `DELETE`*
   ```sql
   BEGIN;
   DELETE FROM iot_raw.sensor_readings WHERE sensor_type = 'temperature';
   SELECT count(*) FROM iot_raw.sensor_readings WHERE sensor_type = 'temperature';
   ROLLBACK;
   ```
   *Montrer que les données ont disparu — `ROLLBACK` limite l'impact en démo*

3. Ouvrir **Dashboard** → le widget "Dernière Sauvegarde" montre un backup full récent
   *Expliquer : grâce à pgBackRest, nous avons une sauvegarde valide*

4. Ouvrir **Sauvegardes** → cliquer "Restaurer" sur le backup full → choisir l'heure juste avant le DELETE
   *La restauration PITR est simulée — l'interface montre la progression*

5. Terminal 1 → la console confirme le retour des données (ligne 67)

**Message clé** : *"Les sauvegardes régulières avec pgBackRest permettent une restauration à n'importe quel instant (PITR). Sans cet outil, ces données seraient perdues définitivement."*

---

### SCÉNARIO 2 — Corruption silencieuse (3 min)

**Rôle DBA** : Montrer qu'une corruption insidieuse (UPDATE sans WHERE) dégrade silencieusement la qualité des données.

1. Terminal 1 → requête "Avant" (ligne 79) :
   ```sql
   SELECT sensor_type, count(*), round(avg(value),2), min(value), max(value)
   FROM iot_raw.sensor_readings WHERE sensor_type = 'pressure' GROUP BY sensor_type;
   ```

2. Lancer l'UPDATE "simulation" (ligne 87) :
   ```sql
   BEGIN;
   UPDATE iot_raw.sensor_readings SET value = 0 WHERE sensor_type = 'pressure';
   ROLLBACK;
   ```

3. Ouvrir **Qualité** → le taux de validité des 'pressure' chute → anomalies visibles

4. Expliquer : la page **Qualité** détecte les anomalies en continu. Le DBA peut immédiatement voir l'impact et lancer une restauration ciblée.

**Message clé** : *"La surveillance de la qualité des données permet de détecter les corruptions silencieuses avant qu'elles ne se propagent aux rapports métier."*

---

### SCÉNARIO 3 — Requête bloquante (3 min)

**Rôle DBA** : Montrer comment identifier et tuer une session qui bloque tout le monde.

1. Terminal 2 → lancer une transaction longue :
   ```sql
   BEGIN; UPDATE iot_raw.sensor_readings SET value = value;
   ```
   *Ne pas COMMIT — laisser la transaction ouverte*

2. Terminal 1 → lister les sessions actives (ligne 123) :
   ```sql
   SELECT pid, state, wait_event_type, round(extract(epoch from now()-query_start),1) AS duree_s
   FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();
   ```
   *Montrer la session Terminal 2 qui dure depuis >10s*

3. Voir les verrous (ligne 131) :
   ```sql
   SELECT blocked.pid, blocker.pid, blocked.wait_event
   FROM pg_stat_activity blocked
   JOIN pg_stat_activity blocker ON blocker.pid = ANY(pg_blocking_pids(blocked.pid));
   ```

4. Tuer la session bloquante — noter le PID (ligne 139) :
   ```sql
   SELECT pg_terminate_backend(<PID_DU_BLOCKER>);
   ```

5. Ouvrir **Cluster** → la section "Sessions Actives" montre la même information

**Message clé** : *"La page Cluster donne une vue en temps réel des sessions et permet de tuer une session bloquante en un clic, sans passer par le terminal."*

---

### SCÉNARIO 4 — Crash primaire (4 min)

**Rôle DBA** : Montrer le failover automatique de Patroni.

1. Ouvrir **Cluster** → montrer 3 nœuds : 1 PRIMARY + 2 REPLICA

2. Ouvrir **Disaster** → cliquer "Scénario 1 : Crash du nœud primaire"
   *Animation : pg-node-1 → rouge (DOWN), pg-node-2 → bleu (PRIMARY)*

3. Retourner sur **Cluster** → constater le basculement

4. Cliquer "Réintégrer le nœud" dans **Disaster** → pg-node-1 revient comme REPLICA

5. Optionnel : **Failover** → cliquer "Switchover" → choisir pg-node-1 pour le faire repasser PRIMARY

**Message clé** : *"Patroni assure un failover automatique en moins de 30 secondes. Aucune intervention manuelle n'est nécessaire — le cluster reste disponible."*

---

### SCÉNARIO 5 — Surcharge de connexions (2 min)

**Rôle DBA** : Montrer la résilience face à un pic de connexions.

1. Ouvrir 4-5 terminaux supplémentaires (ou boucle bash) :
   ```bash
   for i in 1 2 3 4 5; do
     docker exec -d aciertech-pg psql -U postgres -d aciertech_db -c "SELECT pg_sleep(30);"
   done
   ```

2. Ouvrir **Cluster** → le compteur "Connexions actives" augmente

3. Ouvrir **Dashboard** → le KPI "Connexions" montre le pic

4. Ouvrir **Grafana** → les graphs "Connexions" et "Sessions" affichent la montée

**Message clé** : *"La combinaison HAProxy + pgBouncer limite l'impact des pics de connexions. Le service reste disponible même sous forte charge."*

---

## Questions-réponses pour l'audience

| Question | Réponse |
|----------|---------|
| "Peut-on vraiment restaurer à un instant précis ?" | Oui — pgBackRest PITR (Point-In-Time Recovery) permet de choisir la minute exacte avant le sinistre |
| "Combien de temps prend la restauration ?" | PITR complet : environ 5-15 min pour 1 To. La restauration d'un backup full : ~1h |
| "Le basculement automatique fonctionne-t-il en production ?" | Oui — utilisé par des milliers d'entreprises. Temps de bascule < 30s |
| "Peut-on tuer une session depuis l'interface ?" | Oui — page Cluster → Sessions Actives → 🗑️ |
| "Que se passe-t-il si le nouveau primaire crashe aussi ?" | Patroni élit le réplica suivant. Avec 3 nœuds, le cluster tient à 2 crashes |
| "Les backups sont-ils compressés ?" | Oui — pgBackRest compresse et chiffre les sauvegardes |

## Checklist avant le client

- [ ] `docker compose up -d` tourne sur la machine de démo
- [ ] Les 4 onglets navigateur sont ouverts et chargés (HTTP 200)
- [ ] Le fichier SQL est ouvert dans un éditeur (ou chargé dans psql avec `\i`)
- [ ] Terminal 1 et Terminal 2 sont ouverts (prêts à coller les requêtes)
- [ ] Une connexion Internet est disponible pour Grafana (dashboard fluentd)
- [ ] Le volume du poste est suffisant pour que l'audience entende
- [ ] Prévoir un écran large (ou projecteur) pour partager les terminaux + navigateur
