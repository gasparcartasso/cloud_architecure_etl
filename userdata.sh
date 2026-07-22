#!/bin/bash
set -e

yum update -y
yum install -y git jq

# Install Docker
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker

# Create docker group and add ec2-user
groupadd -f docker
usermod -aG docker ec2-user

# Fix Docker socket permissions
chgrp docker /var/run/docker.sock
chmod 660 /var/run/docker.sock

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
  DOCKER_ARCH="arm64"
  COMPOSE_ARCH="aarch64"
else
  DOCKER_ARCH="amd64"
  COMPOSE_ARCH="x86_64"
fi

mkdir -p /usr/libexec/docker/cli-plugins

# Install Buildx
BUILDX_URL=$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest \
  | jq -r --arg arch "linux-${DOCKER_ARCH}" \
    '.assets[] | select(.name | endswith($arch)) | .browser_download_url')

if [ -z "$BUILDX_URL" ]; then
  echo "ERROR: could not resolve buildx download URL for arch ${DOCKER_ARCH}" >&2
  exit 1
fi

curl -fSL "$BUILDX_URL" -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

file /usr/libexec/docker/cli-plugins/docker-buildx | grep -q ELF \
  || { echo "ERROR: docker-buildx is not a valid ELF binary" >&2; exit 1; }

# Install Docker Compose plugin
COMPOSE_URL=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
  | jq -r --arg arch "linux-${COMPOSE_ARCH}" \
    '.assets[] | select(.name | endswith($arch)) | .browser_download_url')

if [ -z "$COMPOSE_URL" ]; then
  echo "ERROR: could not resolve compose download URL for arch ${COMPOSE_ARCH}" >&2
  exit 1
fi

curl -fSL "$COMPOSE_URL" -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

file /usr/libexec/docker/cli-plugins/docker-compose | grep -q ELF \
  || { echo "ERROR: docker-compose is not a valid ELF binary" >&2; exit 1; }

# Clone your repo (idempotent)
rm -rf /opt/app
git clone https://github.com/gasparcartasso/cloud_architecure_etl.git /opt/app
cd /opt/app

# Start your stack as root
docker compose up -d --build