# RootCause MCP installer

Connect your AI agent to RootCause in one command.

RootCause speaks [MCP](https://modelcontextprotocol.io) (Model Context Protocol). Any agent that
speaks MCP can search, read, file and update tickets, comment, schedule work on a Gantt board and
report what has slipped, acting as you with exactly your permissions. This script writes that
connection into whichever agent you use, so you never have to find or hand-edit its config file.

One file, no dependencies beyond `bash` and `curl`. Nothing here is specific to one agent.

## Quick start

1. In RootCause, open your profile and generate a **personal access token**. It starts with
   `rc_pat_` and is shown once. Copy it.
2. On the machine where your agent runs, in a terminal:

   ```bash
   git clone git@github.com:ajayvasan-nitro/rc_mcp_installation.git
   cd rc_mcp_installation
   ./rootcause-mcp.sh
   ```

   Or, without cloning:

   ```bash
   curl -fsSLo rootcause-mcp.sh https://raw.githubusercontent.com/ajayvasan-nitro/rc_mcp_installation/main/rootcause-mcp.sh
   bash rootcause-mcp.sh
   ```

3. Pick your agent from the menu, enter the RootCause MCP address your admin gave you, paste the
   token when asked, and follow the hints it prints for your agent.

That's it. The script tests the connection before writing anything, backs up any config file it
touches, and never echoes your token.

## What it supports

| Agent | What gets configured |
|---|---|
| Claude Code (terminal, VS Code or JetBrains extension) | Registered through `claude mcp add`; falls back to editing `~/.claude.json` or the project `.mcp.json` |
| Claude Desktop | `claude_desktop_config.json`, via the `mcp-remote` bridge (needs Node.js) |
| Cursor | `~/.cursor/mcp.json` or the project `.cursor/mcp.json` |
| VS Code with GitHub Copilot | the user `mcp.json` or the project `.vscode/mcp.json` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |
| OpenAI Codex CLI | `~/.codex/config.toml` |
| Gemini CLI | `~/.gemini/settings.json` |
| Something else | prints a generic JSON config, a Claude API connector snippet and a curl check |

Mac, Linux and Windows (Git Bash or WSL) paths are handled.

## The menu

```
What would you like to do?
   1  Connect an agent              or update a connection you already have
   2  Show what is connected
   3  Test an address and token     changes nothing
   4  Disconnect an agent
   5  Quit
```

- **Connect** asks for the agent, where to store it (everywhere, or only the current folder),
  the MCP address and the token. Running it again for the same agent updates the connection in
  place: new token, new address, either.
- **Show** lists every agent RootCause is connected to and the config file for each. Tokens are
  never displayed.
- **Test** does the MCP handshake against the address with the token and tells you in plain
  words what went wrong if it fails: rejected token, wrong path, wrong hostname, unreachable.
- **Disconnect** removes the RootCause entry and leaves the rest of the agent's config untouched.

## Flags (for scripts and for agents)

Everything the menu asks can be passed up front, so a setup script, or an agent running this
itself from an isolated environment, needs no terminal:

```bash
./rootcause-mcp.sh --client claude-code --url https://mcp.example.com/mcp --token rc_pat_...
./rootcause-mcp.sh --client cursor --scope project --url ... --token ...
./rootcause-mcp.sh --remove --client vscode
./rootcause-mcp.sh --show
./rootcause-mcp.sh --test --url ... --token ...
```

| Flag | Meaning |
|---|---|
| `--client NAME` | `claude-code`, `claude-desktop`, `cursor`, `vscode`, `windsurf`, `codex`, `gemini`, `other` |
| `--scope user\|project` | where to store it (Claude Code, Cursor, VS Code only). Default `user` |
| `--url URL` | the MCP address. `https://` and `/mcp` are added if missing |
| `--token TOKEN` | your personal access token |
| `--name NAME` | the server name inside the agent's config. Default `rootcause` |
| `--no-test` | skip the connection test before writing |
| `--remove`, `--show`, `--test` | the other menu actions |
| `--help`, `--version` | |

## After connecting

Restart the agent, or reload its MCP servers, then try:

> who am I in rootcause, and which projects can I see?

The server's own instructions tell the agent to call `whoami` first and to read a project's
statuses before filing or triaging, so the agent needs no further setup.

Everything the agent changes is attributed to you and marked as agent activity. It can never
reach further than your token allows, and a token can never reach further than you can.

## Updating, removing, revoking

- **Token or address changed:** run the script again and pick the same agent. The old entry is
  replaced, and a backup of the config file is left beside it (`<file>.bak-<timestamp>`).
- **Disconnect:** `./rootcause-mcp.sh --remove`, or option 4 in the menu.
- **Token compromised or no longer needed:** revoke it in RootCause under your profile.
  Disconnecting an agent does not revoke the token.
- **Project scope:** `.mcp.json`, `.cursor/mcp.json` and `.vscode/mcp.json` hold your token in
  plain text. Add them to `.gitignore` before you commit.

## Troubleshooting

| Message | What it means |
|---|---|
| RootCause rejected the token (HTTP 401) | Token pasted incompletely, revoked or expired. Generate a new one. |
| Nothing at … (HTTP 404) | Wrong path. The address ends in `/mcp`; the script adds it, so check the hostname. |
| RootCause refused the Host header (HTTP 421) | Use the exact hostname RootCause is published on, not an IP or alias. |
| Could not reach … | Network, VPN or firewall. Try the address in a browser from the same machine. |
| Neither python3 nor jq is installed | The script prints the exact snippet to paste into the config file instead. |
| Claude Desktop: Node.js (npx) was not found | Install Node.js from https://nodejs.org. Claude Desktop runs only local servers, so it reaches RootCause through the `mcp-remote` bridge. |
| Claude Desktop shows nothing after restart | Quit it fully (not just the window). The first launch downloads `mcp-remote` and can take a few seconds. |

Not every client can connect yet. The claude.ai web app and Claude Desktop's own "custom
connector" flow require OAuth, which RootCause's MCP endpoint does not publish. Use Claude Code,
the bridge for Claude Desktop, or any client that accepts a bearer header.

## For RootCause admins

The MCP surface runs as its own container on port 8091 beside the web app. To let people use
this installer you need to:

1. Route a hostname (for example `mcp.yourcompany.com`) to that port over TLS.
2. Set `MCP_ALLOWED_HOSTS` and `MCP_ALLOWED_ORIGINS` to that hostname, or DNS-rebinding
   protection stays off and the process says so at startup.
3. Tell your team the address. It is the one thing the installer cannot guess.

Hand-configured clients send the token as `Authorization: Bearer rc_pat_...` to
`https://<hostname>/mcp` over Streamable HTTP.

## Security notes

- The script sends nothing anywhere except to the RootCause address you give it, and only for
  the connection test.
- The token is read without echo and is never printed, not even by `--show`.
- Config files the script creates are set to owner-only permissions. Files that already existed
  keep theirs.
- Every file is backed up before it is changed.
- This repository contains no tokens or addresses. Do not commit yours into it.
