using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using Northstar.Operations.Data;
using Northstar.Operations.Options;

namespace Northstar.Operations.BusinessActivities;

public sealed class GuestStayHistoryExportService(
    NorthstarRepository repository,
    IOptions<GuestStayHistoryExportOptions> options,
    IHostApplicationLifetime applicationLifetime,
    ILogger<GuestStayHistoryExportService> logger) : IHostedService, IAsyncDisposable
{
    private readonly SemaphoreSlim _controlGate = new(1, 1);
    private readonly GuestStayHistoryExportOptions _options = options.Value;
    private CancellationTokenSource? _activityCancellation;
    private Task? _activityTask;
    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _stoppedAt;
    private long _completedExports;
    private long _exportedRows;
    private long _failedExports;
    private int _isRunning;

    public GuestStayHistoryExportSnapshot GetStatus()
    {
        return new GuestStayHistoryExportSnapshot(
            IsRunning,
            IsRunning ? _options.WorkerCount : 0,
            _startedAt,
            _stoppedAt,
            Interlocked.Read(ref _completedExports),
            Interlocked.Read(ref _exportedRows),
            Interlocked.Read(ref _failedExports));
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

            _activityCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                applicationLifetime.ApplicationStopping);
            _startedAt = DateTimeOffset.UtcNow;
            _stoppedAt = null;
            Interlocked.Exchange(ref _completedExports, 0);
            Interlocked.Exchange(ref _exportedRows, 0);
            Interlocked.Exchange(ref _failedExports, 0);
            Interlocked.Exchange(ref _isRunning, 1);

            logger.LogInformation(
                "Starting Guest Stay History Export with {WorkerCount} workers over {HistoryDays} history days",
                _options.WorkerCount,
                _options.HistoryDays);

            _activityTask = RunActivityAsync(_activityCancellation.Token);

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

    private async Task RunActivityAsync(CancellationToken cancellationToken)
    {
        try
        {
            var workers = Enumerable.Range(0, _options.WorkerCount)
                .Select(partitionNumber => RunWorkerAsync(partitionNumber, cancellationToken))
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
                "Guest Stay History Export stopped after {CompletedExportCount} completed exports, {ExportedRowCount} rows, and {FailedExportCount} failures",
                Interlocked.Read(ref _completedExports),
                Interlocked.Read(ref _exportedRows),
                Interlocked.Read(ref _failedExports));
        }
    }

    private async Task RunWorkerAsync(int partitionNumber, CancellationToken cancellationToken)
    {
        var random = new Random(HashCode.Combine(Environment.ProcessId, partitionNumber, DateTime.UtcNow.Ticks));

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var endDate = DateOnly.FromDateTime(DateTime.UtcNow);
                var rowCount = await repository.ExportGuestStayHistoryAsync(
                    endDate.AddDays(-_options.HistoryDays),
                    endDate,
                    partitionNumber,
                    _options.WorkerCount,
                    cancellationToken);

                Interlocked.Increment(ref _completedExports);
                Interlocked.Add(ref _exportedRows, rowCount);
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
                Interlocked.Increment(ref _failedExports);
                logger.LogError(
                    exception,
                    "Guest Stay History Export worker {PartitionNumber} failed with SQL error {SqlErrorNumber}",
                    partitionNumber,
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
                "Guest Stay History Export reached configured duration of {RunDurationSeconds} seconds",
                _options.RunDurationSeconds);
            await StopActivityAsync(applicationLifetime.ApplicationStopping);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }
}

public sealed record GuestStayHistoryExportSnapshot(
    bool IsRunning,
    int ActiveWorkerCount,
    DateTimeOffset? StartedAt,
    DateTimeOffset? StoppedAt,
    long CompletedExports,
    long ExportedRows,
    long FailedExports);
