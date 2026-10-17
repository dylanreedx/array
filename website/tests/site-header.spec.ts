import { expect, test } from '@playwright/test';

for (const width of [390, 1440]) {
  for (const theme of ['light', 'dark'] as const) {
    test(`shared header matches the homepage at ${width}px in ${theme} mode`, async ({ page }) => {
      await page.setViewportSize({ width, height: 960 });
      await page.addInitScript(theme => localStorage.setItem('array-theme', theme), theme);

      const measure = () => page.locator('.production-header').evaluate(header => {
        const selectors = ['.production-header__inner', '.brand', '.brand__mark', '.brand__logo', '.production-theme', '.download-split', '.download-split__mark', '.download-split__mark img'];
        return selectors.map(selector => {
          const element = header.querySelector(selector)!;
          const { x, y, width, height } = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return { selector, x, y, width, height, transform: style.transform, objectFit: style.objectFit, background: style.backgroundColor };
        });
      });

      await page.goto('/');
      const home = await measure();
      await expect(page.locator('.brand__logo')).toHaveCSS('transform', 'none');
      const inner = home[0];
      const download = home[5];
      expect(download.x + download.width).toBeCloseTo(inner.x + inner.width, 0);

      for (const route of ['/privacy', '/terms']) {
        await page.goto(route);
        expect(await measure(), route).toEqual(home);
        await expect(page.locator('html')).toHaveAttribute('data-theme', theme);
        await page.getByTestId('download-trigger').click();
        await expect(page.getByTestId('download-popover')).toBeVisible();
        await page.getByTestId('download-trigger').press('Escape');
        await expect(page.getByTestId('download-popover')).toBeHidden();
      }
    });
  }
}
