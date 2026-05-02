# /etc/skel/.zshrc — ShaniOS server profile
# Copied to every new user's home (including cloud-init's 'shanios' user).

# ── PATH ──────────────────────────────────────────────────────────────────────
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "/usr/local/bin"   ]] && export PATH="/usr/local/bin:$PATH"

# ── Starship prompt ───────────────────────────────────────────────────────────
# STARSHIP_CONFIG is set system-wide in /etc/profile.d/starship-server.sh
eval "$(starship init zsh)"

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

# ── Shell options ─────────────────────────────────────────────────────────────
setopt correct extendedglob nocaseglob rcexpandparam nocheckjobs
setopt numericglobsort nobeep appendhistory histignorealldups
setopt autocd auto_pushd pushd_ignore_dups pushdminus

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
bindkey -e
[[ -n "${terminfo[kpp]}"   ]] && bindkey "${terminfo[kpp]}"  up-line-or-history
[[ -n "${terminfo[knp]}"   ]] && bindkey "${terminfo[knp]}"  down-line-or-history
[[ -n "${terminfo[khome]}" ]] && bindkey "${terminfo[khome]}" beginning-of-line
[[ -n "${terminfo[kend]}"  ]] && bindkey "${terminfo[kend]}"  end-of-line
[[ -n "${terminfo[kcbt]}"  ]] && bindkey "${terminfo[kcbt]}"  reverse-menu-complete
bindkey '^?' backward-delete-char
[[ -n "${terminfo[kdch1]}" ]] && bindkey "${terminfo[kdch1]}" delete-char || {
    bindkey "^[[3~" delete-char; bindkey "^[3;5~" delete-char; }

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

if (( ${+terminfo[smkx]} && ${+terminfo[rmkx]} )); then
    autoload -Uz add-zle-hook-widget
    zle_application_mode_start() { echoti smkx }
    zle_application_mode_stop()  { echoti rmkx }
    add-zle-hook-widget -Uz zle-line-init   zle_application_mode_start
    add-zle-hook-widget -Uz zle-line-finish zle_application_mode_stop
fi

typeset -g -A key
key[Control-Left]="${terminfo[kLFT5]}"
key[Control-Right]="${terminfo[kRIT5]}"
key[Alt-Left]="${terminfo[kLFT3]}"
key[Alt-Right]="${terminfo[kRIT3]}"
[[ -n "${key[Control-Left]}"  ]] && bindkey "${key[Control-Left]}"  backward-word
[[ -n "${key[Control-Right]}" ]] && bindkey "${key[Control-Right]}" forward-word
[[ -n "${key[Alt-Left]}"      ]] && bindkey "${key[Alt-Left]}"      backward-word
[[ -n "${key[Alt-Right]}"     ]] && bindkey "${key[Alt-Right]}"     forward-word

# ── mcfly — MCFLY_* vars set system-wide in /etc/profile.d/mcfly-server.sh ───
command -v mcfly &>/dev/null && eval "$(mcfly init zsh)"

# ── fzf ───────────────────────────────────────────────────────────────────────
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'

# ── Aliases ───────────────────────────────────────────────────────────────────
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias dir='dir --color=auto'
alias ip='ip -color'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias tarnow='tar -acf'
alias untar='tar -zxvf'
alias wget='wget -c'
alias psmem='ps auxf | sort -nr -k 4'
alias psmem10='ps auxf | sort -nr -k 4 | head -10'
alias pscpu='ps auxf | sort -nr -k 3'
alias pscpu10='ps auxf | sort -nr -k 3 | head -10'
alias jctl='journalctl -p 3 -xb'
alias jf='journalctl -f'
alias jfu='journalctl -f -u'
alias sc='systemctl'
alias scs='systemctl status'
alias sce='systemctl enable --now'
alias scd='systemctl disable --now'
alias scr='systemctl restart'
alias ports='ss -tulnp'
alias myip='curl -s ifconfig.me'
alias localip='ip -br a'
alias hw='inxi -b'
alias df='df -hT'
alias du='du -sh'
alias dua='du -sh *'
alias btrfsdf='btrfs filesystem df'
alias btrfsus='btrfs filesystem usage'
alias docker='podman'
alias dps='podman ps -a'
alias dim='podman images'
alias dex='podman exec -it'
alias dlg='podman logs -f'
alias shani-update='sudo shani-deploy update'
alias rm='rm -I'
alias cp='cp -i'
alias mv='mv -i'
alias ln='ln -i'

# ── Environment ───────────────────────────────────────────────────────────────
export EDITOR=vim
export VISUAL=vim
export PAGER=less
export LESS='-R --use-color'
export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
