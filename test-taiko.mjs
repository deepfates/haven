import { openBrowser, goto, click, write, text, waitFor, closeBrowser, screenshot, $ } from 'taiko';

const URL = 'http://localhost:8080';

try {
  console.log('Opening browser with Taiko...');
  await openBrowser({ headless: true, args: ['--no-sandbox'] });

  console.log('Navigating...');
  await goto(URL);
  await screenshot({ path: '/tmp/taiko-1.png' });

  console.log('Waiting for connection...');
  await waitFor(async () => await text('connected').exists(), 5000);
  console.log('Connected!');

  console.log('Clicking New...');
  await click($('.header-actions button'));

  console.log('Waiting for init...');
  await waitFor(60000); // wait for agent init

  await screenshot({ path: '/tmp/taiko-2.png' });

  const bodyText = await $('body').text();
  console.log('Page:', bodyText.slice(0, 200));

  console.log('✓ Taiko works!');
} catch (err) {
  console.error('Error:', err.message);
} finally {
  await closeBrowser();
}
