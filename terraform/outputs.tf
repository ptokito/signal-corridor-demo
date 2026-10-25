output "portal_url" {
  value = "http://${aws_instance.host.public_ip}/"
}

output "host_instance_id" {
  value = aws_instance.host.id
}

output "k3s_instance_id" {
  value = aws_instance.k3s.id
}

output "host_private_ip" {
  value = aws_instance.host.private_ip
}

output "k3s_private_ip" {
  value = aws_instance.k3s.private_ip
}

output "newrelic_integration_role_arn" {
  value = var.newrelic_account_id == "" ? "not created (set newrelic_account_id)" : aws_iam_role.newrelic[0].arn
}

output "connect_host" {
  value = "aws ssm start-session --target ${aws_instance.host.id} --region ${var.region}"
}

output "connect_k3s" {
  value = "aws ssm start-session --target ${aws_instance.k3s.id} --region ${var.region}"
}
