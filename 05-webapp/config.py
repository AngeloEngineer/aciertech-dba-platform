# =============================================================================
# CONFIG — AcierTech DBA Console · 05-webapp/config.py
#
# Centralise TOUS les paramètres de connexion aux composants du projet :
#   PostgreSQL 16 · Patroni :8008 · HAProxy :5000/:5001/:7000
#   pgBouncer :6432 · etcd :2379 · Prometheus :9090 · Grafana :3000
#   Pushgateway :9091 · pgBackRest CLI
#
# Toutes les valeurs sont surchargeable via variables d'environnement
# ou fichier .env (copier .env.example → .env et adapter).
#
# Convention DSN :
#   dsn_ro    → aciertech_ro via HAProxy :5001 (RO) pour les vues SQL
#   dsn_admin → postgres    via HAProxy :5000 (RW) pour les opérations admin
#   dsn_direct_node(n) → connexion directe sans HAProxy (pour diagnostics)
# =============================================================================

from __future__ import annotations

from functools import cached_property
from typing import Annotated

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """
    Paramètres de l'application. Priorité de lecture :
    1. Variables d'environnement (ex: PG_PASSWORD_RO=xxx)
    2. Fichier .env à la racine de 05-webapp/
    3. Valeurs par défaut ci-dessous
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ── Application ───────────────────────────────────────────────────────────
    app_name: str    = "AcierTech DBA Console"
    app_version: str = "1.0.0"
    app_env: str     = "production"           # production | development
    debug: bool      = False
    log_level: str   = "info"

    # ── PostgreSQL 16 — Hôtes ─────────────────────────────────────────────────
    # La webapp se connecte toujours VIA HAProxy pour bénéficier du routage
    # automatique primary/replica, sauf pour les diagnostics node-by-node.
    pg_haproxy_host: str = "pg-node-1"
    pg_haproxy_port_rw:  int = 5000           # HAProxy RW → primaire Patroni
    pg_haproxy_port_ro:  int = 5001           # HAProxy RO → standbys Patroni
    pg_port_direct:      int = 5432           # Port PG natif (connexions directes)

    # ── PostgreSQL 16 — Base & rôles ──────────────────────────────────────────
    pg_database: str = "aciertech_db"

    # aciertech_ro : SELECT sur iot_clean.*, dba_schema.v_*, pg_monitor
    # Créé en V007 — utilisé pour TOUTES les lectures de vues/dashboard
    pg_user_ro:       str = "aciertech_ro"
    pg_password_ro:   str = Field(default="", repr=False)

    # postgres : superuser — réservé aux opérations admin (VACUUM manuel, etc.)
    pg_user_admin:    str = "postgres"
    pg_password_admin: str = Field(default="", repr=False)

    # aciertech_app : INSERT sur iot_raw — non utilisé par la webapp (ingestion IoT)
    pg_user_app:      str = "aciertech_app"
    pg_password_app:  str = Field(default="", repr=False)

    # ── Pool de connexions ────────────────────────────────────────────────────
    # La webapp est un outil admin (faible concurrence) → pools modestes
    pg_pool_min_size:     int = 2
    pg_pool_max_size:     int = 10
    pg_pool_timeout:      float = 30.0         # Attente max pour obtenir une connexion
    pg_pool_open_timeout: float = 2.0          # Timeout max pour ouvrir le pool au démarrage
    pg_connect_timeout:   int   = 5            # Timeout connexion TCP
    pg_statement_timeout: int   = 30000        # 30s max par requête webapp (ms)

    # ── Nœuds Patroni (IP ou hostname) ────────────────────────────────────────
    pg_node1_host: str = "pg-node-1"           # 192.168.10.11
    pg_node2_host: str = "pg-node-2"           # 192.168.10.12
    pg_node3_host: str = "pg-node-3"           # 192.168.10.13

    # ── Patroni REST API ──────────────────────────────────────────────────────
    # Port 8008 sur chaque nœud — pas d'authentification par défaut
    # Endpoints utilisés :
    #   GET  /patroni       → état cluster complet
    #   GET  /health        → statut du nœud local
    #   GET  /leader        → 200 si le nœud est leader, 503 sinon
    #   GET  /replica       → 200 si le nœud est standby
    #   GET  /cluster       → liste des membres
    #   POST /switchover    → basculement contrôlé
    #   POST /failover      → failover forcé
    #   POST /reinitialize  → réinitialisation standby
    #   PATCH /config       → pause/resume auto-failover
    patroni_port: int = 8008
    patroni_cluster_name: str = "aciertech"
    patroni_timeout: float = 5.0               # Timeout HTTP vers l'API Patroni

    # ── HAProxy stats ─────────────────────────────────────────────────────────
    # Port 7000 — stats page CSV (backend + frontend + server metrics)
    haproxy_stats_host:     str = "pg-node-1"
    haproxy_stats_port:     int = 7000
    haproxy_stats_user:     str = "admin"
    haproxy_stats_password: str = Field(default="admin", repr=False)
    # URL CSV : http://pg-node-1:7000/stats;csv
    # Backends attendus : postgresql-primary (port 5000), postgresql-replica (port 5001)

    # ── etcd ─────────────────────────────────────────────────────────────────
    # 3 membres — port 2379 (client), 2380 (peer), 2381 (metrics)
    etcd_port_client:  int = 2379
    etcd_port_metrics: int = 2381
    etcd_timeout:      float = 3.0

    # ── Prometheus ────────────────────────────────────────────────────────────
    # Endpoints utilisés :
    #   GET /api/v1/query          → instant query
    #   GET /api/v1/query_range    → range query (graphes)
    #   GET /api/v1/alerts         → alertes actives
    #   GET /api/v1/rules          → règles d'alerte
    prometheus_host:    str = "monitoring-server"
    prometheus_port:    int = 9090
    prometheus_timeout: float = 10.0

    # ── Grafana ───────────────────────────────────────────────────────────────
    # allow_embedding=true, auth.anonymous enabled=true (grafana.ini 04-monitoring)
    # UIDs des dashboards (définis dans les JSON 04-monitoring/grafana/dashboards/) :
    #   aciertech-cluster-ha    → cluster.html, failover.html
    #   aciertech-pg-performance → dashboard.html, pipeline.html
    #   aciertech-data-quality  → quality.html
    #   aciertech-pra-backups   → backups.html
    grafana_host: str = "monitoring-server"     # Hôte interne Docker (pour le serveur)
    grafana_port: int = 3000
    grafana_external_host: str = "localhost"    # Hôte externe navigateur (pour iframes)
    grafana_external_port: int = 3000
    grafana_org_id: int = 1
    grafana_refresh_interval: str = "30s"
    grafana_theme: str = "light"

    # Dashboard UIDs (correspondance avec les JSON 04-monitoring/)
    grafana_uid_cluster:  str = "aciertech-cluster-ha"
    grafana_uid_perf:     str = "aciertech-pg-performance"
    grafana_uid_quality:  str = "aciertech-data-quality"
    grafana_uid_backups:  str = "aciertech-pra-backups"

    # ── Pushgateway ───────────────────────────────────────────────────────────
    # Utilisé par les scripts 03-backup/ — la webapp peut interroger ses métriques
    pushgateway_host: str = "monitoring-server"
    pushgateway_port: int = 9091

    # ── pgBackRest ────────────────────────────────────────────────────────────
    # Stanza définie dans pgbackrest.conf (03-backup/)
    pgbackrest_bin:    str = "/usr/bin/pgbackrest"
    pgbackrest_stanza: str = "aciertech"
    pgbackrest_config: str = "/etc/pgbackrest/pgbackrest.conf"
    # Scripts 03-backup/ (appelés via subprocess)
    backup_scripts_dir: str = "/opt/aciertech/03-backup/scripts"

    # ── Seuils d'alerte webapp (redondants avec Prometheus, pour l'UI) ─────────
    replication_lag_warning_s:  float = 5.0    # secondes
    replication_lag_critical_s: float = 30.0
    quality_rate_warning_pct:   float = 85.0   # %
    quality_rate_critical_pct:  float = 70.0
    connection_warning_pct:     float = 0.85   # ratio (max_connections=200)
    connection_critical_pct:    float = 0.95
    backup_full_age_warning_h:  int   = 170    # heures
    backup_full_age_critical_h: int   = 192    # 8 jours

    # ── Sécurité / sessions ───────────────────────────────────────────────────
    secret_key: str = Field(
        default="CHANGE_ME_IN_PRODUCTION_aciertech_dba_console",
        repr=False,
    )
    session_ttl_minutes: int = 480             # 8h

    # ── Validators ────────────────────────────────────────────────────────────

    @field_validator("app_env")
    @classmethod
    def validate_env(cls, v: str) -> str:
        allowed = {"production", "development", "test"}
        if v not in allowed:
            raise ValueError(f"app_env doit être l'un de : {allowed}")
        return v

    # ── DSN helpers ───────────────────────────────────────────────────────────

    @cached_property
    def dsn_ro(self) -> str:
        """
        DSN pour lectures (aciertech_ro via HAProxy :5001 → standbys).
        Utilisé pour : v_data_quality_dashboard, v_replication_status,
        v_session_activity, v_silent_sensors, backup_history, anomaly_log.
        NE PAS utiliser pour les mutations ou fn_refresh_ai_view.
        """
        return (
            f"host={self.pg_haproxy_host} "
            f"port={self.pg_haproxy_port_ro} "
            f"dbname={self.pg_database} "
            f"user={self.pg_user_ro} "
            f"password={self.pg_password_ro} "
            f"application_name=aciertech_webapp_ro "
            f"connect_timeout={self.pg_connect_timeout} "
            f"options='-c statement_timeout={self.pg_statement_timeout}'"
        )

    @cached_property
    def dsn_admin(self) -> str:
        """
        DSN pour opérations admin (postgres via HAProxy :5000 → primaire).
        Utilisé pour : fn_refresh_ai_view (autocommit), VACUUM manuel,
        diagnostics pg_stat_activity avec détails complets.
        IMPORTANT : fn_refresh_ai_view requiert autocommit=True
        (REFRESH MATERIALIZED VIEW CONCURRENTLY interdit dans une transaction).
        """
        return (
            f"host={self.pg_haproxy_host} "
            f"port={self.pg_haproxy_port_rw} "
            f"dbname={self.pg_database} "
            f"user={self.pg_user_admin} "
            f"password={self.pg_password_admin} "
            f"application_name=aciertech_webapp_admin "
            f"connect_timeout={self.pg_connect_timeout}"
        )

    def dsn_direct(self, node: int = 1) -> str:
        """
        DSN connexion directe à un nœud spécifique (bypass HAProxy).
        Utilisé pour les diagnostics node-by-node dans cluster.py.
        node=1 → pg-node-1, node=2 → pg-node-2, node=3 → pg-node-3
        """
        hosts = {
            1: self.pg_node1_host,
            2: self.pg_node2_host,
            3: self.pg_node3_host,
        }
        host = hosts.get(node, self.pg_node1_host)
        return (
            f"host={host} "
            f"port={self.pg_port_direct} "
            f"dbname={self.pg_database} "
            f"user={self.pg_user_admin} "
            f"password={self.pg_password_admin} "
            f"application_name=aciertech_webapp_direct "
            f"connect_timeout={self.pg_connect_timeout}"
        )

    # ── URL helpers ───────────────────────────────────────────────────────────

    def patroni_url(self, node: int = 1, path: str = "") -> str:
        """URL complète vers l'API Patroni d'un nœud."""
        hosts = {
            1: self.pg_node1_host,
            2: self.pg_node2_host,
            3: self.pg_node3_host,
        }
        host = hosts.get(node, self.pg_node1_host)
        return f"http://{host}:{self.patroni_port}{path}"

    @cached_property
    def patroni_nodes_urls(self) -> list[str]:
        """Liste des URL de base Patroni pour les 3 nœuds."""
        return [self.patroni_url(i) for i in range(1, 4)]

    @cached_property
    def haproxy_stats_url(self) -> str:
        """URL des stats HAProxy au format CSV."""
        return (
            f"http://{self.haproxy_stats_host}:{self.haproxy_stats_port}"
            f"/stats;csv;norefresh"
        )

    @cached_property
    def prometheus_base_url(self) -> str:
        return f"http://{self.prometheus_host}:{self.prometheus_port}"

    @cached_property
    def grafana_base_url(self) -> str:
        return f"http://{self.grafana_host}:{self.grafana_port}"

    def grafana_iframe_url(self, uid: str, extra_params: str = "") -> str:
        """
        URL d'embedding Grafana pour le navigateur (auth.anonymous=true,
        allow_embedding=true configurés dans 04-monitoring/grafana/grafana.ini).

        Utilise grafana_external_host (défaut: localhost) car le navigateur
        ne peut pas résoudre les noms d'hôte Docker-internes.
        Les appels serveur vers Grafana utilisent grafana_host (Docker-internal).
        """
        base_url = f"http://{self.grafana_external_host}:{self.grafana_external_port}"
        base = (
            f"{base_url}/d/{uid}"
            f"?orgId={self.grafana_org_id}"
            f"&kiosk"
            f"&refresh={self.grafana_refresh_interval}"
            f"&theme={self.grafana_theme}"
        )
        if extra_params:
            base += f"&{extra_params}"
        return base

    def etcd_url(self, node: int = 1, path: str = "/health") -> str:
        """URL API etcd d'un nœud (port client 2379)."""
        hosts = {
            1: self.pg_node1_host,
            2: self.pg_node2_host,
            3: self.pg_node3_host,
        }
        host = hosts.get(node, self.pg_node1_host)
        return f"http://{host}:{self.etcd_port_client}{path}"


# Singleton — importé par tous les modules
settings = Settings()