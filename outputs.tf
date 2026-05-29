output "db_public_ip" {
  description = "IP publica de la EC2 con PostgreSQL (SSH)"
  value       = aws_instance.db.public_ip
}

output "api_public_ip" {
  description = "IP publica de la EC2 con Flask/Gunicorn (SSH)"
  value       = aws_instance.api.public_ip
}

output "kong_public_ip" {
  description = "IP publica de Kong — usa esta en JMeter como KONG_HOST"
  value       = aws_instance.kong.public_ip
}

output "api_endpoint" {
  description = "URL completa del endpoint a traves de Kong"
  value       = "http://${aws_instance.kong.public_ip}:8000/cloud-accounts/"
}

output "ssh_db" {
  description = "Comando SSH para conectarse a la DB"
  value       = "ssh -i vockey.pem ubuntu@${aws_instance.db.public_ip}"
}

output "ssh_api" {
  description = "Comando SSH para conectarse a la API"
  value       = "ssh -i vockey.pem ubuntu@${aws_instance.api.public_ip}"
}

output "ssh_kong" {
  description = "Comando SSH para conectarse a Kong"
  value       = "ssh -i vockey.pem ubuntu@${aws_instance.kong.public_ip}"
}

output "mongo_public_ip" {
  description = "IP publica de la EC2 con MongoDB (SSH)"
  value       = aws_instance.mongo.public_ip
}

output "ssh_mongo" {
  description = "Comando SSH para conectarse a MongoDB"
  value       = "ssh -i vockey.pem ubuntu@${aws_instance.mongo.public_ip}"
}
