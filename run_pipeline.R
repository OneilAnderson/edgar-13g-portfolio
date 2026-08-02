# run_pipeline.R
# Runs the full pipeline end to end. Run from the project root:
#   Rscript run_pipeline.R

setwd(here::here())

source("R/01_fetch_filings.R")
source("R/02_parse_xml_cover_pages.R")
source("R/03_reconcile_deadlines.R")
source("R/04_export_for_powerbi.R")

message("\nPipeline complete. Import data/reconciliation_output.csv into Power BI.")
