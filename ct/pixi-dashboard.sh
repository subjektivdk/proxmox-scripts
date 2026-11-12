#!/usr/bin/env bash
# pixi-dashboard LXC: creates an unprivileged Debian 13 container on a Proxmox host and installs the family
# status screen pixi-dashboard with go2rtc for cameras. Run as root on the Proxmox host:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/subjektivdk/proxmox-scripts/main/ct/pixi-dashboard.sh)"
#
# Run inside an existing pixi-dashboard container, it updates instead (same as `pixi-dashboard-lxc update`).
# No secrets in this script: the Home Assistant token and camera URLs are entered in the container afterwards.
# Author: subjektivdk · License: MIT · Style: community-scripts.org
set -Eeuo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/subjektivdk/proxmox-scripts/main}"

# Use a local checkout when the script is run from one, otherwise fetch from GitHub.
SRC_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "$(dirname "${BASH_SOURCE[0]}")/../misc/common.func" ]]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [[ -n "$SRC_DIR" ]]; then
  # shellcheck source=../misc/common.func
  source "$SRC_DIR/misc/common.func"
else
  # shellcheck source=/dev/null
  source <(curl -fsSL "$REPO_RAW/misc/common.func")
fi

# Defaults (override with environment variables, e.g. var_ram=2048 bash -c "$(curl ...)")
var_hostname="${var_hostname:-pixi-dashboard}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_swap="${var_swap:-512}"
var_disk="${var_disk:-6}"
var_bridge="${var_bridge:-vmbr0}"
var_net="${var_net:-dhcp}"            # dhcp or CIDR, e.g. 192.168.1.50/24
var_gateway="${var_gateway:-}"
var_timezone="${var_timezone:-Europe/Copenhagen}"
var_user="${var_user:-pixi}"
var_dash_repo="${var_dash_repo:-git@github.com:subjektivdk/pixi-dashboard.git}"
var_hub_host="${var_hub_host:-pixi-hub}"       # where pixi-hub runs (ssh, key locked to dashboard state)
var_ssh_key="${var_ssh_key:-}"        # public key text or path to a .pub file on the host

header_info() {
  clear 2>/dev/null || true
  cat <<'EOF'
           _       _       _           _
     _ __ (_)__  _(_)    __| | __ _ ___| |__
    | '_ \| |\ \/ / |___ / _` |/ _` / __| '_ \
    | |_) | | >  <| |___| (_| | (_| \__ \ | | |
    | .__/|_|/_/\_\_|    \__,_|\__,_|___/_| |_|
    |_|                    dashboard · LXC · Proxmox
EOF
  echo
}

# --- update mode (inside the container) --------------------------------------
if ! command -v pveversion >/dev/null 2>&1; then
  if command -v pixi-dashboard-lxc >/dev/null 2>&1; then
    exec pixi-dashboard-lxc update
  fi
  die "Kør scriptet som root på Proxmox-værten (eller i en pixi-dashboard-container for at opdatere)."
fi

# --- checks ------------------------------------------------------------------
header_info
[[ $EUID -eq 0 ]] || die "Kør som root."
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Kun amd64 understøttes."
command -v whiptail >/dev/null || die "whiptail mangler."

next_id() { pvesh get /cluster/nextid; }
first_storage() { pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'; }

var_ctid="${var_ctid:-$(next_id)}"
ROOT_STORAGES=$(first_storage rootdir)
TMPL_STORAGES=$(first_storage vztmpl)
var_storage="${var_storage:-$(grep -x local-lvm <<<"$ROOT_STORAGES" || head -n1 <<<"$ROOT_STORAGES")}"
var_tmpl_storage="${var_tmpl_storage:-$(grep -x local <<<"$TMPL_STORAGES" || head -n1 <<<"$TMPL_STORAGES")}"
[[ -n "$var_storage" ]] || die "Fandt ingen storage til containere (rootdir)."
[[ -n "$var_tmpl_storage" ]] || die "Fandt ingen storage til templates (vztmpl)."

# --- settings ----------------------------------------------------------------
wt() { whiptail --backtitle "pixi-dashboard LXC" "$@" 3>&1 1>&2 2>&3; }

show_settings() {
  cat <<EOF
  CT-ID:        $var_ctid
  Hostname:     $var_hostname
  CPU / RAM:    $var_cpu kerner / $var_ram MB (swap $var_swap MB)
  Disk:         $var_disk GB på $var_storage
  Netværk:      $var_bridge, ${var_net}${var_gateway:+ via $var_gateway}
  Tidszone:     $var_timezone
  Bruger:       $var_user
  Repo:         $var_dash_repo
  pixi-hub:     $var_hub_host
EOF
}

advanced_settings() {
  var_ctid=$(wt --inputbox "Container-ID" 8 60 "$var_ctid" --title "CT-ID") || exit 1
  var_hostname=$(wt --inputbox "Hostname" 8 60 "$var_hostname" --title "Hostname") || exit 1
  var_cpu=$(wt --inputbox "CPU-kerner" 8 60 "$var_cpu" --title "CPU") || exit 1
  var_ram=$(wt --inputbox "RAM i MB" 8 60 "$var_ram" --title "RAM") || exit 1
  var_disk=$(wt --inputbox "Disk i GB" 8 60 "$var_disk" --title "Disk") || exit 1
  local items=() s
  for s in $ROOT_STORAGES; do items+=("$s" "" "$([[ $s == "$var_storage" ]] && echo ON || echo OFF)"); done
  var_storage=$(wt --radiolist "Storage til containeren" 14 60 6 "${items[@]}" --title "Storage") || exit 1
  var_bridge=$(wt --inputbox "Bridge" 8 60 "$var_bridge" --title "Netværk") || exit 1
  var_net=$(wt --inputbox "IP: 'dhcp' eller fast med maske, fx 192.168.1.50/24" 8 60 "$var_net" --title "IP") || exit 1
  if [[ "$var_net" != "dhcp" ]]; then
    var_gateway=$(wt --inputbox "Gateway" 8 60 "${var_gateway:-$(ip route | awk '/^default/ {print $3; exit}')}" --title "Gateway") || exit 1
  fi
  var_timezone=$(wt --inputbox "Tidszone" 8 60 "$var_timezone" --title "Tidszone") || exit 1
  var_dash_repo=$(wt --inputbox "pixi-dashboard git-repo (SSH-URL)" 8 70 "$var_dash_repo" --title "Repo") || exit 1
  var_hub_host=$(wt --inputbox "Værten med pixi-hub (navn eller IP)" 8 60 "$var_hub_host" --title "pixi-hub") || exit 1
  var_ssh_key=$(wt --inputbox "SSH public key til root og $var_user (tekst eller sti til .pub). Tom = ingen" 10 70 "$var_ssh_key" --title "SSH") || exit 1
}

if [[ "${var_mode:-}" != "default" ]]; then
  choice=$(wt --title "pixi-dashboard LXC" --menu "Hvordan vil du oprette containeren?" 12 60 2 \
    "1" "Standard (anbefalet)" \
    "2" "Avanceret (vælg selv)") || exit 1
  [[ "$choice" == "2" ]] && advanced_settings
fi

# Validation
pct status "$var_ctid" >/dev/null 2>&1 && die "CT-ID $var_ctid findes allerede."
[[ "$var_cpu$var_ram$var_disk" =~ ^[0-9]+$ ]] || die "CPU, RAM og disk skal være tal."
if [[ "$var_net" != "dhcp" ]]; then
  [[ "$var_net" =~ ^[0-9.]+/[0-9]+$ ]] || die "Fast IP skal skrives med maske, fx 192.168.1.50/24."
  [[ -n "$var_gateway" ]] || die "Fast IP kræver en gateway."
  if ping -c1 -W1 "${var_net%/*}" >/dev/null 2>&1; then
    die "${var_net%/*} svarer allerede på ping. Vælg en anden IP."
  fi
fi
if [[ -n "$var_ssh_key" && -f "$var_ssh_key" ]]; then
  var_ssh_key=$(<"$var_ssh_key")
fi

echo -e "${BOLD}Indstillinger${CL}"
show_settings
echo
# var_mode=default runs without questions (e.g. over ssh); setup then runs with pixi-dashboard-lxc setup.
if [[ "${var_mode:-}" != "default" ]]; then
  whiptail --backtitle "pixi-dashboard LXC" --title "Klar?" --yesno "Opret containeren med disse indstillinger?\n\n$(show_settings)" 20 70 || exit 1
fi

# --- template ----------------------------------------------------------------
msg_info "Finder Debian 13-template"
TEMPLATE=$(pveam list "$var_tmpl_storage" | awk '{print $1}' | grep -o 'debian-13-standard_[^ ]*amd64\.tar\.zst' | sort -V | tail -n1 || true)
if [[ -z "$TEMPLATE" ]]; then
  silent pveam update
  TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard_.*amd64' | sort -V | tail -n1)
  [[ -n "$TEMPLATE" ]] || die "Fandt ingen debian-13-standard-template."
  msg_info "Henter $TEMPLATE"
  silent pveam download "$var_tmpl_storage" "$TEMPLATE"
fi
msg_ok "Template: $TEMPLATE"

# --- create ------------------------------------------------------------------
NET="name=eth0,bridge=$var_bridge,ip=$var_net"
[[ "$var_net" != "dhcp" ]] && NET+=",gw=$var_gateway"

msg_info "Opretter container $var_ctid"
CREATE_ARGS=(
  "$var_ctid" "$var_tmpl_storage:vztmpl/$TEMPLATE"
  --hostname "$var_hostname"
  --cores "$var_cpu" --memory "$var_ram" --swap "$var_swap"
  --rootfs "$var_storage:$var_disk"
  --net0 "$NET"
  --unprivileged 1 --features nesting=1
  --onboot 1 --timezone "$var_timezone"
  --ostype debian
  --tags "pixi-dashboard;go2rtc"
  --description "pixi-dashboard: statusskærm (kalender, vejr, elpris, kamera). Opdatér: pixi-dashboard-lxc update"
)
if [[ -n "$var_ssh_key" ]]; then
  KEYFILE=$(mktemp)
  printf '%s\n' "$var_ssh_key" >"$KEYFILE"
  CREATE_ARGS+=(--ssh-public-keys "$KEYFILE")
fi
silent pct create "${CREATE_ARGS[@]}"
[[ -n "${KEYFILE:-}" ]] && rm -f "$KEYFILE"
msg_ok "Oprettede container $var_ctid ($var_hostname)"

msg_info "Starter container"
silent pct start "$var_ctid"
for _ in $(seq 60); do
  pct exec "$var_ctid" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 1
done
pct exec "$var_ctid" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "Containeren fik ikke netværk/DNS."
msg_ok "Container kører og har netværk"

# --- install -----------------------------------------------------------------
msg_info "Kopierer scripts ind i containeren"
STAGE=$(mktemp -d)
for f in misc/common.func install/pixi-dashboard-install.sh tools/pixi-dashboard-lxc; do
  mkdir -p "$STAGE/$(dirname "$f")"
  if [[ -n "$SRC_DIR" ]]; then
    cp "$SRC_DIR/$f" "$STAGE/$f"
  else
    curl -fsSL "$REPO_RAW/$f" -o "$STAGE/$f"
  fi
done
pct exec "$var_ctid" -- mkdir -p /opt/pixi-dashboard-lxc/misc /opt/pixi-dashboard-lxc/install /opt/pixi-dashboard-lxc/tools
for f in misc/common.func install/pixi-dashboard-install.sh tools/pixi-dashboard-lxc; do
  pct push "$var_ctid" "$STAGE/$f" "/opt/pixi-dashboard-lxc/$f" --perms 0755
done
rm -rf "$STAGE"
msg_ok "Kopierede scripts"

stop_spinner
pct exec "$var_ctid" -- env \
  DASH_USER="$var_user" DASH_REPO="$var_dash_repo" HUB_HOST="$var_hub_host" \
  REPO_RAW="$REPO_RAW" VERBOSE="${VERBOSE:-no}" SSH_KEY="$var_ssh_key" \
  bash /opt/pixi-dashboard-lxc/install/pixi-dashboard-install.sh

# --- interactive setup -------------------------------------------------------
IP=$(pct exec "$var_ctid" -- hostname -I | awk '{print $1}')
echo
msg_ok "Grundinstallationen er færdig"
echo
if [[ "${var_mode:-}" != "default" ]] && whiptail --backtitle "pixi-dashboard LXC" --title "Opsætning" --yesno \
  "Vil du gøre opsætningen færdig nu?\n\n1. Deploy key til pixi-dashboard på GitHub\n2. Nøglen til pixi-hub (låst til dashboard state)\n3. Start tjenesten\n\nKameraer og Home Assistant bagefter i containeren:\n  pixi-dashboard-lxc camera hoveddor\n  pixi-dashboard-lxc ha-token" 19 70; then
  pct exec "$var_ctid" -- /usr/bin/pixi-dashboard-lxc setup
fi

echo
msg_ok "Færdig!"
echo -e "${INFO}${YW}Container:${CL} $var_ctid ($var_hostname) på ${BGN}${IP}${CL}"
echo -e "${INFO}${YW}Skærmen:${CL}   http://${IP}:8080/   ·   indstillinger: http://${IP}:8080/admin (kun fra edit_from)"
echo -e "${INFO}${YW}SSH:${CL}       ssh $var_user@$IP"
echo -e "${INFO}${YW}Status:${CL}    pct exec $var_ctid -- pixi-dashboard-lxc status"
