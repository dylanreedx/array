import { expect, test } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

// Test the rendered documentation, including the content collection's routes.
test('all documentation links and section anchors resolve', async ({ page, request }) => {
  await page.goto('/docs/');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Know what’s possible.');
  const urls = await page.locator('.docs-card').evaluateAll(links => links.map(link => link.getAttribute('href')!));
  expect(urls).toHaveLength(14);
  for (const url of urls) {
    const response = await page.goto(url);
    expect(response?.status(), url).toBe(200);
    await expect(page.locator('h1')).toHaveCount(1);
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', `https://arrayapp.dev${url}`);
    const targets = await page.locator('.docs-main a[href], .docs-outline a[href]').evaluateAll(links => links.map(link => link.getAttribute('href')!).filter(href => href.startsWith('/') || href.startsWith('#')));
    for (const target of new Set(targets)) {
      if (target.startsWith('#')) {
        expect(await page.locator(`[id="${target.slice(1)}"]`).count(), `${url}${target}`).toBe(1);
      } else {
        const linked = await request.get(target);
        expect(linked.status(), `${url} → ${target}`).toBe(200);
        const hash = target.split('#')[1];
        if (hash) expect(await linked.text(), `${url} → ${target}`).toContain(`id="${hash}"`);
      }
    }
  }
});

test('search finds body text and restores navigation with Escape', async ({ page }) => {
  await page.goto('/docs/');
  const search = page.getByRole('searchbox', { name: 'Search documentation' });
  await search.fill('idempotency');
  const results = page.locator('#docs-search-results');
  await expect(results.getByRole('link', { name: /Agents on the canvas/ })).toBeVisible();
  await expect(page.locator('.docs-search-status')).toContainText('guides found');
  await search.fill('no-such-feature-123');
  await expect(results).toContainText('No guides found');
  await search.press('Escape');
  await expect(results).toBeHidden();
  await expect(page.getByRole('navigation', { name: 'Guides', exact: true })).toBeVisible();
  await search.fill('thread/compact/start');
  await results.getByRole('link', { name: /Context and compaction/ }).click();
  await expect(page).toHaveURL(/\/docs\/compaction\//);
});

test('documentation is readable on mobile and themes persist', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/docs/storage/');
  await expect(page.getByRole('link', { name: 'Docs', exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await expect(page.getByRole('navigation', { name: 'Guides', exact: true })).toBeHidden();
  await page.locator('.docs-browse summary').click();
  await expect(page.getByRole('navigation', { name: 'Guides', exact: true })).toBeVisible();
  await page.locator('.docs-browse summary').click();
  await expect(page.getByRole('navigation', { name: 'Guides', exact: true })).toBeHidden();
  const initial = await page.locator('html').getAttribute('data-theme');
  await page.locator('[data-theme-toggle]').click();
  const next = initial === 'dark' ? 'light' : 'dark';
  await expect(page.locator('html')).toHaveAttribute('data-theme', next);
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', next);
});

test('docs support keyboard access and have no automated accessibility violations', async ({ page, browserName }) => {
  for (const url of ['/docs/', '/docs/canvas-tools/', '/docs/storage/']) {
    await page.goto(url);
    const results = await new AxeBuilder({ page }).analyze();
    expect(results.violations, url).toEqual([]);
  }
  await page.goto('/docs/');
  await page.keyboard.press(browserName === 'webkit' ? 'Alt+Tab' : 'Tab');
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.locator('#docs-content')).toBeFocused();
});
