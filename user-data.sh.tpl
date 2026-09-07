#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/arena-set-stack-user-data.log) 2>&1

dnf update -y
dnf install -y docker
systemctl enable --now docker

# Compose v2 as a CLI plugin when available; otherwise standalone binary.
if ! dnf install -y docker-compose-plugin; then
  curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

mkdir -p /opt/arena-set-stack
cd /opt/arena-set-stack

echo "${compose_yaml_b64}" | base64 -d > docker-compose.yml

cat > .env <<EOF
DB_PASSWORD="${db_password}"
APP_CRYPTO_SECRET="${app_crypto_secret}"
APP_MAIL_USERNAME="${app_mail_username}"
APP_MAIL_PASSWORD="${app_mail_password}"
APP_HOST="${public_url}"
CRACKER_IMAGE="${cracker_image}"
SHARER_IMAGE="${sharer_image}"
EOF
chmod 600 .env

compose pull
compose up -d
