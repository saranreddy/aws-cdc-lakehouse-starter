variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "msk_bootstrap_brokers" {
  description = "MSK bootstrap brokers"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for Lambda"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for Lambda"
  type        = string
}

variable "msk_cluster_arn" {
  description = "MSK cluster ARN"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "random_suffix" {
  description = "Random suffix"
  type        = string
}
