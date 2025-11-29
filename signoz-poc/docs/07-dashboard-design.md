# SigNoz POC - Dashboard Design

## Overview

This document provides specifications for the main Payment Gateway dashboard in SigNoz, designed to monitor 500k transactions and provide actionable insights.

---

## Dashboard Philosophy

### Design Principles

1. **Glanceable** - Key metrics visible immediately
2. **Actionable** - Every panel should lead to action
3. **Contextual** - Related metrics grouped together
4. **Drillable** - From overview to details in clicks

### Color Coding

| Color | Symbol | Meaning | Text Label |
|-------|--------|---------|------------|
| 🟢 Green | ✓ | Healthy / Success | OK |
| 🟡 Yellow | ⚠ | Warning / Needs attention | WARN |
| 🔴 Red | ✗ | Critical / Failure | CRIT |
| 🔵 Blue | ℹ | Informational | INFO |

**Accessibility Note:** All dashboard panels should include text labels alongside color indicators to ensure accessibility for users with color vision deficiencies.

---

## Main Payment Gateway Dashboard

### Layout Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     PAYMENT GATEWAY OPERATIONS                               │
│                     Last updated: 2 seconds ago                              │
├───────────────┬───────────────┬───────────────┬───────────────┬─────────────┤
│   📊 Today    │  ✅ Success   │  ⏱️ P99       │  💰 Revenue   │ 🔴 Errors   │
│   12,450 txn  │    99.7%      │    245ms      │  $1,234,567   │    0.3%     │
├───────────────┴───────────────┴───────────────┴───────────────┴─────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │           Transaction Volume (Last 24 Hours)                          │ │
│  │  [Area Chart - Successful (green) / Failed (red) stacked]             │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
├─────────────────────────────────────┬───────────────────────────────────────┤
│                                     │                                       │
│  ┌─────────────────────────────┐   │   ┌─────────────────────────────────┐ │
│  │   Latency Percentiles       │   │   │   Payment Success Rate          │ │
│  │   [Line Chart]              │   │   │   [Gauge with SLO threshold]    │ │
│  │   - p50: 45ms               │   │   │                                 │ │
│  │   - p95: 180ms              │   │   │        ┌─────┐                  │ │
│  │   - p99: 245ms              │   │   │   99.7%│     │ SLO: 99.5%      │ │
│  └─────────────────────────────┘   │   └────────┴─────┴─────────────────┘ │
│                                     │                                       │
├─────────────────────────────────────┼───────────────────────────────────────┤
│                                     │                                       │
│  ┌─────────────────────────────┐   │   ┌─────────────────────────────────┐ │
│  │   Stripe API Performance    │   │   │   Error Breakdown               │ │
│  │   [Heatmap by operation]    │   │   │   [Pie Chart]                   │ │
│  │                             │   │   │   - card_declined: 45%          │ │
│  │   create_intent   ██░░░░    │   │   │   - insufficient_funds: 30%     │ │
│  │   confirm         ███░░░    │   │   │   - expired_card: 15%           │ │
│  │   capture         █░░░░░    │   │   │   - other: 10%                  │ │
│  └─────────────────────────────┘   │   └─────────────────────────────────┘ │
│                                     │                                       │
├─────────────────────────────────────┴───────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                    Database Performance                                │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │ │
│  │  │ Query p95   │  │ Connections │  │ Slow Queries│  │ Error Rate  │   │ │
│  │  │   45ms      │  │   25/100    │  │     3       │  │    0.1%     │   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘   │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │   Recent Errors                                              [Expand] │ │
│  │  ┌──────────┬────────────────────────┬────────────┬─────────────────┐ │ │
│  │  │ Time     │ Error                  │ Count      │ Trace           │ │ │
│  │  ├──────────┼────────────────────────┼────────────┼─────────────────┤ │ │
│  │  │ 10:45:23 │ card_declined          │ 12         │ [View Trace]    │ │ │
│  │  │ 10:44:15 │ insufficient_funds     │ 8          │ [View Trace]    │ │ │
│  │  │ 10:43:02 │ network_error          │ 2          │ [View Trace]    │ │ │
│  │  └──────────┴────────────────────────┴────────────┴─────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Panel Specifications

### Row 1: Key Metrics (Stat Panels)

#### Panel 1.1: Today's Transactions

**Type:** Stat Panel
**Query:**
```sql
SELECT count(*) as value
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= today()
```

**Display:**
- Format: Number (with comma separators)
- Color: Blue (informational)
- Sparkline: Last 6 hours trend

---

#### Panel 1.2: Success Rate

**Type:** Stat Panel with Gauge
**Query:**
```sql
SELECT 
    countIf(stringTagMap['payment.status'] = 'succeeded') * 100.0 / count() as value
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 1 HOUR
```

**Display:**
- Format: Percentage (1 decimal)
- Thresholds:
  - 🟢 >= 99.5%
  - 🟡 >= 98.0%
  - 🔴 < 98.0%
- Show: SLO line at 99.5%

---

#### Panel 1.3: P99 Latency

**Type:** Stat Panel
**Query:**
```sql
SELECT quantile(0.99)(durationNano / 1000000) as value
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 1 HOUR
```

**Display:**
- Format: Duration (ms)
- Thresholds:
  - 🟢 <= 300ms
  - 🟡 <= 500ms
  - 🔴 > 500ms
- Sparkline: Last 6 hours

---

#### Panel 1.4: Revenue Processed

**Type:** Stat Panel
**Query (Metrics):**
```promql
sum(increase(payments_revenue_total[24h]))
```

**Display:**
- Format: Currency ($)
- Color: Green
- Sparkline: Last 24 hours

---

#### Panel 1.5: Error Rate

**Type:** Stat Panel
**Query:**
```sql
SELECT 
    countIf(statusCode = 2) * 100.0 / count() as value
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 1 HOUR
```

**Display:**
- Format: Percentage (2 decimals)
- Thresholds:
  - 🟢 <= 0.5%
  - 🟡 <= 1.0%
  - 🔴 > 1.0%

---

### Row 2: Transaction Volume Chart

**Type:** Area Chart (Stacked)
**Query:**
```sql
SELECT 
    toStartOfFiveMinute(timestamp) as time,
    countIf(stringTagMap['payment.status'] = 'succeeded') as succeeded,
    countIf(stringTagMap['payment.status'] != 'succeeded') as failed
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 24 HOUR
GROUP BY time
ORDER BY time
```

**Display:**
- X-axis: Time (5-minute intervals)
- Y-axis: Transaction count
- Series:
  - Succeeded: Green (#52c41a)
  - Failed: Red (#ff4d4f)
- Fill: Stacked

---

### Row 3: Latency & Success Rate

#### Panel 3.1: Latency Percentiles

**Type:** Time Series (Line Chart)
**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    quantile(0.50)(durationNano / 1000000) as p50,
    quantile(0.95)(durationNano / 1000000) as p95,
    quantile(0.99)(durationNano / 1000000) as p99
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time
ORDER BY time
```

**Display:**
- Lines:
  - p50: Blue (solid)
  - p95: Yellow (dashed)
  - p99: Red (dashed)
- Y-axis: Duration (ms)
- Threshold line at 500ms

---

#### Panel 3.2: Success Rate Gauge

**Type:** Gauge
**Query:**
```sql
SELECT 
    countIf(stringTagMap['payment.status'] = 'succeeded') * 100.0 / count() as value
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 1 HOUR
```

**Display:**
- Min: 90%
- Max: 100%
- SLO Marker: 99.5%
- Thresholds:
  - 🟢 >= 99.5%
  - 🟡 >= 98.0%
  - 🔴 < 98.0%

---

### Row 4: Stripe & Errors

#### Panel 4.1: Stripe API Heatmap

**Type:** Heatmap
**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    stringTagMap['stripe.operation'] as operation,
    quantile(0.95)(durationNano / 1000000) as latency_p95
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['stripe.operation'] != ''
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time, operation
ORDER BY time
```

**Display:**
- X-axis: Time
- Y-axis: Operation type
- Color: Latency (green to red)

---

#### Panel 4.2: Error Breakdown

**Type:** Pie Chart
**Query:**
```sql
SELECT 
    stringTagMap['error.code'] as error_code,
    count() as count
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND statusCode = 2
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY error_code
ORDER BY count DESC
LIMIT 10
```

**Display:**
- Show percentages
- Legend: Right side
- Colors: Gradient (darkest = most frequent)

---

### Row 5: Database Performance

**Type:** Row of Stat Panels
**Queries:**

1. **Query P95:**
```sql
SELECT quantile(0.95)(durationNano / 1000000)
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND timestamp >= now() - INTERVAL 1 HOUR
```

2. **Active Connections:**
```promql
db_pool_active_connections{service="PaymentGateway"}
```

3. **Slow Queries:**
```promql
increase(db_queries_slow_total{service="PaymentGateway"}[1h])
```

4. **DB Error Rate:**
```promql
rate(db_queries_failed_total[5m]) / rate(db_queries_executed_total[5m]) * 100
```

---

### Row 6: Recent Errors Table

**Type:** Table Panel
**Query:**
```sql
SELECT 
    formatDateTime(timestamp, '%H:%M:%S') as time,
    stringTagMap['error.code'] as error_code,
    stringTagMap['error.message'] as message,
    traceId,
    count() as count
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND statusCode = 2
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time, error_code, message, traceId
ORDER BY timestamp DESC
LIMIT 20
```

**Display:**
- Columns:
  - Time
  - Error Code
  - Message (truncated)
  - Count
  - Trace Link (clickable)

---

## Dashboard Variables

### Variable: Time Range

```yaml
name: time_range
type: interval
options:
  - 15m
  - 1h
  - 6h
  - 24h
  - 7d
default: 1h
```

### Variable: Environment

```yaml
name: environment
type: query
query: |
  SELECT DISTINCT stringTagMap['deployment.environment']
  FROM signoz_traces.signoz_index_v2
  WHERE serviceName = 'PaymentGateway'
default: production
```

### Variable: Currency

```yaml
name: currency
type: query
query: |
  SELECT DISTINCT stringTagMap['payment.currency']
  FROM signoz_traces.signoz_index_v2
  WHERE serviceName = 'PaymentGateway'
multi: true
default: all
```

---

## Dashboard JSON Export

The complete dashboard can be exported and imported via SigNoz's JSON format:

```json
{
  "dashboard": {
    "title": "Payment Gateway Operations",
    "description": "Real-time monitoring of payment processing",
    "tags": ["payments", "production", "stripe"],
    "timezone": "browser",
    "refresh": "10s",
    "variables": [...],
    "panels": [...]
  }
}
```

---

## Additional Dashboards

### 1. Stripe Deep Dive Dashboard

Focus on:
- API call breakdown by endpoint
- Webhook processing
- Payment method distribution
- Decline code analysis

### 2. Database Performance Dashboard

Focus on:
- Query performance by type
- Connection pool metrics
- Slow query analysis
- Transaction patterns

### 3. Business Intelligence Dashboard

Focus on:
- Revenue trends
- Customer transaction patterns
- Geographic distribution
- Peak hours analysis

---

## SLO Configuration

### SLO: Payment Success Rate

```yaml
name: Payment Success Rate
objective: 99.5%
window: 30d
indicator:
  type: ratio
  good: payments.succeeded
  total: payments.total
alert_thresholds:
  - burn_rate: 14.4  # 1h window
    window: 1h
    severity: critical
  - burn_rate: 6     # 6h window
    window: 6h
    severity: warning
```

### SLO: Payment Latency

```yaml
name: Payment Latency P99
objective: 99%
threshold: 500ms
window: 30d
indicator:
  type: latency
  percentile: 99
alert_thresholds:
  - burn_rate: 14.4
    window: 1h
    severity: critical
```

---

## Dashboard Access & Permissions

| Role | View | Edit | Admin |
|------|------|------|-------|
| Developers | ✅ | ❌ | ❌ |
| DevOps | ✅ | ✅ | ❌ |
| SRE | ✅ | ✅ | ✅ |
| Management | ✅ | ❌ | ❌ |

---

## Maintenance

### Regular Tasks

- [ ] Weekly: Review alert thresholds
- [ ] Monthly: Update SLO targets if needed
- [ ] Quarterly: Audit dashboard usage
- [ ] Annually: Review and refresh design

### Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Day 15 | Initial dashboard |
| 1.1 | TBD | Add geographic panel |
| 1.2 | TBD | Business metrics |
