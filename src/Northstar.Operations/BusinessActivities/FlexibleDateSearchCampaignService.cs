using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using Northstar.Operations.Data;
using Northstar.Operations.Options;

namespace Northstar.Operations.BusinessActivities;

public sealed class FlexibleDateSearchCampaignService(
    NorthstarRepository repository,
    IOptions<FlexibleDateSearchCampaignOptions> options,
    IHostApplicationLifetime applicationLifetime,
    ILogger<FlexibleDateSearchCampaignService> logger) : IHostedService, IAsyncDisposable
{
    private readonly SemaphoreSlim _controlGate = new(1, 1);
    private readonly FlexibleDateSearchCampaignOptions _options = options.Value;
    private CancellationTokenSource? _activityCancellation;
    private Task? _activityTask;
    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _stoppedAt;
    private long _completedSearches;
    private long _failedSearches;
    private int _isRunning;

    public FlexibleDateSearchCampaignSnapshot GetStatus()
    {
        return new FlexibleDateSearchCampaignSnapshot(
            IsRunning,
            IsRunning ? _options.WorkerCount : 0,
            _startedAt,
            _stoppedAt,
            Interlocked.Read(ref _completedSearches),
            Interlocked.Read(ref _failedSearches));
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
            Interlocked.Exchange(ref _completedSearches, 0);
            Interlocked.Exchange(ref _failedSearches, 0);
            Interlocked.Exchange(ref _isRunning, 1);

            logger.LogInformation(
                "Starting Flexible Date Search Campaign with {WorkerCount} workers over {SearchWindowDays} days",
                _options.WorkerCount,
                _options.SearchWindowDays);

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
            var workers = Enumerable.Range(1, _options.WorkerCount)
                .Select(workerId => RunWorkerAsync(workerId, cancellationToken))
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
                "Flexible Date Search Campaign stopped after {CompletedSearchCount} completed searches and {FailedSearchCount} failures",
                Interlocked.Read(ref _completedSearches),
                Interlocked.Read(ref _failedSearches));
        }
    }

    private async Task RunWorkerAsync(int workerId, CancellationToken cancellationToken)
    {
        var random = new Random(HashCode.Combine(Environment.ProcessId, workerId, DateTime.UtcNow.Ticks));

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await repository.SearchFlexibleStayOptionsAsync(
                    DateOnly.FromDateTime(DateTime.UtcNow).AddDays(random.Next(1, 8)),
                    _options.SearchWindowDays,
                    _options.MinimumNights,
                    _options.MaximumNights,
                    _options.ResultLimit,
                    cancellationToken);

                Interlocked.Increment(ref _completedSearches);
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
                Interlocked.Increment(ref _failedSearches);
                logger.LogError(
                    exception,
                    "Flexible Date Search Campaign worker {WorkerId} failed with SQL error {SqlErrorNumber}",
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
                "Flexible Date Search Campaign reached configured duration of {RunDurationSeconds} seconds",
                _options.RunDurationSeconds);
            await StopActivityAsync(applicationLifetime.ApplicationStopping);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }
}

public sealed record FlexibleDateSearchCampaignSnapshot(
    bool IsRunning,
    int ActiveWorkerCount,
    DateTimeOffset? StartedAt,
    DateTimeOffset? StoppedAt,
    long CompletedSearches,
    long FailedSearches);
