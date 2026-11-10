# OPTIONAL: a grounded assistant. Use any model you like; this file only shows the grounding idea.
# The assistant is NOT the source of truth: it may only use the semantic catalog and approved SQL results.
from pathlib import Path

SEMANTIC = Path("semantic/metrics.yml").read_text(encoding="utf-8")
SYSTEM = (
    "You are an analytics assistant. Use only the metric definitions and SQL evidence provided. "
    "Never invent columns or results. If evidence is missing, say which SQL or data is needed. "
    "Always state the metric definition and the source table.\n\nSEMANTIC CATALOG:\n" + SEMANTIC
)
print(SYSTEM[:1500])
print("\nTODO: connect a model, pass approved read-only SQL results as evidence, and log every answer.")
