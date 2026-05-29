# =============================================================================
# EXPERIMENTO ACADÉMICO — BITE.co Sprint 4
# ASR-SEG: Seguridad API Gateway + ASR-LAT: Latencia con controles activos
#
# AVISO: Contraseñas, API keys y valores sensibles están HARDCODEADOS
# intencionalmente. Esto es un experimento académico en AWS Academy, NO
# usar en producción.
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# =============================================================================
# SECURITY GROUPS
# =============================================================================

resource "aws_security_group" "kong" {
  name        = "bite-kong-sg"
  description = "Kong API Gateway - acceso publico por JMeter"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "JMeter -> Kong proxy"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH admin"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bite-kong-sg" }
}

resource "aws_security_group" "api" {
  name        = "bite-api-sg"
  description = "Flask/Gunicorn - acceso solo desde Kong"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.kong.id]
    description     = "Kong -> API"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH admin"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bite-api-sg" }
}

resource "aws_security_group" "db" {
  name        = "bite-db-sg"
  description = "PostgreSQL - acceso solo desde la API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
    description     = "API -> DB"
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH admin"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bite-db-sg" }
}

# =============================================================================
# EC2: bite-db — PostgreSQL 14 nativo en Ubuntu 22.04
# =============================================================================

resource "aws_instance" "db" {
  ami                         = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS, us-east-1
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.db.id]
  associate_public_ip_address = true

  tags = { Name = "bite-db" }

  user_data = <<EOT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
exec > /tmp/user-data-db.log 2>&1

echo "=== [bite-db] Iniciando setup de PostgreSQL ==="
apt-get update -y
apt-get install -y postgresql postgresql-contrib

systemctl enable postgresql
systemctl start postgresql

# Dar tiempo a que postgres arranque completamente
sleep 5

# Configurar para escuchar en todas las interfaces
PG_CONF=$(find /etc/postgresql -name postgresql.conf | head -1)
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"

# Permitir autenticacion MD5 desde cualquier IP (VPC)
PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -1)
echo "host    all             all             0.0.0.0/0               md5" >> "$PG_HBA"

systemctl restart postgresql
sleep 5

echo "=== Creando base de datos y usuario ==="
sudo -u postgres psql -c "CREATE DATABASE bite;"
sudo -u postgres psql -c "CREATE USER bite_app WITH PASSWORD 'bite_app_pass_123';"

echo "=== Creando esquema ==="
cat > /tmp/schema.sql << 'SQLEOF'
CREATE TABLE IF NOT EXISTS cloud_accounts (
  id         SERIAL PRIMARY KEY,
  company_id UUID         NOT NULL,
  account_id VARCHAR(12)  NOT NULL,
  account_name VARCHAR(50) NOT NULL,
  region     VARCHAR(20)  NOT NULL,
  role_arn   VARCHAR(255) NOT NULL,
  created_at TIMESTAMP    DEFAULT NOW(),
  UNIQUE (company_id, account_id)
);

CREATE TABLE IF NOT EXISTS audit_log (
  id        SERIAL PRIMARY KEY,
  timestamp TIMESTAMP DEFAULT NOW(),
  source_ip VARCHAR(45),
  endpoint  VARCHAR(255),
  status    VARCHAR(50),
  reason    TEXT,
  payload   TEXT
);

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO bite_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO bite_app;
SQLEOF

sudo -u postgres psql -d bite -f /tmp/schema.sql

echo "=== [bite-db] Setup completo ===" > /tmp/db-ready
echo "DB_READY" > /tmp/db-ready
EOT
}

# =============================================================================
# EC2: bite-api — Flask + Gunicorn, Python 3
# =============================================================================

resource "aws_instance" "api" {
  ami                         = "ami-0c7217cdde317cfec"
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.api.id]
  associate_public_ip_address = true
  depends_on                  = [aws_instance.db]

  tags = { Name = "bite-api" }

  user_data = <<EOT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
DB_IP="${aws_instance.db.private_ip}"
exec > /tmp/user-data-api.log 2>&1

echo "=== [bite-api] Iniciando setup ==="
apt-get update -y
apt-get install -y python3 python3-pip python3-dev postgresql-client

echo "=== Esperando a que la DB este completamente lista ==="
# Espera a que psql pueda conectarse Y que la tabla exista
until PGPASSWORD=bite_app_pass_123 psql -h $DB_IP -U bite_app -d bite -c "SELECT 1 FROM cloud_accounts LIMIT 0;" 2>/dev/null; do
  echo "DB no lista aun, reintentando en 10s..."
  sleep 10
done
echo "DB lista!"

echo "=== Instalando dependencias Python ==="
pip3 install flask==3.0.3 gunicorn==22.0.0 psycopg2-binary==2.9.9 --quiet

mkdir -p /opt/bite

echo "=== Escribiendo aplicacion Flask ==="
cat > /opt/bite/app.py << 'PYEOF'
#!/usr/bin/env python3
"""
BITE.co — Microservicio de registro de cuentas cloud AWS
Endpoint: POST /cloud-accounts/
"""
from flask import Flask, request, jsonify
import psycopg2
import psycopg2.errorcodes
import re
import uuid
import json

app = Flask(__name__)

DB_HOST = "DB_IP_PLACEHOLDER"
DB_NAME = "bite"
DB_USER = "bite_app"
DB_PASS = "bite_app_pass_123"

VALID_REGIONS = {
    "us-east-1", "us-east-2", "us-west-1",
    "us-west-2", "eu-west-1", "sa-east-1"
}
ARN_RE = re.compile(r'^arn:aws:iam::\d{12}:role/[A-Za-z0-9_+=,.@-]+$')

# Conexion persistente por worker de gunicorn
_db_conn = None


def get_conn():
    global _db_conn
    try:
        if _db_conn is None or _db_conn.closed:
            raise Exception("Conexion cerrada")
        # Verificar que la conexion sigue viva
        _db_conn.cursor().execute("SELECT 1")
    except Exception:
        _db_conn = psycopg2.connect(
            host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS,
            connect_timeout=5, application_name="bite-api"
        )
    return _db_conn


def log_audit(status, reason, payload, ip, endpoint="/cloud-accounts/"):
    try:
        conn = get_conn()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO audit_log (source_ip, endpoint, status, reason, payload) "
            "VALUES (%s, %s, %s, %s, %s)",
            (ip, endpoint, status, reason,
             json.dumps(payload) if payload else None)
        )
        conn.commit()
        cur.close()
    except Exception as e:
        try:
            _db_conn.rollback()
        except Exception:
            pass


@app.route('/cloud-accounts/', methods=['POST'])
def create_account():
    ip = request.remote_addr

    data = request.get_json(force=True, silent=True)
    if data is None:
        log_audit('INVALID_JSON', 'Body no es JSON valido', None, ip)
        return jsonify({"error": "Invalid JSON"}), 400

    errors = []

    try:
        uuid.UUID(str(data.get('company_id', '')))
    except (ValueError, AttributeError):
        errors.append("company_id debe ser UUID valido")

    account_id_val = str(data.get('account_id', ''))
    if not re.fullmatch(r'\d{12}', account_id_val):
        errors.append("account_id debe ser exactamente 12 digitos numericos")

    name = str(data.get('account_name', ''))
    if not (3 <= len(name) <= 50):
        errors.append("account_name debe tener entre 3 y 50 caracteres")

    if data.get('region') not in VALID_REGIONS:
        errors.append("region invalida (opciones: us-east-1, us-east-2, us-west-1, us-west-2, eu-west-1, sa-east-1)")

    if not ARN_RE.match(str(data.get('role_arn', ''))):
        errors.append("role_arn invalido (formato: arn:aws:iam::ACCOUNT:role/NAME)")

    if errors:
        log_audit('VALIDATION_FAILED', '; '.join(errors), data, ip)
        return jsonify({"errors": errors}), 400

    try:
        conn = get_conn()
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO cloud_accounts "
            "(company_id, account_id, account_name, region, role_arn) "
            "VALUES (%s, %s, %s, %s, %s) RETURNING id",
            (data['company_id'], data['account_id'], data['account_name'],
             data['region'], data['role_arn'])
        )
        new_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
    except psycopg2.IntegrityError as e:
        try:
            conn.rollback()
        except Exception:
            pass
        if e.pgcode == '23505':
            log_audit('DUPLICATE', 'company_id+account_id ya existe', data, ip)
            return jsonify({"error": "Account already registered"}), 409
        log_audit('DB_ERROR', str(e), data, ip)
        return jsonify({"error": "Database error"}), 500
    except Exception as e:
        try:
            _db_conn.rollback()
        except Exception:
            pass
        log_audit('DB_ERROR', str(e), data, ip)
        return jsonify({"error": "Internal server error"}), 500

    log_audit('SUCCESS', None, data, ip)
    return jsonify({"id": new_id}), 201


@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok"}), 200


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
PYEOF

# Reemplazar el placeholder con la IP real de la DB
sed -i "s/DB_IP_PLACEHOLDER/$DB_IP/" /opt/bite/app.py

echo "=== Arrancando Gunicorn con 4 workers ==="
cd /opt/bite
nohup gunicorn -w 4 -b 0.0.0.0:8080 --timeout 30 --log-file /tmp/gunicorn.log app:app > /tmp/app.log 2>&1 &
disown

echo "=== [bite-api] Setup completo ===" > /tmp/api-ready
EOT
}

# =============================================================================
# EC2: bite-kong — Kong 3.6 en Docker sobre Ubuntu 22.04
# =============================================================================

resource "aws_instance" "kong" {
  ami                         = "ami-0c7217cdde317cfec"
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.kong.id]
  associate_public_ip_address = true
  depends_on                  = [aws_instance.api]

  tags = { Name = "bite-kong" }

  user_data = <<EOT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
API_IP="${aws_instance.api.private_ip}"
exec > /tmp/user-data-kong.log 2>&1

echo "=== [bite-kong] Iniciando setup ==="
apt-get update -y
apt-get install -y docker.io
systemctl enable docker
systemctl start docker

# Esperar a que Docker este listo
sleep 5

echo "=== Creando configuracion de Kong ==="
mkdir -p /etc/kong

cat > /etc/kong/kong.yaml << 'KONGEOF'
_format_version: "3.0"
_transform: true

services:
  - name: cloud-accounts-service
    host: API_IP_PLACEHOLDER
    port: 8080
    protocol: http
    routes:
      - name: cloud-accounts-route
        paths:
          - /cloud-accounts
        strip_path: false
        plugins:
          - name: key-auth
            config:
              key_names:
                - apikey
          - name: rate-limiting
            config:
              minute: 2000
              policy: local
              # TG1 (20 threads x ~1 req/s = ~1200 req/min) pasa sin 429.
              # TG4 (5 threads sin timer = ~5000+ req/min) supera el limite y recibe 429.
          - name: request-size-limiting
            config:
              allowed_payload_size: 2
              size_unit: kilobytes
          - name: file-log
            config:
              path: /tmp/kong-audit.log
              reopen: true

consumers:
  - username: bite-admin
    keyauth_credentials:
      - key: bite-key-prod-001
KONGEOF

# Sustituir IP del microservicio
sed -i "s/API_IP_PLACEHOLDER/$API_IP/" /etc/kong/kong.yaml

echo "=== Arrancando Kong 3.6 en Docker ==="
docker run -d \
  --name kong \
  --restart always \
  -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml \
  -e KONG_PROXY_ACCESS_LOG=/dev/stdout \
  -e KONG_PROXY_ERROR_LOG=/dev/stderr \
  -e KONG_ADMIN_ACCESS_LOG=/dev/stdout \
  -e KONG_ADMIN_ERROR_LOG=/dev/stderr \
  -e KONG_LOG_LEVEL=warn \
  -p 8000:8000 \
  -p 8001:8001 \
  -v /etc/kong:/etc/kong \
  kong:3.6

sleep 10
echo "Estado de Kong:"
docker ps | grep kong
docker logs kong --tail 20

echo "=== [bite-kong] Setup completo ===" > /tmp/kong-ready
EOT
}
