namespace Northstar.Operations.Options;

public sealed class ReservationModificationSurgeOptions
{
    public const string SectionName = "BusinessActivities:ReservationModificationSurge";

    public bool Enabled { get; set; }

    public int WorkerCount { get; set; } = 16;

    public int TargetPropertyCount { get; set; } = 1;

    public int WindowDays { get; set; } = 120;

    public int BatchSize { get; set; } = 150;

    public int MaximumRateAdjustmentBasisPoints { get; set; } = 75;

    public int MinimumDelayMilliseconds { get; set; } = 10;

    public int MaximumDelayMilliseconds { get; set; } = 40;

    public int RunDurationSeconds { get; set; }
}
