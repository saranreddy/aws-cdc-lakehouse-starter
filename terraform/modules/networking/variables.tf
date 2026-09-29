variable "name_prefix" {
  description = "Name prefix for resources"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access bastion"
  type        = list(string)
}

variable "random_suffix" {
  description = "Random suffix for unique names"
  type        = string
}
