output "cluster_arn" {
  value = aws_msk_cluster.main.arn
}

output "bootstrap_brokers_sasl_iam" {
  value = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}

output "s3_bucket_name" {
  value = aws_s3_bucket.lakehouse.id
}

output "s3_bucket_arn" {
  value = aws_s3_bucket.lakehouse.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.msk.name
}
