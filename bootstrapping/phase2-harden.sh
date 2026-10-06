#!/usr/bin/env bash
# Phase 2: run ONLY after confirming Tailscale SSH works (see phase1
# output). Must be invoked over Tailscale -- refuses to run if the current
# SSH session came in over the public interface, to avoid self-lockout.
# Safe to re-run.
#
# Usage: sudo bash phase2-harden.sh "$SSH_CONNECTION"
# The connection string is passed as an argument because sudo-rs doesn't
# carry SSH_CONNECTION through to root's environment.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo $0 \"\$SSH_CONNECTION\")" >&2
  exit 1
fi

# --- Safety guard: refuse to run unless we're already on Tailscale ------
if ! systemctl is-active --quiet tailscaled; then
  echo "tailscaled is not running; run phase1-bootstrap.sh first." >&2
  exit 1
fi

CONN="${1:-${SSH_CONNECTION:-}}"
if [[ -z "${CONN}" ]]; then
  echo "Refusing to run: can't tell how you're connected." >&2
  echo "Run it via './deploy.sh harden', or pass \"\$SSH_CONNECTION\" as the first argument." >&2
  exit 1
fi

SRC_IP="${CONN%% *}"
case "${SRC_IP}" in
  100.*|fd7a:115c:a1e0:*)
    ;; # came in over the Tailscale CGNAT range, proceed
  *)
    echo "Refusing to run: this SSH session (${SRC_IP}) did not come in" >&2
    echo "over the Tailscale range (100.64.0.0/10 / fd7a:115c:a1e0::/48)." >&2
    echo "Reconnect via 'ssh ubuntu@<tailscale-hostname>' and retry." >&2
    exit 1
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ufw fail2ban unattended-upgrades apt-listchanges

# --- UFW ------------------------------------------------------------------
if ! grep -q '^IPV6=yes' /etc/default/ufw; then
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 41641/udp comment 'Tailscale direct connections'
ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment 'SSH via Tailscale (v4)'
ufw allow from fd7a:115c:a1e0::/48 to any port 22 proto tcp comment 'SSH via Tailscale (v6)'
ufw --force enable

# --- sshd hardening ---------------------------------------------------------
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t
systemctl reload ssh

# --- fail2ban ----------------------------------------------------------------
cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = 22
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# --- unattended-upgrades ------------------------------------------------------
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat >/etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
systemctl enable --now unattended-upgrades

cat <<'EOF'

=============================================================
Phase 2 complete.
  - UFW: deny incoming by default; 80/443 open to the world;
    22/tcp open only from Tailscale ranges.
  - sshd: password auth and root login disabled.
  - fail2ban: active on sshd.
  - unattended-upgrades: security patches apply automatically,
    with an automatic reboot at 03:00 if one is required.

Verify now, from the Tailscale session you're already in:
  sudo ufw status verbose
  sudo systemctl status fail2ban --no-pager
=============================================================
EOF
