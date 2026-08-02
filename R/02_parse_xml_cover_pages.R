# 02_parse_xml_cover_pages.R
#
# For each filing found in 01_fetch_filings.R, fetch the filing's index to
# locate the structured XML cover page, then parse out the fields that
# actually matter for reconciliation: issuer, filer, filer type, event date,
# percent of class, and whether it's an initial filing or an amendment.
#
# Only works for filings on/after Dec 18 2024 (the XML mandate date) --
# earlier "SC 13G"/"SC 13D" filings are free text and out of scope here.

library(httr2)
library(xml2)
library(dplyr)
library(purrr)
library(yaml)

settings <- read_yaml("config/settings.yml")
throttle_sec <- 1 / settings$requests_per_second

#' Locate the primary XML document for a filing via its EDGAR index.
find_xml_doc_url <- function(cik, accession_no_clean, user_agent) {
  index_url <- sprintf(
    "https://www.sec.gov/Archives/edgar/data/%s/%s/index.json",
    cik, accession_no_clean
  )

  resp <- request(index_url) |>
    req_headers(`User-Agent` = user_agent) |>
    req_perform()

  files <- resp_body_json(resp)$directory$item
  xml_file <- keep(files, ~ grepl("\\.xml$", .x$name) && !grepl("cal|def|lab|pre|htm", .x$name))

  if (length(xml_file) == 0) return(NA_character_)

  sprintf(
    "https://www.sec.gov/Archives/edgar/data/%s/%s/%s",
    cik, accession_no_clean, xml_file[[1]]$name
  )
}

#' Parse the fields we care about out of a Schedule 13D/13G XML cover page.
#' Field names below follow the SEC's published 13D/13G XML technical
#' specification -- confirm current node names against the latest schema
#' before relying on this against a large pull, schemas do get revised.
parse_cover_page <- function(xml_url, user_agent) {
  resp <- request(xml_url) |>
    req_headers(`User-Agent` = user_agent) |>
    req_perform()

  doc <- read_xml(resp_body_string(resp))
  ns <- xml_ns(doc)

  get_val <- function(xpath) {
    node <- xml_find_first(doc, xpath, ns)
    if (inherits(node, "xml_missing")) return(NA_character_)
    xml_text(node)
  }

  tibble(
    issuer_name = get_val(".//*[local-name()='issuerName']"),
    filer_name = get_val(".//*[local-name()='filerName']"),
    filer_type = get_val(".//*[local-name()='filerType']"),
    event_date = get_val(".//*[local-name()='eventDate']"),
    pct_of_class = get_val(".//*[local-name()='percentOfClass']"),
    amendment_flag = get_val(".//*[local-name()='amendmentFlag']")
  )
}

main <- function() {
  filings <- read.csv("data/filings_raw.csv", stringsAsFactors = FALSE)
  ua <- settings$user_agent

  message(sprintf("Parsing XML cover pages for %d filings...", nrow(filings)))

  results <- pmap_dfr(filings, function(cik, accession_no_clean, ...) {
    xml_url <- find_xml_doc_url(cik, accession_no_clean, ua)
    Sys.sleep(throttle_sec)

    if (is.na(xml_url)) {
      return(tibble(cik = cik, accession_no_clean = accession_no_clean,
                     xml_url = NA_character_, issuer_name = NA_character_,
                     filer_name = NA_character_, filer_type = NA_character_,
                     event_date = NA_character_, pct_of_class = NA_character_,
                     amendment_flag = NA_character_))
    }

    cover <- tryCatch(parse_cover_page(xml_url, ua), error = function(e) NULL)
    Sys.sleep(throttle_sec)

    if (is.null(cover)) {
      return(tibble(cik = cik, accession_no_clean = accession_no_clean,
                     xml_url = xml_url, issuer_name = NA_character_,
                     filer_name = NA_character_, filer_type = NA_character_,
                     event_date = NA_character_, pct_of_class = NA_character_,
                     amendment_flag = NA_character_))
    }

    bind_cols(tibble(cik = cik, accession_no_clean = accession_no_clean, xml_url = xml_url), cover)
  })

  parsed <- filings |> left_join(results, by = c("cik", "accession_no_clean"))

  write.csv(parsed, "data/filings_parsed.csv", row.names = FALSE)
  message(sprintf("Saved %d parsed filings to data/filings_parsed.csv", nrow(parsed)))
  parsed
}

if (sys.nframe() == 0) main()
