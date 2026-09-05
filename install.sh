#!/usr/bin/env bash
set -euo pipefail

REALM_VERSION="v2.7.0"
REALM_SERVICE_NAME="realm"
REALM_BIN="/usr/local/bin/realm"
REALM_SHORTCUT_NAME="realm"
REALM_SCRIPT_CMD="/usr/local/sbin/${REALM_SHORTCUT_NAME}"
REALM_DIR="/etc/realm"
REALM_CONFIG="${REALM_DIR}/config.toml"
REALM_ENDPOINTS="${REALM_DIR}/forwards.list"
REALM_LOG_DIR="/var/log/realm"
REALM_LOG_FILE="${REALM_LOG_DIR}/realm.log"
REALM_UNIT="/etc/systemd/system/${REALM_SERVICE_NAME}.service"
SCRIPT_VERSION="v1.1"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
  C_CYAN="\033[36m"
  C_BOLD="\033[1m"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_BOLD=""
fi

color() {
  local c="$1"
  shift
  printf "%b%s%b" "$c" "$*" "$C_RESET"
}

print_tagged() {
  local stream="$1"
  local c="$2"
  local tag="$3"
  shift 3

  if [ "$stream" = "stderr" ]; then
    printf "%b[%s]%b %s\n" "$c" "$tag" "$C_RESET" "$*" >&2
  else
    printf "%b[%s]%b %s\n" "$c" "$tag" "$C_RESET" "$*"
  fi
}

echo_err() {
  print_tagged "stderr" "$C_RED" "ERROR" "$*"
}

echo_warn() {
  print_tagged "stdout" "$C_YELLOW" "WARN" "$*"
}

echo_ok() {
  print_tagged "stdout" "$C_GREEN" "OK" "$*"
}

echo_info() {
  print_tagged "stdout" "$C_BLUE" "INFO" "$*"
}

pause_for_menu() {
  echo ""
  read -r -p "Press Enter to return to the main menu..." _
}

print_section() {
  local title="$1"
  echo ""
  printf "%b[%s]%b\n" "$C_GREEN" "$title" "$C_RESET"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo_err "Please run this script as root or with sudo."
    exit 1
  fi
}

self_install() {
  local self
  self=$(readlink -f "$0" 2>/dev/null || echo "$0")

  if [ "$self" = "$REALM_SCRIPT_CMD" ]; then
    return 0
  fi

  if [ -f "$self" ] && [ -r "$self" ]; then
    install -d -m 0755 "$(dirname "$REALM_SCRIPT_CMD")"
    install -m 0755 "$self" "$REALM_SCRIPT_CMD"
    return 0
  fi

  # Never fall back to downloading a remote copy: it would silently overwrite
  # local modifications to this script (e.g. the [::] dual-stack listen fix).
  echo_warn "Command wrapper installation was skipped because the script source could not be read."
}

detect_pkg_mgr() {
  if have_cmd apt-get; then
    echo "apt"
  elif have_cmd dnf; then
    echo "dnf"
  elif have_cmd yum; then
    echo "yum"
  elif have_cmd apk; then
    echo "apk"
  elif have_cmd pacman; then
    echo "pacman"
  else
    echo ""
  fi
}

install_pkg() {
  local mgr="$1"
  shift

  case "$mgr" in
    apt)
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    pacman)
      pacman -Sy --noconfirm "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_cmd_pkgmap() {
  local cmd="$1"
  local apt_pkg="$2"
  local dnf_pkg="$3"
  local yum_pkg="$4"
  local apk_pkg="$5"
  local pacman_pkg="$6"
  local mgr pkg

  if have_cmd "$cmd"; then
    return 0
  fi

  mgr=$(detect_pkg_mgr)
  if [ -z "$mgr" ]; then
    echo_err "Missing command: $cmd"
    return 1
  fi

  case "$mgr" in
    apt) pkg="$apt_pkg" ;;
    dnf) pkg="$dnf_pkg" ;;
    yum) pkg="$yum_pkg" ;;
    apk) pkg="$apk_pkg" ;;
    pacman) pkg="$pacman_pkg" ;;
    *) pkg="" ;;
  esac

  if [ -z "$pkg" ]; then
    echo_err "Missing command: $cmd"
    return 1
  fi

  echo_info "Installing required command: $cmd"
  install_pkg "$mgr" "$pkg"
  have_cmd "$cmd"
}

ensure_fetch_cmd() {
  if have_cmd curl || have_cmd wget; then
    return 0
  fi

  if ensure_cmd_pkgmap curl curl curl curl curl curl; then
    return 0
  fi

  ensure_cmd_pkgmap wget wget wget wget wget wget
}

ensure_port_check_tool() {
  if have_cmd ss || have_cmd lsof; then
    return 0
  fi

  ensure_cmd_pkgmap lsof lsof lsof lsof lsof lsof
}

ensure_install_tools() {
  ensure_cmd_pkgmap tar tar tar tar tar tar || return 1
  ensure_fetch_cmd || return 1
  ensure_port_check_tool || return 1
}

download_file() {
  local url="$1"
  local output="$2"

  if have_cmd curl; then
    curl -fL --progress-bar -o "$output" "$url"
    return 0
  fi

  if have_cmd wget; then
    wget --progress=bar:force -O "$output" "$url"
    return 0
  fi

  echo_err "Missing downloader: curl or wget"
  return 1
}

get_release_target() {
  case "$(uname -m)" in
    x86_64|amd64)
      echo "x86_64-unknown-linux-gnu"
      ;;
    aarch64|arm64)
      echo "aarch64-unknown-linux-gnu"
      ;;
    armv7l|armv7)
      echo "armv7-unknown-linux-gnueabihf"
      ;;
    i686|i386)
      echo "i686-unknown-linux-gnu"
      ;;
    *)
      return 1
      ;;
  esac
}

realm_download_url() {
  local target="$1"
  echo "https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-${target}.tar.gz"
}

realm_is_installed() {
  [ -x "$REALM_BIN" ] || [ -f "$REALM_UNIT" ] || [ -d "$REALM_DIR" ]
}

realm_has_forwards() {
  [ -f "$REALM_ENDPOINTS" ] && grep -qve '^[[:space:]]*$' "$REALM_ENDPOINTS"
}

get_forward_count() {
  if [ ! -f "$REALM_ENDPOINTS" ]; then
    echo "0"
    return 0
  fi

  awk 'NF { count++ } END { print count + 0 }' "$REALM_ENDPOINTS"
}

is_port_valid() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_port_in_use() {
  local port="$1"

  if have_cmd ss; then
    ss -lntu 2>/dev/null | awk -v suffix=":$port" '$5 ~ (suffix "$") || $5 ~ ("\\]" suffix "$") { found = 1 } END { exit found ? 0 : 1 }'
    return $?
  fi

  if have_cmd lsof; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    lsof -nP -iUDP:"$port" >/dev/null 2>&1 && return 0
    return 1
  fi

  return 1
}

forward_port_exists() {
  local port="$1"

  if [ ! -f "$REALM_ENDPOINTS" ]; then
    return 1
  fi

  awk -F'|' -v port="$port" '
    $1 == port { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$REALM_ENDPOINTS"
}

is_ipv4_valid() {
  local ip="$1"
  local octet
  local -a octets=()
  local old_ifs="$IFS"

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.'
  read -r -a octets <<< "$ip"
  IFS="$old_ifs"

  for octet in "${octets[@]}"; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done

  return 0
}

is_hostname_valid() {
  local host="$1"
  local label
  local tld
  local -a labels=()
  local old_ifs="$IFS"

  [ -n "$host" ] || return 1
  [ "${#host}" -le 253 ] || return 1
  [[ "$host" == *..* ]] && return 1

  host="${host%.}"
  IFS='.'
  read -r -a labels <<< "$host"
  IFS="$old_ifs"

  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done

  if [ "${#labels[@]}" -eq 1 ]; then
    [[ ! "${labels[0]}" =~ ^[0-9]+$ ]] || return 1
    return 0
  fi

  tld="${labels[${#labels[@]} - 1]}"
  [[ ! "$tld" =~ ^[0-9]+$ ]] || return 1

  return 0
}

is_ipv6_valid() {
  local ip="$1"
  local part
  local nonempty_count=0
  local -a parts=()
  local old_ifs="$IFS"

  [ -n "$ip" ] || return 1
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" != *:::* ]] || return 1
  [[ "$ip" != *::*::* ]] || return 1
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1

  IFS=':'
  read -r -a parts <<< "$ip"
  IFS="$old_ifs"

  for part in "${parts[@]}"; do
    if [ -z "$part" ]; then
      continue
    fi

    [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    nonempty_count=$((nonempty_count + 1))
  done

  if [[ "$ip" == *::* ]]; then
    [ "$nonempty_count" -lt 8 ] || return 1
  else
    [ "${#parts[@]}" -eq 8 ] || return 1
  fi

  return 0
}

is_remote_valid() {
  local value="$1"
  local host=""
  local port=""

  if [[ "$value" =~ ^\[[^]]+\]:([0-9]{1,5})$ ]]; then
    host="${value%]:*}"
    host="${host#\[}"
    port="${BASH_REMATCH[1]}"
    is_ipv6_valid "$host" || return 1
  elif [[ "$value" =~ ^[^:]+:[0-9]{1,5}$ ]]; then
    host="${value%:*}"
    port="${value##*:}"
    if ! is_ipv4_valid "$host" && ! is_hostname_valid "$host"; then
      return 1
    fi
  else
    return 1
  fi

  is_port_valid "$port"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-no}"
  local answer=""

  while true; do
    read -r -p "$prompt" answer
    answer="${answer,,}"

    if [ -z "$answer" ]; then
      [ "$default" = "yes" ] && return 0
      return 1
    fi

    case "$answer" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo_err "Please enter y/yes or n/no."
        ;;
    esac
  done
}

read_listen_port() {
  local port=""

  while true; do
    read -r -p "Enter the local listening port [1-65535]: " port

    if ! is_port_valid "$port"; then
      echo_err "The port number must be between 1 and 65535."
      continue
    fi

    if forward_port_exists "$port"; then
      echo_err "That port is already used by an existing forwarding rule."
      continue
    fi

    if is_port_in_use "$port"; then
      echo_err "That port is already in use by another service."
      continue
    fi

    printf "%s\n" "$port"
    return 0
  done
}

read_remote_target() {
  local remote=""

  while true; do
    read -r -p "Enter the remote endpoint [host:port or [IPv6]:port]: " remote

    if ! is_remote_valid "$remote"; then
      echo_err "Invalid remote endpoint. Use host:port or [IPv6]:port."
      continue
    fi

    printf "%s\n" "$remote"
    return 0
  done
}

ensure_runtime_dirs() {
  install -d -m 0755 "$REALM_DIR"
  install -d -m 0755 "$REALM_LOG_DIR"
  touch "$REALM_LOG_FILE"
  touch "$REALM_ENDPOINTS"
}

write_realm_config() {
  local listen_port remote listen_addr

  ensure_runtime_dirs

  # [::] is dual-stack in realm (IPV6_V6ONLY is kept off), so it accepts IPv4 too.
  # Fall back to 0.0.0.0 only when the host has no IPv6 support at all.
  if [ -f /proc/net/if_inet6 ]; then
    listen_addr="[::]"
  else
    listen_addr="0.0.0.0"
  fi

  cat > "$REALM_CONFIG" <<EOF
[log]
level = "warn"
output = "${REALM_LOG_FILE}"

# Enable this block only if DNS resolution is unstable.
#[dns]
#mode = "ipv4_only"
#nameservers = ["8.8.8.8:53", "8.8.4.4:53"]
#min_ttl = 300
#max_ttl = 1800
#cache_size = 128

[network]
use_udp = true
tcp_timeout = 10
udp_timeout = 30
tcp_keepalive = 15
EOF

  while IFS='|' read -r listen_port remote || [ -n "${listen_port:-}" ]; do
    [ -n "${listen_port:-}" ] || continue
    cat >> "$REALM_CONFIG" <<EOF

[[endpoints]]
listen = "${listen_addr}:${listen_port}"
remote = "${remote}"
EOF
  done < "$REALM_ENDPOINTS"
}

write_service_unit() {
  mkdir -p "$(dirname "$REALM_UNIT")"
  cat > "$REALM_UNIT" <<EOF
[Unit]
Description=Realm Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG}
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

reload_systemd() {
  if have_cmd systemctl; then
    systemctl daemon-reload
  fi
}

restart_realm_service() {
  if ! have_cmd systemctl; then
    echo_warn "systemctl is not available. Please manage the Realm service manually."
    return 0
  fi

  reload_systemd
  systemctl enable "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$REALM_SERVICE_NAME"
}

stop_realm_service() {
  if ! have_cmd systemctl; then
    return 0
  fi

  systemctl stop "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl reset-failed "$REALM_SERVICE_NAME" >/dev/null 2>&1 || true
}

get_bbr_status() {
  local current=""

  if have_cmd sysctl; then
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  elif [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
    current=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  fi

  case "$current" in
    bbr)
      printf "%s\n" "$(color "$C_GREEN" "enabled (BBR)")"
      ;;
    bbr2)
      printf "%s\n" "$(color "$C_GREEN" "enabled (BBR2)")"
      ;;
    "")
      printf "%s\n" "$(color "$C_YELLOW" "unknown")"
      ;;
    *)
      printf "%s\n" "$(color "$C_YELLOW" "disabled (current: ${current})")"
      ;;
  esac
}

status_line() {
  local state forward_count
  forward_count=$(get_forward_count)

  if ! realm_is_installed; then
    state=$(color "$C_RED" "not installed")
  elif realm_has_forwards; then
    if have_cmd systemctl && systemctl is-active --quiet "$REALM_SERVICE_NAME"; then
      state=$(color "$C_GREEN" "running")
    else
      state=$(color "$C_YELLOW" "installed but not running")
    fi
  else
    state=$(color "$C_YELLOW" "installed but no forwards")
  fi

  echo "$(color "$C_BOLD" "Service Status:") ${state}"
  echo "$(color "$C_BOLD" "Config File:") $(color "$C_CYAN" "$REALM_CONFIG")"
  echo "$(color "$C_BOLD" "Log File:") $(color "$C_CYAN" "$REALM_LOG_FILE")"
  echo "$(color "$C_BOLD" "BBR Status:") $(get_bbr_status)"
  echo "$(color "$C_BOLD" "Forwarding Rules:") $(color "$C_GREEN" "$forward_count")"
}

show_forward_list() {
  local index=1
  local listen_port remote

  if ! realm_has_forwards; then
    echo_warn "No forwarding rules are configured."
    return 1
  fi

  print_section "Forwarding Rules"
  printf "%b%-6s %-14s %-42s%b\n" "$C_CYAN$C_BOLD" "Rule" "Listen Port" "Remote Endpoint" "$C_RESET"
  printf "%-6s %-14s %-42s\n" "----" "--------------" "------------------------------------------"

  while IFS='|' read -r listen_port remote || [ -n "${listen_port:-}" ]; do
    [ -n "${listen_port:-}" ] || continue
    printf "%b%-6s%b %-14s %-42s\n" "$C_GREEN" "$index" "$C_RESET" "$listen_port" "$remote"
    index=$((index + 1))
  done < "$REALM_ENDPOINTS"

  return 0
}

append_forward_rule() {
  local listen_port="$1"
  local remote="$2"

  ensure_runtime_dirs
  printf "%s|%s\n" "$listen_port" "$remote" >> "$REALM_ENDPOINTS"
}

configure_first_forward() {
  local listen_port remote

  ensure_port_check_tool || return 1
  listen_port=$(read_listen_port) || return 1
  remote=$(read_remote_target) || return 1

  append_forward_rule "$listen_port" "$remote"
  write_realm_config
  restart_realm_service
}

install_realm() {
  local target archive url tmp_dir tmp_archive realm_file

  if realm_is_installed; then
    echo_warn "Realm appears to be installed already. Uninstall it first if you want a clean reinstallation."
    return 1
  fi

  ensure_install_tools || return 1

  target=$(get_release_target) || {
    echo_err "Unsupported architecture: $(uname -m)"
    return 1
  }

  archive="realm-${target}.tar.gz"
  url=$(realm_download_url "$target")
  tmp_dir=$(mktemp -d)
  tmp_archive="${tmp_dir}/${archive}"

  echo_info "Downloading ${archive}..."
  if ! download_file "$url" "$tmp_archive"; then
    rm -rf "$tmp_dir"
    echo_err "Failed to download realm."
    return 1
  fi

  if ! tar -xzf "$tmp_archive" -C "$tmp_dir"; then
    rm -rf "$tmp_dir"
    echo_err "Failed to extract the release archive."
    return 1
  fi

  realm_file=$(find "$tmp_dir" -maxdepth 2 -type f -name realm | head -n 1)
  if [ -z "$realm_file" ] || [ ! -f "$realm_file" ]; then
    rm -rf "$tmp_dir"
    echo_err "The realm binary was not found in the archive."
    return 1
  fi

  install -d -m 0755 "$(dirname "$REALM_BIN")"
  install -m 0755 "$realm_file" "$REALM_BIN"
  ensure_runtime_dirs
  : > "$REALM_ENDPOINTS"
  write_realm_config
  write_service_unit
  reload_systemd
  rm -rf "$tmp_dir"

  echo_ok "Realm installation completed successfully."

  if prompt_yes_no "Add the first forwarding rule now? [Y/n]: " "yes"; then
    configure_first_forward
    echo_ok "The first forwarding rule was added and Realm has been started."
  else
    stop_realm_service
    echo_warn "Realm is installed, but no forwarding rules are configured yet, so the service was left stopped."
  fi
}

uninstall_realm() {
  if ! realm_is_installed; then
    echo_warn "Realm is not installed."
    return 0
  fi

  stop_realm_service
  rm -f "$REALM_UNIT"
  rm -f "$REALM_BIN"
  rm -rf "$REALM_DIR"
  rm -rf "$REALM_LOG_DIR"
  reload_systemd

  echo_ok "Realm was removed successfully."
}

add_forward() {
  local listen_port remote

  if ! realm_is_installed; then
    echo_err "Please install realm first."
    return 1
  fi

  ensure_port_check_tool || return 1
  listen_port=$(read_listen_port) || return 1
  remote=$(read_remote_target) || return 1

  append_forward_rule "$listen_port" "$remote"
  write_realm_config
  restart_realm_service

  echo_ok "Forwarding rule added successfully."
  show_forward_list || true
}

delete_forward() {
  local count idx current=1 tmp_file line

  if ! realm_is_installed; then
    echo_err "Please install realm first."
    return 1
  fi

  if ! realm_has_forwards; then
    echo_err "There are no forwarding rules to delete."
    return 1
  fi

  show_forward_list || return 1
  count=$(get_forward_count)
  echo ""
  read -r -p "Enter the rule number to delete [1-${count}]: " idx

  if [[ ! "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$count" ]; then
    echo_err "Invalid rule number."
    return 1
  fi

  tmp_file=$(mktemp)
  while IFS= read -r line || [ -n "${line:-}" ]; do
    [ -n "${line:-}" ] || continue
    if [ "$current" -ne "$idx" ]; then
      printf "%s\n" "$line" >> "$tmp_file"
    fi
    current=$((current + 1))
  done < "$REALM_ENDPOINTS"

  mv "$tmp_file" "$REALM_ENDPOINTS"
  write_realm_config

  if realm_has_forwards; then
    restart_realm_service
  else
    stop_realm_service
    echo_warn "The last forwarding rule was deleted, so the Realm service was stopped."
  fi

  echo_ok "Forwarding rule removed successfully."
  if realm_has_forwards; then
    show_forward_list || true
  fi
}

delete_script() {
  if realm_is_installed; then
    echo_warn "Realm is still installed. Uninstall Realm before removing the management script."
    return 1
  fi

  if [ -f "$REALM_SCRIPT_CMD" ]; then
    rm -f "$REALM_SCRIPT_CMD"
    echo_ok "Management script removed: ${REALM_SCRIPT_CMD}"
  else
    echo_warn "The management script was not found: ${REALM_SCRIPT_CMD}"
  fi
}

print_menu() {
  echo ""
  echo "$(color "$C_CYAN" "0.") Exit"
}

print_header() {
  local width=58
  local divider left_text right_label right_value padding
  divider=$(printf '%*s' "$width" '' | tr ' ' '-')
  left_text="  Erealm ${SCRIPT_VERSION}"
  right_label="Command: "
  right_value="${REALM_SHORTCUT_NAME}"
  padding=$(( width - ${#left_text} - ${#right_label} - ${#right_value} ))
  if [ "$padding" -lt 1 ]; then
    padding=1
  fi

  echo ""
  echo "$(color "$C_BLUE" "$divider")"
  printf "%b%s%b%*s%b%s%b%b%s%b\n" \
    "$C_CYAN$C_BOLD" "$left_text" "$C_RESET" \
    "$padding" "" \
    "$C_BLUE" "$right_label" "$C_RESET" \
    "$C_RED" "$right_value" "$C_RESET"
  echo "$(color "$C_BLUE" "$divider")"
}

run_menu_action() {
  if "$@"; then
    return 0
  fi

  pause_for_menu
  return 0
}

main() {
  require_root
  self_install

  while true; do
    print_header
    status_line
    if realm_has_forwards; then
      show_forward_list || true
    fi
    echo ""
    printf "[%s]\n" "$(color "$C_GREEN" "Main Menu")"
    print_menu
    read -r -p "Select an option [0]: " choice

    case "$choice" in
      0) exit 0 ;;
      *) echo_err "Invalid menu option." ;;
    esac
  done
}

main
