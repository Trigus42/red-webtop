# syntax=docker/dockerfile:1
###############################################################################
# red-webtop — Autopsy 4.23.1 digital-forensics GUI + a CLI red-team toolset,
# baked into the linuxserver.io Webtop (Debian, KDE) browser desktop container.
# Works on amd64 & arm64.
#
# This image = webtop-autopsy (Debian/KDE) + a curated red-team toolset & the
# useful services ported from a Kali RDP container, adapted to Webtop's world:
#   * remote access is Webtop's browser desktop (Selkies) — NO xrdp/vnc
#   * services are s6-overlay v3 units — NO supervisord
#   * Docker-in-Docker is provided by the Webtop base (run --privileged) — we
#     install nothing for it; the base's "abc" user is already in the docker group
#   * no bwrap-shim: this base has no bubblewrap/glycin (that Kali workaround is moot)
#
# TOOLING IS DISTRO-AGNOSTIC — NO KALI REPO. Mixing Kali's apt repo into Debian
# stable caused dependency skew (it dragged in python3.14 and broke the base's
# Selkies desktop). Instead the offensive tools come from portable sources that
# don't touch the base system libraries:
#   * ffuf, sliver  — prebuilt arm64/amd64 GitHub-release binaries via `mise` (ubi:)
#   * hashcat       — Debian repo
#   * evil-winrm    — Ruby gem (isolated GEM_HOME)
#   * netexec       — NOT baked in (needs a Rust build); `pipx install netexec` to add
# This keeps Autopsy on a stable library floor while the tools stay current.
#
# Build:   docker build -t red-webtop:latest .
# Run:     docker run -d --name red-webtop --privileged --shm-size=2g \
#            -p 3000:3000 -p 3001:3001 -p 8384:8384 -p 2222:22 \
#            -e SSHD_ENABLE=true -e SYNCTHING_ENABLE=true \
#            -v "$PWD/config:/config" \
#            red-webtop:latest
#          then open http://localhost:3000 (KDE desktop); launch "Autopsy" from the
#          menu, open a terminal for the red-team CLI tools (zsh + starship).
#
# LAYERING (so adding a tool / editing config does NOT rebuild the ~GB Autopsy
# stack): the expensive Autopsy/TSK build is an early, stable layer; the red-team
# tool install is a middle layer; the volatile config/services come last via
# COPY root/. Docker reuses a cached layer until it (or something above it)
# changes, and a COPY is keyed on file contents — so editing root/ reuses BOTH
# install layers, and editing the tool list still reuses the Autopsy layer.
###############################################################################

FROM lscr.io/linuxserver/webtop:debian-kde

LABEL org.opencontainers.image.title="red-webtop" \
      org.opencontainers.image.description="Autopsy 4.23.1 forensic GUI + CLI red-team toolset on linuxserver Webtop (Debian KDE)"

# --- Build-time knobs --------------------------------------------------------
ARG AUTOPSY_VER=4.23.1
ARG TSK_VER=4.15.0

# =============================================================================
# LAYER 2 — EXPENSIVE + STABLE: Autopsy 4.x + The Sleuth Kit (built from source).
# Keep this near the top so it stays cached across tool/config changes below.
# =============================================================================
COPY install-autopsy-debian.sh /usr/local/src/install-autopsy-debian.sh
RUN chmod +x /usr/local/src/install-autopsy-debian.sh \
    && AUTOPSY_VER="${AUTOPSY_VER}" TSK_VER="${TSK_VER}" \
       /usr/local/src/install-autopsy-debian.sh
# Trim apt cache in a SEPARATE layer so cleanup can never mask the installer's exit code.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

# =============================================================================
# LAYER 3 — MEDIUM: CLI red-team toolset + shell environment (zsh/starship/mise/uv).
# All from portable, distro-agnostic sources (NO Kali repo — see header). Runs as
# one RUN so a change here re-runs only this layer, not the Autopsy build.
#
# uv note: the ONE build-time tool (jwt_tool) is installed system-wide into
# /usr/local/bin so every user gets it. We deliberately do NOT export UV_TOOL_DIR
# as a global ENV — that would force the abc user's own `uv tool install` at runtime
# into a root-owned dir and fail without sudo. abc's ~/.zshrc instead points
# UV_TOOL_DIR / UV_TOOL_BIN_DIR at a writable per-user location under /config.
#
# GEM_HOME is exported globally (/etc/profile.d) so the evil-winrm launcher finds
# its gems for every user/shell.
# =============================================================================
ENV GEM_HOME=/opt/gems \
    GEM_PATH=/opt/gems
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    export UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin; \
    apt-get update; \
    # --- shell + dev tooling, service deps, and tool build deps, from Debian ---
    #   chromium-sandbox: the base ships Chromium with no SUID sandbox helper and a
    #   wrapper (/usr/local/bin/wrapped-chromium) that decides the sandbox flag from
    #   /proc/1/status Seccomp: on a NORMAL (non-privileged) webtop Seccomp is
    #   filtered (2) so the wrapper adds --no-sandbox and Chromium launches. But we
    #   run --privileged for DIND, which sets Seccomp to 0 — so the wrapper takes its
    #   "privileged ⇒ sandbox works" branch WITHOUT --no-sandbox. That branch then
    #   needs a working sandbox, but unprivileged "abc" can't set up the userns one
    #   (can't write a multi-uid /proc/self/uid_map without CAP_SETUID) → "No usable
    #   sandbox". Installing the SUID chrome-sandbox helper makes that privileged
    #   branch actually TRUE: Chromium runs fully sandboxed (Chromium's own fix). This
    #   completes our --privileged choice rather than masking it with --no-sandbox.
    apt-get install -y --no-install-recommends \
        zsh git git-lfs nano curl ca-certificates \
        zsh-autosuggestions zsh-syntax-highlighting \
        openssh-server syncthing gocryptfs fuse3 \
        hashcat \
        ruby ruby-dev build-essential \
        chromium-sandbox; \
    # --- extra zsh completions (openssl, etc.) — not a Debian package, so clone
    #     the upstream repo to a system fpath location; abc's .zshrc adds it to fpath ---
    git clone --depth 1 https://github.com/zsh-users/zsh-completions.git \
        /usr/local/share/zsh-completions; \
    rm -rf /usr/local/share/zsh-completions/.git; \
    # --- starship prompt ---
    curl -fsSL https://starship.rs/install.sh | sh -s -- --yes; \
    # --- mise (runtime version manager) ---
    curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh; \
    # --- uv + one build-time uv-managed tool (jwt_tool) into the system bin ---
    curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    mkdir -p "$UV_TOOL_DIR"; \
    uv tool install --no-cache git+https://github.com/Trigus42/jwt_tool.git; \
    # --- offensive tools as portable binaries via mise `ubi:` (prebuilt GitHub
    #     releases — arm64 & amd64), installed into a shared mise dir and symlinked
    #     onto /usr/local/bin so they're on PATH for everyone without mise activation.
    #     A tool whose release lacks this arch is logged and skipped (no silent caps). ---
    export MISE_DATA_DIR=/opt/mise MISE_CONFIG_DIR=/opt/mise MISE_CACHE_DIR=/tmp/mise-cache; \
    for spec in "ffuf=ubi:ffuf/ffuf" "sliver=ubi:BishopFox/sliver"; do \
        name="${spec%%=*}"; src="${spec#*=}"; \
        if mise use -g "${src}@latest"; then \
            echo "  installed (mise ubi): ${name} <- ${src}"; \
        else \
            echo "  WARNING: could not install '${name}' via ${src} — skipping"; \
        fi; \
    done; \
    # symlink every binary mise installed into /usr/local/bin (covers sliver-server/client)
    find /opt/mise/installs -maxdepth 3 -type f -perm -u+x 2>/dev/null | while read -r f; do \
        ln -sf "$f" "/usr/local/bin/$(basename "$f")"; \
    done; \
    # --- evil-winrm as a Ruby gem into the shared GEM_HOME ---
    gem install --no-document evil-winrm; \
    ln -sf /opt/gems/bin/evil-winrm /usr/local/bin/evil-winrm; \
    # --- export the gem env for all login shells so evil-winrm resolves its gems ---
    printf 'export GEM_HOME=/opt/gems\nexport GEM_PATH=/opt/gems\n' > /etc/profile.d/redteam-gems.sh; \
    # --- make zsh the abc user's login shell ---
    chsh -s /bin/zsh abc; \
    mkdir -p /run/sshd; \
    # --- hard-fail verification: assert every tool we promised is present ---
    fail=0; \
    check() { if command -v "$1" >/dev/null 2>&1 || [ -e "$1" ]; then echo "  ok: $1"; else echo "  MISSING: $1"; fail=1; fi; }; \
    check zsh; check starship; check mise; check uv; check jwt-tool; \
    check /usr/sbin/sshd; check syncthing; check gocryptfs; \
    check /usr/local/share/zsh-completions/src/_openssl; \
    check ffuf; check hashcat; check sliver; check evil-winrm; \
    { [ -u /usr/lib/chromium/chrome-sandbox ] && echo "  ok: chromium SUID sandbox"; } || { echo "  MISSING: chrome-sandbox SUID"; fail=1; }; \
    GEM_HOME=/opt/gems GEM_PATH=/opt/gems evil-winrm --help >/dev/null 2>&1 \
        && echo "  ok: evil-winrm runs" || { echo "  BROKEN: evil-winrm"; fail=1; }; \
    getent passwd abc | grep -q '/bin/zsh' && echo "  ok: abc shell=zsh" || { echo "  MISSING: abc zsh shell"; fail=1; }; \
    /lsiopy/bin/python3 -c 'import selkies' 2>/dev/null \
        && echo "  ok: base Selkies desktop intact (system python untouched)" \
        || { echo "  BROKEN: selkies import failed"; fail=1; }; \
    [ "$fail" = 0 ] || { echo "ERROR: red-team layer verification failed"; exit 1; }
# Trim apt cache in a SEPARATE layer (same reason as above).
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

# =============================================================================
# LAYER 4 — CHEAP + VOLATILE: s6 services, config seeds, desktop entry.
#   root/etc/s6-overlay/...   Autopsy config seed (oneshot) + redteam shell seed
#                             (oneshot) + sshd/syncthing/gocryptfs (longruns)
#   root/defaults/...         seed data copied into /config at container start
#   root/etc/ssh/sshd_config  key-only sshd config (safe to bake; not under /config)
# Editing anything here reuses BOTH cached install layers above.
# =============================================================================
COPY root/ /

# Ports/volumes/entrypoint inherited from the Webtop base (3000 HTTP desktop,
# 3001 HTTPS; /config is the persistent user volume). We additionally use
# 8384 (syncthing UI) and 22 (sshd) when those services are enabled.
EXPOSE 22/tcp 8384/tcp
