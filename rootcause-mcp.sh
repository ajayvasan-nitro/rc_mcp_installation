#!/usr/bin/env bash
# rootcause-mcp.sh — connect your AI agent to RootCause over MCP.
#
# RootCause speaks MCP (Model Context Protocol) at https://<mcp-host>/mcp. Any agent that
# speaks MCP can read and change your work there, acting as you, using a personal access
# token from your profile page. This script writes that connection into whichever agent you
# use, so you never have to find or hand-edit its config file.
#
#   bash rootcause-mcp.sh                 guided: pick your agent, paste the token, done
#   bash rootcause-mcp.sh --show          what is connected right now, and where
#   bash rootcause-mcp.sh --remove        disconnect RootCause from an agent
#   bash rootcause-mcp.sh --test          check the address and token without changing anything
#
# Everything can also be given up front, for scripts or for an agent running this itself:
#
#   bash rootcause-mcp.sh --client claude-code --url https://mcp.example.com/mcp --token rc_pat_...
#   bash rootcause-mcp.sh --client cursor --scope project --url ... --token ...
#   bash rootcause-mcp.sh --remove --client vscode
#
# Clients: claude-code, claude-desktop, cursor, vscode, windsurf, codex, gemini, other
# Scope (claude-code, cursor, vscode only): user (default, every project) or project (this folder)
#
# Needs: bash, curl. python3 or jq to edit JSON configs (without either you get a snippet
# to paste). Claude Desktop additionally needs Node.js, because it only runs local servers
# and reaches RootCause through the `mcp-remote` bridge.
#
# Nothing is sent anywhere except to the RootCause address you give, and only when you ask
# for a connection test. Every config file is backed up beside itself before it is changed.

set -euo pipefail

VERSION="1.0.0"
DEFAULT_NAME="rootcause"

# --- Presentation ----------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
	BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%s✘ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
hint() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }

# Read interactively from the terminal even when the script itself arrived on stdin
# (`bash <(curl ...)` and `curl ... | bash` both do that).
if [ -t 0 ]; then
	TTY_IN=/dev/stdin
elif ( : </dev/tty ) 2>/dev/null; then
	TTY_IN=/dev/tty
else
	TTY_IN=''
fi

ask() { # ask VAR "Prompt" [default]
	local var="$1" prompt="$2" default="${3:-}" answer
	[ -n "$TTY_IN" ] || fail "No terminal to ask on. Pass --url, --token and --client instead (see --help)."
	if [ -n "$default" ]; then
		printf '%s [%s]: ' "$prompt" "$default"
	else
		printf '%s: ' "$prompt"
	fi
	IFS= read -r answer <"$TTY_IN" || fail "Input ended. Nothing changed."
	printf -v "$var" '%s' "${answer:-$default}"
}

ask_secret() { # ask_secret VAR "Prompt" — never echoed
	local var="$1" prompt="$2" answer
	[ -n "$TTY_IN" ] || fail "No terminal to ask on. Pass --token instead."
	printf '%s: ' "$prompt"
	IFS= read -rs answer <"$TTY_IN" || { printf '\n'; fail "Input ended. Nothing changed."; }
	printf '\n'
	printf -v "$var" '%s' "$answer"
}

confirm() { # confirm "Question" [Y|N]  → 0 for yes
	local answer default="${2:-Y}"
	if [ -z "$TTY_IN" ]; then [ "$default" = Y ]; return; fi
	if [ "$default" = Y ]; then printf '%s [Y/n]: ' "$1"; else printf '%s [y/N]: ' "$1"; fi
	IFS= read -r answer <"$TTY_IN" || true
	answer="${answer:-$default}"
	case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

choose() { # choose VAR "Title" "key|Label|detail" ...  → VAR=key
	local var="$1" title="$2"; shift 2
	local -a keys=() labels=() details=()
	local item
	for item in "$@"; do
		keys+=("${item%%|*}"); item="${item#*|}"
		labels+=("${item%%|*}"); details+=("${item#*|}")
	done
	head_ "$title"
	local i
	for i in "${!keys[@]}"; do
		printf '  %s%2d%s  %-34s %s%s%s\n' "$CYAN" "$((i + 1))" "$RESET" "${labels[$i]}" "$DIM" "${details[$i]}" "$RESET"
	done
	local pick
	while :; do
		ask pick "Choose 1-${#keys[@]}"
		if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#keys[@]}" ]; then
			printf -v "$var" '%s' "${keys[$((pick - 1))]}"
			return
		fi
		warn "Type a number between 1 and ${#keys[@]}."
	done
}

mask() { # show only the tail of a secret
	local s="$1"
	if [ "${#s}" -le 8 ]; then printf '%s' '••••••••'; else printf '%s…%s' "${s:0:7}" "${s: -4}"; fi
}

# --- Platform ---------------------------------------------------------------------------------

case "$(uname -s 2>/dev/null || echo unknown)" in
	Darwin) OS=mac ;;
	MINGW*|MSYS*|CYGWIN*) OS=windows ;;
	*) OS=linux ;;
esac

winpath() { # APPDATA as a path this shell can use
	if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "${1//\\//}"; fi
}

appdata() { [ -n "${APPDATA:-}" ] && winpath "$APPDATA" || printf '%s/AppData/Roaming' "$HOME"; }

have() { command -v "$1" >/dev/null 2>&1; }

if have python3; then JSON_TOOL=python3; elif have jq; then JSON_TOOL=jq; else JSON_TOOL=''; fi

# --- JSON config editing ----------------------------------------------------------------------
#
# Every JSON-configured client keeps servers in one top-level object ("mcpServers", or
# "servers" for VS Code). These three verbs are all we ever need on it. Other keys in the
# file are left exactly as they were.

json_set() { # json_set FILE CONTAINER NAME ENTRY_JSON
	local file="$1" container="$2" name="$3" entry="$4"
	backup "$file"
	mkdir -p "$(dirname "$file")"
	if [ "$JSON_TOOL" = python3 ]; then
		python3 - "$file" "$container" "$name" "$entry" <<-'PY'
		import json, os, sys
		path, container, name, entry = sys.argv[1:5]
		data = {}
		if os.path.exists(path) and os.path.getsize(path):
		    with open(path) as fh:
		        data = json.load(fh)
		data.setdefault(container, {})[name] = json.loads(entry)
		with open(path, 'w') as fh:
		    json.dump(data, fh, indent=2)
		    fh.write('\n')
		PY
	else
		local tmp; tmp="$(mktemp)"
		if [ -s "$file" ]; then
			jq --arg c "$container" --arg n "$name" --argjson e "$entry" '.[$c] = ((.[$c] // {}) + {($n): $e})' "$file" >"$tmp"
		else
			jq -n --arg c "$container" --arg n "$name" --argjson e "$entry" '{($c): {($n): $e}}' >"$tmp"
		fi
		mv "$tmp" "$file"
	fi
	chmod 600 "$file" 2>/dev/null || true
}

json_remove() { # json_remove FILE CONTAINER NAME  → 0 if it was there
	local file="$1" container="$2" name="$3"
	[ -s "$file" ] || return 1
	json_has "$file" "$container" "$name" || return 1
	backup "$file"
	if [ "$JSON_TOOL" = python3 ]; then
		python3 - "$file" "$container" "$name" <<-'PY'
		import json, sys
		path, container, name = sys.argv[1:4]
		with open(path) as fh:
		    data = json.load(fh)
		data.get(container, {}).pop(name, None)
		with open(path, 'w') as fh:
		    json.dump(data, fh, indent=2)
		    fh.write('\n')
		PY
	else
		local tmp; tmp="$(mktemp)"
		jq --arg c "$container" --arg n "$name" 'if .[$c] then .[$c] |= del(.[$n]) else . end' "$file" >"$tmp"
		mv "$tmp" "$file"
	fi
}

json_has() { # json_has FILE CONTAINER NAME
	local file="$1" container="$2" name="$3"
	[ -s "$file" ] || return 1
	if [ "$JSON_TOOL" = python3 ]; then
		python3 - "$file" "$container" "$name" <<-'PY'
		import json, sys
		path, container, name = sys.argv[1:4]
		try:
		    with open(path) as fh:
		        data = json.load(fh)
		except Exception:
		    sys.exit(1)
		sys.exit(0 if name in (data.get(container) or {}) else 1)
		PY
	elif [ "$JSON_TOOL" = jq ]; then
		jq -e --arg c "$container" --arg n "$name" '.[$c][$n]? // empty' "$file" >/dev/null 2>&1
	else
		grep -q "\"$name\"" "$file" 2>/dev/null
	fi
}

json_url_of() { # best-effort: the URL stored for NAME, for --show
	local file="$1" container="$2" name="$3"
	if [ "$JSON_TOOL" = python3 ]; then
		python3 - "$file" "$container" "$name" <<-'PY' 2>/dev/null || true
		import json, sys
		path, container, name = sys.argv[1:4]
		with open(path) as fh:
		    e = json.load(fh).get(container, {}).get(name, {})
		url = e.get('url') or e.get('serverUrl') or e.get('httpUrl')
		if not url:
		    args = e.get('args') or []
		    url = next((a for a in args if a.startswith('http')), '')
		print(url or '')
		PY
	elif [ "$JSON_TOOL" = jq ]; then
		jq -r --arg c "$container" --arg n "$name" '.[$c][$n] | (.url // .serverUrl // .httpUrl // ((.args // [])[] | select(startswith("http"))) // "")' "$file" 2>/dev/null | head -1
	fi
}

backup() {
	local file="$1"
	[ -s "$file" ] || return 0
	local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
	cp -p "$file" "$file.bak-$stamp"
	hint "backed up $file → $file.bak-$stamp"
}

# --- Client catalogue -------------------------------------------------------------------------
#
# One row per client: where its config lives for each scope, which key holds servers, and
# what one server entry looks like. Adding a client means adding a case to each function.

client_label() {
	case "$1" in
		claude-code)    echo "Claude Code" ;;
		claude-desktop) echo "Claude Desktop" ;;
		cursor)         echo "Cursor" ;;
		vscode)         echo "VS Code (GitHub Copilot)" ;;
		windsurf)       echo "Windsurf" ;;
		codex)          echo "OpenAI Codex CLI" ;;
		gemini)         echo "Gemini CLI" ;;
		other)          echo "another agent" ;;
		*)              return 1 ;;
	esac
}

client_supports_project_scope() { case "$1" in claude-code|cursor|vscode) return 0 ;; *) return 1 ;; esac; }

config_path() { # config_path CLIENT SCOPE
	local client="$1" scope="$2"
	case "$client" in
		claude-code)
			if [ "$scope" = project ]; then echo "$PWD/.mcp.json"; else echo "$HOME/.claude.json"; fi ;;
		claude-desktop)
			case "$OS" in
				mac)     echo "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
				windows) echo "$(appdata)/Claude/claude_desktop_config.json" ;;
				*)       echo "$HOME/.config/Claude/claude_desktop_config.json" ;;
			esac ;;
		cursor)
			if [ "$scope" = project ]; then echo "$PWD/.cursor/mcp.json"; else echo "$HOME/.cursor/mcp.json"; fi ;;
		vscode)
			if [ "$scope" = project ]; then echo "$PWD/.vscode/mcp.json"; else
				case "$OS" in
					mac)     echo "$HOME/Library/Application Support/Code/User/mcp.json" ;;
					windows) echo "$(appdata)/Code/User/mcp.json" ;;
					*)       echo "$HOME/.config/Code/User/mcp.json" ;;
				esac
			fi ;;
		windsurf) echo "$HOME/.codeium/windsurf/mcp_config.json" ;;
		codex)    echo "$HOME/.codex/config.toml" ;;
		gemini)   echo "$HOME/.gemini/settings.json" ;;
	esac
}

container_key() { case "$1" in vscode) echo servers ;; *) echo mcpServers ;; esac; }

json_quote() { # a JSON string literal for $1 (handles quotes and backslashes)
	local s="$1"
	s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
	printf '"%s"' "$s"
}

entry_json() { # entry_json CLIENT URL TOKEN → the server object for that client
	local client="$1" url; url="$(json_quote "$2")"
	local auth; auth="$(json_quote "Bearer $3")"
	case "$client" in
		claude-code|vscode) printf '{"type":"http","url":%s,"headers":{"Authorization":%s}}' "$url" "$auth" ;;
		cursor)             printf '{"url":%s,"headers":{"Authorization":%s}}' "$url" "$auth" ;;
		windsurf)           printf '{"serverUrl":%s,"headers":{"Authorization":%s}}' "$url" "$auth" ;;
		gemini)             printf '{"httpUrl":%s,"headers":{"Authorization":%s}}' "$url" "$auth" ;;
		claude-desktop)
			# Claude Desktop launches local servers only; mcp-remote bridges to the HTTP one.
			# The header goes through an env var because the app splits arguments on spaces.
			printf '{"command":"npx","args":["-y","mcp-remote",%s,"--header","Authorization:${AUTH_HEADER}"],"env":{"AUTH_HEADER":%s}}' "$url" "$auth" ;;
	esac
}

# --- Codex (TOML) -----------------------------------------------------------------------------

toml_remove_block() { # drop [mcp_servers.NAME] and its keys; keep everything else
	local file="$1" name="$2"
	[ -s "$file" ] || return 1
	grep -q "^\[mcp_servers\.$name\]" "$file" || return 1
	backup "$file"
	local tmp; tmp="$(mktemp)"
	awk -v hdr="[mcp_servers.$name]" '
		$0 == hdr { skipping = 1; next }
		/^[[:space:]]*\[/ { skipping = 0 }
		!skipping { print }
	' "$file" >"$tmp"
	# Collapse the blank line the block left behind, if any.
	sed -i.tmp -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" 2>/dev/null && rm -f "$tmp.tmp"
	mv "$tmp" "$file"
}

toml_set_block() {
	local file="$1" name="$2" url="$3" token="$4"
	toml_remove_block "$file" "$name" || backup "$file"
	mkdir -p "$(dirname "$file")"
	{
		[ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && printf '\n'
		[ -s "$file" ] && printf '\n'
		printf '[mcp_servers.%s]\n' "$name"
		printf 'url = "%s"\n' "$url"
		printf 'http_headers = { Authorization = "Bearer %s" }\n' "$token"
	} >>"$file"
	chmod 600 "$file" 2>/dev/null || true
}

# --- Connection test --------------------------------------------------------------------------

test_connection() { # test_connection URL TOKEN → 0 if RootCause answered the handshake
	local url="$1" token="$2"
	have curl || { warn "curl is not installed, skipping the connection test."; return 2; }
	local body code
	body="$(mktemp)"
	code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 -X POST "$url" \
		-H "Authorization: Bearer $token" \
		-H 'Content-Type: application/json' \
		-H 'Accept: application/json, text/event-stream' \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rootcause-mcp.sh","version":"'"$VERSION"'"}}}' \
		2>"$body.err")" || code=000
	local result=1
	case "$code" in
		200)
			if grep -q '"serverInfo"' "$body"; then
				ok "RootCause answered at $url and accepted the token."
				result=0
			else
				warn "Something answered at $url, but not an MCP server. Is the address right?"
				hint "$(head -c 300 "$body" | tr '\n' ' ')"
			fi ;;
		401|403) warn "RootCause rejected the token (HTTP $code). Is it pasted completely, and not revoked or expired?" ;;
		404)     warn "Nothing at $url (HTTP 404). The address usually ends in /mcp." ;;
		421)     warn "RootCause refused the Host header (HTTP 421). Use the exact hostname it is published on." ;;
		000)     warn "Could not reach $url."; hint "$(head -c 300 "$body.err" | tr '\n' ' ')" ;;
		*)       warn "Unexpected reply from $url (HTTP $code)."; hint "$(head -c 300 "$body" | tr '\n' ' ')" ;;
	esac
	rm -f "$body" "$body.err"
	return $result
}

# --- Inputs -----------------------------------------------------------------------------------

normalise_url() {
	local url="$1"
	url="${url%/}"
	case "$url" in
		http://*|https://*) ;;
		*) url="https://$url" ;;
	esac
	case "$url" in
		*/mcp) ;;
		*) url="$url/mcp" ;;
	esac
	printf '%s' "$url"
}

collect_url() {
	if [ -z "$URL" ]; then
		head_ "Where is RootCause?"
		hint "The MCP address your RootCause admin published, for example mcp.example.com. The /mcp path is added for you."
		ask URL "RootCause MCP address"
	fi
	[ -n "$URL" ] || fail "An address is needed."
	URL="$(normalise_url "$URL")"
}

collect_token() {
	if [ -z "$TOKEN" ]; then
		head_ "Your personal access token"
		hint "Generate one in RootCause under your profile → Personal access tokens. It starts with rc_pat_ and is shown once."
		hint "Nothing you type here is echoed."
		ask_secret TOKEN "Token"
	fi
	[ -n "$TOKEN" ] || fail "A token is needed."
	case "$TOKEN" in
		rc_pat_*) ;;
		*) warn "RootCause tokens start with rc_pat_. Continuing anyway, but check it if the test fails." ;;
	esac
}

collect_client() {
	[ -n "$CLIENT" ] && { client_label "$CLIENT" >/dev/null || fail "Unknown client '$CLIENT'. One of: claude-code claude-desktop cursor vscode windsurf codex gemini other"; return; }
	choose CLIENT "Which agent do you use?" \
		"claude-code|Claude Code|terminal, or its VS Code / JetBrains extension" \
		"claude-desktop|Claude Desktop|the Claude app on Mac or Windows" \
		"cursor|Cursor|" \
		"vscode|VS Code with GitHub Copilot|agent mode" \
		"windsurf|Windsurf|" \
		"codex|OpenAI Codex CLI|" \
		"gemini|Gemini CLI|" \
		"other|Something else|your own agent, the Claude API, or a client not listed"
}

collect_scope() {
	client_supports_project_scope "$CLIENT" || { SCOPE=user; return; }
	[ -n "$SCOPE" ] && return
	[ -n "$TTY_IN" ] || { SCOPE=user; return; }
	choose SCOPE "Connect for" \
		"user|Everywhere I use $(client_label "$CLIENT")|recommended; stored in your home folder" \
		"project|Only this folder|$PWD — stored in a project config file; mind not to commit the token"
}

# --- Actions ----------------------------------------------------------------------------------

do_connect() {
	collect_client
	if [ "$CLIENT" = other ]; then do_other; return; fi
	collect_scope
	collect_url
	collect_token

	if [ "$SKIP_TEST" != 1 ]; then
		head_ "Checking the connection"
		if ! test_connection "$URL" "$TOKEN"; then
			confirm "Save the connection anyway?" N || fail "Nothing changed."
		fi
	fi

	local file; file="$(config_path "$CLIENT" "$SCOPE")"
	head_ "Connecting $(client_label "$CLIENT")"

	case "$CLIENT" in
		claude-code)
			# The CLI is the front door and keeps its own bookkeeping, so prefer it. If it is
			# absent or unhappy, the files it reads are plain JSON and we write them ourselves.
			local via_cli=1 err
			if have claude; then
				err="$(mktemp)"
				claude mcp remove --scope "$SCOPE" "$NAME" >/dev/null 2>&1 || true
				if claude mcp add --transport http --scope "$SCOPE" "$NAME" "$URL" --header "Authorization: Bearer $TOKEN" >/dev/null 2>"$err"; then
					via_cli=0
					ok "Registered with the claude CLI (scope: $SCOPE)."
				else
					warn "The claude CLI could not register it: $(head -c 200 "$err" | tr '\n' ' ')"
					hint "Editing its config file directly instead."
				fi
				rm -f "$err"
			fi
			if [ $via_cli -ne 0 ]; then
				[ -n "$JSON_TOOL" ] || { manual_snippet "$file"; return; }
				json_set "$file" "$(container_key "$CLIENT")" "$NAME" "$(entry_json "$CLIENT" "$URL" "$TOKEN")"
				ok "Written to $file"
			fi ;;
		codex)
			toml_set_block "$file" "$NAME" "$URL" "$TOKEN"
			ok "Written to $file" ;;
		claude-desktop)
			have npx || warn "Node.js (npx) was not found. Claude Desktop needs it to run the mcp-remote bridge: https://nodejs.org"
			[ -n "$JSON_TOOL" ] || { manual_snippet "$file"; return; }
			json_set "$file" "$(container_key "$CLIENT")" "$NAME" "$(entry_json "$CLIENT" "$URL" "$TOKEN")"
			ok "Written to $file" ;;
		*)
			[ -n "$JSON_TOOL" ] || { manual_snippet "$file"; return; }
			json_set "$file" "$(container_key "$CLIENT")" "$NAME" "$(entry_json "$CLIENT" "$URL" "$TOKEN")"
			ok "Written to $file" ;;
	esac

	[ "$SCOPE" = project ] && warn "That file holds your token. Add it to .gitignore before you commit."
	usage_hints "$CLIENT"
}

manual_snippet() {
	local file="$1"
	warn "Neither python3 nor jq is installed, so the config was not edited automatically."
	say  "Add this to $file under \"$(container_key "$CLIENT")\":"
	say
	printf '  "%s": %s\n' "$NAME" "$(entry_json "$CLIENT" "$URL" "$TOKEN")"
	say
	usage_hints "$CLIENT"
}

do_other() {
	collect_url
	collect_token
	[ "$SKIP_TEST" = 1 ] || { head_ "Checking the connection"; test_connection "$URL" "$TOKEN" || true; }
	head_ "Connection details"
	say "  Transport   Streamable HTTP (MCP)"
	say "  Address     $URL"
	say "  Header      Authorization: Bearer $(mask "$TOKEN")"
	say
	say "${BOLD}Most clients that take a JSON config accept this:${RESET}"
	cat <<-EOF

	  {
	    "mcpServers": {
	      "$NAME": {
	        "type": "http",
	        "url": "$URL",
	        "headers": { "Authorization": "Bearer <your token>" }
	      }
	    }
	  }

	EOF
	say "${BOLD}An agent you build on the Claude API${RESET} (the MCP connector needs both parts):"
	cat <<-EOF

	  client.beta.messages.create(
	      model="claude-opus-5",
	      max_tokens=16000,
	      betas=["mcp-client-2025-11-20"],
	      mcp_servers=[{"type": "url", "url": "$URL",
	                    "name": "$NAME", "authorization_token": "<your token>"}],
	      tools=[{"type": "mcp_toolset", "mcp_server_name": "$NAME"}],
	      messages=[{"role": "user", "content": "What slipped in project ABC this week?"}],
	  )

	EOF
	say "${BOLD}Claude Agent SDK${RESET}: pass the same shape under the mcpServers option, type \"http\"."
	say
	say "${BOLD}Check it from any shell:${RESET}"
	say "  bash rootcause-mcp.sh --test --url $URL --token <your token>"
	say
	hint "Once connected, your agent should call whoami first; the server's own instructions tell it so."
}

do_remove() {
	collect_client
	[ "$CLIENT" = other ] && { say "Nothing to remove for a hand-configured agent; delete the \"$NAME\" entry from its config."; return; }
	collect_scope
	local file; file="$(config_path "$CLIENT" "$SCOPE")"
	head_ "Disconnecting $(client_label "$CLIENT")"
	local removed=1
	case "$CLIENT" in
		claude-code)
			if have claude && claude mcp remove --scope "$SCOPE" "$NAME" >/dev/null 2>&1; then removed=0; fi
			if json_remove "$file" "$(container_key "$CLIENT")" "$NAME"; then removed=0; fi ;;
		codex)
			toml_remove_block "$file" "$NAME" && removed=0 ;;
		*)
			json_remove "$file" "$(container_key "$CLIENT")" "$NAME" && removed=0 ;;
	esac
	if [ $removed -eq 0 ]; then
		ok "RootCause removed from $(client_label "$CLIENT"). Restart it to forget the connection."
		hint "The token itself still works. Revoke it in RootCause under your profile if you no longer need it."
	else
		warn "RootCause was not connected to $(client_label "$CLIENT") (looked in $file)."
	fi
}

do_show() {
	head_ "Where RootCause is connected"
	local found=0 client scope file
	for client in claude-code cursor vscode claude-desktop windsurf codex gemini; do
		for scope in user project; do
			[ "$scope" = project ] && ! client_supports_project_scope "$client" && continue
			file="$(config_path "$client" "$scope")"
			[ -s "$file" ] || continue
			if [ "$client" = codex ]; then
				grep -q "^\[mcp_servers\.$NAME\]" "$file" || continue
				printf '  %s%-28s%s %s\n' "$GREEN" "$(client_label "$client")" "$RESET" "$file"
				hint "$(grep -A1 "^\[mcp_servers\.$NAME\]" "$file" | grep '^url' | sed -e 's/^url = //' -e 's/"//g')"
			else
				json_has "$file" "$(container_key "$client")" "$NAME" || continue
				printf '  %s%-28s%s %s\n' "$GREEN" "$(client_label "$client") ($scope)" "$RESET" "$file"
				hint "$(json_url_of "$file" "$(container_key "$client")" "$NAME")"
			fi
			found=1
		done
	done
	[ $found -eq 1 ] || say "  Not connected anywhere this script knows about."
	say
	hint "Tokens are never shown. Re-run without --show to update one, or --remove to disconnect."
}

do_test() {
	collect_url
	collect_token
	head_ "Checking the connection"
	test_connection "$URL" "$TOKEN"
}

# --- Per-client usage hints -------------------------------------------------------------------

usage_hints() {
	head_ "How to use it in $(client_label "$1")"
	case "$1" in
		claude-code)
			say "  1. Start (or restart) claude in any folder."
			say "  2. Type /mcp — $NAME should be listed as connected."
			say "  3. Try:  ${CYAN}who am I in rootcause, and which projects can I see?${RESET}"
			say "     then: ${CYAN}show me what has slipped in <PROJECT> this week${RESET}" ;;
		claude-desktop)
			say "  1. Quit Claude Desktop completely (not just the window) and open it again."
			say "  2. In a new chat, open the tools menu (the sliders icon) — $NAME is listed there."
			say "  3. Try:  ${CYAN}who am I in rootcause?${RESET}"
			hint "First launch downloads mcp-remote, so the first reply can take a few seconds." ;;
		cursor)
			say "  1. Open Cursor Settings → MCP (or restart Cursor). $NAME shows with a green dot."
			say "  2. In the chat panel, use Agent mode."
			say "  3. Try:  ${CYAN}who am I in rootcause, and what is assigned to me?${RESET}" ;;
		vscode)
			say "  1. Command Palette → ${CYAN}MCP: List Servers${RESET} → $NAME → Start."
			say "  2. Open Copilot Chat and switch to Agent mode."
			say "  3. Try:  ${CYAN}who am I in rootcause?${RESET}"
			hint "VS Code may ask you to trust the server the first time. Say yes." ;;
		windsurf)
			say "  1. Restart Windsurf, or refresh under Settings → Cascade → MCP."
			say "  2. In Cascade, try:  ${CYAN}who am I in rootcause?${RESET}" ;;
		codex)
			say "  1. Start (or restart) codex."
			say "  2. Type /mcp to see $NAME and its tools."
			say "  3. Try:  ${CYAN}who am I in rootcause?${RESET}" ;;
		gemini)
			say "  1. Start (or restart) gemini."
			say "  2. Type /mcp to see $NAME and its tools."
			say "  3. Try:  ${CYAN}who am I in rootcause?${RESET}" ;;
	esac
	say
	hint "Your agent acts as you, with exactly your permissions. Everything it changes is marked as agent activity."
	hint "Change of token or address? Run this script again. To disconnect: bash rootcause-mcp.sh --remove"
}

# --- Entry ------------------------------------------------------------------------------------

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

ACTION=connect
CLIENT=''; SCOPE=''; URL=''; TOKEN=''; NAME="$DEFAULT_NAME"; SKIP_TEST=0

while [ $# -gt 0 ]; do
	case "$1" in
		--client)  CLIENT="$2"; shift 2 ;;
		--scope)   SCOPE="$2"; shift 2 ;;
		--url)     URL="$2"; shift 2 ;;
		--token)   TOKEN="$2"; shift 2 ;;
		--name)    NAME="$2"; shift 2 ;;
		--remove)  ACTION=remove; shift ;;
		--show)    ACTION=show; shift ;;
		--test)    ACTION=test; shift ;;
		--no-test) SKIP_TEST=1; shift ;;
		--version) echo "rootcause-mcp.sh $VERSION"; exit 0 ;;
		-h|--help) usage; exit 0 ;;
		*) fail "Unknown option: $1 (try --help)" ;;
	esac
done

[ -z "$SCOPE" ] || [ "$SCOPE" = user ] || [ "$SCOPE" = project ] || fail "--scope must be user or project"

printf '%sRootCause%s · connect your AI agent over MCP %s(v%s)%s\n' "$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET"

if [ "$ACTION" = connect ] && [ -z "$CLIENT" ] && [ -n "$TTY_IN" ]; then
	choose ACTION "What would you like to do?" \
		"connect|Connect an agent|or update a connection you already have" \
		"show|Show what is connected|" \
		"test|Test an address and token|changes nothing" \
		"remove|Disconnect an agent|" \
		"quit|Quit|"
fi

case "$ACTION" in
	connect) do_connect ;;
	remove)  do_remove ;;
	show)    do_show ;;
	test)    do_test ;;
	quit)    exit 0 ;;
esac
