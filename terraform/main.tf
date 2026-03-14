# Data sources

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
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel*"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
      }
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
        "ssm:GetParameters"
      ]
      Resource = "arn:aws:ssm:${var.region}:*:parameter/rockport/*"
    }]
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
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.rockport.id
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

  user_data = templatefile("${path.module}/../scripts/bootstrap.sh", {
    region                = var.region
    master_key_ssm_path   = "/rockport/master-key"
    tunnel_token_ssm_path = aws_ssm_parameter.tunnel_token.name
    litellm_version       = var.litellm_version
    cloudflared_version   = var.cloudflared_version
    litellm_config        = file("${path.module}/../config/litellm-config.yaml")
    litellm_service       = file("${path.module}/../config/litellm.service")
    cloudflared_service   = file("${path.module}/../config/cloudflared.service")
  })

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  maintenance_options {
    auto_recovery = "default"
  }

  tags = {
    Name = "rockport"
  }
}
