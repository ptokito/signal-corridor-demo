variable "region" {
  type    = string
  default = "us-east-1"
}

variable "owner" {
  type    = string
  default = "tim"
}

variable "newrelic_license_key" {
  description = "New Relic INGEST - LICENSE key (not a user key). Pass with TF_VAR_newrelic_license_key."
  type        = string
  sensitive   = true
}

variable "newrelic_account_id" {
  description = "New Relic account ID. When set, creates the IAM role for the AWS cloud integration."
  type        = string
  default     = ""
}

variable "repo_url" {
  description = "Public Git URL of this repository; both instances clone it at boot."
  type        = string
}

variable "web_ingress_cidrs" {
  description = "Who can reach the portal on port 80. Synthetics public locations need 0.0.0.0/0."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "host_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "k3s_instance_type" {
  type    = string
  default = "t3.large"
}

variable "k3s_use_spot" {
  description = "Spot is cheap for build days. Set false the day before the panel so the node cannot be reclaimed mid-demo."
  type        = bool
  default     = true
}
