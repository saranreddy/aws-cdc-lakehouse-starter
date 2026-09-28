# S3 bucket for Athena query results
resource "aws_s3_bucket" "athena_results" {
  bucket_prefix = "${var.name_prefix}-athena-results-"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-athena-results"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "delete_old_results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

# Athena Workgroup
resource "aws_athena_workgroup" "main" {
  name          = "${var.name_prefix}-workgroup"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = {
    Name = "${var.name_prefix}-workgroup"
  }
}

# Named Query: Current orders per customer
resource "aws_athena_named_query" "orders_per_customer" {
  name      = "${var.name_prefix}_orders_per_customer"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  query     = <<-SQL
    SELECT 
      c.id as customer_id,
      c.name as customer_name,
      COUNT(o.id) as total_orders,
      SUM(o.total_amount) as total_spent
    FROM customers c
    LEFT JOIN orders o ON c.id = o.customer_id
    GROUP BY c.id, c.name
    ORDER BY total_spent DESC;
  SQL

  description = "Count orders and total spent per customer"
}

# Named Query: Revenue by day
resource "aws_athena_named_query" "revenue_by_day" {
  name      = "${var.name_prefix}_revenue_by_day"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  query     = <<-SQL
    SELECT 
      DATE(order_date) as order_day,
      COUNT(*) as order_count,
      SUM(total_amount) as daily_revenue
    FROM orders
    GROUP BY DATE(order_date)
    ORDER BY order_day DESC;
  SQL

  description = "Daily revenue summary"
}

# Named Query: Iceberg time travel example
resource "aws_athena_named_query" "time_travel" {
  name      = "${var.name_prefix}_time_travel_example"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  query     = <<-SQL
    -- View the current state of orders
    SELECT * FROM orders LIMIT 10;
    
    -- To query historical state (replace with actual snapshot ID):
    -- SELECT * FROM orders FOR SYSTEM_TIME AS OF TIMESTAMP '2024-01-01 00:00:00' LIMIT 10;
    
    -- To query by snapshot ID:
    -- SELECT * FROM orders FOR SYSTEM_VERSION AS OF <snapshot_id> LIMIT 10;
    
    -- List available snapshots:
    -- SELECT * FROM "orders$snapshots" ORDER BY committed_at DESC;
  SQL

  description = "Example of Iceberg time travel queries"
}

# Named Query: Top selling items
resource "aws_athena_named_query" "top_items" {
  name      = "${var.name_prefix}_top_selling_items"
  workgroup = aws_athena_workgroup.main.id
  database  = var.glue_database_name
  query     = <<-SQL
    SELECT 
      product_name,
      SUM(quantity) as total_quantity,
      SUM(quantity * unit_price) as total_revenue
    FROM order_items
    GROUP BY product_name
    ORDER BY total_revenue DESC
    LIMIT 20;
  SQL

  description = "Top selling items by revenue"
}
