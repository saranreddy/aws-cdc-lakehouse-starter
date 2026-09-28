data "aws_caller_identity" "current" {}

# Glue Catalog Database for Iceberg tables
# Note: Database names must match ^[a-z0-9_]{1,252}$ (no hyphens)
resource "aws_glue_catalog_database" "lakehouse" {
  name        = "${replace(var.name_prefix, "-", "_")}_lakehouse"
  description = "Database for CDC Iceberg tables"

  tags = {
    Name = "${var.name_prefix}-lakehouse-db"
  }
}

# Clean up Glue tables created by Iceberg sink on destroy
resource "null_resource" "cleanup_glue_tables" {
  # Trigger on database changes
  triggers = {
    database_name = aws_glue_catalog_database.lakehouse.name
    region        = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      # Delete all tables in the database before destroying
      aws glue get-tables --database-name "${self.triggers.database_name}" \
        --region ${self.triggers.region} \
        --query 'TableList[].Name' --output text 2>/dev/null | \
      tr '\t' '\n' | while read -r table; do
        if [ -n "$table" ]; then
          echo "Deleting Glue table: $table"
          aws glue delete-table --database-name "${self.triggers.database_name}" --name "$table" --region ${self.triggers.region} 2>/dev/null || true
        fi
      done
    EOF
  }

  depends_on = [aws_glue_catalog_database.lakehouse]
}
