# CLAUDE.md

Hosts a few small personal sites (`character`, `summon`, `carcosa` on
`totalpartykill.ca`, plus Drambuie on `drambuie.vqvz.com`) with Docker Compose + Caddy on a single OVH VPS. See
`README.md` for the full setup and deploy flow.

The repo name is historical: it used to target Oracle Cloud via Terraform.
That's gone. Don't reintroduce Terraform, Ansible, CI/CD or other
config-management frameworks. Plain, idempotent shell scripts plus
`deploy.sh` are the intended level of machinery for a box this size.

## The host

- OVH VPS `vps-72689be5.vps.ovh.ca`, **Ubuntu 26.04 (`resolute`), amd64**.
- Tailscale hostname `oci-vqvz`. Public IP is in `deploy.sh`.
- DNS is hosted elsewhere and managed by hand on purpose. Only
  `oci.vqvz.com` has A/AAAA records; the three sites are CNAMEs of it.

## Access and deploying

- SSH is reachable **only over Tailscale** (UFW allows 22 from
  `100.64.0.0/10` / `fd7a:115c:a1e0::/48`). 80/443 are public.
- This Claude sandbox is not on the tailnet and has no SSH key, so it cannot
  reach the box. The user runs `./deploy.sh <bootstrap|harden|monitor|init|deploy|ssh>`
  from their Mac. Make the change, commit when asked, and hand off the command.
- `phase2-harden.sh` refuses to run unless the session came in over
  Tailscale. Never weaken or bypass that guard: it's what prevents locking
  the user out of the box.

## Gotchas learned the hard way

- **Don't use `sudo -E`.** Ubuntu 26.04 ships `sudo-rs`, which drops the
  caller's environment. Pass values to scripts as arguments instead (see how
  `deploy.sh` calls both bootstrap phases).
- **sshd keeps the first value it reads**, loading `sshd_config.d/*.conf`
  alphabetically. Hardening lives in `01-hardening.conf` so it beats
  cloud-init's `50-cloud-init.conf`.
- **App images must be built for amd64.** They come from separate repos
  (`funkaoshi/*`) and should be multi-arch:
  `docker buildx build --platform linux/amd64,linux/arm64 ... --push`.
  Check with `docker buildx imagetools inspect <image>:latest`. This sandbox
  is aarch64, so a local test will *not* catch an arm64-only image.
- **Container ports must match the Caddyfile**: randomcharacter 8000,
  lotfp-summon 8001, randomcarcosa 8002. The fix belongs in the app repo if
  an image changes its port.
- **Drambuie is a separate compose project** (`tiff` repo, `~/drambuie`
  on the box, `drambuie.vqvz.com`). This stack's `caddy` depends on its
  external `drambuie-edge` network and `drambuie_media` volume; if
  either is missing, `caddy` fails to start and takes every site down. See
  README "Drambuie" and `DRAMBUIE-DEPLOY.md`.
- Carcosa's `/static/*` needs the `Access-Control-Allow-Origin:
  https://save.vs.totalpartykill.ca` header, which another site depends on.

## Conventions

- Compose v2 only (`docker compose`, never `docker-compose`).
  `compose.service` is `Type=oneshot` + `RemainAfterExit`. Containers
  restart themselves via `restart: unless-stopped`.
- Keep `Caddyfile` and `Caddyfile.dev` in sync. Validate with
  `docker run --rm -v "$PWD/docker:/c:ro" caddy:latest caddy validate --config /c/Caddyfile --adapter caddyfile`.
- To test the dev stack from this sandbox, bypass its proxy:
  `curl --noproxy '*' --resolve carcosa.local:443:127.0.0.1 -sk https://carcosa.local/`
  (quote the `*`).
- Python tooling (black, ruff, pre-commit) is managed with **uv**, not poetry.
- Secrets stay out of git: `bootstrapping/.env` (Tailscale auth key, ntfy topic, Healthchecks URL).
  `docker/data/` is leftover linkding data, including a secret key. It's
  gitignored; never stage it.
- Run `bash -n` on any shell script you change.
- vps-check (installed by `phase3-monitor.sh`) detects logins from the
  journal, deliberately not via PAM, so a bug in it can't block SSH.
- Commit messages: one short sentence ending in a period, optional body.
