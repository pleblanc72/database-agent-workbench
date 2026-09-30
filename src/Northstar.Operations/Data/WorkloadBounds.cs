namespace Northstar.Operations.Data;

public sealed record WorkloadBounds(
    int MinimumPropertyId,
    int MaximumPropertyId,
    long MinimumGuestId,
    long MaximumGuestId,
    int MinimumRoomId,
    int MaximumRoomId,
    long MinimumReservationId,
    long MaximumReservationId);
