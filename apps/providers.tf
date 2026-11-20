# Everything comes from the infra state outputs: no data "aws_eks_cluster" lookup,
# so `terraform destroy` here still works even while the cluster is half gone.
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "arik-rainish-tfstate-092988563851"
    key    = "infra/terraform.tfstate"
    region = "eu-north-1"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  cluster_host = local.infra.cluster_endpoint
  cluster_ca   = base64decode(local.infra.cluster_certificate_authority_data)
  token_args   = ["eks", "get-token", "--region", local.infra.region, "--cluster-name", local.infra.cluster_name]
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_host
    cluster_ca_certificate = local.cluster_ca
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.token_args
    }
  }
}

