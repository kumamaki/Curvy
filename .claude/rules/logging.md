# Logging in Curvy

## The central hub: `AppLog`

All loggers live in `mac/Curvy/Support/AppLog.swift`. Never construct a `Logger` inline in a file — always reference a category from `AppLog`:

```swift
AppLog.net.pub("GET /repos/kumamaki/curvy-room")
AppLog.store.warning("poll skipped — no invite")
AppLog.crypto.error("AES-GCM open failed")
```

## Categories

| Category | What to log there |
|----------|------------------|
| `net`    | GitHub API calls: method + path, status codes, errors |
| `store`  | MessageStore: poll loop ticks, send results, dropped comments |
| `session`| Phase transitions, invite decode, access verification |
| `crypto` | AES-GCM seal/open failures |
| `blobs`  | BlobFetcher: download start/complete, cache hits, decrypt failures |
| `images` | ImagePipeline: resize, recompress, GIF size warnings |
| `notif`  | Notifier + NotificationDelegate: auth, post, response handler |
| `ql`     | QuickLookManager: staging, preview lifecycle |
| `ui`     | ChatView scroll position, anchor decisions |

## Levels

- **`.pub("...")`** — `.notice` + full `privacy: .public`. Default for dev diagnostics. Use for paths, IDs, dimensions, status codes, error descriptions.
- **`.warning(...)`** — degraded but recoverable (e.g. poll failed, will retry).
- **`.error(...)`** — actual failure that needs investigation.
- No `.debug` — it's filtered out of `log show` by default, so it's invisible in practice.

## Privacy contract

Safe to log via `.pub`: GitHub paths, HTTP status codes, comment IDs, asset paths, image dimensions, error messages.

**Never** pass through `.pub` or any logger: room key, PAT, decrypted message body, display names.

## Checking logs

```sh
# Tail everything live (Ctrl-C to stop):
just logs

# Tail one category:
just logs net
just logs store

# Dump last N of history and exit:
just logs-since              # all, last 5m
just logs-since net 30s      # Net only, last 30s
just logs-since store 2m
```

## Adding a new category

1. Add a static let to the `AppLog` enum in `AppLog.swift`.
2. Update the category list comment in `justfile` (the `logs` and `logs-since` recipe headers).
3. That's it — no project.yml changes needed.
