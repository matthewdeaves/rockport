# S3 bucket for video generation output (Nova Reel writes directly to S3).
# Must be in us-east-1 because Nova Reel is only available there.

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_s3_bucket" "video" {
  provider = aws.us_east_1
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
