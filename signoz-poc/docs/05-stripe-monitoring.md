# SigNoz POC - Stripe Payment Monitoring

## Overview

This guide covers monitoring Stripe payment operations in SigNoz, including API calls, webhooks, and payment-specific dashboards.

---

## Stripe Integration Points

### Payment Flow to Monitor

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Client    │────▶│  Payment API    │────▶│  Stripe API     │
│   Request   │     │  (Your App)     │     │  (External)     │
└─────────────┘     └────────┬────────┘     └─────────────────┘
                             │
                             ▼
                    ┌─────────────────┐     ┌─────────────────┐
                    │   SQL Server    │     │    Webhook      │
                    │   (Database)    │◀────│    Handler      │
                    └─────────────────┘     └─────────────────┘
                                                    ▲
                                                    │
                                            ┌───────┴───────┐
                                            │ Stripe Events │
                                            └───────────────┘
```

### Key Operations to Track

| Operation | Type | Importance |
|-----------|------|------------|
| Create PaymentIntent | API Call | Critical |
| Confirm Payment | API Call | Critical |
| Capture Payment | API Call | High |
| Refund | API Call | High |
| Webhook: payment_intent.succeeded | Event | Critical |
| Webhook: payment_intent.failed | Event | Critical |
| Webhook: charge.dispute.created | Event | High |

---

## Step 1: Stripe SDK Instrumentation

### 1.1 Custom HTTP Client Handler

Create `Telemetry/StripeHttpHandler.cs`:

```csharp
using System.Diagnostics;
using PaymentGateway.Telemetry;

namespace PaymentGateway.Infrastructure;

public class StripeHttpHandler : DelegatingHandler
{
    public StripeHttpHandler() : base(new HttpClientHandler())
    {
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, 
        CancellationToken cancellationToken)
    {
        using var activity = StripeInstrumentation.ActivitySource
            .StartActivity("StripeApiCall", ActivityKind.Client);

        var stopwatch = Stopwatch.StartNew();

        // Extract operation from URL
        var operation = ExtractOperation(request.RequestUri);
        
        activity?.SetTag("stripe.operation", operation);
        activity?.SetTag("http.method", request.Method.ToString());
        activity?.SetTag("http.url", SanitizeUrl(request.RequestUri));

        try
        {
            var response = await base.SendAsync(request, cancellationToken);
            
            stopwatch.Stop();

            activity?.SetTag("http.status_code", (int)response.StatusCode);
            
            // Record metrics
            StripeInstrumentation.StripeApiCalls.Add(1,
                new KeyValuePair<string, object?>("operation", operation),
                new KeyValuePair<string, object?>("status_code", (int)response.StatusCode));

            StripeInstrumentation.StripeApiLatency.Record(stopwatch.ElapsedMilliseconds,
                new KeyValuePair<string, object?>("operation", operation));

            if (!response.IsSuccessStatusCode)
            {
                activity?.SetStatus(ActivityStatusCode.Error, $"HTTP {response.StatusCode}");
                
                StripeInstrumentation.StripeApiErrors.Add(1,
                    new KeyValuePair<string, object?>("operation", operation),
                    new KeyValuePair<string, object?>("status_code", (int)response.StatusCode));
            }

            return response;
        }
        catch (Exception ex)
        {
            stopwatch.Stop();
            
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);

            StripeInstrumentation.StripeApiErrors.Add(1,
                new KeyValuePair<string, object?>("operation", operation),
                new KeyValuePair<string, object?>("error_type", "network_error"));

            throw;
        }
    }

    private static string ExtractOperation(Uri? uri)
    {
        if (uri == null) return "unknown";

        var path = uri.AbsolutePath;
        
        // Map paths to operations
        return path switch
        {
            var p when p.Contains("/payment_intents") && p.Contains("/confirm") => "confirm_payment_intent",
            var p when p.Contains("/payment_intents") => "payment_intent",
            var p when p.Contains("/charges") && p.Contains("/refund") => "refund",
            var p when p.Contains("/charges") => "charge",
            var p when p.Contains("/customers") => "customer",
            var p when p.Contains("/payment_methods") => "payment_method",
            _ => "other"
        };
    }

    private static string SanitizeUrl(Uri? uri)
    {
        if (uri == null) return "unknown";
        
        // Remove sensitive parts from URL
        var sanitized = uri.GetLeftPart(UriPartial.Path);
        
        // Mask IDs in path
        return System.Text.RegularExpressions.Regex.Replace(
            sanitized, 
            @"(pi_|ch_|cus_|pm_)[a-zA-Z0-9]+", 
            "$1***");
    }
}
```

### 1.2 Configure Stripe Client

In `Program.cs` or service registration:

```csharp
// Configure Stripe with custom HTTP client
StripeConfiguration.ApiKey = builder.Configuration["Stripe:SecretKey"];

// Register custom HTTP handler for Stripe
builder.Services.AddHttpClient("Stripe")
    .AddHttpMessageHandler<StripeHttpHandler>();

// Or configure Stripe to use custom handler
var httpClient = new HttpClient(new StripeHttpHandler());
StripeConfiguration.StripeClient = new StripeClient(
    apiKey: builder.Configuration["Stripe:SecretKey"],
    httpClient: new SystemNetHttpClient(httpClient));
```

---

## Step 2: Webhook Monitoring

### 2.1 Webhook Controller

Create `Controllers/WebhookController.cs`:

```csharp
using System.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Stripe;
using PaymentGateway.Telemetry;

namespace PaymentGateway.Controllers;

[ApiController]
[Route("api/[controller]")]
public class WebhookController : ControllerBase
{
    private readonly ILogger<WebhookController> _logger;
    private readonly IConfiguration _configuration;
    private readonly IPaymentService _paymentService;

    public WebhookController(
        ILogger<WebhookController> logger,
        IConfiguration configuration,
        IPaymentService paymentService)
    {
        _logger = logger;
        _configuration = configuration;
        _paymentService = paymentService;
    }

    [HttpPost]
    public async Task<IActionResult> HandleStripeWebhook()
    {
        using var activity = StripeInstrumentation.ActivitySource
            .StartActivity("StripeWebhook", ActivityKind.Consumer);

        var json = await new StreamReader(HttpContext.Request.Body).ReadToEndAsync();
        var stopwatch = Stopwatch.StartNew();

        try
        {
            // Record webhook received
            StripeInstrumentation.WebhooksReceived.Add(1);

            // Verify webhook signature
            var stripeEvent = EventUtility.ConstructEvent(
                json,
                Request.Headers["Stripe-Signature"],
                _configuration["Stripe:WebhookSecret"]);

            activity?.SetTag("stripe.event_id", stripeEvent.Id);
            activity?.SetTag("stripe.event_type", stripeEvent.Type);
            activity?.SetTag("stripe.api_version", stripeEvent.ApiVersion);

            _logger.LogInformation(
                "Received Stripe webhook: {EventType} ({EventId})",
                stripeEvent.Type, stripeEvent.Id);

            // Process based on event type
            await ProcessEventAsync(stripeEvent, activity);

            stopwatch.Stop();

            // Record success
            StripeInstrumentation.WebhooksProcessed.Add(1,
                new KeyValuePair<string, object?>("event_type", stripeEvent.Type),
                new KeyValuePair<string, object?>("status", "success"));

            activity?.SetTag("webhook.processing_time_ms", stopwatch.ElapsedMilliseconds);

            return Ok();
        }
        catch (StripeException ex)
        {
            stopwatch.Stop();

            activity?.SetStatus(ActivityStatusCode.Error, "Invalid signature");
            activity?.RecordException(ex);

            _logger.LogError(ex, "Invalid Stripe webhook signature");

            StripeInstrumentation.WebhooksProcessed.Add(1,
                new KeyValuePair<string, object?>("event_type", "unknown"),
                new KeyValuePair<string, object?>("status", "invalid_signature"));

            return BadRequest("Invalid signature");
        }
        catch (Exception ex)
        {
            stopwatch.Stop();

            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);

            _logger.LogError(ex, "Error processing Stripe webhook");

            StripeInstrumentation.WebhooksProcessed.Add(1,
                new KeyValuePair<string, object?>("event_type", "unknown"),
                new KeyValuePair<string, object?>("status", "error"));

            return StatusCode(500);
        }
    }

    private async Task ProcessEventAsync(Event stripeEvent, Activity? activity)
    {
        switch (stripeEvent.Type)
        {
            case Events.PaymentIntentSucceeded:
                await HandlePaymentIntentSucceeded(stripeEvent, activity);
                break;

            case Events.PaymentIntentPaymentFailed:
                await HandlePaymentIntentFailed(stripeEvent, activity);
                break;

            case Events.ChargeRefunded:
                await HandleChargeRefunded(stripeEvent, activity);
                break;

            case Events.ChargeDisputeCreated:
                await HandleDisputeCreated(stripeEvent, activity);
                break;

            default:
                _logger.LogInformation("Unhandled event type: {EventType}", stripeEvent.Type);
                break;
        }
    }

    private async Task HandlePaymentIntentSucceeded(Event stripeEvent, Activity? activity)
    {
        var paymentIntent = stripeEvent.Data.Object as PaymentIntent;
        
        activity?.AddEvent(new ActivityEvent("payment_intent.succeeded", 
            tags: new ActivityTagsCollection
            {
                { "payment_intent_id", paymentIntent?.Id },
                { "amount", paymentIntent?.Amount },
                { "currency", paymentIntent?.Currency }
            }));

        _logger.LogInformation(
            "Payment succeeded: {PaymentIntentId}, Amount: {Amount} {Currency}",
            paymentIntent?.Id, paymentIntent?.Amount, paymentIntent?.Currency);

        // Update transaction status in database
        await _paymentService.UpdateTransactionStatusAsync(
            paymentIntent?.Id, 
            "succeeded");
    }

    private async Task HandlePaymentIntentFailed(Event stripeEvent, Activity? activity)
    {
        var paymentIntent = stripeEvent.Data.Object as PaymentIntent;
        
        activity?.AddEvent(new ActivityEvent("payment_intent.failed",
            tags: new ActivityTagsCollection
            {
                { "payment_intent_id", paymentIntent?.Id },
                { "error_code", paymentIntent?.LastPaymentError?.Code },
                { "error_message", paymentIntent?.LastPaymentError?.Message }
            }));

        activity?.SetStatus(ActivityStatusCode.Error, paymentIntent?.LastPaymentError?.Message);

        _logger.LogWarning(
            "Payment failed: {PaymentIntentId}, Error: {ErrorCode} - {ErrorMessage}",
            paymentIntent?.Id, 
            paymentIntent?.LastPaymentError?.Code,
            paymentIntent?.LastPaymentError?.Message);

        await _paymentService.UpdateTransactionStatusAsync(
            paymentIntent?.Id,
            "failed",
            paymentIntent?.LastPaymentError?.Message);
    }

    private async Task HandleChargeRefunded(Event stripeEvent, Activity? activity)
    {
        var charge = stripeEvent.Data.Object as Charge;
        
        activity?.AddEvent(new ActivityEvent("charge.refunded",
            tags: new ActivityTagsCollection
            {
                { "charge_id", charge?.Id },
                { "amount_refunded", charge?.AmountRefunded }
            }));

        _logger.LogInformation(
            "Charge refunded: {ChargeId}, Amount: {Amount}",
            charge?.Id, charge?.AmountRefunded);
    }

    private async Task HandleDisputeCreated(Event stripeEvent, Activity? activity)
    {
        var dispute = stripeEvent.Data.Object as Dispute;
        
        activity?.AddEvent(new ActivityEvent("dispute.created",
            tags: new ActivityTagsCollection
            {
                { "dispute_id", dispute?.Id },
                { "amount", dispute?.Amount },
                { "reason", dispute?.Reason }
            }));

        // Disputes are critical - add alert-worthy tag
        activity?.SetTag("alert.severity", "critical");
        activity?.SetTag("dispute.id", dispute?.Id);
        activity?.SetTag("dispute.reason", dispute?.Reason);

        _logger.LogCritical(
            "DISPUTE CREATED: {DisputeId}, Reason: {Reason}, Amount: {Amount}",
            dispute?.Id, dispute?.Reason, dispute?.Amount);
    }
}
```

---

## Step 3: Payment-Specific Metrics

### 3.1 Extended Stripe Metrics

Add to `Telemetry/StripeInstrumentation.cs`:

```csharp
// Payment-specific counters
public static readonly Counter<long> PaymentIntentsCreated = 
    Meter.CreateCounter<long>(
        "stripe.payment_intents.created.total",
        unit: "count",
        description: "Payment intents created");

public static readonly Counter<long> PaymentIntentsConfirmed = 
    Meter.CreateCounter<long>(
        "stripe.payment_intents.confirmed.total",
        unit: "count",
        description: "Payment intents confirmed");

public static readonly Counter<long> RefundsProcessed = 
    Meter.CreateCounter<long>(
        "stripe.refunds.processed.total",
        unit: "count",
        description: "Refunds processed");

public static readonly Counter<decimal> RefundAmount = 
    Meter.CreateCounter<decimal>(
        "stripe.refunds.amount.total",
        unit: "USD",
        description: "Total refund amount");

public static readonly Counter<long> DisputesCreated = 
    Meter.CreateCounter<long>(
        "stripe.disputes.created.total",
        unit: "count",
        description: "Disputes created");

// Webhook-specific
public static readonly Counter<long> WebhooksByType = 
    Meter.CreateCounter<long>(
        "stripe.webhooks.by_type.total",
        unit: "count",
        description: "Webhooks by event type");

public static readonly Histogram<double> WebhookProcessingTime = 
    Meter.CreateHistogram<double>(
        "stripe.webhooks.processing_time",
        unit: "ms",
        description: "Webhook processing time");

// Error tracking
public static readonly Counter<long> DeclinedPayments = 
    Meter.CreateCounter<long>(
        "stripe.payments.declined.total",
        unit: "count",
        description: "Declined payments by reason");

// Card brand tracking
public static readonly Counter<long> PaymentsByCardBrand = 
    Meter.CreateCounter<long>(
        "stripe.payments.by_card_brand.total",
        unit: "count",
        description: "Payments by card brand");
```

### 3.2 Usage in Code

```csharp
// After successful payment
StripeInstrumentation.PaymentsByCardBrand.Add(1,
    new KeyValuePair<string, object?>("card_brand", paymentMethod.Card.Brand),
    new KeyValuePair<string, object?>("card_funding", paymentMethod.Card.Funding));

// On decline
StripeInstrumentation.DeclinedPayments.Add(1,
    new KeyValuePair<string, object?>("decline_code", charge.FailureCode),
    new KeyValuePair<string, object?>("card_brand", paymentMethod.Card.Brand));

// On dispute
StripeInstrumentation.DisputesCreated.Add(1,
    new KeyValuePair<string, object?>("reason", dispute.Reason),
    new KeyValuePair<string, object?>("network", dispute.PaymentMethodDetails.Card.Network));
```

---

## Step 4: Stripe Dashboard in SigNoz

### 4.1 Key Panels to Create

#### Panel 1: Payment Success Rate

**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    countIf(stringTagMap['payment.status'] = 'succeeded') * 100.0 / count() as success_rate
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'ProcessPayment'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time
ORDER BY time
```

#### Panel 2: Stripe API Latency

**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    stringTagMap['stripe.operation'] as operation,
    quantile(0.50)(durationNano / 1000000) as p50_ms,
    quantile(0.95)(durationNano / 1000000) as p95_ms,
    quantile(0.99)(durationNano / 1000000) as p99_ms
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name LIKE 'Stripe%'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time, operation
ORDER BY time
```

#### Panel 3: Payment Volume by Currency

**Query (Metrics):**
```
sum(rate(payments_processed_total[5m])) by (currency)
```

#### Panel 4: Error Breakdown

**Query:**
```sql
SELECT 
    stringTagMap['error.code'] as error_code,
    stringTagMap['error.type'] as error_type,
    count() as count
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND statusCode = 2  -- Error status
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY error_code, error_type
ORDER BY count DESC
LIMIT 10
```

#### Panel 5: Webhook Processing

**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    stringTagMap['stripe.event_type'] as event_type,
    count() as count,
    avg(durationNano / 1000000) as avg_processing_ms
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND name = 'StripeWebhook'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time, event_type
ORDER BY time
```

### 4.2 Dashboard Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                    STRIPE PAYMENT DASHBOARD                      │
├───────────────┬───────────────┬───────────────┬─────────────────┤
│ Total Txns    │ Success Rate  │ Avg Latency   │  Revenue (24h)  │
│    12,450     │    99.7%      │    245ms      │   $1,234,567    │
├───────────────┴───────────────┴───────────────┴─────────────────┤
│                                                                 │
│  [Payment Volume Over Time - Stacked by Currency]               │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  [Stripe API Latency - p50, p95, p99 by Operation]             │
│                                                                 │
├─────────────────────────────┬───────────────────────────────────┤
│                             │                                   │
│  [Success vs Failed]        │  [Decline Reasons - Pie Chart]   │
│                             │                                   │
├─────────────────────────────┼───────────────────────────────────┤
│                             │                                   │
│  [Webhooks by Type]         │  [Webhook Processing Time]       │
│                             │                                   │
├─────────────────────────────┴───────────────────────────────────┤
│                                                                 │
│  [Payment Methods - Card Brand Distribution]                    │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  [Recent Errors - Table with Error Code, Count, Last Seen]      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step 5: Alerts for Stripe Operations

### 5.1 Critical Alerts

```yaml
# Alert: Low Payment Success Rate
- name: StripePaymentSuccessRateLow
  condition: payment_success_rate < 98
  for: 5m
  severity: critical
  annotations:
    summary: "Payment success rate below 98%"
    description: "Current success rate: {{ $value }}%"
    runbook: "Check Stripe status page and recent changes"

# Alert: High Stripe API Latency
- name: StripeAPILatencyHigh
  condition: stripe_api_latency_p99 > 3000
  for: 3m
  severity: warning
  annotations:
    summary: "Stripe API latency above 3 seconds (p99)"
    description: "Current p99 latency: {{ $value }}ms"

# Alert: Dispute Created
- name: StripeDisputeCreated
  condition: increase(stripe_disputes_created_total[5m]) > 0
  severity: critical
  annotations:
    summary: "New dispute created"
    description: "A new payment dispute has been opened"
    runbook: "Immediately review in Stripe dashboard"

# Alert: Webhook Processing Failures
- name: StripeWebhookFailures
  condition: rate(stripe_webhooks_failed_total[5m]) > 0.01
  for: 5m
  severity: warning
  annotations:
    summary: "Stripe webhook processing failures detected"
    description: "Webhook failure rate: {{ $value }}/s"

# Alert: High Decline Rate
- name: StripeHighDeclineRate
  condition: >
    (rate(stripe_payments_declined_total[5m]) / rate(payments_processed_total[5m])) > 0.05
  for: 10m
  severity: warning
  annotations:
    summary: "Payment decline rate above 5%"
    description: "Current decline rate: {{ $value }}%"
```

### 5.2 Business Alerts

```yaml
# Alert: Low Transaction Volume
- name: LowTransactionVolume
  condition: rate(payments_processed_total[30m]) < 10
  for: 15m
  severity: info
  annotations:
    summary: "Transaction volume below normal"
    description: "Processing fewer than 10 transactions per 30 minutes"

# Alert: Large Transaction
- name: LargeTransaction
  condition: payments_amount > 10000
  severity: info
  annotations:
    summary: "Large transaction detected"
    description: "Transaction amount: ${{ $value }}"
```

---

## Step 6: Trace Examples

### 6.1 Successful Payment Trace

```
[Span] HTTP POST /api/payment (250ms)
  └── [Span] ProcessPayment (245ms)
        ├── [Span] CreatePaymentIntent (120ms)
        │     └── [Span] StripeApiCall POST /v1/payment_intents (115ms)
        │           Tags:
        │             stripe.payment_intent_id: pi_3ABC123
        │             http.status_code: 200
        │
        ├── [Span] ConfirmPayment (100ms)
        │     └── [Span] StripeApiCall POST /v1/payment_intents/pi_3ABC123/confirm (95ms)
        │           Tags:
        │             stripe.status: succeeded
        │             http.status_code: 200
        │
        └── [Span] SQL INSERT Transaction (20ms)
              Tags:
                db.system: mssql
                db.statement: INSERT INTO Transactions...
```

### 6.2 Failed Payment Trace

```
[Span] HTTP POST /api/payment (180ms) ⚠️ Error
  └── [Span] ProcessPayment (175ms) ⚠️ Error
        ├── [Span] CreatePaymentIntent (50ms)
        │     └── [Span] StripeApiCall POST /v1/payment_intents (45ms)
        │
        └── [Span] ConfirmPayment (120ms) ⚠️ Error
              └── [Span] StripeApiCall POST /v1/payment_intents/pi_3ABC123/confirm (115ms)
                    Tags:
                      stripe.status: failed
                      stripe.error_type: card_error
                      stripe.error_code: card_declined
                      stripe.decline_code: insufficient_funds
                    Exception:
                      type: Stripe.StripeException
                      message: Your card has insufficient funds
```

---

## Next Steps

After completing Stripe monitoring setup:

1. ✅ Verify Stripe API calls appear in traces
2. ✅ Verify webhooks are being tracked
3. ✅ Create Stripe-specific dashboard
4. ➡️ Proceed to [SQL Server Monitoring Guide](06-sql-server-monitoring.md)
