import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { EventEmitter } from "node:events";
import vm from "node:vm";

const payloads = [];
const hooks = [];
const warnings = [];
const callbacks = new Map();
const children = [];
let autoClose = true;
const platform = process.argv[2] ?? process.platform;
let clock = Date.now();
class FixtureDate extends Date {
    constructor(...args) { super(...(args.length ? args : [clock])); }
    static now() { return clock; }
}
let interval;
const timeouts = new Map();
let unreferencedRetries = 0;
let activityQueries = 0;
let finishInitialActivity;
let activityRead = () => new Promise((resolve) => { finishInitialActivity = resolve; });
const context = vm.createContext({
    process: { platform, stderr: { write: (message) => warnings.push(message) } },
    Date: FixtureDate, Number, JSON, queueMicrotask,
    setInterval: (callback, delay) => {
        assert.equal(delay, 30_000);
        interval = callback;
        return { unref() {} };
    },
    setTimeout: (callback, delay) => {
        assert.ok([250, 500, 1000, 2000, 4000, 5000].includes(delay));
        const timer = { unref() { unreferencedRetries++; } };
        timeouts.set(timer, { callback, delay });
        return timer;
    },
    clearTimeout: (id) => timeouts.delete(id),
});
const dependencies = {
    "@github/copilot-sdk/extension": {
        joinSession: async () => ({
            sessionId: "fixture-session",
            rpc: { metadata: { activity: () => { activityQueries++; return activityRead(); } } },
            on: (type, handler) => {
                assert.ok(["assistant.usage", "session.usage_info", "session.compaction_start", "session.compaction_complete",
                    "assistant.turn_start", "session.idle", "session.model_change", "session.model_deselected",
                    "session.truncation", "session.snapshot_rewind", "session.context_cleared"].includes(type));
                callbacks.set(type, handler);
            },
        }),
    },
    "node:child_process": {
        spawn: (path, args, options) => {
            assert.equal(path, `/fixture/.tokenotch/${platform === "win32" ? "TokenotchHook.exe" : "TokenotchHook"}`);
            assert.equal(args[0], "cli");
            assert.ok(["usage", "context", "contextInvalidated", "compaction", "activity"].includes(args[1]));
            hooks.push(args[1]);
            assert.equal(options.timeout, 1000);
            assert.equal(options.windowsHide, true);
            const child = new EventEmitter();
            children.push(child);
            child.stdin = new EventEmitter();
            child.stdin.end = (text) => {
                payloads.push(JSON.parse(text));
                if (autoClose) queueMicrotask(() => child.emit("close", 0));
            };
            return child;
        },
    },
    "node:os": { homedir: () => "/fixture" },
    "node:path": { join: (...parts) => parts.join("/") },
};
const extension = new vm.SourceTextModule(await readFile("integrations/CopilotUsage/extension.mjs", "utf8"), { context });
await extension.link((specifier) => {
    const values = dependencies[specifier];
    assert.ok(values, `Unexpected dependency: ${specifier}`);
    return new vm.SyntheticModule(Object.keys(values), function () {
        for (const [name, value] of Object.entries(values)) this.setExport(name, value);
    }, { context });
});
await extension.evaluate();
assert.equal(callbacks.size, 11);
assert.equal(activityQueries, 1, "Read current activity immediately, including mid-turn attachment");
await new Promise(queueMicrotask);
assert.equal(hooks.shift(), "contextInvalidated", "Attachment must withdraw a previous window reading");
payloads.shift();
assert.equal(warnings.length, 1, "Older runtimes report unavailable snapshot support without stopping events");
warnings.length = 0;
clock += 2;
const timestamp = new Date(clock).toISOString();
function emit(type, data, envelope = {}) {
    if (type === "session.usage_info") data = { messagesLength: 1, ...data };
    callbacks.get(type)({ id: "call-1", timestamp, data, ...envelope });
}
emit("assistant.usage", {
    inputTokens: 1200, outputTokens: 45, cacheReadTokens: 900, cacheWriteTokens: 100, reasoningTokens: 20,
    prompt: "never-forward", model: "fixture-model",
});
await new Promise(queueMicrotask);
assert.equal(payloads.length, 1);
assert.deepEqual(Object.keys(payloads[0]).sort(), [
    "cacheReadTokens", "cacheReadTokensReported", "cacheWriteTokens", "cacheWriteTokensReported",
    "eventId", "inputTokens", "model", "outputTokens", "sessionId", "timestamp", "usageContract",
]);
assert.equal(payloads[0].inputTokens, 1200);
assert.equal(payloads[0].outputTokens, 45);
assert.equal(payloads[0].cacheReadTokens, 900);
assert.equal(payloads[0].cacheReadTokensReported, true);
assert.equal(payloads[0].cacheWriteTokens, 100);
assert.equal(payloads[0].cacheWriteTokensReported, true);
assert.equal(payloads[0].usageContract, 1);
assert.ok(!("reasoningTokens" in payloads[0]), "Reasoning is already included in output");
assert.equal(payloads[0].model, "fixture-model");
assert.equal(payloads[0].timestamp, Date.parse(timestamp));
emit("assistant.usage", { inputTokens: 0, outputTokens: 0 });
await new Promise(queueMicrotask);
assert.equal(payloads.length, 2);
assert.ok(!("model" in payloads[1]));
assert.equal(payloads[1].cacheReadTokensReported, false);
assert.ok(!("cacheReadTokens" in payloads[1]));
assert.equal(payloads[1].cacheWriteTokensReported, false);
assert.ok(!("cacheWriteTokens" in payloads[1]));
emit("session.usage_info", { currentTokens: 75000, tokenLimit: 100000, messages: "never-forward", model: "never-forward" });
await new Promise(queueMicrotask);
assert.equal(payloads.length, 3);
assert.equal(hooks[2], "context");
assert.deepEqual(Object.keys(payloads[2]).sort(), ["currentTokens", "eventId", "sessionId", "timestamp", "tokenLimit"]);
assert.equal(payloads[2].currentTokens, 75000);
assert.equal(payloads[2].tokenLimit, 100000);
assert.ok(!JSON.stringify(payloads).includes("never-forward"));

for (const invalid of [undefined, null, -1, 1.5, true, "1", NaN, Infinity, 1_000_000_001]) {
    emit("assistant.usage", { inputTokens: invalid, outputTokens: 1 });
    emit("assistant.usage", { inputTokens: 1, outputTokens: invalid });
    if (invalid !== undefined) {
        emit("assistant.usage", { inputTokens: 1, outputTokens: 1, cacheReadTokens: invalid });
        emit("assistant.usage", { inputTokens: 1, outputTokens: 1, cacheWriteTokens: invalid });
    }
    emit("session.usage_info", { currentTokens: invalid, tokenLimit: 100 });
    emit("session.usage_info", { currentTokens: 1, tokenLimit: invalid });
    emit("session.usage_info", { currentTokens: 1, tokenLimit: 100, messagesLength: invalid });
}
emit("assistant.usage", { inputTokens: 10, outputTokens: 1, cacheReadTokens: 8, cacheWriteTokens: 3 });
emit("assistant.usage", { inputTokens: 10, outputTokens: 1, cacheReadTokens: 11 });
emit("assistant.usage", { inputTokens: 10, outputTokens: 1, cacheWriteTokens: 11 });
emit("session.usage_info", { currentTokens: 0, tokenLimit: 0 });
for (const model of ["", "a".repeat(129), "bad\nmodel", "bad model", "模型", 1, null]) {
    emit("assistant.usage", { inputTokens: 1, outputTokens: 1, model });
}
for (const envelope of [
    { id: "" }, { id: "x".repeat(513) }, { timestamp: undefined }, { timestamp: "invalid" },
    { timestamp: new Date(Date.now() - 121_000).toISOString() },
    { timestamp: new Date(Date.now() + 31_000).toISOString() },
]) {
    emit("assistant.usage", { inputTokens: 1, outputTokens: 1 }, envelope);
    emit("session.usage_info", { currentTokens: 1, tokenLimit: 100 }, envelope);
}
assert.equal(payloads.length, 3);
assert.equal(warnings.length, 1);

autoClose = false;
const before = payloads.length;
for (let index = 0; index < 66; index++) {
    emit("assistant.usage", { inputTokens: 100, outputTokens: 20 }, { id: `queued-${index}` });
}
assert.equal(payloads.length, before + 1);
for (let index = 0; index < 66; index++) {
    children.at(-1).emit("close", 0);
}
assert.equal(payloads.length, before + 66, "A burst must retain every accounting event");
assert.equal(payloads.slice(before).reduce((sum, p) => sum + p.inputTokens + p.outputTokens, 0), 7920);
assert.equal(new Set(payloads.slice(before).map(p => p.eventId)).size, 66);
autoClose = true;
emit("session.usage_info", { currentTokens: 0, tokenLimit: 100 },
    { timestamp: new Date(clock + 1).toISOString() });
children.at(-1).emit("error", new Error("private error must not leak"));
await new Promise(queueMicrotask);
retry(250);
await new Promise(queueMicrotask);
assert.equal(payloads.at(-1).currentTokens, 0);
assert.equal(warnings.length, 1);
assert.ok(!warnings[0].includes("private"));
emit("assistant.usage", { inputTokens: 10, outputTokens: 2, duration: 2400.5, timeToFirstTokenMs: 120.25 });
await new Promise(queueMicrotask);
assert.equal(payloads.at(-1).durationMs, 2400.5);
assert.equal(payloads.at(-1).timeToFirstTokenMs, 120.25);
for (const invalid of [null, true, "1", -1, NaN, Infinity, 86_400_001]) {
    emit("assistant.usage", { inputTokens: 10, outputTokens: 2, duration: invalid, timeToFirstTokenMs: invalid });
    await new Promise(queueMicrotask);
    assert.equal(payloads.at(-1).inputTokens, 10);
    assert.ok(!("durationMs" in payloads.at(-1)));
    assert.ok(!("timeToFirstTokenMs" in payloads.at(-1)));
}
emit("session.compaction_start", { summaryContent: "never-forward" });
await new Promise(queueMicrotask);
assert.equal(payloads.at(-1).phase, "start");
assert.ok(!("success" in payloads.at(-1)));
emit("session.compaction_complete", {
    success: true, preCompactionTokens: 80, postCompactionTokens: 20,
    summaryContent: "never-forward", checkpointPath: "/never-forward", error: "never-forward",
});
await new Promise(queueMicrotask);
assert.deepEqual(Object.keys(payloads.at(-1)).sort(),
    ["afterTokens", "beforeTokens", "eventId", "phase", "sessionId", "success", "timestamp"]);
assert.equal(payloads.at(-1).beforeTokens, 80);
assert.equal(payloads.at(-1).afterTokens, 20);
const count = payloads.length;
emit("session.compaction_complete", { success: "true" });
await new Promise(queueMicrotask);
assert.equal(payloads.length, count);
assert.ok(!JSON.stringify(payloads).includes("never-forward"));
console.log("PASS: CLI metrics extension validates tokens, latency and compaction, strips content, preserves bursts and retries delivery errors.");

async function settle() {
    await new Promise((resolve) => setImmediate(resolve));
}
function retry(delay) {
    const [id, timer] = [...timeouts.entries()].at(-1);
    assert.equal(timer.delay, delay);
    timeouts.delete(id);
    timer.callback();
}
interval();
assert.equal(activityQueries, 1, "Never overlap activity RPCs");
finishInitialActivity({ hasActiveWork: true, prompt: "never-forward", abortable: true });
await settle();
assert.equal(hooks.at(-1), "activity");
assert.deepEqual(Object.keys(payloads.at(-1)).sort(), ["active", "sessionId", "timestamp"]);
assert.equal(payloads.at(-1).active, true);
assert.equal(timeouts.size, 0);
activityRead = async () => ({ hasActiveWork: true });
for (let index = 0; index < 22; index++) {
    clock += 30_000;
    interval();
    await settle();
    assert.equal(payloads.at(-1).timestamp, clock);
    assert.equal(payloads.at(-1).active, true, "Keep long-running work observable beyond five minutes");
}
const beforeSubagent = activityQueries;
emit("assistant.turn_start", {}, { agentId: "nested-agent" });
emit("session.idle", {}, { agentId: "nested-agent" });
assert.equal(activityQueries, beforeSubagent, "Nested agents are not counted as separate root sessions");
activityRead = async () => ({ hasActiveWork: false });
emit("session.idle", {});
await settle();
assert.equal(payloads.at(-1).active, false, "Idle does not become task success");
activityRead = async () => ({ hasActiveWork: true });
emit("assistant.turn_start", {});
await settle();
assert.equal(payloads.at(-1).active, true);
const validCountBefore = payloads.length;
for (const result of [undefined, null, {}, { hasActiveWork: "true" }, { hasActiveWork: 1 }]) {
    activityRead = async () => result;
    interval();
    await settle();
}
activityRead = async () => { throw new Error("private-rpc-error"); };
interval();
await settle();
assert.equal(payloads.length, validCountBefore, "Invalid and failed reads cannot refresh activity");
assert.equal(warnings.length, 2, "Activity failures have an explicit, deduplicated warning");
assert.ok(!warnings.join("").includes("private-rpc-error"));
let finishSlowRead;
activityRead = () => new Promise((resolve) => { finishSlowRead = resolve; });
interval();
const pendingCount = activityQueries;
clock += 5000;
for (const { callback } of timeouts.values()) callback();
interval();
assert.equal(activityQueries, pendingCount, "A hung RPC cannot accumulate more pending reads");
finishSlowRead({ hasActiveWork: true });
await settle();
assert.equal(payloads.length, validCountBefore, "Timed-out replies cannot look fresh");
activityRead = async () => ({ hasActiveWork: false });
interval();
await settle();
assert.equal(payloads.at(-1).active, false, "A later valid read recovers");
assert.ok(!JSON.stringify(payloads).includes("never-forward"));
emit("assistant.usage", { inputTokens: 10, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 0 },
    { timestamp: new Date(clock).toISOString() });
await settle();
assert.equal(payloads.at(-1).cacheReadTokens, 0);
assert.equal(payloads.at(-1).cacheReadTokensReported, true, "Explicit zero must remain reported");
assert.equal(payloads.at(-1).cacheWriteTokens, 0);
assert.equal(payloads.at(-1).cacheWriteTokensReported, true, "Explicit zero writes must remain reported");
console.log("PASS: live activity polling attaches mid-turn, survives long work, handles idle/stale/error states and excludes subagents.");

autoClose = false;
const usage = { inputTokens: 100, outputTokens: 20 };
emit("assistant.usage", usage, { id: "retry-first", timestamp: new Date(clock).toISOString() });
const original = payloads.at(-1);
const attempts = payloads.length;
children.at(-1).emit("error", new Error("private-spawn-error"));
children.at(-1).emit("close", -1);
emit("assistant.usage", usage, { id: "retry-second", timestamp: new Date(clock).toISOString() });
assert.equal(payloads.length, attempts, "New events must not bypass delivery backoff");
for (const [index, delay] of [250, 500, 1000, 2000, 4000, 5000, 5000].entries()) {
    retry(delay);
    assert.deepEqual(payloads.at(-1), original, "Retries keep the original timestamp, identity and counts");
    if (index === 0) children.at(-1).stdin.emit("error", new Error("private-stdin-error"));
    if (index < 6) children.at(-1).emit("close", index === 0 ? 0 : null);
}
children.at(-1).emit("close", 0);
assert.equal(payloads.at(-1).eventId, "retry-second", "Successful delivery advances exactly once");
children.at(-1).emit("close", 1);
retry(250);
assert.equal(payloads.at(-1).eventId, "retry-second", "A success resets retry backoff");
children.at(-1).emit("close", 0);
assert.equal(timeouts.size, 0, "A drained queue leaves no retry timer");
assert.ok(unreferencedRetries >= 8, "Retry timers must not keep a detached CLI extension alive");
assert.ok(!warnings.join("").includes("private-"));

if (platform === "win32") {
    emit("assistant.usage", usage, { id: "delayed", timestamp: new Date(clock).toISOString() });
    const delayed = payloads.at(-1);
    children.at(-1).emit("close", 1);
    clock += 180_000;
    interval();
    await settle();
    clock += 30_000;
    interval();
    await settle();
    const recoveryCount = payloads.length;
    retry(250);
    assert.deepEqual(payloads.at(-1), delayed, "Windows usage survives delivery delays beyond two minutes");
    children.at(-1).emit("close", 0);
    assert.equal(hooks.at(-1), "activity");
    assert.equal(payloads.at(-1).timestamp, clock, "Waiting activity polls coalesce to the latest snapshot");
    children.at(-1).emit("close", 0);
    assert.equal(payloads.length, recoveryCount + 2);
}

emit("assistant.usage", usage, { id: "expired", timestamp: new Date(clock).toISOString() });
children.at(-1).emit("close", 1);
clock += platform === "win32" ? 86_400_000 : 120_000;
emit("assistant.usage", usage, { id: "after-expiry", timestamp: new Date(clock).toISOString() });
retry(250);
assert.equal(payloads.at(-1).eventId, "after-expiry", "Expired telemetry cannot block current delivery");
children.at(-1).emit("close", 0);
assert.match(warnings.at(-1), /expired.*totals may be incomplete/);
assert.equal(timeouts.size, 0);
console.log("PASS: failed/timeout/stdin deliveries retry with capped backoff and stable identities; expiration is explicit.");
