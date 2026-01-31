// Browser test using Playwright
import { chromium } from 'playwright';

const URL = 'http://localhost:8080';

async function test() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    console.log(`Navigating to ${URL}...`);
    await page.goto(URL);
    await page.screenshot({ path: '/tmp/1-loaded.png' });

    // Check page content
    const bodyText = await page.textContent('body');
    console.log('Page text:', bodyText?.slice(0, 200));

    // Wait for connection status
    console.log('Waiting for connection...');
    try {
      await page.waitForSelector('.status-dot.connected', { timeout: 10000 });
      console.log('Connected!');
    } catch {
      console.log('Connection timeout - checking status...');
      const statusText = await page.textContent('.status');
      console.log('Status:', statusText);
    }
    await page.screenshot({ path: '/tmp/2-status.png' });

    // Click New button (the header one, not the empty state one)
    console.log('Looking for New button...');
    const newButton = page.locator('.header-actions button:has-text("+ New")');
    if (await newButton.isVisible()) {
      console.log('Clicking New...');
      await newButton.click();
    } else {
      // Try the other button
      const altButton = page.locator('button:has-text("+ New Agent")');
      if (await altButton.isVisible()) {
        console.log('Clicking + New Agent...');
        await altButton.click();
      } else {
        console.log('ERROR: New button not visible');
        return false;
      }
    }

    // Wait for session view
    console.log('Waiting for session...');
    await page.waitForTimeout(2000);
    await page.screenshot({ path: '/tmp/3-after-new.png' });

    // Check what we have now
    const pageContent = await page.textContent('body');
    console.log('After New click:', pageContent?.slice(0, 300));

    // Listen to browser console
    page.on('console', msg => console.log('[BROWSER]', msg.text()));

    // Wait for initialization (agent can take up to 60s)
    console.log('Waiting for agent init (up to 90s)...');
    try {
      // Wait for input to become enabled (not just exist)
      await page.waitForFunction(() => {
        const input = document.querySelector('input');
        return input && !input.disabled;
      }, { timeout: 90000 });
      console.log('Input field enabled!');
    } catch {
      console.log('Input field timeout');
      await page.screenshot({ path: '/tmp/4-timeout.png' });
      const content = await page.textContent('body');
      console.log('Current content:', content?.slice(0, 500));
      return false;
    }
    await page.screenshot({ path: '/tmp/4-input-ready.png' });

    // Type and send
    console.log('Typing prompt...');
    await page.fill('input', 'say hello');
    await page.screenshot({ path: '/tmp/5-typed.png' });

    console.log('Clicking Send...');
    await page.click('button:has-text("Send")');

    // Wait for response
    console.log('Waiting for response (up to 30s)...');
    await page.waitForTimeout(5000);
    await page.screenshot({ path: '/tmp/6-waiting.png' });

    // Check for agent response
    for (let i = 0; i < 10; i++) {
      const content = await page.textContent('body');
      console.log(`Check ${i + 1}:`, content?.slice(0, 200));

      if (content?.toLowerCase().includes('hello')) {
        console.log('SUCCESS: Found hello in response!');
        await page.screenshot({ path: '/tmp/7-success.png' });
        return true;
      }
      await page.waitForTimeout(2000);
    }

    await page.screenshot({ path: '/tmp/7-final.png' });
    const finalContent = await page.textContent('body');
    console.log('Final content:', finalContent?.slice(0, 500));
    return false;

  } catch (err) {
    console.error('Test error:', err.message);
    await page.screenshot({ path: '/tmp/error.png' }).catch(() => {});
    return false;
  } finally {
    await browser.close();
  }
}

test().then(success => {
  console.log(success ? '\n✓ TEST PASSED' : '\n✗ TEST FAILED');
  process.exit(success ? 0 : 1);
});
