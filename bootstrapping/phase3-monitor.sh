#!/usr/bin/env bash
# Phase 3: run over Tailscale after phase 2. Installs vps-check: a systemd
# timer that pushes health and security alerts to ntfy and pings
# Healthchecks.io as a heartbeat. Safe to re-run.
#
# Usage: sudo bash phase3-monitor.sh <env-file>
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo $0 <env-file>)" >&2
  exit 1
fi

# Read the env file here rather than relying on sudo to pass variables
# through: sudo-rs drops them.
if [[ -n "${1:-}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$1"
  set +a
fi

: "${NTFY_TOPIC:?No NTFY_TOPIC; pass the env file as the first argument}"
HC_PING_URL="${HC_PING_URL:-}"
ALERT_TZ="${ALERT_TZ:-}"

# --- Secrets for vps-check -------------------------------------------------
install -m 0600 -o root -g root /dev/null /etc/vps-monitor.env
printf 'NTFY_TOPIC=%q\nHC_PING_URL=%q\nALERT_TZ=%q\n' \
  "${NTFY_TOPIC}" "${HC_PING_URL}" "${ALERT_TZ}" >/etc/vps-monitor.env

# --- vps-check -------------------------------------------------------------
cat >/usr/local/sbin/vps-check <<'EOF'
#!/usr/bin/env bash
# Installed by phase3-monitor.sh; run every 5 minutes by vps-check.timer.
# Persistent problems alert once when they start and once when they clear.
# Events (logins, bans, restarts) alert once per run that sees new ones.
set -uo pipefail

# shellcheck disable=SC1091
source /etc/vps-monitor.env
# Times in alerts are in ALERT_TZ if set, otherwise the box's own zone.
[[ -n "${ALERT_TZ:-}" ]] && export TZ="${ALERT_TZ}"

STATE=/var/lib/vps-check
HOST="$(hostname)"
mkdir -p "${STATE}"

NOW="$(date +%s)"
SINCE="$(cat "${STATE}/last-run" 2>/dev/null || echo $((NOW - 300)))"

notify() { # <priority> <title> <body>
  curl -fsS -m 10 -H "Title: ${HOST}: $2" -H "Priority: $1" -d "$3" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null || true
}

# A problem that persists across runs. An empty message means it's fine.
condition() { # <name> <priority> <message>
  local flag="${STATE}/$1.active"
  if [[ -n "$3" ]]; then
    if [[ "$(cat "${flag}" 2>/dev/null)" != "$3" ]]; then
      notify "$2" "$1" "$3"
      printf '%s' "$3" >"${flag}"
    fi
  elif [[ -f "${flag}" ]]; then
    notify default "$1 resolved" "Back to normal."
    rm -f "${flag}"
  fi
}

journal() { # "<epoch> <message>" for entries in the window since the last run
  journalctl -q -o short-unix --no-pager --since "@${SINCE}" --until "@${NOW}" "$@" |
    sed -E 's/^([0-9]+)\.[0-9]+ [^ ]+ [^ ]+: /\1 /'
}

# --- Persistent conditions -------------------------------------------------
failed="$(systemctl --failed --no-legend --plain | awk '{print $1}' | paste -sd' ')"
condition "Failed units" high "${failed:+Failed: ${failed}}"

# One-shot jobs (restart: "no", e.g. Drambuie's migrate) that exited 0 are done, not down.
# shellcheck disable=SC2046  # container IDs are meant to split
stopped="$(docker inspect --format '{{.Name}} {{.State.Status}} {{.State.ExitCode}} {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq) 2>/dev/null |
  awk '$2 != "running" && !($2 == "exited" && $3 == 0 && $4 == "no") {sub("^/", "", $1); printf "%s (%s) ", $1, $2}')"
stopped="${stopped% }"
condition "Containers down" high "${stopped:+Not running: ${stopped}}"

disk="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
condition "Disk" high "$( ((disk >= 90)) && echo "Root filesystem is over 90% full.")"

mem="$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{print int(a*100/t)}' /proc/meminfo)"
condition "Memory" high "$( ((mem < 10)) && echo "Less than 10% of memory is available.")"

# unattended-upgrades reboots at 03:00 on its own; only complain if it didn't.
stale_reboot="$(find /var/run/reboot-required -mmin +1440 2>/dev/null)"
condition "Reboot" default "${stale_reboot:+A reboot has been pending for over a day.}"

# Fetch each site in the deployed Caddyfile by its public name, so DNS, TLS,
# Caddy and the app all have to work. 4xx counts as up; 5xx and errors don't.
CADDYFILE=/home/ubuntu/oracle_free_vm/docker/Caddyfile
down=""
# shellcheck disable=SC2013  # hostnames never contain spaces
for site in $(grep -oE '^[a-z0-9.-]+\.[a-z]+ \{' "${CADDYFILE}" 2>/dev/null | cut -d' ' -f1); do
  code="$(curl -sS -o /dev/null -m 15 --retry 2 -w '%{http_code}' "https://${site}/" 2>/dev/null)"
  [[ "${code}" =~ ^[234] ]] || down+="${site} (${code:-no response}) "
done
condition "Sites down" high "${down:+${down% }}"

# --- Events since the last run ---------------------------------------------
# Logins in time order, one line per burst from the same user and machine,
# e.g. "20:57 ubuntu from mac-mini (me@example.com) ×3". deploy.sh tags each
# run in the journal, so "20:57 deploy.sh deploy" follows the logins it made.
# sshd only logs an IP, so name it from `tailscale status` where possible.
logins="$(
  {
    journal -t sshd -t sshd-session -t sshd-auth | awk '$2 == "Accepted"' |
      awk 'FILENAME != "-" {name[$1] = $2; next}
           {print $1, $5 " from " ($7 in name ? name[$7] : $7) " (OpenSSH)"}' \
        <(tailscale status 2>/dev/null) -
    journal -u tailscaled | grep -E '^[0-9]+ audit: SSH login:' |
      sed -E 's/^([0-9]+) .* user=([^ ]+).* ts_user=([^ ]+) node=([^. ]+).*/\1 \2 from \4 (\3)/'
    journal -t deploy.sh | sed -E 's/^([0-9]+) /\1 deploy.sh /'
  } | sort -s -n -k1,1 | while read -r t event; do
    echo "$(date -d "@${t}" +%H:%M) ${event}"
  done | awk 'function flush() { if (n) print first " " prev (n > 1 ? " ×" n : "") }
              { t = $1; sub(/^[^ ]+ /, "") }
              $0 != prev { flush(); first = t; prev = $0; n = 0 }
              { n++ }
              END { flush() }'
)"
[[ -n "${logins}" ]] && notify default "SSH login" "${logins}"

# Restart counts reset when compose recreates a container, so only increases count.
touch "${STATE}/restarts"
# shellcheck disable=SC2046  # container IDs are meant to split
restarts="$(docker inspect --format '{{.Name}} {{.RestartCount}}' $(docker ps -aq) 2>/dev/null | sed 's#^/##')"
restarted="$(awk 'NR==FNR{prev[$1]=$2; next} $2 > prev[$1] && ($1 in prev){print $1}' \
  "${STATE}/restarts" - <<<"${restarts}" | paste -sd' ')"
printf '%s\n' "${restarts}" >"${STATE}/restarts"
[[ -n "${restarted}" ]] && notify high "Container restarted" "Restarted: ${restarted}"

banned="$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Total banned/{gsub(/ /,"",$2); print $2}')"
prev_banned="$(cat "${STATE}/banned" 2>/dev/null || echo "${banned:-0}")"
echo "${banned:-0}" >"${STATE}/banned"
if [[ -n "${banned}" ]] && ((banned > prev_banned)); then
  notify low "fail2ban" "$((banned - prev_banned)) new ban(s) on sshd."
fi

# Read only what was appended to the log since last run; restart on rotation.
UU_LOG=/var/log/unattended-upgrades/unattended-upgrades.log
if [[ -f "${UU_LOG}" ]]; then
  size="$(stat -c %s "${UU_LOG}")"
  offset="$(cat "${STATE}/uu-offset" 2>/dev/null || echo "${size}")"
  ((size < offset)) && offset=0
  uu_errors="$(tail -c +$((offset + 1)) "${UU_LOG}" | grep -E 'ERROR|WARNING' || true)"
  echo "${size}" >"${STATE}/uu-offset"
  [[ -n "${uu_errors}" ]] && notify high "unattended-upgrades" "${uu_errors}"
fi

echo "${NOW}" >"${STATE}/last-run"

# Heartbeat: Healthchecks.io alerts if this stops arriving (box down, timer dead).
[[ -n "${HC_PING_URL:-}" ]] && curl -fsS -m 10 --retry 3 "${HC_PING_URL}" >/dev/null
exit 0
EOF
chmod 0755 /usr/local/sbin/vps-check

cat >/etc/systemd/system/vps-check.service <<'EOF'
[Unit]
Description=VPS health and security checks
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-check
EOF

cat >/etc/systemd/system/vps-check.timer <<'EOF'
[Unit]
Description=Run vps-check every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vps-check.timer
systemctl start vps-check.service

notify_test() {
  curl -fsS -m 10 -H "Title: $(hostname): monitoring installed" \
    -d "vps-check is running every 5 minutes." "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null
}
notify_test || echo "WARNING: couldn't send a test notification to ntfy." >&2

cat <<'EOF'

=============================================================
Phase 3 complete.
  - vps-check: runs every 5 minutes, alerts via ntfy, pings
    Healthchecks.io if HC_PING_URL is set.
  - You should have just received a test push on your ntfy topic.

Verify:
  systemctl list-timers vps-check.timer
  sudo journalctl -u vps-check.service -n 20 --no-pager
=============================================================
EOF
