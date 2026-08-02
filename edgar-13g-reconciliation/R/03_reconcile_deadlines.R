# 03_reconcile_deadlines.R
#
# The reconciliation logic: classify each filing into a deadline category,
# compute the applicable deadline from the event date, and flag on-time vs
# late. All day-counts live in config/deadline_rules.yml, never here.
#
# Classification comes straight from the structured cover page: 13G filings
# state the rule relied on ("Rule 13d-1(b)" = QII, "(c)" = passive,
# "(d)" = exempt); anything on Schedule 13D is a 13D filer.
#
# Documented simplifications (see README):
# - Amendments are reconciled against each category's *baseline* rule
#   (13d-2(a) for 13D, 13d-2(b) for 13G). The event-driven accelerated
#   amendment triggers (crossing 10%, +/-5% swings) depend on ownership
#   *changes between* filings, which a single filing doesn't reveal —
#   flagging those would require joining each filer's amendment history.
# - The QII accelerated *initial* deadline (>10% before quarter-end) is
#   applied when the reported percent of class exceeds 10, which is the
#   best available proxy from a single cover page.

library(dplyr)
library(lubridate)
library(yaml)
library(purrr)

rules <- read_yaml("config/deadline_rules.yml")

# U.S. federal holidays (observed), 2024-2027. Source: OPM federal holiday
# schedule. Rule 13d-1(i)(2) defines "business day" as any day other than
# Saturday, Sunday, or a federal holiday.
FEDERAL_HOLIDAYS <- as.Date(c(
  "2024-01-01", "2024-01-15", "2024-02-19", "2024-05-27", "2024-06-19",
  "2024-07-04", "2024-09-02", "2024-10-14", "2024-11-11", "2024-11-28",
  "2024-12-25",
  "2025-01-01", "2025-01-20", "2025-02-17", "2025-05-26", "2025-06-19",
  "2025-07-04", "2025-09-01", "2025-10-13", "2025-11-11", "2025-11-27",
  "2025-12-25",
  "2026-01-01", "2026-01-19", "2026-02-16", "2026-05-25", "2026-06-19",
  "2026-07-03", "2026-09-07", "2026-10-12", "2026-11-11", "2026-11-26",
  "2026-12-25",
  "2027-01-01", "2027-01-18", "2027-02-15", "2027-05-31", "2027-06-18",
  "2027-07-05", "2027-09-06", "2027-10-11", "2027-11-11", "2027-11-25",
  "2027-12-24", "2027-12-31"
))

is_business_day <- function(d) {
  !(wday(d) %in% c(1, 7)) & !(d %in% FEDERAL_HOLIDAYS)
}

#' N business days after `date` (exclusive of the start date), per
#' Rule 13d-1(i)(2).
add_business_days <- function(date, n) {
  d <- date
  added <- 0
  while (added < n) {
    d <- d + days(1)
    if (is_business_day(d)) added <- added + 1
  }
  d
}

#' Map a filing to its deadline-rule category.
classify_filer <- function(rule_designation, form_type) {
  if (grepl("13D", form_type, fixed = TRUE)) return("schedule_13d_filer")
  rd <- ifelse(is.na(rule_designation), "", rule_designation)
  if (grepl("13d-1(b)", rd, fixed = TRUE)) return("qualified_institutional_investor")
  if (grepl("13d-1(c)", rd, fixed = TRUE)) return("passive_investor")
  if (grepl("13d-1(d)", rd, fixed = TRUE)) return("exempt_investor")
  NA_character_
}

#' Compute a deadline date from an event date and a (deadline, unit) pair.
compute_deadline <- function(event_date, deadline_n, unit) {
  if (is.na(event_date) || is.null(deadline_n) || is.null(unit)) return(as.Date(NA))
  ed <- as.Date(event_date)

  if (unit == "business_days") {
    add_business_days(ed, deadline_n)
  } else if (unit == "calendar_days_after_quarter_end") {
    q_end <- ceiling_date(ed, "quarter") - days(1)
    q_end + days(deadline_n)
  } else if (unit == "business_days_after_month_end") {
    m_end <- ceiling_date(ed, "month") - days(1)
    add_business_days(m_end, deadline_n)
  } else {
    as.Date(NA)
  }
}

reconcile_row <- function(event_date, filed_date, rule_designation, form_type,
                          amendment_no, pct_of_class) {
  category <- classify_filer(rule_designation, form_type)
  is_amendment <- grepl("/A$", form_type) | !is.na(amendment_no)

  blank <- tibble(filer_category = category, is_amendment = is_amendment,
                  deadline_date = as.Date(NA), days_to_file = NA_real_,
                  days_vs_deadline = NA_real_, on_time_flag = NA,
                  deadline_rule_used = NA_character_)
  if (is.na(category)) return(blank)

  rule <- (if (is_amendment) rules$amendments else rules$initial_filing)[[category]]
  if (is.null(rule)) return(blank)

  # Choose baseline vs accelerated variant.
  use_accelerated <- !is_amendment &&
    category == "qualified_institutional_investor" &&
    !is.na(pct_of_class) && pct_of_class > 10 &&
    !is.null(rule$accelerated_deadline)

  if (use_accelerated) {
    deadline_n <- rule$accelerated_deadline
    unit <- rule$accelerated_unit
    rule_label <- paste0(category, " (accelerated >10%)")
  } else {
    deadline_n <- rule$deadline %||% rule$material_change_deadline
    unit <- rule$unit
    rule_label <- category
  }

  deadline_date <- compute_deadline(event_date, deadline_n, unit)
  filed <- as.Date(filed_date)

  tibble(
    filer_category = category,
    is_amendment = is_amendment,
    deadline_date = deadline_date,
    days_to_file = as.numeric(filed - as.Date(event_date)),
    days_vs_deadline = if (is.na(deadline_date)) NA_real_ else as.numeric(filed - deadline_date),
    on_time_flag = if (is.na(deadline_date)) NA else filed <= deadline_date,
    deadline_rule_used = rule_label
  )
}

`%||%` <- function(a, b) if (is.null(a)) b else a

main_reconcile <- function() {
  filings <- read.csv("data/filings_parsed.csv", stringsAsFactors = FALSE,
                      colClasses = c(cik = "character", accession_clean = "character",
                                     issuer_cik = "character", amendment_no = "character"))

  reconciled <- bind_cols(
    filings,
    pmap_dfr(
      list(filings$event_date, filings$filed_date, filings$rule_designation,
           filings$form_type, filings$amendment_no, filings$pct_of_class),
      reconcile_row
    )
  )

  write.csv(reconciled, "data/filings_reconciled.csv", row.names = FALSE)

  summary_tbl <- reconciled |>
    filter(!is.na(on_time_flag)) |>
    count(filer_category, is_amendment, on_time_flag) |>
    tidyr::pivot_wider(names_from = on_time_flag, values_from = n,
                       values_fill = 0, names_prefix = "on_time_")

  message("Reconciliation summary:")
  print(as.data.frame(summary_tbl))

  n_unclassified <- sum(is.na(reconciled$filer_category))
  if (n_unclassified > 0) {
    message(sprintf("Note: %d filings could not be classified (missing/unrecognized rule designation).",
                    n_unclassified))
  }
  invisible(reconciled)
}

main_reconcile()
