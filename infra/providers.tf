provider "aws" {
  region              = var.region
  allowed_account_ids = ["092988563851"] # refuses to run against any other account

  default_tags {
    tags = {
      Project = "trades-pipeline"
    }
  }
}
