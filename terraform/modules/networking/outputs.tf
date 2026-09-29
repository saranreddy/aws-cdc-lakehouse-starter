output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "msk_security_group_id" {
  value = aws_security_group.msk.id
}

output "msk_connect_security_group_id" {
  value = aws_security_group.msk_connect.id
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}
