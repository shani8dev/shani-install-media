# /etc/skel/.zshrc — ShaniOS server profile default shell config
# Applied to every new user (including cloud-init's 'shanios' user and root).
# Sources: based on the ShaniOS desktop .zshrc, stripped of desktop-only items,
# tuned for server/remote ops use.

# ── PATH ──────────────────────────────────────────────────────────────────────
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "/usr/local/bin"   ]] && export PATH="/usr/local/bin:$PATH"

# ── Starship prompt ───────────────────────────────────────────────────────────
# Config: /etc/starship/server.toml (see overlay)
export STARSHIP_CONFIG="${STARSHIP_CONFIG:-/etc/starship/server.toml}"
eval "$(starship init zsh)"

# Terminal title: user@host:path
function set_win_title() {
    printf '\033]0;%s@%s:%s\007' "$USER" "$HOST" "${PWD/$HOME/~}"
}
precmd_functions+=(set_win_title)

# ── Plugins ───────────────────────────────────────────────────────────────────
[[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] \
    && source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] \
    && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

[[ -f /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh ]] \
    && source /usr/share/zsh/plugins/zsh-history-substring-search/zsh-history-substring-search.zsh

[[ -f /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
[[ -f /usr/share/fzf/completion.zsh    ]] && source /usr/share/fzf/completion.zsh

# ── Options ───────────────────────────────────────────────────────────────────
setopt correct              # Auto-correct typos
setopt extendedglob         # Extended glob patterns
setopt nocaseglob           # Case-insensitive globbing
setopt rcexpandparam        # Array expansion with parameters
setopt nocheckjobs          # Don't warn about background jobs on exit
setopt numericglobsort      # Sort filenames numerically
setopt nobeep               # No terminal bell
setopt appendhistory        # Append history immediately (multi-session safe)
setopt histignorealldups    # Remove older duplicates from history
setopt autocd               # Type a directory path to cd into it
setopt auto_pushd
setopt pushd_ignore_dups
setopt pushdminus

# ── Completion ────────────────────────────────────────────────────────────────
autoload -Uz compinit
compinit
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' rehash true
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' completer _expand _complete _ignored _approximate
zstyle ':completion:*' menu select
zstyle ':completion:*' select-prompt '%SScrolling: %p%s'
zstyle ':completion:*:descriptions' format '%U%F{cyan}%d%f%u'
zstyle ':completion:*' accept-exact '*(N)'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.cache/zcache

autoload -U +X bashcompinit && bashcompinit

# ── History ───────────────────────────────────────────────────────────────────
HISTFILE=~/.zhistory
HISTSIZE=50000
SAVEHIST=10000

# ── Key bindings ──────────────────────────────────────────────────────────────
bindkey -e   # Emacs key bindings

# PageUp / PageDown — history navigation
[[ -n "${terminfo[kpp]}"  ]] && bindkey "${terminfo[kpp]}"  up-line-or-history
[[ -n "${terminfo[knp]}"  ]] && bindkey "${terminfo[knp]}"  down-line-or-history

# Up/Down arrow — history prefix search
if [[ -n "${terminfo[kcuu1]}" ]]; then
    autoload -U up-line-or-beginning-search
    zle -N up-line-or-beginning-search
    bindkey "${terminfo[kcuu1]}" up-line-or-beginning-search
fi
if [[ -n "${terminfo[kcud1]}" ]]; then
    autoload -U down-line-or-beginning-search
    zle -N down-line-or-beginning-search
    bindkey "${terminfo[kcud1]}" down-line-or-beginning-search
fi

# Home / End
[[ -n "${terminfo[khome]}" ]] && bindkey "${terminfo[khome]}" beginning-of-line
[[ -n "${terminfo[kend]}"  ]] && bindkey "${terminfo[kend]}"  end-of-line

# Shift-Tab — reverse completion
[[ -n "${terminfo[kcbt]}"  ]] && bindkey "${terminfo[kcbt]}"  reverse-menu-complete

# Backspace / Delete
bindkey '^?' backward-delete-char
[[ -n "${terminfo[kdch1]}" ]] && bindkey "${terminfo[kdch1]}" delete-char || {
    bindkey "^[[3~"  delete-char
    bindkey "^[3;5~" delete-char
}

# Application mode (fixes Home/End in some terminals)
if (( ${+terminfo[smkx]} && ${+terminfo[rmkx]} )); then
    autoload -Uz add-zle-hook-widget
    zle_application_mode_start() { echoti smkx }
    zle_application_mode_stop()  { echoti rmkx }
    add-zle-hook-widget -Uz zle-line-init   zle_application_mode_start
    add-zle-hook-widget -Uz zle-line-finish zle_application_mode_stop
fi

# Ctrl-Left / Ctrl-Right — word navigation
typeset -g -A key
key[Control-Left]="${terminfo[kLFT5]}"
key[Control-Right]="${terminfo[kRIT5]}"
[[ -n "${key[Control-Left]}"  ]] && bindkey "${key[Control-Left]}"  backward-word
[[ -n "${key[Control-Right]}" ]] && bindkey "${key[Control-Right]}" forward-word

# Alt-Left / Alt-Right — word navigation
key[Alt-Left]="${terminfo[kLFT3]}"
key[Alt-Right]="${terminfo[kRIT3]}"
[[ -n "${key[Alt-Left]}"  ]] && bindkey "${key[Alt-Left]}"  backward-word
[[ -n "${key[Alt-Right]}" ]] && bindkey "${key[Alt-Right]}" forward-word

# ── mcfly: smart shell history (replaces Ctrl-R) ─────────────────────────────
export MCFLY_FUZZY=true
export MCFLY_RESULTS=20
export MCFLY_INTERFACE_VIEW=BOTTOM
export MCFLY_RESULTS_SORT=LAST_RUN
command -v mcfly &>/dev/null && eval "$(mcfly init zsh)"

# ── fzf: fuzzy finder ─────────────────────────────────────────────────────────
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'

# ── Server-tuned aliases ──────────────────────────────────────────────────────

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ip='ip -color'

# Process & memory
alias psmem='ps auxf | sort -nr -k 4'
alias psmem10='ps auxf | sort -nr -k 4 | head -10'
alias pscpu='ps auxf | sort -nr -k 3'
alias pscpu10='ps auxf | sort -nr -k 3 | head -10'

# Archive shortcuts
alias tarnow='tar -acf'
alias untar='tar -zxvf'
alias wget='wget -c'    # resume interrupted downloads

# Logging
alias jctl='journalctl -p 3 -xb'         # errors since last boot
alias jf='journalctl -f'                  # follow all logs
alias jfu='journalctl -f -u'             # follow specific unit: jfu sshd

# Systemd shortcuts
alias sc='systemctl'
alias scs='systemctl status'
alias sce='systemctl enable --now'
alias scd='systemctl disable --now'
alias scr='systemctl restart'

# Network
alias ports='ss -tulnp'                   # listening ports
alias myip='curl -s ifconfig.me'          # public IP
alias localip='ip -br a'                  # brief interface list

# Disk & Btrfs
alias df='df -hT'
alias du='du -sh'
alias dua='du -sh *'
alias btrfsdf='btrfs filesystem df'
alias btrfsus='btrfs filesystem usage'

# Containers (podman with docker-compat aliases)
alias docker='podman'
alias dps='podman ps -a'
alias dim='podman images'
alias dex='podman exec -it'
alias dlg='podman logs -f'

# ShaniOS update
alias shani-update='sudo shani-deploy update'

# Safety nets
alias rm='rm -I'           # prompt before removing 3+ files
alias cp='cp -i'
alias mv='mv -i'
alias ln='ln -i'

# Coloured output
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias dir='dir --color=auto'
alias hw='hwinfo --short 2>/dev/null || inxi -b'

# ── Environment ───────────────────────────────────────────────────────────────
export EDITOR=vim
export VISUAL=vim
export PAGER=less
export LESS='-R --use-color'

# Podman / containers
export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
