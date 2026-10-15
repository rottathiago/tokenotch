import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { checkLinks, checkMarkdown, documents } from "./check.mjs";

const require = createRequire(import.meta.url);
const markdownlintRequire = createRequire(require.resolve("markdownlint-cli2"));
const { parse: parseToml } = markdownlintRequire("smol-toml");

function fixture(t, files) {
  const root = mkdtempSync(join(tmpdir(), "tokenotch-docs-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = spawnSync("git", ["init", "--quiet", root]);
  assert.equal(git.status, 0);
  for (const [name, content] of Object.entries(files)) {
    const path = join(root, name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  }
  return root;
}

test("inventory includes hidden, nested and uppercase Markdown, not ignored/generated files", (t) => {
  const root = fixture(t, {
    "README.md": "# Readme\n",
    ".github/PULL_REQUEST_TEMPLATE.md": "## Summary\n",
    "docs/guide.MD": "# Guide\n",
    "integrations/README.markdown": "# Integration\n",
    "build/generated.md": "# Generated\n",
    "scripts/docs/node_modules/dependency/README.md": "# Dependency\n",
    ".gitignore": "ignored.md\n",
    "ignored.md": "# Ignored\n",
  });
  assert.deepEqual(documents(root), [
    ".github/PULL_REQUEST_TEMPLATE.md", "README.md", "docs/guide.MD", "integrations/README.markdown",
  ]);
});

test("Markdown structure errors fail and valid Markdown passes", (t) => {
  const root = fixture(t, { "README.md": "# Readme\n\nText.\n" });
  assert.doesNotThrow(() => checkMarkdown(root, ["README.md"]));
  writeFileSync(join(root, "README.md"), "# Readme\nText without a heading separator.\n");
  assert.throws(() => checkMarkdown(root, ["README.md"]), /MD022/);
});

test("inline and display math preserve Markdown checks", (t) => {
  const content = "# Math\n\nInline $x + y$.\n\n$$\nx^2 + y^2 = z^2\n$$\n";
  const root = fixture(t, { "README.md": content });
  assert.doesNotThrow(() => checkMarkdown(root, ["README.md"]));
  writeFileSync(join(root, "README.md"), content.replace("# Math\n\n", "# Math\n"));
  assert.throws(() => checkMarkdown(root, ["README.md"]), /MD022/);
});

test("TOML configuration handles independent keys and rejects malformed input", () => {
  const config = parseToml('globs = ["**/*.md"]\n[config]\nMD013 = false\n');
  assert.deepEqual(config.globs, ["**/*.md"]);
  assert.deepEqual(Object.entries(config.config), [["MD013", false]]);
  const entries = Array.from({ length: 2048 }, (_, index) => [`key${index}`, index]);
  const content = entries.map(([key, value]) => `${key} = ${value}`).join("\n");
  assert.deepEqual(Object.entries(parseToml(content)), entries);
  assert.throws(() => parseToml("key = ["));
});

test("local fragments, duplicate heading slugs, reference links and archived relative paths resolve", (t) => {
  const root = fixture(t, {
    "README.md": "# Readme\n\n[One](#topic) [Two](#topic-1) [Guide][guide]\n\n## Topic\n\nA.\n\n## Topic\n\nB.\n\n[guide]: docs/plans/history.md#history\n",
    "docs/plans/history.md": "# History\n\n[Readme](../../README.md)\n",
  });
  assert.doesNotThrow(() => checkLinks(root, documents(root)));
});

test("missing local file fails, including hidden Markdown", (t) => {
  const root = fixture(t, { ".github/guide.md": "# Guide\n\n[Missing](missing.md)\n" });
  assert.throws(() => checkLinks(root, documents(root)), /missing\.md/);
});

test("uppercase Markdown is checked, not merely inventoried", (t) => {
  const root = fixture(t, { ".github/guide.MD": "# Guide\n\n[Missing](missing.md)\n" });
  assert.throws(() => checkLinks(root, documents(root)), /missing\.md/);
});

test("missing local heading fails", (t) => {
  const root = fixture(t, { "README.md": "# Readme\n\n[Missing](#not-a-heading)\n" });
  assert.throws(() => checkLinks(root, documents(root)), /not-a-heading/);
});

test("reference link destinations are checked", (t) => {
  const root = fixture(t, { "README.md": "# Readme\n\n[Missing][target]\n\n[target]: missing.md\n" });
  assert.throws(() => checkLinks(root, documents(root)), /missing\.md/);
});

test("HTML images and picture source paths are checked", (t) => {
  const root = fixture(t, {
    "README.md": '# Readme\n\n<picture><source srcset="missing.png"><img src="image.png" alt="Fixture"></picture>\n',
    "image.png": "fixture",
  });
  assert.throws(() => checkLinks(root, documents(root)), /missing\.png/);
  writeFileSync(join(root, "missing.png"), "fixture");
  assert.doesNotThrow(() => checkLinks(root, documents(root)));
  writeFileSync(join(root, "README.md"), '# Readme\n\n<img src="absent.png" alt="Fixture">\n');
  assert.throws(() => checkLinks(root, documents(root)), /absent\.png/);
});

test("filename case mismatches fail on case-sensitive filesystems", (t) => {
  const root = fixture(t, {
    "README.md": "# Readme\n\n[Guide](guide.md)\n",
    "Guide.md": "# Guide\n",
  });
  if (existsSync(join(root, "guide.md"))) return t.skip("Requires a case-sensitive filesystem; run in Linux CI.");
  assert.throws(() => checkLinks(root, documents(root)), /guide\.md/);
});

test("offline mode does not require external endpoints", (t) => {
  const root = fixture(t, {
    "README.md": "# Readme\n\n[Offline example](https://nonexistent.invalid)\n",
  });
  assert.doesNotThrow(() => checkLinks(root, documents(root)));
});
