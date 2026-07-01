# Browser Smoke: Capability Gap Family Labels

Purpose: verify real-agent capability gap evidence names exact unsupported
mediated ACP capability families instead of only showing a count or broad
file/terminal wording.

Checks were run against the in-app browser at `http://127.0.0.1:4000/` after
reloading the current dev server.

## Inbox Evidence

- `#haven-inbox` rendered.
- No Phoenix error page markers or pending migration text were present.
- Document width stayed bounded in the current browser viewport:
  `clientWidth=656`, `scrollWidth=656`.
- Capability gap badges rendered with text such as `3 capability gaps`.
- Badge titles now name exact unsupported mediated families:
  `fs/read_text_file/fs/write_text_file/terminal`.
- The page content also included exact family strings, so users can search and
  inspect capability boundaries without knowing the underlying report JSON.

This proves the rendered app now carries the validated
`unsupported_client_capabilities` evidence through to user-visible trust
surfaces.
