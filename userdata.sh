#!/bin/bash
set -e
yum update -y
yum install -y git
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
git clone https://github.com/gasparcartasso/cloud_architecure_etl.git /opt/app
cd /opt/app
docker compose up -d
