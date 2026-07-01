# Run Empty Thread Smoke

Date: 2026-07-01

Target:
- `http://127.0.0.1:4000/runs/b524320e-f66d-499a-8fd6-0594a8971f0b`
- Created through `POST /dev/runs` with `agent=stub-acp` and workspace `/Users/deepfates/Hacking/github/deepfates/haven`.

Initial run checks:
- Root/run page did not show an Ecto pending migration page.
- Run page did not show a LiveView crash or exception page.
- Fresh live run rendered `#run-thread-empty-state` before any transcript messages.
- Empty state text was `Ready for a prompt` and `The agent is connected and waiting.`
- `#run-conversation` was absent before the first prompt.
- `#run-prompt` was enabled with placeholder `Message the agent`.

Prompted run checks:
- Browser submitted `hello empty thread smoke` through `#run-prompt-form`.
- Run returned to `idle`.
- `#run-thread-empty-state` was removed after transcript content existed.
- `#run-conversation` rendered the user message and `Echo: hello empty thread smoke`.

Visual read:
- A fresh run now reads as a conversation waiting for input instead of a metadata page with an empty gap.
- Once messages exist, the transcript takes over and the empty state does not remain as persistent chrome.
