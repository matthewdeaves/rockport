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

    # Check CPU utilisation as a second signal
    cpu_metrics = cw.get_metric_statistics(
        Namespace='AWS/EC2',
        MetricName='CPUUtilization',
        Dimensions=[{'Name': 'InstanceId', 'Value': instance_id}],
        StartTime=start,
        EndTime=now,
        Period=300,
        Statistics=['Average']
    )
    cpu_datapoints = cpu_metrics.get('Datapoints', [])
    avg_cpu = (sum(dp['Average'] for dp in cpu_datapoints) / len(cpu_datapoints)) if cpu_datapoints else 0

    # cloudflared keepalives: ~6KB/min = ~180KB/30min
    # A single LLM request: typically 50KB-5MB+
    # 500KB threshold distinguishes idle from active use
    threshold = int(os.environ.get('IDLE_THRESHOLD_BYTES', '500000'))
    cpu_threshold = float(os.environ.get('IDLE_CPU_THRESHOLD_PERCENT', '10'))

    # Only stop if BOTH network and CPU are below thresholds
    if total_bytes < threshold and avg_cpu < cpu_threshold:
        print(f'Idle: {total_bytes} bytes, {avg_cpu:.1f}% CPU in {idle_minutes}min, stopping')
        ec2.stop_instances(InstanceIds=[instance_id])
        return {'status': 'stopped', 'bytes': int(total_bytes), 'cpu_percent': round(avg_cpu, 1)}

    print(f'Active: {total_bytes} bytes, {avg_cpu:.1f}% CPU in {idle_minutes}min')
    return {'status': 'active', 'bytes': int(total_bytes), 'cpu_percent': round(avg_cpu, 1)}
