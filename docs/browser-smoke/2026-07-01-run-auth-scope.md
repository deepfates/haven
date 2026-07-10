# Run Auth Scope Smoke

Date: 2026-07-01

Target:
- `http://127.0.0.1:4000/runs/ef60dac7-2195-4869-a53c-55544bd603c3`
- Created through `POST /dev/runs` with title `Browser smoke auth scope`,
  agent `auth-scope-smoke`, and workspace
  `/Users/deepfates/Hacking/github/deepfates/haven`.
- The saved dev agent used env keys `API_TOKEN` and `WORKSPACE`; the
  `API_TOKEN` value was `browser-secret-token`.

Checks:
- Run detail did not show an Ecto pending migration page.
- Run detail did not show a LiveView crash or exception page.
- `#run-facts-agent-auth-env` rendered `Credential env`.
- `#run-facts-agent-auth-reason` named `API_TOKEN` as the credential-like key.
- The rendered page text did not include `browser-secret-token`.
- At the default/current browser width, the page reported
  `scrollWidth == clientWidth == 656`.
- At a `390x844` mobile viewport, the auth badge remained visible and the page
  reported `scrollWidth == clientWidth == 390`.

Visual read:
- Run facts now preserve the same auth-scope clarity after launch that the
  inbox/start-run surface shows before launch.
- Only environment variable names are visible; values remain hidden from run
  detail and evidence surfaces.
