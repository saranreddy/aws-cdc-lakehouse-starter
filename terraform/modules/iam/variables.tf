variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN"
  type        = string
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN"
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

variable "random_suffix" {
  description = "Random suffix for unique names"
  type        = string
}
