-- =============================================================================
-- AcierTech Industries — Migration V008
-- Objet    : Données initiales — registre et seuils des 47 capteurs IoT
-- =============================================================================
-- CONTEXTE INDUSTRIEL :
--   AcierTech est une usine de transformation de l'acier à Lomé.
--   Processus principaux : four de fusion, laminage à chaud, refroidissement,
--   découpe, contrôle qualité produit.
--
-- RÉPARTITION DES 47 CAPTEURS :
--   Température  : 15 capteurs (IDs 1-15)
--   Pression     : 8  capteurs (IDs 16-23)
--   Vibration    : 8  capteurs (IDs 24-31)
--   Courant      : 6  capteurs (IDs 32-37)
--   Débit        : 5  capteurs (IDs 38-42)
--   Vitesse      : 3  capteurs (IDs 43-45)
--   Épaisseur    : 2  capteurs (IDs 46-47)
--   TOTAL        : 47 capteurs ✓
--
-- SEUILS :
--   critical_min/max → arrêt machine recommandé si dépassé
--   warn_min/max     → surveillance renforcée requise
--   zscore_threshold → 3.0 par défaut (règle 3-sigma)
--                      2.5 pour capteurs critiques (four principal)
-- =============================================================================

-- =============================================================================
-- REGISTRE DES CAPTEURS (dba_schema.sensor_registry)
-- =============================================================================
INSERT INTO dba_schema.sensor_registry
    (sensor_id, sensor_name, sensor_type, location_zone, location_detail,
     manufacturer, model, installed_at, last_calibration, next_calibration)
VALUES
-- ---- TEMPÉRATURE (1-15) -------------------------------------------------------
(1,  'Four principal zone 1',        'temperature', 'Four de fusion',  'Zone 1 - Entrée charge',      'FLUKE', 'T3500-TC', '2022-06-15', '2024-01-10', '2024-07-10'),
(2,  'Four principal zone 2',        'temperature', 'Four de fusion',  'Zone 2 - Préchauffage',       'FLUKE', 'T3500-TC', '2022-06-15', '2024-01-10', '2024-07-10'),
(3,  'Four principal zone 3',        'temperature', 'Four de fusion',  'Zone 3 - Fusion active',      'FLUKE', 'T3500-TC', '2022-06-15', '2024-01-10', '2024-07-10'),
(4,  'Four principal zone 4',        'temperature', 'Four de fusion',  'Zone 4 - Sortie billette',    'FLUKE', 'T3500-TC', '2022-06-15', '2024-01-10', '2024-07-10'),
(5,  'Eau refroidissement four',     'temperature', 'Four de fusion',  'Circuit eau primaire',        'WIKA',  'TR10',     '2022-08-01', '2024-02-15', '2024-08-15'),
(6,  'Eau retour laminoir',          'temperature', 'Laminoir chaud',  'Circuit eau laminoir retour', 'WIKA',  'TR10',     '2022-08-01', '2024-02-15', '2024-08-15'),
(7,  'Bande acier sortie laminoir',  'temperature', 'Laminoir chaud',  'Pyromètre sortie cage 1',     'RAYTEK','MI3-LT',   '2022-09-10', '2024-01-20', '2024-07-20'),
(8,  'Bande acier cage 2',           'temperature', 'Laminoir chaud',  'Pyromètre sortie cage 2',     'RAYTEK','MI3-LT',   '2022-09-10', '2024-01-20', '2024-07-20'),
(9,  'Table de refroidissement 1',   'temperature', 'Refroidissement', 'Section refroidissement A',   'WIKA',  'TR10',     '2023-01-05', '2024-03-01', '2024-09-01'),
(10, 'Table de refroidissement 2',   'temperature', 'Refroidissement', 'Section refroidissement B',   'WIKA',  'TR10',     '2023-01-05', '2024-03-01', '2024-09-01'),
(11, 'Palier moteur laminoir 1',     'temperature', 'Laminoir chaud',  'Palier côté commande M1',     'SKF',   'TMBH1',    '2022-11-20', '2024-01-15', '2024-07-15'),
(12, 'Palier moteur laminoir 2',     'temperature', 'Laminoir chaud',  'Palier côté libre M1',        'SKF',   'TMBH1',    '2022-11-20', '2024-01-15', '2024-07-15'),
(13, 'Armoire électrique principale','temperature', 'Distribution',    'Tableau HTA bâtiment A',      'FLUKE', 'TIS10',    '2023-03-10', '2024-02-01', '2024-08-01'),
(14, 'Ambiance atelier fusion',      'temperature', 'Four de fusion',  'Sonde ambiante hall fusion',  'VAISALA','HMT330',  '2023-03-10', '2024-02-01', '2024-08-01'),
(15, 'Ambiance atelier laminoir',    'temperature', 'Laminoir chaud',  'Sonde ambiante hall laminoir','VAISALA','HMT330',  '2023-03-10', '2024-02-01', '2024-08-01'),

-- ---- PRESSION (16-23) --------------------------------------------------------
(16, 'Hydraulique presse principale','pressure',    'Presse',          'Circuit HP presse 1200T',     'WIKA',  'S-20',     '2022-06-20', '2024-01-08', '2024-07-08'),
(17, 'Hydraulique clamping cage 1',  'pressure',    'Laminoir chaud',  'Vérins serrage cage 1',       'WIKA',  'S-20',     '2022-06-20', '2024-01-08', '2024-07-08'),
(18, 'Hydraulique clamping cage 2',  'pressure',    'Laminoir chaud',  'Vérins serrage cage 2',       'WIKA',  'S-20',     '2022-07-01', '2024-01-08', '2024-07-08'),
(19, 'Pneumatique outillage four',   'pressure',    'Four de fusion',  'Réseau air comprimé four',    'KELLER','PAA-33X',  '2022-08-15', '2024-02-10', '2024-08-10'),
(20, 'Pneumatique ligne découpe',    'pressure',    'Découpe',         'Réseau air outils découpe',   'KELLER','PAA-33X',  '2022-08-15', '2024-02-10', '2024-08-10'),
(21, 'Eau circuit primaire four',    'pressure',    'Four de fusion',  'Pression eau refroidissement','WIKA',  'S-11',     '2022-09-01', '2024-01-25', '2024-07-25'),
(22, 'Eau circuit laminoir',         'pressure',    'Laminoir chaud',  'Pression eau laminage',       'WIKA',  'S-11',     '2022-09-01', '2024-01-25', '2024-07-25'),
(23, 'Gaz naturel alimentation four','pressure',    'Four de fusion',  'Pression gaz brûleurs',       'WIKA',  'S-21',     '2022-10-01', '2024-01-20', '2024-07-20'),

-- ---- VIBRATION (24-31) -------------------------------------------------------
(24, 'Moteur laminoir cage 1 axial', 'vibration',   'Laminoir chaud',  'Moteur principal M1 axial',   'SKF',   'CMSS2200', '2022-06-25', '2024-01-12', '2024-07-12'),
(25, 'Moteur laminoir cage 1 radial','vibration',   'Laminoir chaud',  'Moteur principal M1 radial',  'SKF',   'CMSS2200', '2022-06-25', '2024-01-12', '2024-07-12'),
(26, 'Moteur laminoir cage 2 axial', 'vibration',   'Laminoir chaud',  'Moteur principal M2 axial',   'SKF',   'CMSS2200', '2022-07-05', '2024-01-12', '2024-07-12'),
(27, 'Moteur laminoir cage 2 radial','vibration',   'Laminoir chaud',  'Moteur principal M2 radial',  'SKF',   'CMSS2200', '2022-07-05', '2024-01-12', '2024-07-12'),
(28, 'Pompe eau circuit primaire',   'vibration',   'Utilitaires',     'Pompe refroidissement P1',    'PRFTCH','VB-8',     '2022-08-10', '2024-02-05', '2024-08-05'),
(29, 'Pompe eau circuit secondaire', 'vibration',   'Utilitaires',     'Pompe refroidissement P2',    'PRFTCH','VB-8',     '2022-08-10', '2024-02-05', '2024-08-05'),
(30, 'Réducteur laminoir cage 1',    'vibration',   'Laminoir chaud',  'Boîte réducteur R1',          'BRÜEL', '4507B',    '2022-09-15', '2024-01-18', '2024-07-18'),
(31, 'Réducteur laminoir cage 2',    'vibration',   'Laminoir chaud',  'Boîte réducteur R2',          'BRÜEL', '4507B',    '2022-09-15', '2024-01-18', '2024-07-18'),

-- ---- COURANT ÉLECTRIQUE (32-37) ----------------------------------------------
(32, 'Moteur laminoir cage 1',       'current',     'Laminoir chaud',  'Pupitre MCC moteur M1',       'CHNT',  'DTSF-A',   '2022-06-30', '2024-01-06', '2024-07-06'),
(33, 'Moteur laminoir cage 2',       'current',     'Laminoir chaud',  'Pupitre MCC moteur M2',       'CHNT',  'DTSF-A',   '2022-06-30', '2024-01-06', '2024-07-06'),
(34, 'Brûleurs four principal',      'current',     'Four de fusion',  'Alimentation brûleurs B1-B4', 'CHNT',  'DTSF-A',   '2022-07-15', '2024-01-15', '2024-07-15'),
(35, 'Pompe hydraulique principale', 'current',     'Presse',          'Moteur pompe HP',             'CHNT',  'DTSF-A',   '2022-07-15', '2024-01-15', '2024-07-15'),
(36, 'Compresseur air ateliers',     'current',     'Utilitaires',     'Compresseur Atlas Copco',     'CHNT',  'DTSF-B',   '2022-08-20', '2024-02-20', '2024-08-20'),
(37, 'Centrale hydraulique laminoir','current',     'Laminoir chaud',  'Moteur centrale hydraulique', 'CHNT',  'DTSF-A',   '2022-08-20', '2024-02-20', '2024-08-20'),

-- ---- DÉBIT (38-42) -----------------------------------------------------------
(38, 'Eau primaire four',            'flow',        'Four de fusion',  'Débitmètre eau refroid. four','ENDRESS','PROMAG W',  '2022-09-20', '2024-01-22', '2024-07-22'),
(39, 'Eau laminoir cage 1',          'flow',        'Laminoir chaud',  'Eau de laminage cage 1',      'ENDRESS','PROMAG W',  '2022-09-20', '2024-01-22', '2024-07-22'),
(40, 'Eau laminoir cage 2',          'flow',        'Laminoir chaud',  'Eau de laminage cage 2',      'ENDRESS','PROMAG W',  '2022-10-01', '2024-01-22', '2024-07-22'),
(41, 'Gaz naturel four',             'flow',        'Four de fusion',  'Débitmètre gaz brûleurs',     'YOKOG', 'AXF',       '2022-10-10', '2024-02-01', '2024-08-01'),
(42, 'Eau table refroidissement',    'flow',        'Refroidissement', 'Eau rampe refroidissement',   'ENDRESS','PROMAG W',  '2022-10-15', '2024-02-01', '2024-08-01'),

-- ---- VITESSE ROTATION (43-45) ------------------------------------------------
(43, 'Vitesse cage laminoir 1',      'speed',       'Laminoir chaud',  'Encodeur cage 1 - côté entrée','HEIDNH','RON785',   '2022-11-01', '2024-01-10', '2024-07-10'),
(44, 'Vitesse cage laminoir 2',      'speed',       'Laminoir chaud',  'Encodeur cage 2 - côté sortie','HEIDNH','RON785',   '2022-11-01', '2024-01-10', '2024-07-10'),
(45, 'Vitesse table à rouleaux',     'speed',       'Refroidissement', 'Encodeur table à rouleaux',   'HEIDNH','ROD426',   '2022-11-15', '2024-01-10', '2024-07-10'),

-- ---- ÉPAISSEUR PRODUIT (46-47) -----------------------------------------------
(46, 'Épaissimètre cage 1 sortie',  'thickness',   'Laminoir chaud',  'Jauge rayons X cage 1',       'SIKORA','X-RAY 6000','2023-01-20', '2024-02-15', '2024-08-15'),
(47, 'Épaissimètre cage 2 sortie',  'thickness',   'Laminoir chaud',  'Jauge rayons X cage 2',       'SIKORA','X-RAY 6000','2023-01-20', '2024-02-15', '2024-08-15')

ON CONFLICT (sensor_id) DO UPDATE SET
    sensor_name      = EXCLUDED.sensor_name,
    location_zone    = EXCLUDED.location_zone,
    location_detail  = EXCLUDED.location_detail,
    manufacturer     = EXCLUDED.manufacturer,
    model            = EXCLUDED.model;

-- =============================================================================
-- SEUILS OPÉRATIONNELS (dba_schema.sensor_thresholds)
-- Unités : °C, bar, mm/s (vibration ISO 10816), A, L/min, tr/min, mm
-- =============================================================================
INSERT INTO dba_schema.sensor_thresholds
    (sensor_id, sensor_type, sensor_name, location, unit,
     warn_min, warn_max, critical_min, critical_max,
     zscore_threshold, expected_interval_s)
VALUES

-- ---- TEMPÉRATURE FOUR (seuils critiques stricts, zscore 2.5) ----------------
-- Température four : une montée brutale = risque matériau ou sécurité
(1,  'temperature', 'Four principal zone 1',       'Four de fusion',  '°C',    900,  1200,  800,  1350,  2.5, 30),
(2,  'temperature', 'Four principal zone 2',       'Four de fusion',  '°C',   1000,  1250,  900,  1400,  2.5, 30),
(3,  'temperature', 'Four principal zone 3',       'Four de fusion',  '°C',   1100,  1350,  950,  1500,  2.5, 30),
(4,  'temperature', 'Four principal zone 4',       'Four de fusion',  '°C',    950,  1280,  850,  1430,  2.5, 30),

-- Eau refroidissement four : une surchauffe = risque d'ébullition circuit fermé
(5,  'temperature', 'Eau refroidissement four',    'Circuit primaire', '°C',    40,    55,   20,    65,  3.0, 60),
(6,  'temperature', 'Eau retour laminoir',         'Circuit laminoir', '°C',    35,    50,   15,    60,  3.0, 60),

-- Pyrométrie bande acier : fenêtre de laminage stricte
(7,  'temperature', 'Bande acier sortie cage 1',   'Laminoir chaud',  '°C',    900,  1150,  800,  1250,  2.5, 30),
(8,  'temperature', 'Bande acier cage 2',          'Laminoir chaud',  '°C',    780,  1050,  680,  1150,  2.5, 30),

-- Tables de refroidissement : descente progressive obligatoire
(9,  'temperature', 'Table refroidissement 1',     'Refroidissement', '°C',    200,   650,  100,   750,  3.0, 60),
(10, 'temperature', 'Table refroidissement 2',     'Refroidissement', '°C',    100,   450,   50,   550,  3.0, 60),

-- Paliers moteur : norme ISO 10816 recommande arrêt > 100°C
(11, 'temperature', 'Palier moteur laminoir 1',    'Laminoir chaud',  '°C',     60,    85,   40,   100,  3.0, 60),
(12, 'temperature', 'Palier moteur laminoir 2',    'Laminoir chaud',  '°C',     60,    85,   40,   100,  3.0, 60),

-- Armoire électrique : dégagement thermique critique
(13, 'temperature', 'Armoire électrique princ.',   'Distribution',    '°C',     35,    55,   10,    65,  3.0, 120),

-- Ambiance ateliers : confort + sécurité opérateurs
(14, 'temperature', 'Ambiance atelier fusion',     'Four de fusion',  '°C',     30,    45,   15,    55,  3.0, 300),
(15, 'temperature', 'Ambiance atelier laminoir',   'Laminoir chaud',  '°C',     28,    42,   10,    50,  3.0, 300),

-- ---- PRESSION ---------------------------------------------------------------
-- Hydraulique haute pression : sécurité des vérins (pression nominale 180 bar)
(16, 'pressure', 'Hydraulique presse principale',  'Presse',          'bar',   140,   185,   80,   200,  3.0, 30),
(17, 'pressure', 'Hydraulique clamping cage 1',    'Laminoir chaud',  'bar',   120,   165,   60,   180,  3.0, 30),
(18, 'pressure', 'Hydraulique clamping cage 2',    'Laminoir chaud',  'bar',   120,   165,   60,   180,  3.0, 30),

-- Pneumatique : réseau air comprimé (pression nominale 7 bar)
(19, 'pressure', 'Pneumatique outillage four',     'Four de fusion',  'bar',     5.5,   7.5,  4.0,   9.0, 3.0, 60),
(20, 'pressure', 'Pneumatique ligne découpe',      'Découpe',         'bar',     5.5,   7.5,  4.0,   9.0, 3.0, 60),

-- Eau circuit fermé : pression nominale 4-6 bar
(21, 'pressure', 'Eau circuit primaire four',      'Four de fusion',  'bar',     3.5,   6.5,  2.0,   8.0, 3.0, 60),
(22, 'pressure', 'Eau circuit laminoir',           'Laminoir chaud',  'bar',     3.0,   6.0,  1.5,   7.5, 3.0, 60),

-- Gaz naturel : pression réseau brûleurs (critique sécurité incendie)
(23, 'pressure', 'Gaz naturel alimentation four',  'Four de fusion',  'bar',     0.2,   0.5,  0.1,   0.8, 2.5, 30),

-- ---- VIBRATION (ISO 10816-3 classe III : machines 15-75 kW) -----------------
-- Zone A : 0-2.3 mm/s (neuf)
-- Zone B : 2.3-4.5 mm/s (acceptable longue durée)
-- Zone C : 4.5-7.1 mm/s (surveillance renforcée)
-- Zone D : >7.1 mm/s (arrêt machine)
(24, 'vibration', 'Moteur laminoir cage 1 axial',  'Laminoir chaud',  'mm/s',   NULL,   4.5, NULL,   7.1, 2.5, 30),
(25, 'vibration', 'Moteur laminoir cage 1 radial', 'Laminoir chaud',  'mm/s',   NULL,   4.5, NULL,   7.1, 2.5, 30),
(26, 'vibration', 'Moteur laminoir cage 2 axial',  'Laminoir chaud',  'mm/s',   NULL,   4.5, NULL,   7.1, 2.5, 30),
(27, 'vibration', 'Moteur laminoir cage 2 radial', 'Laminoir chaud',  'mm/s',   NULL,   4.5, NULL,   7.1, 2.5, 30),
(28, 'vibration', 'Pompe eau circuit primaire',    'Utilitaires',     'mm/s',   NULL,   3.5, NULL,   7.1, 3.0, 60),
(29, 'vibration', 'Pompe eau circuit secondaire',  'Utilitaires',     'mm/s',   NULL,   3.5, NULL,   7.1, 3.0, 60),
(30, 'vibration', 'Réducteur laminoir cage 1',     'Laminoir chaud',  'mm/s',   NULL,   4.5, NULL,   7.1, 2.5, 30),
(31, 'vibration', 'Réducteur laminoir cage 2',     'Laminoir chaud',  'mm/s',   NULL,   4.5, NULL,   7.1, 2.5, 30),

-- ---- COURANT ÉLECTRIQUE (en Ampères, nominal variable par équipement) -------
-- Seuil critique = 95% du courant nominal (protection thermique moteur)
-- Seuil warn = 85% du courant nominal
-- Moteurs laminoir : 450A nominal
(32, 'current', 'Moteur laminoir cage 1',          'Laminoir chaud',  'A',      50,   385,   20,   430,  3.0, 30),
(33, 'current', 'Moteur laminoir cage 2',          'Laminoir chaud',  'A',      50,   385,   20,   430,  3.0, 30),
-- Brûleurs four : 120A nominal
(34, 'current', 'Brûleurs four principal',         'Four de fusion',  'A',      10,   102,    5,   115,  3.0, 30),
-- Pompe hydraulique : 75A nominal
(35, 'current', 'Pompe hydraulique principale',    'Presse',          'A',      10,    64,    5,    72,  3.0, 30),
-- Compresseur : 90A nominal
(36, 'current', 'Compresseur air ateliers',        'Utilitaires',     'A',      10,    77,    5,    86,  3.0, 60),
-- Centrale hydraulique : 55A nominal
(37, 'current', 'Centrale hydraulique laminoir',   'Laminoir chaud',  'A',      10,    47,    5,    53,  3.0, 30),

-- ---- DÉBIT (en L/min) -------------------------------------------------------
-- Débit eau refroidissement four : min critique (panne pompe) et max warn (fuite)
(38, 'flow', 'Eau primaire four',                  'Four de fusion',  'L/min',  800,  1800,  500,  2200,  3.0, 30),
(39, 'flow', 'Eau laminoir cage 1',                'Laminoir chaud',  'L/min',  400,  1200,  200,  1500,  3.0, 30),
(40, 'flow', 'Eau laminoir cage 2',                'Laminoir chaud',  'L/min',  400,  1200,  200,  1500,  3.0, 30),
-- Gaz naturel en Nm3/h (converti L/min pour homogénéité)
(41, 'flow', 'Gaz naturel four',                   'Four de fusion',  'Nm3/h',   50,   350,   20,   420,  2.5, 30),
-- Table refroidissement eau
(42, 'flow', 'Eau table refroidissement',          'Refroidissement', 'L/min', 1000,  3000,  500,  4000,  3.0, 60),

-- ---- VITESSE ROTATION (en tr/min) -------------------------------------------
-- Vitesse de laminage variable selon la campagne (réglée par l'opérateur)
-- Seuils larges : le warn/critical dépend de la commande opérateur
-- Ici on surveille surtout les valeurs hors plage physique
(43, 'speed', 'Vitesse cage laminoir 1',           'Laminoir chaud',  'tr/min',  10,   800,   NULL, 1000,  3.0, 30),
(44, 'speed', 'Vitesse cage laminoir 2',           'Laminoir chaud',  'tr/min',  10,  1200,   NULL, 1500,  3.0, 30),
(45, 'speed', 'Vitesse table à rouleaux',          'Refroidissement', 'tr/min',   5,   400,   NULL,  500,  3.0, 30),

-- ---- ÉPAISSEUR (en mm) -------------------------------------------------------
-- Épaisseur produit fini : tolérance ±0.05mm sur cible de 3-20mm selon commande
-- Les seuils ici sont larges (plage de production possible) ;
-- la tolérance fine est gérée côté commande numérique, pas dans ce pipeline
(46, 'thickness', 'Épaissimètre cage 1 sortie',   'Laminoir chaud',  'mm',     2.5,  25.0,   1.5,  30.0,  2.5, 30),
(47, 'thickness', 'Épaissimètre cage 2 sortie',   'Laminoir chaud',  'mm',     2.5,  25.0,   1.5,  30.0,  2.5, 30)

ON CONFLICT (sensor_id, sensor_type) DO UPDATE SET
    warn_min            = EXCLUDED.warn_min,
    warn_max            = EXCLUDED.warn_max,
    critical_min        = EXCLUDED.critical_min,
    critical_max        = EXCLUDED.critical_max,
    zscore_threshold    = EXCLUDED.zscore_threshold,
    expected_interval_s = EXCLUDED.expected_interval_s,
    updated_at          = NOW();

-- =============================================================================
-- VÉRIFICATION DU SEED
-- =============================================================================
DO $$
DECLARE
    v_registry_count  INTEGER;
    v_threshold_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_registry_count  FROM dba_schema.sensor_registry;
    SELECT COUNT(*) INTO v_threshold_count FROM dba_schema.sensor_thresholds;

    IF v_registry_count <> 47 THEN
        RAISE EXCEPTION 'ERREUR V008 : sensor_registry contient % lignes, attendu 47',
            v_registry_count;
    END IF;

    IF v_threshold_count <> 47 THEN
        RAISE EXCEPTION 'ERREUR V008 : sensor_thresholds contient % lignes, attendu 47',
            v_threshold_count;
    END IF;

    RAISE NOTICE 'V008 : seed terminé — % capteurs dans le registre, % configurations de seuils.',
        v_registry_count, v_threshold_count;

    -- Vérification répartition par type
    RAISE NOTICE 'Répartition : %',
        (SELECT STRING_AGG(sensor_type || '=' || cnt::TEXT, ', ' ORDER BY sensor_type)
         FROM (
             SELECT sensor_type, COUNT(*) AS cnt
             FROM dba_schema.sensor_registry
             GROUP BY sensor_type
         ) t);
END $$;