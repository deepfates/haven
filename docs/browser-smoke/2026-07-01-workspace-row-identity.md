# Browser Smoke: Workspace Row Identity

Purpose: verify the mobile-first inbox row can distinguish saved workspace
folders from manual paths without reintroducing dashboard-style clutter or
horizontal overflow.

Checks were run against the in-app browser at `http://127.0.0.1:4000/` after
reloading the current dev server.

## Mobile Viewport

Viewport: `390x844`.

- `#haven-inbox` rendered.
- `#inbox-attention-summary` rendered.
- No Phoenix error page markers or pending migration text were present.
- Document width stayed bounded: `clientWidth=390`, `scrollWidth=390`.
- Workspace row identity chips were present with ids ending in
  `-workspace-kind`.
- The first observed chip read `Saved workspace · Ready`.
- The first chip title named the saved workspace and its full path:
  `Haven repo branch smoke: /Users/deepfates/Hacking/github/deepfates/haven`.

This proves the current browser UI exposes saved/manual workspace identity in
the primary inbox row while preserving the mobile no-overflow invariant.
