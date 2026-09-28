variable "name_prefix" {
  description = "Name prefix for resources"
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
