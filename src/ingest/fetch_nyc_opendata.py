"""Reproducible NYC Open Data Socrata CSV acquisition utility for HomeRescue AI (M1).

Features:
- Deterministic ordering by source primary key ($order).
-Explicit column selection ($select) preserving official Socrata column order and verbatim values.
- Paginated CSV downloads ($limit / $offset) with resumable page cache.
- Bounded retries (max 4 attempts) with exponential backoff and explicit socket timeouts.
- Pre- and post-extraction Socrata row-count verification against the identical $where filter
  to verify extraction completeness and detect live source drift during acquisition.
- Parsed CSV row counting via Python's csv.reader (handling embedded commas/newlines accurately).
- SHA-256 file checksums and full provenance recorded in data/raw/manifest.json.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

USER_AGENT = "HomeRescue-AI-DataWarehouse/1.0 (Academic Capstone)"

DATASET_SPECS = {
    "buildings": {
        "source_id": "NYC-HPD-BLDG",
        "dataset_id": "kj4p-ruqc",
        "official_name": "Buildings Subject to HPD Jurisdiction",
        "portal_url": "https://data.cityofnewyork.us/d/kj4p-ruqc",
        "order_by": "buildingid ASC",
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
        "source_id": "NYC-HPD-COMP",
        "dataset_id": "ygpa-z7cr",
        "official_name": "Housing Maintenance Code Complaints and Problems",
        "portal_url": "https://data.cityofnewyork.us/d/ygpa-z7cr",
        "order_by": "problem_id ASC",
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
        "source_id": "NYC-HPD-VIOL",
        "dataset_id": "wvxf-dwi5",
        "official_name": "Housing Maintenance Code Violations",
        "portal_url": "https://data.cityofnewyork.us/d/wvxf-dwi5",
        "order_by": "violationid ASC",
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
        "source_id": "NYC-HPD-OMO",
        "dataset_id": "mdbu-nrqn",
        "official_name": "Open Market Order (OMO) Charges",
        "portal_url": "https://data.cityofnewyork.us/d/mdbu-nrqn",
        "order_by": "omoid ASC",
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

BOROUGH_MAP = {
    "MANHATTAN": {"boroid": "1", "upper": "MANHATTAN", "title": "Manhattan"},
    "BRONX": {"boroid": "2", "upper": "BRONX", "title": "Bronx"},
    "BROOKLYN": {"boroid": "3", "upper": "BROOKLYN", "title": "Brooklyn"},
    "QUEENS": {"boroid": "4", "upper": "QUEENS", "title": "Queens"},
    "STATEN ISLAND": {"boroid": "5", "upper": "STATEN ISLAND", "title": "Staten Island"},
}


def build_where_clause(entity: str, borough_key: str, start_date: str, end_date: str) -> str:
    b = BOROUGH_MAP[borough_key.upper()]
    start_ts = f"{start_date}T00:00:00.000"
    end_ts = f"{end_date}T23:59:59.999"
    if entity == "buildings":
        return f"boroid = {b['boroid']}"
    if entity == "complaints_problems":
        return (
            f"borough = '{b['upper']}' "
            f"AND received_date >= '{start_ts}' AND received_date <= '{end_ts}'"
        )
    if entity == "violations":
        return (
            f"boroid = {b['boroid']} "
            f"AND inspectiondate >= '{start_ts}' AND inspectiondate <= '{end_ts}'"
        )
    if entity == "omo_charges":
        return (
            f"boro_id = {b['boroid']} "
            f"AND omocreatedate >= '{start_ts}' AND omocreatedate <= '{end_ts}'"
        )
    raise ValueError(f"Unknown entity: {entity}")


def http_get_with_retry(url: str, timeout: int = 60, max_attempts: int = 4) -> bytes:
    last_err = None
    for attempt in range(1, max_attempts + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last_err = exc
            if attempt == max_attempts:
                break
            sleep_s = 2 ** attempt
            print(f"  [Retry {attempt}/{max_attempts}] {exc} -> sleeping {sleep_s}s...")
            time.sleep(sleep_s)
    raise RuntimeError(f"Failed to fetch {url} after {max_attempts} attempts: {last_err}")


def fetch_source_count(dataset_id: str, where_clause: str) -> int:
    params = {"$select": "count(*) as cnt", "$where": where_clause}
    url = f"https://data.cityofnewyork.us/resource/{dataset_id}.json?" + urllib.parse.urlencode(params)
    raw = http_get_with_retry(url)
    data = json.loads(raw.decode("utf-8"))
    return int(data[0]["cnt"]) if data else 0


def count_csv_records_from_text(csv_text: str) -> tuple[int, list[str]]:
    reader = csv.reader(io.StringIO(csv_text))
    header = next(reader, [])
    count = sum(1 for _ in reader)
    return count, header


def count_csv_records_in_file(path: Path) -> tuple[int, list[str]]:
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, [])
        count = sum(1 for _ in reader)
    return count, header


def compute_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def acquire_entity(
    entity: str,
    borough: str,
    start_date: str,
    end_date: str,
    out_dir: Path,
    cache_dir: Path,
    page_size: int = 25000,
    force: bool = False,
) -> dict:
    spec = DATASET_SPECS[entity]
    dataset_id = spec["dataset_id"]
    where_clause = build_where_clause(entity, borough, start_date, end_date)
    select_clause = ",".join(spec["columns"])
    order_clause = spec["order_by"]

    out_file = out_dir / f"{entity}.csv"
    entity_cache = cache_dir / entity
    entity_cache.mkdir(parents=True, exist_ok=True)

    started_at = datetime.now(timezone.utc).isoformat()
    pre_count = fetch_source_count(dataset_id, where_clause)
    print(f"[{entity}] ({dataset_id}) Pre-extraction source count: {pre_count:,} rows")

    if out_file.exists() and not force:
        existing_rows, existing_header = count_csv_records_in_file(out_file)
        if existing_rows == pre_count and existing_header == spec["columns"]:
            post_count = fetch_source_count(dataset_id, where_clause)
            sha = compute_sha256(out_file)
            print(f"[{entity}] Existing file verified ({existing_rows:,} rows, sha256={sha[:12]}...)")
            return {
                "entity": entity,
                "source_id": spec["source_id"],
                "dataset_id": dataset_id,
                "official_name": spec["official_name"],
                "portal_url": spec["portal_url"],
                "api_endpoint": f"https://data.cityofnewyork.us/resource/{dataset_id}.csv",
                "where_clause": where_clause,
                "order_by": order_clause,
                "columns": spec["columns"],
                "started_at_utc": started_at,
                "completed_at_utc": datetime.now(timezone.utc).isoformat(),
                "pre_extraction_source_count": pre_count,
                "post_extraction_source_count": post_count,
                "source_changed_during_extraction": pre_count != post_count,
                "csv_parsed_row_count": existing_rows,
                "physical_line_count": sum(1 for _ in out_file.open("r", encoding="utf-8")),
                "file_path": str(out_file.as_posix()),
                "file_size_bytes": out_file.stat().st_size,
                "sha256": sha,
                "pages_fetched": (existing_rows + page_size - 1) // page_size if existing_rows > 0 else 1,
            }

    offset = 0
    page_files: list[Path] = []
    pages_fetched = 0

    while True:
        page_file = entity_cache / f"page_{offset:09d}_{page_size}.csv"
        params = {
            "$select": select_clause,
            "$where": where_clause,
            "$order": order_clause,
            "$limit": str(page_size),
            "$offset": str(offset),
        }
        url = f"https://data.cityofnewyork.us/resource/{dataset_id}.csv?" + urllib.parse.urlencode(params)

        if page_file.exists() and not force:
            csv_text = page_file.read_text(encoding="utf-8")
            page_rows, _ = count_csv_records_from_text(csv_text)
            print(f"  [{entity}] Using cached page offset={offset} ({page_rows:,} rows)")
        else:
            print(f"  [{entity}] Downloading page offset={offset} limit={page_size}...")
            raw_bytes = http_get_with_retry(url)
            csv_text = raw_bytes.decode("utf-8")
            page_file.write_text(csv_text, encoding="utf-8")
            page_rows, _ = count_csv_records_from_text(csv_text)
            print(f"  [{entity}] Fetched {page_rows:,} rows at offset={offset}")

        page_files.append(page_file)
        pages_fetched += 1

        if page_rows < page_size:
            break
        offset += page_size

    # Assemble final CSV preserving exact raw strings and sanitizing any embedded CR/LF inside fields
    # only if requested; wait: preserve original downloaded values and column order verbatim!
    with out_file.open("w", encoding="utf-8", newline="") as out_f:
        writer = csv.writer(out_f, lineterminator="\n")
        writer.writerow(spec["columns"])
        for pf in page_files:
            with pf.open("r", encoding="utf-8", newline="") as in_f:
                reader = csv.reader(in_f)
                hdr = next(reader, None)
                if hdr and hdr != spec["columns"]:
                    raise RuntimeError(f"Header mismatch in {pf}: {hdr} != {spec['columns']}")
                for row in reader:
                    writer.writerow(row)

    post_count = fetch_source_count(dataset_id, where_clause)
    parsed_rows, final_header = count_csv_records_in_file(out_file)
    physical_lines = sum(1 for _ in out_file.open("r", encoding="utf-8"))
    sha = compute_sha256(out_file)
    completed_at = datetime.now(timezone.utc).isoformat()

    print(
        f"[{entity}] Completed: parsed_rows={parsed_rows:,}, "
        f"pre_count={pre_count:,}, post_count={post_count:,}, "
        f"physical_lines={physical_lines:,}, sha256={sha[:12]}..."
    )

    return {
        "entity": entity,
        "source_id": spec["source_id"],
        "dataset_id": dataset_id,
        "official_name": spec["official_name"],
        "portal_url": spec["portal_url"],
        "api_endpoint": f"https://data.cityofnewyork.us/resource/{dataset_id}.csv",
        "where_clause": where_clause,
        "order_by": order_clause,
        "columns": final_header,
        "started_at_utc": started_at,
        "completed_at_utc": completed_at,
        "pre_extraction_source_count": pre_count,
        "post_extraction_source_count": post_count,
        "source_changed_during_extraction": pre_count != post_count,
        "extraction_matches_source": parsed_rows in (pre_count, post_count),
        "csv_parsed_row_count": parsed_rows,
        "physical_line_count": physical_lines,
        "file_path": str(out_file.as_posix()),
        "file_size_bytes": out_file.stat().st_size,
        "sha256": sha,
        "pages_fetched": pages_fetched,
    }


def main():
    parser = argparse.ArgumentParser(description="Acquire NYC Open Data datasets for HomeRescue AI.")
    parser.add_argument("--borough", default="STATEN ISLAND", help="Target NYC borough name")
    parser.add_argument("--start-date", default="2024-01-01", help="Event start date (YYYY-MM-DD)")
    parser.add_argument("--end-date", default="2024-12-31", help="Event end date (YYYY-MM-DD)")
    parser.add_argument("--out-dir", default="data/raw", help="Output directory for CSV files")
    parser.add_argument("--page-size", type=int, default=25000, help="Socrata pagination size")
    parser.add_argument("--force", action="store_true", help="Force re-download ignoring cache")
    parser.add_argument("--pilot", action="store_true", help="Run pilot mode and save pilot manifest")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    scope_slug = f"{args.borough.lower().replace(' ', '_')}_{args.start_date}_{args.end_date}"
    cache_dir = out_dir / ".cache" / scope_slug

    manifest = {
        "project": "HomeRescue AI",
        "mode": "pilot" if args.pilot else "submission",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": {
            "borough": args.borough.upper(),
            "boroid": BOROUGH_MAP[args.borough.upper()]["boroid"],
            "start_date": args.start_date,
            "end_date": args.end_date,
            "rationale": (
                "Single complete NYC borough building reference population combined with all "
                "complaints/problems, housing code violations, and Open Market Order charges "
                "occurring within the shared calendar window."
            ),
        },
        "datasets": {},
    }

    for entity in ["buildings", "complaints_problems", "violations", "omo_charges"]:
        info = acquire_entity(
            entity=entity,
            borough=args.borough,
            start_date=args.start_date,
            end_date=args.end_date,
            out_dir=out_dir,
            cache_dir=cache_dir,
            page_size=args.page_size,
            force=args.force,
        )
        manifest["datasets"][entity] = info

    manifest_name = "manifest_pilot.json" if args.pilot else "manifest.json"
    manifest_path = out_dir / manifest_name
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"Wrote manifest to {manifest_path}")

    val_dir = Path("data/exports/validation")
    val_dir.mkdir(parents=True, exist_ok=True)
    val_manifest_path = val_dir / f"m1_{manifest_name}"
    val_manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
