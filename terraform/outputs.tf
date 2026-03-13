output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.rockport.id
}

output "tunnel_url" {
  description = "Public URL for the LiteLLM proxy"
  value       = "https://${var.domain}"
}

output "ssm_connect_command" {
  description = "Command to connect to the instance via SSM"
  value       = "aws ssm start-session --target ${aws_instance.rockport.id} --region ${var.region}"
}
