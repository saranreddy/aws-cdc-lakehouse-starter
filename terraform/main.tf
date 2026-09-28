locals {
  common_tags = {
    NamePrefix = var.name_prefix
  }
}

# Random suffix for unique resource names
resource "random_id" "suffix" {
  byte_length = 4
}

# Networking: VPC, subnets, security groups, VPC endpoints
module "networking" {
  source = "./modules/networking"

  name_prefix         = var.name_prefix
  region              = var.region
  allowed_cidr_blocks = var.allowed_cidr_blocks
  random_suffix       = random_id.suffix.hex
}

# RDS Postgres with logical replication
module "rds" {
  source = "./modules/rds"

  name_prefix        = var.name_prefix
  instance_class     = var.rds_instance_class
  allocated_storage  = var.rds_allocated_storage
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  security_group_ids = [module.networking.rds_security_group_id]
  random_suffix      = random_id.suffix.hex
}

# MSK Serverless cluster with IAM auth
module "msk" {
  source = "./modules/msk"

  name_prefix        = var.name_prefix
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  security_group_ids = [module.networking.msk_security_group_id]
  random_suffix      = random_id.suffix.hex
}

# IAM roles for MSK Connect connectors
module "iam" {
  source = "./modules/iam"

  name_prefix        = var.name_prefix
  region             = var.region
  s3_bucket_arn      = module.msk.s3_bucket_arn
  msk_cluster_arn    = module.msk.cluster_arn
  rds_secret_arn     = module.rds.secret_arn
  glue_database_name = module.glue.database_name
  random_suffix      = random_id.suffix.hex
}

# Glue Data Catalog
module "glue" {
  source = "./modules/glue"

  name_prefix   = var.name_prefix
  s3_bucket_arn = module.msk.s3_bucket_arn
  random_suffix = random_id.suffix.hex
}

# MSK Connect: Debezium source and Iceberg sink connectors
# Only created when enable_connectors=true (after seed)
module "msk_connect" {
  count  = var.enable_connectors ? 1 : 0
  source = "./modules/msk-connect"

  name_prefix           = var.name_prefix
  vpc_id                = module.networking.vpc_id
  subnet_ids            = module.networking.private_subnet_ids
  security_group_ids    = [module.networking.msk_connect_security_group_id]
  msk_cluster_arn       = module.msk.cluster_arn
  msk_bootstrap_brokers = module.msk.bootstrap_brokers_sasl_iam
  s3_bucket_name        = module.msk.s3_bucket_name
  s3_bucket_arn         = module.msk.s3_bucket_arn
  debezium_role_arn     = module.iam.debezium_connector_role_arn
  iceberg_role_arn      = module.iam.iceberg_connector_role_arn
  rds_address           = module.rds.address
  rds_port              = module.rds.port
  rds_database_name     = module.rds.database_name
  rds_master_username   = module.rds.master_username
  rds_secret_arn        = module.rds.secret_arn
  glue_database_name    = module.glue.database_name
  glue_catalog_id       = module.glue.catalog_id
  region                = var.region
  random_suffix         = random_id.suffix.hex
}

# Athena workgroup and named queries
module "athena" {
  source = "./modules/athena"

  name_prefix        = var.name_prefix
  glue_database_name = module.glue.database_name
  random_suffix      = random_id.suffix.hex
}
