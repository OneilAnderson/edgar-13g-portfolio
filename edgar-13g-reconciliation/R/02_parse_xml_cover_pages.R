# 02_parse_xml_cover_pages.R
#
# For each filing found by 01_fetch_filings.R, fetch its structured XML
# primary document directly (full-text search already told us the filename,
# so no per-filing index lookup is needed — one request per filing) and
# parse the cover-page fields that matter for reconciliation.
#
# Node names verified against live post-Dec-2024 filings (namespace
# http://www.sec.gov/edgar/schedule13g / .../schedule13d, schema X0202):
#   coverPageHeader/eventDateRequiresFilingThisStatement   (MM/DD/YYYY)
#   coverPageHeader/amendmentNo                            (absent on initials)
#   coverPageHeader/issuerInfo/issuerName, issuerCik
#   coverPageHeader/designateRulesPursuantThisScheduleFiled/
#     designateRulePursuantThisScheduleFiled               ("Rule 13d-1(b)" etc.,
#                                                           13G only)
#   coverPageHeaderReportingPersonDetails/reportingPersonName, classPercent
#     (repeats once per reporting person on joint filings)
#
# XPaths use local-name() so the 13D and 13G namespaces parse identically.

library(httr2)
library(xml2)
library(dplyr)
library(purrr)
library(yaml)

settings <- read_yaml("config/settings.yml")
throttle_sec <- 1 / settings$requests_per_second

xml_doc_url <- function(cik, accession_clean, primary_doc) {
  sprintf("https://www.sec.gov/Archives/edgar/data/%s/%s/%s",
          sub("^0+", "", cik), accession_clean, primary_doc)
}

#' Parse one filing's XML cover page into a one-row tibble.
parse_cover_page <- function(xml_url, user_agent) {
  resp <- request(xml_url) |>
    req_headers(`User-Agent` = user_agent) |>
    req_timeout(30) |>
    req_retry(max_tries = 3, backoff = ~10) |>
    req_perform()

  doc <- read_xml(resp_body_string(resp))

  first_text <- function(xpath) {
    node <- xml_find_first(doc, xpath)
    if (inherits(node, "xml_missing")) NA_character_ else xml_text(node)
  }
  all_text <- function(xpath) {
    nodes <- xml_find_all(doc, xpath)
    if (length(nodes) == 0) character(0) else xml_text(nodes)
  }

  # The 13G and 13D schemas use different node names for the same concepts:
  #   event date:  eventDateRequiresFilingThisStatement (13G) / dateOfEvent (13D)
  #   issuer CIK:  issuerCik (13G) / issuerCIK (13D — local-name() is case-sensitive)
  #   percent:     ...ReportingPersonDetails/classPercent (13G)
  #                reportingPersonInfo/percentOfClass (13D)
  pcts <- suppressWarnings(as.numeric(all_text(paste0(
    ".//*[local-name()='coverPageHeaderReportingPersonDetails']/*[local-name()='classPercent']",
    " | .//*[local-name()='reportingPersonInfo']/*[local-name()='percentOfClass']"
  ))))
  pcts <- pcts[!is.na(pcts)]

  rules <- unique(all_text(".//*[local-name()='designateRulePursuantThisScheduleFiled']"))

  tibble(
    issuer_name = first_text(".//*[local-name()='issuerName']"),
    issuer_cik = first_text(".//*[local-name()='issuerCik' or local-name()='issuerCIK']"),
    filer_name = first_text(".//*[local-name()='reportingPersonName']"),
    rule_designation = if (length(rules) == 0) NA_character_ else paste(rules, collapse = "; "),
    event_date_raw = first_text(
      ".//*[local-name()='eventDateRequiresFilingThisStatement' or local-name()='dateOfEvent']"
    ),
    pct_of_class = if (length(pcts) == 0) NA_real_ else max(pcts),
    amendment_no = first_text(".//*[local-name()='amendmentNo']"),
    n_reporting_persons = length(all_text(paste0(
      ".//*[local-name()='coverPageHeaderReportingPersonDetails']/*[local-name()='reportingPersonName']",
      " | .//*[local-name()='reportingPersonInfo']/*[local-name()='reportingPersonName']"
    )))
  )
}

empty_cover <- function() {
  tibble(
    issuer_name = NA_character_, issuer_cik = NA_character_,
    filer_name = NA_character_, rule_designation = NA_character_,
    event_date_raw = NA_character_, pct_of_class = NA_real_,
    amendment_no = NA_character_, n_reporting_persons = NA_integer_
  )
}

main_parse <- function() {
  filings <- read.csv("data/filings_raw.csv", stringsAsFactors = FALSE,
                      colClasses = c(cik = "character", accession_clean = "character"))
  ua <- settings$user_agent

  # Resume support: skip filings already parsed in a previous run.
  out_path <- "data/filings_parsed.csv"
  done <- character(0)
  if (file.exists(out_path)) {
    prev <- read.csv(out_path, stringsAsFactors = FALSE)
    # Only successfully parsed rows count as done — failures (no event date)
    # get retried on the next run.
    done <- prev$accession_no[!is.na(prev$event_date_raw)]
    message(sprintf("Resuming: %d of %d filings already parsed.", length(done), nrow(filings)))
  }
  todo <- filings[!filings$accession_no %in% done, ]

  if (nrow(todo) == 0) {
    message("Nothing new to parse — data/filings_parsed.csv is up to date.")
    return(invisible(read.csv(out_path, stringsAsFactors = FALSE,
                              colClasses = c(cik = "character", accession_clean = "character",
                                             issuer_cik = "character", amendment_no = "character"))))
  }

  message(sprintf("Parsing XML cover pages for %d filings (~%.0f min at %g req/sec)...",
                  nrow(todo), nrow(todo) * throttle_sec / 60, settings$requests_per_second))

  results <- imap_dfr(seq_len(nrow(todo)), function(i, ...) {
    row <- todo[i, ]
    url <- xml_doc_url(row$cik, row$accession_clean, row$primary_doc)

    cover <- tryCatch(
      parse_cover_page(url, ua),
      error = function(e) {
        message(sprintf("  ! %s: %s", row$accession_no, conditionMessage(e)))
        empty_cover()
      }
    )
    Sys.sleep(throttle_sec)
    if (i %% 50 == 0) message(sprintf("  ...%d / %d", i, nrow(todo)))

    bind_cols(tibble(accession_no = row$accession_no, xml_url = url), cover)
  })

  # Convert MM/DD/YYYY event dates to ISO.
  if (nrow(results) > 0) {
    results$event_date <- format(as.Date(results$event_date_raw, format = "%m/%d/%Y"))
  }

  parsed_new <- filings |>
    inner_join(results, by = "accession_no")

  parsed <- if (file.exists(out_path) && length(done) > 0) {
    prev_keep <- read.csv(out_path, stringsAsFactors = FALSE,
                          colClasses = c(cik = "character", accession_clean = "character",
                                         issuer_cik = "character", amendment_no = "character"))
    # Drop any previously failed rows that were just re-parsed.
    prev_keep <- prev_keep[!prev_keep$accession_no %in% parsed_new$accession_no, ]
    bind_rows(prev_keep, parsed_new)
  } else {
    parsed_new
  }

  write.csv(parsed, out_path, row.names = FALSE)

  n_ok <- sum(!is.na(parsed$event_date))
  message(sprintf("Saved %d parsed filings to %s (%d with a parsed event date, %.1f%%)",
                  nrow(parsed), out_path, n_ok, 100 * n_ok / max(nrow(parsed), 1)))
  invisible(parsed)
}

main_parse()
