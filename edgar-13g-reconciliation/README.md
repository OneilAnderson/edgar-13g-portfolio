# Schedule 13G/13D Beneficial Ownership Reconciliation (Public Data)

A self-contained R pipeline that pulls Schedule 13D/13G beneficial ownership
filings directly from SEC EDGAR, reconciles filing dates against the
post-September 2024 accelerated deadline rules, and exports a clean dataset
for a Power BI dashboard.

**Every data point in this project comes from SEC EDGAR's public APIs.**
No internal firm data, policy, or logic is used anywhere in this repo. The
reconciliation logic (deadline calculations, filer-type rules) is written
from the public rule text (17 CFR 240.13d-1/13d-2, as amended by Release
No. 33-11253) and is my own implementation, not any employer's.

## Why this project

Beneficial ownership reporting went through two major changes recently:

- **September 30, 2024** — accelerated filing deadlines for Schedule 13G
- **December 18, 2024** — mandatory XML structured data for Schedule 13D/13G

The XML mandate means filings after Dec 18, 2024 can be parsed as structured
data (percent of class, event date, and — usefully — the exact rule the
filer relies on, e.g. "Rule 13d-1(b)") instead of scraped out of free text.
This project builds a reconciliation pipeline around that.

## Pipeline

```
R/01_fetch_filings.R          Query EDGAR full-text search (efts.sec.gov) for
                              SCHEDULE 13G / 13D root forms in a date range;
                              amendments (/A) come back in the same query.
                              Chunks the date range to stay under the API's
                              10,000-hit pagination cap.
R/02_parse_xml_cover_pages.R  Fetch each filing's structured XML primary
                              document (one request per filing) and extract
                              issuer, filer, rule designation, event date,
                              percent of class, amendment number.
R/03_reconcile_deadlines.R    Classify each filing by its stated rule
                              designation, apply parameterized deadline rules
                              (with proper business-day math incl. federal
                              holidays), flag on-time vs late.
R/04_export_for_powerbi.R     Write one tidy CSV row per filing for Power BI.
```

## Setup

```r
install.packages(c("httr2", "jsonlite", "xml2", "dplyr", "purrr",
                   "lubridate", "yaml", "tidyr", "tibble"))
```

Then:

```sh
cp config/settings.yml.example config/settings.yml
# edit config/settings.yml: set your real "Name email" User-Agent
Rscript run_pipeline.R
```

SEC requires a descriptive `User-Agent` header on every request (name +
contact email, no key needed) — `config/settings.yml` is gitignored so that
contact info stays local. The pipeline throttles to ~5 req/sec, well under
EDGAR's 10 req/sec fair-access limit.

Start with a narrow date window (the example config uses ~2 weeks) to catch
problems cheaply; widen once it runs clean end to end.

## config/deadline_rules.yml

The day-counts by filer category live in config, not code, so the rule text
and the logic that applies it can be checked independently. The values were
verified against the e-CFR text of 17 CFR 240.13d-1 and 240.13d-2 (as
amended through Feb 2025); each rule in the YAML carries its citation.
The Feb 11, 2025 C&DIs (Q&A 103.11/103.12) affect Schedule 13G
*eligibility*, not deadlines, so they appear in the case study but not in
this file.

### Documented simplifications

- Amendments are reconciled against each category's baseline rule
  (13d-2(a)/(b)). The event-driven accelerated amendment triggers (first
  crossing 10%, ±5% swings thereafter) depend on changes *between* filings,
  which a single filing doesn't reveal; flagging those would require joining
  each filer's full amendment history.
- The QII accelerated initial deadline (>10% before quarter-end) is applied
  when the reported percent of class exceeds 10 — the best available proxy
  from a single cover page.

## Output

`data/reconciliation_output.csv` — one row per filing:

`AccessionNo`, `IssuerCIK`, `Issuer`, `Filer`, `ReportingPersons`,
`FilerCategory`, `FormType`, `IsAmendment`, `EventDate`, `FiledDate`,
`DeadlineDate`, `PercentOfClass`, `DaysToFile`, `DaysVsDeadline`, `OnTime`,
`ThresholdBucket`

This feeds the Power BI dashboard (filing timeliness by filer category,
days-to-file vs deadline distribution, threshold-crossing frequency).

## Rate limits

SEC EDGAR allows up to 10 requests/second. The scripts throttle to ~5/sec
by default (`requests_per_second` in `config/settings.yml`) and retry with
backoff on transient failures.
