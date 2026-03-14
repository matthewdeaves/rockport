# Budget alarm - alerts when Bedrock spend approaches daily limit
resource "aws_budgets_budget" "bedrock_daily" {
  name         = "rockport-bedrock-daily"
  budget_type  = "COST"
  limit_amount = tostring(var.bedrock_daily_budget)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Bedrock"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

# Overall monthly AWS budget (EC2, EBS, Bedrock, data transfer, etc.)
resource "aws_budgets_budget" "monthly_total" {
  name         = "rockport-monthly-total"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

resource "aws_cloudwatch_metric_alarm" "auto_recovery" {
  alarm_name          = "rockport-auto-recovery"
  alarm_description   = "Auto-recover Rockport instance on system status check failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  dimensions = {
    InstanceId = aws_instance.rockport.id
  }

  alarm_actions = [
    "arn:aws:automate:${var.region}:ec2:recover"
  ]

  tags = local.common_tags
}
