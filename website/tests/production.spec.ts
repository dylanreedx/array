import { expect, test } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
async function seek(page: import('@playwright/test').Page, progress: number) {
  await page.locator('[data-assembly-root]').evaluate((el, value) => scrollTo(0, el.getBoundingClientRect().top + scrollY + (el.getBoundingClientRect().height - innerHeight) * value), progress);
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
test('original hero copy and floating tile composition are restored', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.hero-copy__body')).toHaveText('Launch agents and tools from anywhere. Array keeps everything they touch visible on one native workspace.');
  await expect(page.getByText('A native workspace for your coding agents', { exact: true })).toHaveCount(0);
  await expect(page.locator('[data-assembly-surface]')).toHaveCount(6);
  await expect(page.locator('[data-assembly-root]')).toHaveAttribute('data-installed', 'true');
  const nav = await page.locator('.production-header__inner').evaluate(el => ({ border: getComputedStyle(el).borderWidth, width: el.clientWidth }));
  expect(nav.border).toBe('0px');
  const github = await page.locator('.production-header nav').boundingBox();
  expect(github!.x).toBeGreaterThan(nav.width / 2);
  await expect(page.locator('.story-kicker, .story-progress, .story-copy')).toHaveCount(0);
  await expect(page.locator('video')).not.toHaveAttribute('src');
});
test('scroll seeks the real native film forward and backward', async ({ page }) => {
  await page.goto('/');
  await seek(page, .6);
  const video = page.locator('[data-native-film] video');
  await expect.poll(() => video.evaluate(v => (v as HTMLVideoElement).currentTime)).toBeGreaterThan(20);
  await expect.poll(() => video.evaluate(v => (v as HTMLVideoElement).seeking)).toBe(false);
  const midpoint = await video.evaluate(v => (v as HTMLVideoElement).currentTime);
  await expect(video).toHaveAttribute('src', '/videos/array-native-tour.mp4');
  await seek(page, .36);
  await expect.poll(() => video.evaluate(v => (v as HTMLVideoElement).currentTime)).toBeLessThan(10);
  await seek(page, .6);
  await expect.poll(async () => Math.abs(await video.evaluate(v => (v as HTMLVideoElement).currentTime) - midpoint)).toBeLessThan(.1);
  expect(await video.evaluate(v => (v as HTMLVideoElement).error)).toBeNull();
  await expect(page.locator('.story-toolbar, .story-agent, .story-project-picker')).toHaveCount(0);
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
  await page.evaluate(() => scrollTo(0, 0));
  await expect(page.locator('[data-assembly-root]')).toHaveAttribute('data-assembly-phase', 'glimpse');
  const copy = await page.locator('.hero-copy__requirements').boundingBox();
  const floating = await page.locator('[data-assembly-surface=browser]').boundingBox();
  expect(floating!.y).toBeGreaterThan(copy!.y + copy!.height);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(page.locator('.hero-copy h1')).toBeVisible();
  await expect(page.locator('[data-native-film] video')).toHaveJSProperty('controls', true);
  await page.keyboard.press('End');
  await expect(page.locator('video')).toHaveJSProperty('currentTime', 0);
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
