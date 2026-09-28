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
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.name_prefix)) && length(var.name_prefix) <= 20
    error_message = "name_prefix must start with a letter, contain only lowercase letters/numbers/hyphens, not end with hyphen, max 20 chars"
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

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the temporary bastion (use your IP/32)"
  type        = list(string)
  default     = []
}

variable "enable_connectors" {
  description = "Enable MSK Connect connectors (set false for initial apply, true after seed)"
  type        = bool
  default     = false
}

