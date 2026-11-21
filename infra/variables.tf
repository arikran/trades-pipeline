# Every variable has a default so `terraform destroy -input=false` never prompts.

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-north-1"
}

variable "name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "arik-rainish"
}

variable "permissions_boundary_arn" {
  description = "Account-required permissions boundary attached to every IAM role"
  type        = string
  default     = "arn:aws:iam::092988563851:policy/CandidateBoundary"
}

variable "alert_email" {
  description = "Email for the health alarm (empty = no subscription). Never commit a real value."
  type        = string
  default     = ""
}

variable "evaluator_principal_arn" {
  description = "Optional IAM principal ARN that gets cluster-admin: needed for kubectl, make query and the apps-layer destroy. Empty = none."
  type        = string
  default     = ""
}
