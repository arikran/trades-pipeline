# IRSA roles: arik-rainish-* names, account-required permissions boundary, least privilege.
# Each role trusts only its own service account, through the cluster's OIDC provider.

locals {
  # arn:aws:kafka:REGION:ACCOUNT:cluster/NAME/UUID becomes topic/NAME/UUID/trades and group/NAME/UUID/trades-writer
  msk_topic_arn = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/trades"
  msk_group_arn = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/trades-writer"

  irsa_roles = {
    producer  = { namespace = "pipeline", service_account = "producer" }
    consumer  = { namespace = "pipeline", service_account = "consumer" }
    keda      = { namespace = "keda", service_account = "keda-operator" }
    "db-init" = { namespace = "pipeline", service_account = "db-init" }
  }

  pod_policies = {
    producer  = data.aws_iam_policy_document.producer.json
    consumer  = data.aws_iam_policy_document.consumer.json
    keda      = data.aws_iam_policy_document.keda.json
    "db-init" = data.aws_iam_policy_document.db_init.json
  }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pod" {
  for_each = local.irsa_roles

  name                 = "${var.name}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.irsa_trust[each.key].json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "producer" {
  statement {
    sid       = "Cluster"
    actions   = ["kafka-cluster:Connect", "kafka-cluster:WriteDataIdempotently"]
    resources = [aws_msk_cluster.this.arn]
  }
  statement {
    sid       = "Topic"
    actions   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
    resources = [local.msk_topic_arn]
  }
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid       = "Cluster"
    actions   = ["kafka-cluster:Connect"]
    resources = [aws_msk_cluster.this.arn]
  }
  statement {
    sid       = "Topic"
    actions   = ["kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
    resources = [local.msk_topic_arn]
  }
  statement {
    sid       = "Group"
    actions   = ["kafka-cluster:DescribeGroup", "kafka-cluster:AlterGroup"]
    resources = [local.msk_group_arn]
  }
  statement {
    sid       = "DbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app_db.arn] # the app user only, never the master
  }
  statement {
    sid       = "FreshnessMetric"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData has no resource ARN, so it is scoped by namespace instead
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["TradesPipeline"]
    }
  }
}

# KEDA reads the consumer group's lag from Kafka: offsets of the group and end offsets of the topic.
data "aws_iam_policy_document" "keda" {
  statement {
    sid       = "Cluster"
    actions   = ["kafka-cluster:Connect"]
    resources = [aws_msk_cluster.this.arn]
  }
  statement {
    sid       = "Topic"
    actions   = ["kafka-cluster:DescribeTopic"]
    resources = [local.msk_topic_arn]
  }
  statement {
    sid       = "Group"
    actions   = ["kafka-cluster:DescribeGroup"]
    resources = [local.msk_group_arn]
  }
}

# db-init (Helm hook Job) is the only workload that reads the master secret.
data "aws_iam_policy_document" "db_init" {
  statement {
    sid       = "DbSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn, aws_secretsmanager_secret.app_db.arn]
  }
}

resource "aws_iam_role_policy" "pod" {
  for_each = local.irsa_roles

  name   = "${var.name}-${each.key}"
  role   = aws_iam_role.pod[each.key].id
  policy = local.pod_policies[each.key]
}
