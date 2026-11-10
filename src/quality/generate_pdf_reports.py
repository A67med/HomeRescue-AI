from __future__ import annotations

from pathlib import Path
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages


def _setup_page(title: str, subtitle: str):
    fig = plt.figure(figsize=(11, 8.5), dpi=150)
    fig.patch.set_facecolor("white")
    fig.text(0.04, 0.94, title, fontsize=14, fontweight="bold", color="#1B365D")
    fig.text(0.04, 0.91, subtitle, fontsize=9.5, color="#4A5568")
    return fig


def _style_table(tbl, fontsize: float = 8.5, scale_y: float = 1.55) -> None:
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(fontsize)
    tbl.scale(1.0, scale_y)
    for (row, col), cell in tbl.get_celld().items():
        if row == 0:
            cell.set_facecolor("#EDF2F7")
            cell.set_text_props(fontweight="bold", color="#1A202C")


def generate_bronze_pdf(out_path: Path) -> None:
    with PdfPages(out_path) as pdf:
        fig = _setup_page(
            "HomeRescue AI — Bronze Layer Ingestion & Profiling Report (M1-M2)",
            "Scope: NYC Open Data Staten Island (boroid = 5), Full Calendar Year 2024 (2024-01-01 to 2024-12-31)",
        )
        ax1 = fig.add_axes([0.04, 0.48, 0.92, 0.38])
        ax1.axis("off")
        headers = [
            "Bronze Table",
            "Socrata ID",
            "Natural Key",
            "Raw Cols",
            "CSV Rows",
            "Bronze Rows",
            "Duplicate Keys",
            "Status",
        ]
        rows = [
            ["bronze.buildings", "kj4p-ruqc", "buildingid", "23", "22,404", "22,404", "0", "PASS"],
            ["bronze.complaints_problems", "ygpa-z7cr", "problem_id", "33", "14,377", "14,377", "0", "PASS"],
            ["bronze.violations", "wvxf-dwi5", "violationid", "41", "18,463", "18,463", "0", "PASS"],
            ["bronze.omo_charges", "mdbu-nrqn", "omoid / omonumber", "32", "490", "490", "0", "PASS"],
            ["Total Warehouse Raw Scope", "4 Sources", "Connected", "129", "55,734", "55,734", "0", "PASS"],
        ]
        col_widths = [0.24, 0.10, 0.16, 0.08, 0.10, 0.11, 0.12, 0.09]
        tbl = ax1.table(cellText=rows, colLabels=headers, colWidths=col_widths, loc="center", cellLoc="center")
        _style_table(tbl, fontsize=8.5, scale_y=1.6)

        ax2 = fig.add_axes([0.08, 0.08, 0.84, 0.34])
        labels = [
            "Buildings\n(kj4p-ruqc)",
            "Violations\n(wvxf-dwi5)",
            "Complaint Problems\n(ygpa-z7cr)",
            "OMO Charges\n(mdbu-nrqn)",
        ]
        counts = [22404, 18463, 14377, 490]
        bars = ax2.bar(labels, counts, color=["#2B6CB0", "#C53030", "#DD6B20", "#2F855A"], width=0.5)
        ax2.set_title("Extracted & Verified 2024 Staten Island Row Counts by Source Dataset", fontsize=11, fontweight="bold")
        ax2.set_ylabel("Row Count")
        ax2.set_ylim(0, 26000)
        for b in bars:
            h = b.get_height()
            ax2.text(
                b.get_x() + b.get_width() / 2,
                h + 400,
                f"{h:,}",
                ha="center",
                va="bottom",
                fontsize=9,
                fontweight="bold",
            )
        pdf.savefig(fig)
        plt.close(fig)


def generate_silver_pdf(out_path: Path) -> None:
    with PdfPages(out_path) as pdf:
        fig = _setup_page(
            "HomeRescue AI — Silver Layer Cleaning & Reconciliation Report (M3)",
            "Equation Verified: Bronze Rows = Silver Accepted Rows + Silver Rejected Rows + Duplicate Rows Removed",
        )
        ax1 = fig.add_axes([0.03, 0.50, 0.94, 0.36])
        ax1.axis("off")
        headers = [
            "Source Table",
            "Silver Table",
            "Bronze",
            "Accepted",
            "Rejected",
            "Dupes",
            "Matched Bldg",
            "Unmatched",
            "Diff",
        ]
        rows = [
            ["bronze.buildings", "silver.building", "22,404", "22,329", "75", "0", "22,329 (100%)", "0 (0.00%)", "0"],
            [
                "bronze.complaints_problems",
                "silver.complaint_problem",
                "14,377",
                "14,377",
                "0",
                "0",
                "14,342 (99.76%)",
                "35 (0.24%)",
                "0",
            ],
            ["bronze.violations", "silver.violation", "18,463", "18,463", "0", "0", "18,446 (99.91%)", "17 (0.09%)", "0"],
            ["bronze.omo_charges", "silver.omo_charge", "490", "490", "0", "0", "484 (98.78%)", "6 (1.22%)", "0"],
            ["Total All Sources", "4 Silver Tables", "55,734", "55,659", "75", "0", "55,601 (99.90%)", "58 (0.10%)", "0"],
        ]
        col_widths = [0.21, 0.19, 0.08, 0.08, 0.07, 0.06, 0.14, 0.11, 0.06]
        tbl = ax1.table(cellText=rows, colLabels=headers, colWidths=col_widths, loc="center", cellLoc="center")
        _style_table(tbl, fontsize=8.0, scale_y=1.6)

        ax2 = fig.add_axes([0.07, 0.08, 0.40, 0.35])
        v_classes = ["Class C\n(Imm. Haz)", "Class B\n(Hazardous)", "Class A\n(Non-Haz)", "Class I\n(Admin Order)"]
        v_counts = [4763, 8300, 2969, 2431]
        bars = ax2.bar(v_classes, v_counts, color=["#9B2C2C", "#DD6B20", "#3182CE", "#718096"])
        ax2.set_title("2024 Violations by HMC Class (Total = 18,463)", fontsize=10, fontweight="bold")
        ax2.set_ylim(0, 9600)
        for b in bars:
            h = b.get_height()
            ax2.text(
                b.get_x() + b.get_width() / 2,
                h + 150,
                f"{h:,}",
                ha="center",
                va="bottom",
                fontsize=8.5,
                fontweight="bold",
            )

        ax3 = fig.add_axes([0.55, 0.08, 0.38, 0.35])
        cohorts = ["Eligible Residential\nRepairs (458 orders)", "Excluded Demolitions &\nAdmin Orders (32 orders)"]
        awards = [983560.44, 2098049.00]
        bars3 = ax3.bar(cohorts, awards, color=["#2F855A", "#A0AEC0"], width=0.45)
        ax3.set_title("OMO Award Dollars: Eligible Repairs vs. Excluded ($)", fontsize=10, fontweight="bold")
        ax3.set_ylim(0, 2450000)
        for b in bars3:
            h = b.get_height()
            ax3.text(
                b.get_x() + b.get_width() / 2,
                h + 40000,
                f"${h:,.2f}",
                ha="center",
                va="bottom",
                fontsize=8.5,
                fontweight="bold",
            )

        pdf.savefig(fig)
        plt.close(fig)


def generate_gold_pdf(out_path: Path) -> None:
    with PdfPages(out_path) as pdf:
        # Page 1: Intervention Gap & ZIP Code Hazardous Violations
        fig1 = _setup_page(
            "HomeRescue AI — Gold Layer, Semantic Metrics & Business Analytics Report (M4-M5)",
            "Page 1 of 2: Building Maintenance Priority Tiers, OMO Intervention Gap & ZIP Code Distribution",
        )
        ax1 = fig1.add_axes([0.03, 0.50, 0.94, 0.36])
        ax1.axis("off")
        headers = [
            "Intervention Gap Status",
            "Bldgs",
            "Share %",
            "Complaints",
            "Problems",
            "Class B+C",
            "Open Viol",
            "Elig OMOs",
            "Elig OMO Award",
        ]
        rows = [
            ["HIGH_HAZARD_WITH_ELIGIBLE_OMO (Score >= 25)", "137", "0.61%", "2,448", "5,144", "7,687", "1,503", "376", "$751,413.00"],
            ["HIGH_HAZARD_UNADDRESSED_BY_OMO (Score >= 25)", "339", "1.52%", "2,626", "5,461", "4,343", "2,376", "0", "$0.00"],
            ["MODERATE_HAZARD_UNADDRESSED_BY_OMO (1-24)", "2,311", "10.35%", "1,748", "3,176", "969", "1,811", "0", "$0.00"],
            ["MODERATE_HAZARD_WITH_ELIGIBLE_OMO (1-24)", "34", "0.15%", "46", "84", "64", "20", "37", "$55,303.34"],
            ["LOW_OR_ZERO_HAZARD_NO_OMO (Score = 0)", "19,479", "87.22%", "457", "499", "0", "0", "0", "$0.00"],
            ["LOW_HAZARD_WITH_ELIGIBLE_OMO (Score = 0)", "33", "0.15%", "9", "13", "0", "0", "45", "$176,844.10"],
            ["Total Staten Island Building Spine", "22,333", "100.00%", "7,334", "14,377", "13,063", "5,710", "458", "$983,560.44"],
        ]
        col_widths = [0.34, 0.07, 0.07, 0.08, 0.08, 0.08, 0.08, 0.08, 0.12]
        tbl = ax1.table(cellText=rows, colLabels=headers, colWidths=col_widths, loc="center", cellLoc="center")
        _style_table(tbl, fontsize=7.8, scale_y=1.48)

        ax2 = fig1.add_axes([0.07, 0.08, 0.86, 0.35])
        zips = ["10304", "10301", "10303", "10302", "10314", "10310", "10305", "10306", "10312", "10308", "10309", "10307"]
        bc_viols = [5787, 2454, 1066, 842, 690, 605, 603, 577, 195, 110, 90, 29]
        bars = ax2.bar(zips, bc_viols, color="#2B6CB0")
        ax2.set_title("2024 Hazardous Violations (Class B + Class C) by Staten Island ZIP Code", fontsize=10.5, fontweight="bold")
        ax2.set_xlabel("Staten Island ZIP Code")
        ax2.set_ylabel("Class B + C Violations")
        ax2.set_ylim(0, 6500)
        for b in bars:
            h = b.get_height()
            ax2.text(
                b.get_x() + b.get_width() / 2,
                h + 90,
                f"{h:,}",
                ha="center",
                va="bottom",
                fontsize=8,
                fontweight="bold",
            )
        pdf.savefig(fig1)
        plt.close(fig1)

        # Page 2: Monthly Trajectory & Top 10 Buildings
        fig2 = _setup_page(
            "HomeRescue AI — Gold Layer, Semantic Metrics & Business Analytics Report (M4-M5)",
            "Page 2 of 2: Monthly Seasonal Trajectory (2024-01 to 2024-12) & Top 10 Priority Buildings",
        )
        ax3 = fig2.add_axes([0.07, 0.53, 0.86, 0.32])
        months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        problems = [1826, 1227, 1158, 959, 792, 879, 1112, 1156, 1157, 1283, 1233, 1595]
        bc_month = [1049, 793, 891, 1042, 1062, 2211, 857, 1313, 924, 884, 885, 1152]
        ax3.plot(months, problems, marker="o", linewidth=2, color="#DD6B20", label="Complaint Problems (Total=14,377)")
        ax3.plot(months, bc_month, marker="s", linewidth=2, color="#C53030", label="Hazardous Class B+C Violations (Total=13,063)")
        ax3.set_title("2024 Monthly Trajectory: Complaint Problems vs. Hazardous Class B+C Violations", fontsize=10.5, fontweight="bold")
        ax3.set_ylabel("Monthly Event Count")
        ax3.legend(loc="upper center", ncol=2, frameon=True)
        ax3.grid(True, linestyle="--", alpha=0.4)

        ax4 = fig2.add_axes([0.03, 0.05, 0.94, 0.41])
        ax4.axis("off")
        b_headers = ["Rank", "building_id", "Address", "ZIP", "Units", "Problems", "Class C", "Class B", "Eligible OMOs ($)", "Priority Score"]
        b_rows = [
            ["1", "812537", "185 PARK HILL AVENUE", "10304", "150", "481", "357", "442", "31 ($43,348.25)", "3,699"],
            ["2", "769128", "240 PARK HILL AVENUE", "10304", "134", "260", "297", "536", "24 ($59,127.00)", "3,675"],
            ["3", "769127", "225 PARK HILL AVENUE", "10304", "151", "298", "285", "501", "33 ($50,191.25)", "3,518"],
            ["4", "769123", "140 PARK HILL AVENUE", "10304", "132", "237", "232", "338", "22 ($47,755.00)", "2,464"],
            ["5", "812535", "160 PARKHILL AVENUE", "10304", "132", "205", "183", "313", "11 ($22,720.00)", "2,105"],
            ["6", "812539", "280 PARKHILL AVENUE", "10304", "137", "236", "217", "172", "2 ($6,377.00)", "1,888"],
            ["7", "812538", "260 PARKHILL AVENUE", "10304", "132", "236", "138", "129", "7 ($15,307.00)", "1,295"],
            ["8", "812536", "180 PARKHILL AVENUE", "10304", "141", "181", "125", "68", "1 ($3,500.00)", "1,043"],
            ["9", "767602", "55 BOWEN STREET (UNADDRESSED)", "10304", "156", "58", "64", "55", "0 ($0.00 - GAP)", "631"],
            ["10", "812434", "101 DANIEL LOW TERRACE", "10301", "56", "93", "51", "70", "1 ($2,280.00)", "555"],
        ]
        col_widths4 = [0.05, 0.09, 0.24, 0.06, 0.06, 0.08, 0.07, 0.07, 0.17, 0.11]
        tbl4 = ax4.table(cellText=b_rows, colLabels=b_headers, colWidths=col_widths4, loc="center", cellLoc="center")
        _style_table(tbl4, fontsize=8.0, scale_y=1.36)
        pdf.savefig(fig2)
        plt.close(fig2)


def main():
    docs_dir = Path("docs")
    generate_bronze_pdf(docs_dir / "BRONZE_REPORT.pdf")
    generate_silver_pdf(docs_dir / "SILVER_REPORT.pdf")
    generate_gold_pdf(docs_dir / "GOLD_REPORT.pdf")
    print("Generated docs/BRONZE_REPORT.pdf, docs/SILVER_REPORT.pdf, and docs/GOLD_REPORT.pdf.")


if __name__ == "__main__":
    main()
