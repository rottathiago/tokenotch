import test from "node:test";
import assert from "node:assert/strict";
import { runtimeDescription, validateStatus, validateEdge } from "../../desktop/src/state.js";

const status = {
  version: "1.0.0", channel: "development", connectionsEnabled: false,
  edge: "right", widgetVisible: true, minimumWindowsBuild: 26100,
  runtime: { platform: "windows", executableArchitecture: "aarch64", windowsBuild: 26100 },
};

test("native runtime describes executable architecture without asserting native OS architecture", () => {
  assert.equal(validateStatus(status), status);
  assert.match(runtimeDescription(status), /ARM64 executable/);
  assert.match(runtimeDescription(status), /verified separately/);
});

test("browser and macOS preview never claim Windows acceptance", () => {
  for (const [platform, text] of [["browser", /Browser preview/], ["macos", /does not verify Windows/]]) {
    assert.match(runtimeDescription({ ...status, runtime: { ...status.runtime, platform } }), text);
  }
});

test("unsupported status fails explicitly rather than showing connected or zero usage", () => {
  for (const value of [null, {}, { ...status, connectionsEnabled: true }, { ...status, edge: "diagonal" },
    { ...status, widgetVisible: 1 }, { ...status, channel: "release" },
    { ...status, runtime: { ...status.runtime, windowsBuild: "26100" } }]) {
    assert.throws(() => validateStatus(value), /unsupported application status/);
  }
});

test("edge selection is an allowlist", () => {
  for (const edge of ["left", "right", "top", "bottom"]) assert.equal(validateEdge(edge), edge);
  for (const edge of ["", "center", null, {}, 1]) assert.throws(() => validateEdge(edge));
});
