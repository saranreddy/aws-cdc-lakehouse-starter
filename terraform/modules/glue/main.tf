data "aws_caller_identity" "current" {}

# Glue Catalog Database for Iceberg tables
resource "aws_glue_catalog_database" "lakehouse" {
  name        = "${var.name_prefix}_lakehouse"
  description = "Database for CDC Iceberg tables"

  tags = {
    Name = "${var.name_prefix}-lakehouse-db"
  }
}
