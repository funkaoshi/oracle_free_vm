#!/usr/bin/env bash
# Usage: ./deploy.sh <bootstrap|harden|init|deploy|ssh>
#
#   bootstrap  Phase 1 over the public IP: installs Tailscale + Docker.
#              Run once per fresh VPS. Safe to re-run.
#   harden     Phase 2 over Tailscale: firewall, sshd hardening, fail2ban,
#              unattended-upgrades. Run once Tailscale SSH is verified.
#   init       First-time sync of docker/ and install of the systemd unit.
#   deploy     Sync docker/ and restart the stack. Use for every later change.
#   ssh        Open an interactive shell on the box over Tailscale.
set -euo pipefail
cd "$(dirname "$0")"

PUBLIC_HOST="ubuntu@15.235.63.75"
TS_HOST="ubuntu@oci-vqvz"
REMOTE_DIR="oracle_free_vm"

case "${1:-}" in
  bootstrap)
    scp bootstrapping/phase1-bootstrap.sh "${PUBLIC_HOST}:~"
    scp bootstrapping/.env "${PUBLIC_HOST}:~/bootstrap.env"
    ssh "${PUBLIC_HOST}" 'sudo bash ~/phase1-bootstrap.sh ~/bootstrap.env; rc=$?; rm -f ~/bootstrap.env; exit $rc'
    ;;
  harden)
    scp bootstrapping/phase2-harden.sh "${TS_HOST}:~"
    ssh "${TS_HOST}" 'sudo bash ~/phase2-harden.sh "$SSH_CONNECTION"'
    ;;
  init)
    ssh "${TS_HOST}" "mkdir -p ${REMOTE_DIR}"
    rsync -az docker/ "${TS_HOST}:${REMOTE_DIR}/docker/"
    ssh "${TS_HOST}" "sudo cp ${REMOTE_DIR}/docker/compose.service /etc/systemd/system/compose.service && \
                       sudo systemctl daemon-reload && \
                       sudo systemctl enable --now compose"
    ;;
  deploy)
    rsync -az --delete docker/ "${TS_HOST}:${REMOTE_DIR}/docker/"
    ssh "${TS_HOST}" "sudo cp ${REMOTE_DIR}/docker/compose.service /etc/systemd/system/compose.service && \
                       sudo systemctl daemon-reload && \
                       sudo systemctl restart compose"
    ;;
  ssh)
    ssh "${TS_HOST}"
    ;;
  *)
    echo "Usage: $0 <bootstrap|harden|init|deploy|ssh>" >&2
    exit 1
    ;;
esac
