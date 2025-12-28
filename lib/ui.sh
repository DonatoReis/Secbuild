#!/usr/bin/env bash
################################################################################
# ui.sh - Funções de Interface do Usuário
# Spinners, animações e elementos visuais
################################################################################

# Função de spinner animado melhorada
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    echo -n " "
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf "\b%c" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\b \b"
}

# Função spinner com mensagem
spinner() {
    local pid="$1"
    local task="$2"
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    while kill -0 "$pid" 2>/dev/null; do
        for i in $(seq 0 9); do
            printf "\r${CYAN}${spinstr:$i:1}${RESET} %s" "$task"
            sleep 0.1
        done
    done
    printf "\r%*s\r" $((${#task} + 2)) ""
}

