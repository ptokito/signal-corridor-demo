variable "account_id" {
  description = "New Relic account ID that receives the corridor data (the demo account)."
  type        = number
}

variable "alert_email" {
  description = "Email address that receives alert notifications."
  type        = string
}
