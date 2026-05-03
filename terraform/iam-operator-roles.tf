# Operator roles (017): readonly + runtime-ops + deploy.
#
# Each role is assumable from the rockport-deployer user with MFA + 1-hour STS
# sessions. Permissions boundaries cap the maximum each role could ever do,
# even if its inline/managed policies were rewritten.
#
# See specs/017-iam-mfa-scoping/ for the full design.

locals {
  operator_role_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/rockport-deployer"
      }
      Condition = {
        Bool = {
          "aws:MultiFactorAuthPresent" = "true"
        }
        NumericLessThan = {
          "aws:MultiFactorAuthAge" = "3600"
        }
      }
    }]
  })
}

# --- Boundary policies ---
#
# Boundaries are the upper-bound on what each role can do. Even if the
# attached managed policies grant more, the boundary clamps the effective
# permissions.

resource "aws_iam_policy" "operator_readonly_boundary" {
  name        = "RockportOperatorReadonlyBoundary"
  description = "Permissions boundary capping rockport-readonly-role at read-only access"
  policy      = file("${path.module}/deployer-policies/readonly.json")

  tags = local.common_tags
}

resource "aws_iam_policy" "operator_runtime_ops_boundary" {
  name        = "RockportOperatorRuntimeOpsBoundary"
  description = "Permissions boundary capping rockport-runtime-ops-role at runtime ops"
  # Boundary spans BOTH the readonly and runtime-ops policy documents — each
  # role gets both attached and the boundary must allow both.
  policy = data.aws_iam_policy_document.operator_runtime_ops_boundary.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "operator_runtime_ops_boundary" {
  source_policy_documents = [
    file("${path.module}/deployer-policies/readonly.json"),
    file("${path.module}/deployer-policies/runtime-ops.json"),
  ]
}

resource "aws_iam_policy" "operator_deploy_boundary" {
  name        = "RockportOperatorDeployBoundary"
  description = "Permissions boundary capping rockport-deploy-role at deployer-tier services (no IAM-policy/user mutation, no access key mutation)"
  policy      = data.aws_iam_policy_document.operator_deploy_boundary.json

  tags = local.common_tags
}

# Coarser allow-list for the deploy boundary. The combined three deployer JSONs
# are too large to mirror byte-for-byte (over 6144 chars). Instead we list the
# service prefixes the deploy role legitimately needs, then explicit-deny the
# IAM-mutation actions called out in 017 / Finding B so a compromised deploy
# session cannot expand its own boundary or rewrite policy versions.
data "aws_iam_policy_document" "operator_deploy_boundary" {
  statement {
    sid    = "AllowDeployerClassServices"
    effect = "Allow"
    actions = [
      "ec2:*",
      "ssm:*",
      "lambda:*",
      "logs:*",
      "events:*",
      "cloudwatch:*",
      "budgets:*",
      "dlm:*",
      "cloudtrail:*",
      "s3:*",
      "sts:*",
      "ce:*",
      "aws-marketplace:Subscribe",
      "aws-marketplace:ViewSubscriptions",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowBedrockGuardrails"
    effect = "Allow"
    actions = [
      "bedrock:CreateGuardrail",
      "bedrock:GetGuardrail",
      "bedrock:UpdateGuardrail",
      "bedrock:DeleteGuardrail",
      "bedrock:ListGuardrails",
      "bedrock:ListTagsForResource",
      "bedrock:TagResource",
      "bedrock:UntagResource",
      "bedrock:ApplyGuardrail",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowIAMRoleAndProfileMutation"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:PassRole",
      "iam:CreateInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:GetUser",
      "iam:ListAttachedUserPolicies",
      "iam:ListAccessKeys",
    ]
    resources = ["*"]
  }

  # Finding B (017 / D7): the deploy role MUST NOT be able to mutate IAM
  # policies, IAM users, or access keys. Even if a compromised deploy session
  # grants itself such permissions through a policy attachment, the boundary
  # clamps the effective set here.
  statement {
    sid    = "DenyIAMPolicyAndUserMutation"
    effect = "Deny"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:AttachUserPolicy",
      "iam:DetachUserPolicy",
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:UpdateAccessKey",
      "iam:PutUserPolicy",
      "iam:DeleteUserPolicy",
      "iam:CreateLoginProfile",
      "iam:DeleteLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:CreateGroup",
      "iam:DeleteGroup",
      "iam:AddUserToGroup",
      "iam:RemoveUserFromGroup",
      "iam:CreateVirtualMFADevice",
      "iam:DeleteVirtualMFADevice",
      "iam:EnableMFADevice",
      "iam:DeactivateMFADevice",
      "iam:ResyncMFADevice",
    ]
    resources = ["*"]
  }
}

# --- Operator roles ---

resource "aws_iam_role" "operator_readonly" {
  name                 = "rockport-readonly-role"
  description          = "Read-only diagnostic role assumed by rockport-deployer with MFA"
  assume_role_policy   = local.operator_role_trust
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_readonly_boundary.arn

  tags = local.common_tags
}

resource "aws_iam_role" "operator_runtime_ops" {
  name                 = "rockport-runtime-ops-role"
  description          = "Runtime operations role (config push, restart, start/stop) assumed with MFA"
  assume_role_policy   = local.operator_role_trust
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_runtime_ops_boundary.arn

  tags = local.common_tags
}

resource "aws_iam_role" "operator_deploy" {
  name                 = "rockport-deploy-role"
  description          = "Full deploy role (terraform apply, destroy) assumed with MFA"
  assume_role_policy   = local.operator_role_trust
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.operator_deploy_boundary.arn

  tags = local.common_tags
}

# --- Managed-policy attachments ---
#
# The managed policies (RockportOperatorReadonly, RockportOperatorRuntimeOps,
# RockportDeployerCompute, RockportDeployerIamSsm, RockportDeployerMonitoringStorage)
# are created by `rockport.sh init`, not by Terraform — same pattern as the
# existing deployer-class policies. Terraform attaches them by ARN.

resource "aws_iam_role_policy_attachment" "operator_readonly_managed" {
  role       = aws_iam_role.operator_readonly.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/RockportOperatorReadonly"
}

resource "aws_iam_role_policy_attachment" "operator_runtime_ops_readonly" {
  role       = aws_iam_role.operator_runtime_ops.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/RockportOperatorReadonly"
}

resource "aws_iam_role_policy_attachment" "operator_runtime_ops_runtime" {
  role       = aws_iam_role.operator_runtime_ops.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/RockportOperatorRuntimeOps"
}

resource "aws_iam_role_policy_attachment" "operator_deploy_compute" {
  role       = aws_iam_role.operator_deploy.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/RockportDeployerCompute"
}

resource "aws_iam_role_policy_attachment" "operator_deploy_iam_ssm" {
  role       = aws_iam_role.operator_deploy.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/RockportDeployerIamSsm"
}

resource "aws_iam_role_policy_attachment" "operator_deploy_monitoring_storage" {
  role       = aws_iam_role.operator_deploy.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/RockportDeployerMonitoringStorage"
}
