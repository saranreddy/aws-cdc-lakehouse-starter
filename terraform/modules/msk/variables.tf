variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for MSK"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for MSK"
  type        = list(string)
}

variable "instance_type" {
  description = "MSK broker instance type"
  type        = string
}

variable "broker_count" {
  description = "Number of brokers"
  type        = number
}

variable "random_suffix" {
  description = "Random suffix for unique names"
  type        = string
}
