#!/bin/bash
set -e

sleep 30

mkdir -p /labs
cd /labs
git clone ${github_repo} sprint
cd sprint/cloud-accounts-ms

docker build -t accounts-ms .

docker run -d \
  --name accounts-ms \
  --restart always \
  -p 8080:8080 \
  -e DB_HOST=${db_host} \
  -e DB_PORT=5432 \
  -e DB_NAME=cloud_accounts \
  -e DB_USER=bite_admin \
  -e DB_PASS=bite_secure_pass \
  accounts-ms
