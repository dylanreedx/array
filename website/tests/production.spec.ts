import { expect, test, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
const tileIDs = ['stabilize', 'verify', 'audit', 'browser', 'shell', 'note'];
async function seek(page: Page, progress: number) {
  await page.locator('[data-assembly-root]').evaluate((el, value) => {
    const top = el.getBoundingClientRect().top + scrollY;
    scrollTo({ top: top + (el.getBoundingClientRect().height - innerHeight) * value, behavior: 'instant' });
  }, progress);
  await expect.poll(async () => Number(await page.locator('[data-guided-demo]').getAttribute('data-demo-progress')))
    .toBeCloseTo(progress, 2);
}
async function demoSnapshot(page: Page) {
  return page.locator('[data-guided-demo]').evaluate(root => {
    const world = root.querySelector<HTMLElement>('[data-guided-world]')!;
    const cursor = root.querySelector<HTMLElement>('[data-demo-cursor]')!;
    return {
      step: (root as HTMLElement).dataset.demoStep,
      camera: [world.dataset.cameraX, world.dataset.cameraY, world.dataset.cameraScale].map(Number),
      cursor: cursor.style.transform,
      press: root.querySelector<HTMLElement>('[data-demo-cursor-press]')?.style.cssText,
      statuses: Array.from(root.querySelectorAll('[data-demo-status]')).map(el => (el.querySelector('span[data-status]') ?? el).textContent),
      transcripts: Array.from(root.querySelectorAll('[data-demo-transcript]')).map(el => (el.querySelector('[aria-label="Agent transcript"]') ?? el).textContent),
      typing: Array.from(root.querySelectorAll('[data-demo-typing]')).map(el => (el.querySelector('textarea') ?? (el instanceof HTMLTextAreaElement ? el : null))?.value),
      tool: root.querySelector('[data-demo-tool=stabilize]')?.textContent,
      caption: root.querySelector('[data-demo-caption]')?.textContent,
      menus: Array.from(root.querySelectorAll<HTMLElement>('[data-demo-menu]')).map(el => [el.dataset.demoMenu, el.hidden, getComputedStyle(el).display]),
    };
  });
}
async function rememberTiles(page: Page) {
  await page.evaluate(ids => {
    const memory = window as Window & { __heroTiles?: Element[]; __heroRemoved?: boolean; __nativeAgents?: Element[] };
    memory.__heroTiles = ids.map(id => document.querySelector(`[data-assembly-surface="${id}"]`)!);
    memory.__nativeAgents = Array.from(document.querySelectorAll('[data-guided-world] [data-agent-id]'));
    memory.__heroRemoved = false;
    new MutationObserver(records => {
      for (const record of records) for (const removed of record.removedNodes) {
        if ([...memory.__heroTiles!, ...memory.__nativeAgents!].some(tile => removed === tile || removed.contains(tile))) memory.__heroRemoved = true;
      }
    }).observe(document.body, { childList: true, subtree: true });
  }, tileIDs);
}
async function assertTileContinuity(page: Page) {
  expect(await page.evaluate(ids => {
    const memory = window as Window & { __heroTiles?: Element[]; __heroRemoved?: boolean; __nativeAgents?: Element[] };
    return ids.map((id, index) => {
      const tile = document.querySelector(`[data-assembly-surface="${id}"]`);
      return !!tile && tile === memory.__heroTiles?.[index] && tile.isConnected
        && !memory.__heroRemoved && memory.__nativeAgents?.length === 3
        && memory.__nativeAgents.every(agent => agent.isConnected) && getComputedStyle(tile).display !== 'none';
    });
  }, tileIDs)).toEqual(tileIDs.map(() => true));
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
test('original hero copy and the same six floating tiles form the DOM story', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.hero-copy__body')).toHaveText('Launch agents and tools from anywhere. Array keeps everything they touch visible on one native workspace.');
  await expect(page.getByText('A native workspace for your coding agents', { exact: true })).toHaveCount(0);
  await expect(page.locator('[data-assembly-surface]')).toHaveCount(6);
  for (const id of tileIDs) await expect(page.locator(`[data-assembly-surface=${id}]`)).toHaveCount(1);
  await expect(page.locator('[data-guided-world]')).toHaveCount(1);
  await expect(page.locator('[data-guided-demo]')).toHaveAttribute('data-demo-installed', 'true');
  await expect(page.locator('video, [data-native-film]')).toHaveCount(0);
  const nav = await page.locator('.production-header__inner').evaluate(el => ({ border: getComputedStyle(el).borderWidth, width: el.clientWidth }));
  expect(nav.border).toBe('0px');
  const github = await page.locator('.production-header nav').boundingBox();
  expect(github!.x).toBeGreaterThan(nav.width / 2);
  await rememberTiles(page);
  for (const progress of [0, .12, .28, .45, .62, .76, .9, 1, .62, .28, 0]) {
    await seek(page, progress);
    await assertTileContinuity(page);
  }
});
test('direct scroll seek and reverse reproduce camera, cursor, statuses and transcript', async ({ page }) => {
  await page.goto('/');
  await seek(page, .64); // direct seek must not depend on earlier playback
  const direct = await demoSnapshot(page);
  await seek(page, .34);
  const early = await demoSnapshot(page);
  await seek(page, .64);
  expect(await demoSnapshot(page)).toEqual(direct);
  await seek(page, 1);
  await seek(page, .34);
  expect(await demoSnapshot(page)).toEqual(early);
  expect(direct.camera).not.toEqual(early.camera);
  expect(direct.cursor).not.toEqual(early.cursor);
  expect(direct.statuses).not.toEqual(early.statuses);
  expect(direct.transcripts).not.toEqual(early.transcripts);
  expect(direct.caption).not.toEqual(early.caption);
  expect(direct.statuses.length).toBe(3);
  expect(direct.transcripts.length).toBe(3);
  expect(direct.camera.every(value => value !== undefined && Number.isFinite(Number(value)))).toBe(true);
  await page.reload();
  await seek(page, .64);
  expect(await demoSnapshot(page)).toEqual(direct);
});
test('story visibly types, opens the provider choice, requests approval and completes work', async ({ page }) => {
  await page.goto('/');
  await seek(page, .34);
  const draft = page.locator('[data-assembly-surface=stabilize] textarea');
  await expect(draft).toHaveValue(/^Fix zone placement/);
  expect((await draft.inputValue()).length).toBeLessThan('Fix zone placement. Keep tiles aligned while zooming.'.length);
  await seek(page, .49);
  await expect(page.locator('[data-demo-menu=provider]')).toBeVisible();
  await expect(page.locator('[data-demo-menu=provider]')).toContainText('Claude Code');
  await seek(page, .64);
  await expect(page.locator('[data-demo-menu=provider]')).toBeHidden();
  await expect(page.locator('[data-demo-approval] [aria-label="Pending approval"]')).toBeVisible();
  await expect(page.locator('[data-demo-approval]')).toHaveAttribute('data-approval-state', 'waiting');
  const waiting = await demoSnapshot(page);
  expect(waiting.statuses[1]).toBe('Needs approval');
  expect(waiting.camera.every(Number.isFinite)).toBe(true);
  await seek(page, .681);
  const approved = page.locator('[data-interaction-id="approval-approve"]');
  await expect(approved).toHaveText('Approved');
  const buttonBounds = await approved.boundingBox();
  const cursorBounds = await page.locator('[data-demo-cursor]').boundingBox();
  expect(cursorBounds!.x).toBeGreaterThan(buttonBounds!.x);
  expect(cursorBounds!.x).toBeLessThan(buttonBounds!.x + buttonBounds!.width);
  expect(cursorBounds!.y).toBeGreaterThan(buttonBounds!.y);
  expect(cursorBounds!.y).toBeLessThan(buttonBounds!.y + buttonBounds!.height);
  await expect(page.locator('[data-demo-cursor-press]')).toHaveCSS('opacity', '1');
  await seek(page, .70);
  await expect(page.locator('[data-demo-approval]')).toHaveAttribute('data-approval-state', 'approved');
  await expect(page.locator('[data-demo-approval] [aria-label="Pending approval"]')).toBeHidden();
  await seek(page, .64);
  await expect(page.locator('[data-demo-approval] [aria-label="Pending approval"]')).toBeVisible();
  expect(await demoSnapshot(page)).toEqual(waiting);
  await seek(page, .825);
  const shellInput = page.locator('[data-interaction-id="shell-input"]');
  await expect(shellInput).toHaveValue(/^swi/);
  expect((await shellInput.inputValue()).length).toBeLessThan('swift test'.length);
  await seek(page, .83);
  await expect(shellInput).toHaveValue(/^swift/);
  await seek(page, .845);
  await expect(page.locator('[data-assembly-surface=shell]')).toContainText('Running CanvasSceneEditTests');
  await seek(page, .90);
  await expect(page.locator('[data-assembly-surface=shell]')).toContainText('18 checks passed');
  const finished = await demoSnapshot(page);
  expect(finished.statuses).toEqual(['Complete', 'Passed', 'Complete']);
  expect(finished.tool).toContain('Canvas checks passed');
  await seek(page, .34);
  await expect(draft).toHaveValue(/^Fix zone placement/);
  await expect(page.locator('[data-demo-menu=provider]')).toBeHidden();
});
test('the native workspace takes over the viewport with a full-height sidebar and canvas', async ({ page }) => {
  await page.goto('/');
  for (const progress of [.26, .64, .80]) {
    await seek(page, progress);
    const geometry = await page.locator('[data-guided-window]').evaluate(window => {
      const box = (el: Element) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
      return { viewport: { width: innerWidth, height: innerHeight }, window: box(window),
        sidebar: box(window.querySelector('[data-assembly-chrome="sidebar"]')!),
        canvas: box(window.querySelector('[data-assembly-chrome="canvas"]')!),
        topbar: box(window.querySelector('[data-assembly-chrome="topbar"]')!),
        rail: box(window.querySelector('[data-assembly-chrome="status"]')!),
        radius: getComputedStyle(window).borderTopLeftRadius };
    });
    expect(Math.abs(geometry.window.x)).toBeLessThanOrEqual(1);
    expect(Math.abs(geometry.window.y)).toBeLessThanOrEqual(1);
    expect(geometry.window.width).toBeCloseTo(geometry.viewport.width, 0);
    expect(geometry.window.height).toBeCloseTo(geometry.viewport.height, 0);
    expect(parseFloat(geometry.radius)).toBe(0);
    expect(geometry.topbar.height).toBeCloseTo(46, 0);
    expect(geometry.rail.height).toBeCloseTo(28, 0);
    expect(geometry.sidebar.width).toBeCloseTo(280, 0);
    expect(geometry.sidebar.y).toBeCloseTo(geometry.topbar.bottom, 0);
    expect(geometry.sidebar.bottom).toBeGreaterThanOrEqual(geometry.viewport.height - 1);
    expect(geometry.canvas.x).toBeCloseTo(geometry.sidebar.right, 0);
    expect(geometry.canvas.right).toBeGreaterThanOrEqual(geometry.viewport.width - 1);
    expect(geometry.canvas.bottom).toBeCloseTo(geometry.rail.y, 0);
  }
});
test('camera and tile motion continue within the narrated beats', async ({ page }) => {
  await page.goto('/');
  for (const points of [[.34, .36, .40], [.49, .53, .57], [.62, .64, .67], [.77, .80, .84]]) {
    const samples: number[][] = [];
    for (const progress of points) {
      await seek(page, progress);
      samples.push(await page.locator('[data-guided-world]').evaluate(world =>
        Array.from(world.querySelectorAll('[data-assembly-surface]')).flatMap(tile => {
          const r = tile.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2, r.width, r.height];
        })));
    }
    // Screen-space displacement witnesses actual rendered movement, including
    // camera arcs and tile tilts, rather than a changing progress attribute.
    const displacement = Math.max(...samples.slice(1).flatMap(sample => sample.map((value, i) => Math.abs(value - samples[0][i]))));
    expect(displacement, `rendered motion within ${points.join('→')}`).toBeGreaterThan(12);
  }
});
test('the working glyph advances while scroll is paused and stops when complete or reduced', async ({ page }) => {
  await page.goto('/');
  await seek(page, .40);
  const gyro = page.locator('[data-assembly-surface=stabilize] span:has(> [data-node])').last();
  await expect(gyro).toHaveAttribute('data-enhanced', 'true');
  const nodes = gyro.locator('[data-node]');
  await expect(nodes).toHaveCount(3);
  const pose = () => nodes.evaluateAll(elements => elements.map(el => getComputedStyle(el).transform));
  const activePose = await pose();
  const story = await demoSnapshot(page);
  const scroll = await page.evaluate(() => scrollY);
  await expect.poll(pose).not.toEqual(activePose);
  expect(await page.evaluate(() => scrollY)).toBe(scroll);
  expect(await demoSnapshot(page)).toEqual(story);
  await seek(page, .90);
  const completedPose = await pose();
  await page.waitForTimeout(250);
  expect(await pose()).toEqual(completedPose);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(gyro).toHaveAttribute('data-enhanced', 'true');
  const reducedPose = await pose();
  await page.waitForTimeout(250);
  expect(await pose()).toEqual(reducedPose);
});
test('the native board and editor show staged work and reproduce it on reverse seek', async ({ page }) => {
  await page.goto('/');
  const cards = page.locator('[data-demo-board-card]');
  const lines = page.locator('[data-demo-editor-line]');
  await expect(cards).toHaveCount(3);
  expect(await lines.count()).toBeGreaterThanOrEqual(12);
  const state = () => page.evaluate(() => ({
    cards: Array.from(document.querySelectorAll<HTMLElement>('[data-demo-board-card]')).map(el => [el.dataset.demoBoardCard, el.dataset.demoState]),
    lines: Array.from(document.querySelectorAll<HTMLElement>('[data-demo-editor-line]')).map(el => [el.dataset.demoEditorLine, el.dataset.demoActive, el.dataset.demoEdited, el.textContent]),
    detail: document.querySelector<HTMLElement>('[data-demo-board-detail]')?.hidden,
  }));
  await seek(page, .75);
  await expect(page.locator('[data-demo-board-card=placement]')).toHaveAttribute('data-demo-state', 'active');
  await expect(page.locator('[data-demo-board-detail]')).toBeHidden();
  const workingBoard = await state();
  await seek(page, .80);
  await expect(page.locator('[data-demo-editor-line="14"]')).toHaveAttribute('data-demo-active', 'true');
  for (const line of [14, 16, 17]) await expect(page.locator(`[data-demo-editor-line="${line}"]`)).toHaveAttribute('data-demo-edited', 'true');
  const editor = await state();
  await seek(page, .765);
  const detail = page.locator('[data-demo-board-detail]');
  await expect(detail).toBeVisible();
  await expect(detail).toContainText('Move tiles into the project zone');
  await expect(detail).toContainText('Keep three tile positions aligned');
  const detailState = await state();
  await seek(page, .95);
  for (const card of ['placement', 'approval', 'tests']) await expect(page.locator(`[data-demo-board-card=${card}]`)).toHaveAttribute('data-demo-state', 'done');
  await seek(page, .87);
  await expect(detail).toBeHidden();
  await seek(page, .765);
  expect(await state()).toEqual(detailState);
  await seek(page, .80);
  expect(await state()).toEqual(editor);
  await seek(page, .75);
  expect(await state()).toEqual(workingBoard);
});
test('page has no ready gate and keyboard scrolling reaches download', async ({ page }) => {
  await page.goto('/');
  await page.locator('[data-see-all]').click();
  await expect.poll(async () => Number(await page.locator('[data-guided-demo]').getAttribute('data-demo-progress'))).toBeCloseTo(.26, 2);
  await expect(page.getByTestId('interaction-ready-cue')).toHaveCount(0);
  await page.keyboard.press('End');
  await expect(page.getByRole('heading', { name: 'More work. Less hidden state.' })).toBeVisible();
});
for (const width of [390, 320]) {
  test(`mobile ${width}px keeps the focused work readable without page overflow`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await page.goto('/');
    await expect(page.locator('.hero-copy h1')).toBeVisible();
    await expect(page.locator('.hero-copy__body')).toBeVisible();
    await rememberTiles(page);
    for (const progress of [0, .45, .76, 1, .45]) {
      await seek(page, progress);
      await assertTileContinuity(page);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      await expect(page.locator('[data-demo-caption]')).toBeVisible();
    }
    await seek(page, .64);
    const geometry = await page.locator('[data-assembly-surface=verify]').evaluate(tile => {
      const rect = tile.getBoundingClientRect();
      const scale = Number(document.querySelector<HTMLElement>('[data-guided-world]')!.dataset.cameraScale);
      const status = tile.querySelector<HTMLElement>('[data-demo-status=verify] span[data-status]')
        ?? tile.querySelector<HTMLElement>('[data-demo-status=verify]')!;
      return { left: rect.left, right: rect.right, width: rect.width,
        effectiveFont: parseFloat(getComputedStyle(status).fontSize) * scale };
    });
    expect(geometry.left).toBeGreaterThanOrEqual(-8);
    expect(geometry.right).toBeLessThanOrEqual(width + 8);
    expect(geometry.width).toBeGreaterThan(250);
    expect(geometry.effectiveFont).toBeGreaterThanOrEqual(12);
    await expect(page.locator('[data-demo-approval] [aria-label="Pending approval"]')).toBeVisible();
    for (const [progress, selector] of [[.75, '[data-demo-board-card=placement] p'], [.80, '[data-demo-editor-line="14"]'], [.765, '[data-demo-board-detail] li']] as const) {
      await seek(page, progress);
      const focus = await page.locator(selector).first().evaluate(el => {
        const r = el.getBoundingClientRect();
        const scale = Number(el.closest<HTMLElement>('[data-guided-world]')?.dataset.cameraScale ?? 1);
        return { visibleWidth: Math.max(0, Math.min(innerWidth, r.right) - Math.max(0, r.left)),
          visibleHeight: Math.max(0, Math.min(innerHeight, r.bottom) - Math.max(0, r.top)),
          effectiveFont: parseFloat(getComputedStyle(el).fontSize) * scale };
      });
      expect(focus.visibleWidth, `focused ${selector}`).toBeGreaterThan(200);
      expect(focus.visibleHeight, `focused ${selector}`).toBeGreaterThan(16);
      expect(focus.effectiveFont, `readable ${selector}`).toBeGreaterThanOrEqual(12);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
    }
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  });
}
test('desktop story and reduced motion expose accessible ordinary copy and captions', async ({ page }) => {
  await page.goto('/');
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await seek(page, .76);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await seek(page, 0);
  await page.locator('[data-theme-toggle]').click();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  await expect(page.locator('.hero-copy h1')).toBeVisible();
  await expect(page.locator('.hero-copy__body')).toBeVisible();
  await expect(page.locator('video')).toHaveCount(0);
  await expect(page.locator('[data-demo-cursor]')).toBeHidden();
  await page.locator('[data-demo-caption]').scrollIntoViewIfNeeded();
  await expect(page.locator('[data-demo-caption]')).toBeVisible();
  const world = page.locator('[data-guided-world]');
  expect(await world.evaluate(el => getComputedStyle(el).transform)).toBe('none');
  await page.locator('[data-assembly-surface=stabilize]').scrollIntoViewIfNeeded();
  await expect(page.locator('[data-demo-transcript=stabilize]')).toContainText('Canvas checks passed');
  await expect(page.locator('[data-demo-transcript=stabilize]')).toBeVisible();
  await page.locator('[data-assembly-surface=note]').scrollIntoViewIfNeeded();
  await expect(page.locator('[data-demo-board-card=placement]')).toBeVisible();
  await page.locator('[data-assembly-surface=browser]').scrollIntoViewIfNeeded();
  await expect(page.locator('[data-demo-editor-line="14"]')).toBeVisible();
  await page.keyboard.press('End');
  await expect(page.getByRole('heading', { name: 'More work. Less hidden state.' })).toBeVisible();
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

test('without JavaScript the product explanation and download remain readable', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto('/');
  await expect(page.locator('.hero-copy h1')).toBeVisible();
  await expect(page.locator('.demo-without-script')).toContainText('Group work in zones');
  expect(await page.locator('[data-assembly-root]').evaluate(el => el.getBoundingClientRect().height)).toBeLessThan(844);
  await expect(page.locator('[data-testid=download-main]').first()).toHaveAttribute('href', /Array\.dmg$/);
  await context.close();
});
