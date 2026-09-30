using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using Northstar.Operations.Data;
using Northstar.Operations.Options;

namespace Northstar.Operations.Workload;

public sealed class NormalWorkloadService(
    NorthstarRepository repository,
    WorkloadMetrics metrics,
    IOptions<WorkloadOptions> options,
    IHostApplicationLifetime applicationLifetime,
    ILogger<NormalWorkloadService> logger) : IHostedService, IAsyncDisposable
{
    private readonly SemaphoreSlim _controlGate = new(1, 1);
    private readonly WorkloadOptions _options = options.Value;
    private CancellationTokenSource? _workloadCancellation;
    private Task? _workloadTask;
    private int _isRunning;

    public WorkloadSnapshot GetStatus()
    {
        return metrics.GetSnapshot(IsRunning, _options.WorkerCount);
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (_options.Enabled)
        {
            await StartWorkloadAsync(cancellationToken);
        }
        else
        {
            logger.LogInformation("Normal workload is disabled and waiting for an operations console command");
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        return StopWorkloadAsync(cancellationToken);
    }

    public async Task<bool> StartWorkloadAsync(CancellationToken cancellationToken)
    {
        await _controlGate.WaitAsync(cancellationToken);
        try
        {
            if (IsRunning)
            {
                return false;
            }

            var bounds = await repository.GetWorkloadBoundsAsync(cancellationToken);
            _workloadCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                applicationLifetime.ApplicationStopping);

            metrics.BeginRun();
            Interlocked.Exchange(ref _isRunning, 1);

            logger.LogInformation(
                "Starting normal workload with {WorkerCount} workers and delays from {MinimumDelayMilliseconds} to {MaximumDelayMilliseconds} ms",
                _options.WorkerCount,
                _options.MinimumDelayMilliseconds,
                _options.MaximumDelayMilliseconds);

            _workloadTask = RunWorkloadAsync(bounds, _workloadCancellation.Token);

            if (_options.RunDurationSeconds > 0)
            {
                _ = StopAfterDurationAsync(_workloadCancellation.Token);
            }

            return true;
        }
        catch
        {
            Interlocked.Exchange(ref _isRunning, 0);
            _workloadCancellation?.Dispose();
            _workloadCancellation = null;
            metrics.EndRun();
            throw;
        }
        finally
        {
            _controlGate.Release();
        }
    }

    public async Task<bool> StopWorkloadAsync(CancellationToken cancellationToken)
    {
        await _controlGate.WaitAsync(cancellationToken);
        try
        {
            if (!IsRunning || _workloadCancellation is null || _workloadTask is null)
            {
                return false;
            }

            _workloadCancellation.Cancel();

            try
            {
                await _workloadTask.WaitAsync(cancellationToken);
            }
            catch (OperationCanceledException) when (_workloadCancellation.IsCancellationRequested)
            {
            }

            _workloadCancellation.Dispose();
            _workloadCancellation = null;
            _workloadTask = null;
            return true;
        }
        finally
        {
            _controlGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_workloadCancellation is not null)
        {
            _workloadCancellation.Cancel();
        }

        if (_workloadTask is not null)
        {
            try
            {
                await _workloadTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        _workloadCancellation?.Dispose();
        _controlGate.Dispose();
    }

    private bool IsRunning => Volatile.Read(ref _isRunning) == 1;

    private async Task RunWorkloadAsync(WorkloadBounds bounds, CancellationToken stoppingToken)
    {
        try
        {
            var workers = Enumerable.Range(1, _options.WorkerCount)
                .Select(workerId => RunWorkerAsync(workerId, bounds, stoppingToken))
                .ToArray();

            await Task.WhenAll(workers);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
        finally
        {
            Interlocked.Exchange(ref _isRunning, 0);
            metrics.EndRun();
            logger.LogInformation("Normal workload stopped");
        }
    }

    private async Task StopAfterDurationAsync(CancellationToken stoppingToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(_options.RunDurationSeconds), stoppingToken);
            logger.LogInformation(
                "Normal workload reached configured duration of {RunDurationSeconds} seconds",
                _options.RunDurationSeconds);
            await StopWorkloadAsync(applicationLifetime.ApplicationStopping);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
    }

    private async Task RunWorkerAsync(
        int workerId,
        WorkloadBounds bounds,
        CancellationToken stoppingToken)
    {
        var random = new Random(HashCode.Combine(Environment.ProcessId, workerId, DateTime.UtcNow.Ticks));

        while (!stoppingToken.IsCancellationRequested)
        {
            var operationName = "Unknown";

            try
            {
                operationName = await ExecuteOperationAsync(random, bounds, stoppingToken);
                metrics.RecordCompleted();
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (SqlException exception) when (stoppingToken.IsCancellationRequested && exception.Number == 0)
            {
                break;
            }
            catch (SqlException exception) when (exception.Number == 52007)
            {
                metrics.RecordFailed();
                logger.LogWarning(
                    "Worker {WorkerId} could not complete {OperationName}: no matching room was available",
                    workerId,
                    operationName);
            }
            catch (SqlException exception)
            {
                metrics.RecordFailed();
                logger.LogError(
                    exception,
                    "Worker {WorkerId} failed during {OperationName} with SQL error {SqlErrorNumber}",
                    workerId,
                    operationName,
                    exception.Number);
            }

            await Task.Delay(
                random.Next(_options.MinimumDelayMilliseconds, _options.MaximumDelayMilliseconds + 1),
                stoppingToken);
        }
    }

    private async Task<string> ExecuteOperationAsync(
        Random random,
        WorkloadBounds bounds,
        CancellationToken cancellationToken)
    {
        var selection = random.Next(100);
        var propertyId = random.Next(bounds.MinimumPropertyId, bounds.MaximumPropertyId + 1);
        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        if (selection < 35)
        {
            var arrival = today.AddDays(random.Next(1, 46));
            await repository.SearchAvailabilityAsync(
                propertyId,
                arrival,
                arrival.AddDays(random.Next(1, 6)),
                cancellationToken);
            return "SearchAvailability";
        }

        if (selection < 60)
        {
            await repository.GetReservationAsync(
                random.NextInt64(bounds.MinimumReservationId, bounds.MaximumReservationId + 1),
                cancellationToken);
            return "GetReservation";
        }

        if (selection < 70)
        {
            await repository.GetPropertyPerformanceAsync(
                propertyId,
                today.AddDays(-30),
                today,
                cancellationToken);
            return "GetPropertyPerformance";
        }

        if (selection < 78)
        {
            var arrival = today.AddDays(random.Next(2, 46));
            await repository.CreateReservationAsync(
                random.NextInt64(bounds.MinimumGuestId, bounds.MaximumGuestId + 1),
                propertyId,
                arrival,
                arrival.AddDays(random.Next(1, 5)),
                cancellationToken);
            return "CreateReservation";
        }

        if (selection < 84)
        {
            await repository.ProcessNextPendingPaymentAsync(cancellationToken);
            return "ProcessPayment";
        }

        if (selection < 89)
        {
            await repository.UpdateGuestCountsAsync(
                random.NextInt64(bounds.MinimumReservationId, bounds.MaximumReservationId + 1),
                1,
                0,
                cancellationToken);
            return "UpdateReservation";
        }

        if (selection < 92)
        {
            await repository.CancelReservationAsync(
                random.NextInt64(bounds.MinimumReservationId, bounds.MaximumReservationId + 1),
                cancellationToken);
            return "CancelReservation";
        }

        if (selection < 96)
        {
            await repository.CheckInNextArrivalAsync(propertyId, cancellationToken);
            return "CheckInGuest";
        }

        await repository.UpdateRoomStatusAsync(
            random.Next(bounds.MinimumRoomId, bounds.MaximumRoomId + 1),
            random.Next(20) == 0 ? "Cleaning" : "Available",
            cancellationToken);
        return "UpdateRoomStatus";
    }
}
