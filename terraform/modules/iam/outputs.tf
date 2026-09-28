output "debezium_connector_role_arn" {
  value = aws_iam_role.debezium_connector.arn
}

output "iceberg_connector_role_arn" {
  value = aws_iam_role.iceberg_connector.arn
}
