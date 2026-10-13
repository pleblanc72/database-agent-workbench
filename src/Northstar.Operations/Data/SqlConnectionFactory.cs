using Microsoft.Data.SqlClient;

namespace Northstar.Operations.Data;

public sealed class SqlConnectionFactory
{
    private string _connectionString;

    public SqlConnectionFactory(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("Northstar")
            ?? throw new InvalidOperationException(
                "Connection string 'Northstar' is required. Configure it with user secrets or environment variables.");

        if (string.IsNullOrWhiteSpace(_connectionString))
        {
            throw new InvalidOperationException(
                "Connection string 'Northstar' is empty. Configure it with user secrets or environment variables.");
        }
    }

    public DatabaseTarget GetCurrentTarget()
    {
        var builder = new SqlConnectionStringBuilder(Volatile.Read(ref _connectionString));
        return new DatabaseTarget(builder.DataSource, builder.InitialCatalog);
    }

    public SqlConnection Create(string applicationName)
    {
        var builder = new SqlConnectionStringBuilder(Volatile.Read(ref _connectionString))
        {
            ApplicationName = applicationName
        };

        return new SqlConnection(builder.ConnectionString);
    }

    public SqlConnection Create(
        DatabaseTarget target,
        string applicationName)
    {
        var builder = CreateTargetBuilder(target);
        builder.ApplicationName = applicationName;
        return new SqlConnection(builder.ConnectionString);
    }

    public void UseTarget(DatabaseTarget target)
    {
        var builder = CreateTargetBuilder(target);
        Volatile.Write(ref _connectionString, builder.ConnectionString);
    }

    public static DatabaseTarget ValidateTarget(string? server, string? database)
    {
        var normalizedServer = server?.Trim();
        var normalizedDatabase = database?.Trim();

        if (string.IsNullOrWhiteSpace(normalizedServer))
        {
            throw new ArgumentException("Server is required.", nameof(server));
        }

        if (normalizedServer.Length > 256 || normalizedServer.Any(char.IsControl))
        {
            throw new ArgumentException("Server must be 256 characters or fewer and contain no control characters.", nameof(server));
        }

        if (string.IsNullOrWhiteSpace(normalizedDatabase))
        {
            throw new ArgumentException("Database is required.", nameof(database));
        }

        if (normalizedDatabase.Length > 128 || normalizedDatabase.Any(char.IsControl))
        {
            throw new ArgumentException("Database must be 128 characters or fewer and contain no control characters.", nameof(database));
        }

        return new DatabaseTarget(normalizedServer, normalizedDatabase);
    }

    private SqlConnectionStringBuilder CreateTargetBuilder(DatabaseTarget target)
    {
        var builder = new SqlConnectionStringBuilder(Volatile.Read(ref _connectionString))
        {
            DataSource = target.Server,
            InitialCatalog = target.Database
        };

        return builder;
    }
}

public sealed record DatabaseTarget(string Server, string Database);
