# Common tags for all resources

locals {
  common_tags = {
    Project   = "rockport"
    ManagedBy = "terraform"
  }

  # Bedrock regions: primary region + all EU regions for cross-region inference profiles
  # + all US regions for Stability AI us. inference profiles + image/video models.
  # The eu./us. prefix on model IDs can route to ANY region in that geography.
  bedrock_regions = distinct(concat(
    [var.region],
    ["eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-north-1", "eu-south-1", "eu-south-2", "us-east-1", "us-east-2", "us-west-1", "us-west-2"]
  ))
}

# Data sources

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# IAM

resource "aws_iam_role" "rockport" {
  name = "rockport-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "bedrock-invoke"
  role = aws_iam_role.rockport.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = flatten([
          for r in local.bedrock_regions : [
            "arn:aws:bedrock:${r}::foundation-model/*",
            "arn:aws:bedrock:${r}:${data.aws_caller_identity.current.account_id}:inference-profile/*"
          ]
        ])
      },
    ]
  })
}

# Marketplace models (Stability AI image services, Luma Ray2) auto-activate on
# first invoke but require these permissions to trigger the account-wide subscription.
# Resource must be "*" — AWS does not support resource-level permissions for these actions.
resource "aws_iam_role_policy" "marketplace_subscribe" {
  name = "marketplace-subscribe"
  role = aws_iam_role.rockport.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ssm_get_parameter" {
  name = "ssm-get-parameter"
  role = aws_iam_role.rockport.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:PutParameter"
      ]
      Resource = [
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/rockport/master-key",
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/rockport/tunnel-token",
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/rockport/db-password"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_async_invoke" {
  name = "bedrock-async-invoke"
  role = aws_iam_role.rockport.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:StartAsyncInvoke",
          "bedrock:GetAsyncInvoke"
        ]
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/*",
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:async-invoke/*",
          "arn:aws:bedrock:us-west-2::foundation-model/*",
          "arn:aws:bedrock:us-west-2:${data.aws_caller_identity.current.account_id}:async-invoke/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:ListAsyncInvokes"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "s3_video_bucket" {
  name = "s3-video-bucket"
  role = aws_iam_role.rockport.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:HeadObject"
        ]
        Resource = [
          "${aws_s3_bucket.video.arn}/*",
          "${aws_s3_bucket.video_us_west_2.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = "s3:ListBucket"
        Resource = [
          aws_s3_bucket.video.arn,
          aws_s3_bucket.video_us_west_2.arn
        ]
      },
      {
        Sid    = "ArtifactsRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:HeadObject"
        ]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.rockport.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "rockport" {
  name = "rockport-instance-profile"
  role = aws_iam_role.rockport.name
}

# Security group

resource "aws_security_group" "rockport" {
  name        = "rockport-sg"
  description = "Rockport instance - no inbound, all outbound"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(local.common_tags, {
    Name = "rockport-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.rockport.id
  description       = "All outbound - required for Bedrock API and Cloudflare tunnel"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# EC2 instance

resource "aws_instance" "rockport" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.rockport.name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.rockport.id]

  user_data_base64 = base64gzip(templatefile("${path.module}/../scripts/bootstrap.sh", {
    region                    = var.region
    master_key_ssm_path       = "/rockport/master-key"
    tunnel_token_ssm_path     = aws_ssm_parameter.tunnel_token.name
    litellm_version           = var.litellm_version
    cloudflared_version       = var.cloudflared_version
    artifacts_bucket          = aws_s3_bucket.artifacts.id
    video_bucket_name         = aws_s3_bucket.video.id
    video_bucket_us_west_2    = aws_s3_bucket.video_us_west_2.id
    video_max_concurrent_jobs = var.video_max_concurrent_jobs
  }))

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  ebs_optimized = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  maintenance_options {
    auto_recovery = "default"
  }

  tags = merge(local.common_tags, {
    Name = "rockport"
  })
}
