#!/bin/bash

set -e
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== Starting OpenCTI Installation ==="

# Update system
apt-get update
apt-get upgrade -y

# Install Docker
echo "Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu

# Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Wait for and mount data volume
echo "Setting up data volume..."
while [ ! -e /dev/nvme1n1 ]; do sleep 5; done

if ! blkid /dev/nvme1n1; then
  mkfs -t ext4 /dev/nvme1n1
fi

mkdir -p /opt/opencti
mount /dev/nvme1n1 /opt/opencti
echo "UUID=$(blkid -s UUID -o value /dev/nvme1n1) /opt/opencti ext4 defaults,nofail 0 2" >> /etc/fstab

# Create directories
mkdir -p /opt/opencti/{redis,elasticsearch,s3,postgresql}
chown -R ubuntu:ubuntu /opt/opencti

# Create docker-compose.yml
cat > /opt/opencti/docker-compose.yml <<EOF
version: '3'

services:
  redis:
    image: redis:7.2-alpine
    restart: always
    volumes:
      - ./redis:/data
    networks:
      - opencti
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.1
    volumes:
      - ./elasticsearch:/usr/share/elasticsearch/data
    environment:
      - discovery.type=single-node
      - xpack.ml.enabled=false
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms512M -Xmx512M"
    restart: always
    networks:
      - opencti
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost:9200 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 10

  minio:
    image: minio/minio:latest
    volumes:
      - ./s3:/data
    environment:
      MINIO_ROOT_USER: opencti
      MINIO_ROOT_PASSWORD: ${MINIO_PASSWORD}
    command: server /data
    restart: always
    networks:
      - opencti
    healthcheck:
      test: ["CMD", "mc", "alias", "set", "local", "http://localhost:9000", "opencti", "UOI003GsdvReeniCXKERRII5kprxxqPbFyfQBMDdFEI="]
      interval: 10s
      timeout: 5s
      retries: 5

  postgresql:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: opencti
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: opencti
    volumes:
      - ./postgresql:/var/lib/postgresql/data
    restart: always
    networks:
      - opencti
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U opencti"]
      interval: 10s
      timeout: 5s
      retries: 5

  rabbitmq:
    image: rabbitmq:3-management
    environment:
      RABBITMQ_DEFAULT_USER: rabbit
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
    ports:
      - "5672:5672"
      - "15672:15672"
    volumes:
      - ./rabbitmq:/var/lib/rabbitmq
    restart: always
    networks:
      - opencti
    healthcheck:
      test: ["CMD-SHELL", "rabbitmqctl status"]
      interval: 10s
      timeout: 5s
      retries: 10

  opencti:
    image: opencti/platform:6.4.3
    environment:
      NODE_OPTIONS: "--max-old-space-size=2048"
      APP__PORT: 8080
      APP__BASE_URL: http://localhost:8080
      APP__ADMIN__EMAIL: ${ADMIN_EMAIL}
      APP__ADMIN__PASSWORD: ${OPENCTI_PASSWORD}
      APP__ADMIN__TOKEN: ${OPENCTI_TOKEN}
      APP__APP_LOGS__LOGS_LEVEL: error
      RABBITMQ__HOSTNAME: rabbitmq
      RABBITMQ__PORT: 5672
      RABBITMQ__USERNAME: rabbit
      RABBITMQ__PASSWORD: ${RABBITMQ_PASSWORD}
      REDIS__HOSTNAME: redis
      REDIS__PORT: 6379
      ELASTICSEARCH__URL: http://elasticsearch:9200
      MINIO__ENDPOINT: minio
      MINIO__PORT: 9000
      MINIO__USE_SSL: false
      MINIO__ACCESS_KEY: opencti
      MINIO__SECRET_KEY: ${MINIO_PASSWORD}
      DATABASE__HOST: postgresql
      DATABASE__PORT: 5432
      DATABASE__NAME: opencti
      DATABASE__USERNAME: opencti
      DATABASE__PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "8080:8080"
    depends_on:
      redis:
        condition: service_healthy
      elasticsearch:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      minio:
        condition: service_healthy
      postgresql:
        condition: service_healthy
    restart: always
    networks:
      - opencti

  worker:
    image: opencti/worker:6.4.3
    environment:
      OPENCTI_URL: http://opencti:8080
      OPENCTI_TOKEN: ${OPENCTI_TOKEN}
      RABBITMQ__HOSTNAME: rabbitmq
      RABBITMQ__PORT: 5672
      RABBITMQ__USERNAME: rabbit
      RABBITMQ__PASSWORD: ${RABBITMQ_PASSWORD}
      WORKER_LOG_LEVEL: error
    depends_on:
      opencti:
        condition: service_started
    deploy:
      replicas: 2
    restart: always
    networks:
      - opencti

networks:
  opencti:
    driver: bridge
EOF

chown ubuntu:ubuntu /opt/opencti/docker-compose.yml

# Set Elasticsearch parameters
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# Start OpenCTI
echo "Starting OpenCTI..."
cd /opt/opencti
sudo -u ubuntu docker-compose up -d

# Set up Nginx reverse proxy
echo "Setting up Nginx reverse proxy"
cat > /etc/nginx/sites-available/opencti <<EOF
server {
    listen 80;
    server_name ${OPENCTI_DOMAIN};

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/opencti /etc/nginx/sites-enabled/opencti
nginx -t
systemctl restart nginx

certbot --nginx -d ${OPENCTI_DOMAIN} --non-interactive --agree-tos -m ass@ethicalhack.ing

# Create systemd service
cat > /etc/systemd/system/opencti.service <<EOF
[Unit]
Description=OpenCTI Platform
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/opencti
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
User=ubuntu

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable opencti.service

echo "=== OpenCTI Installation Complete ==="
echo "Wait 10-15 minutes for all services to start"
