# /etc/skel/.bashrc — ShaniOS server profile
# Copied to every new user's home. Consistent with .zshrc.

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# ── Starship prompt ───────────────────────────────────────────────────────────
# STARSHIP_CONFIG is set system-wide in /etc/profile.d/starship-server.sh
if [ -x /usr/bin/starship ]; then
    __main() {
        local major="${BASH_VERSINFO[0]}"
        local minor="${BASH_VERSINFO[1]}"
        if ((major > 4)) || { ((major == 4)) && ((minor >= 1)); }; then
            source <("/usr/bin/starship" init bash --print-full-init)
        else
            source /dev/stdin <<<"$("/usr/bin/starship" init bash --print-full-init)"
        fi
    }
    __main
    unset -f __main
fi

# Terminal title
case "$TERM" in
    xterm*|rxvt*|screen*|tmux*)
        PROMPT_COMMAND='printf "\033]0;%s@%s:%s\007" "$USER" "$HOSTNAME" "${PWD/$HOME/~}"'
        ;;
esac

# ── PATH ──────────────────────────────────────────────────────────────────────
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "/usr/local/bin"   ]] && export PATH="/usr/local/bin:$PATH"

# ── History ───────────────────────────────────────────────────────────────────
HISTFILE=~/.bash_history
HISTSIZE=50000
HISTFILESIZE=10000
HISTCONTROL=ignoredups:erasedups
shopt -s histappend
shopt -s cmdhist
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }history -a"

# ── Shell options ─────────────────────────────────────────────────────────────
shopt -s checkwinsize autocd cdspell dirspell globstar nocaseglob

# ── Completion ────────────────────────────────────────────────────────────────
if ! shopt -oq posix; then
    if [[ -f /usr/share/bash-completion/bash_completion ]]; then
        source /usr/share/bash-completion/bash_completion
    elif [[ -f /etc/bash_completion ]]; then
        source /etc/bash_completion
    fi
fi

# ── mcfly — MCFLY_* vars set system-wide in /etc/profile.d/mcfly-server.sh ───
command -v mcfly &>/dev/null && eval "$(mcfly init bash)"

# ── fzf ───────────────────────────────────────────────────────────────────────
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
[[ -f /usr/share/fzf/key-bindings.bash ]] && source /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash   ]] && source /usr/share/fzf/completion.bash

# ── Aliases ───────────────────────────────────────────────────────────────────
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias dir='dir --color=auto'
alias vdir='vdir --color=auto'
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
