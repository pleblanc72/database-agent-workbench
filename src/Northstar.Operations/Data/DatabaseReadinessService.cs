using System.Data;
using Microsoft.Data.SqlClient;

namespace Northstar.Operations.Data;

public sealed class DatabaseReadinessService(SqlConnectionFactory connectionFactory)
{
    private const string ReadinessApplicationName = "Northstar Database Readiness";

    private static readonly RequiredObject[] RequiredObjects =
    [
        new("guest", "Guest", "U"),
        new("property", "Property", "U"),
        new("property", "RoomType", "U"),
        new("property", "Room", "U"),
        new("reservation", "Reservation", "U"),
        new("reservation", "ReservationRoom", "U"),
        new("reservation", "RoomInventory", "U"),
        new("reservation", "ReservationChange", "U"),
        new("billing", "Payment", "U"),
        new("billing", "PaymentTransaction", "U"),
        new("operations", "CheckIn", "U"),
        new("operations", "HousekeepingTask", "U"),
        new("reporting", "PropertyDailySummary", "U"),
        new("reporting", "GuestStayHistoryArchive", "U"),
        new("operations", "GetWorkloadBounds", "P"),
        new("reservation", "SearchAvailability", "P"),
        new("reservation", "GetReservation", "P"),
        new("reservation", "CreateReservation", "P"),
        new("reservation", "UpdateGuestCounts", "P"),
        new("reservation", "CancelReservation", "P"),
        new("billing", "ProcessNextPendingPayment", "P"),
        new("operations", "CheckInNextArrival", "P"),
        new("operations", "UpdateRoomStatus", "P"),
        new("reporting", "GetPropertyPerformance", "P"),
        new("reservation", "ApplyReservationModificationBatch", "P"),
        new("reservation", "SearchFlexibleStayOptions", "P"),
        new("reporting", "ExportGuestStayHistory", "P"),
        new("reporting", "ReconcilePortfolioRevenue", "P")
    ];

    public async Task<DatabaseReadinessResult> CheckAsync(
        DatabaseTarget target,
        CancellationToken cancellationToken)
    {
        var checks = new List<DatabaseReadinessCheck>();

        await using var connection = connectionFactory.Create(target, ReadinessApplicationName);
        try
        {
            await connection.OpenAsync(cancellationToken);
        }
        catch (SqlException exception)
        {
            checks.Add(new DatabaseReadinessCheck(
                "Connection and authentication",
                "Failed",
                exception.Message));
            return CreateResult(target, checks);
        }

        var actualTarget = new DatabaseTarget(connection.DataSource, connection.Database);
        var identityMatches =
            string.Equals(connection.Database, target.Database, StringComparison.OrdinalIgnoreCase);
        checks.Add(new DatabaseReadinessCheck(
            "Connection and database identity",
            identityMatches ? "Passed" : "Failed",
            identityMatches
                ? $"Connected to {connection.DataSource} / {connection.Database}."
                : $"The connection opened database '{connection.Database}' instead of '{target.Database}'."));

        var assetsReady = await CheckRequiredObjectsAsync(connection, checks, cancellationToken);
        if (assetsReady)
        {
            await CheckWorkloadDataAsync(connection, checks, cancellationToken);
            await CheckArchiveDataAsync(connection, checks, cancellationToken);
        }

        await CheckMonitoringAccessAsync(connection, checks, cancellationToken);
        return CreateResult(actualTarget, checks);
    }

    private static async Task<bool> CheckRequiredObjectsAsync(
        SqlConnection connection,
        List<DatabaseReadinessCheck> checks,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT
                schemaInfo.name AS SchemaName,
                objectInfo.name AS ObjectName,
                objectInfo.type AS ObjectType
            FROM sys.objects AS objectInfo
            JOIN sys.schemas AS schemaInfo
                ON schemaInfo.schema_id = objectInfo.schema_id
            WHERE objectInfo.type IN ('U', 'P');
            """;

        var objects = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        {
            await using var command = new SqlCommand(sql, connection) { CommandTimeout = 30 };
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                objects.Add(CreateObjectKey(
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetString(2).Trim()));
            }
        }

        var missingObjects = RequiredObjects
            .Where(required => !objects.Contains(CreateObjectKey(
                required.Schema,
                required.Name,
                required.Type)))
            .Select(required => $"{required.Schema}.{required.Name}")
            .ToArray();

        if (missingObjects.Length > 0)
        {
            checks.Add(new DatabaseReadinessCheck(
                "Required database assets",
                "Failed",
                $"Missing: {string.Join(", ", missingObjects)}."));
            return false;
        }

        checks.Add(new DatabaseReadinessCheck(
            "Required database assets",
            "Passed",
            $"All {RequiredObjects.Length} required tables and stored procedures are present."));

        var procedureNames = RequiredObjects
            .Where(required => required.Type == "P")
            .Select(required => $"{required.Schema}.{required.Name}")
            .ToArray();
        var inaccessibleProcedures = new List<string>();

        foreach (var procedureName in procedureNames)
        {
            await using var permissionCommand = new SqlCommand(
                "SELECT HAS_PERMS_BY_NAME(@ProcedureName, 'OBJECT', 'EXECUTE');",
                connection);
            permissionCommand.Parameters.Add(
                new SqlParameter("@ProcedureName", SqlDbType.NVarChar, 257)
                {
                    Value = procedureName
                });
            var permission = await permissionCommand.ExecuteScalarAsync(cancellationToken);
            if (permission is not 1)
            {
                inaccessibleProcedures.Add(procedureName);
            }
        }

        checks.Add(inaccessibleProcedures.Count == 0
            ? new DatabaseReadinessCheck(
                "Stored procedure permissions",
                "Passed",
                "The application identity can execute every required stored procedure.")
            : new DatabaseReadinessCheck(
                "Stored procedure permissions",
                "Failed",
                $"EXECUTE permission is missing for: {string.Join(", ", inaccessibleProcedures)}."));

        return inaccessibleProcedures.Count == 0;
    }

    private static async Task CheckWorkloadDataAsync(
        SqlConnection connection,
        List<DatabaseReadinessCheck> checks,
        CancellationToken cancellationToken)
    {
        await using var command = new SqlCommand("operations.GetWorkloadBounds", connection)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 30
        };
        await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SingleRow, cancellationToken);

        var populated = await reader.ReadAsync(cancellationToken)
            && reader.FieldCount >= 6
            && !Enumerable.Range(0, reader.FieldCount).Any(reader.IsDBNull);
        checks.Add(new DatabaseReadinessCheck(
            "Core workload data",
            populated ? "Passed" : "Failed",
            populated
                ? "Properties, guests, rooms, reservations, and inventory have usable workload bounds."
                : "The database does not contain the populated Phase 1 data required by the workloads."));
    }

    private static async Task CheckArchiveDataAsync(
        SqlConnection connection,
        List<DatabaseReadinessCheck> checks,
        CancellationToken cancellationToken)
    {
        await using var command = new SqlCommand(
            "SELECT IIF(EXISTS (SELECT 1 FROM reporting.GuestStayHistoryArchive), 1, 0);",
            connection)
        {
            CommandTimeout = 30
        };
        var hasArchiveData = Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken)) == 1;
        checks.Add(new DatabaseReadinessCheck(
            "Historical archive data",
            hasArchiveData ? "Passed" : "Warning",
            hasArchiveData
                ? "Guest stay history is available for export and reconciliation loads."
                : "The archive is empty; the loads can start, but historical export and reconciliation results will be limited."));
    }

    private static async Task CheckMonitoringAccessAsync(
        SqlConnection connection,
        List<DatabaseReadinessCheck> checks,
        CancellationToken cancellationToken)
    {
        const string sql = """
            SELECT TOP (1) session_id FROM sys.dm_exec_requests;
            SELECT TOP (1) avg_cpu_percent FROM sys.dm_db_resource_stats;
            """;

        try
        {
            await using var command = new SqlCommand(sql, connection) { CommandTimeout = 30 };
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            do
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                }
            }
            while (await reader.NextResultAsync(cancellationToken));

            checks.Add(new DatabaseReadinessCheck(
                "Operations monitoring access",
                "Passed",
                "Database activity and threshold telemetry are accessible."));
        }
        catch (SqlException exception)
        {
            checks.Add(new DatabaseReadinessCheck(
                "Operations monitoring access",
                "Warning",
                $"Loads can run, but some console or threshold metrics may be unavailable: {exception.Message}"));
        }
    }

    private static DatabaseReadinessResult CreateResult(
        DatabaseTarget target,
        IReadOnlyList<DatabaseReadinessCheck> checks)
    {
        return new DatabaseReadinessResult(
            checks.All(check => check.Status != "Failed"),
            target,
            checks,
            DateTimeOffset.UtcNow);
    }

    private static string CreateObjectKey(string schema, string name, string type)
    {
        return $"{schema}.{name}:{type}";
    }

    private sealed record RequiredObject(string Schema, string Name, string Type);
}

public sealed record DatabaseReadinessResult(
    bool Ready,
    DatabaseTarget Target,
    IReadOnlyList<DatabaseReadinessCheck> Checks,
    DateTimeOffset CheckedAt);

public sealed record DatabaseReadinessCheck(
    string Name,
    string Status,
    string Message);
