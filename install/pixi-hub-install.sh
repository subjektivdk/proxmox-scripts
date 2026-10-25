#!/usr/bin/env bash
# Runs inside the new container (as root), called by ct/pixi-hub.sh. Non-interactive.
# Installs: base packages, Node.js 24 LTS, obsidian-headless, uv, rclone, age, the user and the
# obsidian-sync user unit. pixi-hub itself is cloned later by `pixi-hub-lxc setup` (needs a deploy key).
# License: MIT
set -Eeuo pipefail
# shellcheck source=../misc/common.func
source /opt/pixi-hub-lxc/misc/common.func

HUB_USER="${HUB_USER:-pixi}"
DEVICE_NAME="${DEVICE_NAME:-pixi-hub-lxc}"
HUB_REPO="${HUB_REPO:-git@github.com:subjektivdk/pixi-hub.git}"
export DEBIAN_FRONTEND=noninteractive

msg_info "Opdaterer Debian"
silent apt-get update
silent apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
msg_ok "Opdaterede Debian"

msg_info "Installerer pakker"
silent apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git sudo openssh-server locales \
  rclone rsync age jq sqlite3 whiptail dbus-user-session less nano
sed -i 's/^# *\(en_US.UTF-8\)/\1/; s/^# *\(da_DK.UTF-8\)/\1/' /etc/locale.gen
silent locale-gen
update-locale LANG=en_US.UTF-8
msg_ok "Installerede pakker"

msg_info "Installerer Node.js 24 LTS (NodeSource)"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  >/etc/apt/sources.list.d/nodesource.list
silent apt-get update
silent apt-get install -y nodejs
msg_ok "Installerede Node.js $(node --version)"

msg_info "Installerer obsidian-headless"
silent npm install -g obsidian-headless
msg_ok "Installerede obsidian-headless $(npm ls -g obsidian-headless --depth=0 2>/dev/null | grep -o '@[0-9.]*' | tr -d @)"

msg_info "Opretter brugeren $HUB_USER"
if ! id "$HUB_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$HUB_USER"
fi
HOME_DIR=$(getent passwd "$HUB_USER" | cut -d: -f6)
install -d -m 0700 -o "$HUB_USER" -g "$HUB_USER" "$HOME_DIR/.ssh" "$HOME_DIR/.config/pixi-hub"
install -d -o "$HUB_USER" -g "$HUB_USER" "$HOME_DIR/Projects" "$HOME_DIR/vault" \
  "$HOME_DIR/.config/systemd/user" "$HOME_DIR/.local/share/pixi-hub"
if [[ -n "${SSH_KEY:-}" ]] && ! grep -qF "$SSH_KEY" "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null; then
  printf '%s\n' "$SSH_KEY" >>"$HOME_DIR/.ssh/authorized_keys"
fi
touch "$HOME_DIR/.ssh/authorized_keys"
chown "$HUB_USER:$HUB_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
# Secrets file for pixi-hub (TYPESAFE_API_KEY, Google tokens ...); filled in during migration.
if [[ ! -f "$HOME_DIR/.config/pixi-hub/env" ]]; then
  install -m 0600 -o "$HUB_USER" -g "$HUB_USER" /dev/null "$HOME_DIR/.config/pixi-hub/env"
fi
loginctl enable-linger "$HUB_USER"
msg_ok "Oprettede brugeren $HUB_USER (linger slået til)"

msg_info "Installerer uv"
runuser -l "$HUB_USER" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null 2>&1 \
  || die "uv-installationen fejlede."
msg_ok "Installerede uv"

msg_info "Installerer Claude Code"
# Used by readiness challengers that ask Claude (headless `claude -p`). Logged in later with `pixi-hub-lxc claude`.
if runuser -l "$HUB_USER" -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1; then
  msg_ok "Installerede Claude Code ($(runuser -u "$HUB_USER" -- "$HOME_DIR/.local/bin/claude" --version 2>/dev/null | head -1))"
else
  msg_warn "Claude Code kunne ikke installeres. Prøv igen senere med: pixi-hub-lxc claude"
fi

msg_info "Henter hubbens hemmeligheder i login-shells"
# So `ssh pixi@pixi-hub pixi-hub ...` sees the same secrets as the systemd service (EnvironmentFile).
if ! grep -q "pixi-hub/env" "$HOME_DIR/.profile" 2>/dev/null; then
  cat >>"$HOME_DIR/.profile" <<'EOF2'

# pixi-hub's secrets (the same file the systemd service reads), added by pixi-hub-lxc.
[ -r "$HOME/.config/pixi-hub/env" ] && { set -a; . "$HOME/.config/pixi-hub/env"; set +a; }
EOF2
  chown "$HUB_USER:$HUB_USER" "$HOME_DIR/.profile"
fi
msg_ok "Login-shells læser ~/.config/pixi-hub/env"

msg_info "Laver deploy key til GitHub"
if [[ ! -f "$HOME_DIR/.ssh/pixi-hub-deploy" ]]; then
  runuser -u "$HUB_USER" -- ssh-keygen -q -t ed25519 -N "" -C "$DEVICE_NAME deploy key" -f "$HOME_DIR/.ssh/pixi-hub-deploy"
fi
if ! grep -q "pixi-hub-deploy" "$HOME_DIR/.ssh/config" 2>/dev/null; then
  cat >>"$HOME_DIR/.ssh/config" <<'EOF'
Host github.com
  IdentityFile ~/.ssh/pixi-hub-deploy
  IdentitiesOnly yes
EOF
  chown "$HUB_USER:$HUB_USER" "$HOME_DIR/.ssh/config"
  chmod 600 "$HOME_DIR/.ssh/config"
fi
runuser -u "$HUB_USER" -- sh -c 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null'
msg_ok "Lavede deploy key"

msg_info "Opretter obsidian-sync.service"
cat >"$HOME_DIR/.config/systemd/user/obsidian-sync.service" <<'EOF'
# Obsidian Headless Sync: holds ~/vault in sync with Obsidian Sync (pixi-hub-lxc, proxmox-scripts).
[Unit]
Description=Obsidian Headless Sync (~/vault)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ob sync --continuous --path %h/vault
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF
chown "$HUB_USER:$HUB_USER" "$HOME_DIR/.config/systemd/user/obsidian-sync.service"
msg_ok "Oprettede obsidian-sync.service (ikke startet endnu)"

msg_info "Gemmer indstillinger og installerer pixi-hub-lxc"
cat >/etc/pixi-hub-lxc.conf <<EOF
HUB_USER="$HUB_USER"
HUB_REPO="$HUB_REPO"
DEVICE_NAME="$DEVICE_NAME"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/subjektivdk/proxmox-scripts/main}"
EOF
ln -sf /opt/pixi-hub-lxc/tools/pixi-hub-lxc /usr/local/bin/pixi-hub-lxc
# "update" in the container, as in the community-scripts LXCs.
cat >/usr/bin/update <<'EOF2'
#!/usr/bin/env bash
# Updates Debian, obsidian-headless, the pixi-hub-lxc scripts and pixi-hub (proxmox-scripts).
exec /usr/local/bin/pixi-hub-lxc update "$@"
EOF2
chmod 0755 /usr/bin/update
msg_ok "Installerede pixi-hub-lxc"

msg_info "Rydder op"
silent apt-get -y autoremove
silent apt-get -y autoclean
msg_ok "Ryddede op"
