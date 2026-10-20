output "instance_id" {
  description = "ID of the EC2 hybrid node."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address of the EC2 hybrid node."
  value       = aws_instance.this.private_ip
}

output "primary_network_interface_id" {
  description = "ID of the hybrid node primary network interface."
  value       = aws_instance.this.primary_network_interface_id
}

output "availability_zone" {
  description = "Availability Zone in which the hybrid node launched."
  value       = aws_instance.this.availability_zone
}