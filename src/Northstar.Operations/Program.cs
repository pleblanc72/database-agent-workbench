using Northstar.Operations.BusinessActivities;
using Northstar.Operations.Data;
using Northstar.Operations.Options;
using Northstar.Operations.Workload;

var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddOptions<WorkloadOptions>()
    .Bind(builder.Configuration.GetSection(WorkloadOptions.SectionName))
    .Validate(options => options.WorkerCount is >= 1 and <= 64, "WorkerCount must be between 1 and 64.")
    .Validate(options => options.MinimumDelayMilliseconds >= 50, "MinimumDelayMilliseconds must be at least 50.")
    .Validate(
        options => options.MaximumDelayMilliseconds >= options.MinimumDelayMilliseconds,
        "MaximumDelayMilliseconds must be greater than or equal to MinimumDelayMilliseconds.")
    .Validate(options => options.RunDurationSeconds >= 0, "RunDurationSeconds cannot be negative.")
    .ValidateOnStart();

builder.Services
    .AddOptions<ReservationModificationSurgeOptions>()
    .Bind(builder.Configuration.GetSection(ReservationModificationSurgeOptions.SectionName))
    .Validate(options => options.WorkerCount is >= 2 and <= 64, "WorkerCount must be between 2 and 64.")
    .Validate(options => options.TargetPropertyCount is >= 1 and <= 40, "TargetPropertyCount must be between 1 and 40.")
    .Validate(options => options.WindowDays is >= 30 and <= 365, "WindowDays must be between 30 and 365.")
    .Validate(options => options.BatchSize is >= 25 and <= 1000, "BatchSize must be between 25 and 1,000.")
    .Validate(
        options => options.MaximumRateAdjustmentBasisPoints is >= 1 and <= 200,
        "MaximumRateAdjustmentBasisPoints must be between 1 and 200.")
    .Validate(options => options.MinimumDelayMilliseconds >= 0, "MinimumDelayMilliseconds cannot be negative.")
    .Validate(
        options => options.MaximumDelayMilliseconds >= options.MinimumDelayMilliseconds,
        "MaximumDelayMilliseconds must be greater than or equal to MinimumDelayMilliseconds.")
    .Validate(options => options.RunDurationSeconds >= 0, "RunDurationSeconds cannot be negative.")
    .ValidateOnStart();

builder.Services
    .AddOptions<FlexibleDateSearchCampaignOptions>()
    .Bind(builder.Configuration.GetSection(FlexibleDateSearchCampaignOptions.SectionName))
    .Validate(options => options.WorkerCount is >= 1 and <= 64, "WorkerCount must be between 1 and 64.")
    .Validate(options => options.SearchWindowDays is >= 30 and <= 180, "SearchWindowDays must be between 30 and 180.")
    .Validate(options => options.MinimumNights is >= 1 and <= 14, "MinimumNights must be between 1 and 14.")
    .Validate(
        options => options.MaximumNights >= options.MinimumNights && options.MaximumNights <= 14,
        "MaximumNights must be between MinimumNights and 14.")
    .Validate(options => options.ResultLimit is >= 25 and <= 1000, "ResultLimit must be between 25 and 1,000.")
    .Validate(options => options.MinimumDelayMilliseconds >= 0, "MinimumDelayMilliseconds cannot be negative.")
    .Validate(
        options => options.MaximumDelayMilliseconds >= options.MinimumDelayMilliseconds,
        "MaximumDelayMilliseconds must be greater than or equal to MinimumDelayMilliseconds.")
    .Validate(options => options.RunDurationSeconds >= 0, "RunDurationSeconds cannot be negative.")
    .ValidateOnStart();

builder.Services
    .AddOptions<GuestStayHistoryExportOptions>()
    .Bind(builder.Configuration.GetSection(GuestStayHistoryExportOptions.SectionName))
    .Validate(options => options.WorkerCount is >= 1 and <= 64, "WorkerCount must be between 1 and 64.")
    .Validate(options => options.HistoryDays is >= 30 and <= 3650, "HistoryDays must be between 30 and 3,650.")
    .Validate(options => options.MinimumDelayMilliseconds >= 0, "MinimumDelayMilliseconds cannot be negative.")
    .Validate(
        options => options.MaximumDelayMilliseconds >= options.MinimumDelayMilliseconds,
        "MaximumDelayMilliseconds must be greater than or equal to MinimumDelayMilliseconds.")
    .Validate(options => options.RunDurationSeconds >= 0, "RunDurationSeconds cannot be negative.")
    .ValidateOnStart();

builder.Services
    .AddOptions<PortfolioRevenueReconciliationOptions>()
    .Bind(builder.Configuration.GetSection(PortfolioRevenueReconciliationOptions.SectionName))
    .Validate(options => options.WorkerCount is >= 1 and <= 8, "WorkerCount must be between 1 and 8.")
    .Validate(options => options.HistoryYears is >= 1 and <= 10, "HistoryYears must be between 1 and 10.")
    .Validate(options => options.MinimumDelayMilliseconds >= 0, "MinimumDelayMilliseconds cannot be negative.")
    .Validate(
        options => options.MaximumDelayMilliseconds >= options.MinimumDelayMilliseconds,
        "MaximumDelayMilliseconds must be greater than or equal to MinimumDelayMilliseconds.")
    .Validate(options => options.RunDurationSeconds >= 0, "RunDurationSeconds cannot be negative.")
    .ValidateOnStart();

builder.Services.AddSingleton<SqlConnectionFactory>();
builder.Services.AddSingleton<DatabaseReadinessService>();
builder.Services.AddSingleton<NorthstarRepository>();
builder.Services.AddSingleton<WorkloadMetrics>();
builder.Services.AddSingleton<NormalWorkloadService>();
builder.Services.AddHostedService(serviceProvider =>
    serviceProvider.GetRequiredService<NormalWorkloadService>());
builder.Services.AddSingleton<ReservationModificationSurgeService>();
builder.Services.AddHostedService(serviceProvider =>
    serviceProvider.GetRequiredService<ReservationModificationSurgeService>());
builder.Services.AddSingleton<FlexibleDateSearchCampaignService>();
builder.Services.AddHostedService(serviceProvider =>
    serviceProvider.GetRequiredService<FlexibleDateSearchCampaignService>());
builder.Services.AddSingleton<GuestStayHistoryExportService>();
builder.Services.AddHostedService(serviceProvider =>
    serviceProvider.GetRequiredService<GuestStayHistoryExportService>());
builder.Services.AddSingleton<PortfolioRevenueReconciliationService>();
builder.Services.AddHostedService(serviceProvider =>
    serviceProvider.GetRequiredService<PortfolioRevenueReconciliationService>());
builder.Services.AddSingleton<BusinessActivityValidationService>();
builder.Services.AddHostedService(serviceProvider =>
    serviceProvider.GetRequiredService<BusinessActivityValidationService>());
builder.Services.AddSingleton<DatabaseTargetManager>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/api/database-target", (DatabaseTargetManager targetManager) =>
    Results.Ok(targetManager.CurrentTarget));

app.MapPost("/api/database-target/check", async (
    DatabaseTargetRequest request,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    if (!TryValidateTarget(request, out var target, out var error))
    {
        return Results.BadRequest(new { Error = error });
    }

    var readiness = await targetManager.CheckAsync(target!, cancellationToken);
    return Results.Ok(readiness);
});

app.MapPost("/api/database-target/switch", async (
    DatabaseTargetRequest request,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    if (!TryValidateTarget(request, out var target, out var error))
    {
        return Results.BadRequest(new { Error = error });
    }

    var result = await targetManager.SwitchAsync(target!, cancellationToken);
    return result.Switched
        ? Results.Ok(result)
        : Results.Conflict(result);
});

app.MapGet("/api/operations/status", async (
    NormalWorkloadService workload,
    NorthstarRepository repository,
    CancellationToken cancellationToken) =>
{
    var database = await repository.GetDatabaseActivityAsync(cancellationToken);
    return Results.Ok(new
    {
        Workload = workload.GetStatus(),
        Database = database,
        ObservedAt = DateTimeOffset.UtcNow
    });
});

app.MapPost("/api/operations/workload/start", async (
    NormalWorkloadService workload,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    var started = await targetManager.ExecuteStartAsync(
        () => workload.StartWorkloadAsync(cancellationToken),
        cancellationToken);
    return Results.Ok(new
    {
        Changed = started,
        Workload = workload.GetStatus()
    });
});

app.MapPost("/api/operations/workload/stop", async (
    NormalWorkloadService workload,
    CancellationToken cancellationToken) =>
{
    var stopped = await workload.StopWorkloadAsync(cancellationToken);
    return Results.Ok(new
    {
        Changed = stopped,
        Workload = workload.GetStatus()
    });
});

app.MapGet("/api/activities/reservation-modification-surge/status", (
    ReservationModificationSurgeService activity) =>
    Results.Ok(activity.GetStatus()));

app.MapPost("/api/activities/reservation-modification-surge/start", async (
    ReservationModificationSurgeService activity,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    var started = await targetManager.ExecuteStartAsync(
        () => activity.StartActivityAsync(cancellationToken),
        cancellationToken);
    return Results.Ok(new
    {
        Changed = started,
        Activity = activity.GetStatus()
    });
});

app.MapPost("/api/activities/reservation-modification-surge/stop", async (
    ReservationModificationSurgeService activity,
    CancellationToken cancellationToken) =>
{
    var stopped = await activity.StopActivityAsync(cancellationToken);
    return Results.Ok(new
    {
        Changed = stopped,
        Activity = activity.GetStatus()
    });
});

app.MapGet("/api/activities/flexible-date-search-campaign/status", (
    FlexibleDateSearchCampaignService activity) =>
    Results.Ok(activity.GetStatus()));

app.MapPost("/api/activities/flexible-date-search-campaign/start", async (
    FlexibleDateSearchCampaignService activity,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    var started = await targetManager.ExecuteStartAsync(
        () => activity.StartActivityAsync(cancellationToken),
        cancellationToken);
    return Results.Ok(new
    {
        Changed = started,
        Activity = activity.GetStatus()
    });
});

app.MapPost("/api/activities/flexible-date-search-campaign/stop", async (
    FlexibleDateSearchCampaignService activity,
    CancellationToken cancellationToken) =>
{
    var stopped = await activity.StopActivityAsync(cancellationToken);
    return Results.Ok(new
    {
        Changed = stopped,
        Activity = activity.GetStatus()
    });
});

app.MapGet("/api/activities/guest-stay-history-export/status", (
    GuestStayHistoryExportService activity) =>
    Results.Ok(activity.GetStatus()));

app.MapPost("/api/activities/guest-stay-history-export/start", async (
    GuestStayHistoryExportService activity,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    var started = await targetManager.ExecuteStartAsync(
        () => activity.StartActivityAsync(cancellationToken),
        cancellationToken);
    return Results.Ok(new
    {
        Changed = started,
        Activity = activity.GetStatus()
    });
});

app.MapPost("/api/activities/guest-stay-history-export/stop", async (
    GuestStayHistoryExportService activity,
    CancellationToken cancellationToken) =>
{
    var stopped = await activity.StopActivityAsync(cancellationToken);
    return Results.Ok(new
    {
        Changed = stopped,
        Activity = activity.GetStatus()
    });
});

app.MapGet("/api/activities/portfolio-revenue-reconciliation/status", (
    PortfolioRevenueReconciliationService activity) =>
    Results.Ok(activity.GetStatus()));

app.MapPost("/api/activities/portfolio-revenue-reconciliation/start", async (
    PortfolioRevenueReconciliationService activity,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    var started = await targetManager.ExecuteStartAsync(
        () => activity.StartActivityAsync(cancellationToken),
        cancellationToken);
    return Results.Ok(new
    {
        Changed = started,
        Activity = activity.GetStatus()
    });
});

app.MapPost("/api/activities/portfolio-revenue-reconciliation/stop", async (
    PortfolioRevenueReconciliationService activity,
    CancellationToken cancellationToken) =>
{
    var stopped = await activity.StopActivityAsync(cancellationToken);
    return Results.Ok(new
    {
        Changed = stopped,
        Activity = activity.GetStatus()
    });
});

app.MapGet("/api/activities/{activityId}/validation/status", (
    string activityId,
    BusinessActivityValidationService validation) =>
{
    return validation.IsKnownActivity(activityId)
        ? Results.Ok(validation.GetStatus(activityId))
        : Results.NotFound(new { Error = $"Unknown business activity '{activityId}'." });
});

app.MapPost("/api/activities/{activityId}/validation/start", async (
    string activityId,
    BusinessActivityValidationService validation,
    DatabaseTargetManager targetManager,
    CancellationToken cancellationToken) =>
{
    var result = await targetManager.ExecuteStartAsync(
        () => validation.TryStartAsync(activityId, cancellationToken),
        cancellationToken);

    if (result.Started)
    {
        return Results.Ok(result);
    }

    return validation.IsKnownActivity(activityId)
        ? Results.Conflict(result)
        : Results.NotFound(result);
});

app.MapGet("/health", (
    NormalWorkloadService workload,
    ReservationModificationSurgeService reservationModificationSurge,
    FlexibleDateSearchCampaignService flexibleDateSearchCampaign,
    GuestStayHistoryExportService guestStayHistoryExport,
    PortfolioRevenueReconciliationService portfolioRevenueReconciliation) => Results.Ok(new
{
    Status = "Healthy",
    Workload = workload.GetStatus(),
    ReservationModificationSurge = reservationModificationSurge.GetStatus(),
    FlexibleDateSearchCampaign = flexibleDateSearchCampaign.GetStatus(),
    GuestStayHistoryExport = guestStayHistoryExport.GetStatus(),
    PortfolioRevenueReconciliation = portfolioRevenueReconciliation.GetStatus()
}));

app.Run();

static bool TryValidateTarget(
    DatabaseTargetRequest request,
    out DatabaseTarget? target,
    out string? error)
{
    try
    {
        target = SqlConnectionFactory.ValidateTarget(request.Server, request.Database);
        error = null;
        return true;
    }
    catch (ArgumentException exception)
    {
        target = null;
        error = exception.Message;
        return false;
    }
}

public sealed record DatabaseTargetRequest(string? Server, string? Database);
