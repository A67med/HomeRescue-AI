from pathlib import Path
import yaml
from sqlalchemy import text
from src.db import get_engine

# Copies semantic/metrics.yml into semantic.metric_catalog (the YAML file is the source of truth).
metrics = yaml.safe_load(Path("semantic/metrics.yml").read_text(encoding="utf-8"))["metrics"]
engine = get_engine()
with engine.begin() as con:
    con.execute(text("DELETE FROM semantic.metric_catalog"))
    for m in metrics:
        con.execute(text(
            "INSERT semantic.metric_catalog (metric_name, label, definition, owner, grain, sql_expression, "
            "dimensions, null_policy, validation_query) VALUES (:n, :l, :d, :o, :g, :s, :dim, :np, :v)"),
            {"n": m["name"], "l": m["label"], "d": m["definition"], "o": m["owner"], "g": m["grain"],
             "s": m["sql"], "dim": ", ".join(m["dimensions"]), "np": m["null_policy"], "v": m["validation_query"]})
print("Synced", len(metrics), "metrics")
