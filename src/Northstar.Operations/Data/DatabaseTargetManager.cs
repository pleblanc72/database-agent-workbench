using Northstar.Operations.BusinessActivities;
using Northstar.Operations.Workload;

namespace Northstar.Operations.Data;

public sealed class DatabaseTargetManager(
    SqlConnectionFactory connectionFactory,
    DatabaseReadinessService readinessService,
    NormalWorkloadService workload,
    ReservationModificationSurgeService reservationModificationSurge,
    FlexibleDateSearchCampaignService flexibleDateSearchCampaign,
    GuestStayHistoryExportService guestStayHistoryExport,
    PortfolioRevenueReconciliationService portfolioRevenueReconciliation,
    BusinessActivityValidationService validation,
    ILogger<DatabaseTargetManager> logger)
{
    private readonly SemaphoreSlim _controlGate = new(1, 1);

    public DatabaseTarget CurrentTarget => connectionFactory.GetCurrentTarget();

    public Task<DatabaseReadinessResult> CheckAsync(
        DatabaseTarget target,
        CancellationToken cancellationToken)
    {
        return readinessService.CheckAsync(target, cancellationToken);
    }

    public async Task<T> ExecuteStartAsync<T>(
        Func<Task<T>> start,
        CancellationToken cancellationToken)
    {
        await _controlGate.WaitAsync(cancellationToken);
        try
        {
            return await start();
        }
        finally
        {
            _controlGate.Release();
        }
    }

    public async Task<DatabaseSwitchResult> SwitchAsync(
        DatabaseTarget target,
        CancellationToken cancellationToken)
    {
        await _controlGate.WaitAsync(cancellationToken);
        try
        {
            var readiness = await readinessService.CheckAsync(target, cancellationToken);
            if (!readiness.Ready)
            {
                return new DatabaseSwitchResult(
                    false,
                    connectionFactory.GetCurrentTarget(),
                    readiness,
                    "The target database failed readiness checks. The active database was not changed.");
            }

            if (validation.HasRunningValidation)
            {
                return new DatabaseSwitchResult(
                    false,
                    connectionFactory.GetCurrentTarget(),
                    readiness,
                    "A threshold validation is running. Wait for it to finish before switching databases.");
            }

            await Task.WhenAll(
                workload.StopWorkloadAsync(cancellationToken),
                reservationModificationSurge.StopActivityAsync(cancellationToken),
                flexibleDateSearchCampaign.StopActivityAsync(cancellationToken),
                guestStayHistoryExport.StopActivityAsync(cancellationToken),
                portfolioRevenueReconciliation.StopActivityAsync(cancellationToken));

            connectionFactory.UseTarget(target);
            logger.LogInformation(
                "Switched active database target to {Server} / {Database}",
                target.Server,
                target.Database);

            return new DatabaseSwitchResult(
                true,
                connectionFactory.GetCurrentTarget(),
                readiness,
                "The database target was switched successfully. Workloads remain stopped.");
        }
        finally
        {
            _controlGate.Release();
        }
    }
}

public sealed record DatabaseSwitchResult(
    bool Switched,
    DatabaseTarget ActiveTarget,
    DatabaseReadinessResult Readiness,
    string Message);
