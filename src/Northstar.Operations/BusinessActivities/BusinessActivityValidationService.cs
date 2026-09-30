using System.Collections.ObjectModel;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Northstar.Operations.Data;

namespace Northstar.Operations.BusinessActivities;

public sealed partial class BusinessActivityValidationService(
    SqlConnectionFactory connectionFactory,
    ReservationModificationSurgeService reservationModificationSurge,
    FlexibleDateSearchCampaignService flexibleDateSearchCampaign,
    GuestStayHistoryExportService guestStayHistoryExport,
    PortfolioRevenueReconciliationService portfolioRevenueReconciliation,
    IHostApplicationLifetime applicationLifetime,
    ILogger<BusinessActivityValidationService> logger) : IHostedService
{
    private const string ValidationApplicationName = "Northstar Threshold Validation";
    private static readonly ReadOnlyDictionary<string, ValidationDefinition> Definitions =
        new(new Dictionary<string, ValidationDefinition>(StringComparer.Ordinal)
        {
            ["reservation-modification-surge"] =
                new(
                    "03-phase-4-validation.sql",
                    "Blocking threshold",
                    "Collecting four blocking samples; this takes about one minute."),
            ["flexible-date-search-campaign"] =
                new(
                    "04-phase-5-validation.sql",
                    "CPU threshold",
                    "Checking recent Azure SQL CPU samples."),
            ["guest-stay-history-export"] =
                new(
                    "05-phase-6-validation.sql",
                    "Storage I/O threshold",
                    "Collecting eight storage samples; this takes about two minutes."),
            ["portfolio-revenue-reconciliation"] =
                new(
                    "06-phase-7-validation.sql",
                    "Long-running request threshold",
                    "Observing long-running requests and waits; this takes eight minutes.")
        });

    private readonly Lock _stateLock = new();
    private readonly SemaphoreSlim _startGate = new(1, 1);
    private readonly Dictionary<string, BusinessActivityValidationSnapshot> _snapshots =
        Definitions.Keys.ToDictionary(
            activityId => activityId,
            activityId => BusinessActivityValidationSnapshot.NotRun(activityId));
    private Task? _runningTask;
    private string? _runningActivityId;

    public Task StartAsync(CancellationToken cancellationToken)
    {
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        Task? runningTask;
        lock (_stateLock)
        {
            runningTask = _runningTask;
        }

        if (runningTask is not null)
        {
            await runningTask.WaitAsync(cancellationToken);
        }
    }

    public bool IsKnownActivity(string activityId)
    {
        return Definitions.ContainsKey(activityId);
    }

    public BusinessActivityValidationSnapshot GetStatus(string activityId)
    {
        lock (_stateLock)
        {
            return _snapshots.TryGetValue(activityId, out var snapshot)
                ? snapshot
                : throw new KeyNotFoundException($"Unknown business activity '{activityId}'.");
        }
    }

    public async Task<BusinessActivityValidationStartResult> TryStartAsync(
        string activityId,
        CancellationToken cancellationToken)
    {
        if (!Definitions.TryGetValue(activityId, out var definition))
        {
            return new BusinessActivityValidationStartResult(
                false,
                null,
                $"Unknown business activity '{activityId}'.");
        }

        await _startGate.WaitAsync(cancellationToken);
        try
        {
            lock (_stateLock)
            {
                if (_runningActivityId is not null)
                {
                    return new BusinessActivityValidationStartResult(
                        false,
                        _snapshots[_runningActivityId],
                        "Another threshold validation is already running.");
                }

                _runningActivityId = activityId;
                _snapshots[activityId] = new BusinessActivityValidationSnapshot(
                    activityId,
                    definition.ThresholdName,
                    "Starting",
                    DateTimeOffset.UtcNow,
                    null,
                    "Starting the business activity for threshold validation.");
            }

            bool activityStartedByValidation;
            try
            {
                activityStartedByValidation = await StartActivityAsync(activityId, cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
            }
            catch (Exception exception)
            {
                Complete(activityId, "Failed", $"Unable to start validation: {exception.Message}");
                throw;
            }

            BusinessActivityValidationSnapshot snapshot;
            lock (_stateLock)
            {
                snapshot = _snapshots[activityId] with
                {
                    State = "Running",
                    Message = definition.RunningMessage
                };
                _snapshots[activityId] = snapshot;
                _runningTask = RunValidationAsync(
                    activityId,
                    definition,
                    activityStartedByValidation,
                    applicationLifetime.ApplicationStopping);
            }

            return new BusinessActivityValidationStartResult(true, snapshot, null);
        }
        finally
        {
            _startGate.Release();
        }
    }

    private async Task RunValidationAsync(
        string activityId,
        ValidationDefinition definition,
        bool activityStartedByValidation,
        CancellationToken cancellationToken)
    {
        var finalState = "Passed";
        var finalMessage = $"{definition.ThresholdName} passed.";

        try
        {
            var scriptPath = Path.Combine(
                AppContext.BaseDirectory,
                "validation",
                definition.ScriptFileName);
            var script = await File.ReadAllTextAsync(scriptPath, cancellationToken);

            await using var connection = connectionFactory.Create(ValidationApplicationName);
            await connection.OpenAsync(cancellationToken);

            foreach (var batch in BatchSeparatorRegex().Split(script))
            {
                if (string.IsNullOrWhiteSpace(batch))
                {
                    continue;
                }

                await using var command = new SqlCommand(batch, connection)
                {
                    CommandTimeout = 900
                };
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);

                do
                {
                    while (await reader.ReadAsync(cancellationToken))
                    {
                    }
                }
                while (await reader.NextResultAsync(cancellationToken));
            }

        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            finalState = "Cancelled";
            finalMessage = "Validation was cancelled because the application stopped.";
        }
        catch (Exception exception)
        {
            logger.LogError(
                exception,
                "Threshold validation failed for business activity {ActivityId}",
                activityId);
            finalState = "Failed";
            finalMessage = exception.Message;
        }
        finally
        {
            if (activityStartedByValidation && !applicationLifetime.ApplicationStopping.IsCancellationRequested)
            {
                try
                {
                    await StopActivityAsync(activityId, CancellationToken.None);
                }
                catch (Exception exception)
                {
                    logger.LogError(
                        exception,
                        "Unable to stop business activity {ActivityId} after threshold validation",
                        activityId);
                    finalState = "Failed";
                    finalMessage =
                        $"Threshold collection finished, but the activity could not be stopped: {exception.Message}";
                }
            }

            Complete(activityId, finalState, finalMessage);
        }
    }

    private Task<bool> StartActivityAsync(string activityId, CancellationToken cancellationToken)
    {
        return activityId switch
        {
            "reservation-modification-surge" =>
                reservationModificationSurge.StartActivityAsync(cancellationToken),
            "flexible-date-search-campaign" =>
                flexibleDateSearchCampaign.StartActivityAsync(cancellationToken),
            "guest-stay-history-export" =>
                guestStayHistoryExport.StartActivityAsync(cancellationToken),
            "portfolio-revenue-reconciliation" =>
                portfolioRevenueReconciliation.StartActivityAsync(cancellationToken),
            _ => throw new KeyNotFoundException($"Unknown business activity '{activityId}'.")
        };
    }

    private Task<bool> StopActivityAsync(string activityId, CancellationToken cancellationToken)
    {
        return activityId switch
        {
            "reservation-modification-surge" =>
                reservationModificationSurge.StopActivityAsync(cancellationToken),
            "flexible-date-search-campaign" =>
                flexibleDateSearchCampaign.StopActivityAsync(cancellationToken),
            "guest-stay-history-export" =>
                guestStayHistoryExport.StopActivityAsync(cancellationToken),
            "portfolio-revenue-reconciliation" =>
                portfolioRevenueReconciliation.StopActivityAsync(cancellationToken),
            _ => throw new KeyNotFoundException($"Unknown business activity '{activityId}'.")
        };
    }

    private void Complete(string activityId, string state, string message)
    {
        lock (_stateLock)
        {
            var current = _snapshots[activityId];
            _snapshots[activityId] = current with
            {
                State = state,
                CompletedAt = DateTimeOffset.UtcNow,
                Message = message
            };
            _runningActivityId = null;
            _runningTask = null;
        }
    }

    [GeneratedRegex(@"(?im)^\s*GO\s*(?:--.*)?$")]
    private static partial Regex BatchSeparatorRegex();

    private sealed record ValidationDefinition(
        string ScriptFileName,
        string ThresholdName,
        string RunningMessage);
}

public sealed record BusinessActivityValidationSnapshot(
    string ActivityId,
    string ThresholdName,
    string State,
    DateTimeOffset? StartedAt,
    DateTimeOffset? CompletedAt,
    string Message)
{
    public static BusinessActivityValidationSnapshot NotRun(string activityId)
    {
        return new BusinessActivityValidationSnapshot(
            activityId,
            string.Empty,
            "NotRun",
            null,
            null,
            "Validation has not been run.");
    }
}

public sealed record BusinessActivityValidationStartResult(
    bool Started,
    BusinessActivityValidationSnapshot? Validation,
    string? Error);
