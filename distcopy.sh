#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-distcopy.yaml}"
CURRENT_DIR="$(pwd)"
LOG_FILE="${LOG_FILE:-distcopy.log}"

# ===== Logging =====
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  exit 1
}

rotate_log() {
  local max_lines="${1:-2000}"
  local keep_files="${2:-5}"

  [[ -f "$LOG_FILE" ]] || return 0

  local lines
  lines="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
  [[ "$lines" =~ ^[0-9]+$ ]] || return 0
  (( lines < max_lines )) && return 0

  local i
  for ((i = keep_files; i >= 1; i--)); do
    if [[ -f "${LOG_FILE}.${i}" ]]; then
      if (( i == keep_files )); then
        rm -f "${LOG_FILE}.${i}"
      else
        mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
      fi
    fi
  done
  mv "$LOG_FILE" "${LOG_FILE}.1"
  : > "$LOG_FILE"
}

# ===== Helpers =====
is_interactive() { [[ -t 0 && -t 1 ]]; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

check_step() {
  local label="$1"
  shift
  printf '%s ' "$label"
  if "$@" >/dev/null 2>&1; then
    printf '✅\n'
    return 0
  else
    printf '❌\n'
    return 1
  fi
}

sanitize_distro_name() {
  local distro="$1"
  distro="${distro,,}"
  distro="${distro// /_}"
  distro="${distro//-/_}"
  echo "$distro"
}

# ===== Dependencies =====
detect_pkg_manager() {
  if command_exists apt-get; then echo apt
  elif command_exists dnf; then echo dnf
  elif command_exists pacman; then echo pacman
  elif command_exists zypper; then echo zypper
  else echo ""; fi
}

install_dependency() {
  local pkg="$1"
  local mgr
  mgr="$(detect_pkg_manager)"
  [[ -n "$mgr" ]] || fail "No supported package manager found to install '$pkg'."

  case "$mgr" in
    apt) apt-get update && apt-get install -y "$pkg" ;;
    dnf) dnf install -y "$pkg" ;;
    pacman) pacman -Sy --noconfirm "$pkg" ;;
    zypper) zypper --non-interactive install "$pkg" ;;
  esac
}

ask_install_with_dialog() {
  local pkg="$1"
  dialog --title "Missing dependency" \
    --yesno "'$pkg' is missing. Install now?" 8 60
}

ensure_dialog_available() {
  if command_exists dialog; then
    return 0
  fi

  if ! is_interactive; then
    fail "'dialog' is required but not installed."
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "'dialog' is missing and you do not have root privileges."
  fi

  read -r -p "'dialog' is missing. Install now? [y/N] " answer
  if [[ "${answer,,}" =~ ^(y|yes)$ ]]; then
    install_dependency dialog
  else
    fail "Cannot continue without 'dialog'."
  fi
}

ensure_base_dependencies() {
  local missing=()

  check_step "checking for wget....." command_exists wget || missing+=("wget")
  check_step "checking for rtorrent....." command_exists rtorrent || missing+=("rtorrent")

  if check_step "checking for cron....." command_exists cron; then
    :
  elif check_step "checking for cron (crond)....." command_exists crond; then
    :
  else
    missing+=("cron")
  fi

  [[ ${#missing[@]} -eq 0 ]] && return 0

  if ! is_interactive; then
    fail "Missing dependencies in non-interactive mode: ${missing[*]}"
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Missing dependencies but no root privileges: ${missing[*]}"
  fi

  local dep pkg
  for dep in "${missing[@]}"; do
    pkg="$dep"
    if [[ "$dep" == "cron" ]] && (command_exists dnf || command_exists pacman); then
      pkg="cronie"
    fi

    if ask_install_with_dialog "$pkg"; then
      install_dependency "$pkg"
      log "Installed dependency: $pkg"
    else
      fail "Dependency installation cancelled: $pkg"
    fi
  done
}

# ===== Config =====
read_yaml_value() {
  local key="$1" default="$2"
  local value
  value="$(awk -F': *' -v key="$key" '$1 == key {print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)"
  value="${value//\"/}"
  value="${value//\'/}"
  [[ -n "$value" ]] && echo "$value" || echo "$default"
}

read_yaml_distros() {
  awk '
    /^distros:/ {in_list=1; next}
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      gsub(/"/, "", $0)
      gsub(/\047/, "", $0)
      print $0
      next
    }
    in_list && !/^[[:space:]]*-/ {in_list=0}
  ' "$CONFIG_FILE" 2>/dev/null || true
}

setup_config_with_dialog() {
  local tmpfile
  tmpfile="$(mktemp)"

  dialog --clear --backtitle "distcopy setup" --title "Distro selection" \
    --checklist "Choose distros for distcopy.yaml:" 18 72 8 \
    arch_linux "Arch Linux" on \
    debian "Debian" on \
    ubuntu "Ubuntu" on \
    openwrt_x86 "OpenWrt x86" off \
    cachy_os "Cachy OS" off 2>"$tmpfile"

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmpfile"
    fail "Setup cancelled."
  fi

  local selected
  selected="$(tr -d '"' < "$tmpfile")"
  rm -f "$tmpfile"
  [[ -n "$selected" ]] || fail "No distro selected."

  cat > "$CONFIG_FILE" <<EOF_CONF
# distcopy configuration
# mode: check | wget | torrent | cron
# cron_download_mode: wget | torrent | auto
# download_method: wget | rtorrent

mode: wget
cron_download_mode: auto
download_method: wget
max_files_per_distro: 3
min_free_gb: 5
downloads_dir: downloads
log_max_lines: 2000
log_keep_files: 5
distros:
EOF_CONF

  local d
  for d in $selected; do
    printf '  - %s\n' "$d" >> "$CONFIG_FILE"
  done

  log "Created configuration: $CONFIG_FILE"
}

# ===== Distro URLs =====
# distro|direct_url|torrent_url
DISTRO_SOURCES=(
  "arch_linux|https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso|https://archlinux.org/releng/releases/2026.04.01/torrent/"
  "debian|https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-amd64-netinst.iso|https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/debian-amd64-netinst.iso.torrent"
  "ubuntu|https://releases.ubuntu.com/noble/ubuntu-24.04.2-desktop-amd64.iso|https://releases.ubuntu.com/noble/ubuntu-24.04.2-desktop-amd64.iso.torrent"
  "openwrt_x86|https://downloads.openwrt.org/releases/23.05.5/targets/x86/64/openwrt-23.05.5-x86-64-generic-ext4-combined-efi.img.gz|"
  "cachy_os|https://mirror.cachyos.org/ISO/latest/cachyos-desktop-linux-x86_64.iso|"
)

resolve_source() {
  local distro="$1"
  local line key direct torrent
  for line in "${DISTRO_SOURCES[@]}"; do
    key="${line%%|*}"
    if [[ "$key" == "$distro" ]]; then
      direct="${line#*|}"
      direct="${direct%%|*}"
      torrent="${line##*|}"
      echo "$direct|$torrent"
      return 0
    fi
  done
  return 1
}

# ===== Checks =====
check_write_access() { [[ -w "$CURRENT_DIR" ]]; }
check_config_exists() { [[ -f "$CONFIG_FILE" ]]; }

check_disk_space() {
  local min_free_gb="$1"
  local avail_kb required_kb
  avail_kb="$(df -Pk "$CURRENT_DIR" | awk 'NR==2 {print $4}')"
  required_kb=$((min_free_gb * 1024 * 1024))
  (( avail_kb >= required_kb ))
}

ensure_download_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || mkdir -p "$dir"
}

run_check_mode() {
  check_step "checking for write permissions....." check_write_access || fail "No write permissions in $CURRENT_DIR"
  check_step "checking for config file (${CONFIG_FILE})....." check_config_exists || fail "Missing config file: $CONFIG_FILE"

  local min_free_gb downloads_dir
  min_free_gb="$(read_yaml_value "min_free_gb" "5")"
  downloads_dir="$(read_yaml_value "downloads_dir" "downloads")"

  [[ "$min_free_gb" =~ ^[0-9]+$ ]] || fail "min_free_gb must be numeric"

  check_step "checking for free disk space (${min_free_gb}GB)....." check_disk_space "$min_free_gb" || fail "Not enough free disk space"

  ensure_download_dir "$downloads_dir"
  check_step "checking for downloads directory (${downloads_dir})....." test -d "$downloads_dir" || fail "Cannot create downloads directory"
}

# ===== Download + prune =====
build_target_file_for_wget() {
  local distro="$1" url="$2"
  local base name ext

  base="${url##*/}"
  [[ -n "$base" ]] || base="${distro}.img"

  if [[ "$base" == *.* ]]; then
    ext=".${base##*.}"
    name="${base%.*}"
  else
    ext=""
    name="$base"
  fi

  if [[ "$url" == *latest* ]]; then
    name="${name}_$(date +%Y%m%d_%H%M%S)"
  fi

  echo "${distro}_${name}${ext}"
}

download_via_wget() {
  local distro="$1" direct_url="$2" target_dir="$3"
  local target_file
  target_file="$(build_target_file_for_wget "$distro" "$direct_url")"

  log "WGET MODE: downloading $distro"
  wget -c -O "$target_dir/$target_file" "$direct_url"
  log "WGET MODE: completed $target_dir/$target_file"
}

download_via_rtorrent() {
  local distro="$1" torrent_url="$2" target_dir="$3"
  local torrent_file
  torrent_file="$(mktemp --suffix=.torrent)"

  [[ -n "$torrent_url" ]] || fail "TORRENT MODE: no torrent URL configured for '$distro'"

  log "TORRENT MODE: fetching torrent metadata for $distro"
  if ! wget -q -O "$torrent_file" "$torrent_url"; then
    rm -f "$torrent_file"
    fail "TORRENT MODE: failed to fetch torrent file for '$distro'"
  fi

  log "TORRENT MODE: starting rtorrent for $distro"
  if rtorrent "$torrent_file"; then
    log "TORRENT MODE: rtorrent exited successfully for $distro"
  else
    local rc=$?
    log "TORRENT MODE: rtorrent exited with code $rc for $distro"
    rm -f "$torrent_file"
    fail "TORRENT MODE failed for '$distro'"
  fi

  rm -f "$torrent_file"
  log "TORRENT MODE: removed torrent metadata file for $distro"
}

prune_old_files_wget_only() {
  local distro="$1" target_dir="$2" keep_max="$3"

  mapfile -t files < <(find "$target_dir" -maxdepth 1 -type f -name "${distro}_*" \
    ! -name "*.part" ! -name "*.tmp" ! -name "*.torrent" \
    -printf '%T@ %p\n' | sort -n | awk '{print $2}')

  local count="${#files[@]}"
  (( count <= keep_max )) && return

  local remove_count=$((count - keep_max))
  local i
  for ((i = 0; i < remove_count; i++)); do
    rm -f "${files[$i]}"
    log "Pruned old file (${distro}): ${files[$i]}"
  done
}

execute_downloads() {
  local mode="$1"
  local download_method configured_method max_files downloads_dir

  configured_method="$(read_yaml_value "download_method" "wget")"
  max_files="$(read_yaml_value "max_files_per_distro" "3")"
  downloads_dir="$(read_yaml_value "downloads_dir" "downloads")"

  [[ "$max_files" =~ ^[0-9]+$ ]] || fail "max_files_per_distro must be numeric"
  [[ "$configured_method" =~ ^(wget|rtorrent)$ ]] || fail "download_method must be wget or rtorrent"

  case "$mode" in
    wget) download_method="wget" ;;
    torrent) download_method="rtorrent" ;;
    cron|auto) download_method="$configured_method" ;;
    *) fail "Invalid execute_downloads mode: $mode" ;;
  esac

  mapfile -t distros < <(read_yaml_distros)
  [[ ${#distros[@]} -gt 0 ]] || fail "No distros configured in distros:"

  local distro normalized source direct torrent
  for distro in "${distros[@]}"; do
    normalized="$(sanitize_distro_name "$distro")"
    source="$(resolve_source "$normalized" || true)"

    if [[ -z "$source" ]]; then
      log "Unknown distro in config, skipping: $distro"
      continue
    fi

    direct="${source%%|*}"
    torrent="${source##*|}"

    case "$download_method" in
      wget)
        log "Selected download_method=wget"
        download_via_wget "$normalized" "$direct" "$downloads_dir"
        prune_old_files_wget_only "$normalized" "$downloads_dir" "$max_files"
        ;;
      rtorrent)
        log "Selected download_method=rtorrent"
        download_via_rtorrent "$normalized" "$torrent" "$downloads_dir"
        log "RTORRENT DOWNLOAD: pruning skipped to avoid deleting unfinished torrent data"
        ;;
    esac
  done
}

run_wget_mode() {
  run_check_mode
  execute_downloads "wget"
}

run_torrent_mode() {
  run_check_mode
  execute_downloads "torrent"
}

run_cron_mode() {
  run_check_mode
  local cron_mode
  cron_mode="$(read_yaml_value "cron_download_mode" "wget")"

  case "$cron_mode" in
    wget) execute_downloads "wget" ;;
    torrent) execute_downloads "torrent" ;;
    auto) execute_downloads "auto" ;;
    *) fail "cron_download_mode must be wget, torrent, or auto" ;;
  esac
}

main() {
  ensure_dialog_available

  if [[ "${1:-}" == "--setup" ]]; then
    setup_config_with_dialog
    exit 0
  fi

  if ! check_config_exists; then
    fail "Missing config file: $CONFIG_FILE (run './distcopy.sh --setup')"
  fi

  local log_max_lines log_keep_files
  log_max_lines="$(read_yaml_value "log_max_lines" "2000")"
  log_keep_files="$(read_yaml_value "log_keep_files" "5")"
  rotate_log "$log_max_lines" "$log_keep_files"

  ensure_base_dependencies

  local mode
  mode="$(read_yaml_value "mode" "wget")"

  case "$mode" in
    check) run_check_mode ;;
    wget) run_wget_mode ;;
    torrent) run_torrent_mode ;;
    cron) run_cron_mode ;;
    *) fail "mode must be one of: check, wget, torrent, cron" ;;
  esac

  log "Done."
}

main "$@"
