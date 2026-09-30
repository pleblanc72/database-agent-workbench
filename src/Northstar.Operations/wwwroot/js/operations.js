const businessActivities = [
    {
        id: "reservation-modification-surge",
        name: "Reservation Modification Surge",
        description: "Coordinates a concentrated period of reservation pricing changes and room inventory adjustments.",
        threshold: "Blocking: at least 3 positive samples; latest sample remains blocked",
        rateLabel: "Batches per minute",
        completedLabel: "Completed batches",
        failedLabel: "Failed batches",
        completedProperty: "completedBatches",
        failedProperty: "failedBatches"
    },
    {
        id: "flexible-date-search-campaign",
        name: "Flexible Date Search Campaign",
        description: "Expands flexible arrival and stay-length searches across the property portfolio.",
        threshold: "CPU: at least 3 samples at or above 80%",
        rateLabel: "Searches per minute",
        completedLabel: "Completed searches",
        failedLabel: "Failed searches",
        completedProperty: "completedSearches",
        failedProperty: "failedSearches"
    },
    {
        id: "guest-stay-history-export",
        name: "Guest Stay History Export",
        description: "Exports detailed historical stays, nightly charges, payments, check-ins, and reservation changes.",
        threshold: "Storage I/O: read IOPS plus latency or PAGEIOLATCH pressure",
        rateLabel: "Rows per minute",
        completedLabel: "Exported rows",
        failedLabel: "Failed exports",
        completedProperty: "exportedRows",
        failedProperty: "failedExports"
    },
    {
        id: "portfolio-revenue-reconciliation",
        name: "Portfolio Revenue Reconciliation",
        description: "Reconciles archived stay evidence against nightly revenue, payments, refunds, and property summaries.",
        threshold: "Long-running request: 5+ minute window and sustained wait rate",
        rateLabel: "Reconciliations per minute",
        completedLabel: "Completed reconciliations",
        failedLabel: "Failed reconciliations",
        completedProperty: "completedReconciliations",
        failedProperty: "failedReconciliations"
    }
];

const elements = {
    connectionState: document.querySelector("#connection-state"),
    workloadState: document.querySelector("#workload-state"),
    startButton: document.querySelector("#start-button"),
    stopButton: document.querySelector("#stop-button"),
    requestsPerMinute: document.querySelector("#requests-per-minute"),
    activeRequests: document.querySelector("#active-requests"),
    blockedRequests: document.querySelector("#blocked-requests"),
    longestRequest: document.querySelector("#longest-request"),
    activeWorkers: document.querySelector("#active-workers"),
    completedRequests: document.querySelector("#completed-requests"),
    failedRequests: document.querySelector("#failed-requests"),
    lastRefreshed: document.querySelector("#last-refreshed"),
    activityGrid: document.querySelector("#activity-grid"),
    message: document.querySelector("#message")
};

const activityElements = new Map();
const activityRateSamples = new Map();
const activityCommandsInProgress = new Set();
let workloadCommandInProgress = false;

function createBusinessActivityCards() {
    for (const activity of businessActivities) {
        const card = document.createElement("article");
        card.className = "activity-card";
        card.dataset.activityId = activity.id;
        card.innerHTML = `
            <div class="activity-card-header">
                <div>
                    <p class="activity-kicker">Reservation operations</p>
                    <h3>${activity.name}</h3>
                </div>
                <span class="workload-state stopped" data-role="state">Stopped</span>
            </div>
            <p class="activity-description">${activity.description}</p>
            <p class="activity-threshold"><strong>Triggers</strong> ${activity.threshold}</p>
            <dl class="activity-metrics">
                <div>
                    <dt>Active workers</dt>
                    <dd data-role="workers">0</dd>
                </div>
                <div>
                    <dt>${activity.rateLabel}</dt>
                    <dd data-role="rate">0</dd>
                </div>
                <div>
                    <dt>${activity.completedLabel}</dt>
                    <dd data-role="completed">0</dd>
                </div>
                <div>
                    <dt>${activity.failedLabel}</dt>
                    <dd data-role="failed">0</dd>
                </div>
            </dl>
            <p class="validation-status" data-role="validation-status">Threshold validation has not been run.</p>
            <div class="activity-actions">
                <button class="button button-validation" data-command="validate" type="button" disabled>
                    Run validation
                </button>
                <button class="button button-primary" data-command="start" type="button">Start</button>
                <button class="button button-secondary" data-command="stop" type="button" disabled>Stop</button>
            </div>
        `;

        const startButton = card.querySelector('[data-command="start"]');
        const stopButton = card.querySelector('[data-command="stop"]');
        const validationButton = card.querySelector('[data-command="validate"]');
        startButton.addEventListener("click", () => sendActivityCommand(activity, "start"));
        stopButton.addEventListener("click", () => sendActivityCommand(activity, "stop"));
        validationButton.addEventListener("click", () => startActivityValidation(activity));

        activityElements.set(activity.id, {
            state: card.querySelector('[data-role="state"]'),
            workers: card.querySelector('[data-role="workers"]'),
            rate: card.querySelector('[data-role="rate"]'),
            completed: card.querySelector('[data-role="completed"]'),
            failed: card.querySelector('[data-role="failed"]'),
            validationStatus: card.querySelector('[data-role="validation-status"]'),
            validationButton,
            startButton,
            stopButton
        });
        elements.activityGrid.append(card);
    }
}

async function request(url, options) {
    const response = await fetch(url, options);
    if (!response.ok) {
        const body = await response.text();
        throw new Error(body || `Request failed with status ${response.status}`);
    }

    return response.json();
}

function setConnectionState(isConnected) {
    elements.connectionState.classList.toggle("connected", isConnected);
    elements.connectionState.classList.toggle("disconnected", !isConnected);
    elements.connectionState.querySelector("span:last-child").textContent =
        isConnected ? "Connected" : "Connection unavailable";
}

function renderStatus(status) {
    const workload = status.workload;
    const database = status.database;

    elements.workloadState.textContent = workload.isRunning ? "Running" : "Stopped";
    elements.workloadState.classList.toggle("running", workload.isRunning);
    elements.workloadState.classList.toggle("stopped", !workload.isRunning);
    elements.startButton.disabled = workload.isRunning || workloadCommandInProgress;
    elements.stopButton.disabled = !workload.isRunning || workloadCommandInProgress;
    elements.requestsPerMinute.textContent = workload.requestsPerMinute.toLocaleString();
    elements.activeRequests.textContent = database.activeRequestCount.toLocaleString();
    elements.blockedRequests.textContent = database.blockedRequestCount.toLocaleString();
    elements.longestRequest.textContent = database.longestActiveRequestSeconds.toLocaleString();
    elements.activeWorkers.textContent = workload.activeWorkerCount.toLocaleString();
    elements.completedRequests.textContent = workload.completedRequests.toLocaleString();
    elements.failedRequests.textContent = workload.failedRequests.toLocaleString();
    elements.lastRefreshed.textContent = new Date(status.observedAt).toLocaleTimeString();
}

function renderActivityStatus(activity, status, validation, anyValidationRunning) {
    const card = activityElements.get(activity.id);
    const commandInProgress = activityCommandsInProgress.has(activity.id);
    const validationIsRunning =
        validation.state === "Starting" || validation.state === "Running";

    card.state.textContent = status.isRunning ? "Running" : "Stopped";
    card.state.classList.toggle("running", status.isRunning);
    card.state.classList.toggle("stopped", !status.isRunning);
    card.workers.textContent = status.activeWorkerCount.toLocaleString();
    card.rate.textContent = calculateActivityRate(activity, status).toLocaleString();
    card.completed.textContent = status[activity.completedProperty].toLocaleString();
    card.failed.textContent = status[activity.failedProperty].toLocaleString();
    card.startButton.disabled = status.isRunning || commandInProgress;
    card.stopButton.disabled = !status.isRunning || commandInProgress || validationIsRunning;
    card.validationButton.disabled =
        commandInProgress || anyValidationRunning;
    card.validationButton.textContent =
        validationIsRunning ? "Validation running..." : "Run validation";
    card.validationStatus.textContent = validation.message;
    card.validationStatus.dataset.state = validation.state.toLowerCase();
}

function calculateActivityRate(activity, status) {
    if (!status.isRunning) {
        activityRateSamples.delete(activity.id);
        return 0;
    }

    const now = Date.now();
    const completed = status[activity.completedProperty];
    const runStartedAt = status.startedAt;
    let tracker = activityRateSamples.get(activity.id);

    if (!tracker || tracker.runStartedAt !== runStartedAt) {
        tracker = {
            runStartedAt,
            samples: [{ observedAt: now, completed }]
        };
        activityRateSamples.set(activity.id, tracker);
        return 0;
    }

    tracker.samples.push({ observedAt: now, completed });
    const cutoff = now - 60000;
    while (tracker.samples.length > 2 && tracker.samples[1].observedAt < cutoff) {
        tracker.samples.shift();
    }

    const first = tracker.samples[0];
    const last = tracker.samples[tracker.samples.length - 1];
    const elapsedSeconds = (last.observedAt - first.observedAt) / 1000;

    if (elapsedSeconds < 1) {
        return 0;
    }

    return Math.max(0, Math.round(
        ((last.completed - first.completed) / elapsedSeconds) * 60));
}

async function refreshStatus() {
    try {
        const [operationsStatus, ...activityResults] = await Promise.all([
            request("/api/operations/status"),
            ...businessActivities.map(async activity => ({
                status: await request(`/api/activities/${activity.id}/status`),
                validation: await request(`/api/activities/${activity.id}/validation/status`)
            }))
        ]);

        renderStatus(operationsStatus);
        const anyValidationRunning = activityResults.some(
            result =>
                result.validation.state === "Starting"
                || result.validation.state === "Running");
        businessActivities.forEach((activity, index) =>
            renderActivityStatus(
                activity,
                activityResults[index].status,
                activityResults[index].validation,
                anyValidationRunning));
        setConnectionState(true);
        elements.message.textContent = "";
    } catch (error) {
        setConnectionState(false);
        elements.message.textContent = `Unable to refresh operations data: ${error.message}`;
    }
}

async function sendWorkloadCommand(command) {
    workloadCommandInProgress = true;
    elements.startButton.disabled = true;
    elements.stopButton.disabled = true;
    elements.message.textContent = "";

    try {
        await request(`/api/operations/workload/${command}`, { method: "POST" });
    } catch (error) {
        elements.message.textContent = `Unable to ${command} the workload: ${error.message}`;
    } finally {
        workloadCommandInProgress = false;
        await refreshStatus();
    }
}

async function sendActivityCommand(activity, command) {
    activityCommandsInProgress.add(activity.id);
    const card = activityElements.get(activity.id);
    card.startButton.disabled = true;
    card.stopButton.disabled = true;
    elements.message.textContent = "";

    try {
        await request(`/api/activities/${activity.id}/${command}`, { method: "POST" });
    } catch (error) {
        elements.message.textContent = `Unable to ${command} ${activity.name}: ${error.message}`;
    } finally {
        activityCommandsInProgress.delete(activity.id);
        await refreshStatus();
    }
}

async function startActivityValidation(activity) {
    const card = activityElements.get(activity.id);
    card.validationButton.disabled = true;
    elements.message.textContent = "";

    try {
        await request(
            `/api/activities/${activity.id}/validation/start`,
            { method: "POST" });
    } catch (error) {
        elements.message.textContent =
            `Unable to validate ${activity.name}: ${error.message}`;
    } finally {
        await refreshStatus();
    }
}

createBusinessActivityCards();
elements.startButton.addEventListener("click", () => sendWorkloadCommand("start"));
elements.stopButton.addEventListener("click", () => sendWorkloadCommand("stop"));

refreshStatus();
setInterval(refreshStatus, 2000);
