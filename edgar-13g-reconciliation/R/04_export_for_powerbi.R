# 04_export_for_powerbi.R
#
# Shapes the reconciled dataset into the flat, tidy table Power BI wants:
# one row per filing, clean column names, real dates, and derived fields
# that make for better visuals than raw day-counts.

library(dplyr)

main_export <- function() {
  reconciled <- read.csv("data/filings_reconciled.csv", stringsAsFactors = FALSE,
                         colClasses = c(cik = "character", issuer_cik = "character"))

  export_tbl <- reconciled |>
    transmute(
      AccessionNo = accession_no,
      IssuerCIK = issuer_cik,
      Issuer = issuer_name,
      Filer = filer_name,
      ReportingPersons = n_reporting_persons,
      FilerCategory = case_when(
        filer_category == "qualified_institutional_investor" ~ "QII (13d-1(b))",
        filer_category == "passive_investor" ~ "Passive (13d-1(c))",
        filer_category == "exempt_investor" ~ "Exempt (13d-1(d))",
        filer_category == "schedule_13d_filer" ~ "Schedule 13D",
        TRUE ~ "Unclassified"
      ),
      FormType = form_type,
      IsAmendment = ifelse(is_amendment, "Amendment", "Initial"),
      EventDate = as.Date(event_date),
      FiledDate = as.Date(filed_date),
      DeadlineDate = as.Date(deadline_date),
      PercentOfClass = pct_of_class,
      DaysToFile = days_to_file,
      DaysVsDeadline = days_vs_deadline,   # negative = filed early, positive = late
      OnTime = case_when(
        is.na(on_time_flag) ~ "Unclassified",
        on_time_flag ~ "On Time",
        TRUE ~ "Late"
      ),
      ThresholdBucket = case_when(
        is.na(pct_of_class) ~ "Unknown",
        pct_of_class <= 5 ~ "<=5%",
        pct_of_class <= 10 ~ "5-10%",
        pct_of_class <= 20 ~ "10-20%",
        TRUE ~ ">20%"
      )
    )

  write.csv(export_tbl, "data/reconciliation_output.csv", row.names = FALSE, na = "")
  message(sprintf("Exported %d rows to data/reconciliation_output.csv for Power BI import",
                  nrow(export_tbl)))
  invisible(export_tbl)
}

main_export()
