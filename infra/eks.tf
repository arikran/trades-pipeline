data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = "${var.name}-eks"
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Access: IAM auth via access entries; public endpoint so reviewers can run kubectl;
  # destroy does not need cluster access.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = ["0.0.0.0/0"]

  # The creator already has admin (above); a second entry for the same principal would fail the apply.
  access_entries = contains(["", data.aws_caller_identity.current.arn], var.evaluator_principal_arn) ? {} : {
    evaluator = {
      principal_arn = var.evaluator_principal_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # IRSA: the account's permissions boundary allows the OIDC provider and
  # sts:AssumeRoleWithWebIdentity, but not eks-auth:AssumeRoleForPodIdentity (Pod Identity).
  enable_irsa = true

  # No customer KMS key: secrets stay encrypted with the AWS-owned key.
  create_kms_key    = false
  encryption_config = null

  # No control-plane logs: nothing left behind after destroy.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  # Cluster role: fixed name + account-required permissions boundary.
  iam_role_name                 = "${var.name}-eks-cluster"
  iam_role_use_name_prefix      = false
  iam_role_permissions_boundary = var.permissions_boundary_arn

  addons = {
    vpc-cni = {
      before_compute = true
    }
    coredns    = {}
    kube-proxy = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      # EKS picks the latest AMI at creation; avoids a plan-time ssm:GetParameter call.
      use_latest_ami_release_version = false
      min_size                       = 2
      max_size                       = 3
      desired_size                   = 2
      subnet_ids                     = module.vpc.private_subnets

      # Must be repeated here: the node group defaults to a name prefix and no boundary.
      iam_role_name                 = "${var.name}-eks-node"
      iam_role_use_name_prefix      = false
      iam_role_permissions_boundary = var.permissions_boundary_arn
    }
  }
}
