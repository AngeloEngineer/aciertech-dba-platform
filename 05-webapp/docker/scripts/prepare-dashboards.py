import json
import os

dashboards_dir = "/home/broly/aciertech-dba/04-monitoring/grafana/dashboards"
output_dir = "/home/broly/aciertech-dba/05-webapp/docker/grafana/dashboards"
os.makedirs(output_dir, exist_ok=True)

for name in ["cluster-ha", "data-quality", "pg-performance", "pra-backups"]:
    path = os.path.join(dashboards_dir, f"{name}.json")
    with open(path) as f:
        d = json.load(f)

    # Remove __inputs
    d.pop("__inputs", None)
    d.pop("__requires", None)

    # Replace all datasource references that use the input format
    def replace_datasource(obj):
        if isinstance(obj, dict):
            if "datasource" in obj:
                ds = obj["datasource"]
                if isinstance(ds, dict) and ds.get("type") == "prometheus":
                    ds["uid"] = "prometheus-aciertech"
            for k, v in obj.items():
                obj[k] = replace_datasource(v)
        elif isinstance(obj, list):
            obj = [replace_datasource(item) for item in obj]
        return obj

    d = replace_datasource(d)

    outpath = os.path.join(output_dir, f"{name}.json")
    with open(outpath, "w") as f:
        json.dump(d, f, indent=2)
    print(f"Processed: {name}.json -> {outpath}")
