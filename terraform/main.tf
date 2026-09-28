# MSK Serverless cluster with IAM auth
module "msk" {
  source = "./modules/msk"

  name_prefix       = var.name_prefix
  vpc_id            = module.networking.vpc_id
  subnet_ids        = module.networking.private_subnet_ids
  security_group_ids = [module.networking.msk_security_group_id]
  random_suffix     = random_id.suffix.hex
}