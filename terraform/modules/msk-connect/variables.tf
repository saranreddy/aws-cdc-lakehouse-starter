variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for MSK Connect"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for MSK Connect"
  type        = list(string)
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK bootstrap brokers"
  type        = string
}

variable "s3_bucket_name" {
  description = "S3 bucket name"
  type        = string
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN"
  type        = string
}

variable "debezium_role_arn" {
  description = "IAM role ARN for Debezium connector"
  type        = string
}

variable "iceberg_role_arn" {
  description = "IAM role ARN for Iceberg connector"
  type        = string
}

variable "rds_endpoint" {
  description = "RDS endpoint"
  type        = string
}

variable "rds_port" {
  description = "RDS port"
  type        = number
}

variable "rds_database_name" {
  description = "RDS database name"
  type        = string
}

variable "rds_master_username" {
  description = "RDS master username"
  type        = string
}

variable "rds_secret_arn" {
  description = "RDS secret ARN"
  type        = string
}

variable "glue_database_name" {
  description = "Glue database name"
  type        = string
}

variable "glue_catalog_id" {
  description = "Glue catalog ID"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "random_suffix" {
  description = "Random suffix for unique names"
  type        = string
}
