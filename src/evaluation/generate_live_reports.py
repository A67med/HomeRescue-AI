"""Produce current Bronze/Silver/Gold PDF evidence from the student's running SQL Server.
Never emits simulated results: queries live database and requires successful validation JSON.
"""
from __future__ import annotations
import json, shutil
from datetime import datetime,timezone
from decimal import Decimal
from pathlib import Path
from xml.sax.saxutils import escape
from sqlalchemy import text
from src.db import get_engine
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer, KeepTogether
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.colors import HexColor

NAVY=HexColor('#172941');TEAL=HexColor('#007F86');LIGHT=HexColor('#EAF2F3');GRAY=HexColor('#526174')
STYLES=getSampleStyleSheet();STYLES.add(ParagraphStyle(name='HeroX',parent=STYLES['Title'],fontSize=18,leading=22,textColor=NAVY,spaceAfter=12)); STYLES.add(ParagraphStyle(name='SectionX',parent=STYLES['Heading2'],fontSize=12,textColor=TEAL,spaceBefore=14,spaceAfter=7)); STYLES.add(ParagraphStyle(name='BodyX',parent=STYLES['BodyText'],fontSize=9,leading=13,spaceAfter=8)); STYLES.add(ParagraphStyle(name='CellX',parent=STYLES['BodyText'],fontSize=8,leading=10));

def q(con,sql):
    return con.execute(text(sql)).mappings().all()
def fmt(v):
    if v is None: return '-'
    if isinstance(v,Decimal):return f'{v:,.2f}'
    if isinstance(v,int):return f'{v:,}'
    return str(v)
def tbl(rows,widths=None):
    header_style = ParagraphStyle(name='HeaderCellNew',parent=STYLES['CellX'],textColor=HexColor('#FFFFFF'),fontName='Helvetica-Bold')
    elements=[[Paragraph(escape(fmt(c)),header_style if index==0 else STYLES['CellX']) for c in row] for index,row in enumerate(rows)]
    out=Table(elements,colWidths=widths,repeatRows=1,hAlign='LEFT')
    out.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),NAVY),('TEXTCOLOR',(0,0),(-1,0),HexColor('#FFFFFF')),('ROWBACKGROUNDS',(0,1),(-1,-1),[HexColor('#FFFFFF'),LIGHT]),('BOTTOMPADDING',(0,0),(-1,-1),7),('TOPPADDING',(0,0),(-1,-1),7),('LINEBELOW',(0,0),(-1,0),0.8,TEAL),('VALIGN',(0,0),(-1,-1),'TOP')]))
    return out

def p(txt):return Paragraph(txt,STYLES['BodyX'])
def section(name):return Paragraph(name,STYLES['SectionX'])
def make(report_name,title,story,out_root):
    path=out_root/(report_name+'.pdf')
    doc=SimpleDocTemplate(str(path),pagesize=landscape(A4),leftMargin=40,rightMargin=40,topMargin=35,bottomMargin=38,title=title,author='HomeRescue AI - Live SQL Server Evidence')
    stamp=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
    header=[Paragraph(escape(title),STYLES['HeroX']),p(f'<b>Source:</b> live database homerescue_dw | <b>Generated:</b> {stamp} | <b>Scope:</b> Staten Island, 2024'),p('All numbers on this report are queried from the current local SQL Server, not copied from previous run reports.')]
    def footer(canvas,doc):
        canvas.saveState();canvas.setFillColor(GRAY);canvas.setFont('Helvetica',8);canvas.drawString(40,20,'HomeRescue AI | NYC Housing Maintenance Data Warehouse');canvas.drawRightString(landscape(A4)[0]-40,20,f'Page {doc.page}');canvas.restoreState()
    doc.build(header+story,onFirstPage=footer,onLaterPages=footer)
    return path

def generate():
    val=Path('data/exports/validation/quality_checks_results_homerescue_dw.json')
    if not val.exists(): raise RuntimeError('Missing validation evidence. Run full SQL pipeline first.')
    result=json.loads(val.read_text(encoding='utf-8'))
    if result.get('overall_status')!='PASS' or result.get('failed_count')!=0:
        raise RuntimeError('Current validation not PASS; refusing to generate reports with a PASS statement.')
    engine=get_engine('homerescue_dw')
    with engine.connect() as con:
        counts=q(con,"""SELECT 'bronze.buildings' AS obj,COUNT_BIG(*) AS n FROM bronze.buildings UNION ALL SELECT 'bronze.complaints_problems',COUNT_BIG(*) FROM bronze.complaints_problems UNION ALL SELECT 'bronze.violations',COUNT_BIG(*) FROM bronze.violations UNION ALL SELECT 'bronze.omo_charges',COUNT_BIG(*) FROM bronze.omo_charges""")
        recon=q(con,"""SELECT source_table,silver_table,bronze_rows,accepted_rows,rejected_rows,duplicate_rows_removed,reconciliation_diff FROM silver.batch_reconciliation ORDER BY source_table""")
        dims=q(con,"""SELECT 'gold.dim_building' AS obj,COUNT_BIG(*) AS n FROM gold.dim_building UNION ALL SELECT 'gold.dim_date',COUNT_BIG(*) FROM gold.dim_date UNION ALL SELECT 'gold.fact_complaint_problem',COUNT_BIG(*) FROM gold.fact_complaint_problem UNION ALL SELECT 'gold.fact_violation',COUNT_BIG(*) FROM gold.fact_violation UNION ALL SELECT 'gold.fact_repair_order',COUNT_BIG(*) FROM gold.fact_repair_order UNION ALL SELECT 'gold.mart_building_month',COUNT_BIG(*) FROM gold.mart_building_month UNION ALL SELECT 'gold.features_building_maintenance',COUNT_BIG(*) FROM gold.features_building_maintenance UNION ALL SELECT 'semantic.metric_catalog',COUNT_BIG(*) FROM semantic.metric_catalog""")
        top=q(con,"""SELECT TOP 10 priority_rank,building_id,full_street_address,zip_code,maintenance_priority_score,class_c_violation_count_2024,class_b_violation_count_2024,eligible_repair_order_count_2024,intervention_gap_status FROM semantic.v_building_priority_ranking ORDER BY priority_rank,building_id""")
        insights=q(con,"""SELECT COUNT_BIG(*) AS total_buildings,SUM(CASE WHEN maintenance_priority_score >= 25 THEN 1 ELSE 0 END) AS high_hazard,SUM(CASE WHEN maintenance_priority_score >= 25 AND eligible_repair_order_count_2024=0 THEN 1 ELSE 0 END) AS high_hazard_without_eligible_omo,SUM(eligible_omo_award_amount_2024) AS eligible_award_usd FROM gold.features_building_maintenance""")[0]
        rejects=q(con,"""SELECT TOP 8 reason,COUNT_BIG(*) AS n FROM silver.reject_log GROUP BY reason ORDER BY COUNT_BIG(*) DESC,reason""")
    engine.dispose()
    out=Path('docs');out.mkdir(exist_ok=True)
    total=sum(r['n'] for r in counts)
    bronze=[section('1 | Ingestion & raw provenance'),p('Four NYC Open Data HPD source datasets, kept in Bronze as raw text fields with source_dataset_id, source_file, batch_id, raw_row_num and ingested_at.'),tbl([['Raw SQL table','Rows','Source ID']]+[[r['obj'],r['n'],{'bronze.buildings':'kj4p-ruqc','bronze.complaints_problems':'ygpa-z7cr','bronze.violations':'wvxf-dwi5','bronze.omo_charges':'mdbu-nrqn'}[r['obj']]] for r in counts],widths=[280,100,160]),Spacer(1,12),p(f'<b>Total Bronze rows: {total:,}</b> | Official source metadata & extraction checksums: data/raw/manifest.json')]
    make('BRONZE_REPORT','BRONZE | Source Ingestion',bronze,out)
    silver=[section('2 | Data cleaning & reconciliation'),p('Bronze = accepted Silver + rejected + removed duplicates. Every source row is accounted for.'),tbl([['Source table','Silver table','Bronze','Accepted','Rejected','Dupes','Diff']]+[[r['source_table'],r['silver_table'],r['bronze_rows'],r['accepted_rows'],r['rejected_rows'],r['duplicate_rows_removed'],r['reconciliation_diff']] for r in recon],widths=[170,155,80,80,80,65,70]),section('Rejection reasons'),tbl([['Reason','Rows']]+[[r['reason'],r['n']] for r in rejects] if rejects else [['Reason','Rows'],['No rejected records',0]],widths=[410,120]),p(f'Validation status: {result["overall_status"]}; SQL checks: {result["total_sql_checks"]}, semantic reconciliations: {result["total_metric_reconciliations"]}, failures: {result["failed_count"]}.')]
    make('SILVER_REPORT','SILVER | Cleaning & Reconciliation',silver,out)
    gold=[section('3 | Star schema & analytical features'),p('Gold uses persistent building and date dimensions, complaint/violation/repair atomic facts, one pre-aggregated building-month mart, plus a one-row-per-building feature view. Metrics are descriptive snapshots, not predictive ML risk probabilities.'),tbl([['Gold or Semantic object','Rows']]+[[r['obj'],r['n']] for r in dims],widths=[360,100]),section('Maintenance prioritization results'),p(f'<b>Total buildings:</b> {fmt(insights["total_buildings"])}. <b>High hazard (score >= 25):</b> {fmt(insights["high_hazard"])}. <b>High hazard without eligible OMO:</b> {fmt(insights["high_hazard_without_eligible_omo"])}. <b>Eligible awards (USD):</b> {fmt(insights["eligible_award_usd"])}.'),section('Top 10 priority buildings'),tbl([['Rank','Building ID','Address','ZIP','Score','Class C','Class B','Elig. OMO']]+[[r['priority_rank'],r['building_id'],r['full_street_address'],r['zip_code'],r['maintenance_priority_score'],r['class_c_violation_count_2024'],r['class_b_violation_count_2024'],r['eligible_repair_order_count_2024']] for r in top],widths=[45,75,280,58,58,62,62,72]),p('Priority score and intervention gap are determined by SQL views in sql/05_feature_views.sql and sql/04_semantic.sql. Eligible award is a contracted order amount, not proof of payment or savings.')]
    make('GOLD_REPORT','GOLD | Dimensions, Facts & Findings',gold,out)
    for layer in ('BRONZE','SILVER','GOLD'):
        dest=Path(f'{dict(BRONZE="03_Bronze",SILVER="04_Silver",GOLD="05_Gold")[layer]}/{layer}_REPORT.pdf')
        dest.parent.mkdir(exist_ok=True)
        shutil.copy2(out/(layer+'_REPORT.pdf'),dest)
    print('Generated current PDF reports from live SQL Server: docs/BRONZE_REPORT.pdf, SILVER_REPORT.pdf, GOLD_REPORT.pdf')

if __name__=='__main__':generate()
