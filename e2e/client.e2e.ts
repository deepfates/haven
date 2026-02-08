import { test, expect } from "@playwright/test";

test("create session and receive agent response", async ({ page }) => {
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      // Surface browser errors in test output
      console.error("[browser]", msg.text());
    }
  });

  await page.goto("/");

  const header = page.locator("header");
  await expect(header.getByRole("heading", { name: "Agents" })).toBeVisible();
  await expect(header.getByText(/connected/i)).toBeVisible();

  const newButton = header.getByRole("button", { name: "+ New" });
  await expect(newButton).toBeEnabled();
  await newButton.click();

  // Fill in the "New Conversation" modal
  const modalInput = page.getByPlaceholder("What would you like to work on?");
  await expect(modalInput).toBeVisible({ timeout: 5_000 });
  await modalInput.fill("test session");
  await page.getByRole("button", { name: "Create" }).click();

  // Wait for session view with chat input
  const chatInput = page.getByPlaceholder("Send a message...");
  await expect(chatInput).toBeVisible({ timeout: 20_000 });

  await chatInput.fill("hello");
  await page.getByRole("button", { name: "Send" }).click();

  await expect(page.getByText("stubbed response")).toBeVisible({
    timeout: 20_000,
  });
});
