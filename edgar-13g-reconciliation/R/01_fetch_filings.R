# 01_fetch_filings.R
#
# Pulls Schedule 13D/13G filing metadata from SEC EDGAR's full-text search
# API (efts.sec.gov/LATEST/search-index). This gives us accession numbers,
# CIKs, form types, filed dates, and the primary XML document name for each
# filing — everything 02_parse_xml_cover_pages.R needs to fetch the
# structured cover pages.
#
# Empirically verified API behavior (Aug 2026):
#   - Returns 100 hits per page; paginate with `from` (0, 100, 200, ...).
#   - `forms=` filters on root_forms, so "SCHEDULE 13G" also returns
#     "SCHEDULE 13G/A"; the per-hit `form` field distinguishes them.
#   - Each hit's `_source.adsh` is the dashed accession number, and the
#     `_id` is "<accession>:<primary document filename>".
#   - Any single query's paging window caps at 10,000 hits — hence the
#     date-range chunking below.
#
# Public endpoint, no API key. Requires a descriptive User-Agent per SEC's
# fair-access policy (config/settings.yml).

library(httr2)
library(dplyr)
library(purrr)
library(yaml)

settings <- read_yaml("config/settings.yml")

if (grepl("example\\.com", settings$user_agent)) {
  stop("Set a real name/email User-Agent in config/settings.yml first ",
       "(copy config/settings.yml.example). SEC blocks generic UAs.")
}

EFTS_BASE <- "https://efts.sec.gov/LATEST/search-index"
throttle_sec <- 1 / settings$requests_per_second

#' Split [start_date, end_date] into chunks of at most `chunk_days` days.
date_chunks <- function(start_date, end_date, chunk_days) {
  starts <- seq(as.Date(start_date), as.Date(end_date), by = chunk_days)
  ends <- pmin(starts + chunk_days - 1, as.Date(end_date))
  Map(function(s, e) list(start = s, end = e), starts, ends)
}

#' Query EDGAR full-text search for one root form type over one date chunk,
#' paging 100 at a time.
fetch_chunk <- function(form_type, start_date, end_date, user_agent) {
  all_hits <- list()
  from <- 0
  page_size <- 100  # what the API actually returns per request

  repeat {
    resp <- request(EFTS_BASE) |>
      req_headers(`User-Agent` = user_agent, Accept = "application/json") |>
      req_url_query(
        # No `q` parameter: the API 500s on an empty q; omitting it entirely
        # returns all filings matching the forms/date filters.
        forms = form_type,
        dateRange = "custom",
        startdt = format(as.Date(start_date)),
        enddt = format(as.Date(end_date)),
        from = from
      ) |>
      req_timeout(30) |>
      req_retry(max_tries = 3, backoff = ~10) |>
      req_perform()

    body <- resp_body_json(resp)
    hits <- body$hits$hits
    if (length(hits) == 0) break

    all_hits <- c(all_hits, hits)
    total <- body$hits$total$value
    from <- from + page_size

    if (from >= total) break
    if (from >= 9900) {
      warning(sprintf(
        "Chunk %s..%s for %s has %d hits — exceeds the API's 10,000-hit paging window. Reduce chunk_days in config/settings.yml.",
        start_date, end_date, form_type, total
      ))
      break
    }
    Sys.sleep(throttle_sec)
  }

  all_hits
}

#' Flatten a single full-text-search hit into a tidy row of filing metadata.
tidy_hit <- function(hit) {
  src <- hit[["_source"]]
  id <- hit[["_id"]]
  tibble(
    accession_no = src$adsh,
    accession_clean = gsub("-", "", src$adsh),
    primary_doc = sub("^[^:]*:", "", id),
    cik = src$ciks[[1]],
    form_type = src$form,
    filed_date = src$file_date,
    entity_names = paste(unlist(src$display_names), collapse = " | ")
  )
}

main_fetch <- function() {
  message(sprintf("Fetching %s filings filed %s to %s from EDGAR full-text search...",
                  paste(settings$form_types, collapse = " + "),
                  settings$start_date, settings$end_date))

  chunks <- date_chunks(settings$start_date, settings$end_date, settings$chunk_days)

  raw_hits <- list()
  for (form_type in settings$form_types) {
    for (ch in chunks) {
      hits <- fetch_chunk(form_type, ch$start, ch$end, settings$user_agent)
      message(sprintf("  %s %s..%s: %d filings", form_type, ch$start, ch$end, length(hits)))
      raw_hits <- c(raw_hits, hits)
      Sys.sleep(throttle_sec)
    }
  }

  filings <- map_dfr(raw_hits, tidy_hit) |>
    distinct(accession_no, .keep_all = TRUE) |>
    arrange(filed_date, accession_no)

  dir.create("data", showWarnings = FALSE)
  write.csv(filings, "data/filings_raw.csv", row.names = FALSE)

  message(sprintf("Saved %d unique filings to data/filings_raw.csv", nrow(filings)))
  invisible(filings)
}

main_fetch()
