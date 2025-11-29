# SigNoz POC - System Architecture

## Overview

This document describes the architecture for deploying SigNoz on AWS EC2 to monitor a .NET payment gateway application with Stripe integration and SQL Server database.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS ACCOUNT                                     │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                           VPC (10.0.0.0/16)                            │  │
│  │                                                                        │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                    Public Subnet (10.0.1.0/24)                   │  │  │
│  │  │                                                                  │  │  │
│  │  │    ┌─────────────────┐         ┌─────────────────────────┐      │  │  │
│  │  │    │   Application   │         │      SigNoz Server      │      │  │  │
│  │  │    │   Load Balancer │         │     (m5.2xlarge EC2)    │      │  │  │
│  │  │    │      (ALB)      │         │                         │      │  │  │
│  │  │    └────────┬────────┘         │  ┌─────────────────┐    │      │  │  │
│  │  │             │                  │  │   SigNoz UI     │    │      │  │  │
│  │  │             │                  │  │   Port 3301     │    │      │  │  │
│  │  │             │                  │  └─────────────────┘    │      │  │  │
│  │  │             │                  │  ┌─────────────────┐    │      │  │  │
│  │  │             │                  │  │ OTEL Collector  │    │      │  │  │
│  │  │             │                  │  │ Port 4317/4318  │    │      │  │  │
│  │  │             │                  │  └─────────────────┘    │      │  │  │
│  │  │             │                  │  ┌─────────────────┐    │      │  │  │
│  │  │             │                  │  │   ClickHouse    │    │      │  │  │
│  │  │             │                  │  │   Port 9000     │    │      │  │  │
│  │  │             │                  │  └─────────────────┘    │      │  │  │
│  │  │             │                  └─────────────────────────┘      │  │  │
│  │  └─────────────┼────────────────────────────────────────────────────┘  │  │
│  │                │                              ▲                        │  │
│  │                │                              │ OTLP (gRPC/HTTP)       │  │
│  │                │                              │                        │  │
│  │  ┌─────────────┼──────────────────────────────┼────────────────────┐  │  │
│  │  │             │  Private Subnet (10.0.2.0/24)│                    │  │  │
│  │  │             ▼                              │                    │  │  │
│  │  │    ┌─────────────────────────────────────────────────────┐     │  │  │
│  │  │    │              .NET Payment Gateway                    │     │  │  │
│  │  │    │                   (EC2 Fleet)                        │     │  │  │
│  │  │    │                                                      │     │  │  │
│  │  │    │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │     │  │  │
│  │  │    │  │ Payment API  │  │ Stripe SDK   │  │   OTel     │ │     │  │  │
│  │  │    │  │   Service    │  │   Client     │  │   Agent    │ │     │  │  │
│  │  │    │  └──────────────┘  └──────┬───────┘  └────────────┘ │     │  │  │
│  │  │    └───────────────────────────┼──────────────────────────┘     │  │  │
│  │  │                                │                                │  │  │
│  │  │                                │ HTTPS                          │  │  │
│  │  │                                ▼                                │  │  │
│  │  │    ┌─────────────────────────────────────────────────────┐     │  │  │
│  │  │    │                 SQL Server (RDS)                     │     │  │  │
│  │  │    │                  Private Subnet                      │     │  │  │
│  │  │    └─────────────────────────────────────────────────────┘     │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      │ HTTPS                                 │
│                                      ▼                                       │
│                           ┌─────────────────────┐                           │
│                           │    Stripe API       │                           │
│                           │  (api.stripe.com)   │                           │
│                           └─────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Details

### 1. SigNoz Server (EC2)

**Instance Specification:**
| Attribute | Value |
|-----------|-------|
| Instance Type | m5.2xlarge |
| vCPU | 8 |
| Memory | 32 GB |
| Storage | 500 GB gp3 SSD |
| OS | Amazon Linux 2 |

**Docker Containers:**
```yaml
services:
  signoz-frontend:          # SigNoz UI
  signoz-query-service:     # Query API
  signoz-alertmanager:      # Alert management
  otel-collector:           # OpenTelemetry Collector
  otel-collector-migrator:  # Schema migrations
  clickhouse:               # Time-series database
  zookeeper:                # ClickHouse coordination
```

**Ports:**
| Port | Service | Protocol | Access |
|------|---------|----------|--------|
| 3301 | SigNoz UI | HTTPS | VPN/Bastion |
| 4317 | OTLP gRPC | gRPC | Private Subnet |
| 4318 | OTLP HTTP | HTTP | Private Subnet |
| 8080 | Query Service | HTTP | Internal |
| 9000 | ClickHouse HTTP | HTTP | Internal |
| 9181 | Zookeeper | TCP | Internal |

### 2. .NET Payment Gateway

**Application Stack:**
```
┌─────────────────────────────────────────┐
│           ASP.NET Core Web API          │
├─────────────────────────────────────────┤
│  Controllers                            │
│  ├── PaymentController                  │
│  ├── WebhookController                  │
│  └── HealthController                   │
├─────────────────────────────────────────┤
│  Services                               │
│  ├── PaymentService                     │
│  ├── StripeService                      │
│  └── TransactionService                 │
├─────────────────────────────────────────┤
│  OpenTelemetry Instrumentation          │
│  ├── ASP.NET Core Auto-instrumentation │
│  ├── HTTP Client Auto-instrumentation   │
│  ├── SQL Client Auto-instrumentation    │
│  └── Custom Payment Spans               │
├─────────────────────────────────────────┤
│  Data Access                            │
│  ├── Entity Framework Core              │
│  └── SQL Server Connection              │
└─────────────────────────────────────────┘
```

**OpenTelemetry Data Flow:**
```
.NET App → OTel SDK → OTLP Exporter → OTel Collector → ClickHouse
                                           │
                                           ▼
                                      Query Service
                                           │
                                           ▼
                                       SigNoz UI
```

### 3. SQL Server Database

**Schema (Simplified):**
```sql
-- Core tables for payment processing
Transactions (
    TransactionId UNIQUEIDENTIFIER PRIMARY KEY,
    CustomerId UNIQUEIDENTIFIER,
    Amount DECIMAL(18,2),
    Currency VARCHAR(3),
    Status VARCHAR(20),
    StripePaymentIntentId VARCHAR(100),
    StripeChargeId VARCHAR(100),
    CreatedAt DATETIME2,
    CompletedAt DATETIME2
)

Customers (
    CustomerId UNIQUEIDENTIFIER PRIMARY KEY,
    Email VARCHAR(255),
    StripeCustomerId VARCHAR(100),
    CreatedAt DATETIME2
)

PaymentMethods (
    PaymentMethodId UNIQUEIDENTIFIER PRIMARY KEY,
    CustomerId UNIQUEIDENTIFIER,
    StripePaymentMethodId VARCHAR(100),
    Type VARCHAR(20),
    Last4 VARCHAR(4),
    IsDefault BIT
)

AuditLogs (
    LogId BIGINT IDENTITY PRIMARY KEY,
    TransactionId UNIQUEIDENTIFIER,
    Action VARCHAR(50),
    Details NVARCHAR(MAX),
    CreatedAt DATETIME2
)
```

---

## Data Flow Diagrams

### Payment Processing Flow

```
┌──────────┐     ┌──────────────┐     ┌─────────────┐     ┌─────────────┐
│  Client  │────▶│   ALB/API    │────▶│  Payment    │────▶│   Stripe    │
│  (User)  │     │   Gateway    │     │  Service    │     │    API      │
└──────────┘     └──────────────┘     └──────┬──────┘     └─────────────┘
                                             │
                                             ▼
                                      ┌─────────────┐
                                      │  SQL Server │
                                      │  (persist)  │
                                      └─────────────┘
```

**Trace Propagation:**
```
[Parent Span: HTTP Request]
    └── [Child Span: PaymentService.ProcessPayment]
            ├── [Child Span: StripeService.CreatePaymentIntent]
            │       └── [Child Span: HTTP POST api.stripe.com]
            ├── [Child Span: SQL INSERT Transaction]
            └── [Child Span: StripeService.ConfirmPayment]
                    └── [Child Span: HTTP POST api.stripe.com]
```

### Telemetry Collection Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    .NET Application                              │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │    Traces    │  │   Metrics    │  │       Logs           │   │
│  │   (Spans)    │  │  (Counters)  │  │   (Structured)       │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘   │
│         │                 │                      │               │
│         └─────────────────┼──────────────────────┘               │
│                           ▼                                      │
│                 ┌─────────────────┐                             │
│                 │  OTLP Exporter  │                             │
│                 └────────┬────────┘                             │
└──────────────────────────┼──────────────────────────────────────┘
                           │
                           ▼ OTLP gRPC (Port 4317)
                 ┌─────────────────┐
                 │ OTel Collector  │
                 │   (SigNoz)      │
                 └────────┬────────┘
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
     ┌──────────┐  ┌──────────┐  ┌──────────┐
     │  Traces  │  │ Metrics  │  │   Logs   │
     │  Table   │  │  Table   │  │  Table   │
     └──────────┘  └──────────┘  └──────────┘
            │             │             │
            └─────────────┼─────────────┘
                          ▼
                 ┌─────────────────┐
                 │   ClickHouse    │
                 │   (Storage)     │
                 └────────┬────────┘
                          │
                          ▼
                 ┌─────────────────┐
                 │  Query Service  │
                 └────────┬────────┘
                          │
                          ▼
                 ┌─────────────────┐
                 │   SigNoz UI     │
                 │  (Dashboard)    │
                 └─────────────────┘
```

---

## Network Architecture

### VPC Configuration

```yaml
VPC:
  CIDR: 10.0.0.0/16
  
Subnets:
  Public:
    - 10.0.1.0/24 (AZ-a) - ALB, NAT Gateway, SigNoz
    - 10.0.3.0/24 (AZ-b) - ALB (Multi-AZ)
    
  Private:
    - 10.0.2.0/24 (AZ-a) - Application EC2
    - 10.0.4.0/24 (AZ-b) - Application EC2 (Multi-AZ)
    
  Database:
    - 10.0.10.0/24 (AZ-a) - RDS Primary
    - 10.0.11.0/24 (AZ-b) - RDS Standby
```

### Security Groups

```yaml
# SigNoz Server Security Group
sg-signoz:
  inbound:
    - port: 3301
      source: VPN-IP/32
      description: SigNoz UI access
    - port: 4317
      source: sg-application
      description: OTLP gRPC from apps
    - port: 4318
      source: sg-application
      description: OTLP HTTP from apps
    - port: 22
      source: bastion-sg
      description: SSH access
  outbound:
    - port: 443
      destination: 0.0.0.0/0
      description: HTTPS outbound

# Application Security Group
sg-application:
  inbound:
    - port: 80/443
      source: sg-alb
      description: HTTP from ALB
    - port: 22
      source: bastion-sg
      description: SSH access
  outbound:
    - port: 4317
      destination: sg-signoz
      description: OTLP to SigNoz
    - port: 1433
      destination: sg-database
      description: SQL Server
    - port: 443
      destination: 0.0.0.0/0
      description: Stripe API

# Database Security Group
sg-database:
  inbound:
    - port: 1433
      source: sg-application
      description: SQL from apps
```

---

## Scalability Considerations

### Current Capacity (500k Transactions)

| Component | Capacity | Notes |
|-----------|----------|-------|
| SigNoz (m5.2xlarge) | ~1M spans/day | Comfortable headroom |
| ClickHouse Storage | 500 GB | ~30 days retention |
| .NET App (t3.large x2) | ~1000 TPS | Peak capacity |

### Future Scaling Options

1. **Vertical Scaling**: Upgrade to m5.4xlarge for 2M+ spans/day
2. **Storage Expansion**: Add EBS volumes as needed
3. **Horizontal Scaling**: Separate ClickHouse cluster for >5M spans/day

---

## Disaster Recovery

### Backup Strategy

| Component | Method | Frequency | Retention |
|-----------|--------|-----------|-----------|
| SigNoz Config | S3 snapshot | Daily | 30 days |
| ClickHouse Data | EBS snapshots | Daily | 7 days |
| SQL Server | RDS automated | Continuous | 7 days |

### Recovery Time Objectives

| Scenario | RTO | RPO |
|----------|-----|-----|
| SigNoz failure | 1 hour | 24 hours |
| Application failure | 15 minutes | 0 |
| Database failure | 30 minutes | 5 minutes |

---

## Security Architecture

### Authentication & Authorization

```
┌─────────────────────────────────────────────┐
│              Access Control                  │
├─────────────────────────────────────────────┤
│                                             │
│  SigNoz UI ──▶ SSO/LDAP (future)           │
│             ──▶ Local users (POC)           │
│                                             │
│  API Access ──▶ API Keys                    │
│                                             │
│  OTLP Ingest ──▶ Network-level (SG)        │
│                                             │
└─────────────────────────────────────────────┘
```

### Data Security

- **In Transit**: TLS 1.3 for all communications
- **At Rest**: EBS encryption with AWS KMS
- **PII Handling**: Stripe tokens only (no card data)

---

## Monitoring the Monitor

### SigNoz Health Metrics

```yaml
cloudwatch_alarms:
  - name: SigNoz-CPU-High
    metric: CPUUtilization
    threshold: 80%
    period: 5 minutes
    
  - name: SigNoz-Disk-Low
    metric: DiskSpaceUtilization
    threshold: 85%
    period: 15 minutes
    
  - name: SigNoz-Memory-High
    metric: MemoryUtilization
    threshold: 85%
    period: 5 minutes

  - name: OTel-Collector-Down
    metric: HTTPCode_Target_5XX_Count
    threshold: 10
    period: 1 minute
```
