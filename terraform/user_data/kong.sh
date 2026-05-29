#!/bin/bash
set -e

sleep 30

yum install -y git

mkdir -p /labs
cd /labs
git clone ${github_repo} sprint
cd sprint/kong

sed -i "s/ACCOUNTS_MS_IP/${accounts_ms_ip}/g" kong.yaml

docker network create kong-net || true
docker run -d --name kong \
  --network=kong-net \
  --restart always \
  -v /labs/sprint/kong:/kong/declarative \
  -e "KONG_DATABASE=off" \
  -e "KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yaml" \
  -e "KONG_PROXY_ACCESS_LOG=/dev/stdout" \
  -e "KONG_ADMIN_ACCESS_LOG=/dev/stdout" \
  -e "KONG_PROXY_ERROR_LOG=/dev/stderr" \
  -e "KONG_ADMIN_ERROR_LOG=/dev/stderr" \
  -e "KONG_ADMIN_LISTEN=0.0.0.0:8001" \
  -p 8000:8000 \
  -p 8001:8001 \
  kong:3.6
