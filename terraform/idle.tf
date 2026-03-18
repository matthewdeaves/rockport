# Auto-stop EC2 instance after period of inactivity

data "archive_file" "idle_shutdown" {
  count       = var.enable_idle_shutdown ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.build/idle-shutdown.zip"
  source_file = "${path.module}/lambda/idle_shutdown.py"
}

resource "aws_lambda_function" "idle_shutdown" {
  count            = var.enable_idle_shutdown ? 1 : 0
  function_name    = "rockport-idle-shutdown"
  runtime          = "python3.12"
  handler          = "idle_shutdown.handler"
  timeout          = 30
  filename         = data.archive_file.idle_shutdown[0].output_path
  source_code_hash = data.archive_file.idle_shutdown[0].output_base64sha256
  role             = aws_iam_role.idle_shutdown[0].arn

  environment {
    variables = {
      INSTANCE_ID          = aws_instance.rockport.id
      IDLE_TIMEOUT_MINUTES = tostring(var.idle_timeout_minutes)
      IDLE_THRESHOLD_BYTES = tostring(var.idle_threshold_bytes)
    }
  }

  tags = local.common_tags
}

resource "aws_iam_role" "idle_shutdown" {
  count = var.enable_idle_shutdown ? 1 : 0
  name  = "rockport-idle-shutdown"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "idle_shutdown" {
  count = var.enable_idle_shutdown ? 1 : 0
  name  = "idle-shutdown"
  role  = aws_iam_role.idle_shutdown[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:StopInstances"
        Resource = aws_instance.rockport.arn
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:GetMetricStatistics"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/rockport-idle-shutdown:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "idle_shutdown" {
  count             = var.enable_idle_shutdown ? 1 : 0
  name              = "/aws/lambda/rockport-idle-shutdown"
  retention_in_days = 30

  tags = local.common_tags
}

resource "aws_cloudwatch_event_rule" "idle_check" {
  count               = var.enable_idle_shutdown ? 1 : 0
  name                = "rockport-idle-check"
  description         = "Check for Rockport instance inactivity every 5 minutes"
  schedule_expression = "rate(5 minutes)"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "idle_check" {
  count = var.enable_idle_shutdown ? 1 : 0
  rule  = aws_cloudwatch_event_rule.idle_check[0].name
  arn   = aws_lambda_function.idle_shutdown[0].arn
}

resource "aws_lambda_permission" "idle_check" {
  count         = var.enable_idle_shutdown ? 1 : 0
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.idle_shutdown[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle_check[0].arn
}

resource "aws_cloudwatch_metric_alarm" "idle_shutdown_errors" {
  count               = var.enable_idle_shutdown ? 1 : 0
  alarm_name          = "rockport-idle-shutdown-errors"
  alarm_description   = "Alerts when the idle-shutdown Lambda fails consecutively, meaning idle detection has stopped working"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.idle_shutdown[0].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = local.common_tags
}
