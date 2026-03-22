output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.rockport.id
  sensitive   = true
}

output "tunnel_url" {
  description = "Public URL for the LiteLLM proxy"
  value       = "https://${var.domain}"
  sensitive   = true
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "ssm_connect_command" {
  description = "Command to connect to the instance via SSM"
  value       = "aws ssm start-session --target ${aws_instance.rockport.id} --region ${var.region}"
  sensitive   = true
}

output "video_bucket_name" {
  description = "S3 bucket for video generation output (us-east-1, Nova Reel)"
  value       = aws_s3_bucket.video.id
  sensitive   = true
}

output "video_bucket_us_west_2_name" {
  description = "S3 bucket for video generation output (us-west-2, Luma Ray2)"
  value       = aws_s3_bucket.video_us_west_2.id
  sensitive   = true
}

output "guardrail_id" {
  description = "Bedrock Guardrail ID (only set when enable_guardrails = true)"
  value       = var.enable_guardrails ? aws_bedrock_guardrail.rockport[0].guardrail_id : null
}

output "guardrail_version" {
  description = "Bedrock Guardrail version (only set when enable_guardrails = true)"
  value       = var.enable_guardrails ? aws_bedrock_guardrail.rockport[0].version : null
}
