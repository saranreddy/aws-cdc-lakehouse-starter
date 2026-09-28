output "endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "port" {
  value = aws_db_instance.postgres.port
}

output "database_name" {
  value = aws_db_instance.postgres.db_name
}

output "master_username" {
  value = aws_db_instance.postgres.username
}

output "secret_arn" {
  value = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "instance_arn" {
  value = aws_db_instance.postgres.arn
}
