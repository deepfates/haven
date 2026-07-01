# Browser Smoke: Workspace Authority Preview

Date: 2026-07-01

Purpose: verify that run creation exposes the effective workspace authority
before a user starts an agent.

Target: `http://127.0.0.1:4000/`

Viewport: `390x844`

Checks:

- Inbox rendered with `h1` = `Inbox`.
- Start-run advanced controls exposed `#new-run-workspace-authority`.
- The visible authority preview rendered:
  - `Reads Ask All workspace paths`
  - `Writes Ask All workspace paths`
  - `Terminals Allow`
- No horizontal overflow at the mobile viewport.
- No pending migration page or server error page appeared.
- Browser console error/warning log check returned no entries.

This smoke verifies a small workspace-security UX improvement: the create-run
path now shows effective authority before launch, including the unrestricted
workspace default when path scopes are blank.
