# Changelog

## 0.1.0a1

First alpha. macOS DMG on GitHub Releases; iPhone and iPad build from source.

- **Chat:** streamed replies with markdown, reasoning, tool calls, artifacts and file uploads.
- **Thread panel:** Oversight, Trace, Sources, Agent and Browser.
- **Agents:** overview, detail and builder.
- **Workflows:** run with a generated input form, follow runs live, approvals.
- **iPhone and iPad:** build from source with `make ios-run` or Xcode.

### Known limitations

- Login uses a browser session (cookies) until the SDK supports tokens.
- Image uploads depend on the server.
- Workflow runs need a worker on the server.
- No auto-update: download new versions from GitHub Releases.
- Not notarized: macOS asks you to allow the first launch (see the README).
