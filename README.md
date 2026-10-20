# Homelab as Code

Ansible playbooks that rebuild any Linux host in my [Desk Pi Rack](https://github.com/KevinTechLabs/Desk-Pi-Rack) from a fresh OS install: SSH lockdown, fail2ban, a per-host firewall, Docker, Tailscale and the [Wazuh](https://github.com/KevinTechLabs/Homelab-SIEM-Detection-Lab) agent. Every setting comes from the hardening I first did by hand and wrote up in the rack docs. This repo turns those write-ups into code that can be re-run, reviewed and tested.

Addresses in this repo use the same fake `10.20.x.x` plan as the rack docs. Real ones live in a git-ignored `site.yml`, so no credentials, keys or real IPs are published.

## Why

Before this, each server was configured by hand from my own notes. That worked, but:

- **Drift.** Nothing checks that a server still matches its write-up after a quick fix.
- **Slow recovery.** Rebuilding a server after a disk failure would mean copy-pasting from Markdown, step by step.
- **Mistakes.** The rack docs record a ufw rule that first landed on the wrong server because two terminals looked alike. With an inventory, the host is named in the command.

Now the docs describe the design, and this repo enforces it.

## What it does

| Role | What it enforces | Comes from |
|---|---|---|
| `common` | Base packages, timezone, unattended security upgrades, kernel network hardening (no redirects, no source routing, martian logging, `kptr_restrict`) | CIS batches in the SIEM lab |
| `ssh` | Keys only, root login off, `AllowUsers`, short grace time, no agent or X11 forwarding. **Refuses to run if the admin account has no key**, so it can't lock me out | `server-hardening.md` |
| `fail2ban` | sshd jail; Servers, Trusted and Tailscale whitelisted. IoT, Lab and Guest deliberately not | `server-hardening.md` |
| `tailscale` | Installs Tailscale and joins with the host's tag (`tag:server` or `tag:vault`). Hosts already on the tailnet are never re-authenticated | `vault.md` Tailscale policy |
| `ufw` | Default deny inbound, then only the host's own rules. On the home lab server, a `DOCKER-USER` rule limits Portainer (9443) to the Trusted zone, because Docker-published ports skip ufw | `server-hardening.md` |
| `docker` | Docker Engine from Docker's repo (or `docker.io` on Kali), capped container logs, `no-new-privileges`, and Portainer without the edge-agent port | `server-hardening.md` |
| `wazuh_agent` | Agent **pinned and held** at the manager's version (4.14.8) and pointed at the manager. On the vault Pi, **active response is off**, so the SIEM can never run commands on the password vault | SIEM lab `lab.md`, `vault-agent.md` |

### Hosts

| Host | Zone | Roles beyond the baseline | What's special |
|---|---|---|---|
| `homelab` | Servers | docker, wazuh_agent | Sentinel, Wazuh manager and pfSense syslog ports; Portainer limited to Trusted |
| `aiserver` | Servers | docker, wazuh_agent | Ollama and web UIs open to Servers and Trusted only |
| `pihole` | Servers | wazuh_agent | DNS open to all zones, admin UI to Trusted only |
| `kali` | Lab | docker, wazuh_agent | No inbound except Tailscale; Docker from the distro package |
| `vault` | Vault | docker, wazuh_agent | Inbound on `tailscale0` only, send-only Wazuh agent, Vaultwarden must stay on loopback |

The differences between hosts live in [`inventory/host_vars/`](inventory/host_vars), one small file per host. Reading those five files tells you the whole lab's exposure.

## Usage

```bash
ansible-galaxy collection install -r requirements.yml

# Your real addresses, subnets and username (git-ignored)
cp inventory/group_vars/all/site.yml.example inventory/group_vars/all/site.yml

# Secrets (Tailscale auth key, optional Wazuh enrollment password)
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml

# Preview, then apply, one host at a time
ansible-playbook playbooks/site.yml --limit aiserver --check --diff --ask-vault-pass
ansible-playbook playbooks/site.yml --limit aiserver --ask-vault-pass

# Prove the result
ansible-playbook playbooks/verify.yml --limit aiserver
```

Run from the desktop (Trusted zone). The vault is reached over Tailscale by its MagicDNS name, because nothing on the LAN can reach it, Ansible included.

Tags let you apply one layer: `--tags ufw`, `--tags ssh`, `--tags wazuh`.

## Verification

[`playbooks/verify.yml`](playbooks/verify.yml) checks what the host actually does, not what the config files say:

- `sshd -T` (the settings sshd really uses) shows no password, keyboard-interactive or root login
- ufw is active and denies inbound by default
- fail2ban has the sshd jail loaded
- On the vault, port 8080 (Vaultwarden) listens on loopback only
- The Wazuh agent is held at the pinned version and reports `connected`

## CI

Every push runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml):

1. **Lint:** `yamllint --strict`, `ansible-lint` on the production profile, syntax check, and a check that the secrets file is never committed unencrypted.
2. **Converge:** a fresh Ubuntu runner configures itself with the playbook.
3. **Idempotence:** the playbook runs a second time and must report `changed=0`. A role that changes something on every run is hiding a bug.
4. **Verify:** the verify playbook runs against the result.

The Docker and Tailscale roles are linted and syntax-checked in CI but not converged: the runner already has Docker, and Tailscale needs a real tailnet.

### Bugs found before anything changed on a real server

| Symptom in CI | Cause | Fix |
|---|---|---|
| SSH role failed to validate its config: `Missing privilege separation directory: /run/sshd` | Ubuntu 24.04+ starts sshd on demand (`ssh.socket`), so the directory doesn't exist until the first login | Create `/run/sshd` before running `sshd -t` |
| Wazuh role couldn't parse `ossec.conf` | The agent config has two `<ossec_config>` roots, so it isn't valid XML and XML tools reject it | Targeted regex edits, one element each |
| Second run changed `net.ipv4.conf.all.log_martians` every time | ufw applies `/etc/ufw/sysctl.conf` on every reload, and its default turns martian logging **off**, silently undoing the hardening | Set the same value in ufw's file |
| `Timeout waiting for privilege escalation prompt` on the first real host | Ubuntu 26.04's `sudo` is sudo-rs, whose password prompt Ansible doesn't recognize | `ansible_become_exe: sudo.ws` (the classic sudo, still installed) on the 26.04 hosts |

The third one is the reason for the idempotence check. The first run looked perfect, and the setting would have been off on every server without any error.

## Design decisions

- **Guard rails before hardening.** The SSH role checks for an installed key before it disables passwords, and ufw rules go in before the default flips to deny. Same rule as my CIS batches: every change has to be reversible or safe to apply over SSH.
- **Pin what talks to the SIEM.** An agent newer than the manager can't connect, and Kali's rolling updates would upgrade it within weeks. The package is pinned and held with `dpkg`.
- **Least privilege for the vault, in code.** Its host vars are the shortest in the repo on purpose: one inbound rule, a different Tailscale tag, and active response off.
- **Docker skips ufw.** Published container ports go through Docker's own iptables chains, so Portainer's restriction lives in `DOCKER-USER`, managed in `after.rules` so it survives reboots.
- **Not managed here (yet):** pfSense, the TL-SG108E switch and the GL.iNet AP. They don't run Linux or a normal SSH/Python stack. They stay documented in Desk-Pi-Rack, with their config backups stored offline.

## Roadmap

- [ ] Compose stacks for the home lab services (Sentinel, Uptime Kuma, Wazuh) under a `services` role
- [ ] Molecule scenarios per role in Docker, including Debian for the Pis
- [ ] Wazuh FIM paths for the vault's keys and config, managed in the agent config
- [ ] Prometheus Pushgateway push from the vault through one narrow Tailscale grant

## License

MIT
