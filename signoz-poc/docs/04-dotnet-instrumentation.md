# SigNoz POC - .NET OpenTelemetry Instrumentation

## Overview

This guide covers instrumenting a .NET payment gateway application with OpenTelemetry to send traces, metrics, and logs to SigNoz.

---

## Prerequisites

- .NET 6.0 or later
- ASP.NET Core Web API project
- SigNoz server running and accessible
- NuGet package manager

---

## Step 1: Install NuGet Packages

### 1.1 Required Packages

Add the following packages to your `.csproj` file:

```xml
<ItemGroup>
  <!-- Core OpenTelemetry -->
  <PackageReference Include="OpenTelemetry" Version="1.7.0" />
  <PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.7.0" />
  
  <!-- Exporters -->
  <PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.7.0" />
  
  <!-- Auto-instrumentation -->
  <PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" Version="1.7.0" />
  <PackageReference Include="OpenTelemetry.Instrumentation.Http" Version="1.7.0" />
  <PackageReference Include="OpenTelemetry.Instrumentation.SqlClient" Version="1.7.0-beta.1" />
  
  <!-- Metrics -->
  <PackageReference Include="OpenTelemetry.Instrumentation.Runtime" Version="1.7.0" />
  <PackageReference Include="OpenTelemetry.Instrumentation.Process" Version="0.5.0-beta.4" />
</ItemGroup>
```

### 1.2 Install via CLI

```bash
dotnet add package OpenTelemetry --version 1.7.0
dotnet add package OpenTelemetry.Extensions.Hosting --version 1.7.0
dotnet add package OpenTelemetry.Exporter.OpenTelemetryProtocol --version 1.7.0
dotnet add package OpenTelemetry.Instrumentation.AspNetCore --version 1.7.0
dotnet add package OpenTelemetry.Instrumentation.Http --version 1.7.0
dotnet add package OpenTelemetry.Instrumentation.SqlClient --version 1.7.0-beta.1
dotnet add package OpenTelemetry.Instrumentation.Runtime --version 1.7.0
```

---

## Step 2: Configure OpenTelemetry in Program.cs

### 2.1 Basic Configuration

```csharp
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OpenTelemetry.Logs;

var builder = WebApplication.CreateBuilder(args);

// Get SigNoz endpoint from configuration
var signozEndpoint = builder.Configuration["OpenTelemetry:Endpoint"] 
    ?? "http://localhost:4317";

// Define service resource
var serviceName = "PaymentGateway";
var serviceVersion = "1.0.0";

// Configure OpenTelemetry
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource
        .AddService(
            serviceName: serviceName,
            serviceVersion: serviceVersion,
            serviceInstanceId: Environment.MachineName)
        .AddAttributes(new Dictionary<string, object>
        {
            ["deployment.environment"] = builder.Environment.EnvironmentName,
            ["service.namespace"] = "payment-services"
        }))
    .WithTracing(tracing => tracing
        // Auto-instrumentation
        .AddAspNetCoreInstrumentation(options =>
        {
            options.RecordException = true;
            options.Filter = httpContext =>
            {
                // Exclude health checks
                return !httpContext.Request.Path.StartsWithSegments("/health");
            };
        })
        .AddHttpClientInstrumentation(options =>
        {
            options.RecordException = true;
            options.FilterHttpRequestMessage = request =>
            {
                // Include all Stripe API calls
                return true;
            };
        })
        .AddSqlClientInstrumentation(options =>
        {
            options.SetDbStatementForText = true;
            options.SetDbStatementForStoredProcedure = true;
            options.RecordException = true;
            options.EnableConnectionLevelAttributes = true;
        })
        // Custom instrumentation source
        .AddSource("PaymentGateway.Payments")
        .AddSource("PaymentGateway.Stripe")
        // Export to SigNoz
        .AddOtlpExporter(options =>
        {
            options.Endpoint = new Uri(signozEndpoint);
            options.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
        }))
    .WithMetrics(metrics => metrics
        // Auto-instrumentation
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddProcessInstrumentation()
        // Custom metrics
        .AddMeter("PaymentGateway.Payments")
        // Export to SigNoz
        .AddOtlpExporter(options =>
        {
            options.Endpoint = new Uri(signozEndpoint);
            options.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
        }));

// Configure logging
builder.Logging.AddOpenTelemetry(logging =>
{
    logging.IncludeFormattedMessage = true;
    logging.IncludeScopes = true;
    logging.ParseStateValues = true;
    logging.AddOtlpExporter(options =>
    {
        options.Endpoint = new Uri(signozEndpoint);
        options.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
    });
});

// Add other services
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();

// Configure middleware
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();
```

### 2.2 Configuration Settings

Add to `appsettings.json`:

```json
{
  "OpenTelemetry": {
    "Endpoint": "http://signoz-server:4317",
    "ServiceName": "PaymentGateway",
    "ServiceVersion": "1.0.0"
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "System.Net.Http": "Warning"
    }
  }
}
```

Add to `appsettings.Production.json`:

```json
{
  "OpenTelemetry": {
    "Endpoint": "http://10.0.1.100:4317"
  }
}
```

---

## Step 3: Create Custom Instrumentation

### 3.1 Payment Instrumentation Class

Create `Telemetry/PaymentInstrumentation.cs`:

```csharp
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace PaymentGateway.Telemetry;

public static class PaymentInstrumentation
{
    public const string ServiceName = "PaymentGateway.Payments";
    public const string Version = "1.0.0";

    // ActivitySource for tracing
    public static readonly ActivitySource ActivitySource = new(ServiceName, Version);

    // Meter for metrics
    private static readonly Meter Meter = new(ServiceName, Version);

    // Counters
    public static readonly Counter<long> PaymentsProcessed = 
        Meter.CreateCounter<long>(
            "payments.processed.total",
            unit: "count",
            description: "Total number of payments processed");

    public static readonly Counter<long> PaymentsSucceeded = 
        Meter.CreateCounter<long>(
            "payments.succeeded.total",
            unit: "count",
            description: "Total number of successful payments");

    public static readonly Counter<long> PaymentsFailed = 
        Meter.CreateCounter<long>(
            "payments.failed.total",
            unit: "count",
            description: "Total number of failed payments");

    public static readonly Counter<decimal> RevenueProcessed = 
        Meter.CreateCounter<decimal>(
            "payments.revenue.total",
            unit: "USD",
            description: "Total revenue processed");

    // Histograms
    public static readonly Histogram<double> PaymentDuration = 
        Meter.CreateHistogram<double>(
            "payments.duration",
            unit: "ms",
            description: "Payment processing duration in milliseconds");

    public static readonly Histogram<double> PaymentAmount = 
        Meter.CreateHistogram<double>(
            "payments.amount",
            unit: "USD",
            description: "Payment amounts processed");

    // Gauges (via ObservableGauge)
    private static int _activePayments = 0;
    
    public static readonly ObservableGauge<int> ActivePayments = 
        Meter.CreateObservableGauge(
            "payments.active",
            () => _activePayments,
            unit: "count",
            description: "Number of payments currently being processed");

    public static void IncrementActivePayments() => Interlocked.Increment(ref _activePayments);
    public static void DecrementActivePayments() => Interlocked.Decrement(ref _activePayments);
}
```

### 3.2 Stripe Instrumentation Class

Create `Telemetry/StripeInstrumentation.cs`:

```csharp
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace PaymentGateway.Telemetry;

public static class StripeInstrumentation
{
    public const string ServiceName = "PaymentGateway.Stripe";
    public const string Version = "1.0.0";

    public static readonly ActivitySource ActivitySource = new(ServiceName, Version);

    private static readonly Meter Meter = new(ServiceName, Version);

    public static readonly Counter<long> StripeApiCalls = 
        Meter.CreateCounter<long>(
            "stripe.api_calls.total",
            unit: "count",
            description: "Total Stripe API calls");

    public static readonly Counter<long> StripeApiErrors = 
        Meter.CreateCounter<long>(
            "stripe.api_errors.total",
            unit: "count",
            description: "Total Stripe API errors");

    public static readonly Histogram<double> StripeApiLatency = 
        Meter.CreateHistogram<double>(
            "stripe.api_latency",
            unit: "ms",
            description: "Stripe API call latency");

    public static readonly Counter<long> WebhooksReceived = 
        Meter.CreateCounter<long>(
            "stripe.webhooks.received.total",
            unit: "count",
            description: "Total Stripe webhooks received");

    public static readonly Counter<long> WebhooksProcessed = 
        Meter.CreateCounter<long>(
            "stripe.webhooks.processed.total",
            unit: "count",
            description: "Total Stripe webhooks processed successfully");
}
```

---

## Step 4: Instrument Payment Service

### 4.1 Payment Service Implementation

Create `Services/PaymentService.cs`:

```csharp
using System.Diagnostics;
using PaymentGateway.Telemetry;
using PaymentGateway.Models;

namespace PaymentGateway.Services;

public class PaymentService : IPaymentService
{
    private readonly IStripeService _stripeService;
    private readonly ITransactionRepository _transactionRepository;
    private readonly ILogger<PaymentService> _logger;

    public PaymentService(
        IStripeService stripeService,
        ITransactionRepository transactionRepository,
        ILogger<PaymentService> logger)
    {
        _stripeService = stripeService;
        _transactionRepository = transactionRepository;
        _logger = logger;
    }

    public async Task<PaymentResult> ProcessPaymentAsync(PaymentRequest request)
    {
        // Start custom span
        using var activity = PaymentInstrumentation.ActivitySource
            .StartActivity("ProcessPayment", ActivityKind.Internal);

        // Track active payments
        PaymentInstrumentation.IncrementActivePayments();
        var stopwatch = Stopwatch.StartNew();

        try
        {
            // Add semantic attributes
            activity?.SetTag("payment.id", request.PaymentId);
            activity?.SetTag("payment.amount", request.Amount);
            activity?.SetTag("payment.currency", request.Currency);
            activity?.SetTag("payment.method", "stripe");
            activity?.SetTag("customer.id", request.CustomerId);

            _logger.LogInformation(
                "Processing payment {PaymentId} for customer {CustomerId}, amount: {Amount} {Currency}",
                request.PaymentId, request.CustomerId, request.Amount, request.Currency);

            // Create payment intent
            var paymentIntent = await _stripeService.CreatePaymentIntentAsync(
                request.Amount, 
                request.Currency, 
                request.CustomerId);

            activity?.SetTag("stripe.payment_intent_id", paymentIntent.Id);

            // Confirm payment
            var charge = await _stripeService.ConfirmPaymentAsync(
                paymentIntent.Id, 
                request.PaymentMethodId);

            activity?.SetTag("stripe.charge_id", charge.Id);
            activity?.SetTag("stripe.status", charge.Status);

            // Save transaction
            var transaction = new Transaction
            {
                Id = Guid.NewGuid(),
                PaymentId = request.PaymentId,
                CustomerId = request.CustomerId,
                Amount = request.Amount,
                Currency = request.Currency,
                StripePaymentIntentId = paymentIntent.Id,
                StripeChargeId = charge.Id,
                Status = charge.Status,
                CreatedAt = DateTime.UtcNow
            };

            await _transactionRepository.SaveAsync(transaction);

            // Record metrics
            stopwatch.Stop();
            var duration = stopwatch.ElapsedMilliseconds;

            PaymentInstrumentation.PaymentsProcessed.Add(1, 
                new KeyValuePair<string, object?>("currency", request.Currency),
                new KeyValuePair<string, object?>("status", "success"));

            PaymentInstrumentation.PaymentsSucceeded.Add(1,
                new KeyValuePair<string, object?>("currency", request.Currency));

            PaymentInstrumentation.PaymentDuration.Record(duration,
                new KeyValuePair<string, object?>("status", "success"));

            PaymentInstrumentation.PaymentAmount.Record((double)request.Amount,
                new KeyValuePair<string, object?>("currency", request.Currency));

            PaymentInstrumentation.RevenueProcessed.Add(request.Amount,
                new KeyValuePair<string, object?>("currency", request.Currency));

            activity?.SetTag("payment.status", "succeeded");
            activity?.SetTag("payment.duration_ms", duration);

            _logger.LogInformation(
                "Payment {PaymentId} completed successfully in {Duration}ms",
                request.PaymentId, duration);

            return new PaymentResult
            {
                Success = true,
                PaymentId = request.PaymentId,
                TransactionId = transaction.Id,
                StripeChargeId = charge.Id
            };
        }
        catch (StripeException ex)
        {
            stopwatch.Stop();
            
            // Record error metrics
            PaymentInstrumentation.PaymentsProcessed.Add(1,
                new KeyValuePair<string, object?>("currency", request.Currency),
                new KeyValuePair<string, object?>("status", "failed"));

            PaymentInstrumentation.PaymentsFailed.Add(1,
                new KeyValuePair<string, object?>("currency", request.Currency),
                new KeyValuePair<string, object?>("error_type", ex.StripeError?.Type ?? "unknown"));

            PaymentInstrumentation.PaymentDuration.Record(stopwatch.ElapsedMilliseconds,
                new KeyValuePair<string, object?>("status", "failed"));

            // Record exception in span
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);
            activity?.SetTag("payment.status", "failed");
            activity?.SetTag("error.type", ex.StripeError?.Type);
            activity?.SetTag("error.code", ex.StripeError?.Code);
            activity?.SetTag("error.message", ex.StripeError?.Message);

            _logger.LogError(ex, 
                "Payment {PaymentId} failed: {ErrorType} - {ErrorMessage}",
                request.PaymentId, ex.StripeError?.Type, ex.StripeError?.Message);

            return new PaymentResult
            {
                Success = false,
                PaymentId = request.PaymentId,
                ErrorCode = ex.StripeError?.Code,
                ErrorMessage = ex.StripeError?.Message
            };
        }
        catch (Exception ex)
        {
            stopwatch.Stop();

            PaymentInstrumentation.PaymentsFailed.Add(1,
                new KeyValuePair<string, object?>("currency", request.Currency),
                new KeyValuePair<string, object?>("error_type", "system_error"));

            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);
            activity?.SetTag("payment.status", "error");

            _logger.LogError(ex, "Unexpected error processing payment {PaymentId}", request.PaymentId);

            throw;
        }
        finally
        {
            PaymentInstrumentation.DecrementActivePayments();
        }
    }
}
```

---

## Step 5: Instrument Stripe Service

### 5.1 Stripe Service Implementation

Create `Services/StripeService.cs`:

```csharp
using System.Diagnostics;
using PaymentGateway.Telemetry;
using Stripe;

namespace PaymentGateway.Services;

public class StripeService : IStripeService
{
    private readonly PaymentIntentService _paymentIntentService;
    private readonly ILogger<StripeService> _logger;

    public StripeService(ILogger<StripeService> logger)
    {
        _paymentIntentService = new PaymentIntentService();
        _logger = logger;
    }

    public async Task<PaymentIntent> CreatePaymentIntentAsync(
        decimal amount, 
        string currency, 
        string customerId)
    {
        using var activity = StripeInstrumentation.ActivitySource
            .StartActivity("CreatePaymentIntent", ActivityKind.Client);

        var stopwatch = Stopwatch.StartNew();

        try
        {
            activity?.SetTag("stripe.operation", "create_payment_intent");
            activity?.SetTag("stripe.amount", amount);
            activity?.SetTag("stripe.currency", currency);
            activity?.SetTag("stripe.customer_id", customerId);

            var options = new PaymentIntentCreateOptions
            {
                Amount = (long)(amount * 100), // Convert to cents
                Currency = currency,
                Customer = customerId,
                AutomaticPaymentMethods = new PaymentIntentAutomaticPaymentMethodsOptions
                {
                    Enabled = true
                }
            };

            var paymentIntent = await _paymentIntentService.CreateAsync(options);

            stopwatch.Stop();

            activity?.SetTag("stripe.payment_intent_id", paymentIntent.Id);
            activity?.SetTag("stripe.status", paymentIntent.Status);

            // Record metrics
            StripeInstrumentation.StripeApiCalls.Add(1,
                new KeyValuePair<string, object?>("operation", "create_payment_intent"),
                new KeyValuePair<string, object?>("status", "success"));

            StripeInstrumentation.StripeApiLatency.Record(stopwatch.ElapsedMilliseconds,
                new KeyValuePair<string, object?>("operation", "create_payment_intent"));

            return paymentIntent;
        }
        catch (StripeException ex)
        {
            stopwatch.Stop();

            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);
            activity?.SetTag("stripe.error_type", ex.StripeError?.Type);
            activity?.SetTag("stripe.error_code", ex.StripeError?.Code);

            StripeInstrumentation.StripeApiCalls.Add(1,
                new KeyValuePair<string, object?>("operation", "create_payment_intent"),
                new KeyValuePair<string, object?>("status", "error"));

            StripeInstrumentation.StripeApiErrors.Add(1,
                new KeyValuePair<string, object?>("operation", "create_payment_intent"),
                new KeyValuePair<string, object?>("error_type", ex.StripeError?.Type ?? "unknown"));

            StripeInstrumentation.StripeApiLatency.Record(stopwatch.ElapsedMilliseconds,
                new KeyValuePair<string, object?>("operation", "create_payment_intent"));

            _logger.LogError(ex, "Failed to create payment intent");
            throw;
        }
    }

    public async Task<Charge> ConfirmPaymentAsync(string paymentIntentId, string paymentMethodId)
    {
        using var activity = StripeInstrumentation.ActivitySource
            .StartActivity("ConfirmPayment", ActivityKind.Client);

        var stopwatch = Stopwatch.StartNew();

        try
        {
            activity?.SetTag("stripe.operation", "confirm_payment");
            activity?.SetTag("stripe.payment_intent_id", paymentIntentId);

            var options = new PaymentIntentConfirmOptions
            {
                PaymentMethod = paymentMethodId
            };

            var paymentIntent = await _paymentIntentService.ConfirmAsync(paymentIntentId, options);

            stopwatch.Stop();

            activity?.SetTag("stripe.status", paymentIntent.Status);
            activity?.SetTag("stripe.charge_id", paymentIntent.LatestChargeId);

            StripeInstrumentation.StripeApiCalls.Add(1,
                new KeyValuePair<string, object?>("operation", "confirm_payment"),
                new KeyValuePair<string, object?>("status", "success"));

            StripeInstrumentation.StripeApiLatency.Record(stopwatch.ElapsedMilliseconds,
                new KeyValuePair<string, object?>("operation", "confirm_payment"));

            // Get the charge details
            var chargeService = new ChargeService();
            return await chargeService.GetAsync(paymentIntent.LatestChargeId);
        }
        catch (StripeException ex)
        {
            stopwatch.Stop();

            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);

            StripeInstrumentation.StripeApiErrors.Add(1,
                new KeyValuePair<string, object?>("operation", "confirm_payment"),
                new KeyValuePair<string, object?>("error_type", ex.StripeError?.Type ?? "unknown"));

            _logger.LogError(ex, "Failed to confirm payment intent {PaymentIntentId}", paymentIntentId);
            throw;
        }
    }
}
```

---

## Step 6: Instrument Controllers

### 6.1 Payment Controller

Create `Controllers/PaymentController.cs`:

```csharp
using Microsoft.AspNetCore.Mvc;
using PaymentGateway.Models;
using PaymentGateway.Services;

namespace PaymentGateway.Controllers;

[ApiController]
[Route("api/[controller]")]
public class PaymentController : ControllerBase
{
    private readonly IPaymentService _paymentService;
    private readonly ILogger<PaymentController> _logger;

    public PaymentController(
        IPaymentService paymentService,
        ILogger<PaymentController> logger)
    {
        _paymentService = paymentService;
        _logger = logger;
    }

    [HttpPost]
    public async Task<ActionResult<PaymentResult>> ProcessPayment([FromBody] PaymentRequest request)
    {
        // Input validation
        if (request.Amount <= 0)
        {
            _logger.LogWarning("Invalid payment amount: {Amount}", request.Amount);
            return BadRequest("Amount must be greater than 0");
        }

        var result = await _paymentService.ProcessPaymentAsync(request);

        if (result.Success)
        {
            return Ok(result);
        }

        return BadRequest(result);
    }

    [HttpGet("{transactionId}")]
    public async Task<ActionResult<Transaction>> GetTransaction(Guid transactionId)
    {
        // Implementation
        throw new NotImplementedException();
    }
}
```

---

## Step 7: Configure Environment Variables

For production deployment, use environment variables:

```bash
# Docker environment
OTEL_EXPORTER_OTLP_ENDPOINT=http://signoz-server:4317
OTEL_SERVICE_NAME=PaymentGateway
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.namespace=payment-services

# Or via .NET configuration
DOTNET_OpenTelemetry__Endpoint=http://signoz-server:4317
```

### Dockerfile Example

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
WORKDIR /app
EXPOSE 80
EXPOSE 443

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["PaymentGateway.csproj", "."]
RUN dotnet restore
COPY . .
RUN dotnet build -c Release -o /app/build

FROM build AS publish
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .

# OpenTelemetry configuration
ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://signoz-server:4317
ENV OTEL_SERVICE_NAME=PaymentGateway

ENTRYPOINT ["dotnet", "PaymentGateway.dll"]
```

---

## Step 8: Verify Instrumentation

### 8.1 Local Testing

```bash
# Run the application
dotnet run

# Make a test request
curl -X POST http://localhost:5000/api/payment \
  -H "Content-Type: application/json" \
  -d '{
    "paymentId": "test-123",
    "customerId": "cust_test",
    "amount": 99.99,
    "currency": "usd",
    "paymentMethodId": "pm_test"
  }'
```

### 8.2 Verify in SigNoz

1. Open SigNoz UI
2. Navigate to **Traces** tab
3. Search for `service.name = PaymentGateway`
4. Verify spans are appearing
5. Check **Metrics** tab for custom metrics

---

## Troubleshooting

### Common Issues

**1. No traces appearing:**
- Verify OTLP endpoint is correct
- Check network connectivity to SigNoz
- Review application logs for export errors

**2. Missing SQL traces:**
- Ensure `OpenTelemetry.Instrumentation.SqlClient` package is installed
- Verify SQL Client instrumentation is added in configuration

**3. High memory usage:**
- Reduce batch size in OTLP exporter
- Configure sampling for high-volume endpoints

```csharp
.WithTracing(tracing => tracing
    .SetSampler(new ParentBasedSampler(new TraceIdRatioBasedSampler(0.1))) // 10% sampling
    // ... rest of config
)
```

---

## Next Steps

After completing instrumentation:

1. ✅ Verify traces in SigNoz
2. ✅ Verify custom metrics are recording
3. ➡️ Proceed to [Stripe Monitoring Guide](05-stripe-monitoring.md)
