# New Relic AWS cloud integration (API polling), as code.
# New Relic assumes the IAM role created by terraform/main.tf (trusted only for
# New Relic's AWS account, with our New Relic account ID as external ID) and
# reads CloudWatch metrics plus instance metadata and tags every few minutes.

variable "aws_role_arn" {
  description = "ARN of the IAM role New Relic assumes (terraform output newrelic_integration_role_arn)."
  type        = string
}

resource "newrelic_cloud_aws_link_account" "corridor" {
  account_id             = var.account_id
  name                   = "corridor-aws"
  arn                    = var.aws_role_arn
  metric_collection_mode = "PULL" # API polling
}

resource "newrelic_cloud_aws_integrations" "corridor" {
  account_id        = var.account_id
  linked_account_id = newrelic_cloud_aws_link_account.corridor.id

  ec2 {
    aws_regions              = ["us-east-1"]
    metrics_polling_interval = 300
    fetch_ip_addresses       = true
  }

  ebs {
    aws_regions              = ["us-east-1"]
    metrics_polling_interval = 900
  }
}
