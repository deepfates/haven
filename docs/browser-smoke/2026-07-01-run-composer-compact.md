# Run Composer Compact Smoke

Date: 2026-07-01

Target:
- `http://127.0.0.1:4000/runs/7383b7b0-89ae-422d-8c5c-ed4baa47bfad`
- Created through `POST /dev/runs` with `agent=stub-acp` and workspace `/Users/deepfates/Hacking/github/deepfates/haven`.

Checks:
- Root page and run page did not show the earlier Ecto pending migration page.
- Run page did not show a LiveView crash or exception page.
- Live connected run rendered one `#run-control-panel` and one `#run-prompt`.
- `#run-control-panel` used the sticky mobile composer classes, including `bottom-0`, `pb-[calc(0.75rem+env(safe-area-inset-bottom))]`, and `md:static`.
- `#run-prompt` rendered enabled with placeholder `Message the agent`, `rows="2"`, `min-h-20`, and `resize-y`.
- `#send-prompt-button` rendered enabled with `inline-flex`, centered content, and `gap-2`.
- `#cancel-run-button` rendered present with the compact icon/text layout and remained disabled while the run was idle with no active turn to cancel.

Control check:
- A disconnected historical run at `http://127.0.0.1:4000/runs/cfffed7d-fe8f-48b3-943d-6509e7b90c66` rendered the same compact field and buttons, but with the expected notice: `This run is not connected. Reconnect it before sending another prompt.`

Visual read:
- The composer now reads as a compact chat-style input area: short label, two-row text area, primary send action, and secondary cancel action.
- The evidence section remains below the composer; the control surface no longer dominates the run page as a dashboard panel.
