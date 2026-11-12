#!/usr/bin/env bash
# Runs inside a new pixi-dashboard container (called by ct/pixi-dashboard.sh). Installs packages, the user,
# uv, go2rtc, keys for GitHub and for pixi-hub, a starter config and the pixi-dashboard-lxc tool.
# No secrets are written here: the Home Assistant token and camera URLs are entered afterwards with
#   pixi-dashboard-lxc ha-token  /  pixi-dashboard-lxc camera <navn>
# Author: subjektivdk · License: MIT
set -Eeuo pipefail
source /opt/pixi-dashboard-lxc/misc/common.func

DASH_USER="${DASH_USER:-pixi}"
DASH_REPO="${DASH_REPO:-git@github.com:subjektivdk/pixi-dashboard.git}"
HUB_HOST="${HUB_HOST:-pixi-hub}"
GO2RTC_VERSION="${GO2RTC_VERSION:-1.9.15}"
export DEBIAN_FRONTEND=noninteractive

msg_info "Opdaterer Debian"
silent apt-get update
silent apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
msg_ok "Opdaterede Debian"

msg_info "Installerer pakker"
silent apt-get install -y --no-install-recommends \
  ca-certificates curl git sudo openssh-server openssh-client locales whiptail dbus-user-session less nano jq \
  ffmpeg   # go2rtc laver stillbilleder (frame.jpeg) med ffmpeg; statustjek og selvhelbredelse bruger dem
sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(da_DK.UTF-8\)/\1/' /etc/locale.gen
silent locale-gen
update-locale LANG=en_US.UTF-8
msg_ok "Installerede pakker"

msg_info "Installerer go2rtc $GO2RTC_VERSION"
curl -fsSL -o /usr/local/bin/go2rtc \
  "https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/go2rtc_linux_amd64"
chmod 0755 /usr/local/bin/go2rtc
msg_ok "Installerede $(/usr/local/bin/go2rtc -version 2>&1 | head -1)"

msg_info "Opretter brugeren $DASH_USER"
id "$DASH_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DASH_USER"
HOME_DIR=$(getent passwd "$DASH_USER" | cut -d: -f6)
install -d -m 0700 -o "$DASH_USER" -g "$DASH_USER" "$HOME_DIR/.ssh" "$HOME_DIR/.config/pixi-dashboard"
install -d -o "$DASH_USER" -g "$DASH_USER" "$HOME_DIR/Projects" "$HOME_DIR/.config/systemd/user" \
  "$HOME_DIR/.local/share/pixi-dashboard" "$HOME_DIR/.local/state/pixi-dashboard"
chown -R "$DASH_USER:$DASH_USER" "$HOME_DIR/.local" "$HOME_DIR/.config"
if [[ -n "${SSH_KEY:-}" ]] && ! grep -qF "$SSH_KEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null; then
  printf '%s\n' "$SSH_KEY" >>"$HOME_DIR/.ssh/authorized_keys"
fi
touch "$HOME_DIR/.ssh/authorized_keys"
chown "$DASH_USER:$DASH_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
[[ -f "$HOME_DIR/.config/pixi-dashboard/env" ]] ||
  install -m 0600 -o "$DASH_USER" -g "$DASH_USER" /dev/null "$HOME_DIR/.config/pixi-dashboard/env"
loginctl enable-linger "$DASH_USER"
msg_ok "Oprettede brugeren $DASH_USER (linger slået til)"

as_dash() { (cd "$HOME_DIR" && runuser -u "$DASH_USER" -- env HOME="$HOME_DIR" USER="$DASH_USER" PATH="$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"); }

msg_info "Installerer uv"
silent as_dash sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
msg_ok "Installerede uv $(as_dash uv --version 2>/dev/null | cut -d' ' -f2)"

msg_info "Laver nøgler til GitHub og til pixi-hub"
[[ -f "$HOME_DIR/.ssh/pixi-dashboard-deploy" ]] ||
  runuser -u "$DASH_USER" -- ssh-keygen -q -t ed25519 -N "" -C "pixi-dashboard deploy key" -f "$HOME_DIR/.ssh/pixi-dashboard-deploy"
# A separate key for pixi-hub: the hub's authorized_keys locks it to `pixi-hub --json dashboard state`.
[[ -f "$HOME_DIR/.ssh/pixi-hub-dashboard" ]] ||
  runuser -u "$DASH_USER" -- ssh-keygen -q -t ed25519 -N "" -C "pixi-dashboard -> pixi-hub (dashboard state)" -f "$HOME_DIR/.ssh/pixi-hub-dashboard"
if ! grep -q "pixi-dashboard-deploy" "$HOME_DIR/.ssh/config" 2>/dev/null; then
  cat >>"$HOME_DIR/.ssh/config" <<EOF
Host github.com
  IdentityFile ~/.ssh/pixi-dashboard-deploy
  IdentitiesOnly yes

Host $HUB_HOST
  User pixi
  IdentityFile ~/.ssh/pixi-hub-dashboard
  IdentitiesOnly yes
EOF
  chown "$DASH_USER:$DASH_USER" "$HOME_DIR/.ssh/config"
  chmod 600 "$HOME_DIR/.ssh/config"
fi
runuser -u "$DASH_USER" -- sh -c 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null'
msg_ok "Lavede nøgler (deploy key og hub-nøgle)"

msg_info "Skriver en startconfig"
CFG="$HOME_DIR/.config/pixi-dashboard/config.toml"
if [[ ! -f "$CFG" ]]; then
  cat >"$CFG" <<EOF
# pixi-dashboard. Ret i /admin i browseren eller her; skærmen tegner om, når filen gemmes.
panels = ["calendar", "weather", "electricity", "clock"]

[sources.hub]
ssh = "$HUB_HOST"

[server]
host = "0.0.0.0"
port = 8080
edit_from = []   # net, der må bruge /admin, fx ["192.168.1.0/24"] (localhost må altid)

[go2rtc]
binary = "/usr/local/bin/go2rtc"

# Kameraer: [cameras.hoveddor] med title = "Hoveddør"; URL'en sættes med: pixi-dashboard-lxc camera hoveddor
# Home Assistant: [sources.ha] med url = "http://192.168.1.24:8123"; token: pixi-dashboard-lxc ha-token
EOF
  chown "$DASH_USER:$DASH_USER" "$CFG"
fi
msg_ok "Startconfig i $CFG"

msg_info "Gemmer indstillinger og installerer pixi-dashboard-lxc"
cat >/etc/pixi-dashboard-lxc.conf <<EOF
DASH_USER="$DASH_USER"
DASH_REPO="$DASH_REPO"
HUB_HOST="$HUB_HOST"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/subjektivdk/proxmox-scripts/main}"
EOF
ln -sf /opt/pixi-dashboard-lxc/tools/pixi-dashboard-lxc /usr/local/bin/pixi-dashboard-lxc
ln -sf /opt/pixi-dashboard-lxc/tools/pixi-dashboard-lxc /usr/bin/pixi-dashboard-lxc
cat >/usr/local/bin/pixi-dashboard <<'EOF2'
#!/usr/bin/env bash
exec "$HOME/.local/bin/pixi-dashboard" "$@"
EOF2
chmod 0755 /usr/local/bin/pixi-dashboard
msg_ok "Installerede pixi-dashboard-lxc"
