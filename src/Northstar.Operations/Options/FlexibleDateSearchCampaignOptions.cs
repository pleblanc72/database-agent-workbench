namespace Northstar.Operations.Options;

public sealed class FlexibleDateSearchCampaignOptions
{
    public const string SectionName = "BusinessActivities:FlexibleDateSearchCampaign";

    public bool Enabled { get; set; }

    public int WorkerCount { get; set; } = 6;

    public int SearchWindowDays { get; set; } = 30;

    public int MinimumNights { get; set; } = 1;

    public int MaximumNights { get; set; } = 3;

    public int ResultLimit { get; set; } = 250;

    public int MinimumDelayMilliseconds { get; set; }

    public int MaximumDelayMilliseconds { get; set; } = 50;

    public int RunDurationSeconds { get; set; }
}
