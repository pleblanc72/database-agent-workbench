using System.Data;
using Microsoft.Data.SqlClient;

namespace Northstar.Operations.Data;

public sealed class NorthstarRepository(SqlConnectionFactory connectionFactory)
{
    private const string ApiApplicationName = "Northstar Reservations API";
    private const string PropertyOperationsApplicationName = "Northstar Property Operations";
    private const string ReportingApplicationName = "Northstar Reporting Service";
    private const string OperationsConsoleApplicationName = "Northstar Operations Console";
    private const string ReservationManagementApplicationName = "Northstar Reservation Management";
    private const string SearchServicesApplicationName = "Northstar Search Services";
    private const string ReportingExportApplicationName = "Northstar Reporting Export";
    private const string RevenueReconciliationApplicationName = "Northstar Revenue Reconciliation";

    public async Task ReconcilePortfolioRevenueAsync(
        DateOnly periodStartDate,
        DateOnly periodEndDate,
        int partitionNumber,
        int partitionCount,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(RevenueReconciliationApplicationName);
        await using var command = CreateStoredProcedure(
            connection,
            "reporting.ReconcilePortfolioRevenue");
        command.CommandTimeout = 1200;
        command.Parameters.Add(new SqlParameter("@PeriodStartDate", SqlDbType.Date) { Value = periodStartDate });
        command.Parameters.Add(new SqlParameter("@PeriodEndDate", SqlDbType.Date) { Value = periodEndDate });
        command.Parameters.Add(new SqlParameter("@PartitionNumber", SqlDbType.Int) { Value = partitionNumber });
        command.Parameters.Add(new SqlParameter("@PartitionCount", SqlDbType.Int) { Value = partitionCount });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task<int> ExportGuestStayHistoryAsync(
        DateOnly historyStartDate,
        DateOnly historyEndDate,
        int partitionNumber,
        int partitionCount,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ReportingExportApplicationName);
        await using var command = CreateStoredProcedure(
            connection,
            "reporting.ExportGuestStayHistory");
        command.CommandTimeout = 300;
        command.Parameters.Add(new SqlParameter("@HistoryStartDate", SqlDbType.Date) { Value = historyStartDate });
        command.Parameters.Add(new SqlParameter("@HistoryEndDate", SqlDbType.Date) { Value = historyEndDate });
        command.Parameters.Add(new SqlParameter("@PartitionNumber", SqlDbType.Int) { Value = partitionNumber });
        command.Parameters.Add(new SqlParameter("@PartitionCount", SqlDbType.Int) { Value = partitionCount });
        return await ExecuteAndCountRowsAsync(connection, command, cancellationToken);
    }

    public async Task SearchFlexibleStayOptionsAsync(
        DateOnly searchStartDate,
        int searchWindowDays,
        int minimumNights,
        int maximumNights,
        int resultLimit,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(SearchServicesApplicationName);
        await using var command = CreateStoredProcedure(
            connection,
            "reservation.SearchFlexibleStayOptions");
        command.CommandTimeout = 300;
        command.Parameters.Add(new SqlParameter("@SearchStartDate", SqlDbType.Date) { Value = searchStartDate });
        command.Parameters.Add(new SqlParameter("@SearchWindowDays", SqlDbType.Int) { Value = searchWindowDays });
        command.Parameters.Add(new SqlParameter("@MinimumNights", SqlDbType.Int) { Value = minimumNights });
        command.Parameters.Add(new SqlParameter("@MaximumNights", SqlDbType.Int) { Value = maximumNights });
        command.Parameters.Add(new SqlParameter("@ResultLimit", SqlDbType.Int) { Value = resultLimit });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task ApplyReservationModificationBatchAsync(
        int propertyId,
        DateOnly windowStartDate,
        int windowDays,
        int batchSize,
        int rateAdjustmentBasisPoints,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ReservationManagementApplicationName);
        await using var command = CreateStoredProcedure(
            connection,
            "reservation.ApplyReservationModificationBatch");
        command.CommandTimeout = 120;
        command.Parameters.Add(new SqlParameter("@PropertyId", SqlDbType.Int) { Value = propertyId });
        command.Parameters.Add(new SqlParameter("@WindowStartDate", SqlDbType.Date) { Value = windowStartDate });
        command.Parameters.Add(new SqlParameter("@WindowDays", SqlDbType.Int) { Value = windowDays });
        command.Parameters.Add(new SqlParameter("@BatchSize", SqlDbType.Int) { Value = batchSize });
        command.Parameters.Add(new SqlParameter("@RateAdjustmentBasisPoints", SqlDbType.Int)
        {
            Value = rateAdjustmentBasisPoints
        });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task<DatabaseActivity> GetDatabaseActivityAsync(CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                COUNT(*) AS ActiveRequestCount,
                COALESCE(SUM(CASE WHEN request.blocking_session_id > 0 THEN 1 ELSE 0 END), 0) AS BlockedRequestCount,
                COALESCE(MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())), 0) AS LongestActiveRequestSeconds
            FROM sys.dm_exec_requests AS request
            JOIN sys.dm_exec_sessions AS sessionInfo
                ON sessionInfo.session_id = request.session_id
            WHERE request.database_id = DB_ID()
                AND request.session_id <> @@SPID
                AND sessionInfo.is_user_process = 1;
            """;

        await using var connection = connectionFactory.Create(OperationsConsoleApplicationName);
        await using var command = new SqlCommand(sql, connection) { CommandTimeout = 10 };
        await connection.OpenAsync(cancellationToken);
        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SingleRow, cancellationToken);

        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidOperationException("Database activity query returned no result.");
        }

        return new DatabaseActivity(
            reader.GetInt32(reader.GetOrdinal("ActiveRequestCount")),
            reader.GetInt32(reader.GetOrdinal("BlockedRequestCount")),
            reader.GetInt32(reader.GetOrdinal("LongestActiveRequestSeconds")));
    }

    public async Task<WorkloadBounds> GetWorkloadBoundsAsync(CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "operations.GetWorkloadBounds");
        await connection.OpenAsync(cancellationToken);
        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SingleRow, cancellationToken);

        if (!await reader.ReadAsync(cancellationToken) || Enumerable.Range(0, reader.FieldCount).Any(reader.IsDBNull))
        {
            throw new InvalidOperationException("The workload requires populated Phase 1 data.");
        }

        return new WorkloadBounds(
            reader.GetInt32(reader.GetOrdinal("MinimumPropertyId")),
            reader.GetInt32(reader.GetOrdinal("MaximumPropertyId")),
            reader.GetInt64(reader.GetOrdinal("MinimumGuestId")),
            reader.GetInt64(reader.GetOrdinal("MaximumGuestId")),
            reader.GetInt32(reader.GetOrdinal("MinimumRoomId")),
            reader.GetInt32(reader.GetOrdinal("MaximumRoomId")),
            reader.GetInt64(reader.GetOrdinal("MinimumReservationId")),
            reader.GetInt64(reader.GetOrdinal("MaximumReservationId")));
    }

    public async Task SearchAvailabilityAsync(
        int propertyId,
        DateOnly arrivalDate,
        DateOnly departureDate,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "reservation.SearchAvailability");
        command.Parameters.Add(new SqlParameter("@PropertyId", SqlDbType.Int) { Value = propertyId });
        command.Parameters.Add(new SqlParameter("@ArrivalDate", SqlDbType.Date) { Value = arrivalDate });
        command.Parameters.Add(new SqlParameter("@DepartureDate", SqlDbType.Date) { Value = departureDate });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task GetReservationAsync(long reservationId, CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "reservation.GetReservation");
        command.Parameters.Add(new SqlParameter("@ReservationId", SqlDbType.BigInt) { Value = reservationId });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task CreateReservationAsync(
        long guestId,
        int propertyId,
        DateOnly arrivalDate,
        DateOnly departureDate,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "reservation.CreateReservation");
        command.Parameters.Add(new SqlParameter("@GuestId", SqlDbType.BigInt) { Value = guestId });
        command.Parameters.Add(new SqlParameter("@PropertyId", SqlDbType.Int) { Value = propertyId });
        command.Parameters.Add(new SqlParameter("@ArrivalDate", SqlDbType.Date) { Value = arrivalDate });
        command.Parameters.Add(new SqlParameter("@DepartureDate", SqlDbType.Date) { Value = departureDate });
        command.Parameters.Add(new SqlParameter("@AdultCount", SqlDbType.TinyInt) { Value = 1 });
        command.Parameters.Add(new SqlParameter("@ChildCount", SqlDbType.TinyInt) { Value = 0 });
        command.Parameters.Add(new SqlParameter("@SourceChannel", SqlDbType.VarChar, 20) { Value = "DirectWeb" });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task UpdateGuestCountsAsync(
        long reservationId,
        byte adultCount,
        byte childCount,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "reservation.UpdateGuestCounts");
        command.Parameters.Add(new SqlParameter("@ReservationId", SqlDbType.BigInt) { Value = reservationId });
        command.Parameters.Add(new SqlParameter("@AdultCount", SqlDbType.TinyInt) { Value = adultCount });
        command.Parameters.Add(new SqlParameter("@ChildCount", SqlDbType.TinyInt) { Value = childCount });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task CancelReservationAsync(long reservationId, CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "reservation.CancelReservation");
        command.Parameters.Add(new SqlParameter("@ReservationId", SqlDbType.BigInt) { Value = reservationId });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task ProcessNextPendingPaymentAsync(CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ApiApplicationName);
        await using var command = CreateStoredProcedure(connection, "billing.ProcessNextPendingPayment");
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task CheckInNextArrivalAsync(int propertyId, CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(PropertyOperationsApplicationName);
        await using var command = CreateStoredProcedure(connection, "operations.CheckInNextArrival");
        command.Parameters.Add(new SqlParameter("@PropertyId", SqlDbType.Int) { Value = propertyId });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task UpdateRoomStatusAsync(
        int roomId,
        string roomStatus,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(PropertyOperationsApplicationName);
        await using var command = CreateStoredProcedure(connection, "operations.UpdateRoomStatus");
        command.Parameters.Add(new SqlParameter("@RoomId", SqlDbType.Int) { Value = roomId });
        command.Parameters.Add(new SqlParameter("@RoomStatus", SqlDbType.VarChar, 20) { Value = roomStatus });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    public async Task GetPropertyPerformanceAsync(
        int propertyId,
        DateOnly startDate,
        DateOnly endDate,
        CancellationToken cancellationToken)
    {
        await using var connection = connectionFactory.Create(ReportingApplicationName);
        await using var command = CreateStoredProcedure(connection, "reporting.GetPropertyPerformance");
        command.Parameters.Add(new SqlParameter("@PropertyId", SqlDbType.Int) { Value = propertyId });
        command.Parameters.Add(new SqlParameter("@StartDate", SqlDbType.Date) { Value = startDate });
        command.Parameters.Add(new SqlParameter("@EndDate", SqlDbType.Date) { Value = endDate });
        await ExecuteAndDrainAsync(connection, command, cancellationToken);
    }

    private static SqlCommand CreateStoredProcedure(SqlConnection connection, string procedureName)
    {
        return new SqlCommand(procedureName, connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 30
        };
    }

    private static async Task ExecuteAndDrainAsync(
        SqlConnection connection,
        SqlCommand command,
        CancellationToken cancellationToken)
    {
        await connection.OpenAsync(cancellationToken);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        do
        {
            while (await reader.ReadAsync(cancellationToken))
            {
            }
        }
        while (await reader.NextResultAsync(cancellationToken));
    }

    private static async Task<int> ExecuteAndCountRowsAsync(
        SqlConnection connection,
        SqlCommand command,
        CancellationToken cancellationToken)
    {
        var rowCount = 0;
        await connection.OpenAsync(cancellationToken);
        await using var reader = await command.ExecuteReaderAsync(
            CommandBehavior.SequentialAccess,
            cancellationToken);

        do
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                rowCount++;
            }
        }
        while (await reader.NextResultAsync(cancellationToken));

        return rowCount;
    }
}
