# Northstar Reservations

Northstar Reservations is a production-shaped hotel reservation sample for Azure SQL Database. It is designed to produce believable operational activity that can be explored with database monitoring and diagnostic tools.

## Current scope

Phases 1 through 7 are implemented. The repository contains:

- six domain schemas and fourteen operational/reporting tables
- keys, integrity constraints, baseline indexes, and row-version columns
- deterministic room-type reference data
- configurable, set-based generation of properties, rooms, guests, reservations, inventory, payments, stays, housekeeping work, and daily summaries
- normal application stored procedures for search, retrieval, creation, modification, cancellation, payments, check-in, room status, and property performance
- an ASP.NET Core normal-workload host with configurable concurrent workers
- a web operations console with normal-workload controls, live database activity, and runtime database-target switching
- independently controlled blocking, CPU, storage-I/O, and long-running-request business activities
- read-only database readiness checks for required assets, data, permissions, and monitoring access
- realistic SQL connection application names and structured logging
- SQL validation for the database foundation and normal workload

All four special business activities are implemented and independently controlled.

## Repository layout

```text
database/
  01-schema.sql
  02-reference-data.sql
  03-generate-data.sql
  04-application-procedures.sql
  05-reservation-modification-surge.sql
  06-flexible-date-search-campaign.sql
  07-guest-stay-history-export.sql
  08-generate-guest-history-archive.sql
  09-portfolio-revenue-reconciliation.sql
  validation/
    01-phase-1-validation.sql
    02-phase-2-validation.sql
    03-phase-4-validation.sql
    04-phase-5-validation.sql
    05-phase-6-validation.sql
    06-phase-7-validation.sql
src/
  Northstar.Operations/
docs/
  architecture.md
  validation.md
```

## Requirements

- Azure SQL Database or a compatible SQL Server instance
- A database principal allowed to create schemas, tables, constraints, and indexes
- An application identity allowed to execute the workload procedures and read the monitoring views used by the console
- .NET 10 SDK
- A SQL client that supports batch separators (`GO`), such as SQL Server Management Studio, Azure Data Studio, the VS Code MSSQL extension, or `sqlcmd`

No credentials or server names are stored in this repository.

## Start the application

Run all commands from the repository root.

### First-time local setup

Restore and build the application:

```powershell
dotnet restore "src\Northstar.Operations\Northstar.Operations.csproj"
dotnet build "src\Northstar.Operations\Northstar.Operations.csproj" --configuration Release
```

Configure the Azure SQL connection through .NET user secrets. Replace the placeholders with your server and database:

```powershell
dotnet user-secrets --project "src\Northstar.Operations\Northstar.Operations.csproj" set `
  "ConnectionStrings:Northstar" `
  "Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
```

This connection string contains no password. `Active Directory Default` uses the current Microsoft Entra sign-in available to the local development environment.

### Start the operations console

```powershell
dotnet run --project "src\Northstar.Operations\Northstar.Operations.csproj" `
  --configuration Release --no-build
```

Wait for the following output:

```text
Now listening on: http://localhost:5055
```

Open [http://localhost:5055](http://localhost:5055) in a browser. Keep the terminal running while using the console. Select **Start workload** to begin normal reservation activity and **Stop workload** to stop it without shutting down the console.

### Switch the server and database

Use the **Database target** panel at the top of the operations console to change targets without restarting the application.

Enter the SQL host and database as separate values:

| Field | Example | Notes |
|---|---|---|
| **Server** | `agentservertest.database.windows.net` | A SQL Server host name, not an `https://` URL. `tcp:agentservertest.database.windows.net,1433` is also valid. |
| **Database** | `hotel_reservations` | The exact database name on that server. |

To switch:

1. Enter the new value in **Server**.
2. Enter the matching value in **Database**.
3. Select **Check readiness**.
4. Review every result. Required checks must pass; warnings explain limited optional behavior.
5. Select **Switch database** and confirm the prompt.
6. Verify **Current target** displays the requested server/database combination.
7. Start the desired workload. A switch never starts workloads automatically.

The current target remains active if readiness fails. A successful switch stops and drains all running workloads before changing the target, then leaves them stopped.

The panel changes only the server and database. It reuses authentication, encryption, timeout, and other connection settings from `ConnectionStrings:Northstar`. For example, when the configured connection uses `Authentication=Active Directory Default`, the current Microsoft Entra identity must already have access to the new server and database. If a target requires different authentication settings, update the secure connection configuration and restart the application instead of using the panel.

Credentials, connection strings, and tokens are never sent to the browser. The selected target lasts for the current application process; restarting the app restores the server and database from `ConnectionStrings:Northstar`.

Readiness is required before a switch. The application checks:

- connection and database identity
- all fourteen required tables and fourteen required stored procedures
- `EXECUTE` permission for every workload procedure
- populated core workload bounds
- retained guest-stay archive data
- access to database activity and Azure SQL resource telemetry

A failed required check leaves the current target unchanged. An empty historical archive is reported as a warning because the loads can start, but export and reconciliation results will be limited. Switching is blocked while threshold validation is running. The application never deploys missing database objects automatically.

Press `Ctrl+C` in the terminal to shut down the application. If the browser reports that it cannot reach the page, confirm that the `dotnet run` command is still running and use the exact URL printed after `Now listening on:`.

For subsequent runs, only the `dotnet run` command is required unless the database connection or application dependencies change.

## Phase 1 setup

Run these scripts against an empty database in order:

1. `database/01-schema.sql`
2. `database/02-reference-data.sql`
3. Review the configuration variables at the top of `database/03-generate-data.sql`, then run it.
4. Run `database/validation/01-phase-1-validation.sql`.

The default generator creates 40 properties, 3,000 rooms, 50,000 guests, 200,000 reservations, and 731 inventory days per room. For a quicker development run, lower the guest and reservation counts while retaining at least 25 properties.

The generator is intentionally append-safe: it stops if operational data already exists. Use a fresh database to regenerate a different data volume.

See [validation guidance](docs/validation.md) for concrete execution and expected results.

## Phase 2 setup

Deploy the application procedures:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\04-application-procedures.sql" -b
```

Configure the connection without storing credentials in source:

```powershell
dotnet user-secrets --project "src\Northstar.Operations" set `
  "ConnectionStrings:Northstar" `
  "Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;"
```

Start the normal workload immediately when the host launches:

```powershell
dotnet run --project "src\Northstar.Operations\Northstar.Operations.csproj" -- `
  --Workload:Enabled=true
```

The default workload uses four workers with a randomized 500–1,200 ms delay between operations. Set `Workload:RunDurationSeconds` to a positive value for a bounded validation run.

## Phase 3 operations console

Start the host with the workload initially stopped:

```powershell
dotnet run --project "src\Northstar.Operations\Northstar.Operations.csproj"
```

Open the URL shown in the application output, normally `http://localhost:5055`. The console provides:

- ad-hoc server and database readiness checks and runtime switching
- normal workload start and stop controls
- normal-workload requests per minute, workers, completions, and failures
- database-wide active and blocked request counts
- database-wide longest active request
- activity-specific workers, throughput per minute, completions, and failures

The console refreshes every two seconds. Normal-workload metrics change only when the normal workload is running. Database activity metrics include the normal workload and all business activities. A configured positive run duration stops the workload when reached but keeps the console running.

The database-target API is also available for automation:

```powershell
$target = @{
  server = "tcp:<server>.database.windows.net,1433"
  database = "<database>"
} | ConvertTo-Json

Invoke-RestMethod "http://localhost:5055/api/database-target"
Invoke-RestMethod "http://localhost:5055/api/database-target/check" `
  -Method Post -ContentType "application/json" -Body $target
Invoke-RestMethod "http://localhost:5055/api/database-target/switch" `
  -Method Post -ContentType "application/json" -Body $target
```

The check endpoint is read-only. The switch endpoint repeats readiness checks, stops and drains every running workload, changes the target atomically, and leaves all workloads stopped. It returns HTTP `409 Conflict` when readiness fails or threshold validation is active, and HTTP `400 Bad Request` for an invalid server or database value.

Each business-activity card identifies the database threshold it is designed to trigger. Select **Run validation** to execute its fixed threshold validation through the application's configured database connection. If the activity is stopped, validation starts it automatically and stops it when sampling finishes. An activity that was already running is left running. Validation runs in the background and the card reports **Starting**, **Running**, **Passed**, or **Failed** without requiring `sqlcmd`. Only one threshold validation runs at a time, and an activity cannot be stopped from the card while its validation is collecting samples. The normal workload does not need to be running.

## Phase 4 Reservation Modification Surge

Phase 4 is deployed independently from the operations console. It produces concurrent reservation and room-inventory modifications across an overlapping property and date window.

Deploy the Phase 4 database objects:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\05-reservation-modification-surge.sql" -b
```

Start the application, then start the activity:

```powershell
Invoke-RestMethod `
  "http://localhost:5055/api/activities/reservation-modification-surge/start" `
  -Method Post
```

Check status:

```powershell
Invoke-RestMethod `
  "http://localhost:5055/api/activities/reservation-modification-surge/status"
```

Stop the activity:

```powershell
Invoke-RestMethod `
  "http://localhost:5055/api/activities/reservation-modification-surge/stop" `
  -Method Post
```

Select **Run validation** while the activity is running. It collects four blocking samples over approximately one minute and enforces the blocking threshold. The equivalent command-line fallback is:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\03-phase-4-validation.sql" -b
```

The default configuration uses 16 workers against one property. This activity intentionally creates significant database contention and should be used only on the dedicated Northstar sample database.

The operations console includes a **Reservation Modification Surge** card with start, stop, state, active-worker, batches-per-minute, completed-batch, and failure metrics. Future business activities will use the same card, control, and throughput pattern as they are implemented.

## Phase 5 Flexible Date Search Campaign

Deploy the Phase 5 search procedure:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\06-flexible-date-search-campaign.sql" -b
```

Use the **Flexible Date Search Campaign** card in the operations console to start and stop the activity. The card displays:

- active search workers
- searches per minute
- completed searches
- failed searches

The activity can also be controlled through:

```powershell
Invoke-RestMethod `
  "http://localhost:5055/api/activities/flexible-date-search-campaign/start" `
  -Method Post

Invoke-RestMethod `
  "http://localhost:5055/api/activities/flexible-date-search-campaign/stop" `
  -Method Post
```

The default configuration uses six workers performing portfolio-wide searches across a 30-day flexible arrival window and one-to-three-night stays. This activity intentionally consumes substantial database compute and should run only on the dedicated Northstar sample database.

Select **Run validation** while the campaign is running. It checks the recent Azure SQL CPU samples. The equivalent command-line fallback is:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\04-phase-5-validation.sql" -b
```

## Phase 6 Guest Stay History Export

Deploy the export schema and procedure, then generate the historical archive:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\07-guest-stay-history-export.sql" -b

sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\08-generate-guest-history-archive.sql" -b
```

The calibrated generator creates ten archived stay-document versions per reservation, approximately 12 GB with the default Phase 1 volume. It commits in batches and safely resumes missing batches if interrupted. Review its configuration before running it on a differently sized or billed database.

Start **Guest Stay History Export** from its operations-console card. The default eight workers partition guests so they stream separate parts of the export. Select **Run validation** to execute the two-minute storage sampler. The equivalent command-line fallback is:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\05-phase-6-validation.sql" -b
```

Stop the activity after validation. The card reports:

- active export workers
- rows per minute
- exported rows
- failed exports

This activity intentionally scans a historical archive larger than the calibrated database buffer pool. Run it only on the dedicated Northstar sample database.

## Phase 7 Portfolio Revenue Reconciliation

Deploy the reconciliation procedure:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\09-portfolio-revenue-reconciliation.sql" -b
```

Start **Portfolio Revenue Reconciliation** from its operations-console card. Two workers partition the property portfolio and reconcile retained stay evidence against nightly revenue, taxes, payments, payment transactions, refunds, and daily reporting summaries.

While the card shows **Running**, select **Run validation**. The card shows progress during the eight-minute calibrated observation. The equivalent command-line fallback is:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\06-phase-7-validation.sql" -b
```

The validation lasts eight minutes so it observes a complete reconciliation cycle. Stop the activity after validation. Its card reports:

- active reconciliation workers
- reconciliations per minute
- completed reconciliations
- failed reconciliations

Portfolio Revenue Reconciliation reads and hashes the retained archive and creates indexed accounting worksets in `tempdb`. It intentionally produces a long-running database operation and should run only on the dedicated Northstar sample database.
