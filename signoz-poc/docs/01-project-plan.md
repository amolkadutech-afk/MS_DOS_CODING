# SigNoz POC - 15-Day Project Plan

## Executive Summary

This document outlines a 15-day implementation plan to deploy SigNoz on AWS and create a payment gateway monitoring dashboard for a .NET application processing 500,000 Stripe transactions.

---

## Phase 1: Infrastructure Setup (Days 1-4)

### Day 1: AWS Environment Preparation

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Review AWS account access and permissions | 2 hours | DevOps | Access verified |
| Plan VPC networking for SigNoz | 2 hours | DevOps | Network diagram |
| Size EC2 instance requirements | 2 hours | DevOps | Instance specs |
| Create security groups | 2 hours | DevOps | SG configurations |

**EC2 Instance Sizing for 500k Transactions:**
```
SigNoz All-in-One Instance:
- Instance Type: t3.xlarge (4 vCPU, 16 GB RAM) minimum
- Recommended: m5.2xlarge (8 vCPU, 32 GB RAM) for production
- Storage: 500 GB gp3 SSD (for ClickHouse data)
- Network: Enhanced networking enabled
```

**Security Groups:**
```
Inbound Rules:
- Port 3301 (SigNoz UI) - Your IP/VPN
- Port 4317 (OTLP gRPC) - Application subnet
- Port 4318 (OTLP HTTP) - Application subnet
- Port 8080 (Query Service) - Internal
- Port 9000 (ClickHouse HTTP) - Internal
```

### Day 2: SigNoz Installation on EC2

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Launch EC2 instance | 1 hour | DevOps | Running instance |
| Install Docker and Docker Compose | 1 hour | DevOps | Docker ready |
| Deploy SigNoz using Docker Compose | 2 hours | DevOps | SigNoz running |
| Configure persistent storage | 2 hours | DevOps | Data persistence |
| Verify SigNoz UI accessibility | 1 hour | DevOps | UI accessible |

**Installation Commands:**
```bash
# Install Docker
sudo yum update -y
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Clone and start SigNoz
git clone -b main https://github.com/SigNoz/signoz.git
cd signoz/deploy
docker-compose -f docker/clickhouse-setup/docker-compose.yaml up -d
```

### Day 3: SigNoz Configuration & Verification

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Configure data retention policies | 2 hours | DevOps | Retention set |
| Set up authentication | 2 hours | DevOps | Auth configured |
| Configure alerting channels | 2 hours | DevOps | Alerts ready |
| Performance baseline testing | 2 hours | DevOps | Baseline metrics |

**Data Retention Configuration:**
```yaml
# For 500k transactions, recommended retention:
traces: 15 days
metrics: 30 days
logs: 7 days
```

### Day 4: Network & Security Hardening

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Configure HTTPS/TLS | 2 hours | DevOps | SSL enabled |
| Set up reverse proxy (nginx) | 2 hours | DevOps | Proxy configured |
| Implement network segmentation | 2 hours | DevOps | Network secured |
| Document access procedures | 2 hours | DevOps | Documentation |

---

## Phase 2: Application Instrumentation (Days 5-9)

### Day 5: .NET OpenTelemetry SDK Setup

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Add OpenTelemetry NuGet packages | 2 hours | Developer | Packages added |
| Configure OTel in Program.cs | 3 hours | Developer | OTel initialized |
| Set up trace exporters | 2 hours | Developer | Traces exporting |
| Verify traces in SigNoz | 1 hour | Developer | Traces visible |

**Required NuGet Packages:**
```xml
<PackageReference Include="OpenTelemetry" Version="1.7.0" />
<PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.7.0" />
<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.7.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" Version="1.7.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.Http" Version="1.7.0" />
<PackageReference Include="OpenTelemetry.Instrumentation.SqlClient" Version="1.7.0-beta.1" />
```

**Program.cs Configuration:**
```csharp
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService("PaymentGateway"))
    .WithTracing(tracing => tracing
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddSqlClientInstrumentation()
        .AddOtlpExporter(opts => 
        {
            opts.Endpoint = new Uri("http://signoz-ec2:4317");
        }))
    .WithMetrics(metrics => metrics
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddOtlpExporter(opts =>
        {
            opts.Endpoint = new Uri("http://signoz-ec2:4317");
        }));
```

### Day 6: Custom Span Instrumentation for Payments

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Create custom ActivitySource | 2 hours | Developer | ActivitySource ready |
| Add spans for payment flow | 4 hours | Developer | Payment spans |
| Add semantic conventions | 2 hours | Developer | Standard attributes |

**Custom Payment Instrumentation:**
```csharp
public static class PaymentInstrumentation
{
    public static readonly ActivitySource ActivitySource = 
        new("PaymentGateway.Payments", "1.0.0");
}

// Usage in PaymentService
public async Task<PaymentResult> ProcessPayment(PaymentRequest request)
{
    using var activity = PaymentInstrumentation.ActivitySource
        .StartActivity("ProcessPayment", ActivityKind.Internal);
    
    activity?.SetTag("payment.amount", request.Amount);
    activity?.SetTag("payment.currency", request.Currency);
    activity?.SetTag("payment.method", "stripe");
    activity?.SetTag("customer.id", request.CustomerId);
    
    try
    {
        var result = await _stripeService.ChargeAsync(request);
        activity?.SetTag("payment.status", result.Status);
        activity?.SetTag("payment.transaction_id", result.TransactionId);
        return result;
    }
    catch (Exception ex)
    {
        activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
        activity?.RecordException(ex);
        throw;
    }
}
```

### Day 7: Stripe Integration Monitoring

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Instrument Stripe API calls | 3 hours | Developer | Stripe traces |
| Add Stripe webhook monitoring | 3 hours | Developer | Webhook traces |
| Configure Stripe-specific metrics | 2 hours | Developer | Stripe metrics |

**Stripe-Specific Attributes:**
```csharp
activity?.SetTag("stripe.payment_intent_id", paymentIntent.Id);
activity?.SetTag("stripe.charge_id", charge.Id);
activity?.SetTag("stripe.customer_id", customerId);
activity?.SetTag("stripe.payment_method_type", paymentMethod.Type);
activity?.SetTag("stripe.status", charge.Status);
activity?.SetTag("stripe.failure_code", charge.FailureCode);
activity?.SetTag("stripe.failure_message", charge.FailureMessage);
```

### Day 8: SQL Server Monitoring Setup

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Enable SQL Client instrumentation | 2 hours | Developer | SQL traces |
| Configure query sanitization | 2 hours | Developer | Safe queries |
| Set up slow query detection | 2 hours | Developer | Slow queries flagged |
| Add database metrics | 2 hours | Developer | DB metrics |

**SQL Client Configuration:**
```csharp
.AddSqlClientInstrumentation(options =>
{
    options.SetDbStatementForText = true;
    options.SetDbStatementForStoredProcedure = true;
    options.RecordException = true;
    options.EnableConnectionLevelAttributes = true;
    options.Filter = (command) =>
    {
        // Exclude health checks
        return !command.CommandText.Contains("SELECT 1");
    };
})
```

### Day 9: Metrics Implementation

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Define custom payment metrics | 3 hours | Developer | Metrics defined |
| Implement counters and histograms | 3 hours | Developer | Metrics collecting |
| Verify metrics in SigNoz | 2 hours | Developer | Metrics visible |

**Custom Metrics:**
```csharp
public static class PaymentMetrics
{
    private static readonly Meter Meter = new("PaymentGateway.Payments", "1.0.0");
    
    public static readonly Counter<long> PaymentsProcessed = 
        Meter.CreateCounter<long>("payments.processed", "count", 
            "Total payments processed");
    
    public static readonly Counter<long> PaymentsFailed = 
        Meter.CreateCounter<long>("payments.failed", "count", 
            "Total payments failed");
    
    public static readonly Histogram<double> PaymentDuration = 
        Meter.CreateHistogram<double>("payments.duration", "ms", 
            "Payment processing duration");
    
    public static readonly Histogram<double> PaymentAmount = 
        Meter.CreateHistogram<double>("payments.amount", "USD", 
            "Payment amounts");
}
```

---

## Phase 3: Dashboard Development (Days 10-13)

### Day 10: Dashboard Planning & Design

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Define KPIs and SLOs | 3 hours | Team | KPI document |
| Design dashboard layout | 3 hours | Team | Wireframe |
| Identify required queries | 2 hours | Developer | Query list |

**Key Performance Indicators (KPIs):**
1. Payment Success Rate (target: 99.5%)
2. Payment Processing Latency (p99 < 2s)
3. Stripe API Latency (p95 < 500ms)
4. Database Query Time (p95 < 100ms)
5. Transaction Volume (per minute/hour)
6. Revenue Processed (hourly/daily)
7. Error Rate by Type

### Day 11: Core Dashboard Widgets

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Create payment volume chart | 2 hours | Developer | Volume widget |
| Create success/failure rate panel | 2 hours | Developer | Rate widget |
| Create latency percentile charts | 2 hours | Developer | Latency widget |
| Create error breakdown panel | 2 hours | Developer | Error widget |

**Dashboard Panels:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    PAYMENT GATEWAY DASHBOARD                      │
├─────────────┬─────────────┬─────────────┬─────────────────────────┤
│ Transactions│ Success Rate│ Avg Latency │     Revenue (24h)       │
│   Today     │             │             │                         │
│   12,450    │   99.7%     │   245ms     │      $1,234,567         │
├─────────────┴─────────────┴─────────────┴─────────────────────────┤
│                                                                   │
│  [Transaction Volume Over Time - Line Chart]                      │
│                                                                   │
├─────────────────────────────────┬─────────────────────────────────┤
│                                 │                                 │
│  [Success vs Failed - Stacked]  │  [Latency Percentiles]         │
│                                 │  p50, p95, p99                  │
├─────────────────────────────────┼─────────────────────────────────┤
│                                 │                                 │
│  [Error Types - Pie Chart]      │  [Top Slow Transactions]       │
│                                 │                                 │
├─────────────────────────────────┴─────────────────────────────────┤
│                                                                   │
│  [Stripe API Performance - Heatmap]                               │
│                                                                   │
├─────────────────────────────────┬─────────────────────────────────┤
│                                 │                                 │
│  [Database Query Latency]       │  [Active Connections]          │
│                                 │                                 │
└─────────────────────────────────┴─────────────────────────────────┘
```

### Day 12: Advanced Dashboard Features

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Add drill-down capabilities | 3 hours | Developer | Drill-downs |
| Create trace correlation links | 2 hours | Developer | Trace links |
| Add time comparison | 2 hours | Developer | Comparisons |
| Configure variables/filters | 1 hour | Developer | Filters |

### Day 13: Alerting Configuration

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Define alert thresholds | 2 hours | Team | Thresholds |
| Configure Slack/Email alerts | 2 hours | DevOps | Alerts active |
| Create runbooks | 3 hours | Team | Runbooks |
| Test alert notifications | 1 hour | Team | Alerts verified |

**Alert Rules:**
```yaml
alerts:
  - name: Payment Success Rate Low
    condition: payment_success_rate < 99%
    duration: 5m
    severity: critical
    
  - name: Payment Latency High
    condition: payment_latency_p99 > 2000ms
    duration: 3m
    severity: warning
    
  - name: Stripe API Errors
    condition: stripe_error_rate > 1%
    duration: 5m
    severity: critical
    
  - name: Database Slow Queries
    condition: db_query_latency_p95 > 500ms
    duration: 5m
    severity: warning
```

---

## Phase 4: Testing & Documentation (Days 14-15)

### Day 14: Load Testing & Validation

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Prepare load test scenarios | 2 hours | QA | Test scripts |
| Execute load tests (500k scale) | 4 hours | QA | Test results |
| Validate dashboard accuracy | 2 hours | Team | Validation report |

**Load Test Scenarios:**
1. Steady state: 500 TPS for 30 minutes
2. Peak load: 1000 TPS for 10 minutes
3. Stress test: Ramp to 2000 TPS
4. Failure injection: Simulate Stripe errors

### Day 15: Documentation & Handover

| Task | Duration | Owner | Deliverable |
|------|----------|-------|-------------|
| Complete technical documentation | 3 hours | Developer | Tech docs |
| Create user guide | 2 hours | Developer | User guide |
| Conduct knowledge transfer | 2 hours | Team | Training |
| Final review and sign-off | 1 hour | Stakeholders | Approval |

---

## Resource Requirements

### Team Composition

| Role | Allocation | Responsibilities |
|------|------------|------------------|
| DevOps Engineer | 100% | Infrastructure, SigNoz deployment |
| .NET Developer | 100% | Application instrumentation |
| QA Engineer | 50% (Days 14-15) | Load testing |
| Technical Lead | 25% | Architecture, review |

### Infrastructure Costs (Estimated)

| Resource | Specification | Monthly Cost |
|----------|---------------|--------------|
| SigNoz EC2 | m5.2xlarge | ~$275 |
| EBS Storage | 500 GB gp3 | ~$45 |
| Data Transfer | 100 GB/month | ~$9 |
| **Total** | | **~$329/month** |

---

## Risk Register

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| SigNoz performance issues | High | Medium | Size instance appropriately, monitor resources |
| Network latency | Medium | Low | Deploy SigNoz in same VPC |
| Data volume exceeds storage | Medium | Medium | Configure retention, monitor disk |
| Stripe rate limiting | Low | Low | Implement caching, retries |

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| SigNoz uptime | 99.9% | CloudWatch |
| Trace sampling rate | 100% | SigNoz metrics |
| Dashboard load time | < 3s | Manual testing |
| Alert accuracy | 95% | Alert audit |
| Mean time to detection | < 5 min | Incident review |

---

## Appendix: Daily Standup Template

```
Date: ___________
Day: __ of 15

Yesterday:
- [ ] Completed tasks

Today:
- [ ] Planned tasks

Blockers:
- [ ] Any issues

Notes:
- Additional observations
```
