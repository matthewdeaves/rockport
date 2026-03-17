# S3 bucket for deploy artifacts (sidecar code, config, systemd units).
# Used by bootstrap (first boot) and config push (runtime updates).

resource "aws_s3_bucket" "artifacts" {
  bucket        = "rockport-artifacts-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "rockport-artifacts"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  depends_on = [aws_s3_bucket_public_access_block.artifacts]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonSSL"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# S3 buckets for video generation output.
# Each video model requires its bucket to be in the same region as the Bedrock endpoint.
# Nova Reel: us-east-1, Luma Ray2: us-west-2.

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

resource "aws_s3_bucket" "video" {
  provider      = aws.us_east_1
  bucket        = "rockport-video-${data.aws_caller_identity.current.account_id}-us-east-1"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "rockport-video"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "video" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.video.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "video" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.video.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "video" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.video.id

  depends_on = [aws_s3_bucket_public_access_block.video]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonSSL"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.video.arn,
        "${aws_s3_bucket.video.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "video" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.video.id

  rule {
    id     = "delete-old-videos"
    status = "Enabled"

    filter {
      prefix = "jobs/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- us-west-2 video bucket (Luma Ray2) ---
# Mirrors us-east-1 bucket security: SSE-S3, public access blocked, DenyNonSSL, 7-day lifecycle.

resource "aws_s3_bucket" "video_us_west_2" {
  provider      = aws.us_west_2
  bucket        = "rockport-video-${data.aws_caller_identity.current.account_id}-us-west-2"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "rockport-video-us-west-2"
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "video_us_west_2" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.video_us_west_2.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "video_us_west_2" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.video_us_west_2.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "video_us_west_2" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.video_us_west_2.id

  depends_on = [aws_s3_bucket_public_access_block.video_us_west_2]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonSSL"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.video_us_west_2.arn,
        "${aws_s3_bucket.video_us_west_2.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "video_us_west_2" {
  provider = aws.us_west_2
  bucket   = aws_s3_bucket.video_us_west_2.id

  rule {
    id     = "delete-old-videos"
    status = "Enabled"

    filter {
      prefix = "jobs/"
    }

    expiration {
      days = 7
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
