# SigNoz POC - SQL Server Monitoring

## Overview

This guide covers monitoring SQL Server database operations in SigNoz, including query performance, connection pool monitoring, and database-specific dashboards.

---

## SQL Server Integration Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    .NET Payment Gateway                          │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │           OpenTelemetry SQL Client Instrumentation        │   │
│  │                                                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │   │
│  │  │   Traces    │  │   Metrics   │  │     Logs        │   │   │
│  │  │ (Queries)   │  │ (Pool,Time) │  │  (Errors)       │   │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
└──────────────────────────────┼───────────────────────────────────┘
                               │ OTLP
                               ▼
                    ┌─────────────────┐
                    │     SigNoz      │
                    │  (ClickHouse)   │
                    └─────────────────┘
```

---

## Step 1: Configure SQL Client Instrumentation

### 1.1 Program.cs Configuration

```csharp
using OpenTelemetry.Trace;

builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        // SQL Client auto-instrumentation
        .AddSqlClientInstrumentation(options =>
        {
            // Include SQL statements (sanitized)
            options.SetDbStatementForText = true;
            options.SetDbStatementForStoredProcedure = true;
            
            // Record exceptions
            options.RecordException = true;
            
            // Include connection details
            options.EnableConnectionLevelAttributes = true;
            
            // Filter out noise (health checks, etc.)
            options.Filter = command =>
            {
                // Exclude simple health check queries
                var sql = command.CommandText?.ToLower() ?? "";
                if (sql == "select 1" || sql.Contains("sys."))
                    return false;
                return true;
            };
            
            // Enrich spans with additional data
            options.Enrich = (activity, eventName, command) =>
            {
                if (command is System.Data.SqlClient.SqlCommand sqlCommand)
                {
                    activity?.SetTag("db.sql.table", ExtractTableName(sqlCommand.CommandText));
                }
            };
        })
        .AddOtlpExporter());
```

### 1.2 Connection String Best Practices

```csharp
// appsettings.json
{
  "ConnectionStrings": {
    "PaymentDb": "Server=sql-server.example.com;Database=PaymentGateway;User Id=app_user;Password=***;Application Name=PaymentGateway;TrustServerCertificate=true;MultipleActiveResultSets=true;Min Pool Size=5;Max Pool Size=100;Connection Timeout=30;"
  }
}
```

**Key Connection String Settings:**
- `Application Name` - Identifies app in SQL Server
- `Min Pool Size` / `Max Pool Size` - Connection pooling
- `Connection Timeout` - Prevents hanging connections

---

## Step 2: Custom Database Telemetry

### 2.1 Database Instrumentation Class

Create `Telemetry/DatabaseInstrumentation.cs`:

```csharp
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace PaymentGateway.Telemetry;

public static class DatabaseInstrumentation
{
    public const string ServiceName = "PaymentGateway.Database";
    public const string Version = "1.0.0";

    public static readonly ActivitySource ActivitySource = new(ServiceName, Version);
    private static readonly Meter Meter = new(ServiceName, Version);

    // Query counters
    public static readonly Counter<long> QueriesExecuted = 
        Meter.CreateCounter<long>(
            "db.queries.executed.total",
            unit: "count",
            description: "Total database queries executed");

    public static readonly Counter<long> QueriesFailed = 
        Meter.CreateCounter<long>(
            "db.queries.failed.total",
            unit: "count",
            description: "Total database queries failed");

    // Latency histograms
    public static readonly Histogram<double> QueryDuration = 
        Meter.CreateHistogram<double>(
            "db.query.duration",
            unit: "ms",
            description: "Database query duration");

    public static readonly Histogram<double> ConnectionAcquisitionTime = 
        Meter.CreateHistogram<double>(
            "db.connection.acquisition_time",
            unit: "ms",
            description: "Time to acquire connection from pool");

    // Connection pool metrics (observable)
    private static int _activeConnections = 0;
    private static int _idleConnections = 0;

    public static readonly ObservableGauge<int> ActiveConnections = 
        Meter.CreateObservableGauge(
            "db.pool.active_connections",
            () => _activeConnections,
            unit: "count",
            description: "Active database connections");

    public static readonly ObservableGauge<int> IdleConnections = 
        Meter.CreateObservableGauge(
            "db.pool.idle_connections",
            unit: "count",
            () => _idleConnections);

    // Slow query tracking
    public static readonly Counter<long> SlowQueries = 
        Meter.CreateCounter<long>(
            "db.queries.slow.total",
            unit: "count",
            description: "Queries exceeding threshold");

    // Deadlock tracking
    public static readonly Counter<long> Deadlocks = 
        Meter.CreateCounter<long>(
            "db.deadlocks.total",
            unit: "count",
            description: "Database deadlocks");

    // Transaction metrics
    public static readonly Counter<long> TransactionsStarted = 
        Meter.CreateCounter<long>(
            "db.transactions.started.total",
            unit: "count",
            description: "Database transactions started");

    public static readonly Counter<long> TransactionsCommitted = 
        Meter.CreateCounter<long>(
            "db.transactions.committed.total",
            unit: "count",
            description: "Database transactions committed");

    public static readonly Counter<long> TransactionsRolledBack = 
        Meter.CreateCounter<long>(
            "db.transactions.rolledback.total",
            unit: "count",
            description: "Database transactions rolled back");

    // Update connection pool stats (call periodically)
    public static void UpdateConnectionPoolStats(int active, int idle)
    {
        _activeConnections = active;
        _idleConnections = idle;
    }
}
```

### 2.2 Connection Pool Monitor

Create `Services/ConnectionPoolMonitor.cs`:

```csharp
using Microsoft.Data.SqlClient;
using PaymentGateway.Telemetry;

namespace PaymentGateway.Services;

public class ConnectionPoolMonitor : BackgroundService
{
    private readonly string _connectionString;
    private readonly ILogger<ConnectionPoolMonitor> _logger;

    public ConnectionPoolMonitor(
        IConfiguration configuration,
        ILogger<ConnectionPoolMonitor> logger)
    {
        _connectionString = configuration.GetConnectionString("PaymentDb")!;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                // Query connection pool stats (SQL Server specific)
                using var connection = new SqlConnection(_connectionString);
                await connection.OpenAsync(stoppingToken);

                var command = new SqlCommand(@"
                    SELECT 
                        (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name = 'PaymentGateway') as active_sessions,
                        (SELECT COUNT(*) FROM sys.dm_exec_connections WHERE session_id IN 
                            (SELECT session_id FROM sys.dm_exec_sessions WHERE program_name = 'PaymentGateway')) as connections
                ", connection);

                using var reader = await command.ExecuteReaderAsync(stoppingToken);
                if (await reader.ReadAsync(stoppingToken))
                {
                    var activeSessions = reader.GetInt32(0);
                    var connections = reader.GetInt32(1);
                    
                    DatabaseInstrumentation.UpdateConnectionPoolStats(connections, 0);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error monitoring connection pool");
            }

            await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken);
        }
    }
}
```

Register the service:

```csharp
builder.Services.AddHostedService<ConnectionPoolMonitor>();
```

---

## Step 3: Enhanced Query Logging

### 3.1 Custom DbCommand Interceptor

For Entity Framework Core, create `Data/QueryInterceptor.cs`:

```csharp
using System.Data.Common;
using System.Diagnostics;
using Microsoft.EntityFrameworkCore.Diagnostics;
using PaymentGateway.Telemetry;

namespace PaymentGateway.Data;

public class QueryInterceptor : DbCommandInterceptor
{
    private const int SlowQueryThresholdMs = 500;
    private readonly ILogger<QueryInterceptor> _logger;

    public QueryInterceptor(ILogger<QueryInterceptor> logger)
    {
        _logger = logger;
    }

    public override DbDataReader ReaderExecuted(
        DbCommand command,
        CommandExecutedEventData eventData,
        DbDataReader result)
    {
        RecordQueryMetrics(command, eventData);
        return base.ReaderExecuted(command, eventData, result);
    }

    public override ValueTask<DbDataReader> ReaderExecutedAsync(
        DbCommand command,
        CommandExecutedEventData eventData,
        DbDataReader result,
        CancellationToken cancellationToken = default)
    {
        RecordQueryMetrics(command, eventData);
        return base.ReaderExecutedAsync(command, eventData, result, cancellationToken);
    }

    public override int NonQueryExecuted(
        DbCommand command,
        CommandExecutedEventData eventData,
        int result)
    {
        RecordQueryMetrics(command, eventData);
        return base.NonQueryExecuted(command, eventData, result);
    }

    public override void CommandFailed(
        DbCommand command,
        CommandErrorEventData eventData)
    {
        var duration = eventData.Duration.TotalMilliseconds;
        var queryType = GetQueryType(command.CommandText);

        DatabaseInstrumentation.QueriesFailed.Add(1,
            new KeyValuePair<string, object?>("query_type", queryType),
            new KeyValuePair<string, object?>("error_type", eventData.Exception?.GetType().Name));

        _logger.LogError(eventData.Exception,
            "Database query failed after {Duration}ms: {Query}",
            duration, SanitizeQuery(command.CommandText));

        base.CommandFailed(command, eventData);
    }

    private void RecordQueryMetrics(DbCommand command, CommandExecutedEventData eventData)
    {
        var duration = eventData.Duration.TotalMilliseconds;
        var queryType = GetQueryType(command.CommandText);

        // Record query execution
        DatabaseInstrumentation.QueriesExecuted.Add(1,
            new KeyValuePair<string, object?>("query_type", queryType));

        // Record duration
        DatabaseInstrumentation.QueryDuration.Record(duration,
            new KeyValuePair<string, object?>("query_type", queryType));

        // Track slow queries
        if (duration > SlowQueryThresholdMs)
        {
            DatabaseInstrumentation.SlowQueries.Add(1,
                new KeyValuePair<string, object?>("query_type", queryType));

            var activity = Activity.Current;
            activity?.SetTag("db.slow_query", true);
            activity?.SetTag("db.query_time_ms", duration);

            _logger.LogWarning(
                "Slow query detected ({Duration}ms): {Query}",
                duration, SanitizeQuery(command.CommandText));
        }
    }

    private static string GetQueryType(string commandText)
    {
        var trimmed = commandText.TrimStart().ToUpperInvariant();
        return trimmed switch
        {
            var s when s.StartsWith("SELECT") => "SELECT",
            var s when s.StartsWith("INSERT") => "INSERT",
            var s when s.StartsWith("UPDATE") => "UPDATE",
            var s when s.StartsWith("DELETE") => "DELETE",
            var s when s.StartsWith("EXEC") => "STORED_PROCEDURE",
            _ => "OTHER"
        };
    }

    private static string SanitizeQuery(string query)
    {
        // Truncate long queries
        if (query.Length > 500)
            query = query.Substring(0, 500) + "...";

        // Remove parameter values (basic sanitization)
        return System.Text.RegularExpressions.Regex.Replace(
            query,
            @"'[^']*'",
            "'***'");
    }
}
```

Register the interceptor:

```csharp
builder.Services.AddDbContext<PaymentDbContext>((sp, options) =>
{
    options.UseSqlServer(connectionString);
    options.AddInterceptors(sp.GetRequiredService<QueryInterceptor>());
});

builder.Services.AddSingleton<QueryInterceptor>();
```

---

## Step 4: Transaction Repository with Telemetry

### 4.1 Repository Implementation

Create `Repositories/TransactionRepository.cs`:

```csharp
using System.Diagnostics;
using Microsoft.EntityFrameworkCore;
using PaymentGateway.Data;
using PaymentGateway.Models;
using PaymentGateway.Telemetry;

namespace PaymentGateway.Repositories;

public class TransactionRepository : ITransactionRepository
{
    private readonly PaymentDbContext _context;
    private readonly ILogger<TransactionRepository> _logger;

    public TransactionRepository(
        PaymentDbContext context,
        ILogger<TransactionRepository> logger)
    {
        _context = context;
        _logger = logger;
    }

    public async Task<Transaction> SaveAsync(Transaction transaction)
    {
        using var activity = DatabaseInstrumentation.ActivitySource
            .StartActivity("SaveTransaction", ActivityKind.Client);

        activity?.SetTag("db.system", "mssql");
        activity?.SetTag("db.operation", "INSERT");
        activity?.SetTag("transaction.id", transaction.Id);
        activity?.SetTag("transaction.amount", transaction.Amount);

        DatabaseInstrumentation.TransactionsStarted.Add(1);

        try
        {
            _context.Transactions.Add(transaction);
            await _context.SaveChangesAsync();

            DatabaseInstrumentation.TransactionsCommitted.Add(1);

            _logger.LogInformation(
                "Transaction saved: {TransactionId}, Amount: {Amount}",
                transaction.Id, transaction.Amount);

            return transaction;
        }
        catch (DbUpdateException ex)
        {
            DatabaseInstrumentation.TransactionsRolledBack.Add(1);
            
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.RecordException(ex);

            if (ex.InnerException?.Message.Contains("deadlock") == true)
            {
                DatabaseInstrumentation.Deadlocks.Add(1);
                activity?.SetTag("db.error", "deadlock");
            }

            throw;
        }
    }

    public async Task<Transaction?> GetByIdAsync(Guid id)
    {
        using var activity = DatabaseInstrumentation.ActivitySource
            .StartActivity("GetTransaction", ActivityKind.Client);

        activity?.SetTag("db.system", "mssql");
        activity?.SetTag("db.operation", "SELECT");
        activity?.SetTag("transaction.id", id);

        return await _context.Transactions
            .FirstOrDefaultAsync(t => t.Id == id);
    }

    public async Task<IEnumerable<Transaction>> GetByCustomerAsync(
        Guid customerId, 
        DateTime? fromDate = null,
        int limit = 100)
    {
        using var activity = DatabaseInstrumentation.ActivitySource
            .StartActivity("GetCustomerTransactions", ActivityKind.Client);

        activity?.SetTag("db.system", "mssql");
        activity?.SetTag("db.operation", "SELECT");
        activity?.SetTag("customer.id", customerId);
        activity?.SetTag("query.limit", limit);

        var query = _context.Transactions
            .Where(t => t.CustomerId == customerId);

        if (fromDate.HasValue)
        {
            query = query.Where(t => t.CreatedAt >= fromDate.Value);
            activity?.SetTag("query.from_date", fromDate.Value.ToString("O"));
        }

        var results = await query
            .OrderByDescending(t => t.CreatedAt)
            .Take(limit)
            .ToListAsync();

        activity?.SetTag("query.result_count", results.Count);

        return results;
    }

    public async Task<TransactionStats> GetStatsAsync(DateTime fromDate, DateTime toDate)
    {
        using var activity = DatabaseInstrumentation.ActivitySource
            .StartActivity("GetTransactionStats", ActivityKind.Client);

        activity?.SetTag("db.system", "mssql");
        activity?.SetTag("db.operation", "AGGREGATE");
        activity?.SetTag("query.from_date", fromDate.ToString("O"));
        activity?.SetTag("query.to_date", toDate.ToString("O"));

        var stats = await _context.Transactions
            .Where(t => t.CreatedAt >= fromDate && t.CreatedAt <= toDate)
            .GroupBy(t => 1)
            .Select(g => new TransactionStats
            {
                TotalCount = g.Count(),
                TotalAmount = g.Sum(t => t.Amount),
                SuccessCount = g.Count(t => t.Status == "succeeded"),
                FailedCount = g.Count(t => t.Status == "failed"),
                AverageAmount = g.Average(t => t.Amount)
            })
            .FirstOrDefaultAsync() ?? new TransactionStats();

        activity?.SetTag("stats.total_count", stats.TotalCount);
        activity?.SetTag("stats.total_amount", stats.TotalAmount);

        return stats;
    }
}
```

---

## Step 5: SQL Server Dashboard in SigNoz

### 5.1 Key Dashboard Panels

#### Panel 1: Query Latency Distribution

**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    quantile(0.50)(durationNano / 1000000) as p50_ms,
    quantile(0.95)(durationNano / 1000000) as p95_ms,
    quantile(0.99)(durationNano / 1000000) as p99_ms
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time
ORDER BY time
```

#### Panel 2: Query Volume by Type

**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    stringTagMap['db.operation'] as operation,
    count() as count
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time, operation
ORDER BY time
```

#### Panel 3: Slow Queries

**Query:**
```sql
SELECT 
    timestamp,
    durationNano / 1000000 as duration_ms,
    stringTagMap['db.statement'] as query,
    stringTagMap['db.operation'] as operation
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND durationNano / 1000000 > 500
  AND timestamp >= now() - INTERVAL 1 HOUR
ORDER BY durationNano DESC
LIMIT 20
```

#### Panel 4: Database Errors

**Query:**
```sql
SELECT 
    toStartOfMinute(timestamp) as time,
    stringTagMap['error.type'] as error_type,
    count() as count
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND statusCode = 2
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY time, error_type
ORDER BY time
```

### 5.2 Dashboard Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                 SQL SERVER MONITORING DASHBOARD                  │
├───────────────┬───────────────┬───────────────┬─────────────────┤
│ Queries/min   │ Avg Latency   │ Error Rate    │ Active Conns    │
│     1,250     │    45ms       │   0.1%        │     25/100      │
├───────────────┴───────────────┴───────────────┴─────────────────┤
│                                                                 │
│  [Query Latency Percentiles - p50, p95, p99 over time]          │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  [Query Volume by Operation Type - Stacked Area Chart]          │
│                                                                 │
├─────────────────────────────┬───────────────────────────────────┤
│                             │                                   │
│  [Connection Pool Usage]    │  [Query Duration Distribution]   │
│  [Active vs Idle]           │  [Histogram]                     │
│                             │                                   │
├─────────────────────────────┼───────────────────────────────────┤
│                             │                                   │
│  [Slow Queries Table]       │  [Error Breakdown]               │
│  [Last 20, with duration]   │  [By type]                       │
│                             │                                   │
├─────────────────────────────┴───────────────────────────────────┤
│                                                                 │
│  [Transaction Success Rate - Committed vs Rolled Back]          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step 6: Alerts for SQL Server

### 6.1 Alert Configuration

```yaml
# Alert: High Query Latency
- name: SQLServerHighLatency
  condition: db_query_duration_p95 > 500
  for: 5m
  severity: warning
  annotations:
    summary: "SQL Server query latency above 500ms (p95)"
    description: "Current p95 latency: {{ $value }}ms"
    runbook: "Check slow query log, review recent deployments"

# Alert: Connection Pool Exhaustion
- name: SQLServerPoolExhaustion
  condition: db_pool_active_connections / db_pool_max_connections > 0.9
  for: 2m
  severity: critical
  annotations:
    summary: "Connection pool nearly exhausted (>90%)"
    description: "Active: {{ $value.active }}, Max: {{ $value.max }}"
    runbook: "Check for connection leaks, increase pool size"

# Alert: Database Errors
- name: SQLServerErrorRate
  condition: rate(db_queries_failed_total[5m]) / rate(db_queries_executed_total[5m]) > 0.01
  for: 5m
  severity: warning
  annotations:
    summary: "Database error rate above 1%"
    description: "Error rate: {{ $value }}%"

# Alert: Deadlock Detected
- name: SQLServerDeadlock
  condition: increase(db_deadlocks_total[5m]) > 0
  severity: critical
  annotations:
    summary: "Database deadlock detected"
    description: "Review transaction patterns and indexes"

# Alert: Slow Query Spike
- name: SQLServerSlowQuerySpike
  condition: rate(db_queries_slow_total[5m]) > 10
  for: 5m
  severity: warning
  annotations:
    summary: "High number of slow queries"
    description: "{{ $value }} slow queries per minute"
```

---

## Step 7: Query Optimization Insights

### 7.1 Query Pattern Analysis

Use SigNoz to identify:

1. **Most Frequent Queries**
```sql
SELECT 
    stringTagMap['db.statement'] as query,
    count() as count,
    avg(durationNano / 1000000) as avg_ms
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND timestamp >= now() - INTERVAL 24 HOUR
GROUP BY query
ORDER BY count DESC
LIMIT 10
```

2. **Slowest Queries (by total time)**
```sql
SELECT 
    stringTagMap['db.statement'] as query,
    count() as count,
    sum(durationNano / 1000000) as total_time_ms,
    avg(durationNano / 1000000) as avg_ms
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND timestamp >= now() - INTERVAL 24 HOUR
GROUP BY query
ORDER BY total_time_ms DESC
LIMIT 10
```

### 7.2 N+1 Query Detection

Look for patterns in traces:
- Parent span with many child SQL spans
- Repeated similar queries in single request

**Example Detection Query:**
```sql
SELECT 
    traceId,
    count() as query_count,
    sum(durationNano / 1000000) as total_db_time_ms
FROM signoz_traces.signoz_index_v2
WHERE serviceName = 'PaymentGateway'
  AND stringTagMap['db.system'] = 'mssql'
  AND timestamp >= now() - INTERVAL 1 HOUR
GROUP BY traceId
HAVING query_count > 10
ORDER BY query_count DESC
LIMIT 20
```

---

## Next Steps

After completing SQL Server monitoring:

1. ✅ Verify database spans in traces
2. ✅ Verify slow query detection works
3. ✅ Create database dashboard
4. ➡️ Proceed to [Dashboard Design Guide](07-dashboard-design.md)
