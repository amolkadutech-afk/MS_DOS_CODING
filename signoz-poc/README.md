# SigNoz POC - Payment Gateway Monitoring

## Overview

This Proof of Concept (POC) demonstrates the implementation of SigNoz for monitoring a .NET payment gateway application integrated with Stripe, running on AWS infrastructure.

## Project Context

| Attribute | Details |
|-----------|---------|
| **Application Type** | .NET Payment Gateway |
| **Payment Provider** | Stripe |
| **Database** | SQL Server |
| **Infrastructure** | AWS (EC2-based, no EKS/ECS) |
| **Transaction Volume** | 500,000 transactions |
| **Project Type** | Greenfield |
| **POC Timeline** | 15 days |

## Documentation Structure

```
signoz-poc/
├── README.md                           # This file
├── docs/
│   ├── 01-project-plan.md              # Detailed 15-day project plan
│   ├── 02-architecture.md              # System architecture design
│   ├── 03-aws-installation.md          # SigNoz installation on AWS EC2
│   ├── 04-dotnet-instrumentation.md    # .NET OpenTelemetry setup
│   ├── 05-stripe-monitoring.md         # Stripe payment monitoring
│   ├── 06-sql-server-monitoring.md     # SQL Server observability
│   └── 07-dashboard-design.md          # Dashboard specifications
```

## Quick Links

- [📋 Project Plan (15 Days)](docs/01-project-plan.md)
- [🏗️ Architecture Design](docs/02-architecture.md)
- [☁️ AWS Installation Guide](docs/03-aws-installation.md)
- [💻 .NET Instrumentation](docs/04-dotnet-instrumentation.md)
- [💳 Stripe Monitoring](docs/05-stripe-monitoring.md)
- [🗄️ SQL Server Monitoring](docs/06-sql-server-monitoring.md)
- [📊 Dashboard Design](docs/07-dashboard-design.md)

## Key Objectives

1. **Install SigNoz on AWS EC2** - Deploy SigNoz without container orchestration (EKS/ECS)
2. **Instrument .NET Application** - Configure OpenTelemetry for the payment gateway
3. **Monitor Stripe Transactions** - Track payment success/failure rates, latency
4. **SQL Server Observability** - Monitor database performance and queries
5. **Create Payment Dashboard** - Build a comprehensive dashboard for 500k transactions

## Success Criteria

- [ ] SigNoz running on AWS EC2 instance
- [ ] .NET application sending traces and metrics to SigNoz
- [ ] Stripe payment transactions visible in SigNoz
- [ ] SQL Server metrics and slow queries tracked
- [ ] One complete dashboard showing payment gateway health

## Getting Started

Start with the [Project Plan](docs/01-project-plan.md) to understand the 15-day implementation timeline.
