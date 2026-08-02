# Power BI Build Spec — EDGAR 13D/13G Reconciliation

Import `data/reconciliation_output.csv` (Get Data → Text/CSV). Name the
table `Reconciliation`. In Power Query, confirm types: `EventDate`,
`FiledDate`, `DeadlineDate` as Date; `PercentOfClass`, `DaysToFile`,
`DaysVsDeadline` as Decimal; `IssuerCIK` and `AccessionNo` as Text.

## Theme (do this first)

View → Themes → Browse for themes → `powerbi/edgar_accessible_theme.json`.

All palette colors pass WCAG AA at 4.5:1 on white (verified):

| Use | Hex | Contrast on white |
|---|---|---|
| On Time / primary | `#1A5276` | 8.4:1 |
| Late | `#B34700` | 5.5:1 |
| QII | `#0F6E5C` | 6.2:1 |
| Passive | `#7B3294` | 7.7:1 |
| Exempt | `#8A5A00` | 5.9:1 |
| Unclassified / neutral | `#595959` | 7.0:1 |
| Axis & label text | `#404040` | 10.4:1 |

Why not the default theme: `#D9B300` (yellow) is 2.02:1 on white — fails
even the 3:1 graphical minimum — and several other defaults clear 3:1 but
not the 4.5:1 required wherever color carries text. Blue/orange for
on-time/late (instead of green/red) stays legible for deuteranopia and
protanopia. Never encode meaning in color alone: keep data labels on.

## Date table

Modeling → New table:

```dax
Calendar =
ADDCOLUMNS(
    CALENDAR(DATE(2026, 2, 1), DATE(2026, 7, 31)),
    "Month", FORMAT([Date], "MMM YYYY"),
    "MonthSort", YEAR([Date]) * 100 + MONTH([Date]),
    "Week Starting", [Date] - WEEKDAY([Date], 2) + 1
)
```

Sort `Month` by `MonthSort`. Mark as date table. Relate
`Calendar[Date]` → `Reconciliation[FiledDate]` (many-to-one, single).

## Measures

```dax
Filings = COUNTROWS(Reconciliation)

Classified Filings =
CALCULATE([Filings], Reconciliation[OnTime] <> "Unclassified")

Late Filings = CALCULATE([Filings], Reconciliation[OnTime] = "Late")

On-Time Filings = CALCULATE([Filings], Reconciliation[OnTime] = "On Time")

Late Rate = DIVIDE([Late Filings], [Classified Filings])          -- format %

On-Time Rate = DIVIDE([On-Time Filings], [Classified Filings])    -- format %

Median Days to File = MEDIAN(Reconciliation[DaysToFile])

Median Days vs Deadline = MEDIAN(Reconciliation[DaysVsDeadline])

Initial Filings =
CALCULATE([Filings], Reconciliation[IsAmendment] = "Initial")

Distinct Issuers = DISTINCTCOUNT(Reconciliation[IssuerCIK])

Distinct Filers = DISTINCTCOUNT(Reconciliation[Filer])
```

## Page 1 — Filing Timeliness by Filer Category

- Four KPI cards across the top: `Filings`, `On-Time Rate`,
  `Late Filings`, `Median Days to File`.
- **100% stacked bar chart**: Y-axis `FilerCategory`, legend `OnTime`
  (On Time `#1A5276`, Late `#B34700`, Unclassified `#595959`), values
  `Filings`. Data labels on.
- **Clustered column chart**: X-axis `FilerCategory`, legend
  `IsAmendment`, values `Late Rate`. This is the analytical punchline:
  passive filers' 5-business-day clock vs QIIs' 45-days-after-quarter-end.
- Slicers (left rail): `FormType`, `IsAmendment`, `FiledDate`
  (between-dates).

## Page 2 — Days-to-File vs Deadline

- **Column chart (histogram)**: create a bin on `DaysVsDeadline`
  (right-click field → New group → Bin size 2). X-axis the bins, values
  `Filings`. Conditional formatting on bar color: `#1A5276` when
  ≤ 0 (on time), `#B34700` when > 0 (late). Add a constant line at 0
  (Analytics pane), labeled "Deadline".
- **Clustered bar**: `Median Days vs Deadline` by `FilerCategory` —
  how much headroom each category typically leaves.
- **Scatter**: X `DaysToFile`, Y `PercentOfClass`, legend
  `FilerCategory`, details `AccessionNo`. Shows whether bigger stakes
  file faster.

## Page 3 — Threshold Crossings Over Time

- **Stacked column chart**: X `Calendar[Month]`, legend
  `ThresholdBucket`, values `Initial Filings` — new >5% positions per
  month by size of stake.
- **Line chart**: X `Calendar[Week Starting]`, Y `Filings`, legend
  `FilerCategory` (line markers ON — shape redundancy, not just color).
  Expect visible spikes ~45 days after quarter-ends (mid-Feb, mid-May)
  from the QII/exempt quarterly deadline cluster — annotate one spike
  with a text box.
- **Table**: `Issuer`, `Filings`, `Late Filings`, `Distinct Filers`,
  sorted by `Filings` descending — most-targeted issuers.

## Accessibility checklist (before screenshotting)

1. Alt text on every visual: select visual → Format → General → Alt text.
   Write what the visual *shows*, not what it is ("Passive investors have
   a ~25% late rate vs under 1% for QIIs", not "bar chart").
2. Tab order: View → Selection pane → Tab order — match visual reading
   order (title → KPIs → main chart → slicers).
3. Data labels on for all bar/column charts; line charts get markers.
4. Minimum 10pt text everywhere (theme enforces this); KPI callouts 24pt.
5. Slicer state visible in screenshots — if a screenshot shows filtered
   data, the slicer showing the filter must be in frame.
6. Check every page with a colorblindness simulator (e.g., Color Oracle,
   free on Mac) before taking finals.

## Screenshot protocol

- View → Actual size, then screenshot the full report canvas per page
  (Cmd+Shift+4 + Space, click the window — no browser chrome or Desktop
  panes in frame).
- PNG format, one per page, named `pbi-timeliness.png`,
  `pbi-days-to-file.png`, `pbi-threshold-crossings.png`.
- These are the only dashboard images that go on the site — built entirely
  from `data/reconciliation_output.csv` (public EDGAR data).
