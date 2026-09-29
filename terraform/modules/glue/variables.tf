variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN for Iceberg tables"
  type        = string
}

variable "random_suffix" {
  description = "Random suffix for unique names"
  type        = string
}
