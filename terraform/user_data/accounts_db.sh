#!/bin/bash
set -e
apt-get update
apt-get install -y postgresql postgresql-contrib

PG_VERSION=$(ls /etc/postgresql/)
echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/$PG_VERSION/main/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf

systemctl restart postgresql

sudo -u postgres psql <<EOF
CREATE USER bite_admin WITH PASSWORD 'bite_secure_pass';
CREATE DATABASE cloud_accounts OWNER bite_admin;
GRANT ALL PRIVILEGES ON DATABASE cloud_accounts TO bite_admin;
EOF
