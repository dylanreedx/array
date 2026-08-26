import { readFile } from 'node:fs/promises';
import { expect, test } from '@playwright/test';

test('Mac canvas declares the active-only native input boundary', async () => {
  const source = await readFile(new URL('../src/components/demo/mac/MacWorkspace.tsx', import.meta.url), 'utf8');
  const css = await readFile(new URL('../src/components/demo/mac/MacWorkspace.module.css', import.meta.url), 'utf8');

  expect(source).toContain("state.inputMode === 'workspace' && state.deviceFocus === 'mac'");
  expect(source).toContain("canvas.addEventListener('wheel', handleWheel, { passive: false })");
  expect(source).toContain('event.preventDefault()');
  expect(source).toContain('event.stopPropagation()');
  expect(source).toContain("dispatch({ type: 'SET_INPUT_MODE', mode: 'page' })");
  expect(source).toContain('data-interaction-id="done-exploring"');
  expect(source).toContain('data-interaction-id="reset-demo"');
  expect(source).toContain('data-assembly-surface={tile.id}');
  expect(css).toMatch(/\.canvasInputActive\s*\{[^}]*overscroll-behavior:\s*contain;[^}]*touch-action:\s*none;/s);
  expect(css).toMatch(/\.canvas\s*\{[^}]*overscroll-behavior:\s*auto;[^}]*touch-action:\s*auto;/s);
});

test('compact download has only essential copy and header has no obsolete section links', async ({ page }) => {
  await page.goto('/');

  const navDownload = page.locator('[data-testid="download-nav"]');
  await expect(navDownload.locator('[data-testid="download-main"]')).toHaveText('Download for Mac');
  await expect(navDownload).not.toContainText('Free during alpha');
  await navDownload.locator('[data-testid="download-trigger"]').click();
  await expect(navDownload.locator('[data-testid="download-popover"]')).toHaveText(/Array for Mac/);
  await expect(navDownload.locator('[data-testid="download-popover"]')).toHaveText(/Array CompanionComing soon/);
  await expect(page.locator('.production-header nav')).toHaveCount(0);
});
