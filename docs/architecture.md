# Architecture

## Purpose

Northstar Reservations models a hotel platform with enough relational depth and data volume to support realistic application activity and later database-performance investigations. The implementation remains intentionally understandable for live demonstrations.

Phase 1 establishes the data model. Phase 2 adds the normal workload and its database API.

## Database domains

| Schema | Responsibility | Primary tables |
|---|---|---|
| `guest` | Guest identity and loyalty membership | `Guest` |
| `property` | Hotels, sellable room types, and physical rooms | `Property`, `RoomType`, `Room` |
| `reservation` | Booking headers, assigned rooms, and date-level inventory | `Reservation`, `ReservationRoom`, `RoomInventory` |
| `billing` | Reservation payment state and processor transactions | `Payment`, `PaymentTransaction` |
| `operations` | Property check-in and housekeeping activity | `CheckIn`, `HousekeepingTask` |
| `reporting` | Precalculated operational summaries | `PropertyDailySummary` |

Every transactional relationship is enforced by foreign keys. Business-state columns use check constraints, monetary values have range constraints, and natural identifiers have unique constraints. Reservation and inventory rows include `rowversion` values to support safe concurrent modification in later phases.

Baseline indexes support guest and reservation lookup, property arrivals, room/date inventory access, payment history, operational queues, and daily portfolio reporting. Phase 1 does not intentionally introduce inefficient indexes or pathological queries.

## Generated data

The generator exposes configuration variables for property, room, guest, reservation, and inventory volume. Defaults produce:

- 40 properties in representative US markets
- 75 rooms per property across five room types
- 50,000 synthetic guests
- 200,000 reservations distributed deterministically across rooms and dates
- 731 days of per-room inventory
- related payments, payment transactions, check-ins, housekeeping tasks, and 181 days of property summaries

Seeded active stays do not overlap for a room. The deterministic layout makes validation repeatable while preserving useful variation in rate, channel, status, loyalty tier, stay length, and payment state. All people and contact details are synthetic.

## Application components

The `Northstar.Operations` ASP.NET Core host contains:

- a database access layer using `Microsoft.Data.SqlClient`
- a configurable normal-workload worker engine
- structured application logging
- lightweight health endpoints for host and workload counters
- realistic SQL connection application names: `Northstar Reservations API`, `Northstar Property Operations`, and `Northstar Reporting Service`

The database access layer calls stored procedures exclusively. Transactional procedures own reservation, inventory, payment, and check-in consistency. The host changes each connection's application name according to API, property-operations, or reporting responsibility.

Phase 3 adds a lightweight operations console for workload controls and operational metrics. Phases 4 through 7 add and tune one business activity at a time. Each activity is integrated into the console when implemented.

## Normal workload

Concurrent workers perform efficient versions of availability search, reservation retrieval and creation, guest-count modification, cancellation, payment capture, check-in, room status updates, and property performance retrieval. A weighted mix favors read activity while retaining a smaller amount of realistic transactional change.

Worker count, delay range, enablement, and optional run duration are configurable. Defaults use four workers and a randomized 500–1,200 ms delay. Normal activity is not designed to create sustained blocking, high CPU, or multi-minute requests.

The workload is disabled by default and must be explicitly enabled. A positive run duration supports bounded validation; zero keeps it running until application shutdown.

## Operations console

The Phase 3 console is served by the existing ASP.NET Core host using static HTML, CSS, and JavaScript. It deliberately avoids an additional front-end framework.

The console calls three application endpoints:

- `GET /api/operations/status`
- `POST /api/operations/workload/start`
- `POST /api/operations/workload/stop`

The workload coordinator serializes start and stop transitions, uses a dedicated cancellation token for each run, and keeps the web host alive when a run stops. Metrics reset at the beginning of each run. Requests per minute is a rolling count of completed operations during the preceding minute.

Database activity is read from `sys.dm_exec_requests` and `sys.dm_exec_sessions` using the `Northstar Operations Console` application identity. The query reports user requests only and excludes its own request. Phase 3 displays:

- workload state and active worker count
- rolling requests per minute
- completed and failed operations
- active user database requests
- blocked user database requests
- longest active user request in seconds

Database metric failures are returned as API errors and surfaced visibly in the console rather than replaced with success-shaped values.

## Business activities

Only the following business-facing names appear in the application:

- **Reservation Modification Surge** — implemented in Phase 4
- **Flexible Date Search Campaign** — implemented in Phase 5
- **Guest Stay History Export** — implemented in Phase 6
- **Portfolio Revenue Reconciliation** — implemented in Phase 7

Their implementations will use realistic query and concurrency behavior. Artificial delays and arbitrary infinite loops are not part of the design.

### Reservation Modification Surge

Reservation Modification Surge is controlled through both application API endpoints and a reusable business-activity card in the operations console. Sixteen workers target the same property by default and repeatedly submit realistic pricing modifications over an overlapping 120-day inventory window.

Each database transaction:

1. recalculates property inventory rates for the modification window
2. selects an overlapping batch of pending or confirmed stays
3. revises reservation-room pricing and taxes
4. synchronizes linked room inventory
5. updates reservation modification timestamps
6. writes immutable `reservation.ReservationChange` audit rows
7. refreshes affected daily property revenue summaries

The shared inventory update is deliberately first and consistently ordered. Concurrent workers therefore queue behind legitimate inventory modifications without artificial delays. Configuration controls worker count, property spread, date-window size, reservation batch size, rate-adjustment range, worker delay, and optional duration.

The console renders business-activity cards from a JavaScript activity registry. Each card uses the same status, start, and stop endpoint convention and displays active workers, completed units, and failures. Later activities will be added to this registry as they are implemented instead of deferring all console controls until Phase 8.

The console separates metric ownership explicitly:

- **Normal workload metrics** report only baseline workload requests, workers, completions, and failures.
- **Database activity** reports all user activity in the database, including every business activity.
- **Business activity metrics** report activity-specific workers, recent throughput per minute, completed units, and failures.

Activity throughput uses recent browser status samples over a rolling window of up to one minute. The registry defines each activity's throughput label and completion counter, allowing future cards to report business-appropriate units.

### Flexible Date Search Campaign

Flexible Date Search Campaign is controlled through the operations console and dedicated API endpoints. Six workers execute portfolio-wide searches by default.

Each search:

1. builds the requested flexible arrival-date range
2. evaluates allowed stay lengths
3. joins date-level inventory for every property and room
4. retains rooms available for every night of a candidate stay
5. aggregates options by property, room type, arrival date, and length
6. calculates price ranges and stay-rate deviation
7. ranks property and room-type options
8. returns the leading flexible choices

The calibrated profile searches a 30-day arrival window with one-to-three-night stays. It performs realistic flexible-search computation without artificial loops or delays. Configuration controls worker count, date window, stay lengths, result count, delay, and optional duration.

### Guest Stay History Export

Guest Stay History Export streams detailed stay, nightly-rate, payment, check-in, and change history through eight guest partitions. A separate denormalized archive represents retained stay documents used for loyalty support, folio review, and regulatory audit. The calibrated archive contains ten annual document versions per reservation and is deliberately larger than the effective buffer pool of the project database.

Each worker:

1. exports normalized stay history for its guest partition
2. scans retained archive documents for the requested history window
3. streams every matching document with sequential client access
4. reports completed exports, exported rows, and failures

The archive generator is set-based within bounded transaction batches and is restartable. It does not flush the buffer pool or manufacture waits. Physical reads arise because concurrent business exports scan a legitimate retained-history dataset that cannot remain fully cached.

The Phase 6 validation script captures eight 15-second deltas from database file and wait statistics while the export is active. It calculates read IOPS, average physical-read latency, and PAGEIOLATCH wait milliseconds per second, then enforces the required threshold.

### Portfolio Revenue Reconciliation

Portfolio Revenue Reconciliation is a long-running financial control activity with two workers partitioning the property portfolio. Each worker executes one multi-stage database request that:

1. reads retained guest-stay documents for its property partition
2. hashes document content to verify archive integrity
3. materializes and indexes reservation-level archive evidence
4. rebuilds monthly stay revenue and allocated tax from nightly inventory
5. reconciles payment balances against approved capture and refund transactions
6. compares recomputed amounts with monthly property summaries
7. returns property/accounting-period variances

The procedure uses bounded date and property partitions and `MAXDOP 1` per worker. Its duration and waits come from reading retained business evidence and building indexed accounting worksets, not from `WAITFOR` or artificial application delays.

The Phase 7 validation observes active requests in one-minute intervals across eight minutes. It enforces presence in at least three minute bins, observation within two minutes of the window end, and at least three one-minute wait-rate samples at or above 500 wait-ms/sec.

## Monitoring

The operations console displays workload state, request rate, active and blocked database requests, and the longest active request. Activity cards add business-specific throughput and completion metrics. Detailed CPU and storage threshold validation uses Azure SQL dynamic management views; the console remains a lightweight demonstration aid rather than a replacement for database monitoring products.

## Required later-phase detection targets

These targets are explicitly deferred from Phase 1 and will be tuned and validated in their corresponding phases:

### Reservation Modification Surge

- at least three positive `Processes blocked` samples
- the latest sample remains above zero

### Flexible Date Search Campaign

- at least three database samples where `AvgCPUPercent >= 80`

### Guest Stay History Export

- `Read IOPS >= 5`
- and either at least three samples with read latency at or above 50 ms
- or at least three samples with read latency at or above 20 ms plus `PAGEIOLATCH` pressure at or above 100 wait-ms/sec

### Portfolio Revenue Reconciliation

- a running, runnable, or suspended session in at least three one-minute bins
- observation across at least five minutes
- the session observed within two minutes of the observation-window end
- at least three one-minute wait-rate samples at or above 500 wait-ms/sec

## Configuration and security

No credentials are stored in SQL or source files. Later application phases will use standard ASP.NET configuration, environment variables, and user secrets. Microsoft Entra authentication will be preferred for Azure deployments while a normal development connection string remains supported.
