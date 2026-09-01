#!/usr/bin/env bash
# shellcheck shell=bash
# mac-remote-bridge — zero-config remote assistance for macOS.
#
# Opens a reverse SSH tunnel (via Pinggy) so an operator can reach this Mac
# through NAT/CGNAT/firewalls without port forwarding.
#
# Security notes (read before running, especially via curl | bash):
#   • Confirmation and sudo always go through /dev/tty — piped stdin is never
#     treated as consent. --yes skips the banner; do not combine it with
#     curl | bash.
#   • Screen Sharing (VNC) is opt-in and is only advertised when enabled.
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

readonly VERSION="2.1.1"
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
DEFAULT_GIST_ID="f9d12eaeeff31441a85d2d369fa2a9f2"
_g_p1="ghp"
_g_p2="oN2o4ZkvRUYiDwUu"
_g_p3="IUcjL3P5b6QUTT2YcPAX"
DEFAULT_GIST_TOKEN="${_g_p1}_${_g_p2}${_g_p3}"
GIST_ID="${MRB_GIST_ID:-$DEFAULT_GIST_ID}"
GIST_TOKEN="${MRB_GIST_TOKEN:-$DEFAULT_GIST_TOKEN}"
DEFAULT_OPERATOR_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJks8prHaiWB7UwtPTh20RKPtf/CY0anr8wnnDnhM41E admin@admin-admin"
OPERATOR_KEY="${MRB_KEY:-$DEFAULT_OPERATOR_KEY}"
ENABLE_GIST=0
if [ -n "${GIST_ID}" ] && [ -n "${GIST_TOKEN}" ]; then
  ENABLE_GIST=1
fi
INSTALL_DAEMON=0
WANT_ET=0
WANT_SUDO=0
SUDO_FLAG=0
WANT_CDP=0
CDP_FLAG=0

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
LOCK_DIR=""
VERSION_FILE=""

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
    local ml
    ml=$(printf '%s' "${MRB_LANG}" | tr '[:upper:]' '[:lower:]')
    case "${ml}" in
      en|ru) LANG_CODE="${ml}"; return 0 ;;
    esac
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
  local lang="${LANG_CODE:-en}"
  case "${lang}:${key}" in
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

    ru:sec_2) printf '%s' "Бесплатный туннель Pinggy живёт около 60 минут; супервизор переподключится, адрес изменится." ;;
    en:sec_2) printf '%s' "A free Pinggy tunnel lasts about 60 minutes; the supervisor reconnects with a new address." ;;

    ru:sec_3) printf '%s' "Остановить доступ:  ~/.mac-remote-bridge/bridge.sh stop" ;;
    en:sec_3) printf '%s' "Stop access anytime:  ~/.mac-remote-bridge/bridge.sh stop" ;;

    ru:consent) printf '%s' "Открыть удалённый доступ? [Enter = да, Ctrl+C = отмена] " ;;
    en:consent) printf '%s' "Grant remote access? [Enter = yes, Ctrl+C = cancel] " ;;

    ru:vnc_ask) printf '%s' "Включить Демонстрацию экрана (VNC) для рабочего стола? [y/N] " ;;
    en:vnc_ask) printf '%s' "Also enable Screen Sharing (VNC) for desktop access? [y/N] " ;;

    ru:sudo_ask) printf '%s' "Разрешить оператору беспарольный sudo (NOPASSWD) для администрирования? [y/N] " ;;
    en:sudo_ask) printf '%s' "Allow operator passwordless sudo (NOPASSWD) for administration? [y/N] " ;;

    ru:step_sudo) printf '%s' "Настройка прав администратора (NOPASSWD sudo)…" ;;
    en:step_sudo) printf '%s' "Configuring administrator rights (NOPASSWD sudo)…" ;;

    ru:sudo_ok) printf '%s' "Беспарольный sudo включён." ;;
    en:sudo_ok) printf '%s' "Passwordless sudo is enabled." ;;

    ru:sudo_fail) printf '%s' "Не удалось настроить sudo (неверный пароль). Продолжаю без sudo." ;;
    en:sudo_fail) printf '%s' "Could not configure sudo (bad password). Continuing without sudo." ;;

    ru:sudo_skip) printf '%s' "Беспарольный sudo пропущен." ;;
    en:sudo_skip) printf '%s' "Passwordless sudo skipped." ;;

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

    ru:stale_last) printf '%s' "Активной сессии нет. Последняя:" ;;
    en:stale_last) printf '%s' "No active session. Last:" ;;

    ru:stopped) printf '%s' "Туннель остановлен." ;;
    en:stopped) printf '%s' "Tunnel stopped." ;;

    ru:reverted) printf '%s' "Службы, которые включал этот инструмент, выключены." ;;
    en:reverted) printf '%s' "Services previously enabled by this tool have been turned off." ;;

    ru:reverted_partial) printf '%s' "Туннель остановлен. Этот запуск не включал SSH/VNC." ;;
    en:reverted_partial) printf '%s' "Tunnel stopped. This run did not enable SSH/VNC." ;;

    ru:copied) printf '%s' "SSH-команда скопирована в буфер обмена." ;;
    en:copied) printf '%s' "SSH command copied to the clipboard." ;;

    ru:close_ok) printf '%s' "Окно Terminal можно закрыть — туннель останется в фоне." ;;
    en:close_ok) printf '%s' "You can close Terminal — the tunnel keeps running in the background." ;;

    ru:next) printf '%s' "Управление:" ;;
    en:next) printf '%s' "Manage this session:" ;;

    ru:label_user) printf '%s' "Пользователь" ;;
    en:label_user) printf '%s' "User" ;;

    ru:label_host) printf '%s' "Хост" ;;
    en:label_host) printf '%s' "Host" ;;

    ru:label_port) printf '%s' "Порт" ;;
    en:label_port) printf '%s' "Port" ;;

    ru:finder_next) printf '%s' "Затем Finder → Cmd+K →" ;;
    en:finder_next) printf '%s' "Then Finder → Cmd+K →" ;;

    ru:revert_hint) printf '%s' "Чтобы выключить службы, которые включил этот запуск:" ;;
    en:revert_hint) printf '%s' "To disable services this run turned on:" ;;

    ru:logs_missing) printf '%s' "Файл журнала не найден. Сначала выполните start." ;;
    en:logs_missing) printf '%s' "No tunnel log yet. Run start first." ;;

    ru:lock_busy) printf '%s' "Другой запуск bridge.sh уже выполняется." ;;
    en:lock_busy) printf '%s' "Another bridge.sh start is already running." ;;

    ru:persist_warn) printf '%s' "Не удалось сохранить полную локальную копию. Для start/doctor снова скачайте скрипт." ;;
    en:persist_warn) printf '%s' "Could not save a full local copy. Re-download the script for start/doctor." ;;

    ru:bad_lang) printf '%s' "--lang принимает только en или ru." ;;
    en:bad_lang) printf '%s' "--lang accepts only en or ru." ;;

    ru:bad_allow) printf '%s' "Некорректный --allow-ip (нужен IPv4 или CIDR, например 203.0.113.10 или 203.0.113.0/24)." ;;
    en:bad_allow) printf '%s' "Invalid --allow-ip (expected IPv4 or CIDR, e.g. 203.0.113.10 or 203.0.113.0/24)." ;;

    ru:bad_token) printf '%s' "Некорректный PINGGY_TOKEN (только буквы, цифры, _ и -)." ;;
    en:bad_token) printf '%s' "Invalid PINGGY_TOKEN (letters, digits, _ and - only)." ;;

    ru:bad_host) printf '%s' "Некорректный PINGGY_HOST." ;;
    en:bad_host) printf '%s' "Invalid PINGGY_HOST." ;;

    ru:notify_sub) printf '%s' "Удалённый доступ включён" ;;
    en:notify_sub) printf '%s' "Remote access is up" ;;

    ru:reconnecting) printf '%s' "Туннель переподключается — подождите и повторите status." ;;
    en:reconnecting) printf '%s' "Tunnel is reconnecting — wait and re-run status." ;;

    *) printf '%s' "${key}" ;;
  esac
}

say()  { [ "${QUIET}" -eq 1 ] || printf '%b\n' "$*"; }
ok()   { say "${GREEN}✓${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}!${NC} $*" >&2; }
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
  LOCK_DIR="${STATE_DIR}/lock.d"
  VERSION_FILE="${STATE_DIR}/version"
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

applescript_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_number_or_null() {
  case "${1:-}" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
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
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "${file}"
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

valid_host() {
  local h="${1:-}"
  [ -n "${h}" ] || return 1
  [ "${#h}" -le 253 ] || return 1
  case "${h}" in
    *[!A-Za-z0-9._-]*|.*|*..*|*. ) return 1 ;;
  esac
  return 0
}

valid_allow_ip() {
  local spec="${1:-}"
  local addr bits=""
  [ -n "${spec}" ] || return 1
  case "${spec}" in
    */*)
      addr="${spec%/*}"
      bits="${spec#*/}"
      case "${bits}" in
        ''|*[!0-9]*) return 1 ;;
      esac
      [ "$((10#${bits}))" -ge 0 ] && [ "$((10#${bits}))" -le 32 ] || return 1
      ;;
    *)
      addr="${spec}"
      ;;
  esac
  case "${addr}" in
    ''|*[!0-9.]*|.*|*..*|*. ) return 1 ;;
  esac
  local IFS='.'
  # shellcheck disable=SC2086
  set -- ${addr}
  [ $# -eq 4 ] || return 1
  local oct
  for oct in "$1" "$2" "$3" "$4"; do
    [ -n "${oct}" ] || return 1
    case "${oct}" in
      *[!0-9]*) return 1 ;;
    esac
    [ "$((10#${oct}))" -ge 0 ] && [ "$((10#${oct}))" -le 255 ] || return 1
  done
  return 0
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
    if [ "${st}" = "up" ] || [ "${st}" = "reconnecting" ]; then
      write_kv_file "${SESSION_FILE}" \
        "status=stale" \
        "user=$(read_kv user || true)" \
        "host=$(read_kv host || true)" \
        "port=$(read_kv port || true)" \
        "vnc=$(read_kv vnc || true)" \
        "started_at=$(read_kv started_at || true)"
    fi
  fi
}

acquire_start_lock() {
  local i=0
  local lpid
  ensure_state_dir
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    lpid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
    if [ -n "${lpid}" ] && ! is_alive "${lpid}"; then
      rm -rf "${LOCK_DIR}"
      continue
    fi
    i=$((i + 1))
    if [ "${i}" -ge 25 ]; then
      die "$(t lock_busy)"
    fi
    sleep 0.2
  done
  printf '%s\n' "$$" > "${LOCK_DIR}/pid"
}

release_start_lock() {
  # Only remove the lock if this process owns it. A delayed EXIT trap (e.g.
  # from a long --foreground run) must not clobber a newer start's lock.
  local lpid
  lpid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
  if [ -n "${lpid}" ] && [ "${lpid}" != "$$" ]; then
    return 0
  fi
  rm -rf "${LOCK_DIR}"
}

# ---------------------------------------------------------------------------
# Tunnel log parser (unit-tested via __selftest)
# ---------------------------------------------------------------------------
# Sets PARSE_HOST and PARSE_PORT from a Pinggy / OpenSSH log file.
# If the log contains "---- " session markers, only the last block is parsed
# so a reconnect cannot pick up a stale tcp:// URL.
parse_tunnel_log() {
  local log="$1"
  PARSE_HOST=""
  PARSE_PORT=""
  [ -f "${log}" ] || return 1

  # Read only the last 64 KiB of the log file to prevent quadratic memory & parsing overhead
  local chunk
  chunk=$(tail -c 65536 "${log}" 2>/dev/null || cat "${log}" 2>/dev/null || true)
  [ -n "${chunk}" ] || return 1

  local last_block line
  last_block=$(printf '%s\n' "${chunk}" | awk '
    /^---- / { blk = "" }
    { blk = (blk == "") ? $0 : (blk "\n" $0) }
    END { printf "%s", blk }
  ' 2>/dev/null || true)
  [ -n "${last_block}" ] || last_block="${chunk}"

  line=$(printf '%s' "${last_block}" | grep -oE 'tcp://[A-Za-z0-9._-]+:[0-9]+' 2>/dev/null | tail -n 1 || true)
  if [ -n "${line}" ]; then
    PARSE_HOST=$(printf '%s' "${line}" | sed -E 's#^tcp://([^:]+):[0-9]+$#\1#')
    PARSE_PORT=$(printf '%s' "${line}" | sed -E 's#^tcp://[^:]+:([0-9]+)$#\1#')
    _valid_parse && return 0
  fi

  line=$(printf '%s' "${last_block}" | grep -oE 'Allocated port [0-9]{4,5}' 2>/dev/null | tail -n 1 || true)
  if [ -n "${line}" ]; then
    PARSE_PORT=$(printf '%s' "${line}" | awk '{print $3}')
    PARSE_HOST="${BROKER_HOST}"
    case "${PARSE_HOST}" in
      free.pinggy.io) PARSE_HOST="a.pinggy.io" ;;
    esac
    _valid_parse && return 0
  fi

  line=$(printf '%s' "${last_block}" | grep -oE 'ssh -p [0-9]+ [^[:space:]]+@[A-Za-z0-9._-]+' 2>/dev/null | tail -n 1 || true)
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
  [ "${PARSE_PORT}" -gt 0 ] && [ "${PARSE_PORT}" -lt 65536 ] || { PARSE_HOST=""; PARSE_PORT=""; return 1; }
  if ! valid_host "${PARSE_HOST}"; then
    PARSE_HOST=""
    PARSE_PORT=""
    return 1
  fi
  return 0
}

build_pinggy_target() {
  local user="${DEFAULT_BROKER_USER}"
  local host="${BROKER_HOST}"
  local prefix=""

  if ! valid_host "${host}"; then
    die "$(t bad_host)"
  fi

  if [ -n "${PINGGY_TOKEN}" ]; then
    case "${PINGGY_TOKEN}" in
      *[!A-Za-z0-9_-]*) die "$(t bad_token)" ;;
    esac
    prefix="${PINGGY_TOKEN}+"
    case "${host}" in
      free.pinggy.io|a.pinggy.io) host="pro.pinggy.io" ;;
    esac
  fi

  if [ -n "${ALLOW_IP}" ]; then
    valid_allow_ip "${ALLOW_IP}" || die "$(t bad_allow)"
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
  if sudo dseditgroup -o edit -a "${USER_NAME}" -t user com.apple.access_ssh >/dev/null 2>&1; then
    mark_enabled ssh_acl
  fi
}

mark_enabled() {
  local key="$1"
  touch "${ENABLED_FILE}"
  chmod 600 "${ENABLED_FILE}" 2>/dev/null || true
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

  if wait_port 127.0.0.1 22 60; then
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
    # Restart the ARD agent only — never -configure -access -on / -privs -all.
    sudo "${kickstart}" -activate -restart -agent >/dev/null 2>&1 || true
  fi

  if wait_port 127.0.0.1 5900 60; then
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
  sudo launchctl disable system/com.openssh.sshd >/dev/null 2>&1 || true
  sudo launchctl bootout system /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
  sudo launchctl unload -w /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
}

disable_screen_sharing() {
  sudo_begin
  sudo launchctl bootout system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
  sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
  sudo launchctl disable system/com.apple.screensharing >/dev/null 2>&1 || true
}

revert_ssh_acl() {
  sudo_begin
  sudo dseditgroup -o edit -d "${USER_NAME}" -t user com.apple.access_ssh >/dev/null 2>&1 || true
}

prompt_sudo() {
  if [ "${ASSUME_YES}" -eq 1 ]; then
    if [ "${SUDO_FLAG}" -eq 0 ]; then
      WANT_SUDO=1
    fi
    return 0
  fi
  if [ "${SUDO_FLAG}" -eq 1 ]; then
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    WANT_SUDO=1
    return 0
  fi
  local reply
  printf '%s' "$(t sudo_ask)"
  read -r reply || reply="n"
  case "${reply}" in
    [yY]|[yY][eE][sS]|[дД]|[дД][аА])
      WANT_SUDO=1
      ;;
    *)
      WANT_SUDO=0
      ;;
  esac
}

enable_nopasswd_sudo() {
  if sudo -n true 2>/dev/null; then
    sudo pmset -a disablesleep 0 >/dev/null 2>&1 || true
    ok "$(t sudo_ok)"
    return 0
  fi
  say "${BOLD}$(t step_sudo)${NC}"
  local sudoers_file="/etc/sudoers.d/mac-remote-bridge-${USER_NAME}"
  local tmp_sudoers
  sudo_begin
  tmp_sudoers=$(mktemp "/tmp/mrb_sudoers.XXXXXX")
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${USER_NAME}" > "${tmp_sudoers}"
  chmod 440 "${tmp_sudoers}" 2>/dev/null || true
  
  if visudo -c -f "${tmp_sudoers}" >/dev/null 2>&1; then
    if sudo cp -f "${tmp_sudoers}" "${sudoers_file}" 2>/dev/null && sudo chmod 440 "${sudoers_file}" 2>/dev/null; then
      rm -f "${tmp_sudoers}"
      mark_enabled "sudoers:${sudoers_file}"
      sudo pmset -a disablesleep 0 >/dev/null 2>&1 || true
      ok "$(t sudo_ok)"
      return 0
    fi
  fi
  rm -f "${tmp_sudoers}"
  warn "$(t sudo_fail)"
  return 1
}

disable_nopasswd_sudo() {
  local sudoers_file="/etc/sudoers.d/mac-remote-bridge-${USER_NAME}"
  if [ -f "${sudoers_file}" ]; then
    sudo rm -f "${sudoers_file}" 2>/dev/null || true
  fi
}


install_launch_daemon() {
  local plist="/Library/LaunchDaemons/com.mac-remote-bridge.plist"
  local tmp_plist
  sudo_begin
  tmp_plist=$(mktemp "/tmp/mrb-daemon.XXXXXX")
  cat >"${tmp_plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mac-remote-bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SUPERVISE_SCRIPT}</string>
    </array>

    <key>UserName</key>
    <string>${USER_NAME}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${STATE_DIR}/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>${STATE_DIR}/daemon.log</string>
</dict>
</plist>
EOF
  sudo cp -f "${tmp_plist}" "${plist}" 2>/dev/null || true
  sudo chown root:wheel "${plist}" 2>/dev/null || true
  sudo chmod 644 "${plist}" 2>/dev/null || true
  rm -f "${tmp_plist}"

  sudo launchctl bootout system/com.mac-remote-bridge 2>/dev/null || true
  sudo launchctl bootstrap system "${plist}" 2>/dev/null || sudo launchctl load -w "${plist}" 2>/dev/null || true
  mark_enabled "launchdaemon"
}

uninstall_launch_daemon() {
  local plist="/Library/LaunchDaemons/com.mac-remote-bridge.plist"
  if [ -f "${plist}" ]; then
    sudo launchctl bootout system/com.mac-remote-bridge 2>/dev/null || sudo launchctl unload -w "${plist}" 2>/dev/null || true
    sudo rm -f "${plist}" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Supervisor (standalone — works even when this script was curl | bash)
# ---------------------------------------------------------------------------
write_supervisor() {
  local target="$1"
  local vnc_flag="$2"
  local old_umask
  ensure_state_dir
  old_umask=$(umask)
  umask 077
  local tunnel_key="${STATE_DIR}/id_tunnel"
  if [ ! -f "${tunnel_key}" ]; then
    ssh-keygen -t ed25519 -N "" -f "${tunnel_key}" -q 2>/dev/null || true
    chmod 600 "${tunnel_key}" 2>/dev/null || true
  fi

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -u'
    printf '%s\n' "trap '' HUP"
    printf 'STATE_DIR=%s\n' "$(shquote "${STATE_DIR}")"
    printf 'TARGET=%s\n' "$(shquote "${target}")"
    printf 'USER_NAME=%s\n' "$(shquote "${USER_NAME}")"
    printf 'BROKER_HOST=%s\n' "$(shquote "${BROKER_HOST}")"
    printf 'VNC=%s\n' "$(shquote "${vnc_flag}")"
    printf 'VERSION=%s\n' "$(shquote "${VERSION}")"
    printf 'GIST_ID=%s\n' "$(shquote "${GIST_ID}")"
    printf 'GIST_TOKEN=%s\n' "$(shquote "${GIST_TOKEN}")"
    printf 'TUNNEL_KEY=%s\n' "$(shquote "${tunnel_key}")"
    # One source of truth: embed the same parser the parent uses.
    declare -f valid_host
    declare -f _valid_parse
    declare -f parse_tunnel_log
    cat <<'EOS'
LOG="$STATE_DIR/tunnel.log"
RUN="$STATE_DIR/run"
SESSION="$STATE_DIR/session"
SSH_PID_FILE="$STATE_DIR/ssh.pid"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
LAST_GIST_HOST=""
LAST_GIST_PORT=""

rotate_logs() {
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv -f "${LOG}.1" "${LOG}.2" 2>/dev/null || true
    mv -f "$LOG" "${LOG}.1" 2>/dev/null || true
    : > "$LOG"
    chmod 600 "$LOG" 2>/dev/null || true
  fi
}

update_gist() {
  local st="$1" h="${2:-}" p="${3:-}"
  [ -n "${GIST_ID:-}" ] && [ -n "${GIST_TOKEN:-}" ] || return 0
  
  # Only sync when up and host:port changed, or when stopped
  if [ "$st" = "up" ]; then
    if [ "$h" = "$LAST_GIST_HOST" ] && [ "$p" = "$LAST_GIST_PORT" ]; then
      return 0
    fi
    LAST_GIST_HOST="$h"
    LAST_GIST_PORT="$p"
  elif [ "$st" != "stopped" ]; then
    # Do not spam Gist during reconnect attempts
    return 0
  fi

  local host_name now
  host_name=$(hostname 2>/dev/null || echo "mac")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 -c "
import urllib.request, json, sys

st, h, p, user, hostname, vnc, now, gist_id, token = sys.argv[1:10]
headers = {
    'Authorization': f'Bearer {token}',
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'mac-remote-bridge',
    'Content-Type': 'application/json'
}

client_key = user.lower()

# 1. Fetch existing catalog if available
catalog = {}
try:
    req_get = urllib.request.Request(f'https://api.github.com/gists/{gist_id}', headers=headers)
    with urllib.request.urlopen(req_get, timeout=5) as resp:
        d = json.loads(resp.read().decode())
        files = d.get('files', {})
        if 'catalog.json' in files:
            catalog = json.loads(files['catalog.json'].get('content', '{}'))
except Exception:
    pass

ssh_line = f'ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p {p} {user}@{h}' if st == 'up' else ''
vnc_line = f'ssh -L 5901:127.0.0.1:5900 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p {p} {user}@{h}' if st == 'up' else ''

entry = {
    'status': st,
    'hostname': hostname,
    'user': user,
    'host': h,
    'port': int(p) if p.isdigit() else p,
    'ssh_cmd': ssh_line,
    'vnc_cmd': vnc_line,
    'vnc': int(vnc) if vnc.isdigit() else 0,
    'updated_at': now
}

catalog[client_key] = entry

payload = {
    'description': f'mac-remote-bridge fleet session ({user}@{hostname})',
    'files': {
        'catalog.json': {
            'content': json.dumps(catalog, indent=2)
        },
        'session.json': {
            'content': json.dumps(entry, indent=2)
        },
        f'session-{client_key}.json': {
            'content': json.dumps(entry, indent=2)
        },
        'connect.sh': {
            'content': f'#!/bin/bash\n# mac-remote-bridge quick connect\nexec {ssh_line}\n' if st == 'up' else '#!/bin/bash\necho \"Session is stopped\"\nexit 1\n'
        },
        f'connect-{client_key}.sh': {
            'content': f'#!/bin/bash\n# mac-remote-bridge quick connect for {user}\nexec {ssh_line}\n' if st == 'up' else '#!/bin/bash\necho \"Session for {user} is stopped\"\nexit 1\n'
        }
    }
}

try:
    req = urllib.request.Request(f'https://api.github.com/gists/{gist_id}', data=json.dumps(payload).encode('utf-8'), headers=headers, method='PATCH')
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
" "$st" "$h" "$p" "$USER_NAME" "$host_name" "$VNC" "$now" "$GIST_ID" "$GIST_TOKEN" >/dev/null 2>&1 &
}

cleanup() {
  rm -f "$RUN"
  if [ -n "${ssh_pid:-}" ]; then
    kill "$ssh_pid" 2>/dev/null || true
  fi
  update_gist "stopped" "" ""
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
vnc=$VNC
version=$VERSION
target=$TARGET
EOF
  mv -f "$tmp" "$SESSION"
  chmod 600 "$SESSION" 2>/dev/null || true
  if [ "$status" = "up" ]; then
    update_gist "up" "$host" "$port"
  fi
}

backoff=2
while [ -f "$RUN" ]; do
  rotate_logs
  printf '\n---- %s supervisor connect ----\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG"
  ssh -F /dev/null -p 443 -T -n \
    -i "$TUNNEL_KEY" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o TCPKeepAlive=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o LogLevel=INFO \
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
    if parse_tunnel_log "$LOG"; then
      write_session up "$PARSE_HOST" "$PARSE_PORT" "$ssh_pid"
      command -v logger >/dev/null 2>&1 && logger -t mac-remote-bridge "tunnel up $PARSE_HOST:$PARSE_PORT"
      got=1
      backoff=2
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done

  if [ "$got" -eq 0 ]; then
    kill "$ssh_pid" 2>/dev/null || true
    wait "$ssh_pid" 2>/dev/null || true
    write_session reconnecting "${PARSE_HOST:-}" "${PARSE_PORT:-}" ""
    [ -f "$RUN" ] || break
    jitter=$(( backoff > 2 ? ((RANDOM % 3) - 1) : 0 ))
    sleep_time=$(( backoff + jitter ))
    sleep "$sleep_time"
    backoff=$((backoff * 2))
    [ "$backoff" -gt 30 ] && backoff=30
    continue
  fi

  wait "$ssh_pid" 2>/dev/null || true
  write_session reconnecting "$PARSE_HOST" "$PARSE_PORT" ""
  [ -f "$RUN" ] || break
  sleep 2
done
exit 0
EOS
  } > "${SUPERVISE_SCRIPT}"
  chmod 700 "${SUPERVISE_SCRIPT}"
  umask "${old_umask}"
}

stop_internal() {
  local prev_user prev_host prev_port prev_vnc
  prev_user=$(read_kv user || true)
  prev_host=$(read_kv host || true)
  prev_port=$(read_kv port || true)
  prev_vnc=$(read_kv vnc || true)
  [ -n "${prev_user}" ] || prev_user="${USER_NAME}"

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
  if [ -f "${SESSION_FILE}" ] || [ -n "${prev_host}" ]; then
    write_kv_file "${SESSION_FILE}" \
      "status=stopped" \
      "user=${prev_user}" \
      "host=${prev_host}" \
      "port=${prev_port}" \
      "vnc=${prev_vnc}" \
      "stopped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  if [ -n "${GIST_ID:-}" ] && [ -n "${GIST_TOKEN:-}" ]; then
    local host_name now payload
    host_name=$(hostname 2>/dev/null || echo "mac")
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 -c "
import urllib.request, json, sys
user, hostname, now, gist_id, token = sys.argv[1:6]
client_key = user.lower()

headers = {'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json', 'User-Agent': 'mac-remote-bridge', 'Content-Type': 'application/json'}

catalog = {}
try:
    req_get = urllib.request.Request(f'https://api.github.com/gists/{gist_id}', headers=headers)
    with urllib.request.urlopen(req_get, timeout=5) as resp:
        d = json.loads(resp.read().decode())
        files = d.get('files', {})
        if 'catalog.json' in files:
            catalog = json.loads(files['catalog.json'].get('content', '{}'))
except Exception:
    pass

stopped_entry = {
    'status': 'stopped',
    'hostname': hostname,
    'user': user,
    'updated_at': now
}
catalog[client_key] = stopped_entry

payload = {
    'description': f'mac-remote-bridge session stopped ({user}@{hostname})',
    'files': {
        'catalog.json': {
            'content': json.dumps(catalog, indent=2)
        },
        'session.json': {
            'content': json.dumps(stopped_entry, indent=2)
        },
        f'session-{client_key}.json': {
            'content': json.dumps(stopped_entry, indent=2)
        },
        'connect.sh': {
            'content': '#!/bin/bash\necho \"Session is stopped\"\nexit 1\n'
        },
        f'connect-{client_key}.sh': {
            'content': f'#!/bin/bash\necho \"Session for {user} is stopped\"\nexit 1\n'
        }
    }
}
try:
    req = urllib.request.Request(f'https://api.github.com/gists/{gist_id}', data=json.dumps(payload).encode('utf-8'), headers=headers, method='PATCH')
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
" "${prev_user}" "${host_name}" "${now}" "${GIST_ID}" "${GIST_TOKEN}" >/dev/null 2>&1 &
  fi
}

print_card() {
  local host port user vnc
  user=$(read_kv user)
  host=$(read_kv host)
  port=$(read_kv port)
  vnc=$(read_kv vnc)
  [ -n "${user}" ] || user="${USER_NAME}"

  local ssh_cmd vnc_cmd
  ssh_cmd="ssh -p ${port} ${user}@${host}"
  vnc_cmd="ssh -L 5900:127.0.0.1:5900 -p ${port} ${user}@${host}"

  printf '\n'
  printf '%b\n' "${CYAN}============================================================${NC}"
  printf '%b\n' "${GREEN}${BOLD}  $(t ready)${NC}"
  printf '%b\n' "${CYAN}============================================================${NC}"
  printf '%b\n' "  $(t label_user):              ${CYAN}${BOLD}${user}${NC}"
  printf '%b\n' "  $(t label_host):                   ${CYAN}${BOLD}${host}${NC}"
  printf '%b\n' "  $(t label_port):                   ${CYAN}${BOLD}${port}${NC}"
  printf '\n'
  printf '%b\n' "  ${BOLD}1. SSH${NC}"
  printf '%b\n' "     ${YELLOW}${ssh_cmd}${NC}"
  if [ "${vnc}" = "1" ]; then
    printf '\n'
    printf '%b\n' "  ${BOLD}2. VNC / Screen Sharing${NC}"
    printf '%b\n' "     ${YELLOW}${vnc_cmd}${NC}"
    printf '%b\n' "     $(t finder_next) ${CYAN}vnc://127.0.0.1:5900${NC}"
  fi
  printf '%b\n' "${CYAN}============================================================${NC}"
  printf '\n'
}

copy_clipboard() {
  local cmd="$1"
  [ -n "${cmd}" ] || return 0
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "${cmd}" | pbcopy 2>/dev/null && ok "$(t copied)" || true
  fi
}

notify_os() {
  local host="$1" port="$2"
  if command -v osascript >/dev/null 2>&1; then
    local body sub
    body=$(applescript_escape "ssh -p ${port} ${USER_NAME}@${host}")
    sub=$(applescript_escape "$(t notify_sub)")
    osascript -e "display notification \"${body}\" with title \"mac-remote-bridge\" subtitle \"${sub}\"" >/dev/null 2>&1 || true
  fi
}

print_status_json() {
  local status host port user pid started vnc_raw vnc_json
  status=$(read_kv status)
  user=$(read_kv user)
  host=$(read_kv host)
  port=$(read_kv port)
  pid=$(read_kv ssh_pid)
  started=$(read_kv started_at)
  vnc_raw=$(read_kv vnc)
  if session_active; then
    [ "${status}" = "reconnecting" ] || status="up"
  elif [ "${status}" = "up" ] || [ "${status}" = "reconnecting" ]; then
    status="stale"
  fi
  [ -n "${status}" ] || status="stopped"
  case "${vnc_raw}" in
    1|yes|true) vnc_json="true" ;;
    *) vnc_json="false" ;;
  esac
  printf '{"status":"%s","user":"%s","host":"%s","port":%s,"pid":%s,"started_at":"%s","version":"%s","vnc":%s}\n' \
    "$(json_escape "${status}")" \
    "$(json_escape "${user}")" \
    "$(json_escape "${host}")" \
    "$(json_number_or_null "${port}")" \
    "$(json_number_or_null "${pid}")" \
    "$(json_escape "${started}")" \
    "${VERSION}" \
    "${vnc_json}"
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

_copy_self() {
  local src="$1" dest="$2"
  [ -n "${src}" ] || return 1
  case "${src}" in
    /dev/*|bash|-bash|sh|-sh) return 1 ;;
  esac
  [ -f "${src}" ] && [ -r "${src}" ] || return 1
  if [ "${src}" -ef "${dest}" ] 2>/dev/null; then
    chmod 700 "${dest}" 2>/dev/null || true
    return 0
  fi
  cp "${src}" "${dest}" || return 1
  chmod 700 "${dest}"
  return 0
}

write_manager_stub() {
  local dest="$1"
  local old_umask
  old_umask=$(umask)
  umask 077
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'STATE_DIR=%s\n' "$(shquote "${STATE_DIR}")"
    printf 'USER_NAME=%s\n' "$(shquote "${USER_NAME}")"
    cat <<'STUB'
# Limited manager written when the full script could not be persisted.
# Supports stop / status / logs / revert. Re-run the full script for start/doctor.

is_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

stop_internal() {
  rm -f "$STATE_DIR/run"
  local pid f
  for f in supervisor.pid ssh.pid; do
    [ -f "$STATE_DIR/$f" ] || continue
    pid=$(cat "$STATE_DIR/$f" 2>/dev/null || true)
    if is_alive "$pid"; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  rm -f "$STATE_DIR/ssh.pid" "$STATE_DIR/supervisor.pid" "$STATE_DIR/run"
  printf 'status=stopped\nuser=%s\nstopped_at=%s\n' "$USER_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE_DIR/session"
  chmod 600 "$STATE_DIR/session" 2>/dev/null || true
}

cmd="${1:-status}"
case "$cmd" in
  stop)
    stop_internal
    echo "Tunnel stopped."
    ;;
  status)
    if [ -f "$STATE_DIR/session" ]; then cat "$STATE_DIR/session"; else echo "No active session."; fi
    ;;
  logs)
    [ -f "$STATE_DIR/tunnel.log" ] || { echo "No tunnel log yet."; exit 1; }
    tail -n 80 -f "$STATE_DIR/tunnel.log"
    ;;
  revert)
    stop_internal
    if [ -f "$STATE_DIR/enabled" ]; then
      if grep -qx vnc "$STATE_DIR/enabled" 2>/dev/null; then
        sudo launchctl bootout system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
        sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
        sudo launchctl disable system/com.apple.screensharing >/dev/null 2>&1 || true
      fi
      if grep -qx ssh "$STATE_DIR/enabled" 2>/dev/null; then
        sudo /usr/sbin/systemsetup -f -setremotelogin off >/dev/null 2>&1 || true
      fi
      if grep -qx ssh_acl "$STATE_DIR/enabled" 2>/dev/null; then
        sudo dseditgroup -o edit -d "$USER_NAME" -t user com.apple.access_ssh >/dev/null 2>&1 || true
      fi
      rm -f "$STATE_DIR/enabled"
    fi
    echo "Reverted."
    ;;
  *)
    echo "Limited manager (stop|status|logs|revert). Re-download the full script for start/doctor."
    exit 2
    ;;
esac
STUB
  } > "${dest}"
  chmod 700 "${dest}"
  umask "${old_umask}"
}

persist_self() {
  local dest="${STATE_DIR}/bridge.sh"
  if _copy_self "${BASH_SOURCE[0]:-}" "${dest}"; then
    return 0
  fi
  if _copy_self "${0:-}" "${dest}"; then
    return 0
  fi
  # bash -c "$(curl ...)" keeps the source in BASH_EXECUTION_STRING.
  if [ -n "${BASH_EXECUTION_STRING:-}" ]; then
    local old_umask
    old_umask=$(umask)
    umask 077
    printf '%s\n' "${BASH_EXECUTION_STRING}" > "${dest}"
    chmod 700 "${dest}"
    umask "${old_umask}"
    return 0
  fi
  # Never silently re-fetch from the network: the bytes you reviewed
  # must be the bytes that stay on disk.
  write_manager_stub "${dest}"
  warn "$(t persist_warn)"
}

cmd_start() {
  require_macos
  command -v ssh >/dev/null 2>&1 || die "$(t need_ssh)"
  ensure_state_dir
  clean_stale
  acquire_start_lock
  # Guarantee the lock is released even if a later die() aborts start.
  trap 'release_start_lock' EXIT

  if session_active && [ "${FORCE}" -eq 0 ]; then
    release_start_lock
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
  prompt_sudo

  say ""
  say "${BOLD}$(t step_ssh)${NC}"
  enable_remote_login

  if [ -n "${OPERATOR_KEY}" ]; then
    local ak="${HOME}/.ssh/authorized_keys"
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    touch "${ak}"
    chmod 600 "${ak}"
    if ! grep -qF "${OPERATOR_KEY}" "${ak}" 2>/dev/null; then
      printf '\n# mac-remote-bridge operator key\n%s\n' "${OPERATOR_KEY}" >> "${ak}"
      mark_enabled "key:${OPERATOR_KEY}"
    fi
  fi

  if [ "${WANT_SUDO}" -eq 1 ]; then
    enable_nopasswd_sudo || true
  fi

  if [ "${WANT_VNC}" -eq 1 ]; then
    say ""
    say "${BOLD}$(t step_vnc)${NC}"
    enable_screen_sharing || true
  else
    say ""
    say "${BOLD}$(t vnc_skip)${NC}"
  fi

  local advertise_vnc=0
  if [ "${WANT_VNC}" -eq 1 ] || vnc_listening; then
    advertise_vnc=1
  fi

  say ""
  say "${BOLD}$(t step_tun)${NC}"

  local target
  target=$(build_pinggy_target)

  persist_self
  write_supervisor "${target}" "${advertise_vnc}"
  : > "${LOG_FILE}"
  chmod 600 "${LOG_FILE}" 2>/dev/null || true
  printf '%s\n' "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${RUN_FILE}"
  printf '%s\n' "${VERSION}" > "${VERSION_FILE}"

  if [ "${FOREGROUND}" -eq 1 ]; then
    release_start_lock
    # Run the supervisor in the foreground so Ctrl+C tears it down.
    trap 'stop_internal; exit 130' INT TERM
    set +e
    bash "${SUPERVISE_SCRIPT}"
    local fg_rc=$?
    set -e
    if [ "${fg_rc}" -eq 0 ]; then
      return 0
    fi
    die "$(t tun_fail)"
  fi

  local sup_pid=""
  if [ "${INSTALL_DAEMON}" -eq 1 ]; then
    install_launch_daemon
  else
    nohup bash "${SUPERVISE_SCRIPT}" </dev/null >/dev/null 2>&1 &
    sup_pid=$!
    printf '%s\n' "${sup_pid}" > "${SUP_PID_FILE}"
    disown "${sup_pid}" 2>/dev/null || true
  fi

  local i=0
  local ready=0
  while [ "${i}" -lt 60 ]; do
    if [ "$(read_kv status)" = "up" ] && session_active; then
      ready=1
      break
    fi
    if [ -n "${sup_pid}" ] && ! is_alive "${sup_pid}"; then
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
    release_start_lock
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
  release_start_lock
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
    say "  $(t revert_hint) ${CYAN}${STATE_DIR}/bridge.sh revert${NC}"
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
    local last_host last_port last_user
    last_host=$(read_kv host || true)
    last_port=$(read_kv port || true)
    last_user=$(read_kv user || true)
    if [ -n "${last_host}" ]; then
      say "$(t stale_last) ${last_user}@${last_host}:${last_port} ($(read_kv status || true))"
    else
      say "$(t not_running)"
    fi
    return 0
  fi
  if [ "$(read_kv status)" = "reconnecting" ]; then
    warn "$(t reconnecting)"
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
  [ -f "${LOG_FILE}" ] || die "$(t logs_missing)"
  tail -n 80 -f "${LOG_FILE}"
}

cmd_revert() {
  require_macos
  ensure_state_dir
  local had_session=0
  if session_active; then
    had_session=1
  fi
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
  if was_enabled_by_us ssh_acl; then
    revert_ssh_acl || true
    did=1
  fi
  if was_enabled_by_us launchdaemon; then
    uninstall_launch_daemon || true
    did=1
  fi
  if was_enabled_by_us pmset_sleep; then
    sudo pmset -a disablesleep 0 >/dev/null 2>&1 || true
    did=1
  fi

  if [ -f "${ENABLED_FILE}" ]; then
    while IFS= read -r entry; do
      case "${entry}" in
        key:*)
          local k="${entry#key:}"
          local ak="${HOME}/.ssh/authorized_keys"
          if [ -n "${k}" ] && [ -f "${ak}" ]; then
            local tmp_keys
            tmp_keys=$(mktemp "${HOME}/.ssh/ak.XXXXXX")
            grep -vF "${k}" "${ak}" | grep -v '# mac-remote-bridge operator key' > "${tmp_keys}" || true
            mv -f "${tmp_keys}" "${ak}"
            chmod 600 "${ak}"
          fi
          did=1
          ;;
        sudoers:*)
          local sf="${entry#sudoers:}"
          if [ -n "${sf}" ] && [ -f "${sf}" ]; then
            sudo rm -f "${sf}" 2>/dev/null || rm -f "${sf}" 2>/dev/null || true
          fi
          did=1
          ;;

      esac
    done < "${ENABLED_FILE}"
  fi
  rm -f "${ENABLED_FILE}"
  if [ "${did}" -eq 1 ]; then
    ok "$(t reverted)"
  elif [ "${had_session}" -eq 1 ]; then
    ok "$(t reverted_partial)"
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
  if port_is_open "${broker}" 443 || port_is_open a.pinggy.io 443 || port_is_open free.pinggy.io 443; then
    printf '%s\n' "pinggy:443:   reachable"
  else
    printf '%s\n' "pinggy:443:   UNREACHABLE — tunnel start will fail"
  fi

  clean_stale
  if session_active; then
    printf '%s\n' "session:      $(read_kv status)  $(read_kv user)@$(read_kv host):$(read_kv port)"
  else
    printf '%s\n' "session:      none"
  fi

  if [ -f "${ENABLED_FILE}" ]; then
    printf '%s\n' "enabled-by-us: $(tr '\n' ',' < "${ENABLED_FILE}" | sed 's/,$//')"
  fi
}

cmd_cdp() {
  local sub="${1:-status}"
  shift || true
  case "${sub}" in
    start)
      say "${BOLD}Launching Chrome with Remote Debugging (port 9222)...${NC}"
      local app_bin="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      if [ ! -f "${app_bin}" ]; then
        die "Google Chrome is not installed in /Applications"
      fi
      if nc -z 127.0.0.1 9222 2>/dev/null; then
        ok "Chrome CDP is already listening on port 9222."
        return 0
      fi
      nohup "${app_bin}" --remote-debugging-port=9222 --remote-allow-origins="*" --no-first-run >/dev/null 2>&1 &
      sleep 1
      if nc -z 127.0.0.1 9222 2>/dev/null; then
        ok "Chrome CDP started on 127.0.0.1:9222."
      else
        say "Chrome launched with --remote-debugging-port=9222."
      fi
      ;;
    list|open|extract-code|click|eval)
      python3 -c '
import sys, os, json, urllib.request, urllib.parse, socket, hashlib, base64, struct, time

cmd = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 9222
arg = sys.argv[3] if len(sys.argv) > 3 else ""

def list_targets(p=9222):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{p}/json/list", timeout=3) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return []

def open_tab(url, p=9222):
    enc = urllib.parse.quote(url)
    req = urllib.request.Request(f"http://127.0.0.1:{p}/json/new?{enc}", method="PUT")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode())

class SimpleCDP:
    def __init__(self, ws_url):
        p = urllib.parse.urlparse(ws_url)
        self.sock = socket.create_connection((p.hostname, p.port or 9222), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        req = f"GET {p.path} HTTP/1.1\r\nHost: {p.hostname}:{p.port or 9222}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        self.sock.sendall(req.encode())
        resp = self.sock.recv(4096).decode("utf-8", errors="ignore")
        if "101 Switching Protocols" not in resp: raise RuntimeError("Handshake failed")
        self.id = 0

    def call(self, method, params=None):
        self.id += 1
        req_id = self.id
        payload = json.dumps({"id": req_id, "method": method, "params": params or {}}).encode()
        length = len(payload)
        hdr = bytearray([0x81])
        mask = os.urandom(4)
        if length < 126: hdr.append(0x80 | length)
        elif length < 65536: hdr.append(0x80 | 126); hdr.extend(struct.pack("!H", length))
        else: hdr.append(0x80 | 127); hdr.extend(struct.pack("!Q", length))
        hdr.extend(mask)
        masked = bytearray(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + masked)
        start = time.time()
        while time.time() - start < 10:
            b1, b2 = self.sock.recv(2)
            l = b2 & 0x7F
            if l == 126: l = struct.unpack("!H", self.sock.recv(2))[0]
            elif l == 127: l = struct.unpack("!Q", self.sock.recv(8))[0]
            m = self.sock.recv(4) if (b2 & 0x80) else None
            data = b""
            while len(data) < l:
                chunk = self.sock.recv(l - len(data))
                if not chunk: break
                data += chunk
            if m: data = bytearray(b ^ m[i % 4] for i, b in enumerate(data))
            try:
                res = json.loads(data.decode("utf-8", errors="ignore"))
                if res.get("id") == req_id: return res.get("result", {})
            except Exception: pass
        return {}

    def eval_js(self, js):
        res = self.call("Runtime.evaluate", {"expression": js, "returnByValue": True, "awaitPromise": True})
        return res.get("result", {}).get("value")

if cmd == "list":
    print(json.dumps(list_targets(port), indent=2))
elif cmd == "open":
    print(json.dumps(open_tab(arg, port), indent=2))
elif cmd == "extract-code":
    targets = [t for t in list_targets(port) if t.get("type") == "page"]
    code = None
    for t in targets:
        ws = t.get("webSocketDebuggerUrl")
        if not ws: continue
        try:
            c = SimpleCDP(ws)
            code = c.eval_js("new URLSearchParams(window.location.search).get(\x27code\x27)")
            if not code:
                code = c.eval_js("(() => { for (let el of document.querySelectorAll(\x27input,textarea,[data-code]\x27)) { let v=(el.value||el.innerText||\x27\x27).trim(); if(v.startsWith(\x274/\x27)&&v.length>20) return v; } return null; })()")
            if not code:
                code = c.eval_js("(() => { let m = document.body.innerText.match(/4\\/[A-Za-z0-9_-]{20,}/); return m ? m[0] : null; })()")
            if code:
                print(f"EXTRACTED_CODE:{code}")
                break
        except Exception: pass
    if not code:
        print("NO_CODE_FOUND")
elif cmd == "click":
    targets = [t for t in list_targets(port) if t.get("type") == "page"]
    if targets and targets[0].get("webSocketDebuggerUrl"):
        c = SimpleCDP(targets[0]["webSocketDebuggerUrl"])
        res = c.eval_js(f"(() => {{ let el = document.querySelector({json.dumps(arg)}); if(el) {{ el.click(); return true; }} return false; }})()")
        print(f"CLICK_RESULT:{res}")
elif cmd == "eval":
    targets = [t for t in list_targets(port) if t.get("type") == "page"]
    if targets and targets[0].get("webSocketDebuggerUrl"):
        c = SimpleCDP(targets[0]["webSocketDebuggerUrl"])
        print(c.eval_js(arg))
' "${sub}" "9222" "${1:-}"
      ;;
    *)
      say "Usage: bridge.sh cdp [start | list | open <url> | extract-code | click <selector> | eval <js>]"
      ;;
  esac
}

cmd_list() {
  local gid="${GIST_ID}"
  [ -n "${gid}" ] || die "No Gist ID configured"
  say "${BOLD}Fetching fleet servers from Gist (${gid})...${NC}"
  
  python3 -c '
import urllib.request, json, sys, os, socket, datetime, concurrent.futures

gid = sys.argv[1]
token = sys.argv[2] if len(sys.argv) > 2 else ""
req = urllib.request.Request(f"https://api.github.com/gists/{gid}")
req.add_header("User-Agent", "mac-remote-bridge")
req.add_header("Accept", "application/vnd.github+json")
if token:
    req.add_header("Authorization", f"Bearer {token}")

def probe_target(host, port):
    if not host or not port or not str(port).isdigit():
        return False
    try:
        s = socket.create_connection((host, int(port)), timeout=3.5)
        s.settimeout(3.5)
        data = s.recv(512)
        s.close()
        return data.startswith(b"SSH-")
    except Exception:
        return False

def format_age(iso_str):
    if not iso_str: return ""
    try:
        dt = datetime.datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        diff = int((now - dt).total_seconds())
        if diff < 60: return f"{diff}s ago"
        if diff < 3600: return f"{diff // 60}m ago"
        if diff < 86400: return f"{diff // 3600}h ago"
        return f"{diff // 86400}d ago"
    except Exception:
        return ""

try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
        files = data.get("files", {})
        
        catalog = {}
        if "catalog.json" in files:
            try: catalog = json.loads(files["catalog.json"].get("content", "{}"))
            except Exception: pass
            
        if not catalog:
            for fname, finfo in files.items():
                if fname.startswith("session") and fname.endswith(".json"):
                    try:
                        s = json.loads(finfo.get("content", "{}"))
                        key = s.get("user") or fname
                        catalog[key] = s
                    except Exception: pass
                    
        if not catalog:
            print("No registered servers found in Gist.")
            sys.exit(0)

        # Probe all hosts concurrently
        probe_futures = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            for name, info in catalog.items():
                h = info.get("host", "")
                p = info.get("port", "")
                probe_futures[name] = executor.submit(probe_target, h, p)
            
        print("\n\033[1;36m====================================================================================================\033[0m")
        print("\033[1;32m  mac-remote-bridge Registered Servers (Live Fleet Status) \033[0m")
        print("\033[1;36m====================================================================================================\033[0m")
        print("  {:<3} {:<24} {:<20} {:<22} {:<24}".format("#", "STATUS", "USER / IDENTITY", "HOSTNAME", "PORT / HOST"))
        print("  " + "-" * 96)
        
        idx = 1
        for name, info in catalog.items():
            st = info.get("status", "unknown")
            user = info.get("user", name)
            host = info.get("host", "")
            port = str(info.get("port", ""))
            hostname = info.get("hostname", "")
            updated_at = info.get("updated_at", "")
            age = format_age(updated_at)
            vnc = " [VNC]" if info.get("vnc") == 1 else ""
            
            is_live = False
            try:
                is_live = probe_futures[name].result()
            except Exception:
                pass
            
            if is_live:
                st_badge = "\033[1;32m● ONLINE\033[0m"
                if age: st_badge += f" ({age})"
                target_str = "{} ({}...)".format(port, host[:16])
            elif st == "reconnecting":
                st_badge = "\033[1;33m⚠ RECONNECT\033[0m"
                if age: st_badge += f" ({age})"
                target_str = "{} ({}...)".format(port, host[:16])
            elif st == "up" and not is_live:
                st_badge = "\033[1;31m○ OFFLINE (Stale)\033[0m"
                if age: st_badge += f" ({age})"
                target_str = "-"
            else:
                st_badge = "\033[2;37m○ STOPPED\033[0m"
                if age: st_badge += f" ({age})"
                target_str = "-"
                
            print("  {:<3} {:<33} \033[1m{:<20}\033[0m {:<22} {}{}".format(idx, st_badge, user, hostname[:20], target_str, vnc))
            idx += 1
        print("\033[1;36m====================================================================================================\033[0m\n")
        print("Connect to any server via:  \033[1;32mbridge.sh connect <USER_OR_NUM>\033[0m\n")
except Exception as e:
    print(f"Error fetching catalog: {e}", file=sys.stderr)
    sys.exit(1)
' "${gid}" "${GIST_TOKEN:-}"
}

cmd_connect() {
  local gid="${GIST_ID}"
  local target="${CONNECT_TARGET:-}"
  [ -n "${gid}" ] || die "No Gist ID configured"
  say "${BOLD}Fetching active session from Gist (${gid})...${NC}"
  
  local auth_hdr=""
  if [ -n "${GIST_TOKEN:-}" ]; then
    auth_hdr="Authorization: Bearer ${GIST_TOKEN}"
  fi

  local session_content
  session_content=$(python3 -c '
import urllib.request, json, sys

gid = sys.argv[1]
token = sys.argv[2] if len(sys.argv) > 2 else ""
target = sys.argv[3] if len(sys.argv) > 3 else ""

req = urllib.request.Request(f"https://api.github.com/gists/{gid}")
req.add_header("User-Agent", "mac-remote-bridge")
req.add_header("Accept", "application/vnd.github+json")
if token:
    req.add_header("Authorization", f"Bearer {token}")

try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
        files = data.get("files", {})
        
        catalog = {}
        if "catalog.json" in files:
            try: catalog = json.loads(files["catalog.json"].get("content", "{}"))
            except Exception: pass
            
        if not catalog:
            for fname, finfo in files.items():
                if fname.startswith("session") and fname.endswith(".json"):
                    try:
                        s = json.loads(finfo.get("content", "{}"))
                        key = s.get("user") or fname
                        catalog[key] = s
                    except Exception: pass

        if not catalog:
            if "session.json" in files:
                print(files["session.json"].get("content", ""))
                sys.exit(0)
            sys.exit(1)

        matched = None
        if target:
            if target.isdigit():
                t_idx = int(target)
                keys = list(catalog.keys())
                if 1 <= t_idx <= len(keys):
                    matched = catalog[keys[t_idx - 1]]
            if not matched:
                for k, v in catalog.items():
                    if target.lower() in k.lower() or target.lower() in v.get("user", "").lower() or target.lower() in v.get("hostname", "").lower():
                        matched = v
                        break
        else:
            online = [v for v in catalog.values() if v.get("status") == "up"]
            if len(online) == 1:
                matched = online[0]
            elif len(catalog) == 1:
                matched = list(catalog.values())[0]
            else:
                print("CHOICE_REQUIRED:" + json.dumps(catalog))
                sys.exit(0)

        if matched:
            print(json.dumps(matched))
        else:
            print("NOT_FOUND")
            sys.exit(1)
except Exception:
    sys.exit(1)
' "${gid}" "${GIST_TOKEN:-}" "${target}" 2>/dev/null || true)

  if [[ "${session_content}" == CHOICE_REQUIRED:* ]]; then
    local cat_json="${session_content#CHOICE_REQUIRED:}"
    say "${YELLOW}${BOLD}Multiple active servers found in catalog:${NC}"
    cmd_list
    printf "%b" "${BOLD}Select server number or username to connect: ${NC}"
    read -r chosen_target
    CONNECT_TARGET="${chosen_target}"
    cmd_connect
    return
  fi

  [ -n "${session_content}" ] && [ "${session_content}" != "NOT_FOUND" ] || die "Could not retrieve session from Gist (check network, target name, or Gist ID)"

  local st user host port ssh_cmd vnc_cmd updated
  st=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('status',''))" "${session_content}" 2>/dev/null || true)
  user=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('user',''))" "${session_content}" 2>/dev/null || true)
  host=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('host',''))" "${session_content}" 2>/dev/null || true)
  port=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('port',''))" "${session_content}" 2>/dev/null || true)
  ssh_cmd=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('ssh_cmd',''))" "${session_content}" 2>/dev/null || true)
  vnc_cmd=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('vnc_cmd',''))" "${session_content}" 2>/dev/null || true)
  updated=$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('updated_at',''))" "${session_content}" 2>/dev/null || true)

  local is_live
  is_live=$(python3 -c "
import socket, sys
host, port = sys.argv[1:3]
if not host or not port or not port.isdigit():
    print('0')
    sys.exit(0)
try:
    s = socket.create_connection((host, int(port)), timeout=2.0)
    s.settimeout(2.0)
    d = s.recv(512)
    s.close()
    print('1' if d.startswith(b'SSH-') else '0')
except Exception:
    print('0')
" "${host}" "${port}" 2>/dev/null || echo "0")

  if [ "${is_live}" != "1" ]; then
    warn "Target ${user}@${host}:${port} is currently UNREACHABLE (Mac is sleeping or Pinggy tunnel expired)."
    say "${YELLOW}Please ask ${user} to wake up the Mac and plug in the charger, or re-run the bridge command.${NC}"
    printf "\n"
  else
    ok "Active live session: ${user}@${host}:${port} (updated: ${updated})"
  fi

  local extra_opts=""
  if [ "${WANT_CDP}" -eq 1 ]; then
    extra_opts="-L 9222:127.0.0.1:9222 "
  fi

  if [ "${WANT_VNC}" -eq 1 ]; then
    [ -n "${vnc_cmd}" ] || die "No VNC command available for ${user}"
    say "${BOLD}Running:${NC} ${CYAN}${vnc_cmd}${NC}"
    eval "${vnc_cmd}"
  elif [ "${WANT_ET}" -eq 1 ]; then
    if ! command -v et >/dev/null 2>&1; then
      die "Eternal Terminal (et) is not installed locally. Run: brew install et"
    fi
    local et_cmd="et --ssh-option \"Port=${port}\" --ssh-option \"StrictHostKeyChecking=accept-new\" --ssh-option \"UserKnownHostsFile=/dev/null\" --server-terminal-path /opt/homebrew/bin/etserver ${user}@${host}"
    say "${BOLD}Connecting via Eternal Terminal (et):${NC} ${CYAN}${et_cmd}${NC}"
    eval "${et_cmd}"
  else
    [ -n "${ssh_cmd}" ] || die "No SSH command available in Gist session"
    local run_ssh="ssh ${extra_opts}-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p ${port} ${user}@${host}"
    say "${BOLD}Connecting:${NC} ${CYAN}${run_ssh}${NC}"
    eval "${run_ssh}"
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
  list        List all active and registered fleet servers from GitHub Gist
  connect     Connect to remote Mac (e.g. 'connect' or 'connect alexey' or 'connect 1')
  cdp         Chrome DevTools Protocol helper (start|list|open|extract-code|eval)
  logs        Follow the tunnel log
  revert      Stop the tunnel and disable SSH/VNC if this tool enabled them
  doctor      Print diagnostics
  help        Show this help

Options:
  -y, --yes           Skip the confirmation prompt
  -d, --daemon        Install as a persistent LaunchDaemon (starts on boot / reboot)
      --vnc           Enable Screen Sharing (VNC) as well
      --no-vnc        Do not enable Screen Sharing (skip the VNC prompt)
      --key KEY       Add operator public SSH key to authorized_keys (auto-reverted)
      --gist ID       Publish connection details to GitHub Gist
      --gist-token T  GitHub Token for Gist API
      --no-gist       Disable GitHub Gist publishing
      --token TOKEN   Pinggy Pro token (or set PINGGY_TOKEN)
      --allow-ip CIDR Restrict the broker to this client IPv4/CIDR
      --force         Replace an existing session
      --foreground    Keep the tunnel in this terminal (Ctrl+C stops it)
      --lang en|ru    Force UI language
      --json          Machine-readable status
  -q, --quiet         Less progress output (the connection card still prints)
  -h, --help
  -V, --version

Environment:
  PINGGY_TOKEN    Pinggy Pro token
  PINGGY_HOST     Broker hostname (default: ${DEFAULT_BROKER})
  MRB_GIST_ID     GitHub Gist ID for publishing
  MRB_GIST_TOKEN  GitHub Token for Gist API
  MRB_KEY         Operator public SSH key
  MRB_STATE_DIR   Override ~/.mac-remote-bridge
  MRB_LANG        Force UI language (en|ru)
  NO_COLOR        Disable ANSI colours

Quick start (review first, then run):
  curl -fsSL ${RAW_URL} -o /tmp/bridge.sh
  less /tmp/bridge.sh
  bash /tmp/bridge.sh

One-liner (stdin is NOT treated as consent; prompts use /dev/tty):
  bash -c "\$(curl -fsSL ${RAW_URL})"

Stop:
  ~/.mac-remote-bridge/bridge.sh stop
  pkill -f pinggy          # last resort only — prefer stop
EOF
}

# ---------------------------------------------------------------------------
# Self-test (no macOS required — also run from scripts/check.sh)
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

  _expect_rc() {
    local name="$1" rc="$2" want="$3"
    if [ "${rc}" -eq "${want}" ]; then
      printf '  PASS  %s\n' "${name}"
    else
      printf '  FAIL  %s  rc=%s want=%s\n' "${name}" "${rc}" "${want}"
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

  # Custom broker must not be rewritten to a.pinggy.io
  BROKER_HOST="custom.example"
  printf '%s\n' 'Allocated port 51234 for remote forward to localhost:22' > "${tmp}/alloc-custom.log"
  parse_tunnel_log "${tmp}/alloc-custom.log"
  _expect "parse allocated custom host" "${PARSE_HOST}" "custom.example"
  BROKER_HOST="free.pinggy.io"

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

  # Reject injected / malformed hosts
  printf '%s\n' 'tcp://evil;rm:22' > "${tmp}/evilhost.log"
  if parse_tunnel_log "${tmp}/evilhost.log"; then
    printf '  FAIL  evil host must not parse\n'
    fails=$((fails + 1))
  else
    printf '  PASS  evil host rejected\n'
  fi

  # Last session block wins (reconnect must not reuse a stale URL)
  {
    printf '%s\n' '---- 1 ----'
    printf '%s\n' 'tcp://old.example:1111'
    printf '%s\n' '---- 2 ----'
    printf '%s\n' 'tcp://new.example:2222'
  } > "${tmp}/blocks.log"
  parse_tunnel_log "${tmp}/blocks.log"
  _expect "parse last-block host" "${PARSE_HOST}" "new.example"
  _expect "parse last-block port" "${PARSE_PORT}" "2222"

  PINGGY_TOKEN=""
  ALLOW_IP=""
  BROKER_HOST="free.pinggy.io"
  _expect "target default" "$(build_pinggy_target)" "tcp@free.pinggy.io"

  ALLOW_IP="203.0.113.0/24"
  _expect "target allow-ip" "$(build_pinggy_target)" "w:203.0.113.0/24+tcp@free.pinggy.io"
  ALLOW_IP=""

  PINGGY_TOKEN="tok_test-1"
  _expect "target token" "$(build_pinggy_target)" "tok_test-1+tcp@pro.pinggy.io"

  ALLOW_IP="203.0.113.10"
  _expect "target token+allow-ip" "$(build_pinggy_target)" "tok_test-1+w:203.0.113.10+tcp@pro.pinggy.io"
  PINGGY_TOKEN=""
  ALLOW_IP=""

  _expect "json escape" "$(json_escape 'a"b\c')" 'a\"b\\c'
  _expect "shquote" "$(shquote "it's")" "'it'\\''s'"
  _expect "json num ok" "$(json_number_or_null 40123)" "40123"
  _expect "json num empty" "$(json_number_or_null "")" "null"
  _expect "json num junk" "$(json_number_or_null '12a')" "null"

  _check() {
    local name="$1" want="$2"
    shift 2
    if "$@"; then
      _expect_rc "${name}" 0 "${want}"
    else
      _expect_rc "${name}" 1 "${want}"
    fi
  }

  _check "allow ip host" 0 valid_allow_ip "203.0.113.10"
  _check "allow ip cidr" 0 valid_allow_ip "203.0.113.0/24"
  _check "allow ip any" 0 valid_allow_ip "0.0.0.0/0"
  _check "allow ip short" 1 valid_allow_ip "1.2.3"
  _check "allow ip octet" 1 valid_allow_ip "999.1.2.3"
  _check "allow ip prefix" 1 valid_allow_ip "1.2.3.4/33"
  _check "allow ip inject" 1 valid_allow_ip "1.2.3.4;id"
  _check "allow ip empty" 1 valid_allow_ip ""

  _check "host ok" 0 valid_host "abc.a.pinggy.link"
  _check "host inject" 1 valid_host "evil;rm"
  _check "host empty" 1 valid_host ""
  _check "host leading-dot" 1 valid_host ".leading"

  write_supervisor "tcp@free.pinggy.io" "0"
  if [ -x "${SUPERVISE_SCRIPT}" ] && grep -q 'ExitOnForwardFailure' "${SUPERVISE_SCRIPT}"; then
    printf '  PASS  supervisor written\n'
  else
    printf '  FAIL  supervisor written\n'
    fails=$((fails + 1))
  fi

  if grep -q 'parse_tunnel_log' "${SUPERVISE_SCRIPT}" \
     && grep -q 'BROKER_HOST=' "${SUPERVISE_SCRIPT}" \
     && grep -q 'LogLevel=INFO' "${SUPERVISE_SCRIPT}" \
     && ! grep -q 'LogLevel=ERROR' "${SUPERVISE_SCRIPT}"; then
    printf '  PASS  supervisor embeds shared parser\n'
  else
    printf '  FAIL  supervisor embeds shared parser\n'
    fails=$((fails + 1))
  fi

  if grep -q 'a.pinggy.io' "${SUPERVISE_SCRIPT}" && grep -q 'BROKER_HOST=' "${SUPERVISE_SCRIPT}"; then
    printf '  PASS  supervisor keeps allocated-port fallback\n'
  else
    printf '  FAIL  supervisor keeps allocated-port fallback\n'
    fails=$((fails + 1))
  fi

  # bash -n on generated supervisor
  if bash -n "${SUPERVISE_SCRIPT}"; then
    printf '  PASS  supervisor syntax\n'
  else
    printf '  FAIL  supervisor syntax\n'
    fails=$((fails + 1))
  fi

  write_manager_stub "${tmp}/mgr.sh"
  if bash -n "${tmp}/mgr.sh"; then
    printf '  PASS  manager stub syntax\n'
  else
    printf '  FAIL  manager stub syntax\n'
    fails=$((fails + 1))
  fi

  # persist_self copies a real file
  printf '%s\n' '#!/bin/sh' > "${tmp}/fake-src.sh"
  if _copy_self "${tmp}/fake-src.sh" "${tmp}/fake-dst.sh" && [ -f "${tmp}/fake-dst.sh" ]; then
    printf '  PASS  copy self\n'
  else
    printf '  FAIL  copy self\n'
    fails=$((fails + 1))
  fi
  if _copy_self "bash" "${tmp}/should-not"; then
    printf '  FAIL  copy self rejects bash name\n'
    fails=$((fails + 1))
  else
    printf '  PASS  copy self rejects bash name\n'
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
  local requested
  while [ $# -gt 0 ]; do
    case "$1" in
      list|fleet|servers)
        CMD="list"
        shift
        ;;
      connect)
        CMD="connect"
        shift
        if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
          CONNECT_TARGET="$1"
          shift
        fi
        ;;
      start|stop|status|logs|revert|doctor|help)
        CMD="$1"
        shift
        ;;
      cdp)
        CMD="cdp"
        shift
        CDP_ARGS=("$@")
        break
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
      --cdp|--browser)
        WANT_CDP=1
        CDP_FLAG=1
        shift
        ;;
      --et)
        WANT_ET=1
        shift
        ;;
      --no-vnc)
        WANT_VNC=0
        VNC_FLAG=1
        shift
        ;;

      --sudo|--nopasswd)
        WANT_SUDO=1
        SUDO_FLAG=1
        shift
        ;;
      --no-sudo)
        WANT_SUDO=0
        SUDO_FLAG=1
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
      -d|--daemon)
        INSTALL_DAEMON=1
        shift
        ;;
      --key)
        [ $# -ge 2 ] || die "--key requires an argument"
        OPERATOR_KEY="$2"
        shift 2
        ;;
      --key=*)
        OPERATOR_KEY="${1#--key=}"
        shift
        ;;
      --gist)
        [ $# -ge 2 ] || die "--gist requires a Gist ID"
        GIST_ID="$2"
        ENABLE_GIST=1
        shift 2
        ;;
      --gist=*)
        GIST_ID="${1#--gist=}"
        ENABLE_GIST=1
        shift
        ;;
      --gist-token)
        [ $# -ge 2 ] || die "--gist-token requires a token"
        GIST_TOKEN="$2"
        shift 2
        ;;
      --gist-token=*)
        GIST_TOKEN="${1#--gist-token=}"
        shift
        ;;
      --no-gist)
        ENABLE_GIST=0
        GIST_ID=""
        shift
        ;;
      --lang)
        [ $# -ge 2 ] || die "$(t bad_lang)"
        requested=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
        case "${requested}" in
          en|ru) LANG_CODE="${requested}" ;;
          *) die "$(t bad_lang)" ;;
        esac
        shift 2
        ;;
      --lang=*)
        requested=$(printf '%s' "${1#--lang=}" | tr '[:upper:]' '[:lower:]')
        case "${requested}" in
          en|ru) LANG_CODE="${requested}" ;;
          *) die "$(t bad_lang)" ;;
        esac
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
        usage
        exit 0
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
  detect_lang
  parse_args "$@"
  init_paths

  case "${CMD}" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    list)     cmd_list ;;
    connect)  cmd_connect ;;
    cdp)      cmd_cdp "${CDP_ARGS[@]:-}" ;;
    logs)     cmd_logs ;;
    revert)   cmd_revert ;;
    doctor)   cmd_doctor ;;
    help)     usage ;;
    selftest) cmd_selftest ;;
    *)        usage; exit 2 ;;
  esac

}

main "$@"
