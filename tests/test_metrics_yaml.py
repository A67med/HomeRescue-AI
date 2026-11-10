from pathlib import Path
import yaml

REQUIRED = ["name", "label", "definition", "owner", "grain", "sql", "dimensions", "null_policy", "validation_query"]


def test_every_metric_has_all_required_keys():
    data = yaml.safe_load(Path("semantic/metrics.yml").read_text(encoding="utf-8"))
    assert data["metrics"], "metrics.yml has no metrics"
    for m in data["metrics"]:
        for key in REQUIRED:
            assert key in m, f"metric {m.get('name')} is missing '{key}'"
