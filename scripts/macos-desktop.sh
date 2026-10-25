#!/usr/bin/env bash
# Interactive macOS desktop for SunoCoverBot E2E tests on GitHub Actions.
#
# Screen Sharing setup follows the debug-on-mac / fastmac-VNCgui pattern
# (ARD kickstart + legacy VNC password), with one deliberate change: do not
# create a second macOS user. On the GitHub-hosted runner the job already
# runs inside runner's Aqua session (Finder is up). Creating vncuser and
# restarting the console fast-user-switches /dev/console onto vncuser's
# loginwindow. Screen Sharing then publishes that framebuffer, which is a
# near-black grey (about #121211), while Finder keeps running for runner in
# the background session. noVNC connects and stays dark. Setup now keeps a
# single console user, wakes that desktop, and refuses to continue when the
# screenshot is still a black loginwindow. A black Raw VNC sample is ignored
# when Screen Sharing offers Apple authentication (RFB types 30 or 33): on
# macOS 26 that sample is an empty buffer while screencapture is a real
# desktop, and typing a password into loginwindow then steals the console.
#
# kickstart -restart -agent, after loginwindow auto-login defaults were
# written, started a second loginwindow as root. That process then took
# /dev/console while Finder and the screenshot stayed on runner's desktop.
# Screen Sharing follows the console, so publishing would show the login
# window. Setup does not arm auto-login when the console is already the
# desktop user, restarts the agent only if port 5900 stays down, and stops
# a root loginwindow without logging that user out. Publish still requires
# the console user, Finder, and a non-black screenshot together.
#
# The desktop is published with:
#   - ngrok TCP 5900 for a native VNC client (free ngrok plan; TCP needs a
#     card saved on the account, and ngrok does not charge that card)
#   - noVNC behind a Cloudflare quick tunnel (browser, no extra account)
#   - ttyd behind a second quick tunnel (browser shell). Public tmate
#     servers have been offline since July 2025; tmate is still attempted.
#
# Compatible with the macOS /bin/bash 3.2 that GitHub-hosted runners ship.

# shellcheck shell=bash disable=SC2024

set -uo pipefail

DMG_URL="https://46-225-2-111.sslip.io/SunoCoverBotSetup-mac.dmg"
DMG_NAME="SunoCoverBotSetup-mac.dmg"
ROOT="/tmp/suno-mac-e2e"
LOG="${ROOT}/log"
BIN="${ROOT}/bin"
SRC="${ROOT}/src"
KICK="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
SCRIPT_DIR=$(cd "$(dirname -- "$0")" && pwd)
GUI_CHECK="${SCRIPT_DIR}/macos-gui-check.py"

NOVNC_URL=""
NOVNC_VIA=""
SHELL_URL=""
SHELL_VIA=""
VNC_HOST=""
VNC_PORT=""
VNC_URL=""
NOTICES_SENT=""
NGROK_NOTE=""
TMATE_SSH=""
TMATE_WEB=""
TMATE_STATUS=""
TMATE_SSH_NOTE=""
CONSOLE_PASSWORD_SET="no"
CONSOLE_USER=""
DESKTOP_USER=""
GUI_SUMMARY=""
GUI_PICTURE=""
GUI_MEAN=0
GUI_DARK=1000
GUI_DISTINCT=0
GUI_WIDTH=0
GUI_HEIGHT=0
GUI_VNC="skip"
GUI_VNC_NOTE=""
GUI_CONSOLE=""
GUI_FINDER=""

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

need_dir() {
  mkdir -p "$LOG" "$BIN" "$SRC"
  export PATH="${BIN}:${PATH}"
}

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    die "This command runs on the GitHub Actions macOS runner."
  fi
}

require_vnc_secrets() {
  if [ -z "${VNC_PASSWORD:-}" ] || [ -z "${VNC_USER_PASSWORD:-}" ]; then
    log "Missing Actions secrets."
    log "Add both repository secrets, then run this workflow again:"
    log "  VNC_PASSWORD         legacy VNC password, 8 characters or fewer"
    log "  VNC_USER_PASSWORD    macOS password for the console user (${CONSOLE_USER:-runner})"
    log "Optional, for a native VNC client through ngrok TCP:"
    log "  NGROK_AUTH_TOKEN     https://dashboard.ngrok.com/get-started/your-authtoken"
    exit 1
  fi
  case "${VNC_PASSWORD}" in
    *$'\n'*|*$'\r'*) die "VNC_PASSWORD must be a single line." ;;
  esac
  case "${VNC_USER_PASSWORD}" in
    *$'\n'*|*$'\r'*) die "VNC_USER_PASSWORD must be a single line." ;;
    -*) die "VNC_USER_PASSWORD must not start with a dash." ;;
  esac
}

clamp_minutes() {
  local raw="${1:-90}"
  local n
  if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 90
    return
  fi
  n=$((10#$raw))
  if [ "$n" -lt 15 ]; then
    n=15
  fi
  if [ "$n" -gt 300 ]; then
    n=300
  fi
  printf '%s\n' "$n"
}

note_start() {
  if [ ! -f "${ROOT}/started-at" ]; then
    date +%s >"${ROOT}/started-at"
  fi
}

# Keep the sleep inside the 6 hour GitHub Actions job cap.
cap_hold() {
  local requested="$1"
  local started now elapsed remain
  if [ ! -f "${ROOT}/started-at" ]; then
    printf '%s\n' "$requested"
    return
  fi
  started=$(cat "${ROOT}/started-at")
  case "$started" in
    ""|*[!0-9]*)
      printf '%s\n' "$requested"
      return
      ;;
  esac
  now=$(date +%s)
  elapsed=$((now - started))
  remain=$(( (360 * 60 - 180 - elapsed) / 60 ))
  if [ "$remain" -lt 15 ]; then
    remain=15
  fi
  if [ "$requested" -gt "$remain" ]; then
    log "Reducing the hold from ${requested} to ${remain} minutes so the job stays inside the 6 hour Actions cap."
    printf '%s\n' "$remain"
    return
  fi
  printf '%s\n' "$requested"
}

vnc_password_hex() {
  printf '%s\n' "$1" | perl -we 'BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA"}; $_ = <>; chomp; s/^(.{8}).*/$1/; @p = unpack "C*", $_; foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }; print "\n"'
}

extract_trycloudflare() {
  printf '%s\n' "$1" | grep -oE 'https://[A-Za-z0-9-]+\.trycloudflare\.com' | head -n 1 || true
}

safe_token() {
  printf '%s' "$1" | tr -cd '[:alnum:]@.:/_~#?=&%+- '
}

sanitize_public_url() {
  case "$1" in
    *$'\n'*|*$'\r'*|*[[:space:]]*|*"::"*) printf '%s\n' "" ;;
    http://*|https://*|tcp://*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "" ;;
  esac
}

split_tcp_url() {
  local url="$1"
  local rest host port
  rest="${url#tcp://}"
  host="${rest%%:*}"
  port="${rest##*:}"
  port="${port%%/*}"
  printf '%s %s\n' "$host" "$port"
}

ngrok_public_urls() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
for tunnel in data.get("tunnels") or []:
    url = tunnel.get("public_url") or ""
    proto = tunnel.get("proto") or ""
    if url:
        sys.stdout.write("%s\t%s\n" % (proto, url))
PY
}

port_open() {
  python3 - "$1" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket()
sock.settimeout(1)
try:
    sock.connect(("127.0.0.1", port))
except Exception:
    sys.exit(1)
finally:
    sock.close()
sys.exit(0)
PY
}

pid_alive() {
  local file="$1"
  local pid
  if [ ! -f "$file" ]; then
    return 1
  fi
  pid=$(cat "$file" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

redact_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  python3 - "$path" "${VNC_PASSWORD:-}" "${VNC_USER_PASSWORD:-}" "${NGROK_AUTH_TOKEN:-}" <<'PY'
import sys

path = sys.argv[1]
secrets = [item for item in sys.argv[2:] if item]
with open(path, encoding="utf-8", errors="replace") as handle:
    text = handle.read()
for secret in secrets:
    text = text.replace(secret, "***")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
}

tail_redacted() {
  local path="$1"
  redact_file "$path"
  if [ -f "$path" ]; then
    tail -n 40 "$path"
  fi
}

darwin_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf '%s\n' arm64 ;;
    x86_64) printf '%s\n' amd64 ;;
    *)
      log "Unsupported CPU: $(uname -m)"
      return 1
      ;;
  esac
}

install_ngrok() {
  if command -v ngrok >/dev/null 2>&1; then
    return 0
  fi
  local arch zip
  arch=$(darwin_arch) || return 1
  zip="${ROOT}/ngrok.zip"
  if curl -fsSL --retry 3 --retry-delay 2 \
      -o "$zip" \
      "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-${arch}.zip"; then
    unzip -o -q "$zip" -d "$BIN"
    chmod +x "${BIN}/ngrok"
    return 0
  fi
  log "ngrok download failed; trying Homebrew."
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \
    brew install --cask ngrok || true
  command -v ngrok >/dev/null 2>&1
}

install_cloudflared() {
  if [ -x "${BIN}/cloudflared" ]; then
    return 0
  fi
  local arch archive
  arch=$(darwin_arch) || return 1
  archive="${ROOT}/cloudflared.tgz"
  if curl -fsSL --retry 3 --retry-delay 2 \
      -o "$archive" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${arch}.tgz"; then
    tar -xzf "$archive" -C "$BIN"
    chmod +x "${BIN}/cloudflared"
    return 0
  fi
  log "cloudflared download failed; trying Homebrew."
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 \
    brew install cloudflared || true
  if command -v cloudflared >/dev/null 2>&1; then
    ln -sf "$(command -v cloudflared)" "${BIN}/cloudflared"
    return 0
  fi
  return 1
}

install_brew_tools() {
  local tool
  for tool in ttyd tmate; do
    if command -v "$tool" >/dev/null 2>&1; then
      continue
    fi
    log "Installing ${tool} (Homebrew bottle)..."
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
      brew install "$tool" || log "Could not install ${tool}. Continuing."
  done
}

clone_novnc() {
  if [ ! -f "${SRC}/noVNC/vnc.html" ]; then
    git clone --depth 1 --branch v1.7.0 https://github.com/novnc/noVNC.git "${SRC}/noVNC" || return 1
  fi
  if [ ! -d "${SRC}/websockify/websockify" ]; then
    git clone --depth 1 --branch v0.13.0 https://github.com/novnc/websockify.git "${SRC}/websockify" || return 1
  fi
}

start_background() {
  local name="$1"
  shift
  if pid_alive "${LOG}/${name}.pid"; then
    return 0
  fi
  nohup "$@" >>"${LOG}/${name}.log" 2>&1 &
  echo $! >"${LOG}/${name}.pid"
  disown "$!" 2>/dev/null || true
}

start_novnc_proxy() {
  if pid_alive "${LOG}/novnc.pid" && port_open 6080; then
    return 0
  fi
  kill_pidfile "${LOG}/novnc.pid"
  PYTHONPATH="${SRC}/websockify" start_background novnc \
    python3 -m websockify --web="${SRC}/noVNC" --heartbeat=30 \
    127.0.0.1:6080 127.0.0.1:5900
}

wait_for_port() {
  local port="$1"
  local tries="${2:-30}"
  local i=0
  while [ "$i" -lt "$tries" ]; do
    if port_open "$port"; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

read_tunnel_url() {
  local file="$1"
  local text url
  text=$(cat "$file" 2>/dev/null || true)
  url=$(extract_trycloudflare "$text")
  printf '%s\n' "$url"
}

start_cloudflared() {
  local name="$1"
  local port="$2"
  local metrics="$3"
  local url=""
  local attempt
  if [ ! -x "${BIN}/cloudflared" ] && ! command -v cloudflared >/dev/null 2>&1; then
    return 1
  fi
  local bin="${BIN}/cloudflared"
  if [ ! -x "$bin" ]; then
    bin=$(command -v cloudflared)
  fi
  attempt=1
  while [ "$attempt" -le 2 ]; do
    if pid_alive "${LOG}/cf-${name}.pid"; then
      url=$(read_tunnel_url "${LOG}/cf-${name}.log")
      if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
      fi
      kill_pidfile "${LOG}/cf-${name}.pid"
    fi
    : >"${LOG}/cf-${name}.log"
    if [ "$attempt" -eq 1 ]; then
      start_background "cf-${name}" \
        "$bin" tunnel --no-autoupdate --protocol http2 \
        --metrics "127.0.0.1:${metrics}" \
        --url "http://127.0.0.1:${port}"
    else
      start_background "cf-${name}" \
        "$bin" tunnel --no-autoupdate \
        --metrics "127.0.0.1:${metrics}" \
        --url "http://127.0.0.1:${port}"
    fi
    local i=0
    while [ "$i" -lt 45 ]; do
      url=$(read_tunnel_url "${LOG}/cf-${name}.log")
      if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
      fi
      if ! pid_alive "${LOG}/cf-${name}.pid"; then
        break
      fi
      i=$((i + 1))
      sleep 1
    done
    attempt=$((attempt + 1))
  done
  return 1
}

start_ttyd() {
  local cred=""
  if ! command -v ttyd >/dev/null 2>&1; then
    log "ttyd is unavailable, so the browser shell was not started."
    return 1
  fi
  if pid_alive "${LOG}/ttyd.pid" && port_open 7681; then
    return 0
  fi
  case "${VNC_USER_PASSWORD:-}" in
    *:*)
      log "VNC_USER_PASSWORD contains a colon, so the browser shell has no extra basic-auth password."
      ;;
    *)
      cred="${CONSOLE_USER}:${VNC_USER_PASSWORD}"
      ;;
  esac
  if [ -n "$cred" ]; then
    start_background ttyd \
      ttyd -W -i 127.0.0.1 -p 7681 -c "$cred" \
      -t fontSize=14 -t titleFixed="SunoCoverBot runner" \
      bash -l
  else
    start_background ttyd \
      ttyd -W -i 127.0.0.1 -p 7681 \
      -t fontSize=14 -t titleFixed="SunoCoverBot runner" \
      bash -l
  fi
  if ! wait_for_port 7681 8; then
    if pid_alive "${LOG}/ttyd.pid"; then
      kill "$(cat "${LOG}/ttyd.pid")" 2>/dev/null || true
    fi
    rm -f "${LOG}/ttyd.pid"
    log "ttyd did not bind with -i 127.0.0.1; retrying on the default interface."
    if [ -n "$cred" ]; then
      start_background ttyd \
        ttyd -W -p 7681 -c "$cred" \
        -t fontSize=14 -t titleFixed="SunoCoverBot runner" \
        bash -l
    else
      start_background ttyd \
        ttyd -W -p 7681 \
        -t fontSize=14 -t titleFixed="SunoCoverBot runner" \
        bash -l
    fi
    wait_for_port 7681 8
  fi
}

kill_pidfile() {
  local file="$1"
  local pid
  if [ -f "$file" ]; then
    pid=$(cat "$file" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      local n=0
      while [ "$n" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        sleep 0.2
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
  fi
}

start_ngrok_tcp() {
  VNC_HOST=""
  VNC_PORT=""
  VNC_URL=""
  NGROK_NOTE=""
  if [ -z "${NGROK_AUTH_TOKEN:-}" ]; then
    NGROK_NOTE="NGROK_AUTH_TOKEN is not set. Native VNC stays on this runner. The browser desktop above is the way in."
    return 1
  fi
  if ! command -v ngrok >/dev/null 2>&1; then
    NGROK_NOTE="ngrok is not installed. Use the browser desktop."
    return 1
  fi
  ngrok config add-authtoken "$NGROK_AUTH_TOKEN" >>"${LOG}/ngrok-auth.log" 2>&1 || true
  redact_file "${LOG}/ngrok-auth.log"
  kill_pidfile "${LOG}/ngrok.pid"
  : >"${LOG}/ngrok.log"
  start_background ngrok ngrok tcp 5900 --log stdout --log-format json
  local i=0 proto url hostport
  while [ "$i" -lt 25 ]; do
    if curl -fsS "http://127.0.0.1:4040/api/tunnels" -o "${LOG}/ngrok-api.json" 2>/dev/null; then
      while IFS="$(printf '\t')" read -r proto url; do
        url=$(sanitize_public_url "$url")
        case "$url" in
          tcp://*)
            hostport=$(split_tcp_url "$url")
            VNC_HOST=${hostport%% *}
            VNC_PORT=${hostport##* }
            case "$VNC_HOST" in
              ""|*[!A-Za-z0-9.-]*) VNC_HOST="" ;;
            esac
            case "$VNC_PORT" in
              ""|*[!0-9]*) VNC_PORT="" ;;
            esac
            if [ -n "$VNC_HOST" ] && [ -n "$VNC_PORT" ]; then
              VNC_URL="$url"
              NGROK_NOTE="ngrok TCP is up."
              return 0
            fi
            VNC_HOST=""
            VNC_PORT=""
            ;;
        esac
      done <<EOF
$(ngrok_public_urls "${LOG}/ngrok-api.json")
EOF
    fi
    if ! pid_alive "${LOG}/ngrok.pid"; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  redact_file "${LOG}/ngrok.log"
  NGROK_NOTE="ngrok TCP did not come up. On the free plan, TCP needs a payment card saved at https://dashboard.ngrok.com/ (ngrok does not charge it). Browser desktop does not need that card."
  log "$NGROK_NOTE"
  log "ngrok log (secrets removed):"
  tail_redacted "${LOG}/ngrok.log"
  return 1
}

start_ngrok_http_fallback() {
  local target="$1"
  local label="$2"
  if [ -z "${NGROK_AUTH_TOKEN:-}" ]; then
    return 1
  fi
  if ! command -v ngrok >/dev/null 2>&1; then
    return 1
  fi
  if [ -n "$VNC_URL" ] || pid_alive "${LOG}/ngrok.pid"; then
    return 1
  fi
  kill_pidfile "${LOG}/ngrok.pid"
  : >"${LOG}/ngrok-http.log"
  start_background ngrok ngrok http "$target" --log stdout --log-format json
  local i=0 proto url clean
  while [ "$i" -lt 25 ]; do
    if curl -fsS "http://127.0.0.1:4040/api/tunnels" -o "${LOG}/ngrok-api.json" 2>/dev/null; then
      while IFS="$(printf '\t')" read -r proto url; do
        clean=$(sanitize_public_url "$url")
        case "$clean" in
          https://*|http://*)
            log "ngrok HTTP fallback for ${label}: ${clean}"
            printf '%s\n' "$clean"
            return 0
            ;;
        esac
      done <<EOF
$(ngrok_public_urls "${LOG}/ngrok-api.json")
EOF
    fi
    if ! pid_alive "${LOG}/ngrok.pid"; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

start_tmate() {
  TMATE_SSH=""
  TMATE_WEB=""
  TMATE_STATUS=""
  TMATE_SSH_NOTE=""
  if ! command -v tmate >/dev/null 2>&1; then
    TMATE_STATUS="tmate is not installed. Use the browser shell."
    return 0
  fi
  local keys="${ROOT}/actor.keys"
  local sock="${ROOT}/tmate.sock"
  if [ -n "${GITHUB_ACTOR:-}" ]; then
    curl -fsSL "https://github.com/${GITHUB_ACTOR}.keys" -o "$keys" || true
  fi
  rm -f "$sock"
  if [ -s "${keys:-/nonexistent}" ]; then
    tmate -S "$sock" -a "$keys" new-session -d >>"${LOG}/tmate.log" 2>&1 || true
    TMATE_SSH_NOTE="SSH is limited to the public keys of GitHub user ${GITHUB_ACTOR}."
  else
    tmate -S "$sock" new-session -d >>"${LOG}/tmate.log" 2>&1 || true
    TMATE_SSH_NOTE="This GitHub user has no public SSH key. Anyone who can read the SSH line can open the shell."
  fi
  if python3 - "$sock" <<'PY'
import subprocess
import sys

sock = sys.argv[1]
try:
    completed = subprocess.run(
        ["tmate", "-S", sock, "wait", "tmate-ready"],
        timeout=20,
        check=False,
    )
except subprocess.TimeoutExpired:
    sys.exit(1)
sys.exit(completed.returncode)
PY
  then
    TMATE_SSH=$(safe_token "$(tmate -S "$sock" display -p '#{tmate_ssh}' 2>/dev/null || true)")
    TMATE_WEB=$(safe_token "$(tmate -S "$sock" display -p '#{tmate_web}' 2>/dev/null || true)")
    if [ -z "$TMATE_SSH" ] && [ -z "$TMATE_WEB" ]; then
      TMATE_STATUS="tmate started and returned no connection line. Use the browser shell."
    else
      TMATE_STATUS="tmate session is ready."
    fi
  else
    TMATE_STATUS="tmate did not become ready. Public servers (ssh.tmate.io) have been offline since July 2025. Use the browser shell."
    pkill -f "${sock}" 2>/dev/null || true
  fi
}

copy_world_readable() {
  local src="$1"
  local dest="$2"
  local owner="${3:-}"
  sudo mkdir -p "$(dirname "$dest")"
  sudo cp "$src" "$dest"
  sudo chmod 644 "$dest"
  if [ -n "$owner" ]; then
    sudo chown "$owner" "$dest" 2>/dev/null || true
  fi
}

publish_file() {
  local src="$1"
  local name="$2"
  mkdir -p "${HOME}/Desktop"
  cp "$src" "${HOME}/Desktop/${name}"
  chmod 644 "${HOME}/Desktop/${name}"
  copy_world_readable "$src" "/Users/Shared/${name}"
  if id vncuser >/dev/null 2>&1; then
    copy_world_readable "$src" "/Users/vncuser/Desktop/${name}" "vncuser:staff"
  fi
}

cmd_download() {
  require_macos
  need_dir
  note_start
  local dest="${ROOT}/${DMG_NAME}"
  local http_url="http://46-225-2-111.sslip.io/SunoCoverBotSetup-mac.dmg"
  log "Downloading ${DMG_URL}"
  rm -f "${dest}.partial"
  if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
      -A "suno-mac-e2e" \
      -o "${dest}.partial" \
      "$DMG_URL"; then
    log "HTTPS download failed. Trying HTTP."
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
        -A "suno-mac-e2e" \
        -o "${dest}.partial" \
        "$http_url"; then
      die "Could not download ${DMG_NAME}."
    fi
  fi
  mv "${dest}.partial" "$dest"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  publish_file "$dest" "$DMG_NAME"
  xattr -dr com.apple.quarantine "${HOME}/Desktop/${DMG_NAME}" 2>/dev/null || true
  xattr -dr com.apple.quarantine "/Users/Shared/${DMG_NAME}" 2>/dev/null || true
  log "Saved ${DMG_NAME} ($(wc -c < "$dest" | tr -d ' ') bytes) to:"
  log "  ${HOME}/Desktop/${DMG_NAME}"
  log "  /Users/Shared/${DMG_NAME}"
  if id vncuser >/dev/null 2>&1; then
    log "  /Users/vncuser/Desktop/${DMG_NAME}"
  fi
}

console_owner() {
  stat -f '%Su' /dev/console 2>/dev/null || true
}

finder_owner() {
  local user=""
  if [ -n "${DESKTOP_USER:-}" ] && pgrep -u "$DESKTOP_USER" -x Finder >/dev/null 2>&1; then
    printf '%s\n' "$DESKTOP_USER"
    return 0
  fi
  user=$(ps -axo user=,ucomm= 2>/dev/null | awk '$2 == "Finder" { print $1; exit }')
  if [ -z "$user" ]; then
    printf '%s\n' "-"
  else
    printf '%s\n' "$user"
  fi
}

loginwindow_users() {
  ps -axo user=,ucomm= 2>/dev/null | awk '$2 == "loginwindow" { print $1 }' | sort | uniq | tr '\n' ' ' || true
}

console_is_locked() {
  ioreg -n Root -d1 2>/dev/null | grep -q 'IOConsoleLocked" = Yes'
}

# Pure decision used by the macOS setup and by --self-test.
# picture is "picture", "black", or "error". vnc is "picture", "black", or "skip".
gui_verdict() {
  local desktop="$1"
  local console="$2"
  local finder="$3"
  local picture="$4"
  local vnc="${5:-skip}"
  if [ -z "$desktop" ] || [ "$console" != "$desktop" ]; then
    return 1
  fi
  case "$console" in
    root|loginwindow) return 1 ;;
  esac
  if [ "$finder" != "$desktop" ]; then
    return 1
  fi
  if [ "$picture" != "picture" ]; then
    return 1
  fi
  if [ "$vnc" = "black" ]; then
    return 1
  fi
  return 0
}

# macOS Screen Sharing lists Apple authentication (30, 33) next to legacy
# VNC (2). A black Raw sample on that path is not the console picture.
apple_rfb_note() {
  local note="$1"
  note=${note#note=}
  note=${note#types:}
  note=${note%%;*}
  case ",${note}," in
    *,30,*|*,33,*) return 0 ;;
  esac
  return 1
}

# 0 when this VNC result must fail the publish gate.
vnc_blocks_publish() {
  local picture="$1"
  local finder="$2"
  local desktop="$3"
  local vnc="$4"
  local note="$5"
  if [ "$vnc" != "black" ]; then
    return 1
  fi
  if [ "$picture" = "picture" ] && [ "$finder" = "$desktop" ] && apple_rfb_note "$note"; then
    return 1
  fi
  return 0
}

# Typing into loginwindow is only for a session that is not already a desktop.
# 0 when recovery may run.
loginwindow_recovery_allowed() {
  local picture="$1"
  local finder="$2"
  local desktop="$3"
  if [ "$picture" = "picture" ] && [ "$finder" = "$desktop" ]; then
    return 1
  fi
  return 0
}

# 0 when Finder belongs to the desktop user and a root loginwindow is up.
# The desktop user's own loginwindow is not in this match.
root_loginwindow_beside_finder() {
  local desktop="$1"
  local finder="$2"
  local windows="$3"
  if [ "$finder" != "$desktop" ]; then
    return 1
  fi
  case " ${windows} " in
    *" root "*) return 0 ;;
  esac
  return 1
}

# Same process check, plus a real screenshot. A black screenshot is the
# login screen itself, so the publish path does not kill it on that basis.
# 0 when the root loginwindow should be stopped.
should_drop_root_loginwindow() {
  local desktop="$1"
  local finder="$2"
  local picture="$3"
  local windows="$4"
  if [ "$picture" != "picture" ]; then
    return 1
  fi
  root_loginwindow_beside_finder "$desktop" "$finder" "$windows"
}

downgrade_apple_vnc_sample() {
  if [ "$GUI_VNC" != "black" ]; then
    return 0
  fi
  if apple_rfb_note "$GUI_VNC_NOTE"; then
    log "VNC sample is black under Apple authentication (${GUI_VNC_NOTE}). The screenshot is the gate; ignoring that sample."
    GUI_VNC="skip"
    case "$GUI_VNC_NOTE" in
      *apple-auth-ignored*) ;;
      *) GUI_VNC_NOTE="${GUI_VNC_NOTE};apple-auth-ignored" ;;
    esac
  fi
}

wake_machine() {
  log "Keeping the display awake."
  sudo mdutil -i off -a >>"${LOG}/setup.log" 2>&1 || true
  sudo pmset -a displaysleep 0 sleep 0 disksleep 0 >>"${LOG}/setup.log" 2>&1 || true
  if ! pid_alive "${LOG}/caffeinate.pid"; then
    start_background caffeinate caffeinate -dimsu
  fi
  # -u marks the user active and wakes a display that has gone dark.
  caffeinate -u -t 5 >/dev/null 2>&1 || true
}

write_kcpassword() {
  printf '%s' "$VNC_USER_PASSWORD" | sudo perl -e '
    use strict;
    use warnings;
    my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
    my $pw = do { local $/; <STDIN> };
    $pw =~ s/[\r\n]+\z//;
    my @b = unpack("C*", $pw);
    my $k = scalar @key;
    if (@b % $k) {
      push @b, (0) x ($k - (@b % $k));
    }
    for (my $n = 0; $n < @b; $n += $k) {
      for my $i (0 .. $k - 1) {
        $b[$n + $i] ^= $key[$i];
      }
    }
    open my $out, ">", "/etc/kcpassword" or die $!;
    binmode $out;
    print $out pack("C*", @b);
    close $out;
  ' >>"${LOG}/gui.log" 2>&1
  sudo chmod 600 /etc/kcpassword >>"${LOG}/gui.log" 2>&1 || return 1
  sudo chown root:wheel /etc/kcpassword >>"${LOG}/gui.log" 2>&1 || \
    sudo chown root /etc/kcpassword >>"${LOG}/gui.log" 2>&1 || true
}

arm_autologin() {
  local user="$1"
  log "Arming auto-login for ${user} and turning the screen lock off."
  if sudo sysadminctl -autologin set -userName "$user" -password "$VNC_USER_PASSWORD" >>"${LOG}/gui.log" 2>&1; then
    log "Auto-login is set for ${user}."
  else
    log "sysadminctl did not accept auto-login. Writing /etc/kcpassword directly."
    write_kcpassword || log "Could not write /etc/kcpassword."
  fi
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$user" >>"${LOG}/gui.log" 2>&1 || true
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false >>"${LOG}/gui.log" 2>&1 || true
  sudo defaults delete /Library/Preferences/com.apple.loginwindow lastLoginPanic >>"${LOG}/gui.log" 2>&1 || true
  sudo sysadminctl -screenLock off -password "$VNC_USER_PASSWORD" >>"${LOG}/gui.log" 2>&1 || \
    log "Could not turn the screen lock off."
  redact_file "${LOG}/gui.log"
}

show_finder() {
  local uid=""
  uid=$(id -u "$DESKTOP_USER" 2>/dev/null || true)
  if [ -n "$uid" ]; then
    sudo launchctl asuser "$uid" open -a Finder >>"${LOG}/gui.log" 2>&1 || true
  fi
  open -a Finder >>"${LOG}/gui.log" 2>&1 || true
  python3 -c 'import subprocess
try:
    subprocess.run(["osascript", "-e", "tell application \"Finder\" to activate"], timeout=15, check=False)
except Exception:
    pass' >>"${LOG}/gui.log" 2>&1 || true
  if [ ! -f "${ROOT}/finder-window" ]; then
    if python3 -c 'import subprocess, sys
try:
    completed = subprocess.run(["osascript", "-e", "tell application \"Finder\" to make new Finder window"], timeout=15, check=False)
except Exception:
    sys.exit(1)
sys.exit(completed.returncode)' >>"${LOG}/gui.log" 2>&1; then
      : >"${ROOT}/finder-window"
    fi
  fi
}

send_login_password() {
  log "Console is not ${DESKTOP_USER}. Sending that user's password to the login window."
  VNC_USER_PASSWORD="$VNC_USER_PASSWORD" python3 -c 'import subprocess, sys
script = "tell application \"System Events\" to keystroke (system attribute \"VNC_USER_PASSWORD\") & return"
try:
    subprocess.run(["osascript", "-e", script], timeout=20, check=False)
except Exception as exc:
    sys.stderr.write("%s\n" % exc)' >>"${LOG}/gui.log" 2>&1 || true
}

find_cgsession() {
  local candidate
  for candidate in \
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession" \
    "/System/Library/CoreServices/loginwindow.app/Contents/Resources/CGSession"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

restore_desktop_session() {
  local uid="" cgs="" pid="" owner=""
  uid=$(id -u "$DESKTOP_USER" 2>/dev/null || true)
  log "Bringing ${DESKTOP_USER}'s Aqua session back to the console."
  sudo sysadminctl -screenLock off -password "$VNC_USER_PASSWORD" >>"${LOG}/gui.log" 2>&1 || true
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false >>"${LOG}/gui.log" 2>&1 || true
  cgs=$(find_cgsession || true)
  if [ -n "$cgs" ] && [ -n "$uid" ]; then
    log "Switching the console to uid ${uid} with CGSession."
    pid=$(pgrep -u "$DESKTOP_USER" -x loginwindow | head -n 1 || true)
    if [ -n "$pid" ]; then
      sudo launchctl bsexec "$pid" "$cgs" -switchToUserID "$uid" >>"${LOG}/gui.log" 2>&1 || true
    else
      sudo launchctl asuser "$uid" "$cgs" -switchToUserID "$uid" >>"${LOG}/gui.log" 2>&1 || true
    fi
  fi
  show_finder
  owner=$(console_owner)
  case "$owner" in
    ""|root|loginwindow)
      send_login_password
      ;;
    *)
      if [ "$owner" != "$DESKTOP_USER" ]; then
        log "Console is ${owner}. Not typing a password over the current session."
      fi
      ;;
  esac
  redact_file "${LOG}/gui.log"
  sleep 2
}

classify_png() {
  local line="" kind=""
  GUI_PICTURE="error"
  GUI_MEAN=0
  GUI_DARK=1000
  GUI_DISTINCT=0
  GUI_WIDTH=0
  GUI_HEIGHT=0
  if [ ! -s "${ROOT}/console.png" ]; then
    return 1
  fi
  if [ ! -f "$GUI_CHECK" ]; then
    log "Missing ${GUI_CHECK}."
    return 1
  fi
  line=$(python3 "$GUI_CHECK" png-stats "${ROOT}/console.png" 2>>"${LOG}/gui.log" || true)
  read -r kind GUI_MEAN GUI_DARK GUI_DISTINCT GUI_WIDTH GUI_HEIGHT <<EOF
$line
EOF
  case "$kind" in
    picture|black) GUI_PICTURE="$kind" ;;
    *) GUI_PICTURE="error" ;;
  esac
}

capture_console() {
  rm -f "${ROOT}/console.png"
  screencapture -x "${ROOT}/console.png" >>"${LOG}/gui.log" 2>&1 || return 1
  [ -s "${ROOT}/console.png" ]
}

sample_vnc_kind() {
  local line="" kind=""
  GUI_VNC="skip"
  GUI_VNC_NOTE=""
  if ! port_open 5900; then
    GUI_VNC_NOTE="port-5900-closed"
    return 0
  fi
  if [ ! -f "$GUI_CHECK" ]; then
    GUI_VNC_NOTE="no-gui-check"
    return 0
  fi
  line=$(VNC_PASSWORD="$VNC_PASSWORD" python3 "$GUI_CHECK" vnc-sample 5900 2>>"${LOG}/gui.log" || true)
  read -r kind _mean _dark _distinct _width _height note <<EOF
$line
EOF
  case "$kind" in
    picture|black|skip) GUI_VNC="$kind" ;;
    *) GUI_VNC="skip" ;;
  esac
  GUI_VNC_NOTE=${note#note=}
  log "VNC framebuffer sample: ${line}"
}

log_gui_state() {
  local bytes=0
  if [ -f "${ROOT}/console.png" ]; then
    bytes=$(stat -f%z "${ROOT}/console.png" 2>/dev/null || wc -c <"${ROOT}/console.png" | tr -d ' ')
  fi
  printf '%s\n' "$bytes" >"${ROOT}/display-bytes.txt"
  GUI_SUMMARY="console ${GUI_CONSOLE:-unknown}, Finder ${GUI_FINDER:-unknown}, screenshot ${GUI_WIDTH:-0}x${GUI_HEIGHT:-0} ${GUI_PICTURE:-error} mean ${GUI_MEAN:-0}/255 dark ${GUI_DARK:-0}/1000 distinct ${GUI_DISTINCT:-0}, VNC ${GUI_VNC:-skip}${GUI_VNC_NOTE:+ ${GUI_VNC_NOTE}}"
  printf '%s\n' "$GUI_SUMMARY" >"${ROOT}/gui-check.txt"
  log "GUI check: ${GUI_SUMMARY} (${bytes} bytes). loginwindow: $(loginwindow_users)"
}

read_local_gui() {
  GUI_CONSOLE=$(console_owner)
  GUI_FINDER=$(finder_owner)
  if ! capture_console; then
    GUI_PICTURE="error"
    log "screencapture did not write a console image."
    return 1
  fi
  classify_png || true
  return 0
}

fail_gui() {
  local detail=""
  detail=$(cat "${ROOT}/gui-check.txt" 2>/dev/null || true)
  log "ERROR: The macOS GUI session is not a logged-in desktop."
  log "ERROR: ${detail}"
  if [ "${GUI_PICTURE:-}" = "picture" ] && [ "${GUI_FINDER:-}" = "$DESKTOP_USER" ] && [ "${GUI_CONSOLE:-}" != "$DESKTOP_USER" ]; then
    log "ERROR: Finder is ${DESKTOP_USER} and the screenshot is a desktop, but the console is ${GUI_CONSOLE:-unknown}."
    log "ERROR: Screen Sharing follows the console. Refusing to publish until the console is ${DESKTOP_USER} again."
  else
    log "ERROR: Refusing to publish Screen Sharing. A black loginwindow is not a usable desktop."
  fi
  log "ERROR: Expected console user ${DESKTOP_USER} with Finder running for that user, and a screenshot that is not near-black."
  tail_redacted "${LOG}/gui.log" || true
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat >>"${GITHUB_STEP_SUMMARY}" <<EOF
## Desktop was not ready

Screen Sharing was not published. The console is not a logged-in Aqua desktop, so noVNC would show the login window.

\`${detail:-"(no GUI check recorded)"}\`

Expected console user \`${DESKTOP_USER}\` with Finder running as that user, and a screenshot brighter than the dark grey login window. See the \`GUI check:\` lines in the job log.
EOF
  fi
  exit 1
}

# Pids of loginwindow running as uid 0. The desktop user's loginwindow is
# left alone: that process owns the Aqua session.
root_loginwindow_pids() {
  local found=""
  found=$(ps -axww -o uid=,pid=,command= 2>/dev/null | awk '
    $1 == 0 && index($0, "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow") {
      print $2
    }
  ')
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  ps -axww -o uid=,pid=,ucomm= 2>/dev/null | awk '$1 == 0 && $3 == "loginwindow" { print $2 }'
}

drop_root_loginwindow() {
  local pids="" pid=""
  pids=$(root_loginwindow_pids || true)
  if [ -z "$pids" ]; then
    return 0
  fi
  log "Stopping the root loginwindow without logging ${DESKTOP_USER} out."
  while read -r pid; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    log "Stopping root loginwindow pid ${pid}."
    sudo kill "$pid" >>"${LOG}/gui.log" 2>&1 || true
  done <<EOF
$pids
EOF
  sleep 1
  pids=$(root_loginwindow_pids || true)
  if [ -z "$pids" ]; then
    return 0
  fi
  while read -r pid; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    log "Root loginwindow pid ${pid} is still running. Sending SIGKILL."
    sudo kill -9 "$pid" >>"${LOG}/gui.log" 2>&1 || true
  done <<EOF
$pids
EOF
  sleep 1
}

# Between kickstart steps the desktop was just verified. Stop a new root
# loginwindow before it can take /dev/console. Publish still waits for a
# fresh screenshot.
drop_extra_root_loginwindow() {
  local finder="" windows=""
  finder=$(finder_owner)
  windows=$(loginwindow_users)
  if root_loginwindow_beside_finder "$DESKTOP_USER" "$finder" "$windows"; then
    log "A root loginwindow appeared while Finder is still ${DESKTOP_USER}."
    drop_root_loginwindow
  fi
}

# read_local_gui must have run first. Stops a root loginwindow when the
# desktop user's Finder and a real screenshot are both still up, then reads
# the console again. Does not type a password and does not switch sessions.
settle_visible_desktop() {
  local windows="" rounds=0 owner=""
  windows=$(loginwindow_users)
  owner=$(console_owner)
  if ! should_drop_root_loginwindow "$DESKTOP_USER" "$GUI_FINDER" "$GUI_PICTURE" "$windows"; then
    if [ "$owner" = "root" ] && [ "$GUI_PICTURE" = "picture" ] && [ "$GUI_FINDER" = "$DESKTOP_USER" ]; then
      log "Console is root while ${DESKTOP_USER}'s desktop is still on screen. Stopping a root loginwindow if one is running."
      drop_root_loginwindow
      sleep 2
      read_local_gui || true
    fi
    return 0
  fi
  while [ "$rounds" -lt 2 ]; do
    drop_root_loginwindow
    sleep 2
    read_local_gui || true
    windows=$(loginwindow_users)
    if ! should_drop_root_loginwindow "$DESKTOP_USER" "$GUI_FINDER" "$GUI_PICTURE" "$windows"; then
      break
    fi
    rounds=$((rounds + 1))
    log "Root loginwindow is still running after stop attempt ${rounds}."
  done
  owner=$(console_owner)
  if [ "$owner" != "$DESKTOP_USER" ]; then
    log "Console is ${owner:-unknown} after stopping the root loginwindow. ${DESKTOP_USER}'s Finder is still the desktop; not typing a password."
  else
    log "Console is ${DESKTOP_USER} after stopping the root loginwindow."
  fi
}

note_console() {
  local label="$1"
  log "Console ${label}: $(console_owner); loginwindow: $(loginwindow_users)"
}

ensure_gui_ready() {
  local want_vnc="${1:-}"
  local attempt=1
  local vnc_kind="skip"
  local saw_desktop=0
  wake_machine
  while [ "$attempt" -le 3 ]; do
    show_finder
    sleep 2
    read_local_gui || true
    if [ "$GUI_PICTURE" = "picture" ] && [ "$GUI_FINDER" = "$DESKTOP_USER" ]; then
      saw_desktop=1
    fi
    settle_visible_desktop
    if [ "$GUI_PICTURE" = "picture" ] && [ "$GUI_FINDER" = "$DESKTOP_USER" ]; then
      saw_desktop=1
    fi
    vnc_kind="skip"
    GUI_VNC="skip"
    GUI_VNC_NOTE=""
    if [ "$want_vnc" = "vnc" ] && gui_verdict "$DESKTOP_USER" "$GUI_CONSOLE" "$GUI_FINDER" "$GUI_PICTURE" skip; then
      sample_vnc_kind
      downgrade_apple_vnc_sample
      vnc_kind="$GUI_VNC"
    fi
    log_gui_state
    if gui_verdict "$DESKTOP_USER" "$GUI_CONSOLE" "$GUI_FINDER" "$GUI_PICTURE" "$vnc_kind"; then
      log "Desktop session is ready for ${DESKTOP_USER}."
      return 0
    fi
    if [ "$saw_desktop" = "1" ] || ! loginwindow_recovery_allowed "$GUI_PICTURE" "$GUI_FINDER" "$DESKTOP_USER"; then
      log "Desktop is not ready (attempt ${attempt} of 3). Screenshot is already a desktop for ${DESKTOP_USER}; not typing into loginwindow."
      if [ "$GUI_CONSOLE" != "$DESKTOP_USER" ]; then
        log "Console is ${GUI_CONSOLE:-unknown}. Publish stays blocked until it is ${DESKTOP_USER} again."
      fi
      attempt=$((attempt + 1))
      continue
    fi
    log "Desktop is not ready (attempt ${attempt} of 3)."
    restore_desktop_session
    attempt=$((attempt + 1))
  done
  read_local_gui || true
  if [ "$GUI_PICTURE" = "picture" ] && [ "$GUI_FINDER" = "$DESKTOP_USER" ]; then
    settle_visible_desktop
  fi
  vnc_kind="skip"
  if [ "$want_vnc" = "vnc" ]; then
    sample_vnc_kind || true
    downgrade_apple_vnc_sample
    vnc_kind="$GUI_VNC"
  fi
  log_gui_state
  if gui_verdict "$DESKTOP_USER" "$GUI_CONSOLE" "$GUI_FINDER" "$GUI_PICTURE" "$vnc_kind"; then
    log "Desktop session is ready for ${DESKTOP_USER}."
    return 0
  fi
  fail_gui
}

save_session_state() {
  printf '%s\n' "$DESKTOP_USER" >"${ROOT}/desktop-user"
  printf '%s\n' "$CONSOLE_PASSWORD_SET" >"${ROOT}/console-password-set"
  printf '%s\n' "${CONSOLE_USER:-$DESKTOP_USER}" >"${ROOT}/console-user"
}

load_session_state() {
  if [ -f "${ROOT}/desktop-user" ]; then
    DESKTOP_USER=$(cat "${ROOT}/desktop-user")
  fi
  if [ -z "${DESKTOP_USER:-}" ]; then
    DESKTOP_USER=$(id -un)
  fi
  if [ -f "${ROOT}/console-password-set" ]; then
    CONSOLE_PASSWORD_SET=$(cat "${ROOT}/console-password-set")
  fi
  if [ -z "${CONSOLE_USER:-}" ]; then
    CONSOLE_USER=$(id -un)
  fi
}

screensharing_pids() {
  {
    pgrep -x screensharingd || true
    pgrep -x AppleVNCServer || true
    pgrep -x ARDAgent || true
  } | sort | tr '\n' ' '
  printf '\n'
}

start_screensharing_service() {
  sudo launchctl enable system/com.apple.screensharing >>"${LOG}/kickstart.log" 2>&1 || true
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist \
    >>"${LOG}/kickstart.log" 2>&1 || \
    sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist \
    >>"${LOG}/kickstart.log" 2>&1 || true
}

force_restart_novnc() {
  log "Restarting the noVNC proxy so it opens a fresh connection to Screen Sharing."
  kill_pidfile "${LOG}/novnc.pid"
  start_novnc_proxy || true
  if ! wait_for_port 6080 10; then
    log "noVNC proxy did not bind 6080 after the restart."
    tail_redacted "${LOG}/novnc.log"
  fi
}

# Screen Sharing restarts drop websockify's TCP session. noVNC then sits on
# "Connecting…" until the proxy is started again. Watch the listener and the
# screensharing pids and recycle the proxy when either changes.
guard_novnc() {
  local sig="" old=""
  sig=$(screensharing_pids)
  old=$(cat "${ROOT}/screensharing.pids" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$sig" != "$old" ]; then
    log "Screen Sharing process changed. Recycling noVNC."
    force_restart_novnc
  fi
  printf '%s\n' "$sig" >"${ROOT}/screensharing.pids"
  if ! port_open 5900; then
    log "Screen Sharing is not listening. Starting it again without touching the console session."
    start_screensharing_service
    if wait_for_port 5900 15; then
      force_restart_novnc
    else
      log "Screen Sharing did not come back."
    fi
  elif ! port_open 6080 || ! pid_alive "${LOG}/novnc.pid"; then
    log "noVNC proxy is down. Starting it again."
    start_novnc_proxy || true
  fi
}

enable_screen_sharing() {
  if [ ! -x "$KICK" ]; then
    die "Screen Sharing kickstart is missing: ${KICK}"
  fi
  log "Enabling Screen Sharing and the legacy VNC password."
  log "Not creating a second user, and not restarting the console. The agent is restarted only if port 5900 stays down."
  note_console "before Screen Sharing"
  # -restart -agent is not on this command. On the runner it started a root
  # loginwindow, and that process took /dev/console a few seconds later.
  sudo "$KICK" -activate -configure -access -on \
    -allowAccessFor -allUsers -privs -all \
    >>"${LOG}/kickstart.log" 2>&1 || log "kickstart activate returned a non-zero status (often still applied)."
  note_console "after kickstart configure"
  drop_extra_root_loginwindow

  printf '%s\n%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | \
    sudo "$KICK" -configure -clientopts -setvnclegacy -vnclegacy yes -setvncpw \
    >>"${LOG}/kickstart.log" 2>&1 || true

  sudo "$KICK" -configure -clientopts -setvnclegacy -vnclegacy yes \
    -setvncpw -vncpw "$VNC_PASSWORD" \
    >>"${LOG}/kickstart.log" 2>&1 || true

  if command -v perl >/dev/null 2>&1; then
    vnc_password_hex "$VNC_PASSWORD" | sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null
    sudo chown root:wheel /Library/Preferences/com.apple.VNCSettings.txt 2>/dev/null || true
  else
    log "perl is missing, so the legacy password file was not written. kickstart still received the password."
  fi
  note_console "after VNC password"
  drop_extra_root_loginwindow

  if ! wait_for_port 5900 15; then
    log "Screen Sharing is not listening yet. Starting the launch daemon without restarting loginwindow."
    start_screensharing_service
    note_console "after launchctl bootstrap"
    drop_extra_root_loginwindow
  fi
  if ! port_open 5900; then
    # One agent restart, and never -console. -console restarts loginwindow
    # and leaves the framebuffer on a black login screen.
    log "Screen Sharing is still down. Restarting the Remote Management agent once."
    sudo "$KICK" -restart -agent >>"${LOG}/kickstart.log" 2>&1 || true
    sudo "$KICK" -activate >>"${LOG}/kickstart.log" 2>&1 || true
    note_console "after agent restart"
    drop_extra_root_loginwindow
  fi
  redact_file "${LOG}/kickstart.log"

  if ! wait_for_port 5900 20; then
    log "Screen Sharing is not listening on 127.0.0.1:5900."
    if grep -q "Screen recording might be disabled" "${LOG}/kickstart.log" 2>/dev/null; then
      log "kickstart reported that Screen Recording permission may be missing."
    fi
    tail_redacted "${LOG}/kickstart.log"
    tail_redacted "${LOG}/user.log"
    exit 1
  fi
  log "Screen Sharing is listening on 127.0.0.1:5900."
  read_local_gui || true
  settle_visible_desktop
  note_console "after Screen Sharing"
  screensharing_pids >"${ROOT}/screensharing.pids" || true
}

reset_console_password() {
  local user="$DESKTOP_USER"
  if sudo sysadminctl -resetPasswordFor "$user" -newPassword "$VNC_USER_PASSWORD" >>"${LOG}/user.log" 2>&1; then
    CONSOLE_PASSWORD_SET="yes"
    log "Set the macOS password for ${user}."
  elif printf '%s\n' "$VNC_USER_PASSWORD" | sudo dscl . -passwd "/Users/${user}" >>"${LOG}/user.log" 2>&1; then
    CONSOLE_PASSWORD_SET="yes"
    log "Set the macOS password for ${user} with dscl."
  else
    CONSOLE_PASSWORD_SET="no"
    log "Could not set the macOS password for ${user}. Legacy VNC still uses VNC_PASSWORD."
    log "If a client asks for a macOS account, VNC_USER_PASSWORD may be rejected."
  fi
  redact_file "${LOG}/user.log"
}

cmd_setup() {
  require_macos
  need_dir
  note_start
  CONSOLE_USER=$(id -un)
  DESKTOP_USER="$CONSOLE_USER"
  require_vnc_secrets
  local vnc_len before="" after=""
  vnc_len=$(printf '%s' "$VNC_PASSWORD" | wc -c | tr -d ' ')
  if [ "$vnc_len" -gt 8 ]; then
    log "VNC_PASSWORD is ${vnc_len} characters. Legacy VNC uses the first 8."
  fi
  sudo mkdir -p /Users/Shared
  sudo chmod 755 /Users/Shared
  wake_machine
  before=$(console_owner)
  log "Console before setup: ${before:-unknown}. Desktop user: ${DESKTOP_USER}."
  log "Leaving the existing Aqua session in place. A second account is not created."
  reset_console_password
  after=$(console_owner)
  if [ "$before" = "$DESKTOP_USER" ] && [ "$after" = "$DESKTOP_USER" ]; then
    # sysadminctl -autologin and defaults write com.apple.loginwindow ran
    # before kickstart on the run where a root loginwindow appeared and
    # then took /dev/console. The console is already this user, so those
    # writes are not needed for Screen Sharing.
    log "Console is already ${DESKTOP_USER}. Not arming auto-login and not writing com.apple.loginwindow."
  else
    if [ "$CONSOLE_PASSWORD_SET" = "yes" ]; then
      arm_autologin "$DESKTOP_USER"
    fi
    after=$(console_owner)
    if [ "$before" = "$DESKTOP_USER" ] && [ -n "$after" ] && [ "$after" != "$DESKTOP_USER" ]; then
      log "Setting the password moved the console from ${before} to ${after}."
      restore_desktop_session
    fi
  fi
  ensure_gui_ready
  enable_screen_sharing
  ensure_gui_ready vnc
  save_session_state
  mkdir -p "${HOME}/Desktop"
  log "Screen Sharing is ready. Logged-in desktop user: ${DESKTOP_USER}."
}

novnc_link() {
  if [ -z "$NOVNC_URL" ]; then
    printf '%s\n' ""
    return
  fi
  printf '%s\n' "${NOVNC_URL}/vnc.html?autoconnect=1&resize=scale&reconnect=1"
}

write_summary() {
  local summary="${GITHUB_STEP_SUMMARY:-}"
  local link tight account_line dmg_line display_line tmate_line shell_line native_line end_line
  link=$(novnc_link)
  if [ -n "$VNC_HOST" ]; then
    tight="${VNC_HOST}::${VNC_PORT}"
    native_line=$(cat <<EOF
### Native VNC client

- Host: \`${VNC_HOST}\`
- Port: \`${VNC_PORT}\`
- TightVNC address: \`${tight}\`
- Password: the \`VNC_PASSWORD\` secret (first 8 characters)
EOF
)
  else
    native_line=$(cat <<EOF
### Native VNC client

${NGROK_NOTE}
EOF
)
  fi
  if [ "$CONSOLE_PASSWORD_SET" = "yes" ]; then
    account_line="- The desktop is already logged in as \`${DESKTOP_USER:-$CONSOLE_USER}\`. If a client asks for a macOS account, use that name. Password: the \`VNC_USER_PASSWORD\` secret."
  else
    account_line="- The desktop is already logged in as \`${DESKTOP_USER:-$CONSOLE_USER}\`. Legacy VNC uses \`VNC_PASSWORD\`. The macOS account password was left unchanged, so a username prompt may reject \`VNC_USER_PASSWORD\`."
  fi
  if [ -f "/Users/Shared/${DMG_NAME}" ]; then
    dmg_line="- \`${DMG_NAME}\` is on the Desktop and at \`/Users/Shared/${DMG_NAME}\`."
  else
    dmg_line="- Installer was not downloaded. From the desktop: \`curl -fL -o ~/Desktop/${DMG_NAME} ${DMG_URL}\`"
  fi
  if [ -f "${ROOT}/gui-check.txt" ]; then
    display_line="- GUI check: $(cat "${ROOT}/gui-check.txt")"
  elif [ -f "${ROOT}/display-bytes.txt" ]; then
    display_line="- Console capture: $(cat "${ROOT}/display-bytes.txt") bytes."
  else
    display_line=""
  fi
  if [ -n "$SHELL_URL" ]; then
    shell_line=$(cat <<EOF
### Browser shell

- ${SHELL_URL}
- Basic auth user: \`${CONSOLE_USER}\`
- Basic auth password: the \`VNC_USER_PASSWORD\` secret (skipped when that secret contains a colon)
EOF
)
  else
    shell_line="### Browser shell"$'\n\n'"ttyd tunnel is not up. See the job log."
  fi
  if [ -n "$TMATE_WEB" ] || [ -n "$TMATE_SSH" ]; then
    tmate_line=$(cat <<EOF
### tmate

- Web: ${TMATE_WEB:-"(none)"}
- SSH: \`${TMATE_SSH:-"(none)"}\`
- ${TMATE_SSH_NOTE}
EOF
)
  else
    tmate_line=$(cat <<EOF
### tmate

${TMATE_STATUS}
EOF
)
  fi
  end_line="Hold ends at about ${HOLD_END_TEXT:-unknown} runner time (${HOLD_MINUTES_EFFECTIVE:-?} minutes)."
  if [ -z "$summary" ]; then
    summary="${ROOT}/summary.md"
  fi
  cat >"$summary" <<EOF
## SunoCoverBot macOS desktop

This log is public. Anyone who can read it can open the addresses below until the run is cancelled.

${end_line}

### Browser desktop

- ${link:-"(tunnel not ready)"}
- Password: the \`VNC_PASSWORD\` secret (GitHub masks it in the log)

${native_line}

${account_line}

${shell_line}

${tmate_line}

### On the desktop

${dmg_line}
${display_line}
- Google Chrome is preinstalled at \`/Applications/Google Chrome.app\`.
- If Gatekeeper blocks the app: System Settings → Privacy & Security → Open Anyway.

Cancel this workflow run when you finish. A new run cancels the one already open.
EOF
}

print_banner() {
  local link tight
  link=$(novnc_link)
  log "============================================================"
  log " SunoCoverBot macOS desktop"
  log "============================================================"
  log "This log is public. Cancel the run when you finish."
  log "Hold: ${HOLD_MINUTES_EFFECTIVE:-?} minutes (ends about ${HOLD_END_TEXT:-unknown})."
  log "GitHub stops the job at 6 hours even if the timer is shorter."
  log ""
  log "Browser desktop (open in Chrome, no VNC app):"
  log "  ${link:-"(not ready)"}"
  log "  Password: VNC_PASSWORD (stored as a secret; masked in this log)"
  log ""
  if [ -n "$VNC_HOST" ]; then
    tight="${VNC_HOST}::${VNC_PORT}"
    log "Native VNC:"
    log "  Host: ${VNC_HOST}"
    log "  Port: ${VNC_PORT}"
    log "  TightVNC address: ${tight}"
    log "  Password: VNC_PASSWORD (first 8 characters)"
  else
    log "Native VNC:"
    log "  ${NGROK_NOTE}"
  fi
  if [ "$CONSOLE_PASSWORD_SET" = "yes" ]; then
    log "  macOS account, if asked: ${DESKTOP_USER:-$CONSOLE_USER} / VNC_USER_PASSWORD"
  else
    log "  macOS account password was not changed. If asked, try ${DESKTOP_USER:-$CONSOLE_USER}; VNC_USER_PASSWORD may be rejected."
  fi
  log "  The desktop should already be logged in (menu bar and Finder), not a black login window."
  log ""
  log "Browser shell (ttyd):"
  log "  ${SHELL_URL:-"(not ready)"}"
  log "  Basic auth user: ${CONSOLE_USER}"
  log "  Basic auth password: VNC_USER_PASSWORD"
  log "tmate: ${TMATE_STATUS}"
  if [ -n "$TMATE_WEB" ]; then
    log "  Web: ${TMATE_WEB}"
  fi
  if [ -n "$TMATE_SSH" ]; then
    log "  SSH: ${TMATE_SSH}"
  fi
  if [ -n "$TMATE_SSH_NOTE" ]; then
    log "  ${TMATE_SSH_NOTE}"
  fi
  log ""
  if [ -f "/Users/Shared/${DMG_NAME}" ]; then
    log "Installer: /Users/Shared/${DMG_NAME} and the Desktop of ${DESKTOP_USER:-$CONSOLE_USER}."
  else
    log "Installer was not downloaded."
    log "  curl -fL -o ~/Desktop/${DMG_NAME} ${DMG_URL}"
  fi
  log "Chrome: /Applications/Google Chrome.app"
  if [ -f "${ROOT}/gui-check.txt" ]; then
    log "GUI check: $(cat "${ROOT}/gui-check.txt")"
  elif [ -f "${ROOT}/display-bytes.txt" ]; then
    log "Console capture bytes: $(cat "${ROOT}/display-bytes.txt")"
  fi
  log "עברית: סיסמת ה-VNC היא הסוד VNC_PASSWORD. שולחן העבודה בדפדפן הוא הקישור למעלה. מבטלים את הריצה בסיום."
  log "============================================================"
  write_summary
  if [ "$NOTICES_SENT" = "yes" ]; then
    return 0
  fi
  NOTICES_SENT="yes"
  if [ -n "$link" ]; then
    echo "::notice title=Browser desktop::${link}"
  fi
  if [ -n "$VNC_HOST" ]; then
    echo "::notice title=Native VNC::${VNC_HOST}:${VNC_PORT}"
  fi
  if [ -n "$SHELL_URL" ]; then
    echo "::notice title=Browser shell::${SHELL_URL}"
  fi
}

write_connect_file() {
  local tmp="${ROOT}/CONNECT.txt"
  local link
  link=$(novnc_link)
  cat >"$tmp" <<EOF
SunoCoverBot macOS E2E

Browser desktop: ${link:-"(see the Actions log)"}
VNC password: the VNC_PASSWORD secret (not written in this file)

Native VNC host: ${VNC_HOST:-"(ngrok TCP not up)"}
Native VNC port: ${VNC_PORT:-"-"}

Browser shell: ${SHELL_URL:-"(see the Actions log)"}
Shell user: ${CONSOLE_USER}
Shell password: the VNC_USER_PASSWORD secret

Installer: /Users/Shared/${DMG_NAME}
Chrome: /Applications/Google Chrome.app

If Gatekeeper blocks the app, open System Settings, Privacy & Security, Open Anyway.
EOF
  publish_file "$tmp" "CONNECT.txt"
}

refresh_tunnels() {
  local url
  guard_novnc
  if ! port_open 7681; then
    start_ttyd || true
  fi
  if ! pid_alive "${LOG}/caffeinate.pid"; then
    start_background caffeinate caffeinate -dimsu
  fi
  if [ "$NOVNC_VIA" = "cloudflare" ] && ! pid_alive "${LOG}/cf-novnc.pid"; then
    log "Browser desktop tunnel stopped. Opening a new one."
    url=$(start_cloudflared novnc 6080 44451 || true)
    if [ -n "$url" ] && [ "$url" != "$NOVNC_URL" ]; then
      NOVNC_URL="$url"
      NOTICES_SENT=""
      print_banner
    fi
  fi
  if [ "$SHELL_VIA" = "cloudflare" ] && ! pid_alive "${LOG}/cf-shell.pid"; then
    log "Browser shell tunnel stopped. Opening a new one."
    url=$(start_cloudflared shell 7681 44452 || true)
    if [ -n "$url" ] && [ "$url" != "$SHELL_URL" ]; then
      SHELL_URL="$url"
      NOTICES_SENT=""
      print_banner
    fi
  fi
  if [ "$NOVNC_VIA" = "ngrok" ] && [ -z "$VNC_URL" ] && ! pid_alive "${LOG}/ngrok.pid"; then
    log "ngrok HTTP tunnel stopped. Starting it again."
    url=$(start_ngrok_http_fallback 6080 "noVNC" || true)
    if [ -n "$url" ]; then
      NOVNC_URL="$url"
      NOTICES_SENT=""
      print_banner
    fi
  fi
  if [ -n "$VNC_URL" ] && ! pid_alive "${LOG}/ngrok.pid"; then
    log "ngrok stopped. Starting TCP again."
    start_ngrok_tcp || true
    NOTICES_SENT=""
    print_banner
  fi
}

cmd_serve() {
  require_macos
  need_dir
  CONSOLE_USER=$(id -un)
  load_session_state
  require_vnc_secrets
  if ! port_open 5900; then
    die "Screen Sharing is not listening. The setup step needs to succeed first."
  fi
  note_start
  log "Checking the logged-in desktop before opening tunnels."
  ensure_gui_ready vnc
  HOLD_MINUTES_EFFECTIVE=$(clamp_minutes "${HOLD_MINUTES:-90}")

  log "Installing noVNC, cloudflared, ngrok, ttyd, and tmate."
  clone_novnc || log "Could not clone noVNC. The browser desktop needs it."
  install_cloudflared || log "cloudflared install failed."
  if [ -n "${NGROK_AUTH_TOKEN:-}" ]; then
    install_ngrok || log "ngrok install failed."
  fi
  install_brew_tools

  log "Starting the noVNC proxy on 127.0.0.1:6080."
  start_novnc_proxy || true
  if ! wait_for_port 6080 20; then
    log "noVNC did not start. Log:"
    tail_redacted "${LOG}/novnc.log"
  fi

  log "Starting the browser shell on 127.0.0.1:7681."
  start_ttyd || true

  log "Opening Cloudflare quick tunnels."
  NOVNC_URL=$(start_cloudflared novnc 6080 44451 || true)
  if [ -n "$NOVNC_URL" ]; then
    NOVNC_VIA="cloudflare"
  else
    log "Cloudflare tunnel for the desktop did not return a URL."
    tail_redacted "${LOG}/cf-novnc.log"
  fi
  SHELL_URL=$(start_cloudflared shell 7681 44452 || true)
  if [ -n "$SHELL_URL" ]; then
    SHELL_VIA="cloudflare"
  else
    log "Cloudflare tunnel for the shell did not return a URL."
    tail_redacted "${LOG}/cf-shell.log"
  fi

  log "Starting ngrok TCP for native VNC."
  start_ngrok_tcp || true

  if [ -z "$NOVNC_URL" ] && [ -z "$VNC_HOST" ]; then
    local fallback
    kill_pidfile "${LOG}/ngrok.pid"
    fallback=$(start_ngrok_http_fallback 6080 "noVNC" || true)
    if [ -n "$fallback" ]; then
      NOVNC_URL="$fallback"
      NOVNC_VIA="ngrok"
      NGROK_NOTE="Browser desktop is on an ngrok HTTP address. The free plan shows an ngrok warning page before the session. Save a card on the ngrok account (it is not charged) when you want native TCP as well."
    fi
  fi
  if [ -z "$SHELL_URL" ] && ! pid_alive "${LOG}/ngrok.pid"; then
    local shell_fallback
    shell_fallback=$(start_ngrok_http_fallback 7681 "ttyd" || true)
    if [ -n "$shell_fallback" ]; then
      SHELL_URL="$shell_fallback"
      SHELL_VIA="ngrok"
    fi
  fi

  log "Starting tmate (short wait; public servers may be offline)."
  start_tmate

  log "Keeping the display awake for this session."
  start_background caffeinate caffeinate -dimsu

  if [ -z "$NOVNC_URL" ] && [ -z "$VNC_HOST" ] && [ -z "$SHELL_URL" ] && [ -z "$TMATE_SSH" ]; then
    log "No tunnel or shell came up, so the runner will not be held."
    tail_redacted "${LOG}/cf-novnc.log"
    tail_redacted "${LOG}/ngrok.log"
    exit 1
  fi

  HOLD_MINUTES_EFFECTIVE=$(cap_hold "$HOLD_MINUTES_EFFECTIVE")
  local now end_epoch
  now=$(date +%s)
  end_epoch=$((now + HOLD_MINUTES_EFFECTIVE * 60))
  if HOLD_END_TEXT=$(date -r "$end_epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null); then
    :
  else
    HOLD_END_TEXT=$(date -d "@${end_epoch}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$end_epoch")
  fi
  export HOLD_MINUTES_EFFECTIVE HOLD_END_TEXT

  log "Checking the desktop once more before publishing the browser URL."
  ensure_gui_ready vnc
  write_connect_file || log "Could not copy CONNECT.txt onto the Desktop."
  print_banner

  local next_banner now_loop remaining
  next_banner=$(( $(date +%s) + 300 ))
  while [ "$(date +%s)" -lt "$end_epoch" ]; do
    now_loop=$(date +%s)
    remaining=$(( (end_epoch - now_loop) / 60 ))
    refresh_tunnels
    if [ "$now_loop" -ge "$next_banner" ]; then
      print_banner
      next_banner=$((now_loop + 300))
    else
      log "Desktop still open. About ${remaining} minutes left. Cancel the run when you finish."
    fi
    sleep 60
  done
  log "Hold time elapsed. Shutting the desktop down."
}

self_test() {
  local got long short url hostport sample json_file proto parsed
  got=$(clamp_minutes "")
  [ "$got" = "90" ]
  got=$(clamp_minutes 5)
  [ "$got" = "15" ]
  got=$(clamp_minutes 90)
  [ "$got" = "90" ]
  got=$(clamp_minutes 9999)
  [ "$got" = "300" ]
  got=$(clamp_minutes abc)
  [ "$got" = "90" ]
  got=$(clamp_minutes 090)
  [ "$got" = "90" ]

  long=$(vnc_password_hex "123456789")
  short=$(vnc_password_hex "12345678")
  [ "$long" = "$short" ]
  [ "${#long}" -eq 32 ]
  case "$long" in
    *[!0-9A-F]*) die "VNC hex was not uppercase hex: ${long}" ;;
  esac

  sample="ready https://AbC-123.trycloudflare.com/vnc.html more"
  url=$(extract_trycloudflare "$sample")
  [ "$url" = "https://AbC-123.trycloudflare.com" ]

  hostport=$(split_tcp_url "tcp://1.tcp.ngrok.io:12345")
  [ "$hostport" = "1.tcp.ngrok.io 12345" ]

  json_file=$(mktemp)
  cat >"$json_file" <<'EOF'
{"tunnels":[{"name":"vnc","proto":"tcp","public_url":"tcp://0.tcp.ngrok.io:17777"}]}
EOF
  parsed=$(ngrok_public_urls "$json_file")
  proto=${parsed%%"$(printf '\t')"*}
  url=${parsed#*"$(printf '\t')"}
  [ "$proto" = "tcp" ]
  [ "$url" = "tcp://0.tcp.ngrok.io:17777" ]
  rm -f "$json_file"

  sample=$(mktemp)
  printf '%s\n' "token hunter2 and password s3cret" >"$sample"
  VNC_PASSWORD=s3cret
  NGROK_AUTH_TOKEN=hunter2
  redact_file "$sample"
  grep -q '\*\*\*' "$sample"
  if grep -q 'hunter2' "$sample"; then
    die "redact_file left the ngrok token in place"
  fi
  if grep -q 's3cret' "$sample"; then
    die "redact_file left the VNC password in place"
  fi
  rm -f "$sample"
  VNC_PASSWORD=""
  NGROK_AUTH_TOKEN=""

  if gui_verdict runner runner runner picture skip; then
    :
  else
    die "gui_verdict rejected a logged-in desktop"
  fi
  if gui_verdict runner vncuser runner picture skip; then
    die "gui_verdict accepted a console owned by a different user"
  fi
  if gui_verdict runner runner "-" picture skip; then
    die "gui_verdict accepted a session with no Finder"
  fi
  if gui_verdict runner runner runner black skip; then
    die "gui_verdict accepted a black screenshot"
  fi
  if gui_verdict runner runner runner picture black; then
    die "gui_verdict accepted a black VNC framebuffer"
  fi
  if gui_verdict runner root loginwindow black skip; then
    die "gui_verdict accepted the login window"
  fi
  if gui_verdict runner loginwindow runner picture skip; then
    die "gui_verdict accepted loginwindow as the console user"
  fi
  if ! apple_rfb_note "types:30,33,36,2,35"; then
    die "apple RFB types were not recognized"
  fi
  if ! apple_rfb_note "types:30"; then
    die "security type 30 alone was not recognized"
  fi
  if apple_rfb_note "types:2"; then
    die "legacy VNC type 2 was treated as Apple authentication"
  fi
  if apple_rfb_note "types:130,2"; then
    die "type 130 was treated as Apple authentication"
  fi
  if vnc_blocks_publish picture runner runner black "types:30,33,36,2,35"; then
    die "a black Apple-auth VNC sample blocked a picture desktop"
  fi
  if vnc_blocks_publish picture runner runner skip "types:30,33"; then
    die "a skipped VNC sample blocked publish"
  fi
  if vnc_blocks_publish picture runner runner black "types:2"; then
    :
  else
    die "a legacy-only black VNC sample was ignored"
  fi
  if loginwindow_recovery_allowed picture runner runner; then
    die "loginwindow recovery ran against a visible Finder desktop"
  fi
  if loginwindow_recovery_allowed black runner runner; then
    :
  else
    die "loginwindow recovery was skipped for a black screenshot"
  fi
  if loginwindow_recovery_allowed picture "-" runner; then
    :
  else
    die "loginwindow recovery was skipped when Finder was missing"
  fi
  if root_loginwindow_beside_finder runner runner "root runner"; then
    :
  else
    die "a root loginwindow beside Finder was ignored"
  fi
  if root_loginwindow_beside_finder runner "-" "root"; then
    die "a root loginwindow was matched when Finder was missing"
  fi
  if root_loginwindow_beside_finder runner runner "runner"; then
    die "the desktop user's loginwindow was matched as an extra root process"
  fi
  if should_drop_root_loginwindow runner runner picture "root runner"; then
    :
  else
    die "a root loginwindow over a visible desktop was left running"
  fi
  if should_drop_root_loginwindow runner runner picture "root runner "; then
    :
  else
    die "a trailing space hid the root loginwindow"
  fi
  if should_drop_root_loginwindow runner runner picture "root"; then
    :
  else
    die "a lone root loginwindow over a visible desktop was left running"
  fi
  if should_drop_root_loginwindow runner runner picture "runner root"; then
    :
  else
    die "root listed after the desktop user was left running"
  fi
  if should_drop_root_loginwindow runner runner picture "runner"; then
    die "the desktop user's loginwindow was treated as root"
  fi
  if should_drop_root_loginwindow runner runner picture "runner "; then
    die "the desktop user's loginwindow was treated as root"
  fi
  if should_drop_root_loginwindow runner runner black "root runner"; then
    die "a root loginwindow was stopped while the screenshot was black"
  fi
  if should_drop_root_loginwindow runner "-" picture "root"; then
    die "a root loginwindow was stopped when Finder was not the desktop user"
  fi
  if should_drop_root_loginwindow runner runner picture "rooty runner"; then
    die "a user named rooty was treated as root"
  fi
  if gui_verdict runner root runner picture skip; then
    die "gui_verdict accepted console root while Finder and the screenshot were a desktop"
  fi
  python3 "$GUI_CHECK" self-test

  if port_open 59991; then
    die "port_open reported a closed port as open"
  fi
  got=$(sanitize_public_url "https://example.trycloudflare.com")
  [ "$got" = "https://example.trycloudflare.com" ]
  got=$(sanitize_public_url "https://evil.example/::stop-commands::")
  [ -z "$got" ]
  log "self-test ok"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    setup) cmd_setup ;;
    download) cmd_download ;;
    serve) cmd_serve ;;
    --self-test) self_test ;;
    *)
      log "Usage: macos-desktop.sh setup|download|serve|--self-test"
      exit 2
      ;;
  esac
}

main "$@"
