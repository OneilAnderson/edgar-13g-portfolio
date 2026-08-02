# 04_export_for_powerbi.R
#
# Shapes the reconciled dataset into the flat, tidy table Power BI wants:
# one row per filing, clean column names, dates as actual dates, and a
# couple of derived fields that make for better dashboard visuals than
# raw days-to-file (e.g. a bucketed "timeliness" category).

library(dplyr)

main <- function() {
  reconciled <- read.csv("data/filings_reconciled.csv", stringsAsFactors = FALSE)

  export_tbl <- reconciled |>
    transmute(
      CIK = cik,
      Issuer = issuer_name,
      Filer = filer_name,
      FilerCategory = deadline_rule_used,
      FormType = form_type,
      IsAmendment = amendment_flag,
      EventDate = as.Date(event_date),
      FiledDate = as.Date(filed_date),
      DeadlineDate = as.Date(deadline_date),
      PercentOfClass = as.numeric(pct_of_class),
      DaysToFile = days_to_file,
      OnTime = case_when(
        is.na(on_time_flag) ~ "Unclassified",
        on_time_flag ~ "On Time",
        TRUE ~ "Late"
      ),
      TimelinessBucket = case_when(
        is.na(days_to_file) ~ "Unclassified",
        days_to_file <= 2 ~ "0-2 days",
        days_to_file <= 5 ~ "3-5 days",
        days_to_file <= 15 ~ "6-15 days",
        days_to_file <= 45 ~ "16-45 days",
        TRUE ~ "45+ days"
      )
    )

  write.csv(export_tbl, "data/reconciliation_output.csv", row.names = FALSE)
  message(sprintf("Exported %d rows to data/reconciliation_output.csv for Power BI import", nrow(export_tbl)))

  export_tbl
}

if (sys.nframe() == 0) main()
