# Auto-stop EC2 instance after period of inactivity

data "archive_file" "idle_shutdown" {
  count       = var.enable_idle_shutdown ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.build/idle-shutdown.zip"

  source {
    content  = <<-PYTHON
    import boto3
    import os
    from datetime import datetime, timedelta, timezone

    def handler(event, context):
        ec2 = boto3.client('ec2')
        cw = boto3.client('cloudwatch')

        instance_id = os.environ['INSTANCE_ID']
        idle_minutes = int(os.environ['IDLE_TIMEOUT_MINUTES'])

        # Skip if instance is not running
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        inst = resp['Reservations'][0]['Instances'][0]
        state = inst['State']['Name']
        if state != 'running':
            print(f'Instance {instance_id} is {state}, skipping')
            return {'status': state}

        # Grace period: skip if instance launched/started less than 10 minutes ago
        # This prevents killing the instance during bootstrap or post-start recovery
        now = datetime.now(timezone.utc)
        launch_time = inst['LaunchTime']
        uptime_minutes = (now - launch_time).total_seconds() / 60
        if uptime_minutes < 10:
            print(f'Instance uptime {uptime_minutes:.0f}min < 10min grace period, skipping')
            return {'status': 'grace_period', 'uptime_minutes': int(uptime_minutes)}
        start = now - timedelta(minutes=idle_minutes)

        metrics = cw.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName='NetworkIn',
            Dimensions=[{'Name': 'InstanceId', 'Value': instance_id}],
            StartTime=start,
            EndTime=now,
            Period=300,
            Statistics=['Sum']
        )

        total_bytes = sum(dp['Sum'] for dp in metrics['Datapoints'])

        # cloudflared keepalives: ~6KB/min = ~180KB/30min
        # A single LLM request: typically 50KB-5MB+
        # 500KB threshold distinguishes idle from active use
        threshold = int(os.environ.get('IDLE_THRESHOLD_BYTES', '500000'))

        if total_bytes < threshold:
            print(f'Idle: {total_bytes} bytes in {idle_minutes}min, stopping')
            ec2.stop_instances(InstanceIds=[instance_id])
            return {'status': 'stopped', 'bytes': int(total_bytes)}

        print(f'Active: {total_bytes} bytes in {idle_minutes}min')
        return {'status': 'active', 'bytes': int(total_bytes)}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "idle_shutdown" {
  count            = var.enable_idle_shutdown ? 1 : 0
  function_name    = "rockport-idle-shutdown"
  runtime          = "python3.12"
  handler          = "index.handler"
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
