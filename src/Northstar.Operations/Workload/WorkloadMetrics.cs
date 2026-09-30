using System.Collections.Concurrent;

namespace Northstar.Operations.Workload;

public sealed class WorkloadMetrics
{
    private readonly ConcurrentQueue<DateTimeOffset> _recentCompletions = new();
    private long _completedRequests;
    private long _failedRequests;
    private DateTimeOffset? _startedAt;
    private DateTimeOffset? _stoppedAt;

    public void BeginRun()
    {
        Interlocked.Exchange(ref _completedRequests, 0);
        Interlocked.Exchange(ref _failedRequests, 0);
        _recentCompletions.Clear();
        _startedAt = DateTimeOffset.UtcNow;
        _stoppedAt = null;
    }

    public void EndRun()
    {
        _stoppedAt = DateTimeOffset.UtcNow;
    }

    public void RecordCompleted()
    {
        Interlocked.Increment(ref _completedRequests);
        _recentCompletions.Enqueue(DateTimeOffset.UtcNow);
    }

    public void RecordFailed()
    {
        Interlocked.Increment(ref _failedRequests);
    }

    public WorkloadSnapshot GetSnapshot(bool isRunning, int workerCount)
    {
        var cutoff = DateTimeOffset.UtcNow.AddMinutes(-1);
        while (_recentCompletions.TryPeek(out var completedAt) && completedAt < cutoff)
        {
            _recentCompletions.TryDequeue(out _);
        }

        return new WorkloadSnapshot(
            isRunning,
            isRunning ? workerCount : 0,
            _startedAt,
            _stoppedAt,
            Interlocked.Read(ref _completedRequests),
            Interlocked.Read(ref _failedRequests),
            _recentCompletions.Count);
    }
}

public sealed record WorkloadSnapshot(
    bool IsRunning,
    int ActiveWorkerCount,
    DateTimeOffset? StartedAt,
    DateTimeOffset? StoppedAt,
    long CompletedRequests,
    long FailedRequests,
    int RequestsPerMinute);
