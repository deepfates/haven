# Run Capability Gap Summary Smoke

Date: 2026-07-01

Target:
- `http://127.0.0.1:4000/runs/99126c77-71e3-42b3-bebf-ac6e850bfdb5`
- Created through `POST /dev/runs` with title
  `Browser smoke capability gap summary`, agent `codex-acp`, and workspace
  `/Users/deepfates/Hacking/github/deepfates/haven`.

Checks:
- Run detail did not show an Ecto pending migration page.
- Run detail did not show a LiveView crash or exception page.
- `#run-agent-capability-gap-summary` rendered inside the existing capability
  gap evidence disclosure.
- The summary rendered the exact unsupported mediated families:
  `fs/read_text_file`, `fs/write_text_file`, and `terminal`.
- At the default/current browser width, the page reported
  `scrollWidth == clientWidth == 656`.
- At a `390x844` mobile viewport, the summary remained visible and the page
  reported `scrollWidth == clientWidth == 390`.

Visual read:
- The run facts still lead with agent, process, session, and timestamps.
- The capability gap disclosure now gives a plain-language trust summary before
  artifact filenames, so a user can understand what is not proven without
  reading raw probe report names first.
