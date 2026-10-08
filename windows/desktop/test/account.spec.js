import { test, expect } from "@playwright/test";

const quota = remaining => ({ id: "premium_interactions", isUnlimitedEntitlement: false,
  entitlementRequests: 300, usedRequests: 300 * (1 - remaining / 100), remainingPercentage: remaining });
const account = remaining => ({ login: "fixture-user", plan: "Pro", observedAt: Date.now(),
  runtimeVersion: "fixture", quotas: [quota(remaining)] });

async function fixture(page, state = {}) {
  await page.addInitScript(state => {
    window.__accountState = state;
    window.__accountActions = [];
    window.__links = [];
    window.__chosenFiles = 0;
  }, state);
  await page.route("**/src/bridge.js", async route => {
    const response = await route.fetch();
    await route.fulfill({ response, body: `${await response.text()}
      const baseSnapshot = bridge.snapshot.bind(bridge);
      bridge.snapshot = async () => ({ ...await baseSnapshot(), ...window.__accountState });
      bridge.chooseFile = async () => { window.__chosenFiles++; return "C:\\\\Copilot\\\\copilot.exe"; };
      bridge.account = async operation => {
        window.__accountActions.push(operation);
        if (operation === "signOut") {
          window.__accountState = { account: null, accountAuth: {status:"signedOut"}, accountError: null };
          await bridge.preferences({...((await baseSnapshot()).preferences), accountEnabled:false});
          return;
        }
        if (window.__holdAccount) await new Promise(resolve => { window.__finishAccount = resolve; });
        window.__accountState = { account: ${JSON.stringify(account(75))}, accountAuth: {status:"signedIn",login:"fixture-user"} };
      };
      bridge.link = async target => { window.__links.push(target); };
      bridge.companion = async () => "C:\\\\Tokenotch\\\\TokenotchVSCode.vsix";
      bridge.installCompanion = async () => {
        window.__companionInstalls = (window.__companionInstalls ?? 0) + 1;
        if (window.__noVSCode) throw new Error("VS Code was not found.");
        return "vscodeSetup";
      };
      bridge.connection = async (source,operation,metrics) => {
        window.__editorRequest = {source,operation,metrics};
        window.__accountState.connections = {cli:false,vscode:false,
          vscodeSetup:{status:"pending",operation:operation==="install"?"configure":"remove",canOpen:true}};
      };` });
  });
}

test("Usage signs in with explicit quota consent, shows identity and percentage, then signs out", async ({ page }) => {
  await fixture(page);
  await page.goto("/?page=usage");
  await expect(page.locator("#usage-account-identity")).toHaveText("GitHub account not connected");
  await expect(page.locator("#quota")).toContainText("Usage percentage: Not reported");
  await expect(page.getByRole("button", { name: "Refresh quota", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Sign in with GitHub", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("Enable account quota");
  await expect(page.getByRole("dialog")).toContainText("existing Copilot CLI sign-in");
  expect(await page.evaluate(() => window.__accountActions)).toEqual([]);
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.locator("#usage-account-identity")).toHaveText("Signed in as @fixture-user");
  expect(await page.evaluate(() => window.__chosenFiles)).toBe(0);
  await expect(page.getByRole("button", { name: "Sign in with GitHub", exact: true })).toBeHidden();
  await expect(page.locator("#quota .plan-percent")).toHaveText("25% used");
  await expect(page.locator("#quota")).toContainText("75 of 300");
  await expect(page.getByRole("button", { name: "Refresh quota", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await expect(page.getByRole("dialog")).toContainText("normal Copilot sign-in is untouched");
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.locator("#usage-account-identity")).toHaveText("Signed out of GitHub");
  await expect(page.locator("#quota")).toContainText("Usage percentage: Not reported");
  expect(await page.evaluate(() => window.__accountActions)).toEqual(["signIn", "signOut"]);
});

test("Usage keeps authentication visible when quota is unavailable and never invents a percentage", async ({ page }) => {
  await fixture(page, { accountAuth: {status:"signedIn",login:"fixture-user"},
    accountError:"Copilot denied the quota request.", account:null });
  await page.goto("/?page=usage");
  await expect(page.locator("#usage-account-identity")).toHaveText("Signed in as @fixture-user");
  await expect(page.locator("#quota")).toContainText("Usage percentage: Not reported");
  await expect(page.locator("#usage-account-status")).toContainText("denied the quota request");
  await expect(page.getByRole("button", { name: "Sign out", exact: true })).toBeEnabled();
});

test("Usage renders exact empty/full percentages and labels unlimited entitlement without a fake percent", async ({ page }) => {
  await fixture(page, {account:account(100)});
  await page.goto("/?page=usage");
  await expect(page.locator("#quota .plan-percent")).toHaveText("0% used");
  await page.evaluate(value => { window.__accountState.account = value; }, account(0));
  await page.getByRole("button", { name:"Refresh status", exact:true }).click();
  await expect(page.locator("#quota .plan-percent")).toHaveText("100% used");
  await page.evaluate(() => { window.__accountState.account.quotas[0].isUnlimitedEntitlement = true; });
  await page.getByRole("button", { name:"Refresh status", exact:true }).click();
  await expect(page.locator("#quota")).toContainText("Unlimited");
  await expect(page.locator("#quota .plan-percent")).toHaveCount(0);
});

test("account controls show progress and prevent sign-out during browser authentication", async ({ page }) => {
  await fixture(page);
  await page.goto("/?page=usage");
  await page.evaluate(() => { window.__holdAccount = true; });
  await page.getByRole("button", { name:"Sign in with GitHub", exact:true }).click();
  await page.getByRole("button", { name:"Continue", exact:true }).click();
  await expect(page.locator("#usage-account-status")).toHaveText("Account operation in progress...");
  await expect(page.getByRole("button", { name:"Sign out", exact:true })).toBeDisabled();
  await expect.poll(() => page.evaluate(() => typeof window.__finishAccount)).toBe("function");
  await page.evaluate(() => { window.__finishAccount(); });
  await expect(page.getByRole("button", { name:"Sign out", exact:true })).toBeEnabled();
});

test("VS Code connect installs the companion, opens the consent handoff and does not equate pending approval with connection", async ({ page }) => {
  await fixture(page);
  await page.goto("/");
  await expect(page.getByLabel("Capture Copilot model & token telemetry", {exact:false})).toBeChecked();
  await expect(page.getByRole("button", { name:"Continue setup in VS Code", exact:true })).toBeHidden();
  await page.getByRole("button", { name:"Connect VS Code", exact:true }).click();
  await expect(page.getByRole("dialog")).toContainText("installs its setup companion");
  await page.getByRole("button", { name:"Continue", exact:true }).click();
  await expect(page.locator("#vscode-status")).toContainText("Not connected");
  await expect(page.locator("#vscode-result")).toContainText("Waiting for approval in VS Code");
  expect(await page.evaluate(() => window.__editorRequest)).toEqual({source:"vscode",operation:"install",metrics:true});
  expect(await page.evaluate(() => window.__companionInstalls)).toBe(1);
  expect(await page.evaluate(() => window.__links)).toEqual(["vscodeSetup"]);
  await expect(page.getByRole("button", { name:"Continue setup in VS Code", exact:true })).toBeVisible();
  await page.locator(".connection-card details summary", { hasText: "Advanced" }).click();
  await page.getByRole("button", { name:"Continue in VS Code Insiders", exact:true }).click();
  expect(await page.evaluate(() => window.__links.at(-1))).toBe("vscodeInsidersSetup");
  await page.evaluate(() => { window.__accountState.connections.vscodeSetup = {status:"expired",canOpen:false}; });
  await page.getByRole("button", { name:"Refresh status", exact:true }).click();
  await expect(page.locator("#vscode-result")).toContainText("approval expired");
  await expect(page.getByRole("button", { name:"Continue setup in VS Code", exact:true })).toBeHidden();
});

test("VS Code connect falls back to the bundled extension when VS Code is not detected", async ({ page }) => {
  await fixture(page);
  await page.goto("/");
  await page.evaluate(() => { window.__noVSCode = true; });
  await page.getByLabel("Capture Copilot model & token telemetry", {exact:false}).uncheck();
  await page.getByRole("button", { name:"Connect VS Code", exact:true }).click();
  await page.getByRole("button", { name:"Continue", exact:true }).click();
  await expect(page.locator("#companion-location")).toContainText("VS Code was not found");
  await expect(page.locator("#companion-location")).toContainText("TokenotchVSCode.vsix");
  expect(await page.evaluate(() => window.__editorRequest)).toEqual({source:"vscode",operation:"install",metrics:false});
  expect(await page.evaluate(() => window.__links)).toEqual(["vscodeCompanion"]);
});
