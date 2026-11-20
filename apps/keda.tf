resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.20.2" # KEDA 2.20 supports Kubernetes 1.33-1.35; cluster is 1.35
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 600
  # IRSA: the chart annotates the keda-operator service account with this role,
  # whose trust policy in infra/iam.tf accepts only keda/keda-operator.
  values = [yamlencode({
    podIdentity = { aws = { irsa = { enabled = true, roleArn = local.infra.pod_role_arns["keda"] } } }
  })]
}
