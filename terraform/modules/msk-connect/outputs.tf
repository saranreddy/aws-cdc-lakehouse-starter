output "debezium_connector_name" {
  description = "Name of the Debezium source connector"
  value       = aws_mskconnect_connector.debezium_postgres.name
}

output "debezium_connector_arn" {
  description = "ARN of the Debezium source connector"
  value       = aws_mskconnect_connector.debezium_postgres.arn
}

output "iceberg_connector_name" {
  description = "Name of the Iceberg sink connector"
  value       = aws_mskconnect_connector.iceberg_sink.name
}

output "iceberg_connector_arn" {
  description = "ARN of the Iceberg sink connector"
  value       = aws_mskconnect_connector.iceberg_sink.arn
}

output "debezium_plugin_arn" {
  description = "ARN of the Debezium custom plugin"
  value       = aws_mskconnect_custom_plugin.debezium.arn
}

output "iceberg_plugin_arn" {
  description = "ARN of the Iceberg custom plugin"
  value       = aws_mskconnect_custom_plugin.iceberg.arn
}
