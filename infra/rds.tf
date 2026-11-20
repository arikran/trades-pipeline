resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-pg"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-pg"
  description = "PostgreSQL, reachable only from EKS nodes"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from EKS nodes"
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100 # storage autoscaling: ~13M rows/day would fill 20 GB within days
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name                     = "trades"
  username                    = "trades"
  manage_master_user_password = true # password lives in Secrets Manager, never in state or Git

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # documented shortcut

  # Clean destroy (sandbox, not production)
  skip_final_snapshot      = true
  deletion_protection      = false
  delete_automated_backups = true
  apply_immediately        = true
}

# Least-privilege DB user for the consumer. db_init.py (Helm hook, master user) creates it with this
# password. The password is ephemeral and write-only: it goes straight to Secrets Manager and never
# lands in the Terraform state.
ephemeral "random_password" "app_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "app_db" {
  name                    = "${var.name}-db-app"
  recovery_window_in_days = 0 # sandbox: destroy and deploy again without a 7-day name lock
}

resource "aws_secretsmanager_secret_version" "app_db" {
  secret_id                = aws_secretsmanager_secret.app_db.id
  secret_string_wo         = jsonencode({ username = "trades_app", password = ephemeral.random_password.app_db.result })
  secret_string_wo_version = 1
}
