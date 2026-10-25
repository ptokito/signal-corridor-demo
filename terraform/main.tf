# Smart Signal Corridor demo environment (New Relic TSM assignment), on AWS.
#
# Two EC2 instances in the default VPC:
#   corridor-host-tier  Ubuntu VM: NGINX reverse proxy, Operations Portal (Flask),
#                       PostgreSQL, Redis, New Relic infrastructure agent and
#                       on-host integrations
#   corridor-k3s-node   single-node Kubernetes (k3s): signal-api, timing-engine,
#                       crew-dispatch, corridor-simulator, and the New Relic
#                       Kubernetes integration
#
# No SSH. Both instances are reached with AWS Systems Manager Session Manager.
# The New Relic license key is stored once in SSM Parameter Store and read at boot.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = "smart-signal-corridor"
      Owner   = var.owner
    }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

locals {
  subnet_id = sort(data.aws_subnets.default.ids)[0]
}

# ---------------------------------------------------------------- secrets
resource "aws_ssm_parameter" "nr_license_key" {
  name        = "/signal-corridor/newrelic-license-key"
  type        = "SecureString"
  value       = var.newrelic_license_key
  description = "New Relic ingest license key for the demo agents"
}

resource "random_password" "pg" {
  length  = 24
  special = false
}

resource "random_password" "redis" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "pg_password" {
  name  = "/signal-corridor/postgres-password"
  type  = "SecureString"
  value = random_password.pg.result
}

resource "aws_ssm_parameter" "redis_password" {
  name  = "/signal-corridor/redis-password"
  type  = "SecureString"
  value = random_password.redis.result
}

# ---------------------------------------------------------------- IAM for the instances
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "corridor-demo-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_params" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/signal-corridor/*"]
  }
}

resource "aws_iam_role_policy" "read_params" {
  name   = "read-demo-parameters"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.read_params.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "corridor-demo-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------- network
resource "aws_security_group" "host" {
  name        = "corridor-host-tier"
  description = "Public web on 80; database and cache only from the cluster"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Portal over HTTP (Synthetics and real browsers)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.web_ingress_cidrs
  }
  ingress {
    description     = "Portal from the in-cluster corridor simulator"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.k3s.id]
  }
  ingress {
    description     = "PostgreSQL from k3s"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.k3s.id]
  }
  ingress {
    description     = "Redis from k3s"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.k3s.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "k3s" {
  name        = "corridor-k3s"
  description = "k3s node; signal-api NodePort reachable from host tier only"
  vpc_id      = data.aws_vpc.default.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "k3s_from_host" {
  type                     = "ingress"
  description              = "signal-api NodePort from the portal"
  from_port                = 30081
  to_port                  = 30081
  protocol                 = "tcp"
  security_group_id        = aws_security_group.k3s.id
  source_security_group_id = aws_security_group.host.id
}

# ---------------------------------------------------------------- instances
resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.k3s_instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  dynamic "instance_market_options" {
    for_each = var.k3s_use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type = "one-time"
      }
    }
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }
  user_data = templatefile("${path.module}/../scripts/k3s-bootstrap.sh", {
    region   = var.region
    repo_url = var.repo_url
  })
  tags = { Name = "corridor-k3s-node", Role = "kubernetes" }
}

resource "aws_instance" "host" {
  # The boot script reads these parameters, so they must exist before the host starts.
  depends_on = [aws_ssm_parameter.nr_license_key, aws_ssm_parameter.pg_password, aws_ssm_parameter.redis_password]

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.host_instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  user_data = templatefile("${path.module}/../scripts/host-bootstrap.sh", {
    region          = var.region
    repo_url        = var.repo_url
    k3s_private_ip  = aws_instance.k3s.private_ip
    vpc_cidr        = data.aws_vpc.default.cidr_block
  })
  tags = { Name = "corridor-host-tier", Role = "proxy-web-db-cache" }
}

# ---------------------------------------------------------------- New Relic AWS integration (optional)
# Role that New Relic's AWS account assumes for API polling of EC2 and other services.
# 754728514883 is New Relic's AWS account; the external ID is your New Relic account ID.
data "aws_iam_policy_document" "newrelic_assume" {
  count = var.newrelic_account_id == "" ? 0 : 1
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::754728514883:root"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.newrelic_account_id]
    }
  }
}

resource "aws_iam_role" "newrelic" {
  count              = var.newrelic_account_id == "" ? 0 : 1
  name               = "NewRelicInfrastructure-Integrations-corridor"
  assume_role_policy = data.aws_iam_policy_document.newrelic_assume[0].json
}

resource "aws_iam_role_policy_attachment" "newrelic_readonly" {
  count      = var.newrelic_account_id == "" ? 0 : 1
  role       = aws_iam_role.newrelic[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
