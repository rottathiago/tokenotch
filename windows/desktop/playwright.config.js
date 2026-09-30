import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./test",
  outputDir: "../test-results",
  use: { baseURL: "http://127.0.0.1:1420", viewport: { width: 860, height: 680 } },
  webServer: {
    command: "npm run dev",
    url: "http://127.0.0.1:1420",
    reuseExistingServer: false,
  },
});
