namespace Northstar.Operations.Options;

public sealed class GuestStayHistoryExportOptions
{
    public const string SectionName = "BusinessActivities:GuestStayHistoryExport";

    public bool Enabled { get; set; }

    public int WorkerCount { get; set; } = 8;

    public int HistoryDays { get; set; } = 365;

    public int MinimumDelayMilliseconds { get; set; }

    public int MaximumDelayMilliseconds { get; set; } = 100;

    public int RunDurationSeconds { get; set; }
}
