#!/usr/bin/env bash
# Usage: ./deploy.sh <bootstrap|harden|monitor|init|deploy|ssh>
#
#   bootstrap  Phase 1 over the public IP: installs Tailscale + Docker.
#              Run once per fresh VPS. Safe to re-run.
#   harden     Phase 2 over Tailscale: firewall, sshd hardening, fail2ban,
#              unattended-upgrades. Run once Tailscale SSH is verified.
#   monitor    Phase 3 over Tailscale: installs vps-check, which pushes
#              health and security alerts to ntfy. Safe to re-run.
#   init       First-time sync of docker/ and install of the systemd unit.
#   deploy     Sync docker/ and restart the stack. Use for every later change.
#   ssh        Open an interactive shell on the box over Tailscale.
set -euo pipefail
cd "$(dirname "$0")"

PUBLIC_HOST="ubuntu@15.235.63.75"
TS_HOST="ubuntu@oci-vqvz"
REMOTE_DIR="oracle_free_vm"
# Prefixed to each remote command so vps-check can say which logins were us.
TAG="logger -t deploy.sh ${1:-}"

case "${1:-}" in
  bootstrap)
    scp bootstrapping/phase1-bootstrap.sh "${PUBLIC_HOST}:~"
    scp bootstrapping/.env "${PUBLIC_HOST}:~/bootstrap.env"
    ssh "${PUBLIC_HOST}" "${TAG}; "'sudo bash ~/phase1-bootstrap.sh ~/bootstrap.env; rc=$?; rm -f ~/bootstrap.env; exit $rc'
    ;;
  harden)
    scp bootstrapping/phase2-harden.sh "${TS_HOST}:~"
    ssh "${TS_HOST}" "${TAG}; "'sudo bash ~/phase2-harden.sh "$SSH_CONNECTION"'
    ;;
  monitor)
    scp bootstrapping/phase3-monitor.sh "${TS_HOST}:~"
    scp bootstrapping/.env "${TS_HOST}:~/monitor.env"
    ssh "${TS_HOST}" "${TAG}; "'sudo bash ~/phase3-monitor.sh ~/monitor.env; rc=$?; rm -f ~/monitor.env; exit $rc'
    ;;
  init)
    ssh "${TS_HOST}" "${TAG}; mkdir -p ${REMOTE_DIR}"
    rsync -az docker/ "${TS_HOST}:${REMOTE_DIR}/docker/"
    ssh "${TS_HOST}" "${TAG}; sudo cp ${REMOTE_DIR}/docker/compose.service /etc/systemd/system/compose.service && \
                       sudo systemctl daemon-reload && \
                       sudo systemctl enable --now compose"
    ;;
  deploy)
    rsync -az --delete docker/ "${TS_HOST}:${REMOTE_DIR}/docker/"
    ssh "${TS_HOST}" "${TAG}; sudo cp ${REMOTE_DIR}/docker/compose.service /etc/systemd/system/compose.service && \
                       sudo systemctl daemon-reload && \
                       sudo systemctl restart compose"
    ;;
  ssh)
    ssh -t "${TS_HOST}" "${TAG}; exec \"\${SHELL}\" -l"
    ;;
  *)
    echo "Usage: $0 <bootstrap|harden|monitor|init|deploy|ssh>" >&2
    exit 1
    ;;
esac
