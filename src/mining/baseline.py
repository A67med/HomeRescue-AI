import datetime as dt
import uuid
import pandas as pd
from sklearn.cluster import KMeans
from src.db import get_engine

# SQL -> Python -> SQL: read a documented feature view, cluster, write the result back to SQL.
engine = get_engine()
features = ["event_count", "total_amount", "avg_amount"]
df = pd.read_sql("SELECT * FROM gold.features_entity ORDER BY entity_key", engine)
df[features] = df[features].astype(float)   # SQL DECIMAL arrives as Decimal objects

if len(df) >= 2:
    k = min(2, len(df))
    df["cluster_id"] = KMeans(n_clusters=k, random_state=42, n_init="auto").fit_predict(df[features])
    df["model_name"] = "kmeans_baseline"
    df["model_version"] = "v0.1"
    df["run_id"] = str(uuid.uuid4())
    df["generated_at"] = dt.datetime.now()
    df.to_sql("entity_cluster", engine, schema="ml", if_exists="replace", index=False)
    print(df)
else:
    print("Need at least two entities")
