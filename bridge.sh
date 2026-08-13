#!/usr/bin/env bash
# shellcheck shell=bash
# mac-remote-bridge — zero-config remote assistance for macOS.
#
# Opens a reverse SSH tunnel (via Pinggy) so an operator can reach this Mac
# through NAT/CGNAT/firewalls without port forwarding.
#
# Security notes (read before running, especially via curl | bash):
#   • Confirmation and sudo always go through /dev/tty — piped stdin is never
#     treated as consent.
#   • Screen Sharing (VNC) is opt-in.
#   • The tunnel is tracked by PID files; we never pkill unrelated processes.
#   • SSH client config is ignored (-F /dev/null) so ProxyJump/Identities
#     cannot break or leak into the broker connection.
#
# Usage: bridge.sh [command] [options]
# Run `bridge.sh help` for the full command list.
#
# License: MIT

# Must be bash — re-exec if invoked with sh.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

readonly VERSION="2.0.0"
readonly RAW_URL="https://raw.githubusercontent.com/chumafox/mac-remote-bridge/main/bridge.sh"
readonly DEFAULT_BROKER="free.pinggy.io"
readonly DEFAULT_BROKER_USER="tcp"

# Overridable (tests set MRB_STATE_DIR / reassign STATE_DIR).
STATE_DIR="${MRB_STATE_DIR:-${HOME}/.mac-remote-bridge}"

# ---------------------------------------------------------------------------
# Globals (bash 3.2 — no associative arrays)
# ---------------------------------------------------------------------------
CMD="start"
ASSUME_YES=0
WANT_VNC=0
VNC_FLAG=0
FORCE=0
FOREGROUND=0
JSON=0
QUIET=0
LANG_CODE=""
PINGGY_TOKEN="${PINGGY_TOKEN:-}"
ALLOW_IP=""
BROKER_HOST="${PINGGY_HOST:-$DEFAULT_BROKER}"

USER_NAME=""
RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" NC=""

SESSION_FILE=""
RUN_FILE=""
LOG_FILE=""
SSH_PID_FILE=""
SUP_PID_FILE=""
SUPERVISE_SCRIPT=""
KNOWN_HOSTS=""
ENABLED_FILE=""

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
init_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    RED=$'\033[1;31m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[1;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
  fi
}

detect_lang() {
  if [ -n "${LANG_CODE}" ]; then
    return 0
  fi
  if [ -n "${MRB_LANG:-}" ]; then
    LANG_CODE=$(printf '%s' "${MRB_LANG}" | tr '[:upper:]' '[:lower:]')
    return 0
  fi
  local spec
  spec=$(printf '%s' "${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}" | tr '[:upper:]' '[:lower:]')
  case "${spec}" in
    ru|ru_*|*.ru|ru.*) LANG_CODE="ru" ;;
    *) LANG_CODE="en" ;;
  esac
}

# Tiny i18n table. Keys are stable; never put user data in the key.
t() {
  local key="$1"
  case "${LANG_CODE}:${key}" in
    ru:not_macos) printf '%s' "Этот инструмент работает только на macOS." ;;
    en:not_macos) printf '%s' "This tool only runs on macOS." ;;

    ru:no_tty) printf '%s' "Нет управляющего терминала (/dev/tty). Запустите из Terminal.app или передайте --yes." ;;
    en:no_tty) printf '%s' "No controlling terminal (/dev/tty). Run from Terminal.app or pass --yes." ;;

    ru:need_ssh) printf '%s' "Не найден клиент ssh. Установите Command Line Tools." ;;
    en:need_ssh) printf '%s' "ssh client not found. Install Apple Command Line Tools." ;;

    ru:banner_title) printf '%s' "mac-remote-bridge — мастер удалённого доступа" ;;
    en:banner_title) printf '%s' "mac-remote-bridge — remote access setup" ;;

    ru:warn_title) printf '%s' "ВНИМАНИЕ: вы открываете временный удалённый доступ к этому Mac" ;;
    en:warn_title) printf '%s' "WARNING: you are opening temporary remote access to this Mac" ;;

    ru:does_header) printf '%s' "Скрипт выполнит следующее:" ;;
    en:does_header) printf '%s' "This script will:" ;;

    ru:does_1) printf '%s' "Включить Remote Login (SSH), если он выключен (нужен пароль администратора)." ;;
    en:does_1) printf '%s' "Enable Remote Login (SSH) if it is off (administrator password required)." ;;

    ru:does_2) printf '%s' "Создать зашифрованный обратный туннель через Pinggy (исходящий SSH на порт 443)." ;;
    en:does_2) printf '%s' "Open an encrypted reverse tunnel via Pinggy (outbound SSH to port 443)." ;;

    ru:does_3) printf '%s' "Показать готовые команды для оператора (SSH и, при желании, VNC)." ;;
    en:does_3) printf '%s' "Print ready-to-use operator commands (SSH and, optionally, VNC)." ;;

    ru:sec_header) printf '%s' "Безопасность:" ;;
    en:sec_header) printf '%s' "Security:" ;;

    ru:sec_1) printf '%s' "Вход по-прежнему требует пароль (или ключ) учётной записи этого Mac." ;;
    en:sec_1) printf '%s' "Login still requires this Mac account's password or SSH key." ;;

    ru:sec_2) printf '%s' "Бесплатный туннель Pinggy живёт около 60 минут и меняет адрес после обрыва." ;;
    en:sec_2) printf '%s' "A free Pinggy tunnel lasts about 60 minutes and changes address if it drops." ;;

    ru:sec_3) printf '%s' "Остановить доступ:  bridge.sh stop   или   pkill -f pinggy" ;;
    en:sec_3) printf '%s' "Stop access anytime:  bridge.sh stop   or   pkill -f pinggy" ;;

    ru:consent) printf '%s' "Открыть удалённый доступ? [Enter = да, Ctrl+C = отмена] " ;;
    en:consent) printf '%s' "Grant remote access? [Enter = yes, Ctrl+C = cancel] " ;;

    ru:vnc_ask) printf '%s' "Включить Демонстрацию экрана (VNC) для рабочего стола? [y/N] " ;;
    en:vnc_ask) printf '%s' "Also enable Screen Sharing (VNC) for desktop access? [y/N] " ;;

    ru:cancelled) printf '%s' "Отменено." ;;
    en:cancelled) printf '%s' "Cancelled." ;;

    ru:step_ssh) printf '%s' "[1/3] Проверка Remote Login (SSH)…" ;;
    en:step_ssh) printf '%s' "[1/3] Checking Remote Login (SSH)…" ;;

    ru:ssh_on) printf '%s' "SSH уже слушает порт 22." ;;
    en:ssh_on) printf '%s' "SSH is already listening on port 22." ;;

    ru:ssh_enabling) printf '%s' "Включаю Remote Login (запрос прав администратора)…" ;;
    en:ssh_enabling) printf '%s' "Enabling Remote Login (administrator prompt)…" ;;

    ru:ssh_ok) printf '%s' "SSH включён." ;;
    en:ssh_ok) printf '%s' "SSH is enabled." ;;

    ru:ssh_fail) printf '%s' "Не удалось включить SSH. Проверьте пароль и System Settings → General → Sharing → Remote Login." ;;
    en:ssh_fail) printf '%s' "Could not enable SSH. Check the password and System Settings → General → Sharing → Remote Login." ;;

    ru:step_vnc) printf '%s' "[2/3] Проверка Screen Sharing (VNC)…" ;;
    en:step_vnc) printf '%s' "[2/3] Checking Screen Sharing (VNC)…" ;;

    ru:vnc_on) printf '%s' "Screen Sharing уже слушает порт 5900." ;;
    en:vnc_on) printf '%s' "Screen Sharing is already listening on port 5900." ;;

    ru:vnc_skip) printf '%s' "[2/3] Screen Sharing пропущен (включите флагом --vnc)." ;;
    en:vnc_skip) printf '%s' "[2/3] Screen Sharing skipped (pass --vnc to enable)." ;;

    ru:vnc_ok) printf '%s' "Screen Sharing включён." ;;
    en:vnc_ok) printf '%s' "Screen Sharing is enabled." ;;

    ru:vnc_fail) printf '%s' "Не удалось включить Screen Sharing. SSH-туннель всё равно будет работать." ;;
    en:vnc_fail) printf '%s' "Could not enable Screen Sharing. The SSH tunnel will still work." ;;

    ru:step_tun) printf '%s' "[3/3] Запуск защищённого туннеля…" ;;
    en:step_tun) printf '%s' "[3/3] Starting the encrypted tunnel…" ;;

    ru:tun_ok) printf '%s' "Сессия удалённого доступа создана." ;;
    en:tun_ok) printf '%s' "Remote access session is up." ;;

    ru:tun_fail) printf '%s' "Не удалось поднять туннель. Проверьте интернет и доступ к Pinggy." ;;
    en:tun_fail) printf '%s' "Could not start the tunnel. Check the network and Pinggy reachability." ;;

    ru:ready) printf '%s' "Готово. Данные для оператора:" ;;
    en:ready) printf '%s' "Ready. Operator connection details:" ;;

    ru:already) printf '%s' "Туннель уже запущен. Используйте --force чтобы пересоздать." ;;
    en:already) printf '%s' "A tunnel is already running. Pass --force to replace it." ;;

    ru:not_running) printf '%s' "Активной сессии нет." ;;
    en:not_running) printf '%s' "No active session." ;;

    ru:stopped) printf '%s' "Туннель остановлен." ;;
    en:stopped) printf '%s' "Tunnel stopped." ;;

    ru:reverted) printf '%s' "Службы, которые включал этот инструмент, выключены." ;;
    en:reverted) printf '%s' "Services previously enabled by this tool have been turned off." ;;

    ru:copied) printf '%s' "SSH-команда скопирована в буфер обмена." ;;
    en:copied) printf '%s' "SSH command copied to the clipboard." ;;

    ru:close_ok) printf '%s' "Окно Terminal можно закрыть — туннель останется в фоне." ;;
    en:close_ok) printf '%s' "You can close Terminal — the tunnel keeps running in the background." ;;

    ru:next) printf '%s' "Управление:" ;;
    en:next) printf '%s' "Manage this session:" ;;

    *) printf '%s' "${key}" ;;
  esac
}

say()  { [ "${QUIET}" -eq 1 ] || printf '%b\n' "$*"; }
ok()   { say "${GREEN}✓${NC} $*"; }
warn() { say "${YELLOW}!${NC} $*" >&2; }
err()  { printf '%b\n' "${RED}✗${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

hr() {
  say "${CYAN}============================================================${NC}"
}

# ---------------------------------------------------------------------------
# Paths / small helpers
# ---------------------------------------------------------------------------
init_paths() {
  SESSION_FILE="${STATE_DIR}/session"
  RUN_FILE="${STATE_DIR}/run"
  LOG_FILE="${STATE_DIR}/tunnel.log"
  SSH_PID_FILE="${STATE_DIR}/ssh.pid"
  SUP_PID_FILE="${STATE_DIR}/supervisor.pid"
  SUPERVISE_SCRIPT="${STATE_DIR}/supervise.sh"
  KNOWN_HOSTS="${STATE_DIR}/known_hosts"
  ENABLED_FILE="${STATE_DIR}/enabled"
  USER_NAME=$(id -un)
}

ensure_state_dir() {
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}" 2>/dev/null || true
}

is_macos() {
  [ "$(uname -s)" = "Darwin" ]
}

require_macos() {
  if ! is_macos; then
    die "$(t not_macos)"
  fi
}

have_tty() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

is_alive() {
  local pid="${1:-}"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null
}

read_kv() {
  local key="$1"
  local file="${2:-$SESSION_FILE}"
  [ -f "${file}" ] || return 0
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "${file}"
}

write_kv_file() {
  local file="$1"
  shift
  local tmp
  tmp=$(mktemp "${STATE_DIR}/tmp.XXXXXX")
  printf '%s\n' "$@" > "${tmp}"
  mv -f "${tmp}" "${file}"
  chmod 600 "${file}" 2>/dev/null || true
}

port_is_open() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    # macOS nc supports -G (seconds); GNU nc supports -w. Try both.
    nc -z -G 2 "${host}" "${port}" >/dev/null 2>&1 \
      || nc -z -w 2 "${host}" "${port}" >/dev/null 2>&1
    return $?
  fi
  # Last-resort bash /dev/tcp (may be compiled out).
  (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

wait_port() {
  local host="$1"
  local port="$2"
  local tries="${3:-20}"
  local i=0
  while [ "${i}" -lt "${tries}" ]; do
    if port_is_open "${host}" "${port}"; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

session_active() {
  local sup sshpid
  sup=$(read_kv supervisor_pid 2>/dev/null || true)
  sshpid=$(read_kv ssh_pid 2>/dev/null || true)
  if [ -f "${SUP_PID_FILE}" ]; then
    sup=$(cat "${SUP_PID_FILE}" 2>/dev/null || true)
  fi
  if [ -f "${SSH_PID_FILE}" ]; then
    sshpid=$(cat "${SSH_PID_FILE}" 2>/dev/null || true)
  fi
  if is_alive "${sup}" || is_alive "${sshpid}"; then
    return 0
  fi
  return 1
}

clean_stale() {
  if session_active; then
    return 0
  fi
  rm -f "${RUN_FILE}" "${SSH_PID_FILE}" "${SUP_PID_FILE}"
  if [ -f "${SESSION_FILE}" ]; then
    local st
    st=$(read_kv status || true)
    if [ "${st}" = "up" ]; then
      write_kv_file "${SESSION_FILE}" \
        "status=stale" \
        "user=$(read_kv user || true)" \
        "host=$(read_kv host || true)" \
        "port=$(read_kv port || true)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Tunnel log parser (unit-tested via __selftest)
# ---------------------------------------------------------------------------
# Sets PARSE_HOST and PARSE_PORT from a Pinggy / OpenSSH log file.
parse_tunnel_log() {
  local log="$1"
  PARSE_HOST=""
  PARSE_PORT=""
  [ -f "${log}" ] || return 1

  local line

  line=$(grep -oE 'tcp://[A-Za-z0-9._-]+:[0-9]+' "${log}" 2>/dev/null | tail -n 1 || true)
  if [ -n "${line}" ]; then
    PARSE_HOST=$(printf '%s' "${line}" | sed -E 's#^tcp://([^:]+):[0-9]+$#\1#')
    PARSE_PORT=$(printf '%s' "${line}" | sed -E 's#^tcp://[^:]+:([0-9]+)$#\1#')
    _valid_parse && return 0
  fi

  line=$(grep -oE 'Allocated port [0-9]+' "${log}" 2>/dev/null | tail -n 1 || true)
  if [ -n "${line}" ]; then
    PARSE_PORT=$(printf '%s' "${line}" | awk '{print $3}')
    PARSE_HOST="${BROKER_HOST}"
    case "${PARSE_HOST}" in
      free.pinggy.io) PARSE_HOST="a.pinggy.io" ;;
    esac
    _valid_parse && return 0
  fi

  line=$(grep -oE 'ssh -p [0-9]+ [^[:space:]]+@[A-Za-z0-9._-]+' "${log}" 2>/dev/null | tail -n 1 || true)
  if [ -n "${line}" ]; then
    PARSE_PORT=$(printf '%s' "${line}" | awk '{print $3}')
    PARSE_HOST=$(printf '%s' "${line}" | awk '{print $4}' | awk -F@ '{print $NF}')
    _valid_parse && return 0
  fi

  return 1
}

_valid_parse() {
  case "${PARSE_PORT}" in
    ''|*[!0-9]*) PARSE_HOST=""; PARSE_PORT=""; return 1 ;;
  esac
  [ "${PARSE_PORT}" -gt 0 ] && [ "${PARSE_PORT}" -lt 65536 ] || return 1
  [ -n "${PARSE_HOST}" ] || return 1
  return 0
}

build_pinggy_target() {
  local user="${DEFAULT_BROKER_USER}"
  local host="${BROKER_HOST}"
  local prefix=""

  if [ -n "${PINGGY_TOKEN}" ]; then
    case "${PINGGY_TOKEN}" in
      *[!A-Za-z0-9_-]*) die "Invalid PINGGY_TOKEN (expected alphanumeric)." ;;
    esac
    prefix="${PINGGY_TOKEN}+"
    case "${host}" in
      free.pinggy.io|a.pinggy.io) host="pro.pinggy.io" ;;
    esac
  fi

  if [ -n "${ALLOW_IP}" ]; then
    case "${ALLOW_IP}" in
      *[!0-9./]*) die "Invalid --allow-ip (expected IPv4 or CIDR)." ;;
    esac
    user="w:${ALLOW_IP}+${user}"
  fi

  printf '%s%s@%s' "${prefix}" "${user}" "${host}"
}

# ---------------------------------------------------------------------------
# macOS services
# ---------------------------------------------------------------------------
ssh_listening() {
  port_is_open 127.0.0.1 22
}

vnc_listening() {
  port_is_open 127.0.0.1 5900
}

sudo_begin() {
  if sudo -n true >/dev/null 2>&1; then
    return 0
  fi
  if ! have_tty; then
    die "$(t no_tty)"
  fi
  # Force the password prompt onto the real keyboard, even under curl | bash.
  sudo -v </dev/tty >/dev/tty 2>/dev/tty
}

ensure_ssh_acl() {
  if ! dseditgroup -o read com.apple.access_ssh >/dev/null 2>&1; then
    return 0
  fi
  if dseditgroup -o checkmember -m "${USER_NAME}" com.apple.access_ssh >/dev/null 2>&1; then
    return 0
  fi
  sudo_begin
  sudo dseditgroup -o edit -a "${USER_NAME}" -t user com.apple.access_ssh >/dev/null 2>&1 || true
}

mark_enabled() {
  local key="$1"
  touch "${ENABLED_FILE}"
  if ! grep -qx "${key}" "${ENABLED_FILE}" 2>/dev/null; then
    printf '%s\n' "${key}" >> "${ENABLED_FILE}"
  fi
}

was_enabled_by_us() {
  local key="$1"
  [ -f "${ENABLED_FILE}" ] && grep -qx "${key}" "${ENABLED_FILE}" 2>/dev/null
}

enable_remote_login() {
  if ssh_listening; then
    ok "$(t ssh_on)"
    ensure_ssh_acl
    return 0
  fi

  say "${BOLD}$(t ssh_enabling)${NC}"
  sudo_begin

  # Official toggle — also updates System Settings → Sharing.
  sudo /usr/sbin/systemsetup -f -setremotelogin on >/dev/null 2>&1 || \
    sudo /usr/sbin/systemsetup -setremotelogin on >/dev/null 2>&1 || true

  # Fallbacks for hosts where systemsetup is restricted (FDA / newer macOS).
  if ! ssh_listening; then
    sudo launchctl enable system/com.openssh.sshd >/dev/null 2>&1 || true
    sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
    sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
    sudo launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
  fi

  ensure_ssh_acl

  if wait_port 127.0.0.1 22 40; then
    mark_enabled ssh
    ok "$(t ssh_ok)"
    return 0
  fi
  die "$(t ssh_fail)"
}

enable_screen_sharing() {
  if vnc_listening; then
    ok "$(t vnc_on)"
    return 0
  fi

  sudo_begin

  sudo launchctl enable system/com.apple.screensharing >/dev/null 2>&1 || true
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
  sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
  sudo launchctl kickstart -k system/com.apple.screensharing >/dev/null 2>&1 || true

  local kickstart="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
  if [ -x "${kickstart}" ] && ! vnc_listening; then
    # Enable Screen Sharing only — not full ARD "all privileges".
    sudo "${kickstart}" -activate -configure -access -on -restart -agent >/dev/null 2>&1 || true
  fi

  if wait_port 127.0.0.1 5900 40; then
    mark_enabled vnc
    ok "$(t vnc_ok)"
    return 0
  fi
  warn "$(t vnc_fail)"
  return 1
}

disable_remote_login() {
  sudo_begin
  sudo /usr/sbin/systemsetup -f -setremotelogin off >/dev/null 2>&1 || \
    sudo /usr/sbin/systemsetup -setremotelogin off >/dev/null 2>&1 || true
}

disable_screen_sharing() {
  sudo_begin
  sudo launchctl bootout system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
  sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
  sudo launchctl disable system/com.apple.screensharing >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Supervisor (standalone — works even when this script was curl | bash)
# ---------------------------------------------------------------------------
write_supervisor() {
  local target="$1"
  local old_umask
  ensure_state_dir
  old_umask=$(umask)
  umask 077

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -u'
    printf '%s\n' "trap '' HUP"
    printf 'STATE_DIR=%s\n' "$(shquote "${STATE_DIR}")"
    printf 'TARGET=%s\n' "$(shquote "${target}")"
    printf 'USER_NAME=%s\n' "$(shquote "${USER_NAME}")"
    cat <<'EOS'
LOG="$STATE_DIR/tunnel.log"
RUN="$STATE_DIR/run"
SESSION="$STATE_DIR/session"
SSH_PID_FILE="$STATE_DIR/ssh.pid"
KNOWN_HOSTS="$STATE_DIR/known_hosts"

cleanup() {
  rm -f "$RUN"
  if [ -n "${ssh_pid:-}" ]; then
    kill "$ssh_pid" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup TERM INT

write_session() {
  local status="$1" host="$2" port="$3" pid="$4"
  local tmp
  tmp=$(mktemp "$STATE_DIR/sess.XXXXXX")
  cat >"$tmp" <<EOF
status=$status
user=$USER_NAME
host=$host
port=$port
ssh_pid=$pid
supervisor_pid=$$
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ssh_cmd=ssh -p $port $USER_NAME@$host
vnc_cmd=ssh -L 5900:127.0.0.1:5900 -p $port $USER_NAME@$host
target=$TARGET
EOF
  mv -f "$tmp" "$SESSION"
  chmod 600 "$SESSION" 2>/dev/null || true
}

parse_log() {
  PARSE_HOST=""
  PARSE_PORT=""
  local line
  line=$(grep -oE 'tcp://[A-Za-z0-9._-]+:[0-9]+' "$LOG" 2>/dev/null | tail -n 1)
  if [ -n "$line" ]; then
    PARSE_HOST=${line#tcp://}
    PARSE_PORT=${PARSE_HOST##*:}
    PARSE_HOST=${PARSE_HOST%:*}
    return 0
  fi
  line=$(grep -oE 'Allocated port [0-9]+' "$LOG" 2>/dev/null | tail -n 1)
  if [ -n "$line" ]; then
    PARSE_PORT=$(printf '%s' "$line" | awk '{print $3}')
    PARSE_HOST="a.pinggy.io"
    return 0
  fi
  line=$(grep -oE 'ssh -p [0-9]+ [^[:space:]]+@[A-Za-z0-9._-]+' "$LOG" 2>/dev/null | tail -n 1)
  if [ -n "$line" ]; then
    PARSE_PORT=$(printf '%s' "$line" | awk '{print $3}')
    PARSE_HOST=$(printf '%s' "$line" | awk '{print $4}' | awk -F@ '{print $NF}')
    return 0
  fi
  return 1
}

fails=0
while [ -f "$RUN" ]; do
  : >"$LOG"
  ssh -F /dev/null -p 443 -N -T -n \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o LogLevel=ERROR \
    -R0:127.0.0.1:22 \
    "$TARGET" >>"$LOG" 2>&1 &
  ssh_pid=$!
  printf '%s\n' "$ssh_pid" >"$SSH_PID_FILE"

  got=0
  i=0
  while [ "$i" -lt 40 ]; do
    if ! kill -0 "$ssh_pid" 2>/dev/null; then
      break
    fi
    if parse_log; then
      write_session up "$PARSE_HOST" "$PARSE_PORT" "$ssh_pid"
      command -v logger >/dev/null 2>&1 && logger -t mac-remote-bridge "tunnel up $PARSE_HOST:$PARSE_PORT"
      got=1
      fails=0
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done

  if [ "$got" -eq 0 ]; then
    kill "$ssh_pid" 2>/dev/null || true
    wait "$ssh_pid" 2>/dev/null || true
    fails=$((fails + 1))
    if [ "$fails" -ge 3 ]; then
      write_session failed "" "" ""
      exit 1
    fi
    sleep 2
    continue
  fi

  wait "$ssh_pid" 2>/dev/null || true
  write_session down "$PARSE_HOST" "$PARSE_PORT" ""
  [ -f "$RUN" ] || break
  sleep 2
done
exit 0
EOS
  } > "${SUPERVISE_SCRIPT}"
  chmod 700 "${SUPERVISE_SCRIPT}"
}

stop_internal() {
  rm -f "${RUN_FILE}"
  local pid
  if [ -f "${SUP_PID_FILE}" ]; then
    pid=$(cat "${SUP_PID_FILE}" 2>/dev/null || true)
    if is_alive "${pid}"; then
      kill "${pid}" 2>/dev/null || true
      sleep 0.2
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi
  if [ -f "${SSH_PID_FILE}" ]; then
    pid=$(cat "${SSH_PID_FILE}" 2>/dev/null || true)
    if is_alive "${pid}"; then
      kill "${pid}" 2>/dev/null || true
      sleep 0.2
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi
  # Belt and suspenders: only our supervise.sh / recorded pids, never pkill -f.
  rm -f "${SSH_PID_FILE}" "${SUP_PID_FILE}" "${RUN_FILE}"
  if [ -f "${SESSION_FILE}" ]; then
    write_kv_file "${SESSION_FILE}" \
      "status=stopped" \
      "user=${USER_NAME}" \
      "stopped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
}

print_card() {
  local host port user
  user=$(read_kv user)
  host=$(read_kv host)
  port=$(read_kv port)
  [ -n "${user}" ] || user="${USER_NAME}"

  local ssh_cmd vnc_cmd
  ssh_cmd="ssh -p ${port} ${user}@${host}"
  vnc_cmd="ssh -L 5900:127.0.0.1:5900 -p ${port} ${user}@${host}"

  say ""
  hr
  say "${GREEN}${BOLD}  $(t ready)${NC}"
  hr
  say "  $( [ "${LANG_CODE}" = ru ] && printf '%s' 'Пользователь' || printf '%s' 'User' ):              ${CYAN}${BOLD}${user}${NC}"
  say "  $( [ "${LANG_CODE}" = ru ] && printf '%s' 'Хост' || printf '%s' 'Host' ):                   ${CYAN}${BOLD}${host}${NC}"
  say "  $( [ "${LANG_CODE}" = ru ] && printf '%s' 'Порт' || printf '%s' 'Port' ):                   ${CYAN}${BOLD}${port}${NC}"
  say ""
  say "  ${BOLD}1. SSH${NC}"
  say "     ${YELLOW}${ssh_cmd}${NC}"
  say ""
  say "  ${BOLD}2. VNC / Screen Sharing${NC}"
  say "     ${YELLOW}${vnc_cmd}${NC}"
  say "     $( [ "${LANG_CODE}" = ru ] && printf '%s' 'Затем Finder → Cmd+K →' || printf '%s' 'Then Finder → Cmd+K →' ) ${CYAN}vnc://127.0.0.1:5900${NC}"
  hr
  say ""
}

copy_clipboard() {
  local cmd="$1"
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "${cmd}" | pbcopy 2>/dev/null && ok "$(t copied)" || true
  fi
}

notify_os() {
  local host="$1" port="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"ssh -p ${port} ${USER_NAME}@${host}\" with title \"mac-remote-bridge\" subtitle \"Remote access is up\"" >/dev/null 2>&1 || true
  fi
}

print_status_json() {
  local status host port user pid started
  status=$(read_kv status)
  user=$(read_kv user)
  host=$(read_kv host)
  port=$(read_kv port)
  pid=$(read_kv ssh_pid)
  started=$(read_kv started_at)
  if session_active; then
    status="up"
  elif [ "${status}" = "up" ]; then
    status="stale"
  fi
  [ -n "${status}" ] || status="stopped"
  printf '{"status":"%s","user":"%s","host":"%s","port":%s,"pid":%s,"started_at":"%s","version":"%s"}\n' \
    "$(json_escape "${status}")" \
    "$(json_escape "${user}")" \
    "$(json_escape "${host}")" \
    "${port:-null}" \
    "${pid:-null}" \
    "$(json_escape "${started}")" \
    "${VERSION}"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
prompt_consent() {
  if [ "${ASSUME_YES}" -eq 1 ]; then
    return 0
  fi
  if ! have_tty; then
    die "$(t no_tty)"
  fi
  local reply=""
  printf '%b' "${BOLD}$(t consent)${NC}" >/dev/tty
  # IFS= preserves empty Enter. Always read the keyboard, never the curl pipe.
  IFS= read -r reply </dev/tty || true
  case "${reply}" in
    ""|y|Y|yes|YES|да|Да) return 0 ;;
    *) say "$(t cancelled)"; exit 1 ;;
  esac
}

prompt_vnc() {
  [ "${VNC_FLAG}" -eq 1 ] && return 0
  [ "${ASSUME_YES}" -eq 1 ] && return 0
  have_tty || return 0
  local reply=""
  printf '%b' "${BOLD}$(t vnc_ask)${NC}" >/dev/tty
  IFS= read -r reply </dev/tty || true
  case "${reply}" in
    y|Y|yes|YES|д|Д|да|Да) WANT_VNC=1 ;;
  esac
}

persist_self() {
  local src="${BASH_SOURCE[0]:-}"
  if [ -n "${src}" ] && [ -f "${src}" ] && [ -r "${src}" ]; then
    cp "${src}" "${STATE_DIR}/bridge.sh"
    chmod 700 "${STATE_DIR}/bridge.sh"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${RAW_URL}" -o "${STATE_DIR}/bridge.sh" 2>/dev/null || true
    [ -f "${STATE_DIR}/bridge.sh" ] && chmod 700 "${STATE_DIR}/bridge.sh"
  fi
}

cmd_start() {
  require_macos
  command -v ssh >/dev/null 2>&1 || die "$(t need_ssh)"
  ensure_state_dir
  clean_stale

  if session_active && [ "${FORCE}" -eq 0 ]; then
    warn "$(t already)"
    cmd_status
    return 0
  fi
  if session_active && [ "${FORCE}" -eq 1 ]; then
    stop_internal
  fi

  say ""
  hr
  say "${CYAN}${BOLD}  $(t banner_title)${NC}  ${DIM}v${VERSION}${NC}"
  hr
  say ""
  say "${RED}${BOLD}$(t warn_title)${NC}"
  say ""
  say "${BOLD}$(t does_header)${NC}"
  say "  1. $(t does_1)"
  say "  2. $(t does_2)"
  say "  3. $(t does_3)"
  say ""
  say "${BOLD}$(t sec_header)${NC}"
  say "  • $(t sec_1)"
  say "  • $(t sec_2)"
  say "  • $(t sec_3)"
  say ""

  prompt_consent
  prompt_vnc

  say ""
  say "${BOLD}$(t step_ssh)${NC}"
  enable_remote_login

  if [ "${WANT_VNC}" -eq 1 ]; then
    say ""
    say "${BOLD}$(t step_vnc)${NC}"
    enable_screen_sharing || true
  else
    say ""
    say "${BOLD}$(t vnc_skip)${NC}"
  fi

  say ""
  say "${BOLD}$(t step_tun)${NC}"

  local target
  target=$(build_pinggy_target)

  persist_self
  write_supervisor "${target}"
  : > "${LOG_FILE}"
  printf '%s\n' "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${RUN_FILE}"
  printf '%s\n' "${VERSION}" > "${STATE_DIR}/version"

  if [ "${FOREGROUND}" -eq 1 ]; then
    # Run the supervisor in the foreground so Ctrl+C tears it down.
    trap 'stop_internal; exit 130' INT TERM
    bash "${SUPERVISE_SCRIPT}"
    return 0
  fi

  nohup bash "${SUPERVISE_SCRIPT}" </dev/null >/dev/null 2>&1 &
  local sup_pid=$!
  printf '%s\n' "${sup_pid}" > "${SUP_PID_FILE}"
  disown "${sup_pid}" 2>/dev/null || true

  local i=0
  local ready=0
  while [ "${i}" -lt 50 ]; do
    if [ "$(read_kv status)" = "up" ] && session_active; then
      ready=1
      break
    fi
    if [ "$(read_kv status)" = "failed" ] || ! is_alive "${sup_pid}"; then
      break
    fi
    sleep 0.4
    i=$((i + 1))
  done

  if [ "${ready}" -ne 1 ]; then
    err "$(t tun_fail)"
    if [ -s "${LOG_FILE}" ]; then
      say ""
      say "${DIM}---- tunnel log ----${NC}"
      tail -n 40 "${LOG_FILE}" || true
    fi
    stop_internal
    exit 1
  fi

  ok "$(t tun_ok)"
  ok "$(t close_ok)"
  print_card
  copy_clipboard "$(read_kv ssh_cmd)"
  notify_os "$(read_kv host)" "$(read_kv port)"

  say "${BOLD}$(t next)${NC}"
  say "  ${CYAN}${STATE_DIR}/bridge.sh status${NC}"
  say "  ${CYAN}${STATE_DIR}/bridge.sh stop${NC}"
  say "  ${CYAN}${STATE_DIR}/bridge.sh logs${NC}"
  say ""
}

cmd_stop() {
  ensure_state_dir
  if ! session_active; then
    clean_stale
    say "$(t not_running)"
    return 0
  fi
  stop_internal
  ok "$(t stopped)"
  if [ -f "${ENABLED_FILE}" ]; then
    if [ "${LANG_CODE}" = ru ]; then
      say "  Чтобы выключить службы, которые включил этот запуск: ${CYAN}${STATE_DIR}/bridge.sh revert${NC}"
    else
      say "  To disable services this run turned on: ${CYAN}${STATE_DIR}/bridge.sh revert${NC}"
    fi
  fi
}

cmd_status() {
  ensure_state_dir
  clean_stale
  if [ "${JSON}" -eq 1 ]; then
    print_status_json
    return 0
  fi
  if ! session_active; then
    say "$(t not_running)"
    return 0
  fi
  print_card
  local pid started
  pid=$(read_kv ssh_pid)
  started=$(read_kv started_at)
  say "  pid=${pid}  started=${started}  state=${STATE_DIR}"
  say ""
}

cmd_logs() {
  ensure_state_dir
  [ -f "${LOG_FILE}" ] || die "$(t not_running)"
  tail -n 80 -f "${LOG_FILE}"
}

cmd_revert() {
  require_macos
  ensure_state_dir
  stop_internal
  local did=0
  if was_enabled_by_us vnc; then
    disable_screen_sharing || true
    did=1
  fi
  if was_enabled_by_us ssh; then
    disable_remote_login || true
    did=1
  fi
  rm -f "${ENABLED_FILE}"
  if [ "${did}" -eq 1 ]; then
    ok "$(t reverted)"
  else
    say "$(t not_running)"
  fi
}

cmd_doctor() {
  printf '%s\n' "mac-remote-bridge doctor v${VERSION}"
  printf '%s\n' "os:           $(uname -s) $(uname -m) $(uname -r)"
  printf '%s\n' "bash:         ${BASH_VERSION}"
  printf '%s\n' "user:         $(id -un)"
  printf '%s\n' "state:        ${STATE_DIR}"
  printf '%s\n' "lang:         ${LANG_CODE}"

  if ! is_macos; then
    printf '%s\n' "macos:        NO — start/revert are disabled on this OS"
  else
    printf '%s\n' "macos:        yes"
    if command -v sw_vers >/dev/null 2>&1; then
      printf '%s\n' "product:      $(sw_vers -productName) $(sw_vers -productVersion)"
    fi
  fi

  if command -v ssh >/dev/null 2>&1; then
    printf '%s\n' "ssh:          $(command -v ssh) ($(ssh -V 2>&1 | tr -d '\n'))"
  else
    printf '%s\n' "ssh:          MISSING"
  fi

  if command -v nc >/dev/null 2>&1; then
    printf '%s\n' "nc:           $(command -v nc)"
  else
    printf '%s\n' "nc:           missing (port checks will use /dev/tcp)"
  fi

  if ssh_listening; then
    printf '%s\n' "sshd :22:     listening"
  else
    printf '%s\n' "sshd :22:     not listening"
  fi
  if vnc_listening; then
    printf '%s\n' "vnc  :5900:   listening"
  else
    printf '%s\n' "vnc  :5900:   not listening"
  fi

  if is_macos && command -v fdesetup >/dev/null 2>&1; then
    printf '%s\n' "filevault:    $(fdesetup status 2>/dev/null | head -n 1)"
  fi

  if is_macos && dseditgroup -o read com.apple.access_ssh >/dev/null 2>&1; then
    if dseditgroup -o checkmember -m "$(id -un)" com.apple.access_ssh >/dev/null 2>&1; then
      printf '%s\n' "ssh acl:      com.apple.access_ssh contains $(id -un)"
    else
      printf '%s\n' "ssh acl:      WARNING — $(id -un) is not in com.apple.access_ssh"
    fi
  else
    printf '%s\n' "ssh acl:      all users (group absent)"
  fi

  local broker="${BROKER_HOST}"
  if port_is_open "${broker}" 443 || port_is_open a.pinggy.io 443; then
    printf '%s\n' "pinggy:443:   reachable"
  else
    printf '%s\n' "pinggy:443:   UNREACHABLE — tunnel start will fail"
  fi

  clean_stale
  if session_active; then
    printf '%s\n' "session:      UP  $(read_kv user)@$(read_kv host):$(read_kv port)"
  else
    printf '%s\n' "session:      none"
  fi
}

usage() {
  cat <<EOF
mac-remote-bridge ${VERSION}
Zero-config remote SSH (and optional VNC) for macOS, via a Pinggy tunnel.

Usage:
  bridge.sh [command] [options]

Commands:
  start       Enable Remote Login and open a background tunnel (default)
  stop        Close the tunnel (does not disable SSH/VNC)
  status      Show the current connection details
  logs        Follow the tunnel log
  revert      Stop the tunnel and disable SSH/VNC if this tool enabled them
  doctor      Print diagnostics
  help        Show this help

Options:
  -y, --yes           Skip the confirmation prompt
      --vnc           Enable Screen Sharing (VNC) as well
      --no-vnc        Do not enable Screen Sharing (default)
      --token TOKEN   Pinggy Pro token (or set PINGGY_TOKEN)
      --allow-ip CIDR Restrict the broker to this client IPv4/CIDR
      --force         Replace an existing session
      --foreground    Keep the tunnel in this terminal (Ctrl+C stops it)
      --lang en|ru    Force UI language
      --json          Machine-readable status
  -q, --quiet         Less output
  -h, --help
  -V, --version

Quick start (review first, then run):
  curl -fsSL ${RAW_URL} -o /tmp/bridge.sh
  less /tmp/bridge.sh
  bash /tmp/bridge.sh

One-liner (stdin is NOT treated as consent; prompts use /dev/tty):
  bash -c "\$(curl -fsSL ${RAW_URL})"

Stop:
  ~/.mac-remote-bridge/bridge.sh stop
  pkill -f pinggy          # still works as a last resort
EOF
}

# ---------------------------------------------------------------------------
# Self-test (no macOS required — used by CI)
# ---------------------------------------------------------------------------
cmd_selftest() {
  local tmp fails=0
  tmp=$(mktemp -d /tmp/mrb-selftest.XXXXXX)
  # Isolate state so tests never touch a real session.
  STATE_DIR="${tmp}/state"
  BROKER_HOST="free.pinggy.io"
  init_paths
  ensure_state_dir

  _expect() {
    local name="$1" got="$2" want="$3"
    if [ "${got}" = "${want}" ]; then
      printf '  PASS  %s\n' "${name}"
    else
      printf '  FAIL  %s  got=%s want=%s\n' "${name}" "${got}" "${want}"
      fails=$((fails + 1))
    fi
  }

  # tcp:// URL (current Pinggy TCP tunnel format)
  printf '%s\n' 'Welcome' 'tcp://abc123.a.pinggy.link:40123' 'Enjoy' > "${tmp}/tcp.log"
  parse_tunnel_log "${tmp}/tcp.log"
  _expect "parse tcp host" "${PARSE_HOST}" "abc123.a.pinggy.link"
  _expect "parse tcp port" "${PARSE_PORT}" "40123"

  # Classic OpenSSH "Allocated port"
  printf '%s\n' 'Allocated port 51234 for remote forward to localhost:22' > "${tmp}/alloc.log"
  parse_tunnel_log "${tmp}/alloc.log"
  _expect "parse allocated host" "${PARSE_HOST}" "a.pinggy.io"
  _expect "parse allocated port" "${PARSE_PORT}" "51234"

  # Fallback ssh -p line
  printf '%s\n' 'Connect with: ssh -p 2222 bob@r4nd0m.a.pinggy.link' > "${tmp}/ssh.log"
  parse_tunnel_log "${tmp}/ssh.log"
  _expect "parse ssh host" "${PARSE_HOST}" "r4nd0m.a.pinggy.link"
  _expect "parse ssh port" "${PARSE_PORT}" "2222"

  # Ignore http(s) URLs — those are HTTP tunnels, not SSH.
  printf '%s\n' 'https://abc.a.pinggy.link' 'http://abc.a.pinggy.link' > "${tmp}/http.log"
  if parse_tunnel_log "${tmp}/http.log"; then
    printf '  FAIL  http urls must not parse\n'
    fails=$((fails + 1))
  else
    printf '  PASS  http urls ignored\n'
  fi

  # Reject out-of-range ports
  printf '%s\n' 'tcp://host.example:99999' > "${tmp}/badport.log"
  if parse_tunnel_log "${tmp}/badport.log"; then
    printf '  FAIL  bad port must not parse\n'
    fails=$((fails + 1))
  else
    printf '  PASS  bad port rejected\n'
  fi

  PINGGY_TOKEN=""
  ALLOW_IP=""
  BROKER_HOST="free.pinggy.io"
  _expect "target default" "$(build_pinggy_target)" "tcp@free.pinggy.io"

  ALLOW_IP="203.0.113.0/24"
  _expect "target allow-ip" "$(build_pinggy_target)" "w:203.0.113.0/24+tcp@free.pinggy.io"
  ALLOW_IP=""

  PINGGY_TOKEN="tok_test-1"
  _expect "target token" "$(build_pinggy_target)" "tok_test-1+tcp@pro.pinggy.io"
  PINGGY_TOKEN=""

  _expect "json escape" "$(json_escape 'a"b\c')" 'a\"b\\c'
  _expect "shquote" "$(shquote "it's")" "'it'\\''s'"

  write_supervisor "tcp@free.pinggy.io"
  if [ -x "${SUPERVISE_SCRIPT}" ] && grep -q 'ExitOnForwardFailure' "${SUPERVISE_SCRIPT}"; then
    printf '  PASS  supervisor written\n'
  else
    printf '  FAIL  supervisor written\n'
    fails=$((fails + 1))
  fi

  # bash -n on generated supervisor
  if bash -n "${SUPERVISE_SCRIPT}"; then
    printf '  PASS  supervisor syntax\n'
  else
    printf '  FAIL  supervisor syntax\n'
    fails=$((fails + 1))
  fi

  rm -rf "${tmp}"
  if [ "${fails}" -ne 0 ]; then
    printf '\nselftest: %s failure(s)\n' "${fails}"
    exit 1
  fi
  printf '\nselftest: ok\n'
}

# ---------------------------------------------------------------------------
# Args + main
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      start|stop|status|logs|revert|doctor|help)
        CMD="$1"
        shift
        ;;
      __selftest)
        CMD="selftest"
        shift
        ;;
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      --vnc)
        WANT_VNC=1
        VNC_FLAG=1
        shift
        ;;
      --no-vnc)
        WANT_VNC=0
        VNC_FLAG=1
        shift
        ;;
      --token)
        [ $# -ge 2 ] || die "--token requires an argument"
        PINGGY_TOKEN="$2"
        shift 2
        ;;
      --token=*)
        PINGGY_TOKEN="${1#--token=}"
        shift
        ;;
      --allow-ip)
        [ $# -ge 2 ] || die "--allow-ip requires an argument"
        ALLOW_IP="$2"
        shift 2
        ;;
      --allow-ip=*)
        ALLOW_IP="${1#--allow-ip=}"
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --foreground)
        FOREGROUND=1
        shift
        ;;
      --lang)
        [ $# -ge 2 ] || die "--lang requires en or ru"
        LANG_CODE=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
        shift 2
        ;;
      --lang=*)
        LANG_CODE=$(printf '%s' "${1#--lang=}" | tr '[:upper:]' '[:lower:]')
        shift
        ;;
      --json)
        JSON=1
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      -h|--help)
        CMD="help"
        shift
        ;;
      -V|--version)
        printf '%s\n' "${VERSION}"
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1  (try --help)"
        ;;
      *)
        die "Unknown command: $1  (try --help)"
        ;;
    esac
  done
}

main() {
  init_colors
  parse_args "$@"
  detect_lang
  init_paths

  case "${CMD}" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    logs)     cmd_logs ;;
    revert)   cmd_revert ;;
    doctor)   cmd_doctor ;;
    help)     usage ;;
    selftest) cmd_selftest ;;
    *)        usage; exit 2 ;;
  esac
}

main "$@"
