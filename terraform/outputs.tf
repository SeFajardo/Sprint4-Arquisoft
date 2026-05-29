output "kong_public_ip" {
  value       = aws_instance.kong.public_ip
  description = "IP pública del Kong Gateway — usar en JMeter como host"
}

output "accounts_ms_public_ip" {
  value       = aws_instance.accounts_ms.public_ip
  description = "IP pública del microservicio (solo para SSH/debugging)"
}

output "accounts_db_public_ip" {
  value       = aws_instance.accounts_db.public_ip
  description = "IP pública de la DB (solo para SSH/debugging)"
}

output "api_endpoint" {
  value       = "http://${aws_instance.kong.public_ip}:8000/cloud-accounts/"
  description = "Endpoint que JMeter va a atacar"
}

output "api_key" {
  value       = "bite-key-prod-001"
  description = "API key válida (debe enviarse en header 'apikey')"
}
