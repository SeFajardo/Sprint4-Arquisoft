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

resource "aws_security_group" "mongo" {
  name        = "bite-mongo-sg"
  description = "MongoDB - acceso solo desde la API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
    description     = "API -> MongoDB"
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

  tags = { Name = "bite-mongo-sg" }
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

echo "=== Insertando datos semilla en PostgreSQL ==="
cat > /tmp/seed.sql << 'SEEDEOF'
-- 15 cuentas cloud de demostración (empresas colombianas ficticias)
INSERT INTO cloud_accounts (company_id, account_id, account_name, region, role_arn) VALUES
  ('11111111-1111-1111-1111-111111111111', '100000000001', 'TechCorp Production AWS',  'us-east-1', 'arn:aws:iam::100000000001:role/BiteCoAccess'),
  ('22222222-2222-2222-2222-222222222222', '200000000002', 'Bancolombia Digital',       'us-east-1', 'arn:aws:iam::200000000002:role/BiteCoAccess'),
  ('33333333-3333-3333-3333-333333333333', '300000000003', 'Rappi Cloud Services',      'us-west-2', 'arn:aws:iam::300000000003:role/BiteCoAccess'),
  ('44444444-4444-4444-4444-444444444444', '400000000004', 'Ecopetrol Tech Ops',        'us-east-2', 'arn:aws:iam::400000000004:role/BiteCoAccess'),
  ('55555555-5555-5555-5555-555555555555', '500000000005', 'Grupo Exito AWS',           'us-east-1', 'arn:aws:iam::500000000005:role/BiteCoAccess'),
  ('66666666-6666-6666-6666-666666666666', '600000000006', 'Avianca Systems',           'us-east-1', 'arn:aws:iam::600000000006:role/BiteCoAccess'),
  ('77777777-7777-7777-7777-777777777777', '700000000007', 'Davivienda Cloud',          'sa-east-1', 'arn:aws:iam::700000000007:role/BiteCoAccess'),
  ('88888888-8888-8888-8888-888888888888', '800000000008', 'Corona Digital',            'us-west-2', 'arn:aws:iam::800000000008:role/BiteCoAccess'),
  ('99999999-9999-9999-9999-999999999999', '900000000009', 'Alpina Cloud Services',     'us-east-1', 'arn:aws:iam::900000000009:role/BiteCoAccess'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '101000000010', 'Claro Colombia AWS',        'us-east-2', 'arn:aws:iam::101000000010:role/BiteCoAccess'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '110000000011', 'Nutresa Tech Hub',          'us-west-1', 'arn:aws:iam::110000000011:role/BiteCoAccess'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', '120000000012', 'ISA Networks Cloud',        'sa-east-1', 'arn:aws:iam::120000000012:role/BiteCoAccess'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '130000000013', 'Celsia Digital Ops',        'us-east-1', 'arn:aws:iam::130000000013:role/BiteCoAccess'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '140000000014', 'Cementos Argos Cloud',      'eu-west-1', 'arn:aws:iam::140000000014:role/BiteCoAccess'),
  ('ffffffff-ffff-ffff-ffff-ffffffffffff', '150000000015', 'Suramericana AWS',          'us-east-1', 'arn:aws:iam::150000000015:role/BiteCoAccess')
ON CONFLICT (company_id, account_id) DO NOTHING;

-- Eventos de auditoría de demostración (variedad de status)
INSERT INTO audit_log (source_ip, endpoint, status, reason, payload) VALUES
  ('10.0.1.50', '/cloud-accounts/', 'SUCCESS',          NULL,
   '{"company_id":"11111111-1111-1111-1111-111111111111","account_id":"100000000001","account_name":"TechCorp Production AWS","region":"us-east-1","role_arn":"arn:aws:iam::100000000001:role/BiteCoAccess"}'),
  ('10.0.1.51', '/cloud-accounts/', 'SUCCESS',          NULL,
   '{"company_id":"22222222-2222-2222-2222-222222222222","account_id":"200000000002","account_name":"Bancolombia Digital","region":"us-east-1","role_arn":"arn:aws:iam::200000000002:role/BiteCoAccess"}'),
  ('10.0.1.52', '/cloud-accounts/', 'SUCCESS',          NULL,
   '{"company_id":"33333333-3333-3333-3333-333333333333","account_id":"300000000003","account_name":"Rappi Cloud Services","region":"us-west-2","role_arn":"arn:aws:iam::300000000003:role/BiteCoAccess"}'),
  ('10.0.1.60', '/cloud-accounts/', 'VALIDATION_FAILED','account_id debe ser exactamente 12 digitos numericos',
   '{"company_id":"33333333-3333-3333-3333-333333333333","account_id":"12345","account_name":"Test","region":"us-east-1","role_arn":"arn:aws:iam::300000000003:role/BiteCoAccess"}'),
  ('10.0.1.61', '/cloud-accounts/', 'VALIDATION_FAILED','region invalida',
   '{"company_id":"44444444-4444-4444-4444-444444444444","account_id":"400000000004","account_name":"Ecopetrol","region":"sa-west-9","role_arn":"arn:aws:iam::400000000004:role/BiteCoAccess"}'),
  ('10.0.1.62', '/cloud-accounts/', 'VALIDATION_FAILED','company_id debe ser UUID valido; account_name debe tener entre 3 y 50 caracteres',
   '{"company_id":"not-a-uuid","account_id":"500000000005","account_name":"X","region":"us-east-1","role_arn":"arn:aws:iam::500000000005:role/BiteCoAccess"}'),
  ('10.0.1.50', '/cloud-accounts/', 'DUPLICATE',        'company_id+account_id ya existe',
   '{"company_id":"11111111-1111-1111-1111-111111111111","account_id":"100000000001","account_name":"TechCorp Production AWS","region":"us-east-1","role_arn":"arn:aws:iam::100000000001:role/BiteCoAccess"}'),
  ('10.0.1.51', '/cloud-accounts/', 'DUPLICATE',        'company_id+account_id ya existe',
   '{"company_id":"22222222-2222-2222-2222-222222222222","account_id":"200000000002","account_name":"Bancolombia Digital","region":"us-east-1","role_arn":"arn:aws:iam::200000000002:role/BiteCoAccess"}'),
  ('10.0.1.70', '/cloud-accounts/', 'INVALID_JSON',     'Body no es JSON valido', NULL),
  ('10.0.1.53', '/cloud-accounts/', 'SUCCESS',          NULL,
   '{"company_id":"44444444-4444-4444-4444-444444444444","account_id":"400000000004","account_name":"Ecopetrol Tech Ops","region":"us-east-2","role_arn":"arn:aws:iam::400000000004:role/BiteCoAccess"}');
SEEDEOF

sudo -u postgres psql -d bite -f /tmp/seed.sql

echo "=== [bite-db] Setup completo ===" > /tmp/db-ready
echo "DB_READY" > /tmp/db-ready
EOT
}

# =============================================================================
# EC2: bite-mongo — MongoDB 7.0 (Audit Event Store + Account Cache)
# Tácticas: Polyglot Persistence → Audit Event Store (ASR-SEG)
#           Cache-aside / Write-through (ASR-LAT: reduce latencia en dup check)
# =============================================================================

resource "aws_instance" "mongo" {
  ami                         = "ami-0c7217cdde317cfec"
  instance_type               = "t3.micro"
  key_name                    = "vockey"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.mongo.id]
  associate_public_ip_address = true

  tags = { Name = "bite-mongo" }

  user_data = <<EOT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
exec > /tmp/user-data-mongo.log 2>&1

echo "=== [bite-mongo] Instalando MongoDB 7.0 ==="
apt-get update -y
apt-get install -y gnupg curl

curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
  gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
  tee /etc/apt/sources.list.d/mongodb-org-7.0.list

apt-get update -y
apt-get install -y mongodb-org

systemctl enable mongod
systemctl start mongod
sleep 10

echo "=== Configurando MongoDB para escuchar en todas las interfaces ==="
sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
systemctl restart mongod
sleep 5

echo "=== Creando colecciones e indices ==="
cat > /tmp/mongo_setup.js << 'MONGOEOF'
db.createCollection('audit_events');
db.createCollection('account_cache');
db.audit_events.createIndex({timestamp: -1});
db.audit_events.createIndex({status: 1, timestamp: -1});
db.account_cache.createIndex({company_id: 1, account_id: 1}, {unique: true});
print('Colecciones e indices creados');
MONGOEOF

mongosh "mongodb://localhost:27017/bite_mongo" /tmp/mongo_setup.js

echo "=== Insertando datos semilla en MongoDB ==="
cat > /tmp/mongo_seed.js << 'MONGOSEED'
// account_cache: espejo de PostgreSQL + campos extra que el schema relacional no permite
db.account_cache.insertMany([
  { pg_id: 1,  company_id: "11111111-1111-1111-1111-111111111111", account_id: "100000000001",
    account_name: "TechCorp Production AWS",  region: "us-east-1", role_arn: "arn:aws:iam::100000000001:role/BiteCoAccess",
    contact_email: "cloudops@techcorp.com.co", company_nit: "900.123.456-7",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["production", "colombia", "fintech"],
    billing_account: "BA-TECH-001", monthly_budget_usd: 15000,
    cached_at: new Date("2026-05-01T08:00:00Z") },

  { pg_id: 2,  company_id: "22222222-2222-2222-2222-222222222222", account_id: "200000000002",
    account_name: "Bancolombia Digital",       region: "us-east-1", role_arn: "arn:aws:iam::200000000002:role/BiteCoAccess",
    contact_email: "aws-admin@bancolombia.com.co", company_nit: "890.903.938-8",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["banking", "regulated", "pci-dss"],
    billing_account: "BA-BANC-002", monthly_budget_usd: 85000,
    cached_at: new Date("2026-05-01T08:01:00Z") },

  { pg_id: 3,  company_id: "33333333-3333-3333-3333-333333333333", account_id: "300000000003",
    account_name: "Rappi Cloud Services",      region: "us-west-2", role_arn: "arn:aws:iam::300000000003:role/BiteCoAccess",
    contact_email: "infra@rappi.com", company_nit: "901.103.939-2",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["delivery", "latam", "high-availability"],
    billing_account: "BA-RAPP-003", monthly_budget_usd: 120000,
    cached_at: new Date("2026-05-01T08:02:00Z") },

  { pg_id: 4,  company_id: "44444444-4444-4444-4444-444444444444", account_id: "400000000004",
    account_name: "Ecopetrol Tech Ops",        region: "us-east-2", role_arn: "arn:aws:iam::400000000004:role/BiteCoAccess",
    contact_email: "cloud@ecopetrol.com.co", company_nit: "899.999.068-1",
    subscription_tier: "standard", mfa_enabled: true,
    tags: ["energy", "oil-gas", "government"],
    billing_account: "BA-ECOP-004", monthly_budget_usd: 45000,
    cached_at: new Date("2026-05-01T08:03:00Z") },

  { pg_id: 5,  company_id: "55555555-5555-5555-5555-555555555555", account_id: "500000000005",
    account_name: "Grupo Exito AWS",           region: "us-east-1", role_arn: "arn:aws:iam::500000000005:role/BiteCoAccess",
    contact_email: "cloud.infra@grupoexito.com", company_nit: "860.007.386-3",
    subscription_tier: "standard", mfa_enabled: false,
    tags: ["retail", "ecommerce", "colombia"],
    billing_account: "BA-EXIT-005", monthly_budget_usd: 22000,
    cached_at: new Date("2026-05-01T08:04:00Z") },

  { pg_id: 6,  company_id: "66666666-6666-6666-6666-666666666666", account_id: "600000000006",
    account_name: "Avianca Systems",           region: "us-east-1", role_arn: "arn:aws:iam::600000000006:role/BiteCoAccess",
    contact_email: "aws@avianca.com", company_nit: "830.000.071-0",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["aviation", "saas", "critical"],
    billing_account: "BA-AVIA-006", monthly_budget_usd: 67000,
    cached_at: new Date("2026-05-01T08:05:00Z") },

  { pg_id: 7,  company_id: "77777777-7777-7777-7777-777777777777", account_id: "700000000007",
    account_name: "Davivienda Cloud",          region: "sa-east-1", role_arn: "arn:aws:iam::700000000007:role/BiteCoAccess",
    contact_email: "cloud@davivienda.com", company_nit: "860.034.313-7",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["banking", "sfc-regulated", "latam"],
    billing_account: "BA-DAVI-007", monthly_budget_usd: 91000,
    cached_at: new Date("2026-05-01T08:06:00Z") },

  { pg_id: 8,  company_id: "88888888-8888-8888-8888-888888888888", account_id: "800000000008",
    account_name: "Corona Digital",            region: "us-west-2", role_arn: "arn:aws:iam::800000000008:role/BiteCoAccess",
    contact_email: "it.cloud@corona.com.co", company_nit: "860.006.661-0",
    subscription_tier: "basic", mfa_enabled: false,
    tags: ["manufacturing", "iot", "industry40"],
    billing_account: "BA-CORO-008", monthly_budget_usd: 8500,
    cached_at: new Date("2026-05-01T08:07:00Z") },

  { pg_id: 9,  company_id: "99999999-9999-9999-9999-999999999999", account_id: "900000000009",
    account_name: "Alpina Cloud Services",     region: "us-east-1", role_arn: "arn:aws:iam::900000000009:role/BiteCoAccess",
    contact_email: "devops@alpina.com.co", company_nit: "860.009.300-7",
    subscription_tier: "basic", mfa_enabled: false,
    tags: ["food", "logistics", "supply-chain"],
    billing_account: "BA-ALPI-009", monthly_budget_usd: 5200,
    cached_at: new Date("2026-05-01T08:08:00Z") },

  { pg_id: 10, company_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", account_id: "101000000010",
    account_name: "Claro Colombia AWS",        region: "us-east-2", role_arn: "arn:aws:iam::101000000010:role/BiteCoAccess",
    contact_email: "cloud.ops@claro.com.co", company_nit: "830.122.330-3",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["telecom", "isp", "critical-infra"],
    billing_account: "BA-CLAR-010", monthly_budget_usd: 200000,
    cached_at: new Date("2026-05-01T08:09:00Z") },

  { pg_id: 11, company_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", account_id: "110000000011",
    account_name: "Nutresa Tech Hub",          region: "us-west-1", role_arn: "arn:aws:iam::110000000011:role/BiteCoAccess",
    contact_email: "aws.admin@nutresa.com", company_nit: "890.903.071-0",
    subscription_tier: "standard", mfa_enabled: true,
    tags: ["food", "fmcg", "latam"],
    billing_account: "BA-NUTR-011", monthly_budget_usd: 18000,
    cached_at: new Date("2026-05-01T08:10:00Z") },

  { pg_id: 12, company_id: "cccccccc-cccc-cccc-cccc-cccccccccccc", account_id: "120000000012",
    account_name: "ISA Networks Cloud",        region: "sa-east-1", role_arn: "arn:aws:iam::120000000012:role/BiteCoAccess",
    contact_email: "cloud@isa.com.co", company_nit: "800.116.398-2",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["energy-transmission", "scada", "critical"],
    billing_account: "BA-ISA0-012", monthly_budget_usd: 55000,
    cached_at: new Date("2026-05-01T08:11:00Z") },

  { pg_id: 13, company_id: "dddddddd-dddd-dddd-dddd-dddddddddddd", account_id: "130000000013",
    account_name: "Celsia Digital Ops",        region: "us-east-1", role_arn: "arn:aws:iam::130000000013:role/BiteCoAccess",
    contact_email: "devops@celsia.com", company_nit: "805.000.936-9",
    subscription_tier: "standard", mfa_enabled: false,
    tags: ["utilities", "smart-grid", "iot"],
    billing_account: "BA-CELS-013", monthly_budget_usd: 13000,
    cached_at: new Date("2026-05-01T08:12:00Z") },

  { pg_id: 14, company_id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", account_id: "140000000014",
    account_name: "Cementos Argos Cloud",      region: "eu-west-1", role_arn: "arn:aws:iam::140000000014:role/BiteCoAccess",
    contact_email: "cloud@argos.com.co", company_nit: "890.920.140-3",
    subscription_tier: "standard", mfa_enabled: true,
    tags: ["construction", "materials", "global"],
    billing_account: "BA-ARGO-014", monthly_budget_usd: 31000,
    cached_at: new Date("2026-05-01T08:13:00Z") },

  { pg_id: 15, company_id: "ffffffff-ffff-ffff-ffff-ffffffffffff", account_id: "150000000015",
    account_name: "Suramericana AWS",          region: "us-east-1", role_arn: "arn:aws:iam::150000000015:role/BiteCoAccess",
    contact_email: "aws@suramericana.com.co", company_nit: "890.900.608-7",
    subscription_tier: "enterprise", mfa_enabled: true,
    tags: ["insurance", "fintech", "latam"],
    billing_account: "BA-SURA-015", monthly_budget_usd: 78000,
    cached_at: new Date("2026-05-01T08:14:00Z") }
]);

// audit_events: eventos de seguridad pre-cargados (schema-free — campos varían por tipo)
db.audit_events.insertMany([
  { timestamp: new Date("2026-05-01T08:00:10Z"), source_ip: "10.0.1.50", endpoint: "/cloud-accounts/",
    status: "SUCCESS", reason: null,
    payload: { company_id: "11111111-1111-1111-1111-111111111111", account_id: "100000000001", region: "us-east-1" },
    kong_consumer: "bite-admin", response_time_ms: 142 },

  { timestamp: new Date("2026-05-01T08:00:15Z"), source_ip: "10.0.1.51", endpoint: "/cloud-accounts/",
    status: "SUCCESS", reason: null,
    payload: { company_id: "22222222-2222-2222-2222-222222222222", account_id: "200000000002", region: "us-east-1" },
    kong_consumer: "bite-admin", response_time_ms: 118 },

  { timestamp: new Date("2026-05-01T08:00:22Z"), source_ip: "203.0.113.15", endpoint: "/cloud-accounts/",
    status: "VALIDATION_FAILED",
    reason: "account_id debe ser exactamente 12 digitos numericos",
    payload: { company_id: "33333333-3333-3333-3333-333333333333", account_id: "12345", region: "us-east-1" },
    kong_consumer: "bite-admin", response_time_ms: 8,
    security_flag: "bad_account_id" },

  { timestamp: new Date("2026-05-01T08:00:30Z"), source_ip: "198.51.100.42", endpoint: "/cloud-accounts/",
    status: "VALIDATION_FAILED",
    reason: "region invalida; company_id debe ser UUID valido",
    payload: { company_id: "not-a-uuid", account_id: "400000000004", region: "mars-central-1" },
    kong_consumer: "bite-admin", response_time_ms: 5,
    security_flag: "multiple_validation_errors" },

  { timestamp: new Date("2026-05-01T08:01:00Z"), source_ip: "10.0.1.50", endpoint: "/cloud-accounts/",
    status: "DUPLICATE",
    reason: "company_id+account_id ya existe (mongo cache hit)",
    payload: { company_id: "11111111-1111-1111-1111-111111111111", account_id: "100000000001" },
    kong_consumer: "bite-admin", response_time_ms: 3,
    cache_hit: true },

  { timestamp: new Date("2026-05-01T08:01:05Z"), source_ip: "10.0.1.51", endpoint: "/cloud-accounts/",
    status: "DUPLICATE",
    reason: "company_id+account_id ya existe (postgres)",
    payload: { company_id: "22222222-2222-2222-2222-222222222222", account_id: "200000000002" },
    kong_consumer: "bite-admin", response_time_ms: 67,
    cache_hit: false },

  { timestamp: new Date("2026-05-01T08:01:30Z"), source_ip: "10.0.1.70", endpoint: "/cloud-accounts/",
    status: "INVALID_JSON", reason: "Body no es JSON valido", payload: null,
    kong_consumer: "bite-admin", response_time_ms: 2 },

  { timestamp: new Date("2026-05-01T08:02:00Z"), source_ip: "10.0.1.52", endpoint: "/cloud-accounts/",
    status: "SUCCESS", reason: null,
    payload: { company_id: "33333333-3333-3333-3333-333333333333", account_id: "300000000003", region: "us-west-2" },
    kong_consumer: "bite-admin", response_time_ms: 155 },

  { timestamp: new Date("2026-05-01T08:02:30Z"), source_ip: "10.0.1.53", endpoint: "/cloud-accounts/",
    status: "SUCCESS", reason: null,
    payload: { company_id: "44444444-4444-4444-4444-444444444444", account_id: "400000000004", region: "us-east-2" },
    kong_consumer: "bite-admin", response_time_ms: 201 },

  { timestamp: new Date("2026-05-01T08:03:00Z"), source_ip: "10.0.1.54", endpoint: "/cloud-accounts/",
    status: "SUCCESS", reason: null,
    payload: { company_id: "55555555-5555-5555-5555-555555555555", account_id: "500000000005", region: "us-east-1" },
    kong_consumer: "bite-admin", response_time_ms: 133 }
]);

print("Seed data insertado: " + db.account_cache.countDocuments() + " cuentas, " + db.audit_events.countDocuments() + " eventos");
MONGOSEED

mongosh "mongodb://localhost:27017/bite_mongo" /tmp/mongo_seed.js

echo "=== [bite-mongo] Setup completo ===" > /tmp/mongo-ready
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
  depends_on                  = [aws_instance.db, aws_instance.mongo]

  tags = { Name = "bite-api" }

  user_data = <<EOT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
DB_IP="${aws_instance.db.private_ip}"
MONGO_IP="${aws_instance.mongo.private_ip}"
exec > /tmp/user-data-api.log 2>&1

echo "=== [bite-api] Iniciando setup ==="
apt-get update -y
apt-get install -y python3 python3-pip python3-dev postgresql-client netcat-openbsd

echo "=== Esperando a que PostgreSQL este lista ==="
until PGPASSWORD=bite_app_pass_123 psql -h $DB_IP -U bite_app -d bite -c "SELECT 1 FROM cloud_accounts LIMIT 0;" 2>/dev/null; do
  echo "PostgreSQL no lista aun, reintentando en 10s..."
  sleep 10
done
echo "PostgreSQL lista!"

echo "=== Esperando a que MongoDB este lista ==="
until nc -z $MONGO_IP 27017 2>/dev/null; do
  echo "MongoDB no lista aun, reintentando en 5s..."
  sleep 5
done
echo "MongoDB lista!"

echo "=== Instalando dependencias Python ==="
pip3 install flask==3.0.3 gunicorn==22.0.0 psycopg2-binary==2.9.9 pymongo==4.7.3 --quiet

mkdir -p /opt/bite

echo "=== Escribiendo aplicacion Flask ==="
cat > /opt/bite/app.py << 'PYEOF'
#!/usr/bin/env python3
from flask import Flask, request, jsonify
import psycopg2
import psycopg2.errorcodes
from pymongo import MongoClient
import re
import uuid
import json
import datetime

app = Flask(__name__)

# --- PostgreSQL (fuente de verdad ACID) ---
DB_HOST = "DB_IP_PLACEHOLDER"
DB_NAME = "bite"
DB_USER = "bite_app"
DB_PASS = "bite_app_pass_123"

# --- MongoDB (Audit Event Store + Account Cache) ---
MONGO_HOST = "MONGO_IP_PLACEHOLDER"

VALID_REGIONS = {
    "us-east-1", "us-east-2", "us-west-1",
    "us-west-2", "eu-west-1", "sa-east-1"
}
ARN_RE = re.compile(r'^arn:aws:iam::\d{12}:role/[A-Za-z0-9_+=,.@-]+$')

_db_conn = None
_mongo_client = None


def get_conn():
    global _db_conn
    try:
        if _db_conn is None or _db_conn.closed:
            raise Exception("cerrada")
        _db_conn.cursor().execute("SELECT 1")
    except Exception:
        _db_conn = psycopg2.connect(
            host=DB_HOST, dbname=DB_NAME, user=DB_USER, password=DB_PASS,
            connect_timeout=5, application_name="bite-api"
        )
    return _db_conn


def get_mongo():
    global _mongo_client
    try:
        if _mongo_client is None:
            raise Exception("no client")
        _mongo_client.admin.command('ping')
    except Exception:
        _mongo_client = MongoClient(
            "mongodb://" + MONGO_HOST + ":27017/",
            serverSelectionTimeoutMS=3000,
            connectTimeoutMS=3000
        )
    return _mongo_client["bite_mongo"]


def log_audit(status, reason, payload, ip, endpoint="/cloud-accounts/"):
    # PostgreSQL: audit log relacional (fuente de verdad de auditoria)
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
    except Exception:
        try:
            _db_conn.rollback()
        except Exception:
            pass

    # MongoDB: Audit Event Store — documentos JSON sin schema fijo (ASR-SEG)
    # Permite queries flexibles por IP, status, timestamp sin migrar esquema
    try:
        mdb = get_mongo()
        mdb.audit_events.insert_one({
            "timestamp": datetime.datetime.utcnow(),
            "source_ip": ip,
            "endpoint": endpoint,
            "status": status,
            "reason": reason,
            "payload": payload
        })
    except Exception:
        pass  # Fallo de MongoDB no interrumpe el flujo principal


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

    # Cache-aside: verificar duplicado en MongoDB antes de ir a PostgreSQL (ASR-LAT)
    # MongoDB hace lookup por indice compuesto sin overhead de SQL query planner
    try:
        mdb = get_mongo()
        if mdb.account_cache.find_one({
            "company_id": data["company_id"],
            "account_id": data["account_id"]
        }):
            log_audit('DUPLICATE', 'company_id+account_id ya existe (mongo cache hit)', data, ip)
            return jsonify({"error": "Account already registered"}), 409
    except Exception:
        pass  # Si MongoDB falla, continuar con PostgreSQL como fuente de verdad

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
            log_audit('DUPLICATE', 'company_id+account_id ya existe (postgres)', data, ip)
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

    # Write-through: poblar cache MongoDB tras INSERT exitoso en PostgreSQL (ASR-LAT)
    try:
        mdb = get_mongo()
        mdb.account_cache.insert_one({
            "pg_id": new_id,
            "company_id": data["company_id"],
            "account_id": data["account_id"],
            "account_name": data["account_name"],
            "region": data["region"],
            "role_arn": data["role_arn"],
            "cached_at": datetime.datetime.utcnow()
        })
    except Exception:
        pass  # Cache write no-fatal: PostgreSQL es la fuente de verdad

    log_audit('SUCCESS', None, data, ip)
    return jsonify({"id": new_id}), 201


@app.route('/health', methods=['GET'])
def health():
    return jsonify({"status": "ok"}), 200


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
PYEOF

sed -i "s/DB_IP_PLACEHOLDER/$DB_IP/" /opt/bite/app.py
sed -i "s/MONGO_IP_PLACEHOLDER/$MONGO_IP/" /opt/bite/app.py

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
