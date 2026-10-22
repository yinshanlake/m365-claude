# m365-claude

Run [Claude Code](https://code.claude.com) against Microsoft 365 Copilot model routes instead of the Anthropic API.

This repository contains only the glue layer: a launcher, a process manager, a local Anthropic-compatible adapter, and a small patch for an upstream proxy. The upstream proxy is not vendored; you clone it at a pinned commit.

> **Status: personal, experimental tooling.** It relies on an unofficial, reverse-engineered M365 Copilot client protocol that can change without notice. Use it only with an account and in a way that your organization's policies allow. The route names are proxy identifiers, not verified model versions.

## How it works

```text
m365-claude (Start-M365Claude.ps1)
  -> Claude Code (normal tools, permissions, MCP)
  -> Anthropic adapter       127.0.0.1:4145   cli/m365-anthropic.cjs   ("ClaudeRouter")
  -> m365-copilot-proxy      127.0.0.1:4144   OpenAI-compatible        ("CliProxy")
  -> Microsoft 365 Copilot
```

| Piece | What it does |
| --- | --- |
| `Start-M365Claude.ps1` | Starts the two CLI services, waits for both ports, sets a process-scoped Claude Code environment (`ANTHROPIC_BASE_URL`, local bearer token, a dedicated `CLAUDE_CONFIG_DIR`, model defaults), runs `claude`, and then restores the caller's environment. |
| `Manage-Proxies.ps1` | Starts, stops, and reports status for the background services. It tracks process ID, executable path, and start time so it never stops a process it did not start, and it refuses to take over a port that is already in use. |
| `cli/m365-anthropic.cjs`, `cli/anthropic-protocol.cjs` | Translate between the Anthropic Messages API and the proxy's OpenAI-style API: streaming SSE, tool calls and results, deferred tool schemas, cancellation, JSON output validation, and local token estimates. |
| `cli/models.json`, `cli/route-m365.cjs` | Model catalog and strict alias resolution. An unknown model returns HTTP 400; there is no silent fallback. |
| `cli/agent-system-prompt.md` | The system prompt that the launcher passes to Claude Code. |
| `patches/m365-copilot-proxy-session-isolation.patch` | Adds the optional OpenAI `user` field to the proxy's conversation fingerprint, so separate CLI sessions that start with the same message do not share M365 conversation state. |

The adapter exposes `/v1/messages`, `/v1/messages/count_tokens`, `/v1/models`, `/v1/models/{id}`, and `/health`. All endpoints except `/health` require the local bearer token.

## Prerequisites

- Windows with PowerShell 7.4 or later (`pwsh`)
- Node.js 24 and Git
- Claude Code on `PATH`, or `M365_CLAUDE_EXE` set to its path
- Google Chrome, used for the interactive Microsoft sign-in
- A Microsoft 365 account with Copilot access

## Setup

Run these commands from the repository root.

1. Clone the upstream proxy at the tested commit and apply the patch:

   ```powershell
   git clone https://github.com/cramt/m365-copilot-proxy.git
   git -C m365-copilot-proxy checkout 65905e881d6597040966aff9b087aa9a908b358a
   git -C m365-copilot-proxy apply ../patches/m365-copilot-proxy-session-isolation.patch
   Set-Location m365-copilot-proxy
   npx --yes pnpm@10.32.1 install --frozen-lockfile
   npx --yes pnpm@10.32.1 run build
   Set-Location ..
   ```

2. Install the adapter's runtime dependencies (OpenAI and Anthropic SDKs, JSON schema validator, tokenizer):

   ```powershell
   npm ci --prefix cli/claude-router
   ```

3. Create the local adapter credential. Any random string works; it only protects the loopback adapter.

   ```powershell
   New-Item -ItemType Directory .local -Force | Out-Null
   (New-Guid).Guid.Replace('-', '') | Set-Content .local/claude-router-api-key.txt -NoNewline
   ```

4. Optional: create `.local/claude-mcp.json` in Claude Code's `--mcp-config` format. Without it, start with `-NoMcp`.

5. Optional: add a shell shortcut, for example in your PowerShell profile:

   ```powershell
   function m365-claude { pwsh -NoProfile -File 'C:/path/to/m365-claude/Start-M365Claude.ps1' @args }
   ```

The first request opens a Chrome window for Microsoft sign-in. The upstream proxy caches tokens outside this repository.

## Usage

```powershell
m365-claude                          # default route (gpt-5.5-think-deeper) or your saved /model choice
m365-claude -Model claude-opus       # pick the startup route
m365-claude -NoMcp                   # no MCP servers
m365-claude -Directory C:/src/app    # start in another directory
m365-claude -BuiltInTools Read,Edit,Bash
m365-claude --continue               # other arguments pass through to Claude Code
```

Inside a session, use `/model` to switch routes. The routes are listed in `cli/models.json`; availability depends on your M365 entitlement, and some routes are metered.

Manage the services directly:

```powershell
pwsh -NoProfile -File Manage-Proxies.ps1 -Action Status
pwsh -NoProfile -File Manage-Proxies.ps1 -Action Stop -Service ClaudeRouter
```

`-Service All` also manages two optional services that `m365-claude` does not need: a second instance of the same proxy on port 4143 (`CopilotProxy`), and https://github.com/HEXUXIU/M365-Copilot2API on port 4141 (`Copilot2API`). Copilot2API needs its own checkout and `.local/copilot2api-admin-password.txt`.

Logs and process state are written to `runtime/`.

### Configuration

| Variable | Default | Used by |
| --- | --- | --- |
| `M365_CLAUDE_EXE` | `claude.exe` found on `PATH` | launcher |
| `M365_CHROME_PATH` | `C:/Program Files/Google/Chrome/Application/chrome.exe` | proxy sign-in |
| `M365_LOGIN_TIMEZONE` | `UTC` | proxy sign-in |

## Known limits

- Tool calls are reconstructed from model text by the proxy; they are not native tool-call objects. Correct transport does not guarantee that the model picks the right tool.
- Observed behavior varies by route: a Sonnet route refused large tool descriptions, and GPT and Opus routes sometimes drifted from browser tasks. None of the routes has passed a full agent evaluation.
- Not supported: Anthropic server tools, PDF document input, signed thinking, precise effort control, prompt-cache accounting, and a guaranteed 1M-token context. Token counts are local estimates.
- Requests are serialized. There are no automatic retries or model fallbacks; upstream rate limits and `Retry-After` are passed through.
- The CLI proxy runs with `M365_FORCE_AGENT=0`, so it does not create Copilot Studio agents.

## Tests

```powershell
node --test cli/anthropic-protocol.test.cjs
```

This protocol suite exercises real local HTTP exchanges through the Anthropic SDK. Run it from a shell where `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, and `ANTHROPIC_API_KEY` are unset (for example, outside a `m365-claude` session). The SDK client prefers those variables and the test would get a 401.

## Security

- Never commit `.local/`. It holds the adapter credential, optional MCP configuration, and the dedicated Claude Code profile. `.gitignore` excludes it, along with `runtime/` and the upstream checkouts.
- All services bind to `127.0.0.1` only.
- The launcher adds no permission-bypass flags. Claude Code's own approvals still apply.

## Credits

- https://github.com/cramt/m365-copilot-proxy, the M365 Copilot to OpenAI-compatible proxy
- https://github.com/HEXUXIU/M365-Copilot2API, the optional alternative proxy
- https://github.com/Joouis/agent-maestro, used as a reference for Anthropic protocol handling