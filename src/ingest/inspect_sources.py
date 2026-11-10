"""Inspect live NYC Open Data Socrata metadata and borough/year distributions for M1 scope selection."""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from pathlib import Path
from datetime import datetime, timezone

SOURCES = {
    "buildings": {
        "dataset_id": "kj4p-ruqc",
        "name": "Buildings",
        "url": "https://data.cityofnewyork.us/d/kj4p-ruqc",
    },
    "complaints_problems": {
        "dataset_id": "ygpa-z7cr",
        "name": "Housing Maintenance Code Complaints and Problems",
        "url": "https://data.cityofnewyork.us/d/ygpa-z7cr",
    },
    "violations": {
        "dataset_id": "wvxf-dwi5",
        "name": "Housing Maintenance Code Violations",
        "url": "https://data.cityofnewyork.us/d/wvxf-dwi5",
    },
    "omo_charges": {
        "dataset_id": "mdbu-nrqn",
        "name": "Open Market Order (OMO) Charges",
        "url": "https://data.cityofnewyork.us/d/mdbu-nrqn",
    },
}


def fetch_json(url: str, timeout: int = 45):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "HomeRescue-AI-DataWarehouse/1.0 (Academic Capstone)",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def inspect_metadata():
    summary = {
        "inspected_at_utc": datetime.now(timezone.utc).isoformat(),
        "sources": {},
    }
    for key, info in SOURCES.items():
        ds_id = info["dataset_id"]
        meta_url = f"https://data.cityofnewyork.us/api/views/{ds_id}.json"
        print(f"Fetching metadata for {key} ({ds_id})...")
        meta = fetch_json(meta_url)
        columns = []
        for col in meta.get("columns", []):
            field_name = col.get("fieldName", "")
            if field_name.startswith(":@"):
                continue
            columns.append(
                {
                    "fieldName": field_name,
                    "name": col.get("name"),
                    "dataTypeName": col.get("dataTypeName"),
                    "description": col.get("description", ""),
                    "position": col.get("position"),
                }
            )
        sample_url = f"https://data.cityofnewyork.us/resource/{ds_id}.json?$limit=2"
        sample_rows = fetch_json(sample_url)
        count_url = f"https://data.cityofnewyork.us/resource/{ds_id}.json?$select=count(*)%20as%20cnt"
        count_res = fetch_json(count_url)
        total_rows = int(count_res[0]["cnt"]) if count_res else None

        summary["sources"][key] = {
            "dataset_id": ds_id,
            "official_name": meta.get("name", info["name"]),
            "url": info["url"],
            "rowsUpdatedAt": meta.get("rowsUpdatedAt"),
            "viewLastModified": meta.get("viewLastModified"),
            "attribution": meta.get("attribution"),
            "category": meta.get("category"),
            "total_rows_live": total_rows,
            "column_count": len(columns),
            "columns": columns,
            "sample_rows": sample_rows,
        }
        print(
            f"  -> {meta.get('name')}: {total_rows} total rows, {len(columns)} columns"
        )
        print(f"  -> Columns: {[c['fieldName'] for c in columns]}")

    out_dir = Path("data/exports/validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "m1_live_source_metadata.json"
    out_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"Saved live metadata to {out_path}")


def query_soql(ds_id: str, params: dict, timeout: int = 60):
    url = f"https://data.cityofnewyork.us/resource/{ds_id}.json?" + urllib.parse.urlencode(params)
    return fetch_json(url, timeout=timeout)


def profile_scope_candidates():
    profile = {
        "profiled_at_utc": datetime.now(timezone.utc).isoformat(),
        "buildings_by_boro": query_soql(
            "kj4p-ruqc",
            {"$select": "boroid, boro, count(*) as cnt", "$group": "boroid, boro", "$order": "boroid"},
        ),
        "candidates": {},
    }
    print("Buildings by boro:", json.dumps(profile["buildings_by_boro"], indent=2))

    candidates = [
        ("STATEN ISLAND", "5", "2024"),
        ("STATEN ISLAND", "5", "2025"),
        ("MANHATTAN", "1", "2024"),
        ("BRONX", "2", "2024"),
    ]
    for boro_name, boroid, yr in candidates:
        start = f"{yr}-01-01T00:00:00.000"
        end = f"{yr}-12-31T23:59:59.999"
        key = f"{boro_name}_{yr}"
        print(f"Profiling {key}...")
        comp_cnt = query_soql(
            "ygpa-z7cr",
            {
                "$select": "count(*) as cnt",
                "$where": f"borough = '{boro_name}' AND received_date >= '{start}' AND received_date <= '{end}'",
            },
            timeout=90,
        )[0]["cnt"]
        viol_cnt = query_soql(
            "wvxf-dwi5",
            {
                "$select": "count(*) as cnt",
                "$where": f"boroid = {boroid} AND inspectiondate >= '{start}' AND inspectiondate <= '{end}'",
            },
            timeout=90,
        )[0]["cnt"]
        omo_cnt = query_soql(
            "mdbu-nrqn",
            {
                "$select": "count(*) as cnt",
                "$where": f"boro_id = {boroid} AND omocreatedate >= '{start}' AND omocreatedate <= '{end}'",
            },
            timeout=90,
        )[0]["cnt"]
        profile["candidates"][key] = {
            "borough": boro_name,
            "boroid": boroid,
            "year": yr,
            "complaints_problems_rows": int(comp_cnt),
            "violations_rows": int(viol_cnt),
            "omo_charges_rows": int(omo_cnt),
        }
        print(f"  -> {key}: complaints={comp_cnt}, violations={viol_cnt}, omo_charges={omo_cnt}")

    out_path = Path("data/exports/validation/m1_scope_profile.json")
    out_path.write_text(json.dumps(profile, indent=2), encoding="utf-8")
    print(f"Saved scope profile to {out_path}")


if __name__ == "__main__":
    import sys
    if "--profile-only" in sys.argv:
        profile_scope_candidates()
    else:
        inspect_metadata()
        profile_scope_candidates()

