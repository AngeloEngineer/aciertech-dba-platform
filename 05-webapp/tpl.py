# =============================================================================
# Shared Jinja2Templates instance for all routers.
# Sets Grafana URL helpers and app-level globals in one place.
# =============================================================================
from datetime import datetime, timezone

from fastapi.templating import Jinja2Templates

from config import settings

templates = Jinja2Templates(directory="templates")
templates.env.globals["grafana_base_url"]    = settings.grafana_base_url
templates.env.globals["grafana_uid_cluster"] = settings.grafana_uid_cluster
templates.env.globals["grafana_uid_perf"]    = settings.grafana_uid_perf
templates.env.globals["grafana_uid_quality"] = settings.grafana_uid_quality
templates.env.globals["grafana_uid_backups"] = settings.grafana_uid_backups
templates.env.globals["app_version"]         = settings.app_version
templates.env.globals["grafana_iframe_url"]  = settings.grafana_iframe_url
templates.env.globals["now"]                 = lambda fmt="%Y-%m-%dT%H:%M:%SZ": datetime.now(timezone.utc).strftime(fmt)
templates.env.globals["total_sensors"]       = 47
