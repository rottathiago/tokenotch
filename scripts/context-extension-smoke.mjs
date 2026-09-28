import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { EventEmitter } from "node:events";
import vm from "node:vm";

const code = await readFile("integrations/CopilotUsage/extension.mjs", "utf8");
const settle = () => new Promise((resolve) => setImmediate(resolve));
const snapshot = (totalTokens, promptTokenLimit, messages = 1, modelSource = "selected") => ({
    contextAttribution: { totalTokens, promptTokenLimit, limit: promptTokenLimit + 10,
        modelId: "not-forwarded", modelSource, categories: { messages },
        entries: [{ label: "private-content" }] },
});

async function fixture(sessionId, initial = snapshot(75, 100)) {
    let clock = Date.now();
    let read = async () => initial;
    let interval;
    let queries = 0;
    const callbacks = new Map(), timers = new Map(), payloads = [], warnings = [];
    let timerID = 0;
    class Clock extends Date {
        constructor(...args) { super(...(args.length ? args : [clock])); }
        static now() { return clock; }
    }
    const context = vm.createContext({
        process: { stderr: { write: (message) => warnings.push(message) } }, Date: Clock, queueMicrotask,
        setInterval: (callback, delay) => {
            assert.equal(delay, 30_000); interval = callback; return { unref() {} };
        },
        setTimeout: (callback, delay) => {
            assert.equal(delay, 5000); timers.set(++timerID, callback); return timerID;
        },
        clearTimeout: (id) => timers.delete(id),
    });
    const dependencies = {
        "@github/copilot-sdk/extension": {
            joinSession: async () => ({
                sessionId,
                rpc: { metadata: {
                    activity: async () => ({ hasActiveWork: false }),
                    getContextAttribution: () => { queries++; return read(); },
                } },
                on: (type, handler) => callbacks.set(type, handler),
            }),
        },
        "node:child_process": {
            spawn: (_path, args) => {
                const child = new EventEmitter();
                child.stdin = new EventEmitter();
                child.stdin.end = (text) => {
                    payloads.push({ hook: args[1], ...JSON.parse(text) });
                    queueMicrotask(() => child.emit("close", 0));
                };
                return child;
            },
        },
        "node:os": { homedir: () => "/fixture" },
        "node:path": { join: (...parts) => parts.join("/") },
    };
    const extension = new vm.SourceTextModule(code, { context });
    await extension.link((specifier) => {
        const values = dependencies[specifier];
        assert.ok(values);
        return new vm.SyntheticModule(Object.keys(values), function () {
            for (const [key, value] of Object.entries(values)) this.setExport(key, value);
        }, { context });
    });
    await extension.evaluate();
    await settle();
    return {
        payloads, warnings,
        get queries() { return queries; },
        get context() { return payloads.filter((p) => p.hook.startsWith("context")); },
        get clock() { return clock; },
        read(value) { read = typeof value === "function" ? value : async () => value; },
        advance(ms = 10) { clock += ms; },
        poll() { interval(); },
        timeout() { for (const callback of timers.values()) callback(); },
        emit(type, data = {}, envelope = {}) {
            if (type === "session.usage_info") data = { messagesLength: 1, ...data };
            callbacks.get(type)({ id: `event-${clock}`, timestamp: new Date(clock).toISOString(), data, ...envelope });
        },
    };
}

const a = await fixture("session-a");
const b = await fixture("session-b", snapshot(10, 200));
assert.deepEqual(a.context.map((p) => p.hook), ["contextInvalidated", "context"]);
assert.equal(a.context.at(-1).currentTokens, 75, "Attachment reports already occupied context without another prompt");
assert.equal(a.context.at(-1).tokenLimit, 100, "Use the runtime's prompt budget, not a guessed model capacity");
assert.deepEqual(Object.keys(a.context.at(-1)).sort(),
    ["currentTokens", "eventId", "hook", "sessionId", "timestamp", "tokenLimit"]);
assert.ok(!JSON.stringify(a.payloads).includes("private-content"));
assert.ok(!JSON.stringify(a.payloads).includes("not-forwarded"));

for (const [name, initial] of [
    ["empty", snapshot(29, 100, 0)],
    ["fallback-model", snapshot(22, 100, 1, "default")],
    ["uninitialized", { contextAttribution: null }],
]) {
    const fresh = await fixture(`fresh-${name}`, initial);
    assert.ok(fresh.context.length > 0 && fresh.context.every((p) => p.hook === "contextInvalidated"),
        `${name} sessions must not display a speculative startup percentage`);
    fresh.advance(30_000);
    fresh.poll();
    await settle();
    assert.ok(fresh.context.every((p) => !("currentTokens" in p)), "Polling cannot fabricate startup usage");
    fresh.advance();
    fresh.read(snapshot(29, 100, 0));
    fresh.emit("session.usage_info", { currentTokens: 29, tokenLimit: 100, messagesLength: 0, isInitial: true });
    await settle();
    assert.equal(fresh.context.at(-1).hook, "contextInvalidated", "Preloaded context is not conversation activity");
    fresh.advance();
    fresh.emit("session.usage_info", { currentTokens: 32, tokenLimit: 200, messagesLength: 2 });
    await settle();
    assert.equal(fresh.context.at(-1).currentTokens, 32, "The first real usage reading keeps all context overhead");
    assert.equal(fresh.context.at(-1).tokenLimit, 200);
    const reported = fresh.context.at(-1);
    const queries = fresh.queries;
    fresh.advance(30_000);
    fresh.poll();
    fresh.emit("assistant.turn_start");
    fresh.emit("session.idle");
    await settle();
    assert.equal(fresh.queries, queries, "Polling must not overwrite a reported context reading with an estimate");
    assert.deepEqual(fresh.context.at(-1), reported, "Idle polling must not redate old reported usage as fresh");
}

const working = await fixture("working-session", snapshot(22, 100));
working.emit("session.usage_info", { currentTokens: 60, tokenLimit: 200 });
await settle();
assert.equal(working.context.at(-1).currentTokens, 60, "An attachment-time usage event beats the startup snapshot");
working.advance();
working.emit("session.usage_info", { currentTokens: 80, tokenLimit: 200 });
await settle();
const lastWorkingContext = working.context.at(-1);
assert.equal(lastWorkingContext.currentTokens / lastWorkingContext.tokenLimit, 0.4);
for (const idleSnapshot of [snapshot(29, 100), snapshot(22, 100), { contextAttribution: null }]) {
    working.advance();
    working.read(idleSnapshot);
    working.emit("session.idle");
    working.advance(30_000);
    working.poll();
    await settle();
    assert.deepEqual(working.context.at(-1), lastWorkingContext,
        "Finishing work must keep 40% reported usage, not replace it with 29%, 22% or unavailable");
}
working.advance(300_000);
working.poll();
await settle();
assert.deepEqual(working.context.at(-1), lastWorkingContext, "Idle usage must age naturally rather than look freshly reported");
working.advance();
working.emit("assistant.turn_start");
working.emit("session.usage_info", { currentTokens: 100, tokenLimit: 200 });
await settle();
assert.equal(working.context.at(-1).currentTokens, 100, "A resumed session accepts new authoritative usage");
assert.equal(b.context.at(-1).currentTokens, 10, "Another session's idle/resume cycle must not change this session");
working.advance();
working.read(snapshot(50, 400));
working.emit("session.model_change");
await settle();
assert.equal(working.context.at(-1).tokenLimit, 400, "An explicit model change permits fresh snapshot fallback again");

const awaitingUser = await fixture("attention-session", snapshot(6_000, 100_000));
awaitingUser.advance();
awaitingUser.emit("session.usage_info", { currentTokens: 6_000, tokenLimit: 100_000 });
await settle();
const beforeAttention = awaitingUser.context.at(-1);
awaitingUser.read(snapshot(76_000, 100_000));
for (let index = 0; index < 3; index++) {
    awaitingUser.advance(30_000);
    awaitingUser.poll();
    await settle();
    assert.deepEqual(awaitingUser.context.at(-1), beforeAttention,
        "Waiting for user attention must preserve reported 6% rather than poll an estimate of 76%");
}
awaitingUser.emit("session.idle");
await settle();
assert.equal(awaitingUser.context.at(-1).currentTokens / awaitingUser.context.at(-1).tokenLimit, 0.06);

for (const estimate of [snapshot(29, 100), snapshot(22, 100, 1, "default"),
    snapshot(29, 100, 0), { contextAttribution: null }]) {
    const delayed = await fixture("delayed-session");
    delayed.advance();
    delayed.read(estimate);
    delayed.poll();
    await settle();
    const previous = delayed.context.at(-1);
    delayed.emit("session.usage_info", { currentTokens: 80, tokenLimit: 200 },
        { timestamp: new Date(delayed.clock - 1).toISOString() });
    await settle();
    assert.equal(delayed.context.at(-1).currentTokens, 80,
        "A delayed usage event from this context generation supersedes any later attribution result");
    assert.ok(delayed.context.at(-1).timestamp > previous.timestamp,
        "A delayed authoritative reading must reach the native ledger");
}

a.advance();
a.read(snapshot(10, 50));
a.emit("session.model_change", { newModel: "private-model" });
await settle();
assert.deepEqual(a.context.slice(-2).map((p) => p.hook), ["contextInvalidated", "context"]);
assert.equal(a.context.at(-1).tokenLimit, 50, "Changing model replaces the denominator");
assert.equal(a.context.at(-1).currentTokens, 10);
assert.equal(b.context.at(-1).tokenLimit, 200, "Another session remains independent");
for (const type of ["session.model_change", "session.model_deselected", "session.truncation",
    "session.snapshot_rewind", "session.context_cleared", "session.compaction_start",
    "session.compaction_complete", "session.usage_info"]) {
    const count = a.payloads.length;
    a.advance();
    a.emit(type, { currentTokens: 99, tokenLimit: 100, success: true }, { agentId: "subagent" });
    await settle();
    assert.equal(a.payloads.length, count, `${type} from a subagent cannot change the root context`);
}
for (const type of ["session.model_deselected", "session.truncation", "session.snapshot_rewind", "session.compaction_complete"]) {
    a.advance();
    a.read(snapshot(5, 100));
    a.emit(type, { success: true, postCompactionTokens: 5 });
    await settle();
    assert.equal(a.context.at(-2).hook, "contextInvalidated", `${type} invalidates before reading`);
    assert.equal(a.context.at(-1).currentTokens, 5, `${type} refreshes without waiting for a prompt`);
}
a.advance();
a.emit("session.usage_info", { currentTokens: 0, tokenLimit: 100 });
await settle();
assert.equal(a.context.at(-1).currentTokens, 0, "A reported zero after clearing must replace the old count");
const afterClear = a.context.length;
a.emit("session.usage_info", { currentTokens: 90, tokenLimit: 100 },
    { timestamp: new Date(a.clock - 1).toISOString() });
await settle();
assert.equal(a.context.length, afterClear, "A delayed event cannot undo a clear");

// A new foreground session reloads the extension; a reload of the same session must also replace old state.
const cleared = await fixture("session-after-clear", snapshot(29, 100, 0));
const reloaded = await fixture("session-a", snapshot(20, 200));
assert.equal(cleared.context.at(-1).sessionId, "session-after-clear");
assert.equal(cleared.context.at(-1).hook, "contextInvalidated", "A cleared conversation must not show preload usage");
assert.equal(reloaded.context[0].hook, "contextInvalidated");
assert.equal(reloaded.context.at(-1).currentTokens, 20);

// A snapshot's local read time must not suppress a newer authoritative event delivered slightly later.
reloaded.advance();
reloaded.read(snapshot(29, 100));
reloaded.poll();
await settle();
const estimate = reloaded.context.at(-1);
reloaded.emit("session.usage_info", { currentTokens: 14, tokenLimit: 200 });
await settle();
assert.equal(reloaded.context.at(-1).currentTokens, 14, "An equal-time usage event supersedes an attribution estimate");
assert.ok(reloaded.context.at(-1).timestamp > estimate.timestamp, "The native ledger must accept the replacement");
const reportedCount = reloaded.context.length;
reloaded.emit("session.usage_info", { currentTokens: 99, tokenLimit: 100 });
reloaded.emit("session.usage_info", { currentTokens: 99, tokenLimit: 100 },
    { timestamp: new Date(reloaded.clock - 1).toISOString() });
await settle();
assert.equal(reloaded.context.length, reportedCount, "Duplicate and older usage events cannot overwrite reported usage");
reloaded.advance();
reloaded.read(snapshot(29, 100, 0));
reloaded.emit("session.context_cleared", { initialMessage: "private-content" });
await settle();
assert.equal(reloaded.context.at(-1).hook, "contextInvalidated", "Clear-without-reattachment withdraws reported usage");
reloaded.advance();
reloaded.emit("session.usage_info", { currentTokens: 8, tokenLimit: 100 });
await settle();
assert.equal(reloaded.context.at(-1).currentTokens, 8, "Usage recovers after clearing");
assert.ok(!JSON.stringify(reloaded.payloads).includes("private-content"));

let finish;
a.advance();
a.read(() => new Promise((resolve) => { finish = resolve; }));
a.emit("session.model_change");
const beforeRace = a.queries;
a.advance();
a.emit("session.model_change");
a.poll();
assert.equal(a.queries, beforeRace, "Never overlap context RPCs");
a.read(snapshot(12, 400));
finish(snapshot(99, 100));
await settle();
assert.equal(a.queries, beforeRace + 1, "Re-read once after an in-flight model change");
assert.equal(a.context.at(-1).tokenLimit, 400, "The old model's in-flight reply cannot restore the previous limit");
assert.ok(!a.context.slice(-3).some((p) => p.currentTokens === 99));

a.advance();
a.read(() => new Promise((resolve) => { finish = resolve; }));
a.emit("session.model_change");
a.advance();
a.emit("session.usage_info", { currentTokens: 22, tokenLimit: 400 });
await settle();
finish(snapshot(1, 400));
await settle();
assert.equal(a.context.at(-1).currentTokens, 22, "A newer event beats an older RPC snapshot");

a.advance();
a.read(() => new Promise((resolve) => { finish = resolve; }));
a.emit("session.model_change");
const beforeTimeout = a.queries;
await settle();
a.advance(5000);
a.timeout();
a.poll();
assert.equal(a.queries, beforeTimeout, "A stuck context RPC cannot accumulate requests");
const timeoutCount = a.context.length;
finish(snapshot(88, 100));
await settle();
assert.equal(a.context.length, timeoutCount, "Timed-out replies must not look current");
assert.equal(a.warnings.length, 1);
a.advance(30_000);
a.read(snapshot(0, 200));
a.poll();
await settle();
assert.equal(a.context.at(-1).currentTokens, 0, "Periodic polling recovers without user activity");
assert.equal(a.context.at(-1).timestamp, a.clock);

for (const invalid of [undefined, {}, { contextAttribution: {} }, snapshot(true, 100), snapshot(-1, 100),
    snapshot(1.5, 100), snapshot(0, 0), snapshot(1, "100"), snapshot(1_000_000_001, 100),
    snapshot(1, 100, -1), snapshot(1, 100, true), snapshot(1, 100, "1"), snapshot(1, 100, 1, ""),
    { contextAttribution: { totalTokens: 29, promptTokenLimit: 100 } }]) {
    a.advance();
    const count = a.context.length;
    a.read(invalid);
    a.poll();
    await settle();
    assert.equal(a.context.length, count, "Invalid responses cannot fabricate a reading");
}
a.advance();
a.read(async () => { throw new Error("private-error"); });
a.emit("session.model_change");
await settle();
assert.equal(a.context.at(-1).hook, "contextInvalidated", "Failed model-change reads cannot display the previous window");
assert.ok(!a.warnings.join("").includes("private-error"));
a.advance();
a.read({ contextAttribution: null });
a.poll();
await settle();
assert.equal(a.context.at(-1).hook, "contextInvalidated", "Uninitialized context is unknown, not zero");
assert.ok(!("currentTokens" in a.context.at(-1)));
console.log("PASS: context startup guards, authoritative session usage, clear/reload, model changes, polling, races, privacy and failures.");
