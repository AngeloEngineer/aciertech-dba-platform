import json
import random
import re
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

NOW = int(time.time())

RE_METRIC = re.compile(
    r'(?:rate\()?\s*'
    r'(?P<metric>\w[\w_]*)\s*'
    r'(?:\{(?P<labels>[^}]*)\})?\s*'
    r'(?:\))?\s*'
    r'(?:\[5m\])?\s*'
    r'(?:\s*[\+\-\*/]\s*.*)?'
)

INCREMENTAL = {}
_INCREMENTAL_TS = {}

# ── Disaster Simulation State ──────────────────────────────────────────────────

DISASTER = {
    "active": False,
    "scenario": None,
    "scenario_description": "",
    "events": [],
    "initialized_at": datetime.now(timezone.utc).isoformat(),
    "nodes": {
        "pg-node-1": {"state": "running", "role": "leader", "timeline": 1, "host": "pg-node-1"},
        "pg-node-2": {"state": "running", "role": "replica", "timeline": 1, "host": "pg-node-2"},
        "pg-node-3": {"state": "running", "role": "replica", "timeline": 1, "host": "pg-node-3"},
    },
    "leader": "pg-node-1",
    "replication_lag_ms": 0,
    "replication_lag_bytes": 52428800,
    "pause_mode": False,
    "data_corrupted": False,
    "data_corruption_time": None,
    "backups_valid": True,
    "pitr_in_progress": False,
    "pitr_completed": False,
    "active_alerts": [],
}

def _log_event(level, message):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    DISASTER["events"].append({
        "time": ts,
        "level": level,
        "message": message
    })
    if len(DISASTER["events"]) > 50:
        DISASTER["events"] = DISASTER["events"][-50:]

def _set_node_state(node, state):
    if node in DISASTER["nodes"]:
        DISASTER["nodes"][node]["state"] = state

def _get_node_state(node):
    return DISASTER["nodes"].get(node, {}).get("state", "unknown")

def _is_leader(node):
    return DISASTER.get("leader") == node

def _get_healthy_nodes():
    return [n for n, d in DISASTER["nodes"].items() if d["state"] == "running"]

def _get_members():
    members = []
    for name, nd in DISASTER["nodes"].items():
        role = "leader" if name == DISASTER["leader"] else "replica"
        state = nd["state"]
        members.append({
            "name": name,
            "role": role,
            "state": state,
            "host": nd.get("host", name),
            "port": 5432,
            "timeline": nd.get("timeline", 1),
            "api_url": f"http://{name}:8008",
        })
    return members

def _apply_disaster_event():
    """Generate alerts and metric impacts based on current disaster state."""
    DISASTER["active_alerts"] = []
    healthy = _get_healthy_nodes()
    total = len(DISASTER["nodes"])

    # Cluster degraded?
    if len(healthy) < total:
        DISASTER["active_alerts"].append({
            "labels": {"alertname": "ClusterDegraded", "severity": "critical",
                       "node": DISASTER["leader"]},
            "state": "firing",
            "annotations": {"summary": f"Cluster degraded: {len(healthy)}/{total} nodes healthy",
                            "description": f"Node(s) down: {', '.join(n for n,d in DISASTER['nodes'].items() if d['state'] != 'running')}"},
            "activeAt": datetime.now(timezone.utc).isoformat(),
            "value": "1",
        })

    # Primary down?
    leader_state = _get_node_state(DISASTER["leader"])
    if leader_state != "running":
        DISASTER["active_alerts"].append({
            "labels": {"alertname": "PrimaryNodeDown", "severity": "critical",
                       "node": DISASTER["leader"]},
            "state": "firing",
            "annotations": {"summary": f"Primary node {DISASTER['leader']} is down",
                            "description": f"PostgreSQL primary {DISASTER['leader']} is unreachable. Failover required."},
            "activeAt": datetime.now(timezone.utc).isoformat(),
            "value": "1",
        })

    # Replication lag
    if DISASTER["replication_lag_ms"] > 30000:
        DISASTER["active_alerts"].append({
            "labels": {"alertname": "ReplicationLagCritical", "severity": "critical",
                       "node": next((n for n in DISASTER["nodes"] if n != DISASTER["leader"] and _get_node_state(n) == "running"), "unknown")},
            "state": "firing",
            "annotations": {"summary": f"Replication lag {DISASTER['replication_lag_ms']}ms > 30s threshold",
                            "description": f"Standby falling behind. Lag: {DISASTER['replication_lag_ms']}ms"},
            "activeAt": datetime.now(timezone.utc).isoformat(),
            "value": "4.5e+01",
        })

    # Data corruption
    if DISASTER["data_corrupted"]:
        DISASTER["active_alerts"].append({
            "labels": {"alertname": "DataCorruptionDetected", "severity": "critical",
                       "node": DISASTER["leader"]},
            "state": "firing",
            "annotations": {"summary": "Data corruption detected on primary",
                            "description": "Checksum failures detected in sensor data. PITR restore recommended."},
            "activeAt": datetime.now(timezone.utc).isoformat(),
            "value": "1",
        })

    # Backup alerts
    if not DISASTER["backups_valid"]:
        DISASTER["active_alerts"].append({
            "labels": {"alertname": "BackupValidationFailed", "severity": "warning"},
            "state": "firing",
            "annotations": {"summary": "Backup verification failed",
                            "description": "Last pgBackRest verify returned errors."},
            "activeAt": datetime.now(timezone.utc).isoformat(),
            "value": "0",
        })

# ── Metrics helpers ───────────────────────────────────────────────────────────

def _incr(metric):
    INCREMENTAL.setdefault(metric, 0)
    INCREMENTAL[metric] += 1
    return str(INCREMENTAL[metric])

def _series_val(metric, base, noise=0.1, drift=0):
    ts_key = metric
    t = _INCREMENTAL_TS.get(ts_key, NOW - 3600)
    t += 60
    _INCREMENTAL_TS[ts_key] = t
    v = base + random.uniform(-noise * base, noise * base) + drift
    return t, round(v, 2)

def _time_series(metric, base, count=60, noise=0.1, drift=0):
    ts_key = metric + "_ts"
    t = _INCREMENTAL_TS.get(ts_key, NOW - 3600)
    out = []
    for _ in range(count):
        t += 60
        v = base + random.uniform(-noise * base, noise * base) + drift * ((t - NOW) / 3600)
        out.append([t, str(round(v, 2))])
    _INCREMENTAL_TS[ts_key] = t
    return out

def _adjust_for_disaster(metric, base_val, labels_str=""):
    """Adjust metric values based on disaster state."""
    # If primary is down, PG metrics go to 0 for the primary node
    is_primary = "node1" in labels_str or "pg-node-1" in labels_str
    leader = DISASTER["leader"]
    leader_idx = leader.split("-")[-1]
    is_leader_metric = f"node{leader_idx}" in labels_str or leader in labels_str

    # Node down → metrics become 0 or degrade
    for node_name, nd in DISASTER["nodes"].items():
        if nd["state"] != "running":
            node_idx = node_name.split("-")[-1]
            if f"node{node_idx}" in labels_str or node_name in labels_str:
                if metric == "up":
                    return 0.0
                else:
                    return 0.0 if random.random() < 0.8 else base_val * 0.1

    # Data corruption → quality metrics crash
    if DISASTER["data_corrupted"] and "valid_rate" in metric:
        return max(5, base_val * 0.08)
    if DISASTER["data_corrupted"] and "quality" in metric:
        return max(10, base_val * 0.15)
    if DISASTER["data_corrupted"] and "anomaly" in metric:
        return base_val * 8

    # Replication lag increase
    if DISASTER["replication_lag_ms"] > 1000 and "replication_lag" in metric:
        return base_val + DISASTER["replication_lag_ms"] / 1000

    return base_val

def _val(metric, labels_str):
    base = METRIC_VALUES.get(metric)
    if base is not None:
        adj = _adjust_for_disaster(metric, base, labels_str)
        return adj + random.uniform(-0.05 * adj, 0.05 * adj) if adj > 1 else adj

    job = ""
    if labels_str:
        for part in labels_str.split(","):
            part = part.strip()
            if "=" in part:
                k, v = part.split("=", 1)
                v = v.strip('"').strip("'")
                if k == "job":
                    job = v

    if metric == "up":
        for node_name, nd in DISASTER["nodes"].items():
            node_idx = node_name.split("-")[-1]
            if f"node{node_idx}" in labels_str or node_name in labels_str:
                return 1.0 if nd["state"] == "running" else 0.0
        if "etcd" in job:
            return 1.0
        # Health check for primary probes → reflect leader state
        leader_state = _get_node_state(DISASTER["leader"])
        return 1.0 if leader_state == "running" else 0.0

    if metric.startswith("pg_stat_database_"):
        lag = DISASTER["replication_lag_ms"] / 1000
        if "blks_hit" in metric:
            return _adjust_for_disaster(metric, 12000.0, labels_str)
        if "blks_read" in metric:
            return _adjust_for_disaster(metric, 45.0, labels_str)
        if "xact_commit" in metric:
            return _adjust_for_disaster(metric, 800.0, labels_str)
        if "xact_rollback" in metric:
            return _adjust_for_disaster(metric, 3.0, labels_str)
        if "numbackends" in metric:
            healthy = len(_get_healthy_nodes())
            return _adjust_for_disaster(metric, 12.0, labels_str)
        if "deadlocks" in metric:
            return _adjust_for_disaster(metric, 1.0, labels_str)
        return 100.0

    if metric.startswith("pg_stat_archiver_"):
        if "archived_count" in metric:
            return 150.0
        if "failed_count" in metric:
            return 0.0
        if "last_archived_time" in metric:
            return float(NOW - 120)
        return 0.0

    if metric.startswith("pg_stat_user_tables_"):
        if "n_dead_tup" in metric:
            return 500.0
        if "last_autovacuum" in metric:
            return float(NOW - 1800)
        return 0.0

    if metric.startswith("pg_locks_"):
        return 2.0

    if metric.startswith("haproxy_"):
        healthy_primaries = sum(1 for n in ["pg-node-1","pg-node-2","pg-node-3"]
                                if _get_node_state(n) == "running")
        if "active_servers" in metric:
            if "primary" in labels_str:
                return 1.0 if _get_node_state(DISASTER["leader"]) == "running" else 0.0
            return float(healthy_primaries - 1 if healthy_primaries > 0 else 0.0)
        if "current_sessions" in metric:
            return 3.0 if "replica" in labels_str else 5.0
        return 1.0

    if metric.startswith("pgbouncer_"):
        if "cl_active" in metric:
            return 3.0
        if "cl_waiting" in metric:
            return 0.0
        if "sv_active" in metric:
            return 2.0
        return 1.0

    if metric.startswith("node_filesystem_"):
        if "avail_bytes" in metric:
            if "pgbackrest" in labels_str:
                return 214748364800.0
            return 536870912000.0
        if "size_bytes" in metric:
            if "pgbackrest" in labels_str:
                return 536870912000.0
            return 1073741824000.0

    if metric.startswith("aciertech_"):
        if DISASTER["data_corrupted"]:
            if "valid_rate_pct" in metric:
                return 8.3
            if "quality" in metric:
                return 12.0
            if "anomaly" in metric:
                return 850.0
            if "critical_silent_sensors" in metric:
                return 12.0
            if "warning_silent_sensors" in metric:
                return 15.0
            if "quarantined_count" in metric:
                return 420.0
        if "valid_readings_total" in metric:
            return 500000.0
        if "quarantined_readings_total" in metric:
            return 25000.0
        if "valid_rate_pct" in metric:
            return 94.7
        if "quality_level" in metric:
            return 3.0
        if "avg_quality_score" in metric:
            return 87.3
        if "never_seen_sensors_count" in metric:
            return 0.0
        if "critical_silent_sensors_count" in metric:
            return 1.0
        if "warning_silent_sensors_count" in metric:
            return 2.0
        if "quarantined_count_1h" in metric:
            return 23.0
        if "total_readings_1h" in metric:
            return 8472.0
        if "anomaly_log_total" in metric:
            return 156.0
        if "ai_view_refresh_duration_seconds" in metric:
            return 2.3
        if "ai_view_last_refresh_timestamp" in metric:
            return float(NOW - 300)
        if "sessions_blocked_count" in metric:
            return 0.0
        if "long_query_seconds_max" in metric:
            return 15.0
        if "sessions_active_count" in metric:
            return 5.0
        if "sessions_idle_count" in metric:
            return 3.0
        if "sessions_idle_in_transaction_count" in metric:
            return 1.0
        if "replication_lag_seconds" in metric:
            return DISASTER["replication_lag_ms"] / 1000
        if "replication_lag_bytes" in metric:
            return float(DISASTER["replication_lag_bytes"])
        if "replication_catching_up" in metric:
            return 0.0
        if "backup_verify_status" in metric:
            return 1.0 if DISASTER["backups_valid"] else 0.0
        if "backup_test_status" in metric:
            return 1.0 if DISASTER["backups_valid"] else 0.0
        if "backup_repo_size_bytes" in metric:
            return 1572864000.0
        if "backup_full_count" in metric:
            return 3.0
        if "backup_oldest_full_age_hours" in metric:
            return 72.0
        if "backup_last_success_timestamp" in metric:
            return float(NOW - 3600)

    return round(random.uniform(10, 99), 1)

HARDCODED_METRICS = {
    "up": 1,
    "scalar": {"5": 5.0, "30": 30.0},
}

METRIC_VALUES = {}

class MockHandler(BaseHTTPRequestHandler):

    def _json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
        return True  # indicate request was handled (stop further processing)

    def _text(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(data.encode())
        return True

    def _csv(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/csv")
        self.end_headers()
        self.wfile.write(data.encode())
        return True

    def _parse_promql(self, raw_query):
        q = raw_query.strip()
        agg_match = re.match(r'(sum|count|avg)\s*\(\s*(.+)', q)
        if agg_match:
            inner = agg_match.group(2)
            m = RE_METRIC.search(inner)
        else:
            m = RE_METRIC.search(q)
        if m:
            return m.group("metric"), m.group("labels") or ""
        return q, ""

    def _handle_query(self, query, is_range=False):
        q = query.strip()

        if q.startswith("scalar("):
            inner = q[7:-1].strip()
            try:
                val = float(inner)
            except ValueError:
                val = 0.0
            return self._prom_vector([{"metric": {}, "value": [NOW, str(val)]}])

        if q.startswith("time()"):
            val = float(NOW)
            return self._prom_vector([{"metric": {}, "value": [NOW, str(val)]}])

        if q.startswith("1 -"):
            inner = q[3:].strip()
            return self._handle_query(inner, is_range)

        if q.startswith("count("):
            inner = q[6:-1].strip()
            m = RE_METRIC.search(inner)
            if m and m.group("metric") == "up":
                healthy = len(_get_healthy_nodes())
                return self._prom_vector([{"metric": {}, "value": [NOW, str(healthy)]}])

        if q.startswith("avg("):
            inner = q[4:-1].strip()
            m = RE_METRIC.search(inner)
            if m:
                val = _val(m.group("metric"), m.group("labels") or "")
                return self._prom_vector([{"metric": {}, "value": [NOW, str(val)]}])

        if q.startswith("sum("):
            inner = q[4:-1].strip()
            m = RE_METRIC.search(inner)
            if m:
                val = _val(m.group("metric"), m.group("labels") or "")
                return self._prom_vector([{"metric": {}, "value": [NOW, str(val)]}])

        if q.startswith("increase("):
            inner = q[9:-1].strip()
            m = RE_METRIC.search(inner)
            if m:
                val = _val(m.group("metric"), m.group("labels") or "")
                return self._prom_vector([{"metric": {}, "value": [NOW, str(val)]}])

        if q.startswith("rate("):
            inner = q[5:-1].strip()
            m = RE_METRIC.search(inner)
            if m:
                val = _val(m.group("metric"), m.group("labels") or "")
                return self._prom_vector([{"metric": {}, "value": [NOW, str(val * 0.01)]}])

        expr_match = re.match(r'([\w_]+)\s*\{\s*([^}]*)\s*\}\s*([\+\-\*/])\s*(.+)', q)
        if expr_match:
            left_metric = expr_match.group(1)
            left_labels = expr_match.group(2)
            op = expr_match.group(3)
            right_expr = expr_match.group(4).strip()
            if right_expr.startswith("("):
                right_expr = right_expr[1:]
            right_parts = right_expr.split("+")
            right_val = 0
            for part in right_parts:
                part = part.strip().rstrip(")")
                if part.startswith("pg_stat_database_blks_read"):
                    m2 = RE_METRIC.search(part)
                    if m2:
                        right_val += _val(m2.group("metric"), m2.group("labels") or "")
                else:
                    try:
                        right_val += float(part) if part else 0
                    except ValueError:
                        right_val += 1
            left_val = _val(left_metric, left_labels)
            if op == "/":
                result = left_val / max(right_val, 1)
            elif op == "-":
                result = left_val - right_val
            elif op == "*":
                result = left_val * right_val
            else:
                result = left_val + right_val
            return self._prom_vector([{"metric": {}, "value": [NOW, str(round(result, 2))]}])

        if q.startswith("count by"):
            inner = q[q.index("(")+1:q.rindex(")")]
            m = RE_METRIC.search(inner)
            if m:
                healthy = len(_get_healthy_nodes())
                return self._prom_vector([{"metric": {"job": "postgres_exporter_node1"}, "value": [NOW, str(healthy)]}])

        metric, labels = self._parse_promql(q)

        if is_range:
            series = _time_series(metric, _val(metric, labels), count=60)
            return self._prom_matrix([{"metric": {}, "values": series}])
        else:
            val = _val(metric, labels)
            return self._prom_vector([{"metric": {}, "value": [NOW, str(val)]}])

    def _prom_vector(self, results):
        return self._json({
            "status": "success",
            "data": {"resultType": "vector", "result": results}
        })

    def _prom_matrix(self, results):
        return self._json({
            "status": "success",
            "data": {"resultType": "matrix", "result": results}
        })

    def _prom_label_values(self, label_name):
        if label_name == "node":
            healthy = [n for n,d in DISASTER["nodes"].items() if d["state"] == "running"]
            return self._json({"status": "success", "data": healthy})
        if label_name == "job":
            return self._json({
                "status": "success",
                "data": ["postgres_exporter_node1", "postgres_exporter_node2",
                         "postgres_exporter_node3", "etcd"]
            })
        if label_name == "proxy":
            return self._json({
                "status": "success",
                "data": ["postgresql-primary", "postgresql-replica"]
            })
        if label_name == "database":
            return self._json({"status": "success", "data": ["aciertech_db"]})
        if label_name == "mountpoint":
            return self._json({
                "status": "success",
                "data": ["/var/lib/postgresql", "/var/lib/pgbackrest"]
            })
        return self._json({"status": "success", "data": []})

    # ── Disaster API endpoints ─────────────────────────────────────────────

    def _handle_disaster_get(self, path):
        if path == "/api/disaster/status":
            return self._json({
                "active": DISASTER["active"],
                "scenario": DISASTER["scenario"],
                "scenario_description": DISASTER["scenario_description"],
                "healthy_nodes": _get_healthy_nodes(),
                "total_nodes": len(DISASTER["nodes"]),
                "leader": DISASTER["leader"],
                "replication_lag_ms": DISASTER["replication_lag_ms"],
                "replication_lag_bytes": DISASTER["replication_lag_bytes"],
                "pause_mode": DISASTER["pause_mode"],
                "data_corrupted": DISASTER["data_corrupted"],
                "backups_valid": DISASTER["backups_valid"],
                "pitr_in_progress": DISASTER["pitr_in_progress"],
                "pitr_completed": DISASTER["pitr_completed"],
                "alerts_count": len(DISASTER["active_alerts"]),
                "events": DISASTER["events"],
                "nodes": {n: d["state"] for n, d in DISASTER["nodes"].items()},
                "alerts": DISASTER["active_alerts"],
            })
        return None

    def _handle_disaster_post(self, path, body):
        data = {}
        if body:
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                pass
        node = data.get("node", "")

        # ── Crash Primary ──
        if path == "/api/disaster/crash-primary":
            old_leader = DISASTER["leader"]
            _set_node_state(old_leader, "down")
            DISASTER["active"] = True
            DISASTER["scenario"] = "primary_crash"
            DISASTER["scenario_description"] = "Primary node crashed — cluster degraded, failover required"
            DISASTER["replication_lag_ms"] = 45000
            DISASTER["replication_lag_bytes"] = 104857600
            _log_event("CRITICAL", f"PRIMARY {old_leader} is DOWN — cluster degraded")
            _log_event("WARN", "Writes to RW:5000 failing — connections timing out")
            _log_event("WARN", "Replication stopped — standbys waiting for new primary")
            _apply_disaster_event()
            return self._json({"success": True, "message": f"Primary {old_leader} crashed",
                               "events": DISASTER["events"][-3:]})

        # ── Crash Replica ──
        if path == "/api/disaster/crash-replica":
            if not node:
                node = "pg-node-3"
            if node == DISASTER["leader"]:
                return self._json({"success": False, "message": "Cannot crash primary via this endpoint"}, 400)
            _set_node_state(node, "down")
            DISASTER["active"] = True
            DISASTER["scenario"] = "replica_crash"
            DISASTER["scenario_description"] = f"Replica {node} crashed — replication degraded"
            DISASTER["replication_lag_ms"] = 60000
            _log_event("CRITICAL", f"Replica {node} is DOWN — cluster degraded")
            _log_event("WARN", f"Replication from {node} stopped — HAProxy routes removed")
            _apply_disaster_event()
            return self._json({"success": True, "message": f"Replica {node} crashed",
                               "events": DISASTER["events"][-3:]})

        # ── Data Corruption ──
        if path == "/api/disaster/data-corruption":
            DISASTER["active"] = True
            DISASTER["scenario"] = "data_corruption"
            DISASTER["scenario_description"] = "Data corruption detected — checksum failures, quality metrics crashed"
            DISASTER["data_corrupted"] = True
            DISASTER["data_corruption_time"] = datetime.now(timezone.utc).isoformat()
            _log_event("CRITICAL", "DATA CORRUPTION detected — checksum mismatches in sensor_data table")
            _log_event("WARN", "IoT quality metrics crashed: valid_rate=8.3% — 420 readings quarantined")
            _log_event("WARN", "Anomaly detection alert: 850 anomalies in last 5 minutes")
            _log_event("INFO", "Recommend PITR restore to pre-corruption timestamp")
            _apply_disaster_event()
            return self._json({"success": True, "message": "Data corruption simulated",
                               "events": DISASTER["events"][-4:]})

        # ── Failover (force) ──
        if path == "/api/disaster/failover":
            old_leader = DISASTER["leader"]
            # Pick first healthy replica as new leader
            candidates = [n for n,d in DISASTER["nodes"].items()
                         if n != old_leader and d["state"] == "running"]
            if not candidates:
                return self._json({"success": False, "message": "No healthy replica available for failover"}, 400)
            new_leader = candidates[0]
            _set_node_state(old_leader, "down")
            DISASTER["leader"] = new_leader
            DISASTER["nodes"][new_leader]["role"] = "leader"
            DISASTER["nodes"][new_leader]["timeline"] += 1
            DISASTER["replication_lag_ms"] = 2000
            _log_event("WARN", f"FORCE FAILOVER: {new_leader} promoted to PRIMARY")
            _log_event("INFO", f"Timeline bumped to {DISASTER['nodes'][new_leader]['timeline']}")
            _log_event("INFO", "HAProxy RW:5000 now routes to new primary")
            _apply_disaster_event()
            return self._json({"success": True, "message": f"Failover to {new_leader} completed",
                               "leader": new_leader, "events": DISASTER["events"][-3:]})

        # ── Switchover (controlled) ──
        if path == "/api/disaster/switchover":
            if not node:
                node = "pg-node-2"
            if node not in DISASTER["nodes"] or _get_node_state(node) != "running":
                return self._json({"success": False, "message": f"Node {node} is not available"}, 400)
            if node == DISASTER["leader"]:
                return self._json({"success": False, "message": "Node is already the leader"}, 400)
            old_leader = DISASTER["leader"]
            DISASTER["nodes"][old_leader]["role"] = "replica"
            DISASTER["nodes"][node]["role"] = "leader"
            DISASTER["nodes"][node]["timeline"] += 1
            DISASTER["leader"] = node
            DISASTER["replication_lag_ms"] = 500
            _log_event("INFO", f"Planned switchover: {old_leader} → {node}")
            _log_event("INFO", "Zero data loss — WAL positions verified")
            _log_event("INFO", f"HAProxy RW:5000 re-routed to {node}")
            _apply_disaster_event()
            return self._json({"success": True, "message": f"Switchover to {node} completed",
                               "leader": node, "events": DISASTER["events"][-3:]})

        # ── Reinitialize node ──
        if path == "/api/disaster/reinit":
            if not node:
                node = "pg-node-3"
            _set_node_state(node, "running")
            DISASTER["nodes"][node]["timeline"] = DISASTER["nodes"][DISASTER["leader"]]["timeline"]
            # Recalculate replication lag after reinit
            DISASTER["replication_lag_ms"] = max(500, DISASTER["replication_lag_ms"] - 10000)
            _log_event("INFO", f"Node {node} re-initialized from {DISASTER['leader']}")
            _log_event("INFO", f"Full re-replication completed — PGDATA recreated")
            _apply_disaster_event()
            return self._json({"success": True, "message": f"Node {node} reinitialized",
                               "events": DISASTER["events"][-2:]})

        # ── Pause auto-failover ──
        if path == "/api/disaster/pause":
            DISASTER["pause_mode"] = True
            _log_event("WARN", "Auto-failover suspended (maintenance window)")
            return self._json({"success": True, "message": "Auto-failover paused"})

        # ── Resume auto-failover ──
        if path == "/api/disaster/resume":
            DISASTER["pause_mode"] = False
            _log_event("INFO", "Auto-failover resumed")
            return self._json({"success": True, "message": "Auto-failover resumed"})

        # ── PITR Restore ──
        if path == "/api/disaster/pitr-restore":
            DISASTER["pitr_in_progress"] = True
            DISASTER["scenario"] = "pitr_restore"
            DISASTER["scenario_description"] = "Point-in-Time Recovery in progress"
            target_ts = data.get("target_timestamp", "2026-05-23T00:00:00Z")
            _log_event("WARN", f"PITR RESTORE initiated to: {target_ts}")
            _log_event("INFO", "Cluster stopped — pgBackRest restore starting")
            _log_event("INFO", "Restoring WAL archive from repo1...")
            _log_event("INFO", "Recovery applying WAL...")
            _log_event("INFO", f"PITR complete — cluster restarted at {target_ts}")
            DISASTER["data_corrupted"] = False
            DISASTER["pitr_in_progress"] = False
            DISASTER["pitr_completed"] = True
            _apply_disaster_event()
            return self._json({"success": True, "message": "PITR restore completed",
                               "events": DISASTER["events"][-5:]})

        # ── Reset ──
        if path == "/api/disaster/reset":
            _log_event("INFO", "=== DISASTER RECOVERY COMPLETE ===")
            _log_event("INFO", "Cluster fully restored to healthy state")
            DISASTER["active"] = False
            DISASTER["scenario"] = None
            DISASTER["scenario_description"] = ""
            for n in DISASTER["nodes"]:
                DISASTER["nodes"][n]["state"] = "running"
                DISASTER["nodes"][n]["role"] = "replica"
                DISASTER["nodes"][n]["timeline"] = 1
            DISASTER["leader"] = "pg-node-1"
            DISASTER["nodes"]["pg-node-1"]["role"] = "leader"
            DISASTER["replication_lag_ms"] = 0
            DISASTER["replication_lag_bytes"] = 52428800
            DISASTER["data_corrupted"] = False
            DISASTER["data_corruption_time"] = None
            DISASTER["backups_valid"] = True
            DISASTER["pitr_in_progress"] = False
            DISASTER["pitr_completed"] = False
            DISASTER["pause_mode"] = False
            _apply_disaster_event()
            return self._json({"success": True, "message": "Cluster reset to healthy state",
                               "events": DISASTER["events"][-2:]})

        return None

    # ── HTTP Methods ────────────────────────────────────────────────────────

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        # Disaster API
        result = self._handle_disaster_get(path)
        if result is not None:
            return result

        # PATRONI API (port 8008)
        if path == "/cluster":
            return self._json({
                "members": _get_members(),
                "pause": DISASTER["pause_mode"],
                "ttl": 30,
                "cluster": "aciertech",
            })
        if path == "/health":
            # Node-specific health: each node returns its own state
            host = self.headers.get("Host", "").split(":")[0]
            node_name = host
            state = _get_node_state(node_name)
            role = "leader" if _is_leader(node_name) else "replica"
            if state == "running":
                return self._json({"state": "running", "role": role}, 200)
            else:
                return self._json({"state": "down", "role": role}, 503)
        if path == "/leader":
            leader_node = DISASTER["leader"]
            if _get_node_state(leader_node) == "running":
                return self._json({"state": "running", "role": "leader"}, 200)
            return self._json({"error": "No leader"}, 503)
        if path == "/replica":
            return self._json({"state": "running", "role": "replica"}, 200)
        if path == "/config":
            return self._json({
                "ttl": 30, "loop_wait": 10, "retry_timeout": 10,
                "maximum_lag_on_failover": 1048576,
            })
        if path == "/patroni":
            return self._json({
                "database": {"pg_version": 160000},
                "patroni": {"version": "4.0.3", "scope": "aciertech"},
            })

        # PROMETHEUS API (port 9090)
        if path == "/api/v1/query":
            query = params.get("query", [""])[0]
            return self._handle_query(query, is_range=False)

        if path == "/api/v1/query_range":
            query = params.get("query", [""])[0]
            return self._handle_query(query, is_range=True)

        if path == "/api/v1/status/buildinfo":
            return self._json({
                "status": "success",
                "data": {
                    "version": "2.53.0", "revision": "mock",
                    "branch": "HEAD", "buildUser": "mock@mock",
                    "buildDate": "20260101-00:00:00", "goVersion": "go1.22.0",
                }
            })

        if path == "/-/healthy":
            return self._text("Prometheus is Healthy.\n", 200)

        if path == "/api/v1/labels":
            return self._json({
                "status": "success",
                "data": ["__name__", "job", "instance", "node", "proxy",
                         "database", "mountpoint", "datname", "schemaname",
                         "relname", "granted", "state", "severity", "alertname"]
            })

        if path.startswith("/api/v1/label/") and path.endswith("/values"):
            label_name = path.split("/")[4]
            return self._prom_label_values(label_name)

        if path == "/api/v1/series":
            return self._json({
                "status": "success",
                "data": self._build_series()
            })

        if path == "/api/v1/alerts":
            _apply_disaster_event()
            return self._json({
                "status": "success",
                "data": {"alerts": DISASTER["active_alerts"]}
            })

        if path == "/api/v1/rules":
            return self._json({
                "status": "success",
                "data": {
                    "groups": self._build_rule_groups()
                }
            })

        # ETCD API (port 2379)
        if path == "/health":
            return self._json({"health": "true"})
        if path == "/v2/stats/leader":
            return self._json({"leader": DISASTER["leader"]})
        if path == "/v2/stats/self":
            return self._json({
                "state": "StateLeader",
                "name": "etcd-1",
                "id": "abc123",
            })

        # HAPROXY STATS (port 7000, CSV)
        if path in ("/stats;csv;norefresh", "/stats;csv"):
            return self._csv(self._build_haproxy_csv())

        self._json({"error": "not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode() if content_len else ""

        # Disaster API
        result = self._handle_disaster_post(path, body)
        if result is not None:
            return result

        # Prometheus query POST (used by Grafana)
        if path == "/api/v1/query":
            params = parse_qs(body)
            query = params.get("query", [""])[0]
            return self._handle_query(query, is_range=False)

        if path == "/api/v1/query_range":
            params = parse_qs(body)
            query = params.get("query", [""])[0]
            return self._handle_query(query, is_range=True)

        # Patroni actions
        if path in ("/switchover", "/failover", "/reinitialize"):
            return self._json({"success": True})
        if path == "/pause":
            DISASTER["pause_mode"] = True
            return self._json({"success": True})
        if path == "/resume":
            DISASTER["pause_mode"] = False
            return self._json({"success": True})

        self._json({"error": "not found"}, 404)

    def _build_series(self):
        healthy = _get_healthy_nodes()
        series = []
        for n in DISASTER["nodes"]:
            idx = n.split("-")[-1]
            state = DISASTER["nodes"][n]["state"]
            series.append({
                "__name__": "up", "job": f"postgres_exporter_node{idx}",
                "instance": f"{n}:9187", "node": n
            })
        return series

    def _build_rule_groups(self):
        groups = [
            {
                "name": "replication_lag",
                "file": "rules/postgresql_alerts.yml",
                "rules": [{
                    "name": "ReplicationLagCritical",
                    "query": "aciertech_replication_lag_seconds > 30",
                    "state": "firing" if DISASTER["replication_lag_ms"] > 30000 else "inactive",
                    "alerts": [{"labels": {"severity": "critical"}}],
                }],
            },
            {
                "name": "cluster_health",
                "file": "rules/postgresql_alerts.yml",
                "rules": [{
                    "name": "PrimaryNodeDown",
                    "query": "up{job=~'postgres_exporter.*'} == 0",
                    "state": "firing" if any(nd["state"] != "running" for nd in DISASTER["nodes"].values()) else "inactive",
                    "alerts": [{"labels": {"severity": "critical"}}],
                }],
            },
        ]
        if DISASTER["data_corrupted"]:
            groups.append({
                "name": "data_quality",
                "file": "rules/iot_alerts.yml",
                "rules": [{
                    "name": "DataCorruptionDetected",
                    "query": "aciertech_valid_rate_pct < 50",
                    "state": "firing",
                    "alerts": [{"labels": {"severity": "critical"}}],
                }],
            })
        return groups

    def _build_haproxy_csv(self):
        """Build HAProxy CSV reflecting current cluster state."""
        leader = DISASTER["leader"]
        healthy = _get_healthy_nodes()
        lines = [
            "# pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status,weight,act,bck,chkfail,chkdown,lastchg,downtime,qlimit,pid,iid,sid,throttle,ltime,tracking,type,rate,rate_lim,rate_max,check_status,check_code,check_duration,hrsp_1xx,hrsp_2xx,hrsp_3xx,hrsp_4xx,hrsp_5xx,hrsp_other,hanafail,req_rate,req_rate_max,req_tot,cli_abrt,srv_abrt,comp_in,comp_out,comp_byp,comp_rsp,lastsess,last_chk,last_agt,qtime,ctime,rtime,ttime,agent_status,agent_code,agent_duration,check_desc,agent_desc,check_rise,check_fall,check_health,agent_rise,agent_fall,agent_health,addr,cookie,mode,algo,conn_rate,conn_rate_max,conn_tot,intercepted,dcon,dses\n"
        ]

        # Primary frontend + backend
        primary_state = "UP" if _get_node_state(leader) == "running" else "DOWN"
        lines.append(
            f"postgresql-primary,FRONTEND,,,1,5,100,12345,12345,67890,,1,0,0,0,0,0,OPEN,,,,,,,,,1,1,0,,0,1,0,1,,0,,1,0,0,0,0,0,0,0,0,,,,,0,0,,,0,,,0,0,0,0,,,,,,,,,,,,,,,,,,\n"
        )
        lines.append(
            f"postgresql-primary,{leader},0,0,1,5,100,12345,12345,67890,,1,0,0,0,0,0,{primary_state},1,1,0,0,0,97800,0,,1,3,0,,1,2,0,0,L7OK,200,1,0,1,0,0,0,0,0,0,0,,,,,0,215743,,,0,,3,6,0,20,,,,,,{primary_state},1,3,0,0,0,0,0,0,0,0,\n"
        )

        # Replicas
        replicas = [n for n in ["pg-node-2", "pg-node-3"] if n in DISASTER["nodes"]]
        replica_states = []
        for r in replicas:
            state = "UP" if _get_node_state(r) == "running" else "DOWN"
            replica_states.append((r, state))

        lines.append(
            f"postgresql-replica,FRONTEND,,,{len(replica_states)},5,100,67890,23456,78901,,1,0,0,0,0,0,OPEN,,,,,,,,,1,2,0,,0,1,0,1,,0,,1,0,0,0,0,0,0,0,0,,,,,0,0,,,0,,,0,0,0,0,,,,,,,,,,,,,,,,,,\n"
        )
        for r, state in replica_states:
            lines.append(
                f"postgresql-replica,{r},0,0,1,5,100,45678,23456,78901,,1,0,0,0,0,0,{state},1,1,0,0,0,97800,0,,1,4,0,,2,2,0,0,L7OK,200,1,0,1,0,0,0,0,0,0,0,,,,,0,148159,,,0,,2,4,0,10,,,,,,{state},1,3,0,0,0,0,0,0,0,0,\n"
            )

        return "".join(lines)

    def log_message(self, format, *args):
        import sys
        print(f"[{self.client_address[0]}:{self.client_address[1]}] {format % args}", flush=True)


if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8008
    _log_event("INFO", "Mock server started — cluster initializing")
    _log_event("INFO", "pg-node-1 (PRIMARY), pg-node-2, pg-node-3 (REPLICAS)")
    _log_event("INFO", "All 3 nodes healthy — replication active")
    server = HTTPServer(("0.0.0.0", port), MockHandler)
    print(f"Mock server running on port {port}")
    server.serve_forever()
