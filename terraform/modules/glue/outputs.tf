output "database_name" {
  value = aws_glue_catalog_database.lakehouse.name
}

output "catalog_id" {
  value = aws_glue_catalog_database.lakehouse.catalog_id
}
