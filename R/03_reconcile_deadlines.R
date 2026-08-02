# 03_reconcile_deadlines.R
#
# The actual reconciliation logic: for each filing, work out which deadline
# rule applies (by filer type and form type), compute the deadline date from
# the event date, and flag on-time vs. late.
#
# All day-counts live in config/deadline_rules.yml, not here -- this script
# only implements *how* to apply a rule, never *what* the rule says. That
# split is deliberate: if the SEC revises timing, or if you spot a mistake
# in how I've read the rule, you fix one YAML file instead of hunting
# through calculation logic.

library(dplyr)
library(lubridate)
library(yaml)
library(purrr)

rules <- read_yaml("config/deadline_rules.yml")

#' Map the raw XML filer_type string to a deadline-rule category.
#' EDGAR's filer_type values are things like "QII", "EXEMPT", "PASSIVE" --
#' confirm exact enum values against the current XML schema; adjust the
#' match logic here if the schema differs from what's assumed below.
classify_filer <- function(filer_type_raw, form_type) {
  if (grepl("13D", form_type)) return("schedule_13d_filer")

  ft <- toupper(coalesce(filer_type_raw, ""))
  case_when(
    grepl("QII|QUALIFIED", ft) ~ "qualified_institutional_investor",
    grepl("EXEMPT", ft)        ~ "exempt_investor",
    grepl("PASSIVE", ft)       ~ "passive_investor",
    TRUE                       ~ NA_character_
  )
}

#' Next business day, skipping weekends only (does not account for federal
#' holidays -- add a holiday calendar here, e.g. via {timeDate}, before
#' treating deadline_date as exact for real compliance use).
add_business_days <- function(date, n) {
  d <- date
  added <- 0
  while (added < n) {
    d <- d + days(1)
    if (!wday(d) %in% c(1, 7)) added <- added + 1
  }
  d
}

#' Compute a deadline date given an event date and a rule spec.
compute_deadline <- function(event_date, rule) {
  if (is.null(rule) || is.na(event_date)) return(as.Date(NA))

  ed <- as.Date(event_date)

  if (rule$unit == "business_days") {
    add_business_days(ed, rule$deadline)
  } else if (rule$unit == "calendar_days_after_quarter_end") {
    q_end <- ceiling_date(ed, "quarter") - days(1)
    q_end + days(rule$deadline)
  } else {
    as.Date(NA)
  }
}

reconcile_row <- function(event_date, filed_date, filer_type, form_type, amendment_flag) {
  category <- classify_filer(filer_type, form_type)
  if (is.na(category)) return(tibble(deadline_date = as.Date(NA), days_to_file = NA_real_,
                                       on_time_flag = NA, deadline_rule_used = NA_character_))

  is_amendment <- coalesce(amendment_flag, "false") %in% c("true", "TRUE", "1")
  rule_set <- if (is_amendment) rules$amendments else rules$initial_filing
  rule <- rule_set[[category]]

  deadline_date <- compute_deadline(event_date, rule)
  filed <- as.Date(filed_date)

  tibble(
    deadline_date = deadline_date,
    days_to_file = as.numeric(filed - as.Date(event_date)),
    on_time_flag = if (is.na(deadline_date)) NA else filed <= deadline_date,
    deadline_rule_used = category
  )
}

main <- function() {
  filings <- read.csv("data/filings_parsed.csv", stringsAsFactors = FALSE)

  reconciled <- filings |>
    bind_cols(
      pmap_dfr(
        list(filings$event_date, filings$filed_date, filings$filer_type,
             filings$form_type, filings$amendment_flag),
        ~ reconcile_row(..1, ..2, ..3, ..4, ..5)
      )
    )

  write.csv(reconciled, "data/filings_reconciled.csv", row.names = FALSE)

  summary_tbl <- reconciled |>
    filter(!is.na(on_time_flag)) |>
    count(deadline_rule_used, on_time_flag) |>
    tidyr::pivot_wider(names_from = on_time_flag, values_from = n, values_fill = 0)

  message("Reconciliation summary by filer category:")
  print(summary_tbl)

  reconciled
}

if (sys.nframe() == 0) main()
