namespace Northstar.Operations.Options;

public sealed class WorkloadOptions
{
    public const string SectionName = "Workload";

    public bool Enabled { get; set; }

    public int WorkerCount { get; set; } = 4;

    public int MinimumDelayMilliseconds { get; set; } = 500;

    public int MaximumDelayMilliseconds { get; set; } = 1200;

    public int RunDurationSeconds { get; set; }
}
