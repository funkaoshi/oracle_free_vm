# oracle_free_vm

Infrastructure for hosting a handful of small Flask / Django apps on a
single Ubuntu VPS.

- **`docker/`** is what gets run *on* the VM. Docker Compose runs the apps,
  and Caddy sits in front of them terminating TLS and serving static files.
- **`bootstrapping/`** gets a fresh VPS ready to run the compose file, and
  locks it down so admin access only works over Tailscale.
- **`deploy.sh`** is the one entry point for everything below, run from your
  laptop.

## Layout

```
bootstrapping/
  phase1-bootstrap.sh   installs Tailscale + Docker, run once over the public IP
  phase2-harden.sh      firewall + sshd hardening + fail2ban + auto-updates, run once over Tailscale
  phase3-monitor.sh     vps-check health and security alerts, run once over Tailscale
  .env.example          template for the Tailscale auth key and monitoring settings
docker/
  docker-compose.yml       production stack
  docker-compose-dev.yml   same stack for local development
  Caddyfile                production routing (real hostnames, real certs)
  Caddyfile.dev            local routing (*.local hostnames)
  compose.service          systemd unit so the stack comes up on boot
  Makefile                 up/down + caddy reload helpers
deploy.sh                  bootstrap / harden / monitor / init / deploy / ssh, from your laptop
```

## What actually runs

| Hostname (prod)             | Container                     | Port | Static files |
| --------------------------- | ----------------------------- | ---- | ------------ |
| `character.totalpartykill.ca` | `funkaoshi/randomcharacter`   | 8000 | `/static/*` from `character-volume` |
| `summon.totalpartykill.ca`    | `funkaoshi/lotfp-summon`      | 8001 | `/static/*` from `summon-volume` |
| `carcosa.totalpartykill.ca`   | `funkaoshi/randomcarcosa`     | 8002 | `/1807*`, `/704-yards*`, `/sorceress-rituals*` from `carcosa-volume` |

Each app image ships its own static assets and mounts a named volume at
`/app/static`; Caddy mounts the same volume at `/srv/<app>` and serves those
paths itself, so requests for static content never reach the app process.

`character.totalpartykill.ca`, `summon.totalpartykill.ca`, and
`carcosa.totalpartykill.ca` are DNS aliases (CNAMEs) of `oci.vqvz.com` — only
`oci.vqvz.com`'s A/AAAA records need to point at the box. Nothing is served
at `oci.vqvz.com` itself.

Locally the same services answer on `character.local`, `summon.local` and
`carcosa.local`.

## Access model

This runs on a single Ubuntu VPS bought directly from a hosting provider's
control panel (not something Terraform provisions — there's no cloud API
behind it to automate). Hardening it the same way every time is what
`bootstrapping/` and `deploy.sh` are for.

- **80 and 443 are open to the whole internet.** That's the point — these
  are public websites, and Caddy needs inbound 80/443 to issue and renew
  Let's Encrypt certificates.
- **22 is reachable only from the Tailscale network.** Admin access (SSH)
  never uses the box's public IP after initial setup. UFW allows port 22
  only from Tailscale's CGNAT ranges (`100.64.0.0/10` / `fd7a:115c:a1e0::/48`),
  sshd has password auth and root login disabled, and Tailscale's own SSH
  (`tailscale ssh`) is enabled as a second, independent access path.

Setting this up is a deliberate two-phase process, because the box is
reachable over its public IP *before* Tailscale exists on it, and once a
firewall blocks public port 22 there's no way back in except Tailscale. Each
phase is idempotent (safe to re-run), and phase 2 refuses to run at all
unless it's invoked over a Tailscale connection, so there's no way to
accidentally cut off the public fallback before Tailscale is proven to work.

## 1. Provision a VPS

Buy the VPS through the provider's control panel and note its public IP —
there's nothing to script here, it's a one-time manual step. The rest of
this README assumes a recent Ubuntu LTS and a default `ubuntu` user with
your SSH key already installed (the provider does this for you).
`phase1-bootstrap.sh` falls back to an older Docker-supported codename on
its own if the box is running a release new enough that
`download.docker.com` hasn't published packages for it yet.

## 2. Bootstrap and harden

Generate a Tailscale auth key at
[the Tailscale admin console](https://login.tailscale.com/admin/settings/keys),
then:

```sh
cp bootstrapping/.env.example bootstrapping/.env
# edit bootstrapping/.env with your real TAILSCALE_AUTHKEY
```

`deploy.sh` already points `PUBLIC_HOST`/`TS_HOST` at this box's public IP
and chosen Tailscale hostname (`oci-vqvz`) — update those two variables at
the top of the file if you ever rebuild on a different VPS or rename the
node, then:

```sh
./deploy.sh bootstrap
```

This installs Tailscale and Docker over the public IP. It does **not**
touch the firewall or sshd. Once it finishes, **in a new terminal**, verify
Tailscale access works before doing anything else:

```sh
ssh ubuntu@<tailscale-hostname>
```

Only once that succeeds:

```sh
./deploy.sh harden
```

This installs UFW, fail2ban, and unattended-upgrades, closes public SSH
access, and hardens sshd. From here on, `ssh ubuntu@<public-ip>` no longer
works — use `./deploy.sh ssh` or `ssh ubuntu@<tailscale-hostname>`.

Unattended-upgrades is configured to reboot automatically at 03:00 when a
patch needs it — every container already has `restart: unless-stopped` and
the compose stack comes back up via its systemd unit, so a reboot
self-heals. If you'd rather not have surprise reboots, change
`Unattended-Upgrade::Automatic-Reboot` to `"false"` in
`/etc/apt/apt.conf.d/51unattended-upgrades-local` on the box.

## 3. DNS

Point `oci.vqvz.com`'s A (and AAAA, if you want IPv6) record at the VPS's
public IP(s). Do this *before* bringing up the stack — Caddy requests Let's
Encrypt certificates on first request, which needs the name resolving to
the box on port 80/443. This stays a manual step: DNS for this domain isn't
managed by the same provider as the VPS, so there's no API to script it
against.

## 4. Run the stack

From your laptop:

```sh
./deploy.sh init
```

This syncs `docker/` to the box and installs/enables the `compose` systemd
unit, which pulls images and brings the stack up (and back up on reboot).

Caddy keeps its certificates and state in the `caddy-data` / `caddy-config`
volumes, so they survive a recreate.

## 5. Deploying changes

Whenever an app image, the `Caddyfile`, or anything else under `docker/`
changes:

```sh
./deploy.sh deploy
```

This re-syncs `docker/` and restarts the `compose` unit, which pulls fresh
images and brings the stack back up.

If you only changed the `Caddyfile` and don't want to restart every
container, `make reload-caddy` (over `./deploy.sh ssh`, from `~/oracle_free_vm/docker`)
sends Caddy a reload signal instead.

## 6. Monitoring

- **vps-check** runs on the box every 5 minutes from a systemd timer and
  pushes to [ntfy](https://ntfy.sh) when it sees SSH logins, fail2ban bans,
  failed systemd units, stopped or restarting containers, a site in the
  `Caddyfile` not answering over HTTPS, unattended-upgrades errors, a reboot pending for over a day, the root disk over 90% full, or
  less than 10% of memory available. Persistent problems alert once, and
  again when they clear. Fill in `NTFY_TOPIC` and `HC_PING_URL` in
  `bootstrapping/.env`, then:

  ```sh
  ./deploy.sh monitor
  ```

  Expect an "SSH login" push after every `./deploy.sh` run;
  that's the point.
- **[Healthchecks.io](https://healthchecks.io)** catches what a script on
  the box can't: a check (period 5m, grace 10m) receives vps-check's
  heartbeat and alerts if the box, its network or the timer dies.

## 7. Local development

`docker-compose-dev.yml` runs the same images behind `Caddyfile.dev`, which
uses `.local` hostnames. Add them to `/etc/hosts`:

```
127.0.0.1 character.local summon.local carcosa.local
```

Then:

```sh
cd docker
docker compose -f docker-compose-dev.yml up
make reload-caddy-dev   # after editing Caddyfile.dev
```

Caddy issues its own internal certificate for `.local` names, so expect a
browser warning unless you trust Caddy's local root CA.

Differences from production: no `caddy-data` / `caddy-config` volumes.

## Secrets kept out of git

The only secrets are in `bootstrapping/.env` (the Tailscale auth key, the
ntfy topic and the Healthchecks.io URL), which `.gitignore` covers. On the
box, vps-check reads its copy from `/etc/vps-monitor.env` (root, 0600).

## Adding another app

1. Publish an image that serves on a port of its own and copies its static
   assets into `/app/static`.
2. Add the service to both compose files, with a named volume mounted at
   `/app/static`, and declare that volume at the top.
3. Mount the same volume into the `caddy` service at `/srv/<app>` and add
   the service to caddy's `depends_on`.
4. Add a site block to `Caddyfile` and `Caddyfile.dev` — `handle /static/*`
   stripping the prefix and serving from `/srv/<app>`, then a catch-all
   `handle` reverse proxying to the container.
5. Point DNS at the box, then `./deploy.sh deploy`.

## Rough edges

- DNS is managed by hand, deliberately — not worth automating for one
  record sitting with a DNS provider separate from the VPS host.
- Both OpenSSH-over-Tailscale and Tailscale's own built-in SSH (`tailscale
  ssh`) are left enabled as redundant access paths, in case one of them
  ever misbehaves.
