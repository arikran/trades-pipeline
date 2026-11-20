resource "helm_release" "pipeline" {
  name             = "pipeline"
  chart            = "${path.module}/chart/pipeline"
  namespace        = "pipeline"
  create_namespace = true
  wait             = true
  # Not atomic: a failed first install keeps its pods and logs for debugging instead of being rolled back.
  atomic          = false
  cleanup_on_fail = false
  timeout         = 600

  # The ScaledObject CRD must exist before this chart installs.
  depends_on = [helm_release.keda]

  values = [yamlencode({
    region   = local.infra.region
    imageTag = var.image_tag
    images = {
      producer = local.infra.ecr_repository_urls["producer"]
      consumer = local.infra.ecr_repository_urls["consumer"]
    }
    roleArns = {
      producer = local.infra.pod_role_arns["producer"]
      consumer = local.infra.pod_role_arns["consumer"]
    }
    kafka = {
      bootstrap = local.infra.msk_bootstrap_brokers_sasl_iam
    }
    db = {
      host      = local.infra.rds_endpoint
      name      = local.infra.rds_db_name
      secretArn = local.infra.db_secret_arn
    }
  })]
}
