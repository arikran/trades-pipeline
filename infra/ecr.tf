resource "aws_ecr_repository" "this" {
  for_each = toset(["producer", "consumer"])

  name                 = "${var.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # sandbox: destroy must not fail on leftover images

  image_scanning_configuration {
    scan_on_push = true
  }
}
