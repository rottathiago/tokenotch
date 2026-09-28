import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const repository = resolve(directory, "../..");
const tools = JSON.parse(readFileSync(resolve(directory, "package.json"), "utf8"));

function execute(command, args, root, input) {
  const env = { ...process.env };
  delete env.GITHUB_TOKEN;
  delete env.GH_TOKEN;
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8", input, env });
  if (result.error) throw new Error(`Cannot run ${command}: ${result.error.message}. See CONTRIBUTING.md prerequisites.`);
  if (result.status !== 0) {
    throw new Error(`${command} failed (${result.status ?? result.signal}):\n${result.stdout}${result.stderr}`);
  }
  return result.stdout;
}

export function documents(root) {
  const paths = execute("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], root);
  const files = [...new Set(paths.split("\0"))].filter((file) =>
    /\.(md|mdx|markdown)$/i.test(file) &&
    !/(^|\/)(node_modules|build|\.build|DerivedData|\.git)\//.test(file) &&
    existsSync(resolve(root, file))
  ).sort();
  if (files.length === 0) throw new Error("No publishable Markdown files found.");
  for (const file of files) {
    if (/[\r\n]/.test(file) || !lstatSync(resolve(root, file)).isFile()) {
      throw new Error(`Unsupported documentation path: ${JSON.stringify(file)}`);
    }
  }
  return files;
}

export function checkMarkdown(root, files) {
  const cli = resolve(directory, "node_modules/markdownlint-cli2/markdownlint-cli2-bin.mjs");
  if (!existsSync(cli)) throw new Error("Install documentation dependencies with npm ci --prefix scripts/docs --ignore-scripts --no-audit --no-fund.");
  return execute(process.execPath, [cli, "--config", resolve(repository, ".markdownlint-cli2.jsonc"),
    "--no-globs", ...files.map((file) => `:${file}`)], root);
}

export function checkLinks(root, files, external = false) {
  const version = execute("lychee", ["--version"], root).trim();
  if (version !== `lychee ${tools.config.lycheeVersion}`) {
    throw new Error(`Expected lychee ${tools.config.lycheeVersion}, found ${version}. See CONTRIBUTING.md.`);
  }
  return execute("lychee", ["--config", resolve(repository, "lychee.toml"),
    ...(external ? ["--scheme", "https"] : ["--offline"]),
    "--files-from", "-"], root, `${files.join("\n")}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const args = process.argv.slice(2);
    if (args.length > 1 || (args.length === 1 && args[0] !== "--external")) {
      throw new Error("Usage: node scripts/docs/check.mjs [--external]");
    }
    const external = args[0] === "--external";
    const files = documents(process.cwd());
    if (!external) process.stdout.write(checkMarkdown(process.cwd(), files));
    process.stdout.write(checkLinks(process.cwd(), files, external));
    console.log(`${files.length} Markdown files checked (${external ? "advisory external HTTPS links" : "offline Markdown and local links"}).`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
