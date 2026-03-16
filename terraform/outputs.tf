output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.rockport.id
}

output "tunnel_url" {
  description = "Public URL for the LiteLLM proxy"
  value       = "https://${var.domain}"
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "ssm_connect_command" {
  description = "Command to connect to the instance via SSM"
  value       = "aws ssm start-session --target ${aws_instance.rockport.id} --region ${var.region}"
}

output "video_bucket_name" {
  description = "S3 bucket for video generation output"
  value       = aws_s3_bucket.video.id
}
