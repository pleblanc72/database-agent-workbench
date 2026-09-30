# Validation

## Operations-console validation

Every business-activity card shows the threshold it triggers and provides a **Run validation** button. The button executes the corresponding allowlisted SQL validation through `Microsoft.Data.SqlClient`; it does not launch a shell or accept user-provided SQL. Scripts are packaged with the application, and credentials continue to come from the configured connection string and Microsoft Entra authentication.

Select **Run validation** whether the activity is running or stopped. If needed, the application starts that activity, waits for its database sessions to initialize, performs validation, and stops the activity afterward. If the activity was already running, validation leaves it running. The normal workload may remain stopped. Validation status remains visible on the card:

- Reservation Modification Surge: approximately one minute
- Flexible Date Search Campaign: checks recent CPU samples immediately
- Guest Stay History Export: approximately two minutes
- Portfolio Revenue Reconciliation: eight minutes

Only one validation can run at a time. The activity's **Stop** button is disabled while its validation is running so the sample window is not interrupted. The `sqlcmd` examples below remain available for automation and troubleshooting.

## Phase 1 execution

Create or select an empty Azure SQL Database or SQL Server database. Connect with a principal that can create schemas and tables, then run:

1. `database/01-schema.sql`
2. `database/02-reference-data.sql`
3. `database/03-generate-data.sql`
4. `database/validation/01-phase-1-validation.sql`

When using `sqlcmd`, set connection details through your normal secure environment and run each file independently. For example, with Microsoft Entra authentication:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\01-schema.sql" -b
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\02-reference-data.sql" -b
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\03-generate-data.sql" -b
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\validation\01-phase-1-validation.sql" -b
```

The `-b` option makes `sqlcmd` return a failure exit code when SQL reports an error.

## Expected default volumes

| Entity | Expected count |
|---|---:|
| Properties | 40 |
| Rooms | 3,000 |
| Guests | 50,000 |
| Reservations | 200,000 |
| Reservation rooms | 200,000 |
| Room inventory rows | 2,193,000 |
| Payments | 200,000 |
| Housekeeping tasks | 3,000 |
| Property daily summaries | 7,240 |

Payment-transaction and check-in counts vary by generated reservation status. Counts also change when generator variables are adjusted.

## Automated checks

The validation script:

- lists all six expected schemas and their table counts
- reports row counts for the major tables
- confirms foreign keys are enabled and trusted
- checks for orphaned reservations, reservation rooms, and payments
- confirms linked room inventory falls inside its stay dates
- detects overlapping active seeded stays
- verifies the supported property range and availability-search index
- runs a representative future availability aggregation

The script throws an error if an integrity check fails. Successful execution ends with:

```text
Phase 1 validation completed successfully.
```

## Focused manual checks

Confirm each property received the configured number of rooms:

```sql
SELECT
    p.PropertyCode,
    COUNT(*) AS RoomCount
FROM property.Property AS p
JOIN property.Room AS r ON r.PropertyId = p.PropertyId
GROUP BY p.PropertyCode
ORDER BY p.PropertyCode;
```

Inspect reservation status and date distribution:

```sql
SELECT
    ReservationStatus,
    MIN(ArrivalDate) AS FirstArrival,
    MAX(DepartureDate) AS LastDeparture,
    COUNT_BIG(*) AS ReservationCount
FROM reservation.Reservation
GROUP BY ReservationStatus
ORDER BY ReservationStatus;
```

Confirm inventory is unique by room and date:

```sql
SELECT RoomId, InventoryDate, COUNT(*) AS DuplicateCount
FROM reservation.RoomInventory
GROUP BY RoomId, InventoryDate
HAVING COUNT(*) > 1;
```

The final query must return no rows.

## Independent script behavior

- `01-schema.sql` is a fresh-database installation script.
- `02-reference-data.sql` is independently rerunnable and updates the fixed room-type catalog.
- `03-generate-data.sql` is configurable but intentionally refuses to append to populated operational tables.
- `01-phase-1-validation.sql` is read-only except for its in-memory check table and can be rerun at any time.

To validate a different generation profile, create a fresh database, change only the declared configuration values at the top of `03-generate-data.sql`, and execute the sequence again.

## Phase 2 validation

Deploy the normal application procedures:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\04-application-procedures.sql" -b
```

Build the workload host:

```powershell
dotnet build "src\Northstar.Operations\Northstar.Operations.csproj" --configuration Release
```

Configure `ConnectionStrings:Northstar` through user secrets or the `ConnectionStrings__Northstar` environment variable. A Microsoft Entra connection string can use:

```text
Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;
```

Run a bounded workload:

```powershell
dotnet run --project "src\Northstar.Operations\Northstar.Operations.csproj" `
  --configuration Release --no-build -- `
  --Workload:Enabled=true `
  --Workload:WorkerCount=4 `
  --Workload:RunDurationSeconds=30
```

Expected logs include the worker count, delay range, configured-duration completion, and workload shutdown. The web host remains available after a bounded workload stops. SQL failures are logged with worker, operation, and SQL error number.

Run the Phase 2 database checks:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G -i "database\validation\02-phase-2-validation.sql" -b
```

The script confirms:

- all ten normal application procedures are deployed
- workload-created reservations have room and payment records
- active workload reservations own the expected inventory dates
- recognizable application connection names are present when the host is running
- current active and blocked request counts

Successful execution ends with:

```text
Phase 2 validation completed successfully.
```

## Phase 3 validation

Build and start the operations console:

```powershell
dotnet build "src\Northstar.Operations\Northstar.Operations.csproj" --configuration Release
dotnet run --project "src\Northstar.Operations\Northstar.Operations.csproj" `
  --configuration Release --no-build
```

Open the URL reported by ASP.NET Core. Confirm the page title is **Northstar Reservations | Operations Console** and the initial workload state is **Stopped**.

Select **Start workload** and verify:

- state changes to **Running**
- active workers matches the configured worker count
- completed requests and requests per minute begin increasing
- active and blocked request metrics continue refreshing
- no failures appear during a normal bounded observation

The **Normal workload metrics** section must remain scoped to the normal workload. Starting a business activity by itself must not increase normal requests per minute, normal workers, or normal completions.

Select **Stop workload** and verify:

- state returns to **Stopped**
- active workers returns to zero
- the host and console remain available
- completed and failure totals remain visible for the last run

The same behavior can be validated from PowerShell:

```powershell
Invoke-RestMethod "http://localhost:5055/api/operations/status"
Invoke-RestMethod "http://localhost:5055/api/operations/workload/start" -Method Post
Start-Sleep -Seconds 10
Invoke-RestMethod "http://localhost:5055/api/operations/status"
Invoke-RestMethod "http://localhost:5055/api/operations/workload/stop" -Method Post
Invoke-RestMethod "http://localhost:5055/api/operations/status"
```

During a normal run, `BlockedRequestCount` should remain zero or transient and `LongestActiveRequestSeconds` should remain short. Phase 3 does not tune or initiate any special business activity.

## Phase 4 validation

Deploy the activity objects:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\05-reservation-modification-surge.sql" -b
```

Start the application with the normal workload stopped, then start Reservation Modification Surge through its independent endpoint:

```powershell
Invoke-RestMethod `
  "http://localhost:5055/api/activities/reservation-modification-surge/start" `
  -Method Post
```

Alternatively, select **Start** on the **Reservation Modification Surge** card in the operations console. The card must change to **Running**, show 16 active workers by default, and begin increasing completed batches.

After at least two refresh intervals, **Batches per minute** must become positive. While the normal workload remains stopped:

- normal workload metrics remain zero or retain the latest normal-run totals
- database activity reflects the surge sessions
- the surge card reports its own workers, batch rate, completed batches, and failures

While the activity runs, sample its user sessions:

```sql
SELECT
    COUNT(*) AS ActiveRequests,
    SUM(CASE WHEN request.blocking_session_id > 0 THEN 1 ELSE 0 END) AS BlockedRequests,
    MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())) AS LongestRequestSeconds
FROM sys.dm_exec_requests AS request
JOIN sys.dm_exec_sessions AS sessionInfo
    ON sessionInfo.session_id = request.session_id
WHERE request.database_id = DB_ID()
    AND sessionInfo.program_name = 'Northstar Reservation Management';
```

Capture at least three samples using the same cadence as the monitoring system. The target is:

- at least three positive blocked-request samples
- the latest sample remains above zero while the activity runs

Stop the activity:

```powershell
Invoke-RestMethod `
  "http://localhost:5055/api/activities/reservation-modification-surge/stop" `
  -Method Post
```

The console **Stop** button performs the same operation. After stopping, the card must show **Stopped**, zero active workers, and retain the completed-batch and failure totals from the run.

Run the integrity validation:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\03-phase-4-validation.sql" -b
```

### Recorded Phase 4 result

The default configuration was calibrated against the project Azure SQL database on September 24, 2026:

- 12 consecutive samples contained blocked requests
- the latest sample contained 15 blocked requests
- observed blocked requests ranged from 14 to 15
- 16 activity requests remained active during most samples
- 99 client-confirmed batches completed with zero application failures
- 100 database batches committed and recorded 15,000 audit rows
- 837 distinct reservations were modified
- audit integrity failures: zero
- no activity sessions remained after stop

The configured server is not currently registered in the available external monitoring collector, so the result was measured directly from Azure SQL dynamic management views. Confirm the named `Processes blocked` telemetry samples in the intended monitoring product before a final presentation.

## Phase 5 validation

Deploy the flexible-date search procedure:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\06-flexible-date-search-campaign.sql" -b
```

Start **Flexible Date Search Campaign** from its console card. Confirm:

- state changes to **Running**
- active workers reaches six by default
- completed searches and searches per minute begin increasing
- database-wide activity changes while normal-workload metrics remain separately scoped

Azure SQL database resource statistics are sampled every 15 seconds. The requirement is at least three samples where average CPU is at or above 80 percent:

```sql
SELECT TOP (12)
    end_time,
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

Stop the campaign from its console card, then run:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\04-phase-5-validation.sql" -b
```

The validation script fails unless at least three of the latest twelve resource-stat samples meet the 80 percent target.

### Recorded Phase 5 result

The default profile was calibrated on the `GP_Gen5_2` project database on September 24, 2026:

- eight consecutive observed samples exceeded 80 percent CPU
- observed average CPU ranged from 99.52 to 99.79 percent
- the final validation window contained ten qualifying samples
- 12 searches completed during the calibration run
- application failures: zero
- CPU recovered to 20.08 percent in the first post-stop sample
- no campaign sessions remained after stop

The full 120-day, one-to-seven-night search profile took approximately 80 seconds for one request. The calibrated 30-day, one-to-three-night profile took approximately 12 seconds for one request before concurrency and was selected to sustain utilization while still completing work.

## Phase 6 validation

Deploy the archive schema and export procedure, then generate the calibrated archive:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\07-guest-stay-history-export.sql" -b
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\08-generate-guest-history-archive.sql" -b
```

With the default 200,000 reservations, the generator creates 2,000,000 retained stay documents with approximately 12 GB of payload. Generation commits every 5,000 reservations and can be rerun after interruption; already completed reservation/sequence pairs are skipped.

Start **Guest Stay History Export** from the operations console. Confirm:

- state changes to **Running**
- active workers reaches eight by default
- exported rows and rows per minute begin increasing
- failed exports remains zero
- normal-workload metrics remain separately scoped

Run the validation while the export remains active:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\05-phase-6-validation.sql" -b
```

The script first verifies the procedure, archive, calibrated row volume, and active export sessions. It then records eight 15-second samples from `sys.dm_io_virtual_file_stats` and `sys.dm_db_wait_stats`. It fails unless:

- at least three samples have read IOPS at or above 5
- and either at least three samples have average read latency at or above 50 ms
- or at least three samples have average read latency at or above 20 ms and at least three have PAGEIOLATCH pressure at or above 100 wait-ms/sec

After the script succeeds, stop the activity from its console card. Confirm it shows **Stopped**, active workers returns to zero, exported-row totals remain visible, failures remain zero, and no active `Northstar Reporting Export` requests remain. Sleeping connections can remain temporarily because SQL client connection pooling is enabled.

### Recorded Phase 6 result

The default profile was calibrated on the `GP_Gen5_2` project database on September 24, 2026:

- 2,002,470 retained stay documents were generated
- document payload totaled 12,014,820,000 bytes
- the archive reserved 15,745.29 MB including indexes and allocation overhead
- all eight final samples exceeded 5 read IOPS
- observed read IOPS ranged from 141.00 to 340.20
- all eight samples exceeded 20 ms average read latency
- observed average read latency ranged from 21.86 to 63.16 ms
- five samples exceeded 100 PAGEIOLATCH wait-ms/sec
- observed qualifying PAGEIOLATCH pressure ranged from 159.87 to 3,012.20 wait-ms/sec
- 10 export partitions completed and reported 463,157 exported rows
- application failures: zero
- no active export requests remained after stop

The final profile therefore satisfied the second allowed threshold path: sustained read IOPS, at least three latency samples at or above 20 ms, and at least three PAGEIOLATCH samples at or above 100 wait-ms/sec.

## Phase 7 validation

Deploy the portfolio reconciliation procedure:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\09-portfolio-revenue-reconciliation.sql" -b
```

Start **Portfolio Revenue Reconciliation** from the operations console. Confirm:

- state changes to **Running**
- active workers reaches two by default
- the database-wide longest request increases
- completed reconciliations eventually increase
- failed reconciliations remains zero
- normal-workload metrics remain separately scoped

Run the validation while reconciliation remains active:

```powershell
sqlcmd -S "<server>.database.windows.net" -d "<database>" -G `
  -i "database\validation\06-phase-7-validation.sql" -b
```

The script records nine observations over eight minutes. It fails unless:

- the observation window spans at least five minutes
- reconciliation is running, runnable, or suspended in at least three one-minute bins
- reconciliation is observed within two minutes of the window end
- at least three one-minute samples reach 500 wait-ms/sec

After validation succeeds, stop the activity. Confirm the card shows **Stopped**, active workers returns to zero, totals remain visible, failures remain zero, and no active `Northstar Revenue Reconciliation` requests remain.

### Recorded Phase 7 result

The default profile was calibrated on the `GP_Gen5_2` project database on September 24, 2026:

- the observation window spanned eight minutes
- active reconciliation requests were present in seven of nine observations
- reconciliation was present in the final observation
- three one-minute samples exceeded 500 wait-ms/sec
- qualifying wait rates were 4,022.65, 4,019.22, and 4,017.07 wait-ms/sec
- 12 reconciliations completed during the full calibration run
- application failures: zero
- no active reconciliation requests remained after stop
