import { joinSession } from "@github/copilot-sdk/extension";
import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const session = await joinSession({ tools: [] });
const helper = join(homedir(), ".tokenotch", "TokenotchHook");
const queue = [];
let active = false;
let warned = false;
let activityPending = false;
let activityWarned = false;
let contextPending = false;
let contextWarned = false;
let contextRefreshNeeded = false;
let contextRevision = 0;
let contextBoundary = -Infinity;
let lastContextTimestamp = -Infinity;
let lastUsageTimestamp = -Infinity;
let contextReported = false;

function warn() {
    if (warned) return;
    warned = true;
    process.stderr.write("Tokenotch metric delivery unavailable; check Tokenotch Connections.\n");
}

function drain() {
    if (active || queue.length === 0) return;
    active = true;
    const { hook, payload } = queue.shift();
    const child = spawn(helper, ["cli", hook], { stdio: ["pipe", "ignore", "ignore"], timeout: 1000 });
    child.on("error", warn);
    child.stdin.on("error", warn);
    child.on("close", (code) => {
        if (code !== 0) warn();
        active = false;
        drain();
    });
    child.stdin.end(JSON.stringify(payload));
}

function validCount(value) {
    return Number.isSafeInteger(value) && value >= 0 && value <= 1_000_000_000;
}

function enqueuePayload(hook, payload) {
    if (queue.length >= 64) {
        warn();
        return;
    }
    queue.push({ hook, payload });
    drain();
}

function eventTimestamp(event) {
    const timestamp = typeof event.timestamp === "string" ? Date.parse(event.timestamp) : NaN;
    const now = Date.now();
    if (!Number.isFinite(timestamp) || timestamp < now - 120_000 || timestamp > now + 30_000
        || typeof event.id !== "string" || event.id.length === 0 || event.id.length > 512
        || typeof session.sessionId !== "string" || session.sessionId.length === 0 || session.sessionId.length > 512) {
        warn();
        return undefined;
    }
    return timestamp;
}

function enqueue(hook, event, metrics) {
    const timestamp = eventTimestamp(event);
    if (timestamp === undefined) return;
    enqueuePayload(hook, {
        sessionId: session.sessionId,
        eventId: event.id,
        timestamp,
        ...metrics,
    });
}

function warnContext() {
    if (contextWarned) return;
    contextWarned = true;
    process.stderr.write("Tokenotch live context unavailable; check CLI compatibility and reload the Tokenotch extension.\n");
}

function sendContext(hook, timestamp, metrics = {}, eventId) {
    timestamp = Math.max(timestamp, lastContextTimestamp + 1);
    lastContextTimestamp = timestamp;
    enqueuePayload(hook, {
        sessionId: session.sessionId, eventId: eventId ?? `context-${timestamp}`, timestamp, ...metrics,
    });
}

function invalidateContext(timestamp) {
    contextRevision++;
    contextReported = false;
    contextBoundary = Math.max(timestamp, contextBoundary);
    sendContext("contextInvalidated", contextBoundary);
}

async function refreshContext() {
    // Attribution is a startup fallback, not a replacement for reported session usage.
    if (contextPending || contextReported) return;
    contextPending = true;
    contextRefreshNeeded = false;
    const revision = contextRevision;
    const started = Date.now();
    const timeout = setTimeout(warnContext, 5000);
    try {
        const snapshot = await session.rpc.metadata.getContextAttribution();
        // An event or model change received during the read wins over that in-flight snapshot.
        if (revision !== contextRevision) return;
        if (Date.now() - started >= 5000 || Date.now() < started) { warnContext(); return; }
        const reading = snapshot?.contextAttribution;
        if (reading === null) {
            sendContext("contextInvalidated", started);
            return;
        }
        if (!validCount(reading?.totalTokens) || !validCount(reading?.promptTokenLimit)
            || reading.promptTokenLimit === 0 || !validCount(reading?.categories?.messages)
            || typeof reading?.modelSource !== "string" || reading.modelSource.length === 0) {
            warnContext();
            return;
        }
        if (reading.modelSource === "default" || reading.categories.messages === 0) {
            sendContext("contextInvalidated", started);
            return;
        }
        sendContext("context", started, {
            currentTokens: reading.totalTokens, tokenLimit: reading.promptTokenLimit,
        });
        contextWarned = false;
    } catch {
        warnContext();
    } finally {
        clearTimeout(timeout);
        contextPending = false;
        if (contextRefreshNeeded) void refreshContext();
    }
}

function warnActivity() {
    if (activityWarned) return;
    activityWarned = true;
    process.stderr.write("Tokenotch live activity unavailable; check CLI compatibility and reload the Tokenotch extension.\n");
}

async function refreshActivity() {
    if (activityPending) return;
    activityPending = true;
    // Date the read at its start so a slow reply cannot supersede a newer lifecycle hook.
    const timestamp = Date.now();
    const timeout = setTimeout(warnActivity, 5000);
    try {
        const snapshot = await session.rpc.metadata.activity();
        if (Date.now() - timestamp >= 5000 || Date.now() < timestamp
            || typeof snapshot?.hasActiveWork !== "boolean"
            || typeof session.sessionId !== "string" || session.sessionId.length === 0 || session.sessionId.length > 512) {
            warnActivity();
            return;
        }
        enqueuePayload("activity", { sessionId: session.sessionId, timestamp, active: snapshot.hasActiveWork });
        activityWarned = false;
    } catch {
        warnActivity();
    } finally {
        clearTimeout(timeout);
        activityPending = false;
    }
}

for (const type of ["assistant.turn_start", "session.idle"]) {
    session.on(type, (event) => {
        if (event.agentId === undefined) {
            void refreshActivity();
            void refreshContext();
        }
    });
}
const activityTimer = setInterval(() => { void refreshActivity(); void refreshContext(); }, 30_000);
activityTimer.unref();
void refreshActivity();
if (typeof session.sessionId === "string" && session.sessionId.length > 0 && session.sessionId.length <= 512) {
    // Extensions reattach on /clear and when the foreground conversation is replaced.
    invalidateContext(Date.now());
    void refreshContext();
} else { warnContext(); }

for (const type of ["session.model_change", "session.model_deselected", "session.truncation",
    "session.snapshot_rewind", "session.context_cleared"]) {
    session.on(type, (event) => {
        if (event.agentId !== undefined) return;
        const timestamp = eventTimestamp(event);
        if (timestamp === undefined || timestamp < contextBoundary) return;
        invalidateContext(timestamp);
        contextRefreshNeeded = true;
        void refreshContext();
    });
}

session.on("assistant.usage", (event) => {
    const { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, model } = event.data;
    if (!validCount(inputTokens) || !validCount(outputTokens)
        || (cacheReadTokens !== undefined && !validCount(cacheReadTokens))
        || (cacheWriteTokens !== undefined && !validCount(cacheWriteTokens))
        || (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0) > inputTokens
        || (model !== undefined && (typeof model !== "string" || !/^[a-zA-Z0-9._:/-]{1,128}$/.test(model)))) {
        warn();
        return;
    }
    const latency = {};
    for (const [source, target] of [["duration", "durationMs"], ["timeToFirstTokenMs", "timeToFirstTokenMs"]]) {
        const value = event.data[source];
        if (value === undefined) continue;
        if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 86_400_000) {
            warn();
            continue;
        }
        latency[target] = value;
    }
    enqueue("usage", event, {
        usageContract: 1,
        inputTokens,
        outputTokens,
        cacheReadTokensReported: cacheReadTokens !== undefined,
        ...(cacheReadTokens === undefined ? {} : { cacheReadTokens }),
        cacheWriteTokensReported: cacheWriteTokens !== undefined,
        ...(cacheWriteTokens === undefined ? {} : { cacheWriteTokens }),
        ...(model === undefined ? {} : { model }),
        ...latency,
    });

});

session.on("session.compaction_start", (event) => {
    if (event.agentId !== undefined) return;
    const timestamp = eventTimestamp(event);
    if (timestamp === undefined) return;
    if (timestamp >= contextBoundary) invalidateContext(timestamp);
    enqueue("compaction", event, { phase: "start" });
});

session.on("session.compaction_complete", (event) => {
    if (event.agentId !== undefined) return;
    const { success, preCompactionTokens, postCompactionTokens } = event.data;
    if (typeof success !== "boolean") { warn(); return; }
    const timestamp = eventTimestamp(event);
    if (timestamp === undefined) return;
    const counts = {};
    for (const [key, value] of [["beforeTokens", preCompactionTokens], ["afterTokens", postCompactionTokens]]) {
        if (value === undefined) continue;
        if (!validCount(value)) { warn(); continue; }
        counts[key] = value;
    }
    if (timestamp >= contextBoundary) invalidateContext(timestamp);
    enqueue("compaction", event, { phase: "complete", success, ...counts });
    contextRefreshNeeded = true;
    void refreshContext();
});

session.on("session.usage_info", (event) => {
    if (event.agentId !== undefined) return;
    const { currentTokens, tokenLimit, messagesLength } = event.data;
    if (!validCount(currentTokens) || !validCount(tokenLimit) || tokenLimit === 0 || !validCount(messagesLength)) {
        warn();
        return;
    }
    const timestamp = eventTimestamp(event);
    if (timestamp === undefined || timestamp < contextBoundary || timestamp <= lastUsageTimestamp) return;
    lastUsageTimestamp = timestamp;
    if (messagesLength === 0) {
        invalidateContext(timestamp);
        return;
    }
    contextRevision++;
    contextReported = true;
    sendContext("context", timestamp, { currentTokens, tokenLimit }, event.id);
});
