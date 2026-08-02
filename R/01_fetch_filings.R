# 01_fetch_filings.R
#
# Pulls Schedule 13D/13G filing metadata from SEC EDGAR's full-text search
# API (efts.sec.gov). This gives us the accession numbers and CIKs we need
# to go fetch the actual XML cover pages in the next script -- full-text
# search itself does not return the structured ownership fields.
#
# Public endpoint, no API key. Requires a descriptive User-Agent per SEC's
# fair-access policy (see config/settings.yml).

library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(yaml)

settings <- read_yaml("config/settings.yml")

EFTS_BASE <- "https://efts.sec.gov/LATEST/search-index"
throttle_sec <- 1 / settings$requests_per_second

#' Query EDGAR full-text search for one form type over a date range.
#' Pages through results 100 at a time (the API's per-request max).
fetch_filings_for_form <- function(form_type, start_date, end_date, user_agent) {

  all_hits <- list()
  from <- 0
  page_size <- 100

  repeat {
    req <- request(EFTS_BASE) |>
      req_headers(`User-Agent` = user_agent, Accept = "application/json") |>
      req_url_query(
        q = "",
        forms = form_type,
        dateRange = "custom",
        startdt = start_date,
        enddt = end_date,
        from = from
      )

    resp <- req_perform(req)
    body <- resp_body_json(resp)

    hits <- body$hits$hits
    if (length(hits) == 0) break

    all_hits <- c(all_hits, hits)

    total <- body$hits$total$value
    from <- from + page_size
    if (from >= total) break

    Sys.sleep(throttle_sec)
  }

  message(sprintf("  %s: %d filings", form_type, length(all_hits)))
  all_hits
}

#' Flatten a single EFTS hit into a tidy row of filing metadata.
tidy_hit <- function(hit) {
  src <- hit[["_source"]]
  tibble(
    cik = src$ciks[[1]],
    entity_name = src$display_names[[1]],
    form_type = src$form_type,
    filed_date = src$file_date,
    accession_no = sub("^.*:", "", hit[["_id"]]),
    accession_no_clean = gsub("-", "", sub(":.*$", "", hit[["_id"]]))
  )
}

main <- function() {
  message("Fetching 13D/13G filings from EDGAR full-text search...")

  raw_hits <- map(
    settings$form_types,
    ~ fetch_filings_for_form(.x, settings$start_date, settings$end_date, settings$user_agent)
  ) |> flatten()

  filings <- map_dfr(raw_hits, tidy_hit) |> distinct()

  dir.create("data", showWarnings = FALSE)
  write.csv(filings, "data/filings_raw.csv", row.names = FALSE)

  message(sprintf("Saved %d filings to data/filings_raw.csv", nrow(filings)))
  filings
}

if (sys.nframe() == 0) main()
