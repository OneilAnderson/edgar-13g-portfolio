# run_pipeline.R
# Runs the full pipeline end to end. Run from this directory
# (edgar-13g-reconciliation/):
#   Rscript run_pipeline.R
#
# Each stage script executes when sourced and writes its output to data/,
# so stages can also be run individually:
#   Rscript R/01_fetch_filings.R

if (!file.exists("config/settings.yml")) {
  stop("config/settings.yml not found. Run from the edgar-13g-reconciliation/ ",
       "directory, and copy config/settings.yml.example to config/settings.yml first.")
}

source("R/01_fetch_filings.R")
source("R/02_parse_xml_cover_pages.R")
source("R/03_reconcile_deadlines.R")
source("R/04_export_for_powerbi.R")

message("\nPipeline complete. Import data/reconciliation_output.csv into Power BI.")
