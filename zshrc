# Path to your oh-my-zsh configuration.
ZSH=$HOME/.oh-my-zsh

# Set name of the theme to load.
# Look in ~/.oh-my-zsh/themes/
# Optionally, if you set this to "random", it'll load a random theme each
# time that oh-my-zsh is loaded.
# ZSH_THEME="half-life"

# Set to this to use case-sensitive completion
# CASE_SENSITIVE="true"

# Comment this out to disable weekly auto-update checks
DISABLE_AUTO_UPDATE="true"

# Uncomment following line if you want to disable colors in ls
# DISABLE_LS_COLORS="true"

# Uncomment following line if you want to disable autosetting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment following line if you want red dots to be displayed while waiting for completion
COMPLETION_WAITING_DOTS="true"

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Example format: plugins=(rails git textmate ruby lighthouse)
# plugins=(autojump brew bundler cloudapp git github gem rails3 rake rvm ssh-agent terminalapp thor osx)

source $ZSH/oh-my-zsh.sh
. $HOME/.files/powerline/powerline/bindings/zsh/powerline.zsh

# Customize to your needs...
export PATH=/usr/local/sbin:/usr/local/bin:$(brew --prefix ruby193)/bin:/usr/local/share/python:/bin:/sbin:/usr/bin:/usr/sbin:/usr/X11/bin

export EDITOR="vim"
export GIT_EDITOR="vim +1"
set -o vi

eval "$(hub alias -s)"

alias stats="history | awk '{a[\$2]++} END {for(i in a){print a[i] \" \" i}}' | sort -nr | head"
alias reload-shell="source ~/.zshrc"
