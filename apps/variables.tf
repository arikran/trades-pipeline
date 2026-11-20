# Default so `terraform destroy -input=false` never prompts.
variable "image_tag" {
  description = "Image tag (git SHA) for producer and consumer"
  type        = string
  default     = "none"
}
