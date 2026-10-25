import { defineConfig } from '@playwright/test';

/** Браузерные проверки страницы по ссылке (006): сервер из dist/ на временной папке данных. */
export default defineConfig({
  testDir: 'e2e',
  outputDir: 'e2e-results/output',
  fullyParallel: true,
  timeout: 30_000,
  reporter: 'line',
  use: { browserName: 'chromium' },
});
