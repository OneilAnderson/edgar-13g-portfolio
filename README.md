# Schedule 13G/13D Beneficial Ownership Reconciliation (Public Data)

A self-contained project that pulls Schedule 13D/13G beneficial ownership
filings directly from SEC EDGAR, reconciles filing dates against the
post-September 2024 accelerated deadline rules, and exports a clean dataset
for a Power BI dashboard.

**Every data point in this project comes from SEC EDGAR's public APIs.**
No internal firm data, policy, or logic is used anywhere in this repo. The
reconciliation logic (deadline calculations, filer-type rules) is written
from the public rule text (Release No. 33-11253) and is my own
implementation, not any employer's.

## Why this project

Beneficial ownership reporting went through two major changes recently:
- **September 30, 2024** — accelerated filing deadlines for Schedule 13G
- **December 18, 2024** — mandatory XML structured data for Schedule 13D/13G

The XML mandate means, for the first time, filings after Dec 18 2024 can be
parsed as structured data (percent of class, event date, filer type) instead
of scraped out of free text. This project builds a pipeline around that.

## Pipeline

```
R/01_fetch_filings.R          Query EDGAR full-text search for SCHEDULE 13G /
                               SCHEDULE 13G-A / SCHEDULE 13D filings in a date range
R/02_parse_xml_cover_pages.R  Pull each filing's XML cover page, extract structured
                               fields (issuer, filer, event date, % of class, filer type)
R/03_reconcile_deadlines.R    Apply parameterized deadline rules by filer type,
                               flag on-time vs late, compute days-to-file
R/04_export_for_powerbi.R     Write a tidy CSV/Parquet for Power BI import
```

## Setup

```r
install.packages(c("httr2", "jsonlite", "xml2", "dplyr", "purrr", "lubridate", "arrow"))
```

SEC requires a descriptive `User-Agent` header on every request (name + contact
email, no key needed). Set yours in `config/settings.yml` before running
`01_fetch_filings.R` — requests without one get blocked.

## config/deadline_rules.yml

The exact day-counts by filer type (Qualified Institutional Investor, Exempt
Investor, Passive Investor >5%/>10%, etc.) are pulled out into this config
file rather than hardcoded, on purpose — **confirm the current values against
17 CFR 240.13d-1/13d-2 and the Feb 2025 SEC C&DI guidance before treating
this as authoritative.** I'd rather you (or anyone reviewing this repo)
verify the numbers than trust a hardcoded constant in a script.

## Output

`data/reconciliation_output.csv` — one row per filing, with:
`cik`, `issuer`, `filer`, `filer_type`, `form_type`, `event_date`,
`filed_date`, `pct_of_class`, `deadline_date`, `days_to_file`, `on_time_flag`

This feeds directly into the Power BI dashboard (filing timeliness by filer
type, threshold-crossing frequency, days-to-file distribution).

## Rate limits

SEC EDGAR allows up to 10 requests/second. The fetch scripts throttle to a
safer ~5/sec by default — adjust in `config/settings.yml` if needed.
