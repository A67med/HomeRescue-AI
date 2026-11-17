"""Offline correctness gate before loading raw CSVs into SQL Server.

Prevents invalid or truncated source downloads from becoming apparently valid warehouse data.
Original user-upload ZIP contains embedded HTTP 500 error payloads in two members.
"""
from __future__ import annotations
import csv, hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path
from src.ingest.fetch_nyc_opendata import DATASET_SPECS, build_where_clause

COUNTS_FLOORS = {'buildings': 20000, 'complaints_problems': 10000, 'violations': 15000, 'omo_charges': 400}
DATE = {'buildings': None, 'complaints_problems':'received_date', 'violations':'inspectiondate', 'omo_charges':'omocreatedate'}
BORO = {'buildings':'boroid', 'complaints_problems':'borough', 'violations':'boroid', 'omo_charges':'boro_id'}

def check(raw_dir: Path = Path('data/raw')) -> dict:
    old_api_manifest = raw_dir / 'manifest.json'
    api_data = None
    if old_api_manifest.is_file():
        try:api_data = json.loads(old_api_manifest.read_text(encoding='utf-8'))
        except Exception: pass
    summary = {'checked_at_utc':datetime.now(timezone.utc).isoformat(), 'scope':'Staten Island, 2024', 'files':{},'status':'PASS'}
    failed = []
    for entity,spec in DATASET_SPECS.items():
        f = raw_dir / (entity+'.csv')
        if not f.exists():
            failed.append(f'{f}: MISSING')
            continue
        digest = hashlib.sha256()
        with open(f,'rb') as fp:
            for block in iter(lambda:fp.read(1024*1024),b''):digest.update(block)
        with f.open('r',encoding='utf-8-sig',newline='') as fp:
            r=csv.reader(fp);header=next(r,None); count=0; wrong_boro=0; wrong_date=0; broken=0
            if header != spec['columns']:
                failed.append(f'{f}: header mismatch; refusing to load');continue
            b_idx=header.index(BORO[entity]); d_idx=header.index(DATE[entity]) if DATE[entity] else None
            for row in r:
                count+=1
                if len(row)!=len(header):broken+=1;continue
                if row[b_idx].upper() != ('STATEN ISLAND' if entity=='complaints_problems' else '5'):
                    wrong_boro+=1
                if d_idx is not None and not row[d_idx].startswith('2024-'):
                    wrong_date+=1
        item={'dataset_id':spec['dataset_id'],'file':str(f),'sha256':digest.hexdigest(),'csv_rows':count,'columns':len(header),'wrong_borough':wrong_boro,'wrong_year':wrong_date,'malformed_records':broken,'source':spec['portal_url']}
        summary['files'][entity]=item
        if count < COUNTS_FLOORS[entity]:failed.append(f'{entity}: only {count} rows (sanity minimum {COUNTS_FLOORS[entity]})')
        if wrong_boro or wrong_date or broken:failed.append(f'{entity}: borough/date/format mismatch: {wrong_boro}/{wrong_date}/{broken}')
        # If the active SODA acquisition manifest says a source has a count, enforce it.
        if isinstance(api_data,dict) and entity in api_data.get('datasets',{}):
            api_item=api_data['datasets'][entity]
            source_count=api_item.get('post_extraction_source_count')
            if source_count is not None and count != source_count:
                failed.append(f'{entity}: {count} parsed != {source_count} API source rows')
    if failed:summary['status']='FAIL';summary['errors']=failed
    else:
        summary['total_rows']=sum(x['csv_rows'] for x in summary['files'].values())
        (raw_dir/'manifest.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    out=Path('data/exports/validation');out.mkdir(parents=True,exist_ok=True)
    (out/'source_inputs_verification.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(json.dumps(summary,indent=2))
    return summary

if __name__=='__main__':
    sys.exit(0 if check()['status']=='PASS' else 1)
