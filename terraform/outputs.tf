output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "RDS port"
  value       = module.rds.port
}

output "rds_database_name" {
  description = "RDS database name"
  value       = module.rds.database_name
}

output "rds_master_username" {
  description = "RDS master username"
  value       = module.rds.master_username
}

output "rds_secret_arn" {
  description = "ARN of the secret containing the RDS master password"
  value       = module.rds.secret_arn
}

output "msk_bootstrap_brokers" {
  description = "MSK bootstrap brokers (IAM auth)"
  value       = module.msk.bootstrap_brokers_sasl_iam
}

output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = module.msk.cluster_arn
}

output "s3_bucket_name" {
  description = "S3 bucket for Iceberg tables and connector plugins"
  value       = module.msk.s3_bucket_name
}

output "glue_database_name" {
  description = "Glue database name"
  value       = module.glue.database_name
}

output "athena_workgroup_name" {
  description = "Athena workgroup name"
  value       = module.athena.workgroup_name
}

output "athena_results_bucket" {
  description = "Athena query results bucket"
  value       = module.athena.results_bucket
}

output "bastion_instance_id" {
  description = "Bastion instance ID (for SSM Session Manager)"
  value       = module.networking.bastion_instance_id
}

output "debezium_connector_name" {
  description = "Debezium source connector name (if enabled)"
  value       = var.enable_connectors ? module.msk_connect[0].debezium_connector_name : null
}

output "iceberg_connector_name" {
  description = "Iceberg sink connector name (if enabled)"
  value       = var.enable_connectors ? module.msk_connect[0].iceberg_connector_name : null
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}
output "iceberg_connector_arn" {
  description = "Iceberg connector ARN"
  value       = try(module.msk_connect.iceberg_connector_arn, null)
}
