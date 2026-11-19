resource "aws_msk_configuration" "this" {
  name           = "${var.name}-msk-config"
  kafka_versions = ["3.9.x"]

  server_properties = <<-PROPS
    auto.create.topics.enable=false
    default.replication.factor=3
    min.insync.replicas=2
    log.retention.hours=24
  PROPS
}

resource "aws_security_group" "msk" {
  name        = "${var.name}-msk"
  description = "MSK IAM listener, reachable only from EKS nodes"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_nodes" {
  security_group_id            = aws_security_group.msk.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 9098
  to_port                      = 9098
  description                  = "Kafka SASL/IAM from EKS nodes"
}

resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.name}-msk"
  kafka_version          = "3.9.x"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 20
      }
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  timeouts {
    delete = "120m"
  }
}

# The topic is infrastructure: created here (MSK topic API, Kafka >= 3.6), not by the producer.
resource "aws_msk_topic" "trades" {
  cluster_arn        = aws_msk_cluster.this.arn
  name               = "trades"
  partition_count    = 6
  replication_factor = 3
}
