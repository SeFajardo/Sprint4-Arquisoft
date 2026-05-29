provider "aws" {
  region = var.aws_region
}

# --- Networking: default VPC ---
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- Security Groups ---
resource "aws_security_group" "kong_sg" {
  name        = "${var.resource_prefix}-kong-sg"
  description = "Allow HTTP and SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "accounts_ms_sg" {
  name        = "${var.resource_prefix}-accounts-ms-sg"
  description = "Allow from Kong + SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.kong_sg.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "accounts_db_sg" {
  name        = "${var.resource_prefix}-accounts-db-sg"
  description = "Allow PostgreSQL from accounts-ms"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.accounts_ms_sg.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- AMIs ---
data "aws_ami" "amazon_linux_ecs" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-ecs-hvm-*-x86_64"]
  }
}

data "aws_ami" "ubuntu_24" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# --- DB instance (Ubuntu + PostgreSQL nativo) ---
resource "aws_instance" "accounts_db" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = "t3.micro"
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.accounts_db_sg.id]
  user_data              = file("${path.module}/user_data/accounts_db.sh")

  tags = {
    Name = "${var.resource_prefix}-accounts-db"
  }
}

# --- Accounts MS instance (Amazon Linux + Docker) ---
resource "aws_instance" "accounts_ms" {
  ami                    = data.aws_ami.amazon_linux_ecs.id
  instance_type          = "t3.micro"
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.accounts_ms_sg.id]

  user_data = templatefile("${path.module}/user_data/accounts_ms.sh", {
    db_host     = aws_instance.accounts_db.private_ip
    github_repo = var.github_repo_url
  })

  depends_on = [aws_instance.accounts_db]

  tags = {
    Name = "${var.resource_prefix}-accounts-ms"
  }
}

# --- Kong instance ---
resource "aws_instance" "kong" {
  ami                    = data.aws_ami.amazon_linux_ecs.id
  instance_type          = "t3.micro"
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.kong_sg.id]

  user_data = templatefile("${path.module}/user_data/kong.sh", {
    accounts_ms_ip = aws_instance.accounts_ms.private_ip
    github_repo    = var.github_repo_url
  })

  depends_on = [aws_instance.accounts_ms]

  tags = {
    Name = "${var.resource_prefix}-kong"
  }
}
