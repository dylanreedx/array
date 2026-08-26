import { expect, test } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { isInteractionRegistered } from '../src/features/demo/interaction-contract';

async function revealDemo(page: import('@playwright/test').Page) {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(page.locator('[data-assembly-root]')).toHaveAttribute('data-assembly-phase', 'ready');
  await expect(page.locator('[data-mac-workspace]')).toBeVisible();
  await page.getByRole('button', { name: 'Use the workspace' }).click();
}

test('static hero, premium download menu, navigation, and theme work without demo hydration', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Keep every agent in view.' })).toBeVisible();
  await expect(page.locator('[data-testid="download-main"]').first()).toHaveAttribute('href', /Array\.dmg$/);
  await page.locator('[data-testid="download-trigger"]').first().click();
  await expect(page.locator('[data-testid="download-popover"]').first()).toBeVisible();
  await expect(page.locator('[data-testid="download-companion"]').first()).toHaveAttribute('aria-disabled', 'true');
  await page.keyboard.press('Escape');
  await expect(page.locator('[data-testid="download-popover"]').first()).toBeHidden();
  await page.locator('[data-theme-toggle]').click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
});

test('assembly reaches stable exact endpoints without creating another demo', async ({ page }) => {
  await page.goto('/');
  const track = page.locator('[data-assembly-root]');
  await page.evaluate(() => scrollTo(0, 0));
  await expect(track).toHaveAttribute('data-assembly-phase', 'glimpse');
  await page.getByRole('button', { name: 'See all of it ↓' }).click();
  await expect(track).toHaveAttribute('data-assembly-phase', 'ready', { timeout: 8_000 });
  await expect(page.locator('[data-mac-workspace]')).toBeVisible();
  await expect(page.locator('[data-mac-workspace]')).toHaveCount(1);
  await expect(page.locator('[data-testid="companion"]')).toHaveCount(1);
  await expect(page.locator('[data-presentation-layer]')).toHaveCount(0);
  await page.evaluate(() => scrollTo(0, 0));
  await expect(track).toHaveAttribute('data-assembly-phase', 'glimpse');
});

test('ready workspace advertises interaction and removes the cue after activation', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(page.locator('[data-assembly-root]')).toHaveAttribute('data-assembly-phase', 'ready');
  const cue = page.getByTestId('interaction-ready-cue');
  await expect(cue).toBeVisible();
  await expect(cue).toContainText('Take control.');
  await expect(cue).toContainText('Move a tile. Tidy the canvas. Open Command Center. Approve work from Companion.');
  await page.getByRole('button', { name: 'Use the workspace' }).click();
  await expect(cue).toHaveCount(0);
  await expect(page.locator('[data-demo-root]')).toHaveAttribute('data-input-mode', 'workspace');
});

test('ready workspace has a stable scroll shelf before the track ends', async ({ page }) => {
  await page.goto('/');
  const track = page.locator('[data-assembly-root]');
  await page.getByRole('button', { name: 'See all of it ↓' }).click();
  await expect(track).toHaveAttribute('data-assembly-phase', 'ready', { timeout: 8_000 });
  const shelf = await track.evaluate((element) => {
    const top = element.getBoundingClientRect().top + scrollY;
    const available = element.getBoundingClientRect().height - innerHeight;
    return { scrollY, top, available, remaining: top + available - scrollY };
  });
  expect(shelf.remaining).toBeGreaterThan(page.viewportSize()!.height * .3);
  const heldAt = await page.evaluate(() => scrollY);
  await page.mouse.wheel(0, 180);
  await page.waitForTimeout(120);
  expect(await page.evaluate(() => scrollY)).toBe(heldAt);
  await expect(track).toHaveAttribute('data-assembly-phase', 'ready');
  await expect(track).toHaveAttribute('data-ready-gate', 'held');
  await expect(page.getByTestId('interaction-ready-cue')).toBeVisible();
  await page.getByRole('button', { name: 'Keep scrolling' }).click();
  await expect(track).toHaveAttribute('data-ready-gate', 'released');
  await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(heldAt);
});

test('native provider marks identify Codex, Claude, and Pi across the paired workspace', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(page.locator('[data-provider-mark="openai"]').first()).toBeVisible();
  await expect(page.locator('[data-provider-mark="anthropic"]').first()).toBeVisible();
  await expect(page.locator('[data-provider-mark="pi"]').first()).toBeVisible();
  await expect(page.locator('[data-provider-mark]')).toHaveCount(9);
});

test('floating surfaces respond to viewport size without internal canvas clipping', async ({ page }) => {
  const viewports = [
    { width: 390, height: 844 },
    { width: 768, height: 900 },
    { width: 1024, height: 768 },
    { width: 1440, height: 960 },
    { width: 1920, height: 1080 },
  ];
  for (const viewport of viewports) {
    await page.setViewportSize(viewport);
    await page.goto('/');
    await expect(page.locator('[data-assembly-root]')).toHaveAttribute('data-assembly-phase', 'glimpse');
    for (const id of ['stabilize', 'browser', 'shell', 'note', 'verify']) {
      const box = await page.locator(`[data-assembly-surface="${id}"]`).boundingBox();
      expect(box, `${id} has geometry at ${viewport.width}px`).not.toBeNull();
      expect(box!.x + box!.width, `${id} reaches the viewport at ${viewport.width}px`).toBeGreaterThan(20);
      expect(box!.x, `${id} reaches the viewport at ${viewport.width}px`).toBeLessThan(viewport.width - 20);
      expect(box!.y + box!.height).toBeGreaterThan(0);
      expect(box!.y).toBeLessThan(viewport.height);
    }
    await expect(page.locator('[data-assembly-chrome="canvas-shell"]')).toHaveCSS('overflow', 'visible');
  }

  const root = page.locator('[data-assembly-root]');
  await page.mouse.move(1880, 1020);
  await expect.poll(() => root.evaluate((element) => element.style.getPropertyValue('--pointer-x'))).not.toBe('0');
  await expect.poll(() => root.evaluate((element) => element.style.getPropertyValue('--pointer-tilt-x'))).not.toBe('0deg');
});

test('Mac, Command Center, Companion, and shared approval state are interactive', async ({ page }) => {
  await revealDemo(page);
  await page.getByRole('button', { name: 'Tidy' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Auto layout arranged' })).toBeVisible();
  await page.getByRole('button', { name: 'Undo' }).click();
  await page.getByRole('button', { name: 'New zone' }).click();
  const canvas = page.locator('[data-interaction-id="canvas-surface"]');
  const canvasBox = await canvas.boundingBox();
  if (!canvasBox) throw new Error('Canvas has no geometry');
  await page.mouse.move(canvasBox.x + 36, canvasBox.y + canvasBox.height - 170);
  await page.mouse.down();
  await page.mouse.move(canvasBox.x + 230, canvasBox.y + canvasBox.height - 54, { steps: 4 });
  await page.mouse.up();
  await expect(page.getByRole('status').filter({ hasText: 'Zone created' })).toBeVisible();
  await page.getByRole('button', { name: /Add or jump/ }).click();
  await expect(page.getByRole('dialog', { name: 'Command Center' })).toBeVisible();
  await page.locator('[data-interaction-id="command-search"]').fill('New Agent');
  await page.keyboard.press('Enter');
  await expect(page.getByRole('dialog', { name: 'Choose a model' })).toBeVisible();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('dialog', { name: /Choose effort/ })).toBeVisible();
  await page.keyboard.press('Enter');
  await expect(page.getByText('New agent', { exact: true }).first()).toBeVisible();

  await page.getByRole('button', { name: 'Focus Companion' }).click();
  await page.locator('[data-interaction-id="companion-tab-approvals"]').click();
  await page.locator('[data-testid="approval-approve"]').click();
  await expect(page.getByText('Approval sent')).toBeVisible();
  await page.getByRole('button', { name: 'Focus Mac workspace' }).click();
  await expect(page.getByText('Running the approved iOS verification').first()).toBeVisible();
});

test('every visible control satisfies the central interaction contract or is a real link', async ({ page }) => {
  await revealDemo(page);
  const controls = page.locator('button, a, input, textarea, select, summary, [role="tab"], [role="menuitem"], [role="option"], [role="slider"]:visible');
  const count = await controls.count();
  const failures: string[] = [];
  for (let index = 0; index < count; index++) {
    const control = controls.nth(index);
    if (!(await control.isVisible())) continue;
    const id = await control.getAttribute('data-interaction-id');
    const tag = await control.evaluate((node) => node.tagName.toLowerCase());
    const href = tag === 'a' ? await control.getAttribute('href') : null;
    const disabled = await control.isDisabled().catch(() => false) || await control.getAttribute('aria-disabled') === 'true';
    if (id && isInteractionRegistered(id)) continue;
    if (tag === 'a' && href) continue;
    if (disabled) continue;
    failures.push(`${tag}:${id ?? await control.getAttribute('aria-label') ?? (await control.textContent())?.trim().slice(0, 40)}`);
  }
  expect(failures, `Uncontracted controls: ${failures.join(', ')}`).toEqual([]);
});

test('homepage and ready demo pass automated accessibility scans', async ({ page }) => {
  await page.goto('/');
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await revealDemo(page);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});

test('mobile enters Companion-first while retaining a linked Mac panorama', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await page.getByRole('button', { name: 'Use the workspace' }).click();
  await expect(page.locator('[data-demo-root]')).toHaveAttribute('data-device-focus', 'companion');
  await expect(page.locator('[data-testid="companion"]')).toBeVisible();
  await expect(page.locator('[data-mac-workspace]')).toBeVisible();
  await page.locator('[data-interaction-id="companion-tab-canvas"]').click();
  await expect(page.locator('[data-testid="companion-screen-canvas"]')).toBeVisible();
});

test('Reduced Motion resolves to the settled portal without a pinned track', async ({ browser }) => {
  const context = await browser.newContext({ reducedMotion: 'reduce', viewport: { width: 1440, height: 960 } });
  const page = await context.newPage();
  await page.goto('/');
  await expect(page.locator('[data-assembly-root]')).toHaveAttribute('data-assembly-phase', 'ready');
  await expect(page.locator('[data-presentation-layer]')).toHaveCount(0);
  await context.close();
});
