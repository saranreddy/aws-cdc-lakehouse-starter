variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Unique name prefix for all resources (allows multiple deployments to coexist)"
  type        = string
  default     = "cdc-lakehouse"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name_prefix)) && length(var.name_prefix) <= 20
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, max 20 chars"
  }
}

variable "rds_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "msk_instance_type" {
  description = "MSK broker instance type"
  type        = string
  default     = "kafka.t3.small"
}

variable "msk_broker_count" {
  description = "Number of MSK brokers (must match number of AZs)"
  type        = number
  default     = 2
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the temporary bastion (use your IP/32)"
  type        = list(string)
  default     = []
}
