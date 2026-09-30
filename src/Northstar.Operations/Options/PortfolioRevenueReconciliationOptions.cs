namespace Northstar.Operations.Options;

public sealed class PortfolioRevenueReconciliationOptions
{
    public const string SectionName = "BusinessActivities:PortfolioRevenueReconciliation";

    public bool Enabled { get; set; }

    public int WorkerCount { get; set; } = 2;

    public int HistoryYears { get; set; } = 10;

    public int MinimumDelayMilliseconds { get; set; } = 250;

    public int MaximumDelayMilliseconds { get; set; } = 1000;

    public int RunDurationSeconds { get; set; }
}
