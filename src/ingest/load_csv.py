"""Load raw NYC Open Data CSV files into SQL Server Bronze tables via safe staging swap.

Supports:
- Loading all four datasets in a directory:
    python -m src.ingest.load_csv
    python -m src.ingest.load_csv --data-dir data/raw/pilot
- Loading a single CSV file by path:
    python -m src.ingest.load_csv data/raw/buildings.csv
- Targeting an explicit database (e.g. homerescue_dw_verify):
    python -m src.ingest.load_csv --database homerescue_dw_verify
"""

from __future__ import annotations

import argparse
import csv
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from sqlalchemy import text
from src.db import get_database_name, get_engine

ENTITY_CONFIG = {
    "buildings": {
        "filename": "buildings.csv",
        "stg_table": "bronze.stg_buildings",
        "target_table": "bronze.buildings",
        "proc_name": "bronze.load_buildings",
        "columns": [
            "buildingid", "boroid", "boro", "housenumber", "lowhousenumber",
            "highhousenumber", "streetname", "zip", "block", "lot", "bin",
            "communityboard", "censustract", "managementprogram",
            "dobbuildingclassid", "dobbuildingclass", "legalstories",
            "legalclassa", "legalclassb", "registrationid", "lifecycle",
            "recordstatusid", "recordstatus",
        ],
    },
    "complaints_problems": {
        "filename": "complaints_problems.csv",
        "stg_table": "bronze.stg_complaints_problems",
        "target_table": "bronze.complaints_problems",
        "proc_name": "bronze.load_complaints_problems",
        "columns": [
            "received_date", "problem_id", "complaint_id", "building_id",
            "borough", "house_number", "street_name", "post_code", "block",
            "lot", "apartment", "community_board", "unit_type", "space_type",
            "type", "major_category", "minor_category", "problem_code",
            "complaint_status", "complaint_status_date", "problem_status",
            "problem_status_date", "status_description",
            "problem_duplicate_flag", "complaint_anonymous_flag", "unique_key",
            "latitude", "longitude", "council_district", "census_tract",
            "bin", "bbl", "nta",
        ],
    },
    "violations": {
        "filename": "violations.csv",
        "stg_table": "bronze.stg_violations",
        "target_table": "bronze.violations",
        "proc_name": "bronze.load_violations",
        "columns": [
            "violationid", "buildingid", "registrationid", "boroid", "boro",
            "housenumber", "lowhousenumber", "highhousenumber", "streetname",
            "streetcode", "zip", "apartment", "story", "block", "lot", "class",
            "inspectiondate", "approveddate", "originalcertifybydate",
            "originalcorrectbydate", "newcertifybydate", "newcorrectbydate",
            "certifieddate", "ordernumber", "novid", "novdescription",
            "novissueddate", "currentstatusid", "currentstatus",
            "currentstatusdate", "novtype", "violationstatus", "rentimpairing",
            "latitude", "longitude", "communityboard", "councildistrict",
            "censustract", "bin", "bbl", "nta",
        ],
    },
    "omo_charges": {
        "filename": "omo_charges.csv",
        "stg_table": "bronze.stg_omo_charges",
        "target_table": "bronze.omo_charges",
        "proc_name": "bronze.load_omo_charges",
        "columns": [
            "omoid", "omonumber", "buildingid", "boro_id", "boro",
            "housenumber", "streetname", "apartment", "zip", "block", "lot",
            "lifecycle", "worktypegeneral", "omostatusreason",
            "omoawardamount", "omocreatedate", "netchangeorders",
            "omoawarddate", "isaep", "iscommercialdemolition",
            "servicechargeflag", "femaeventid", "femaevent", "omodescription",
            "latitude", "longitude", "community_board", "council_district",
            "census_tract", "bin", "bbl", "nta",
        ],
    },
}


def load_entity_csv(
    engine,
    entity: str,
    csv_path: Path,
    batch_id: str | None = None,
    chunk_size: int = 5000,
) -> dict:
    cfg = ENTITY_CONFIG[entity]
    cols = cfg["columns"]
    stg_table = cfg["stg_table"]
    target_table = cfg["target_table"]
    proc_name = cfg["proc_name"]
    batch_uid = batch_id or str(uuid.uuid4())
    resolved_path = str(csv_path.resolve())

    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if header != cols:
            raise ValueError(
                f"Header mismatch in {csv_path}: got {header}, expected {cols}"
            )

        raw_conn = engine.raw_connection()
        try:
            cur = raw_conn.cursor()
            cur.fast_executemany = True
            cur.execute(f"TRUNCATE TABLE {stg_table};")
            placeholders = ", ".join(["?"] * (len(cols) + 1))
            col_list = ", ".join(["raw_row_num"] + cols)
            insert_sql = f"INSERT INTO {stg_table} ({col_list}) VALUES ({placeholders})"

            batch_rows = []
            parsed_row_count = 0
            for idx, row in enumerate(reader, start=1):
                parsed_row_count += 1
                # Preserve exact raw strings; convert empty string "" to None so SQL stores NULL
                # or preserve empty string? Wait: in BULK INSERT CSV, empty unquoted fields become NULL.
                # Converting empty string "" to None matches BULK INSERT NULL semantics while keeping
                # any whitespace-only or non-empty string verbatim.
                cleaned_row = [ idx ] + [ (val if val != "" else None) for val in row ]
                batch_rows.append(cleaned_row)
                if len(batch_rows) >= chunk_size:
                    cur.executemany(insert_sql, batch_rows)
                    batch_rows.clear()

            if batch_rows:
                cur.executemany(insert_sql, batch_rows)
                batch_rows.clear()

            raw_conn.commit()
        finally:
            raw_conn.close()

    with engine.begin() as con:
        con.execute(
            text(f"EXEC {proc_name} @file_path = :p, @batch_id = :b, @use_staged = 1"),
            {"p": resolved_path, "b": batch_uid},
        )
        bronze_count = int(
            con.execute(text(f"SELECT COUNT_BIG(*) FROM {target_table}")).scalar()
        )

    if bronze_count != parsed_row_count:
        raise RuntimeError(
            f"Row count mismatch for {target_table}: CSV parsed {parsed_row_count} != Bronze {bronze_count}"
        )

    print(
        f"Loaded {bronze_count:,} rows into {target_table} from {resolved_path} "
        f"(CSV parsed={parsed_row_count:,}, batch_id={batch_uid})"
    )
    return {
        "entity": entity,
        "target_table": target_table,
        "file_path": resolved_path,
        "batch_id": batch_uid,
        "csv_parsed_rows": parsed_row_count,
        "bronze_rows": bronze_count,
        "reconciled": bronze_count == parsed_row_count,
    }


def main():
    parser = argparse.ArgumentParser(description="Load NYC Open Data CSVs into Bronze.")
    parser.add_argument("single_file", nargs="?", help="Optional single CSV file path")
    parser.add_argument("--data-dir", default="data/raw", help="Directory containing raw CSVs")
    parser.add_argument("--database", default=None, help="Target SQL Server database override")
    args = parser.parse_args()

    target_db = args.database or get_database_name()
    engine = get_engine(database=target_db)
    batch_id = str(uuid.uuid4())
    results = []

    if args.single_file:
        p = Path(args.single_file)
        stem = p.stem.lower()
        if stem not in ENTITY_CONFIG:
            raise ValueError(f"Unrecognized CSV filename stem '{stem}'. Expected one of {list(ENTITY_CONFIG)}")
        results.append(load_entity_csv(engine, stem, p, batch_id=batch_id))
    else:
        data_dir = Path(args.data_dir)
        for entity, cfg in ENTITY_CONFIG.items():
            csv_path = data_dir / cfg["filename"]
            if not csv_path.exists():
                raise FileNotFoundError(f"Expected CSV file not found: {csv_path}")
            results.append(load_entity_csv(engine, entity, csv_path, batch_id=batch_id))

    out_dir = Path("data/exports/validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"bronze_load_reconciliation_{target_db}.json"
    out_file.write_text(
        json.dumps(
            {
                "database": target_db,
                "batch_id": batch_id,
                "executed_at_utc": datetime.now(timezone.utc).isoformat(),
                "tables": results,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"Saved Bronze load reconciliation evidence to {out_file}")


if __name__ == "__main__":
    main()
