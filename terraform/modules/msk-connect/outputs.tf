output "debezium_connector_name" {
  value = aws_mskconnect_connector.debezium.name
}

output "debezium_connector_arn" {
  value = aws_mskconnect_connector.debezium.arn
}

output "iceberg_connector_name" {
  value = aws_mskconnect_connector.iceberg.name
}

output "iceberg_connector_arn" {
  value = aws_mskconnect_connector.iceberg.arn
}

output "debezium_plugin_arn" {
  value = aws_mskconnect_custom_plugin.debezium.arn
}

output "iceberg_plugin_arn" {
  value = aws_mskconnect_custom_plugin.iceberg.arn
}
