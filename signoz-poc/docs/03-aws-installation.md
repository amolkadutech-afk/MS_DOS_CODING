# SigNoz POC - AWS EC2 Installation Guide

## Prerequisites

Before starting the installation, ensure you have:

- [ ] AWS account with appropriate permissions
- [ ] VPC with public and private subnets configured
- [ ] SSH key pair for EC2 access
- [ ] Security groups created per architecture document

---

## Step 1: Launch EC2 Instance

### 1.1 Instance Configuration

**Console Steps:**
1. Navigate to EC2 Dashboard → Launch Instance
2. Configure as follows:

| Setting | Value |
|---------|-------|
| Name | signoz-server |
| AMI | Amazon Linux 2023 AMI |
| Instance Type | m5.2xlarge |
| Key Pair | Select existing or create new |
| Network | Your VPC |
| Subnet | Public subnet |
| Auto-assign Public IP | Enable |
| Security Group | sg-signoz (created earlier) |

### 1.2 Storage Configuration

| Volume | Size | Type | IOPS | Throughput |
|--------|------|------|------|------------|
| Root | 50 GB | gp3 | 3000 | 125 MB/s |
| Data | 500 GB | gp3 | 6000 | 250 MB/s |

**Add Second Volume:**
```
Device: /dev/sdb
Size: 500 GB
Volume Type: gp3
IOPS: 6000
Throughput: 250
Delete on Termination: No (preserve data)
Encrypted: Yes
```

### 1.3 Launch Instance

Click "Launch Instance" and wait for the instance to be running.

---

## Step 2: Initial Server Setup

### 2.1 Connect to Instance

```bash
# SSH into the instance
ssh -i your-key.pem ec2-user@<public-ip>

# Or use Session Manager
aws ssm start-session --target <instance-id>
```

### 2.2 System Updates

```bash
# Update system packages
sudo yum update -y

# Install required tools
sudo yum install -y git wget curl vim htop

# Set timezone
sudo timedatectl set-timezone America/New_York
```

### 2.3 Mount Data Volume

```bash
# Check available disks
lsblk

# Format the data volume (only first time)
sudo mkfs -t xfs /dev/nvme1n1

# Create mount point
sudo mkdir -p /data

# Mount the volume
sudo mount /dev/nvme1n1 /data

# Add to fstab for persistence
echo '/dev/nvme1n1 /data xfs defaults,nofail 0 2' | sudo tee -a /etc/fstab

# Verify mount
df -h /data
```

---

## Step 3: Install Docker

### 3.1 Install Docker Engine

```bash
# Install Docker
sudo yum install -y docker

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add ec2-user to docker group
sudo usermod -aG docker ec2-user

# Verify installation
docker --version
```

### 3.2 Install Docker Compose

```bash
# Download Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose

# Make executable
sudo chmod +x /usr/local/bin/docker-compose

# Verify installation
docker-compose --version
```

### 3.3 Configure Docker for Data Volume

```bash
# Stop Docker
sudo systemctl stop docker

# Move Docker data to /data
sudo mv /var/lib/docker /data/docker
sudo ln -s /data/docker /var/lib/docker

# Start Docker
sudo systemctl start docker

# Verify
docker info | grep "Docker Root Dir"
```

**Log out and back in for group changes to take effect:**
```bash
exit
ssh -i your-key.pem ec2-user@<public-ip>
```

---

## Step 4: Install SigNoz

### 4.1 Clone SigNoz Repository

```bash
# Create SigNoz directory
cd /data
git clone -b main https://github.com/SigNoz/signoz.git
cd signoz/deploy
```

### 4.2 Configure Environment Variables

```bash
# Create environment file
cat > .env << 'EOF'
# SigNoz Configuration

# ClickHouse settings
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_PORT=9000
CLICKHOUSE_USER=admin
CLICKHOUSE_PASSWORD=<strong-password>

# Query service
SIGNOZ_LOCAL_DB_PATH=/var/lib/signoz/signoz.db

# Frontend
FRONTEND_PORT=3301

# OTEL Collector
OTELCOL_GRPC_PORT=4317
OTELCOL_HTTP_PORT=4318

# Retention settings (in hours)
TRACES_TTL=360
METRICS_TTL=720
LOGS_TTL=168

# Alertmanager
ALERTMANAGER_URL=http://alertmanager:9093
EOF

# Secure the file
chmod 600 .env
```

### 4.3 Customize Docker Compose (Optional)

Create a production override file:

```bash
cat > docker-compose.override.yml << 'EOF'
version: "3.8"

services:
  clickhouse:
    volumes:
      - /data/clickhouse:/var/lib/clickhouse
    deploy:
      resources:
        limits:
          memory: 16G
        reservations:
          memory: 8G

  otel-collector:
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G

  query-service:
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G

  frontend:
    ports:
      - "3301:3301"
EOF
```

### 4.4 Start SigNoz

```bash
# Navigate to deploy directory
cd /data/signoz/deploy

# Start all services
docker-compose -f docker/clickhouse-setup/docker-compose.yaml up -d

# Check status
docker-compose -f docker/clickhouse-setup/docker-compose.yaml ps
```

**Expected Output:**
```
NAME                        STATUS              PORTS
signoz-alertmanager-1      Up 2 minutes        9093/tcp
signoz-clickhouse-1        Up 2 minutes        8123/tcp, 9000/tcp, 9181/tcp
signoz-frontend-1          Up 2 minutes        0.0.0.0:3301->3301/tcp
signoz-otel-collector-1    Up 2 minutes        4317/tcp, 4318/tcp
signoz-query-service-1     Up 2 minutes        8080/tcp
signoz-zookeeper-1         Up 2 minutes        2181/tcp, 2888/tcp, 3888/tcp
```

---

## Step 5: Verify Installation

### 5.1 Check Container Logs

```bash
# Check all container logs
docker-compose -f docker/clickhouse-setup/docker-compose.yaml logs --tail=50

# Check specific service
docker-compose -f docker/clickhouse-setup/docker-compose.yaml logs otel-collector
docker-compose -f docker/clickhouse-setup/docker-compose.yaml logs clickhouse
```

### 5.2 Test OTLP Endpoint

```bash
# Test gRPC endpoint
curl -v http://localhost:4317

# Test HTTP endpoint
curl -v http://localhost:4318/v1/traces
```

### 5.3 Access SigNoz UI

1. Open browser: `http://<public-ip>:3301`
2. Create admin account on first access
3. Verify dashboard loads correctly

---

## Step 6: Configure TLS/HTTPS (Recommended)

### 6.1 Install Nginx

```bash
sudo yum install -y nginx
sudo systemctl start nginx
sudo systemctl enable nginx
```

### 6.2 Install Certbot (Let's Encrypt)

```bash
# Install Certbot
sudo yum install -y certbot python3-certbot-nginx

# Obtain certificate (replace with your domain)
sudo certbot --nginx -d signoz.yourdomain.com
```

### 6.3 Configure Nginx Reverse Proxy

```bash
sudo cat > /etc/nginx/conf.d/signoz.conf << 'EOF'
server {
    listen 443 ssl http2;
    server_name signoz.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/signoz.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/signoz.yourdomain.com/privkey.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;

    # SigNoz UI
    location / {
        proxy_pass http://localhost:3301;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name signoz.yourdomain.com;
    return 301 https://$server_name$request_uri;
}
EOF

sudo nginx -t
sudo systemctl reload nginx
```

---

## Step 7: Configure Firewall (Optional)

If using iptables instead of security groups:

```bash
# Allow SigNoz UI
sudo iptables -A INPUT -p tcp --dport 3301 -j ACCEPT

# Allow OTLP gRPC
sudo iptables -A INPUT -p tcp --dport 4317 -j ACCEPT

# Allow OTLP HTTP
sudo iptables -A INPUT -p tcp --dport 4318 -j ACCEPT

# Save rules
sudo iptables-save | sudo tee /etc/sysconfig/iptables
```

---

## Step 8: Create Systemd Service (Auto-restart)

```bash
sudo cat > /etc/systemd/system/signoz.service << 'EOF'
[Unit]
Description=SigNoz Observability Platform
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/data/signoz/deploy
ExecStart=/usr/local/bin/docker-compose -f docker/clickhouse-setup/docker-compose.yaml up -d
ExecStop=/usr/local/bin/docker-compose -f docker/clickhouse-setup/docker-compose.yaml down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable signoz
```

---

## Step 9: Configure Data Retention

### 9.1 Access ClickHouse

```bash
docker exec -it signoz-clickhouse-1 clickhouse-client
```

### 9.2 Set Retention Policies

```sql
-- Set traces retention to 15 days
ALTER TABLE signoz_traces.signoz_index_v2 
MODIFY TTL toDateTime(timestamp) + INTERVAL 15 DAY;

-- Set metrics retention to 30 days
ALTER TABLE signoz_metrics.time_series_v2 
MODIFY TTL toDateTime(unix_milli/1000) + INTERVAL 30 DAY;

-- Set logs retention to 7 days
ALTER TABLE signoz_logs.logs 
MODIFY TTL toDateTime(timestamp/1000000000) + INTERVAL 7 DAY;

-- Exit
exit
```

---

## Step 10: Backup Configuration

### 10.1 Create Backup Script

```bash
cat > /data/backup-signoz.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/data/backups/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Backup SigNoz configuration
cp -r /data/signoz/deploy/.env $BACKUP_DIR/
cp -r /data/signoz/deploy/docker-compose.override.yml $BACKUP_DIR/

# Backup ClickHouse data (optional - large)
# docker exec signoz-clickhouse-1 clickhouse-backup create

# Upload to S3
# aws s3 sync $BACKUP_DIR s3://your-bucket/signoz-backups/

echo "Backup completed: $BACKUP_DIR"
EOF

chmod +x /data/backup-signoz.sh
```

### 10.2 Schedule Daily Backups

```bash
# Add to crontab
(crontab -l 2>/dev/null; echo "0 2 * * * /data/backup-signoz.sh") | crontab -
```

---

## Troubleshooting

### Common Issues

**1. ClickHouse not starting:**
```bash
# Check logs
docker logs signoz-clickhouse-1

# Common fix: increase file descriptors
echo 'fs.file-max = 262144' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

**2. OTLP endpoint not accepting data:**
```bash
# Check collector status
docker logs signoz-otel-collector-1

# Verify ports are listening
netstat -tlnp | grep -E "4317|4318"
```

**3. UI not loading:**
```bash
# Check frontend logs
docker logs signoz-frontend-1

# Restart frontend
docker-compose -f docker/clickhouse-setup/docker-compose.yaml restart frontend
```

**4. High memory usage:**
```bash
# Check resource usage
docker stats

# Adjust limits in docker-compose.override.yml
```

---

## Next Steps

After completing the installation:

1. ✅ Verify SigNoz UI is accessible
2. ✅ Test OTLP endpoints are receiving data
3. ➡️ Proceed to [.NET Instrumentation Guide](04-dotnet-instrumentation.md)
