namespace Northstar.Operations.Data;

public sealed record DatabaseActivity(
    int ActiveRequestCount,
    int BlockedRequestCount,
    int LongestActiveRequestSeconds);
