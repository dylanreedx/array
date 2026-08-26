import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 30_000,
  expect: { toHaveScreenshot: { animations: 'disabled', maxDiffPixelRatio: 0.01 } },
  use: {
    baseURL: 'http://127.0.0.1:4321',
    trace: 'retain-on-failure'
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 960 } } },
    {
      name: 'webkit',
      grepInvert: /round-one checkpoints/,
      use: { ...devices['Desktop Safari'], viewport: { width: 1440, height: 960 } }
    }
  ],
  webServer: {
    command: 'pnpm build && pnpm preview --host 127.0.0.1',
    url: 'http://127.0.0.1:4321/',
    reuseExistingServer: true,
    timeout: 120_000
  }
});
