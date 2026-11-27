# Studio for macOS, iPhone and iPad

Native SwiftUI client for the Django AI SDK API.

- **Chat:** streamed replies with markdown, reasoning, tool calls, artifacts, citations and
  file uploads (attach, paste or drop).
- **Agents:** browse, inspect, start a chat, and build your own agents (tools, settings, access).
- **Workflows:** run a workflow with a generated input form and follow the run live.

```sh
make run   # swift run, dev build
make app   # build/Studio.app (ad-hoc signed)
```

Needs macOS 15+ and Xcode command line tools. The server URL is on the login screen
(default `http://127.0.0.1:8000`, the Django backend directly, not the Next.js proxy).

## iPhone and iPad

The iOS app is an XcodeGen project (`iOS/project.yml`) whose target compiles the same
`Sources/` as the Mac app; platform differences use `#if os(macOS)` / `#if os(iOS)`.
The generated `iOS/StudioiOS.xcodeproj` is not checked in. Needs Xcode and
`brew install xcodegen`.

```sh
make ios-project   # generate iOS/StudioiOS.xcodeproj (then open it in Xcode to run on a device)
make ios-build     # build for the iOS Simulator (no signing)
make ios-run       # build, boot the "iPhone 17" simulator, install, launch and open Device Hub
make ios-run IOS_SIM="iPad Pro 13-inch (M5)"
```

- **Server:** the simulator shares the Mac's network, so the default
  `http://127.0.0.1:8000` reaches a backend running on the Mac. A real device cannot: tap
  the server address on the login screen and enter the Mac's LAN address (run Django on
  `0.0.0.0:8000`, add the IP to `ALLOWED_HOSTS`, and allow the local-network prompt), or use
  an HTTPS tunnel. Plain HTTP is allowed only for local addresses (`NSAllowsLocalNetworking`).
- **Signing:** the simulator needs none. For a device, open the project in Xcode and pick
  your team under Signing & Capabilities (or set `DEVELOPMENT_TEAM` in `iOS/project.yml`).
- **Layout:** on iPhone the sidebar is the start screen (New Chat, Agents, Workflows,
  chats; pull to refresh, swipe to delete) and each row pushes its screen. Sign Out is in
  the account menu. On iPad the sidebar and the screen sit side by side. Workflows push the
  form on iPhone and show list and form side by side on iPad; a run opens in a sheet.

## Auth workaround

The SDK API only accepts Django session auth; it does not accept tokens yet. The app logs
in through allauth's **browser** client (`/_allauth/browser/v1/auth/login`), keeps the
`sessionid` and `csrftoken` cookies in `HTTPCookieStorage`, and sends `X-CSRFToken` on
every request, the same as the web app. No backend change is needed.

When the SDK accepts tokens, switch `Sources/Core/API.swift` to allauth's app client
(`/_allauth/app/v1`, `X-Session-Token` header) and drop the cookie handling.

## Layout

| Path | What |
|---|---|
| `Sources/App.swift` | App, login, sidebar navigation (split view on Mac/iPad, stack on iPhone), `AppStore` |
| `Sources/Core/` | `API` (+ per-feature extensions), `JSON`, logo |
| `Sources/Chat/` | `ChatStore`, stream reducer, chat view, composer, uploads, message parts |
| `Sources/Agents/`, `Sources/Workflows/` | Feature screens |
| `Resources/` | App icon (macOS) |
| `iOS/` | XcodeGen spec and asset catalog for the iPhone/iPad app |

Chat messages keep the AI SDK UIMessage shape (`parts` as raw JSON), the same as the web
app and `GET /api/threads/{id}/`, so `StreamReducer` folds the SSE stream into parts and
the views read them directly.
