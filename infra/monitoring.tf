# Three alarms and one composite health alarm. Only the composite notifies SNS.

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # must be confirmed from the inbox, else it stays PendingConfirmation
}

# End-to-end freshness from the consumer. Missing data means the consumer is dead: breaching.
resource "aws_cloudwatch_metric_alarm" "freshness" {
  alarm_name          = "${var.name}-freshness"
  alarm_description   = "Trades older than 5s when written to the DB, or no metric at all"
  namespace           = "TradesPipeline"
  metric_name         = "FreshnessSeconds"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
}

# Consumer alive but falling behind: the estimated time to drain the backlog. With no consumer at all
# it reads 0 (no read rate to estimate from), so the backlog alarm below covers that case.
# Missing data (no consumer group yet, right after a deploy) is not a backlog: notBreaching.
resource "aws_cloudwatch_metric_alarm" "lag" {
  alarm_name          = "${var.name}-lag"
  alarm_description   = "Consumer group trades-writer is more than 60s behind on topic trades"
  namespace           = "AWS/Kafka"
  metric_name         = "EstimatedMaxTimeLag"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    "Cluster Name"   = aws_msk_cluster.this.cluster_name
    "Consumer Group" = "trades-writer"
    "Topic"          = "trades"
  }
}

# Messages waiting in the busiest partition. Normal peaks were under 600 over 48 hours; with the
# consumers stopped it grew by about 10,000 a minute. Unlike the time lag, it grows when no one reads.
resource "aws_cloudwatch_metric_alarm" "backlog" {
  alarm_name          = "${var.name}-backlog"
  alarm_description   = "More than 10,000 messages waiting in a partition of topic trades for group trades-writer"
  namespace           = "AWS/Kafka"
  metric_name         = "MaxOffsetLag"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 10000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    "Cluster Name"   = aws_msk_cluster.this.cluster_name
    "Consumer Group" = "trades-writer"
    "Topic"          = "trades"
  }
}

resource "aws_cloudwatch_composite_alarm" "health" {
  alarm_name        = "${var.name}-health"
  alarm_description = "Pipeline health: freshness OR lag OR backlog"
  alarm_rule        = "ALARM(\"${aws_cloudwatch_metric_alarm.freshness.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.lag.alarm_name}\") OR ALARM(\"${aws_cloudwatch_metric_alarm.backlog.alarm_name}\")"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
