using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using Northstar.Operations.Data;
using Northstar.Operations.Options;

namespace Northstar.Operations.BusinessActivities;

public sealed class ReservationModificationSurgeService(
    NorthstarRepository repository,
    IOptions<ReservationModificationSurgeOptions> options,
    IHostApplicationLifetime applicationLifetime,
    ILogger<ReservationModificationSurgeService> logger) : IHostedService, IAsyncDisposable
{
    private readonly SemaphoreSlim _controlGate = new(1, 1);
    private readonly ReservationModificationSurgeOptions _options = options.Value;
    private CancellationTokenSource? _activityCancellation;
    private Task? _activityTask;
    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _stoppedAt;
    private long _completedBatches;
    private long _failedBatches;
    private int _isRunning;

    public ReservationModificationSurgeSnapshot GetStatus()
    {
        return new ReservationModificationSurgeSnapshot(
            IsRunning,
            IsRunning ? _options.WorkerCount : 0,
            _startedAt,
            _stoppedAt,
            Interlocked.Read(ref _completedBatches),
            Interlocked.Read(ref _failedBatches));
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (_options.Enabled)
        {
            await StartActivityAsync(cancellationToken);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        return StopActivityAsync(cancellationToken);
    }

    public async Task<bool> StartActivityAsync(CancellationToken cancellationToken)
    {
        await _controlGate.WaitAsync(cancellationToken);
        try
        {
            if (IsRunning)
            {
                return false;
            }

            var bounds = await repository.GetWorkloadBoundsAsync(cancellationToken);
            var availablePropertyCount = bounds.MaximumPropertyId - bounds.MinimumPropertyId + 1;

            if (_options.TargetPropertyCount > availablePropertyCount)
            {
                throw new InvalidOperationException(
                    "Reservation Modification Surge targets more properties than are available.");
            }

            _activityCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                applicationLifetime.ApplicationStopping);
            _startedAt = DateTimeOffset.UtcNow;
            _stoppedAt = null;
            Interlocked.Exchange(ref _completedBatches, 0);
            Interlocked.Exchange(ref _failedBatches, 0);
            Interlocked.Exchange(ref _isRunning, 1);

            logger.LogInformation(
                "Starting Reservation Modification Surge with {WorkerCount} workers across {TargetPropertyCount} properties",
                _options.WorkerCount,
                _options.TargetPropertyCount);

            _activityTask = RunActivityAsync(bounds.MinimumPropertyId, _activityCancellation.Token);

            if (_options.RunDurationSeconds > 0)
            {
                _ = StopAfterDurationAsync(_activityCancellation.Token);
            }

            return true;
        }
        catch
        {
            Interlocked.Exchange(ref _isRunning, 0);
            _activityCancellation?.Dispose();
            _activityCancellation = null;
            throw;
        }
        finally
        {
            _controlGate.Release();
        }
    }

    public async Task<bool> StopActivityAsync(CancellationToken cancellationToken)
    {
        await _controlGate.WaitAsync(cancellationToken);
        try
        {
            if (!IsRunning || _activityCancellation is null || _activityTask is null)
            {
                return false;
            }

            _activityCancellation.Cancel();

            try
            {
                await _activityTask.WaitAsync(cancellationToken);
            }
            catch (OperationCanceledException) when (_activityCancellation.IsCancellationRequested)
            {
            }

            _activityCancellation.Dispose();
            _activityCancellation = null;
            _activityTask = null;
            return true;
        }
        finally
        {
            _controlGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        _activityCancellation?.Cancel();

        if (_activityTask is not null)
        {
            try
            {
                await _activityTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        _activityCancellation?.Dispose();
        _controlGate.Dispose();
    }

    private bool IsRunning => Volatile.Read(ref _isRunning) == 1;

    private async Task RunActivityAsync(int minimumPropertyId, CancellationToken cancellationToken)
    {
        try
        {
            var workers = Enumerable.Range(1, _options.WorkerCount)
                .Select(workerId => RunWorkerAsync(workerId, minimumPropertyId, cancellationToken))
                .ToArray();

            await Task.WhenAll(workers);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            Interlocked.Exchange(ref _isRunning, 0);
            _stoppedAt = DateTimeOffset.UtcNow;
            logger.LogInformation(
                "Reservation Modification Surge stopped after {CompletedBatchCount} completed batches and {FailedBatchCount} failures",
                Interlocked.Read(ref _completedBatches),
                Interlocked.Read(ref _failedBatches));
        }
    }

    private async Task RunWorkerAsync(
        int workerId,
        int minimumPropertyId,
        CancellationToken cancellationToken)
    {
        var random = new Random(HashCode.Combine(Environment.ProcessId, workerId, DateTime.UtcNow.Ticks));
        var propertyId = minimumPropertyId + ((workerId - 1) % _options.TargetPropertyCount);

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var adjustment = random.Next(
                    -_options.MaximumRateAdjustmentBasisPoints,
                    _options.MaximumRateAdjustmentBasisPoints + 1);

                await repository.ApplyReservationModificationBatchAsync(
                    propertyId,
                    DateOnly.FromDateTime(DateTime.UtcNow),
                    _options.WindowDays,
                    _options.BatchSize,
                    adjustment,
                    cancellationToken);

                Interlocked.Increment(ref _completedBatches);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (SqlException exception) when (cancellationToken.IsCancellationRequested && exception.Number == 0)
            {
                break;
            }
            catch (SqlException exception)
            {
                Interlocked.Increment(ref _failedBatches);
                logger.LogError(
                    exception,
                    "Reservation Modification Surge worker {WorkerId} failed with SQL error {SqlErrorNumber}",
                    workerId,
                    exception.Number);
            }

            await Task.Delay(
                random.Next(_options.MinimumDelayMilliseconds, _options.MaximumDelayMilliseconds + 1),
                cancellationToken);
        }
    }

    private async Task StopAfterDurationAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(_options.RunDurationSeconds), cancellationToken);
            logger.LogInformation(
                "Reservation Modification Surge reached configured duration of {RunDurationSeconds} seconds",
                _options.RunDurationSeconds);
            await StopActivityAsync(applicationLifetime.ApplicationStopping);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }
}

public sealed record ReservationModificationSurgeSnapshot(
    bool IsRunning,
    int ActiveWorkerCount,
    DateTimeOffset? StartedAt,
    DateTimeOffset? StoppedAt,
    long CompletedBatches,
    long FailedBatches);
