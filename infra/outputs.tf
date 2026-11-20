output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "msk_cluster_name" {
  value = aws_msk_cluster.this.cluster_name
}

output "msk_arn" {
  value = aws_msk_cluster.this.arn
}

output "msk_bootstrap_brokers_sasl_iam" {
  value = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "rds_db_name" {
  value = aws_db_instance.this.db_name
}

output "db_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "app_db_secret_arn" {
  value = aws_secretsmanager_secret.app_db.arn
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
