# homelab-deploy

Portable Bash orchestrator that automates VM provisioning on a Proxmox + OPNsense homelab:

1. Clone a cloud-init VM template on Proxmox
2. Create a static DHCP lease in OPNsense (Kea)
3. Boot the VM and wait for SSH + cloud-init completion
4. Optionally publish the app behind a Zoraxy reverse proxy

---

## Requirements

| Tool | Purpose |
| ---- | ------- |
| `bash` ≥ 4.0 | Script runtime |
| `curl` | Proxmox, OPNsense, and Zoraxy API calls |
| `jq` | JSON parsing |
| `ssh` / `ssh-keyscan` | VM connectivity checks |

**Install `jq`:**
```bash
# macOS
brew install jq

# Debian / Ubuntu
apt install jq

# Alpine
apk add jq

# RHEL / Fedora
dnf install jq
```

---

## Quick Start

```bash
cp .env.example .env
# edit .env with your infra values

./deploy.sh gitea 10.0.0.50 git.example.com
```

Interactive wizard (prompts for everything):
```bash
./deploy.sh --wizard
# or simply: ./deploy.sh  (no arguments, interactive terminal)
```

---

## SSH Deploy Key

The script injects a public key into the cloned VM via cloud-init. Generate a dedicated key pair:

```bash
ssh-keygen -t ed25519 -C "deploy-automation" -f ~/.ssh/deploy_automation -N ""
```

Set `SSH_KEY_FILE=~/.ssh/deploy_automation` in your `.env`. The script reads both `${SSH_KEY_FILE}` (private) and `${SSH_KEY_FILE}.pub` (public).

---

## Proxmox Setup

### API Token

Create a dedicated token in **Datacenter → Permissions → API Tokens**.

Minimum permissions required on the node and storage:

| Path | Role |
| ---- | ---- |
| `/` | `PVEAuditor` (read cluster resources) |
| `/nodes/<node>` | `PVEVMAdmin` (clone, configure, start) |
| `/storage/<storage>` | `PVEDatastoreUser` (create disk) |

Set in `.env`:
```env
PROXMOX_TOKEN_ID="root@pam!deploy"
PROXMOX_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Cloud-init Template

The script clones from a template VM. That template must:
- Have a cloud-init drive attached
- Be configured with `user: <your SSH user>` in cloud-init
- Have `PROXMOX_TEMPLATE_ID` set to its VMID

### Self-signed Certificate

Proxmox uses a self-signed certificate by default. The script uses `curl -k` to skip TLS verification for Proxmox API calls only — this is intentional and expected in a homelab environment.

---

## OPNsense Setup

### API Key

Go to **System → Access → Users**, edit your user, and generate an API key under **API keys**.

The user needs access to the Kea DHCP plugin:

- `kea` module: read + write

Set in `.env`:
```env
OPNSENSE_HOST="10.0.0.1"
OPNSENSE_API_KEY="your-key"
OPNSENSE_API_SECRET="your-secret"
```

---

## Configuration

Copy the template and fill in your values:
```bash
cp .env.example .env
chmod 600 .env
```

`.env` is git-ignored — never commit it.

### Required Variables

```env
# Proxmox
PROXMOX_HOST="pve.example.com:8006"
PROXMOX_NODE="pve"
PROXMOX_TEMPLATE_ID="280"
PROXMOX_STORAGE="local-lvm"
PROXMOX_TOKEN_ID="root@pam!deploy"
PROXMOX_TOKEN_SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# OPNsense
OPNSENSE_HOST="10.0.0.1"
OPNSENSE_API_KEY="your-key"
OPNSENSE_API_SECRET="your-secret"

# SSH
SSH_KEY_FILE="~/.ssh/deploy_automation"
SSH_USER="root"
```

### VMID Allocation

| Policy | Behaviour |
| ------ | --------- |
| `nextid` | Ask Proxmox cluster for the next free ID (default) |
| `range_first` | First free ID in `[RANGE_START, RANGE_END]` |
| `range_random` | Random free ID in that range |
| `manual` | Fixed ID from `PROXMOX_VMID` |

```env
PROXMOX_VMID_POLICY="range_first"
PROXMOX_VMID_RANGE_START="200"
PROXMOX_VMID_RANGE_END="299"
```

### Execution Modes

| `DEPLOY_FLOW` | What runs |
| ------------- | --------- |
| `full` | Provision + optional proxy (default) |
| `provision` | Provision only |
| `proxy` | Proxy only (for an existing app) |

### Timeouts

```env
SSH_WAIT_TIMEOUT="300"    # seconds to wait for SSH after VM boot (default: 300)
CLOUD_INIT_TIMEOUT="120"  # seconds to wait for cloud-init marker (default: 120)
```

---

## Proxy Integration (Zoraxy)

```env
PROXY_PROVIDER="zoraxy_api"
ZORAXY_API_BASE="http://zoraxy.example.com:8400"
ZORAXY_USERNAME="admin"       # optional, if auth is enabled
ZORAXY_PASSWORD="yourpassword"

ENABLE_PROXY="auto"           # auto | 1 | 0
```

Upstream port detection:
```env
PROXY_UPSTREAM_PORT="8080"        # set explicitly, or leave unset for auto-detection
PROXY_AUTO_DETECT_PORT="true"
PROXY_PORT_CANDIDATES="80,8080,3000,3001,5000,5173,8000,8081"
PROXY_AUTO_PORT_STRATEGY="first"  # first | strict
```

Use `strict` to fail when multiple ports respond (avoids guessing in ambiguous setups).

---

## Common Scenarios

**Provision a VM, add proxy later:**
```bash
# .env: DEPLOY_FLOW=provision
./deploy.sh gitea 10.0.0.50 git.example.com

# after manually deploying the app on the VM:
# .env: DEPLOY_FLOW=proxy  PROXY_PROVIDER=zoraxy_api
./deploy.sh gitea 10.0.0.50 git.example.com
```

**Full deploy in one shot:**
```bash
# .env: DEPLOY_FLOW=full  PROXY_PROVIDER=zoraxy_api
./deploy.sh gitea 10.0.0.50 git.example.com
```

---

## Deployment State

Each run saves state to `.deploy-state/<app-name>.env` (git-ignored). It records the VMID, MAC address, DHCP reservation UUID, and proxy status. This file is for reference and debugging — it is not required for the script to run.

---

## Rollback

In `full` and `provision` modes, if any phase fails after the VM is cloned, the script automatically:

1. Force-stops the cloned VM
2. Deletes the cloned VM from Proxmox
3. Deletes the DHCP reservation from OPNsense Kea

This keeps your infrastructure clean on failure without manual cleanup.

---

## Project Layout

```text
deploy.sh               # main orchestrator + wizard
lib/
  common.sh             # curl helpers, urlencode, jq wrappers, SSH
  state.sh              # per-deployment state file management
modules/
  proxmox.sh            # VM clone, MAC extraction, cloud-init, boot, SSH wait
  dhcp.sh               # OPNsense Kea DHCP reservation
integrations/
  proxy.sh              # Zoraxy reverse proxy API integration
.env.example            # configuration template
```

---

## License

[MIT](LICENSE)
