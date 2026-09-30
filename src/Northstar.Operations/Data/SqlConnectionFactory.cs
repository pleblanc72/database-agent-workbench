using Microsoft.Data.SqlClient;

namespace Northstar.Operations.Data;

public sealed class SqlConnectionFactory
{
    private readonly string _connectionString;

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

    public SqlConnection Create(string applicationName)
    {
        var builder = new SqlConnectionStringBuilder(_connectionString)
        {
            ApplicationName = applicationName
        };

        return new SqlConnection(builder.ConnectionString);
    }
}
