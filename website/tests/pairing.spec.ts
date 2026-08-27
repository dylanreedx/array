import { expect, test } from '@playwright/test';

const invitation = 'v1.private%2Bpairing-token';

test('pairing page keeps its invitation fragment private', async ({ page }) => {
  const leakedRequests: string[] = [];
  page.on('request', request => {
    if (request.url().includes('private') || request.url().includes('pairing-token')) leakedRequests.push(request.url());
  });

  await page.goto(`/pair#${invitation}`);
  await expect(page).toHaveTitle('Pair Array Companion');
  await expect(page.getByRole('heading', { name: 'Finish pairing on your iPhone.' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open Array to Pair' })).toBeEnabled();
  await expect(page.getByText('The invitation stays on this device')).toBeVisible();
  expect(page.url().endsWith(`#${invitation}`)).toBe(true);
  expect(leakedRequests).toEqual([]);
});

test('pairing page handles a missing invitation safely', async ({ page }) => {
  await page.goto('/pair');
  await expect(page.getByRole('button', { name: 'Open Array to Pair' })).toBeHidden();
  await expect(page.getByText('This pairing invitation is missing or incomplete.')).toBeVisible();
});

test('pairing page exposes configured Apple installation destinations', async ({ page }) => {
  await page.goto(`/pair#${invitation}`);
  await expect(page.getByRole('link', { name: 'Get Array on TestFlight' })).toHaveAttribute('href', 'https://testflight.apple.com/join/arrayalpha');
  await expect(page.getByRole('link', { name: 'View on the App Store' })).toHaveAttribute('href', 'https://apps.apple.com/ca/app/array/id123456789');
});

test('AASA limits universal links to the pairing path', async ({ request }) => {
  const response = await request.get('/.well-known/apple-app-site-association');
  expect(response.ok()).toBe(true);
  expect(await response.json()).toEqual({
    applinks: {
      details: [{
        appIDs: ['46TTB6J9DZ.dev.dylanreedx.continuum'],
        components: [{ '/': '/pair', comment: 'Array Companion pairing invitations' }],
      }],
    },
  });
});
