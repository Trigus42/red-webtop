# red-webtop

A browser-accessible **red-team + digital-forensics workstation**: a full KDE desktop
in your browser with the **Autopsy 4.23.1** GUI and a zsh terminal preloaded with
offensive CLI tools — built on [linuxserver.io Webtop](https://docs.linuxserver.io/images/docker-webtop/)
(Debian/KDE).

## Quick start

Copy the example compose file (it holds your runtime env, so it isn't tracked) and
bring the stack up:

```bash
cp docker-compose.example.yaml docker-compose.yaml
docker compose up -d --build
```

or plain Docker:

```bash
docker build -t red-webtop:latest .
docker run -d --name red-webtop --privileged --shm-size=2g \
  -p 3000:3000 -p 3001:3001 -p 8384:8384 -p 2222:22 \
  -e SSHD_ENABLE=true -e SYNCTHING_ENABLE=true \
  -v "$PWD/config:/config" \
  red-webtop:latest
```

Open **http://localhost:3000** (HTTPS on 3001). Launch **Autopsy** from the KDE
Security/Forensics menu, or open a terminal for the CLI tools.

Everything under **`/config`** (cases, evidence, shell history, ssh keys, syncthing
state) persists in the mounted `./config` volume.

> To route all traffic through a VPN, use the Gluetun variant instead — see
> [VPN (Gluetun)](#vpn-gluetun).

## SSH access

Key-only (no password), user **`abc`**, enabled with `SSHD_ENABLE=true`. Drop your
public key in the config volume before starting:

```bash
mkdir -p config/.ssh
cat ~/.ssh/id_ed25519.pub >> config/.ssh/authorized_keys
```

Then connect to the host-mapped port:

```bash
ssh -p 2222 abc@localhost
```

## What's inside

| | |
|---|---|
| Desktop | KDE via browser (Selkies), user `abc` |
| **Autopsy GUI** | 4.23.1 in `/opt/autopsy` (TSK 4.15.0 + JNI built from source, JDK 17, JavaFX 17) |
| Shell | zsh + starship + mise + uv, autosuggestions/syntax-highlighting, rich completions |
| Offensive CLI | **ffuf**, **sliver**, **hashcat**, **evil-winrm**, **jwt-tool** |
| Docker-in-Docker | provided by the base; active because we run `--privileged` |

`abc` can `uv tool install <pkg>` and `mise use -g ...` without sudo (user tools land
in `~/.local/bin` / your mise path, both persisted under `/config`).

## Services (all opt-in, off by default)

| Service | Enable with | Port | Notes |
|---|---|---|---|
| **sshd** | `SSHD_ENABLE=true` | 2222→22 | key-only; see [SSH access](#ssh-access) |
| **syncthing** | `SYNCTHING_ENABLE=true` | 8384 | runs as `abc`; state under `/config`; device ID in `docker logs` |
| **gocryptfs** | `GOCRYPTFS_PASSWORD=…` | — | encrypted host volume (needs `/dev/fuse`); cipher-text in `/workspace/host-unencrypted`, decrypted at `/workspace/host-encrypted` |
| **Docker (DIND)** | `--privileged` (default on) | — | `abc` is in the `docker` group; persist with `-v ./docker-data:/var/lib/docker` |

## VPN (Gluetun)

Route **all** of red-webtop's traffic through a WireGuard VPN with a kill switch, using
a [Gluetun](https://github.com/qdm12/gluetun) sidecar that owns the network namespace
(if the tunnel drops, nothing leaks). Ports are published on the gluetun container, so
the desktop/ssh stay reachable regardless of VPN state.

```bash
cp docker-compose.gluetun.example.yaml docker-compose.gluetun.yaml
mkdir -p vpn-configs                 # drop your WireGuard config at vpn-configs/wg0.conf
docker compose -f docker-compose.gluetun.yaml up -d --build
```

`wg0.conf` is standard `wg-quick` format. Its `DNS =` line is ignored — Gluetun uses its
own encrypted DoT resolver (Quad9 by default; set `DNS_UPSTREAM_RESOLVERS`). Set
`VPN_IPV6=off` if your provider lacks IPv6, and `FIREWALL_OUTBOUND_SUBNETS=<cidr>` to
allow LAN access outside the tunnel.

## Adding more tools

No Kali/apt repo — tools come from portable sources that don't disturb the base:

```bash
mise use -g ubi:<owner>/<repo>   # any GitHub-release binary (e.g. ubi:ffuf/ffuf)
uv tool install <pypi-pkg>       # isolated Python tool (e.g. pipx install netexec)
gem install <gem>                # Ruby gems (GEM_HOME=/opt/gems preset)
```

Avoid `apt install` of anything that pulls a newer `python3.X` as the default
interpreter — it shadows the base's Selkies desktop and breaks the browser session.

## Notes

- **Why no Kali repo:** mixing Kali into Debian stable dragged in `python3.14` and broke
  the Selkies desktop. Portable binaries keep Autopsy on a stable library floor while the
  tools stay current. **netexec** isn't baked in (needs a Rust build) — `pipx install netexec`.
- **Build caching:** the Dockerfile puts the ~GB Autopsy/TSK build in an early layer, tools
  in the middle, and `root/` (services/config) last — so editing config rebuilds nothing
  expensive, and editing the tool list still reuses the cached Autopsy layer.
- **Autopsy** is installed exactly as in [`webtop-autopsy`](../webtop-autopsy) (see it for
  the ingest modules disabled by default on Linux/ARM).
