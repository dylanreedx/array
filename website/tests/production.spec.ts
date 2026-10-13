import { expect, test } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
async function seek(page: import('@playwright/test').Page, progress: number) {
  await page.locator('[data-narrative]').evaluate((el, value) => scrollTo(0, el.getBoundingClientRect().top + scrollY + (el.getBoundingClientRect().height - innerHeight) * value), progress);
}
test('homepage links, downloads and theme work', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Keep every agent in view.', level: 1 })).toBeVisible();
  await expect(page.locator('.production-header nav a')).toHaveAttribute('href', 'https://github.com/dylanreedx/array');
  await expect(page.locator('[data-testid=download-main]').first()).toHaveAttribute('href', /Array\.dmg$/);
  await page.locator('[data-testid=download-trigger]').first().click();
  await expect(page.locator('[data-testid=download-popover]').first()).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('[data-testid=download-popover]').first()).toBeHidden();
  await page.locator('[data-theme-toggle]').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
});
test('scroll narrates all eight beats and reverses deterministically', async ({ page }) => {
  await page.goto('/');
  const root = page.locator('[data-narrative]');
  const ids = ['canvas', 'zone', 'agent', 'task', 'parallel', 'approval', 'tools', 'overview'];
  for (let i = 0; i < ids.length; i++) {
    await seek(page, (i + .75) / 8);
    await expect(root).toHaveAttribute('data-step', ids[i]);
    await expect(page.locator('[data-story-caption]:visible')).toHaveCount(1);
  }
  const transform = await page.locator('[data-story-world]').getAttribute('style');
  await seek(page, .05);
  await expect(root).toHaveAttribute('data-step', 'canvas');
  await expect(page.locator('.story-zone')).toHaveAttribute('data-visible', 'false');
  await seek(page, 7.75 / 8);
  await expect(root).toHaveAttribute('data-step', 'overview');
  await expect(page.locator('[data-story-world]')).toHaveAttribute('style', transform!);
});
test('cursor creates a project zone and agent from the toolbar without visitor interaction', async ({ page }) => {
  await page.goto('/');
  await seek(page, 1.2 / 8);
  await expect(page.locator('.story-project-picker')).toBeVisible();
  await expect(page.locator('.story-zone')).toHaveAttribute('data-visible', 'false');
  const cursor = await page.locator('[data-story-cursor]').boundingBox();
  const target = await page.locator('[data-toolbar-zone]').boundingBox();
  expect(cursor!.x).toBeCloseTo(target!.x + target!.width / 2, 0);
  expect(cursor!.y).toBeCloseTo(target!.y + target!.height / 2, 0);
  await seek(page, 1.8 / 8);
  await expect(page.locator('.story-zone')).toHaveAttribute('data-visible', 'true');
  await seek(page, 2.2 / 8);
  await expect(page.locator('.story-provider-picker')).toBeVisible();
  await seek(page, 2.8 / 8);
  await expect(page.locator('.story-agent--0')).toHaveAttribute('data-visible', 'true');
  await expect(page.locator('.story-provider-picker')).toBeHidden();
});
test('task typing, provider parity, approval and neighboring tools appear in order', async ({ page }) => {
  await page.goto('/');
  await seek(page, 3.3 / 8);
  await expect(page.locator('[data-typed-task]')).toContainText('Build a settings');
  await seek(page, 4.8 / 8);
  await expect(page.locator('.story-agent[data-visible=true]')).toHaveCount(3);
  await seek(page, 5.8 / 8);
  await expect(page.locator('.story-approval')).toHaveAttribute('data-visible', 'true');
  await seek(page, 6.8 / 8);
  await expect(page.locator('.story-terminal')).toHaveAttribute('data-visible', 'true');
  await expect(page.locator('.story-browser')).toHaveAttribute('data-visible', 'true');
});
test('page has no ready gate and keyboard scrolling reaches download', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByTestId('interaction-ready-cue')).toHaveCount(0);
  await page.keyboard.press('End');
  await expect(page.getByRole('heading', { name: 'More work. Less hidden state.' })).toBeVisible();
});
test('desktop, mobile and reduced motion remain accessible', async ({ page }) => {
  await page.goto('/');
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await seek(page, .71);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await page.setViewportSize({ width: 390, height: 844 });
  await seek(page, .44);
  await expect(page.locator('[data-narrative]')).toHaveAttribute('data-step', 'task');
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(page.locator('[data-narrative]')).toHaveAttribute('data-step', 'overview');
  await expect(page.locator('[data-story-cursor]')).toBeHidden();
  await expect(page.getByRole('heading', { name: 'The demo, step by step' })).toBeVisible();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});
test('home and legal pages emit complete metadata and accurate linked legal copy', async ({ page }) => {
  for (const route of ['/', '/privacy', '/terms']) {
    await page.goto(route);
    await expect(page.locator('link[rel=canonical]')).toHaveAttribute('href', `https://arrayapp.dev${route}`);
    await expect(page.locator('meta[property="og:image"]')).toHaveAttribute('content', 'https://arrayapp.dev/og-image.png');
    await expect(page.locator('meta[property="og:image:width"]')).toHaveAttribute('content', '1200');
    await expect(page.locator('meta[property="og:image:height"]')).toHaveAttribute('content', '630');
    await expect(page.locator('meta[name="twitter:card"]')).toHaveAttribute('content', 'summary_large_image');
    expect(JSON.parse((await page.locator('script[type="application/ld+json"]').textContent())!)).toMatchObject({ '@type': 'SoftwareApplication', operatingSystem: 'macOS', offers: { price: '0' } });
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  }
  await page.goto('/privacy');
  await expect(page.locator('main')).toContainText('We do not use analytics today');
  await expect(page.locator('main')).toContainText('Your workspace data stays on your Mac');
});
