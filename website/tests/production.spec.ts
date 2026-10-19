import { expect, test, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { scrollForProgress } from '../src/lib/guided-timeline';
const tileIDs = ['stabilize', 'verify', 'audit', 'browser', 'shell', 'note'];
/** Seek by authored progress; an inserted beat's own point lands on its first frame. */
async function seek(page: Page, progress: number, insertT?: number) {
  await page.locator('[data-assembly-root]').evaluate((el, value) => {
    const top = el.getBoundingClientRect().top + scrollY;
    scrollTo({ top: top + (el.getBoundingClientRect().height - innerHeight) * value, behavior: 'instant' });
  }, scrollForProgress(progress, insertT));
  await expect.poll(async () => Number(await page.locator('[data-guided-demo]').getAttribute('data-demo-progress')))
    .toBeCloseTo(progress, 2);
}
async function clippedGeometry(page: Page, selector: string) {
  return page.locator(selector).first().evaluate(el => {
    const r = el.getBoundingClientRect();
    let left = Math.max(0, r.left), right = Math.min(innerWidth, r.right);
    let top = Math.max(0, r.top), bottom = Math.min(innerHeight, r.bottom);
    for (let ancestor = el.parentElement; ancestor; ancestor = ancestor.parentElement) {
      const style = getComputedStyle(ancestor), clip = ancestor.getBoundingClientRect();
      if (/hidden|clip|scroll|auto/.test(style.overflowX)) { left = Math.max(left, clip.left); right = Math.min(right, clip.right); }
      if (/hidden|clip|scroll|auto/.test(style.overflowY)) { top = Math.max(top, clip.top); bottom = Math.min(bottom, clip.bottom); }
    }
    const scale = Number(el.closest<HTMLElement>('[data-guided-world]')?.dataset.cameraScale ?? 1);
    return { visibleWidth: Math.max(0, right - left), visibleHeight: Math.max(0, bottom - top),
      effectiveFont: parseFloat(getComputedStyle(el).fontSize) * scale };
  });
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
        && memory.__nativeAgents.every(agent => agent.isConnected);
    });
  }, tileIDs)).toEqual(tileIDs.map(() => true));
}
test('homepage links, downloads and theme work', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Keep every agent in view.', level: 1 })).toBeVisible();
  // The header's only section links: the docs and the source.
  await expect(page.locator('.production-header nav a')).toHaveText(['Docs', 'GitHub']);
  await expect(page.locator('.production-header nav a').nth(0)).toHaveAttribute('href', '/docs/');
  await expect(page.locator('.production-header nav a').nth(1)).toHaveAttribute('href', 'https://github.com/dylanreedx/array');
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
  await seek(page, .40);
  const early = await demoSnapshot(page);
  await seek(page, .64);
  expect(await demoSnapshot(page)).toEqual(direct);
  await seek(page, 1);
  await seek(page, .40);
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
  await seek(page, .40);
  const draft = page.locator('[data-assembly-surface=stabilize] textarea');
  await expect(draft).toHaveValue(/^Fix zone placement/);
  expect((await draft.inputValue()).length).toBeLessThan('Fix zone placement. Keep tiles aligned while zooming.'.length);
  await seek(page, .49);
  await expect(page.locator('[data-assembly-surface=verify] [data-demo-menu=provider]')).toBeVisible();
  await expect(page.locator('[data-assembly-surface=verify] [data-demo-menu=provider]')).toContainText('Claude Code');
  await seek(page, .64);
  for (const id of ['stabilize', 'verify', 'audit']) await expect(page.locator(`[data-assembly-surface=${id}] [data-demo-menu=provider]`)).toBeHidden();
  await expect(page.locator('[data-demo-approval] [aria-label="Pending approval"]')).toBeVisible();
  await expect(page.locator('[data-demo-approval]')).toHaveAttribute('data-approval-state', 'waiting');
  const waiting = await demoSnapshot(page);
  expect(waiting.statuses[1]).toBe('Needs attention');
  expect(waiting.camera.every(Number.isFinite)).toBe(true);
  await seek(page, .681);
  const approved = page.locator('[data-interaction-id="approval-approve"]');
  await expect(approved).toHaveText('Sending…');
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
  // The command is typed inline at the prompt, as in a real terminal; there is no input bar.
  const shellInput = page.locator('[data-interaction-id="shell-input"]');
  await expect(page.locator('[data-assembly-surface=shell] input')).toHaveCount(0);
  await expect(shellInput).toHaveText(/^swi/);
  expect((await shellInput.textContent())!.length).toBeLessThan('swift test'.length);
  await seek(page, .83);
  await expect(shellInput).toHaveText(/^swift/);
  await seek(page, .845);
  await expect(page.locator('[data-assembly-surface=shell]')).toContainText('CanvasSceneEditTests');
  await expect(page.locator('[data-assembly-surface=shell]')).not.toContainText('Executed 18 tests', { useInnerText: true });
  await seek(page, .90);
  await expect(page.locator('[data-assembly-surface=shell]')).toContainText('Executed 18 tests, with 0 failures', { useInnerText: true });
  const finished = await demoSnapshot(page);
  expect(finished.statuses).toEqual(['Done', 'Done', 'Done']);
  expect(finished.tool).toContain('Canvas checks passed');
  await seek(page, .40);
  await expect(draft).toHaveValue(/^Fix zone placement/);
  for (const id of ['stabilize', 'verify', 'audit']) await expect(page.locator(`[data-assembly-surface=${id}] [data-demo-menu=provider]`)).toBeHidden();
});
test('golden flow creates a native agent before focus, typing and send', async ({ page }) => {
  await page.goto('/');
  await rememberTiles(page);
  const root = page.locator('[data-guided-demo]');
  const main = page.locator('[data-assembly-surface=stabilize]');
  const draft = main.locator('textarea');
  await seek(page, .26);
  await expect(root).toHaveAttribute('data-demo-creation-stage', 'absent');
  await expect(main).toHaveAttribute('data-demo-created', 'false');
  await expect(main).toHaveAttribute('data-demo-visible', 'false');
  await expect(draft).toHaveValue('');
  await seek(page, .29);
  await expect(root).toHaveAttribute('data-demo-creation-stage', 'command');
  await expect(page.locator('[data-demo-command-agent]')).toBeVisible();
  await seek(page, .32);
  await expect(root).toHaveAttribute('data-demo-creation-stage', 'models');
  await expect(page.locator('[data-demo-command-models]')).toBeVisible();
  await expect(page.locator('[data-demo-command-model][data-selected=true]')).toContainText('Default');
  await expect(page.locator('[data-demo-command-model] [data-provider-mark=openai]')).toHaveCount(1);
  await expect(main).toHaveAttribute('data-demo-created', 'false');
  await expect(draft).toHaveValue('');
  await seek(page, .35);
  await expect(root).toHaveAttribute('data-demo-creation-stage', 'spawning');
  await expect(main).toHaveAttribute('data-demo-created', 'true');
  await expect(main).toHaveAttribute('data-demo-visible', 'true');
  await expect(draft).toHaveValue('');
  await seek(page, .38);
  await expect(root).toHaveAttribute('data-demo-focused-tile', 'stabilize');
  await expect(root).toHaveAttribute('data-demo-selected-tile', 'stabilize');
  await expect(draft).toHaveValue('');
  await seek(page, .40);
  await expect(root).toHaveAttribute('data-demo-creation-stage', 'focused');
  await expect(draft).toHaveValue(/^Fix zone placement/);
  const focused = await demoSnapshot(page);
  await seek(page, .44);
  await expect(root).toHaveAttribute('data-demo-creation-stage', 'sent');
  await expect(draft).toHaveValue('');
  await expect(main.locator('[data-kind=user]')).toContainText('Fix zone placement');
  for (const [progress, id] of [[.53, 'verify'], [.575, 'audit']] as const) {
    await seek(page, progress);
    await expect(root).toHaveAttribute('data-demo-focused-tile', id);
    await expect(root).toHaveAttribute('data-demo-selected-tile', id);
    expect(await page.locator(`[data-assembly-surface=${id}] textarea`).inputValue()).not.toBe('');
  }
  await seek(page, .40);
  expect(await demoSnapshot(page)).toEqual(focused);
  await seek(page, .26);
  await expect(main).toHaveAttribute('data-demo-created', 'false');
  await expect(main).toHaveAttribute('data-demo-visible', 'false');
  await expect(draft).toHaveValue('');
  await assertTileContinuity(page);
});
test('golden flow provider marks, menu anchor and square context rings match the native tile', async ({ page }) => {
  await page.goto('/');
  for (const [id, mark] of [['stabilize', 'openai'], ['verify', 'anthropic'], ['audit', 'openai']] as const) {
    await expect(page.locator(`[data-assembly-surface=${id}] > header [data-provider-mark=${mark}]`)).toHaveCount(1);
  }
  await seek(page, .49);
  const anchor = await page.locator('[data-assembly-surface=verify]').evaluate(tile => {
    const menu = tile.querySelector('[data-demo-menu=provider]')!.getBoundingClientRect();
    const footer = tile.querySelector('[aria-label="Next turn settings"]')!.getBoundingClientRect();
    const trigger = tile.querySelector('[data-interaction-id="agent-provider-verify"]')!.getBoundingClientRect();
    return { gap: footer.top - menu.bottom, aligned: menu.left - trigger.left, menuWidth: menu.width };
  });
  expect(anchor.gap).toBeGreaterThanOrEqual(-3);
  expect(anchor.gap).toBeLessThanOrEqual(20);
  expect(Math.abs(anchor.aligned)).toBeLessThan(24);
  expect(anchor.menuWidth).toBeGreaterThan(150);
  for (const [progress, id] of [[.40, 'stabilize'], [.53, 'verify'], [.575, 'audit'], [.945, 'stabilize']] as const) {
    await seek(page, progress);
    const ring = page.locator(`[data-assembly-surface=${id}] [data-demo-context-ring]`);
    await expect(ring).toHaveCount(1);
    const percent = { stabilize: 12, verify: 18, audit: 8 }[id];
    await expect(ring).toHaveAttribute('data-context-percent', String(percent));
    await expect(ring).toHaveAttribute('aria-label', `Illustrative context usage ${percent} percent`);
    const fill = await ring.locator('circle').last().evaluate(el => {
      const style = getComputedStyle(el); return 1 - parseFloat(style.strokeDashoffset) / parseFloat(style.strokeDasharray);
    });
    expect(fill).toBeCloseTo(percent / 100, 3);
    const geometry = await ring.evaluate(el => {
      const r = el.getBoundingClientRect(), style = getComputedStyle(el);
      return { width: r.width, height: r.height, localWidth: parseFloat(style.width), localHeight: parseFloat(style.height), flexShrink: style.flexShrink };
    });
    expect(geometry.width).toBeGreaterThan(10);
    expect(Math.abs(geometry.width - geometry.height)).toBeLessThan(1);
    expect(geometry.localWidth).toBe(geometry.localHeight);
    expect(geometry.flexShrink).toBe('0');
  }
});
test('golden flow focus outline follows selection with native marching ants', async ({ page }) => {
  await page.goto('/');
  const outline = page.locator('[data-demo-focus-outline]');
  const path = page.locator('[data-demo-focus-path]');
  for (const [progress, id] of [[.40, 'stabilize'], [.53, 'verify'], [.575, 'audit']] as const) {
    await seek(page, progress);
    await expect(outline).toBeVisible();
    const geometry = await outline.evaluate((el, id) => {
      const selected = document.querySelector(`[data-assembly-surface="${id}"]`)!.getBoundingClientRect();
      const r = el.getBoundingClientRect();
      const style = getComputedStyle(el.querySelector('[data-demo-focus-path]')!);
      return { outsideWorld: !el.closest('[data-guided-world]'), leftGap: selected.left - r.left, topGap: selected.top - r.top,
        widthExtra: r.width - selected.width, heightExtra: r.height - selected.height,
        stroke: parseFloat(style.strokeWidth), dash: style.strokeDasharray.match(/[\d.]+/g)?.map(Number) };
    }, id);
    expect(geometry.outsideWorld).toBe(true);
    expect(geometry.leftGap).toBeCloseTo(8, 0);
    expect(geometry.topGap).toBeCloseTo(8, 0);
    expect(geometry.widthExtra).toBeCloseTo(16, 0);
    expect(geometry.heightExtra).toBeCloseTo(16, 0);
    expect(geometry.stroke).toBe(1.5);
    expect(geometry.dash).toEqual([6, 4]);
  }
  expect(await path.evaluate(el => el.getAnimations().map(animation => Number(animation.effect?.getTiming().duration)))).toContain(2500);
  const offset = await path.evaluate(el => getComputedStyle(el).strokeDashoffset);
  await expect.poll(() => path.evaluate(el => getComputedStyle(el).strokeDashoffset)).not.toBe(offset);
});
test('golden flow drag, neighbor reflow and resize are deterministic on reverse seek', async ({ page }) => {
  await page.goto('/');
  await rememberTiles(page);
  const frames = () => page.locator('[data-guided-world]').evaluate(world =>
    Array.from(world.querySelectorAll<HTMLElement>('[data-assembly-surface]')).map(el => ({
      id: el.dataset.assemblySurface, x: el.offsetLeft, y: el.offsetTop, width: el.offsetWidth, height: el.offsetHeight,
      dragging: el.dataset.demoDragging, resizing: el.dataset.demoResizing,
    })));
  await seek(page, .86);
  const before = await frames();
  await seek(page, .895);
  await expect(page.locator('[data-assembly-surface=stabilize]')).toHaveAttribute('data-demo-dragging', 'true');
  const dragging = await frames();
  const originalFrame = before.find(f => f.id === 'stabilize')!, draggedFrame = dragging.find(f => f.id === 'stabilize')!;
  expect(Math.abs(draggedFrame.x - originalFrame.x) + Math.abs(draggedFrame.y - originalFrame.y)).toBeGreaterThan(30);
  await seek(page, .915);
  await expect(page.locator('[data-assembly-surface=browser]')).toHaveAttribute('data-demo-dragging', 'true');
  const reflow = await frames();
  const originalEditor = before.find(f => f.id === 'browser')!, draggedEditor = reflow.find(f => f.id === 'browser')!;
  expect(Math.abs(draggedEditor.x - originalEditor.x) + Math.abs(draggedEditor.y - originalEditor.y)).toBeGreaterThan(15);
  expect(reflow.filter(f => ['verify', 'audit'].includes(f.id!))).not.toEqual(before.filter(f => ['verify', 'audit'].includes(f.id!)));
  await seek(page, .945);
  await expect(page.locator('[data-assembly-surface=browser]')).toHaveAttribute('data-demo-resizing', 'true');
  const resizing = await frames();
  await seek(page, .97);
  const finished = await frames();
  const startSize = before.find(f => f.id === 'browser')!, endSize = finished.find(f => f.id === 'browser')!;
  expect(Math.abs(endSize.width - startSize.width) + Math.abs(endSize.height - startSize.height)).toBeGreaterThan(40);
  await seek(page, .945);
  expect(await frames()).toEqual(resizing);
  await seek(page, .895);
  expect(await frames()).toEqual(dragging);
  await seek(page, .86);
  expect(await frames()).toEqual(before);
  await assertTileContinuity(page);
});
for (const width of [1440, 390]) {
  test(`drag preview is a vacant native placement and releases into that placement at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 960 });
    await page.goto('/');
    const ghost = page.locator('[data-demo-snap-preview]');
    const prediction = () => ghost.evaluate(el => {
      const world = document.querySelector<HTMLElement>('[data-guided-world]')!, scale = Number(world.dataset.cameraScale);
      const style = (el as HTMLElement).style, origin = (el as HTMLElement).offsetParent!.getBoundingClientRect(), worldRect = world.getBoundingClientRect();
      // Camera data records its center; recover world coordinates from the
      // actual containing block without the native preview's spring scale.
      return { x: (parseFloat(style.left) + origin.left - worldRect.left) / scale,
        y: (parseFloat(style.top) + origin.top - worldRect.top) / scale,
        width: parseFloat(style.width) / scale, height: parseFloat(style.height) / scale };
    });
    for (const [samples, beforeRelease, release, id] of [
      [[.875, .8775, .884, .895], .9019, .902, 'stabilize'],
      [[.911, .916, .921], .9228, .923, 'browser'],
    ] as const) {
      for (const progress of samples) {
        await seek(page, progress);
        await expect(page.locator('[data-demo-focus-outline]')).toBeHidden();
        await expect(ghost).toBeVisible();
        const preview = await prediction();
        if (id === 'stabilize') expect.soft(preview.y, `native row top at ${progress}`).toBeCloseTo(90, 0);
        const passive = await page.locator('[data-guided-world] [data-assembly-surface]').evaluateAll((tiles, moving) => tiles
          .filter(el => (el as HTMLElement).dataset.assemblySurface !== moving && (el as HTMLElement).dataset.demoVisible !== 'false')
          .map(el => { const tile = el as HTMLElement; return { id: tile.dataset.assemblySurface,
            x: parseFloat(tile.style.left), y: parseFloat(tile.style.top), width: parseFloat(tile.style.width), height: parseFloat(tile.style.height) }; }), id);
        for (const tile of passive) {
          if (id === 'stabilize' && ['verify', 'audit', 'shell'].includes(tile.id!))
            expect.soft(tile.y, `passive row ${tile.id} at ${progress}`).toBeCloseTo(90, 0);
          const overlapX = Math.min(preview.x + preview.width, tile.x + tile.width) - Math.max(preview.x, tile.x);
          const overlapY = Math.min(preview.y + preview.height, tile.y + tile.height) - Math.max(preview.y, tile.y);
          expect.soft(overlapX <= .5 || overlapY <= .5, `preview overlaps passive ${tile.id} at ${progress}: ${overlapX} × ${overlapY}`).toBe(true);
        }
      }
      await seek(page, beforeRelease);
      await expect(ghost).toBeVisible();
      const finalPreview = await prediction();
      await seek(page, release + .0005);
      await expect(ghost).toBeHidden();
      const committed = await page.locator(`[data-assembly-surface=${id}]`).evaluate(el => {
        const s = (el as HTMLElement).style; return { x: parseFloat(s.left), y: parseFloat(s.top), width: parseFloat(s.width), height: parseFloat(s.height) };
      });
      for (const key of ['x', 'y', 'width', 'height'] as const) expect.soft(finalPreview[key], `release ${id}.${key}`).toBeCloseTo(committed[key], 0);
      if (id === 'stabilize') {
        const row = await page.locator('[data-guided-world]').evaluate(world => ['stabilize', 'verify', 'audit', 'shell'].map(id => {
          const el = world.querySelector<HTMLElement>(`[data-assembly-surface=${id}]`)!;
          return { id, x: parseFloat(el.style.left), y: parseFloat(el.style.top), width: parseFloat(el.style.width) };
        }).sort((a, b) => a.x - b.x));
        for (const tile of row) expect.soft(tile.y, `released row ${tile.id}`).toBeCloseTo(90, 0);
        for (let i = 1; i < row.length; i++) expect.soft(row[i].x - row[i - 1].x - row[i - 1].width, `native contact ${row[i - 1].id}→${row[i].id}`).toBeCloseTo(8, 0);
      }
      await seek(page, samples[0]);
      await expect(ghost).toBeVisible();
    }
  });
}
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
    expect(parseFloat(geometry.radius)).toBeLessThan(.01);
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
test('workspace frame grows from the inset preview and shrinks again on reverse seek', async ({ page }) => {
  await page.goto('/');
  const frame = () => page.locator('[data-guided-window]').evaluate(el => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height, radius: parseFloat(getComputedStyle(el).borderTopLeftRadius), viewportWidth: innerWidth, viewportHeight: innerHeight };
  });
  await seek(page, .18);
  const preview = await frame();
  expect(preview.x).toBeGreaterThan(0);
  expect(preview.y).toBeGreaterThan(0);
  expect(preview.width).toBeLessThan(preview.viewportWidth);
  expect(preview.height).toBeLessThan(preview.viewportHeight);
  expect(preview.radius).toBeGreaterThan(0);
  await seek(page, .22);
  const growing = await frame();
  expect(growing.width).toBeGreaterThan(preview.width);
  expect(growing.height).toBeGreaterThan(preview.height);
  await seek(page, .26);
  const full = await frame();
  expect(full.width).toBeGreaterThan(growing.width);
  expect(full.height).toBeGreaterThan(growing.height);
  expect(full.x).toBeCloseTo(0, 0);
  expect(full.y).toBeCloseTo(0, 0);
  await seek(page, 1);
  const final = await frame();
  expect(final.width).toBeLessThan(full.width);
  expect(final.height).toBeLessThan(full.height);
  expect(final.radius).toBeGreaterThan(0);
  await seek(page, .22);
  expect(await frame()).toEqual(growing);
  await seek(page, .18);
  expect(await frame()).toEqual(preview);
});
for (const width of [1440, 390]) {
  test(`native drag presses and three resize corners follow live geometry at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: width === 1440 ? 960 : 844 });
    await page.goto('/');
    const cursor = page.locator('[data-demo-cursor]');
    const assertCursorInside = async (selector: string) => {
      const target = await page.locator(selector).boundingBox();
      // The authored cursor tip is the translate origin, rather than the center
      // of its decorative arrow and press halo bounding box.
      const tip = await cursor.evaluate(el => {
        const r = el.getBoundingClientRect(); return { x: r.x, y: r.y };
      });
      expect(tip.x).toBeGreaterThanOrEqual(target!.x - 1);
      expect(tip.x).toBeLessThanOrEqual(target!.x + target!.width + 1);
      expect(tip.y).toBeGreaterThanOrEqual(target!.y - 1);
      expect(tip.y).toBeLessThanOrEqual(target!.y + target!.height + 1);
    };
    for (const [approach, pressed, id] of [[.868, .89, 'stabilize'], [.906, .916, 'browser']] as const) {
      await seek(page, approach);
      await expect(cursor).toHaveAttribute('data-pressed', 'false');
      await expect(page.locator('[data-demo-focus-outline]')).toBeHidden();
      await seek(page, pressed);
      await expect(cursor).toHaveAttribute('data-pressed', 'true');
      await expect(page.locator(`[data-assembly-surface=${id}]`)).toHaveAttribute('data-demo-dragging', 'true');
      await assertCursorInside(`[data-demo-drag-handle=${id}]`);
    }
    // The held tile is pointer-owned: the cursor keeps one grab offset on its
    // title bar for the whole move rather than sliding along it.
    for (const [samples, id] of [[[.875, .88, .885, .89, .895, .9], 'stabilize'], [[.911, .915, .919, .922], 'browser']] as const) {
      const offsets: Array<{ x: number; y: number }> = [];
      for (const progress of samples) {
        await seek(page, progress);
        // Read both rects in one task so they always come from the same written frame.
        offsets.push(await cursor.evaluate((el, tile) => {
          const tip = el.getBoundingClientRect(), handle = document.querySelector(`[data-demo-drag-handle=${tile}]`)!.getBoundingClientRect();
          return { x: tip.x - handle.x, y: tip.y - handle.y };
        }, id));
      }
      for (const offset of offsets) expect(Math.hypot(offset.x - offsets[0].x, offset.y - offsets[0].y), `${id} grab offset`).toBeLessThan(.5);
    }
    const readout = page.locator('[data-demo-resize-readout]');
    const states: Array<{ progress: number; frame: number[]; readout: string | null }> = [];
    for (const [progress, id] of [[.94, 'browser'], [.965, 'stabilize'], [.981, 'shell']] as const) {
      await seek(page, progress);
      const tile = page.locator(`[data-assembly-surface=${id}]`);
      await expect(tile).toHaveAttribute('data-demo-resizing', 'true');
      await expect(cursor).toHaveAttribute('data-pressed', 'true');
      await expect(cursor).toHaveAttribute('data-gesture', 'resize');
      await expect(cursor.locator('[data-demo-cursor-resize]')).toBeVisible();
      await expect(cursor.locator(':scope > svg').first()).toBeHidden();
      await assertCursorInside(`[data-demo-resize-handle=${id}]`);
      await expect(readout).toBeVisible();
      await expect(readout).toHaveAttribute('data-demo-resize-tile', id);
      const frame = await tile.evaluate(el => [parseFloat((el as HTMLElement).style.width), parseFloat((el as HTMLElement).style.height)]);
      await expect(readout).toHaveText(`${Math.round(frame[0])} × ${Math.round(frame[1] - 24)}`);
      states.push({ progress, frame, readout: await readout.textContent() });
    }
    for (const state of states.reverse()) {
      await seek(page, state.progress);
      await expect(readout).toHaveText(state.readout!);
    }
    for (const progress of [.902, .95, .966, .985]) {
      await seek(page, progress);
      const gaps = await page.locator('[data-guided-world]').evaluate(world => {
        const tile = (id: string) => world.querySelector<HTMLElement>(`[data-assembly-surface=${id}]`)!;
        const main = tile('stabilize'), audit = tile('audit'), shell = tile('shell');
        return [audit.offsetLeft - (main.offsetLeft + main.offsetWidth), shell.offsetLeft - (audit.offsetLeft + audit.offsetWidth)];
      });
      for (const gap of gaps) expect(gap, `native 8px tile spacing at ${progress}`).toBeGreaterThanOrEqual(7);
    }
    await seek(page, .99);
    await expect(readout).toBeHidden();
  });
}
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
  await seek(page, .455);
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
    lines: Array.from(document.querySelectorAll<HTMLElement>('[data-demo-editor-line]')).map(el => [el.dataset.demoEditorLine, el.dataset.demoActive, el.dataset.demoSelectedCode, el.textContent]),
    detail: document.querySelector<HTMLElement>('[data-demo-board-detail]')?.hidden,
  }));
  await seek(page, .75);
  await expect(page.locator('[data-demo-board-card=placement]')).toHaveAttribute('data-demo-state', 'active');
  await expect(page.locator('[data-demo-board-detail]')).toBeHidden();
  const workingBoard = await state();
  await seek(page, .80);
  await expect(page.locator('[data-demo-editor-line="14"]')).toHaveAttribute('data-demo-active', 'true');
  for (const line of [14, 15, 16, 17]) await expect(page.locator(`[data-demo-editor-line="${line}"]`)).toHaveAttribute('data-demo-selected-code', 'true');
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
    await seek(page, .26);
    await expect(page.locator('[data-assembly-surface=stabilize]')).toHaveAttribute('data-demo-created', 'false');
    await seek(page, .40);
    await expect(page.locator('[data-guided-demo]')).toHaveAttribute('data-demo-focused-tile', 'stabilize');
    await expect(page.locator('[data-assembly-surface=stabilize] textarea')).toHaveValue(/^Fix zone placement/);
    const composer = await clippedGeometry(page, '[data-assembly-surface=stabilize] textarea');
    expect(composer.visibleWidth).toBeGreaterThan(200);
    expect(composer.visibleHeight).toBeGreaterThan(20);
    expect(composer.effectiveFont).toBeGreaterThanOrEqual(12);
    await seek(page, .49);
    const providerSelector = '[data-assembly-surface=verify] [data-demo-menu=provider]';
    await expect(page.locator(providerSelector)).toBeVisible();
    await expect(page.locator(`${providerSelector} [data-demo-provider-option]`)).toHaveCount(2);
    for (const provider of ['Codex', 'Claude Code']) {
      const selector = `${providerSelector} [data-demo-provider-option="${provider}"]`;
      const option = page.locator(selector);
      await expect(option).toBeVisible();
      const native = await option.evaluate(el => ({ height: (el as HTMLElement).offsetHeight, font: parseFloat(getComputedStyle(el).fontSize) }));
      expect(native.height).toBeGreaterThanOrEqual(30);
      expect(native.font).toBeGreaterThanOrEqual(11);
      const visible = await clippedGeometry(page, selector);
      const bounds = await option.boundingBox();
      expect(visible.visibleWidth).toBeGreaterThanOrEqual(bounds!.width - 1);
      expect(visible.visibleHeight).toBeGreaterThanOrEqual(bounds!.height - 1);
    }
    const ring = await page.locator('[data-assembly-surface=verify] [data-demo-context-ring]').boundingBox();
    expect(Math.abs(ring!.width - ring!.height)).toBeLessThan(1);
    await seek(page, .26);
    await expect(page.locator('[data-assembly-surface=stabilize]')).toHaveAttribute('data-demo-created', 'false');
    await expect(page.locator('[data-assembly-surface=stabilize] textarea')).toHaveValue('');
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
      const focus = await clippedGeometry(page, selector);
      if (selector === '[data-demo-board-card=placement] p') {
        const bounds = await page.locator(selector).boundingBox();
        expect(focus.visibleWidth, `unclipped ${selector}`).toBeGreaterThanOrEqual(bounds!.width - 1);
        expect(focus.visibleHeight, `unclipped ${selector}`).toBeGreaterThanOrEqual(bounds!.height - 1);
      } else expect(focus.visibleWidth, `focused ${selector}`).toBeGreaterThan(200);
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
test('the canvas toolbar tours, drags to the left edge, and opens the terminal', async ({ page }) => {
  await page.goto('/');
  const toolbar = page.locator('[data-demo-toolbar]');
  const bar = toolbar.locator('[data-demo-toolbar-bar]');
  let canvas = await page.locator('[data-demo-canvas]').boundingBox();
  const cursorTip = () => page.locator('[data-demo-cursor]').evaluate(el => { const r = el.getBoundingClientRect(); return { x: r.left + 3, y: r.top + 2 }; });
  const inside = (box: { x: number; y: number; width: number; height: number } | null) => {
    expect(box).not.toBeNull();
    expect(box!.x).toBeGreaterThanOrEqual(canvas!.x - .5);
    expect(box!.y).toBeGreaterThanOrEqual(canvas!.y - .5);
    expect(box!.x + box!.width).toBeLessThanOrEqual(canvas!.x + canvas!.width + .5);
    expect(box!.y + box!.height).toBeLessThanOrEqual(canvas!.y + canvas!.height + .5);
  };

  // Landing, full screen: a flat capsule centred on the bottom edge.
  await seek(page, .265);
  canvas = await page.locator('[data-demo-canvas]').boundingBox();
  const resting = await bar.boundingBox();
  expect(resting!.width).toBeGreaterThan(resting!.height * 5);
  expect(Math.abs(resting!.x + resting!.width / 2 - (canvas!.x + canvas!.width / 2))).toBeLessThan(1);
  expect(canvas!.y + canvas!.height - (resting!.y + resting!.height)).toBeCloseTo(12, 0);

  // The tour: the hovered button fills, its pill names it whole, beside the bar.
  await seek(page, .27, .3);
  await expect(page.locator('[data-guided-demo]')).toHaveAttribute('data-demo-step', 'toolbar');
  await expect(toolbar.locator('[data-toolbar-item="agent"]')).toHaveAttribute('data-state', 'hover');
  const pill = toolbar.locator('[data-toolbar-pill="agent"]');
  await expect(pill).toBeVisible();
  await expect(pill).toHaveText('Agent⌘N');
  inside(await pill.boundingBox());
  expect((await pill.boundingBox())!.y + (await pill.boundingBox())!.height).toBeLessThanOrEqual(resting!.y);
  expect(await pill.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  const agent = await toolbar.locator('[data-toolbar-item="agent"]').boundingBox();
  const tip = await cursorTip();
  expect(Math.hypot(tip.x - (agent!.x + agent!.width / 2), tip.y - (agent!.y + agent!.height / 2))).toBeLessThan(4);
  const caption = await page.locator('[data-demo-caption]').boundingBox();
  expect(caption!.y + caption!.height).toBeLessThanOrEqual((await pill.boundingBox())!.y);

  // Mid-drag the hand holds the Terminal button while the bar swings.
  await seek(page, .27, .7);
  await expect(toolbar).toHaveAttribute('data-dragging', 'true');
  const held = await toolbar.locator('[data-toolbar-item="terminal"]').boundingBox();
  const handTip = await cursorTip();
  expect(Math.hypot(handTip.x - (held!.x + held!.width / 2), handTip.y - (held!.y + held!.height / 2))).toBeLessThan(4);
  inside(await bar.boundingBox());

  // Landed: standing on the left edge, centred, every icon upright.
  await seek(page, .5);
  await expect(toolbar).toHaveAttribute('data-edge', 'left');
  const left = await bar.boundingBox();
  expect(left!.height).toBeGreaterThan(left!.width * 5);
  expect(left!.x - canvas!.x).toBeCloseTo(12, 0);
  expect(Math.abs(left!.y + left!.height / 2 - (canvas!.y + canvas!.height / 2))).toBeLessThan(1);
  const glyph = await toolbar.locator('[data-toolbar-item="terminal"] svg').first().evaluate(el => new DOMMatrix(getComputedStyle(el.parentElement!.closest('[data-demo-toolbar-bar]')!).transform).multiply(new DOMMatrix(getComputedStyle(el.parentElement!).transform)));
  expect(Math.abs(glyph.b)).toBeLessThan(1e-6);

  // The terminal comes from the toolbar's menu, beside the bar.
  await seek(page, .815, .52);
  const menu = toolbar.locator('[data-toolbar-menu="terminal"]');
  await expect(menu).toHaveAttribute('data-open', 'true');
  await expect(menu.locator('p')).toHaveText('New terminal');
  await expect(menu.locator('[data-toolbar-choice="Shell"]')).toHaveAttribute('data-highlighted', 'true');
  const menuBox = await menu.boundingBox();
  inside(menuBox);
  expect(menuBox!.x).toBeGreaterThanOrEqual(left!.x + left!.width);
  await expect(page.locator('[data-assembly-surface="shell"]')).toHaveAttribute('data-demo-visible', 'false');
  await seek(page, .815, .9);
  await expect(menu).toHaveAttribute('data-open', 'false');
  await expect(page.locator('[data-assembly-surface="shell"]')).toHaveAttribute('data-demo-visible', 'true');
  await seek(page, .82);
  await expect(page.locator('[data-assembly-surface="shell"]')).toBeInViewport();
});
test('reduced motion still shows the toolbar, lying flat above the tiles', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/');
  const bar = page.locator('[data-demo-toolbar-bar]');
  await bar.scrollIntoViewIfNeeded();
  await expect(bar).toBeVisible();
  const box = await bar.boundingBox();
  expect(box!.width).toBeGreaterThan(box!.height * 5);
  await expect(page.locator('[data-toolbar-pill]:visible')).toHaveCount(0);
});
