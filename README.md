# oracle_free_vm

Infrastructure for hosting a handful of small Flask / Django apps on Oracle Cloud Infrastructure (OCI) "always free" VMs.

- **`terraform/`** builds the infrastructure: a VCN, a subnet, and two ARM VMs on the always free tier. Mostly Oracle's own example, trimmed down.
- **`docker/`** is what gets run *on* the VM. Docker Compose runs the apps, and Caddy sits in front of them terminating TLS and serving static files.

`bootstrapping/init.sh` is the glue that gets a fresh VM ready to run the compose file.

## Layout

```
terraform/
  ociprovider.tf   oracle/oci provider requirement
  variables.tf     tenancy/user/key/region inputs
  compartment.tf   the "alwaysfree" compartment
  main.tf          network, security list, the two instances, IP outputs
bootstrapping/
  init.sh          apt packages + docker group, run once on a new VM
docker/
  docker-compose.yml       production stack
  docker-compose-dev.yml   same stack for local development
  Caddyfile                production routing (real hostnames, real certs)
  Caddyfile.dev            local routing (*.local hostnames)
  compose.service          systemd unit so the stack comes up on boot
  Makefile                 caddy reload helpers
```

## What actually runs

| Hostname (prod)             | Container                     | Port | Static files |
| --------------------------- | ----------------------------- | ---- | ------------ |
| `character.totalpartykill.ca` | `funkaoshi/randomcharacter`   | 8000 | `/static/*` from `character-volume` |
| `summon.totalpartykill.ca`    | `funkaoshi/lotfp-summon`      | 8001 | `/static/*` from `summon-volume` |
| `carcosa.totalpartykill.ca`   | `funkaoshi/randomcarcosa`     | 8002 | `/1807*`, `/704-yards*`, `/sorceress-rituals*` from `carcosa-volume` |
| `oci.vqvz.com`                | `sissbruecker/linkding`       | 9090 | n/a (5MB max request body) |

Each app image ships its own static assets and mounts a named volume at `/app/static`; Caddy mounts the same volume at `/srv/<app>` and serves those paths itself, so requests for static content never reach the app process.

Locally the same services answer on `character.local`, `summon.local`, `carcosa.local` and `linkding.local`.

## 1. Provision the infrastructure

You need Terraform and an OCI API signing key (the OCI console generates one and shows you the fingerprint).

`terraform/variables.tf` declares these with no defaults, so supply them all:

- `tenancy_ocid`
- `compartment_ocid`
- `user_ocid`
- `fingerprint`
- `private_key_path` — the OCI API private key
- `ssh_public_key_path` — public key installed on the VMs for the `ubuntu` user
- `region` — defaults to `ca-toronto-1`

The convention here is an `env-vars.sh` that exports them as `TF_VAR_*` (it is gitignored, along with `.terraform*` and `*.tfstate*`):

```sh
export TF_VAR_tenancy_ocid="ocid1.tenancy.oc1..."
export TF_VAR_compartment_ocid="ocid1.compartment.oc1..."
export TF_VAR_user_ocid="ocid1.user.oc1..."
export TF_VAR_fingerprint="aa:bb:cc:..."
export TF_VAR_private_key_path="$HOME/.oci/oci_api_key.pem"
export TF_VAR_ssh_public_key_path="$HOME/.ssh/id_rsa.pub"
```

Then:

```sh
cd terraform
source ../env-vars.sh
terraform init
terraform plan
terraform apply
```

`compartment.tf` creates the `alwaysfree` compartment. That is a chicken and
egg situation with `compartment_ocid`: create the compartment first (or apply
it on its own), then set `TF_VAR_compartment_ocid` to it before applying the
rest.

Apply prints the two public IPs:

```
worker_node_ip  = <ip of "Always Free Instance">
strigil_node_ip = <ip of "Strigil">
```

Notes on what gets built:

- Both instances are `VM.Standard.A1.Flex` with 2 OCPUs and 12GB — together that is exactly the always free Ampere allotment (4 OCPUs / 24GB).
- Ingress is open to the world on 22, 80 and 443 only. Egress is TCP to anywhere.
- The Ubuntu 22.04 image is pinned by OCID, and image OCIDs are **region specific** — changing `region` means looking up a new `source_id` in `main.tf`.

## 2. Bootstrap a VM

```sh
scp bootstrapping/init.sh ubuntu@<ip>:
ssh ubuntu@<ip>
sh init.sh
```

It installs `docker.io`, `docker-compose`, `curl` and `git`, and adds `ubuntu` to the `docker` group. Log out and back in for the group to take effect.

Then clone this repo to the path the systemd unit expects:

```sh
git clone <this repo> ~/oracle_free_vm
```

## 3. DNS

Point an A record for each hostname in `docker/Caddyfile` at the instance's public IP. Do this *before* starting the stack: Caddy provisions Let's Encrypt certificates on first request, which needs the names resolving to the box on port 80/443.

## 4. Run the stack

```sh
cd ~/oracle_free_vm/docker
docker-compose pull
docker-compose up -d
```

To have it start on boot, install the unit:

```sh
sudo cp compose.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now compose
```
The unit runs as `ubuntu` out of `/home/ubuntu/oracle_free_vm/docker/`, pulls images before every start (`--ignore-pull-failures`, so a registry hiccup doesn't keep the site down), and restarts always. Deploying a new version of an app is therefore `sudo systemctl restart compose`.

Caddy keeps its certificates and state in the `caddy-data` / `caddy-config` volumes, so they survive a recreate.

After editing the `Caddyfile`:

```sh
make reload-caddy
```

## 5. Local development

`docker-compose-dev.yml` runs the same images behind `Caddyfile.dev`, which uses `.local` hostnames. Add them to `/etc/hosts`:

```
127.0.0.1 character.local summon.local carcosa.local linkding.local
```

Then:

```sh
cd docker
docker compose -f docker-compose-dev.yml up
make reload-caddy-dev   # after editing Caddyfile.dev
```

Caddy issues its own internal certificate for `.local` names, so expect a browser warning unless you trust Caddy's local root CA.

Differences from production: no `caddy-data` / `caddy-config` volumes, and `.env-linkding` is optional rather than required.

## Secrets and state kept out of git

`.gitignore` covers these; they have to exist on the machine that needs them.

- `env-vars.sh` — the `TF_VAR_*` exports above.
- `**/*.tfstate*`, `**/.terraform*` — Terraform state is local.
- `docker/.env-linkding` — linkding's environment (`LD_*` settings, superuser credentials). Required by `docker-compose.yml`, optional in the dev file.
- `docker/data/` — linkding's SQLite databases, favicons, previews and assets. Override the location with `LD_HOST_DATA_DIR`; it defaults to `./data`.

## Adding another app

1. Publish an image that serves on a port of its own and copies its static assets into `/app/static`.
2. Add the service to both compose files, with a named volume mounted at `/app/static`, and declare that volume at the top.
3. Mount the same volume into the `caddy` service at `/srv/<app>` and add the service to caddy's `depends_on`.
4. Add a site block to `Caddyfile` and `Caddyfile.dev` — `handle /static/*` stripping the prefix and serving from `/srv/<app>`, then a catch-all
   `handle` reverse proxying to the container.
5. Point DNS at the VM, then `make reload-caddy`.

## Rough edges

- `poetry.lock` / `pyproject.toml` pull in Ansible, but there are no playbooks yet; configuration management is still `init.sh` plus ssh.
- `compose.service` and `init.sh` use docker-compose v1 (`docker-compose`), while the `Makefile` uses the v2 plugin syntax (`docker compose`). On the VM the Makefile targets only work if the compose plugin is installed too; otherwise `docker-compose kill -s USR1 caddy`.
- Caddy 2 doesn't document `SIGUSR1` as a reload signal, so if `make reload-caddy` doesn't pick up a `Caddyfile` change, fall back to `docker compose restart caddy` (or `caddy reload` inside the container).
- Instance IPs are ephemeral-by-default public IPs and DNS records are managed by hand. Still an open question in the original README: what the tidy way to do DNS for a setup like this is.
