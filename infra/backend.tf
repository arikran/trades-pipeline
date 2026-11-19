terraform {
  backend "s3" {
    bucket         = "arik-rainish-tfstate-092988563851"
    key            = "infra/terraform.tfstate"
    region         = "eu-north-1"
    encrypt        = true
    dynamodb_table = "arik-rainish-tflock" # the lock table the account provides; Terraform prints a deprecation warning
  }
}
