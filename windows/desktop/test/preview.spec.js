import { test, expect } from "@playwright/test";

test("browser preview states collection is off and offers working appearance controls", async ({ page }) => {
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Not collecting usage" })).toBeVisible();
  await expect(page.getByRole("status")).toContainText("Browser preview");
  await page.getByRole("button", { name: "Appearance", exact: true }).click();
  await page.getByLabel("Screen edge").selectOption("bottom");
  await expect(page.locator("#preview-widget")).toHaveAttribute("data-edge", "bottom");
  await page.getByLabel("Show activity widget").uncheck();
  await expect(page.locator("#preview-widget")).toBeHidden();
  await page.getByRole("button", { name: "About", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Not a supported Windows release" })).toBeVisible();
  expect(errors).toEqual([]);
});

test("narrow layout keeps navigation and status reachable", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.getByRole("status")).toContainText("Browser preview");
  await page.getByRole("button", { name: "Appearance", exact: true }).click();
  await expect(page.getByLabel("Screen edge")).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: "../test-results/appearance-narrow.png", fullPage: true });
});

test("widget hover expands without invented usage values", async ({ page }) => {
  await page.goto("/?surface=widget");
  await page.locator(".edge-widget").hover({ position: { x: 15, y: 30 } });
  await expect(page.getByRole("heading", { name: "No connections yet" })).toBeVisible();
  await page.screenshot({ path: "../test-results/widget.png" });
  await page.getByRole("button", { name: "Open settings", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Connections", exact: true })).toBeVisible();
});
