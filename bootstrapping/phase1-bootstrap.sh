#!/usr/bin/env bash
# Phase 1: run once over the PUBLIC IP (the only time it's used for admin
# access). Installs Tailscale and Docker. Does NOT touch the firewall or
# sshd -- the current public SSH path must keep working until Tailscale
# access is verified. Safe to re-run.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-oci-vqvz}"
DOCKER_FALLBACK_CODENAME="noble"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y curl git ca-certificates gnupg

# --- Tailscale ----------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
  echo "Already joined to a tailnet; skipping auth-key login."
else
  : "${TAILSCALE_AUTHKEY:?Set TAILSCALE_AUTHKEY (source bootstrapping/.env) before running this script}"
  tailscale up --authkey="${TAILSCALE_AUTHKEY}" \
               --hostname="${TAILSCALE_HOSTNAME}" \
               --ssh \
               --accept-dns=true
fi

TS_IP="$(tailscale ip -4)"

# --- Docker (official repo, Ubuntu "noble" compatible) ------------------
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

# Docker's apt repo can lag a brand-new Ubuntu release by weeks. If there's
# no suite published for our codename yet, fall back to the newest LTS
# codename Docker is known to support -- the .debs have no hard dependency
# on anything specific to the newer userland.
REPO_CODENAME="${CODENAME}"
if ! curl -fsSL --head "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1; then
  echo "WARNING: download.docker.com has no '${CODENAME}' suite yet; using '${DOCKER_FALLBACK_CODENAME}' instead." >&2
  REPO_CODENAME="${DOCKER_FALLBACK_CODENAME}"
fi

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${REPO_CODENAME} stable
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu

cat <<EOF

=============================================================
Phase 1 complete.

Tailscale hostname: ${TAILSCALE_HOSTNAME}
Tailscale IPv4:      ${TS_IP}

STOP. In a NEW terminal (keep this SSH session open as a fallback),
verify Tailscale SSH access works:

    ssh ubuntu@${TAILSCALE_HOSTNAME}             # via MagicDNS, or
    ssh ubuntu@${TS_IP}                          # via Tailscale IP
    tailscale ssh ubuntu@${TAILSCALE_HOSTNAME}   # via Tailscale's own SSH

Only once that works should you run phase2-harden.sh (which closes
public SSH access).
=============================================================
EOF
