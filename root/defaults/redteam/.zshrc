# =============================================================================
# red-webtop .zshrc — seeded for the abc user on first container start.
# Plugins (autosuggestions, syntax-highlighting, zsh-completions) are installed
# system-wide at build time and simply sourced/added to fpath here — no runtime
# downloads. Order matters: env → mise (adds tools + completions to PATH/fpath) →
# compinit → interactive plugins → starship.
# =============================================================================

# --- Environment -------------------------------------------------------------
export LC_CTYPE="C.UTF-8"          # correct width for multi-byte glyphs in the prompt

# The linuxserver base runs its desktop from a private python venv at /lsiopy and
# exports VIRTUAL_ENV=/lsiopy globally, so it leaks into our shell and starship
# renders a stray "(lsiopy)" venv in the prompt. That venv is the base's, not the
# user's — drop it (and its bin from PATH) for interactive shells so the prompt is clean.
if [[ "${VIRTUAL_ENV:-}" == /lsiopy ]]; then
    unset VIRTUAL_ENV
    path=(${path:#/lsiopy/bin})
fi

# uv: put user-installed tools in a WRITABLE per-user dir so `uv tool install <x>`
# works without sudo. The image's build-time tools (jwt-tool) live in the
# root-owned /opt/uv + /usr/local/bin and stay available; this just adds a personal
# dir on top, under /config so it persists on the volume.
export UV_TOOL_DIR="$HOME/.local/share/uv/tools"
export UV_TOOL_BIN_DIR="$HOME/.local/bin"
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"

# --- History (shared across terminals) ---------------------------------------
HISTFILE="${ZSH_HISTFILE:-$HOME/.zsh_history}"
HISTSIZE=100000
SAVEHIST=100000
setopt INC_APPEND_HISTORY SHARE_HISTORY EXTENDED_HISTORY \
       HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_EXPIRE_DUPS_FIRST \
       HIST_IGNORE_DUPS HIST_VERIFY
alias history="history 0"          # show the full history, not just the tail

# --- Shell behaviour + keybindings (Kali defaults) ---------------------------
setopt autocd interactivecomments magicequalsubst nonomatch notify \
       numericglobsort promptsubst
WORDCHARS='_-'
PROMPT_EOL_MARK=""

bindkey -e                                        # emacs keys
bindkey ' ' magic-space                           # history expansion on space
bindkey '^U' backward-kill-line
bindkey '^[[3;5~' kill-word                        # ctrl+del
bindkey '^[[3~' delete-char
bindkey '^[[1;5C' forward-word                     # ctrl+->
bindkey '^[[1;5D' backward-word                    # ctrl+<-
bindkey '^[[5~' beginning-of-buffer-or-history     # pgup
bindkey '^[[6~' end-of-buffer-or-history           # pgdn
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[Z' undo                                # shift+tab

# --- mise (runtime version manager) — before compinit so tools land on PATH ---
# `mise activate zsh` also wires mise's own completions into fpath.
eval "$(mise activate zsh)"

# --- Completions -------------------------------------------------------------
# Add the zsh-users/zsh-completions repo (cloned system-wide at build time) to
# fpath BEFORE compinit — it provides completions Debian's zsh doesn't ship, e.g.
# openssl. The distro vendor/site dirs (docker, git, curl, systemd, …) are already
# on fpath by default.
[[ -d /usr/local/share/zsh-completions/src ]] && \
    fpath=(/usr/local/share/zsh-completions/src $fpath)

autoload -Uz compinit
compinit -C -d "${XDG_CACHE_HOME:-$HOME/.cache}/zcompdump"   # -C: trust system dirs, faster

# On-the-fly completions: on first TAB for a command, try `<cmd> completion zsh`
# so modern tools that ship their own completion (uv, nxc, starship, …) just work
# without a static _<cmd> file.
_try_load_completion() {
    local cmd=$words[1]
    local out=$($cmd completion zsh 2>/dev/null)
    if [[ $out == *compdef* ]]; then
        source <(echo $out)
        ${_comps[$cmd]} "$@"
    else
        _default "$@"
    fi
}
_comps[-default-]=_try_load_completion
zstyle ':completion:*:*:*:*:*' menu select
zstyle ':completion:*' completer _expand _complete
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' rehash true
zstyle ':completion:*' use-compctl false
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# --- Colours + aliases -------------------------------------------------------
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    export LS_COLORS="$LS_COLORS:ow=30;44:"        # readable 777 dirs
    alias ls='ls --color=auto'; alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'; alias egrep='egrep --color=auto'
    alias diff='diff --color=auto'; alias ip='ip --color=auto'
    # coloured man pages via less
    export LESS_TERMCAP_mb=$'\E[1;31m' LESS_TERMCAP_md=$'\E[1;36m' LESS_TERMCAP_me=$'\E[0m'
    export LESS_TERMCAP_so=$'\E[01;33m' LESS_TERMCAP_se=$'\E[0m'
    export LESS_TERMCAP_us=$'\E[1;32m' LESS_TERMCAP_ue=$'\E[0m' MANROFFOPT="-c"
    zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
    zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
fi
alias ll='ls -l'; alias la='ls -A'; alias l='ls -CF'

# --- Interactive plugins (installed system-wide at build time) ---------------
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && {
    . /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'
}
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
    . /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /etc/zsh_command_not_found ] && . /etc/zsh_command_not_found

# --- Prompt (starship) -------------------------------------------------------
eval "$(starship init zsh)"
