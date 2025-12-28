#!/usr/bin/env bash

################################################################################
# SecBuild v3.1 - Security Tools Automated Installer (Modular Version)
# Author: SecBuild Team
# Description: Ferramenta robusta e otimizada para instalação automatizada
#              de ferramentas de segurança em Kali Linux e Ubuntu
# Compatibility: Kali Linux, Ubuntu 20.04+
################################################################################

# Verificar versão do Bash (requer 4.0+ para arrays associativos)
if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
    echo "Erro: Este script requer Bash 4.0 ou superior." >&2
    echo "Versão atual: $BASH_VERSION" >&2
    echo "" >&2
    echo "No macOS, instale Bash atualizado via Homebrew:" >&2
    echo "  brew install bash" >&2
    echo "" >&2
    echo "Depois execute com:" >&2
    echo "  /usr/local/bin/bash $0" >&2
    echo "" >&2
    echo "Ou adicione ao /etc/shells e defina como shell padrão." >&2
    exit 1
fi

set -uo pipefail
IFS=$'\n\t'

export BASH_INI_PARSER_DEBUG=0   # ← ADICIONE ESTA LINHA


# ==============================================================================
# CONFIGURAÇÕES GLOBAIS
# ==============================================================================

readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly LOCALES_DIR="${SCRIPT_DIR}/locales"

# Diretórios de trabalho
readonly WORK_DIR="${WORK_DIR:-$HOME/.secbuild}"
readonly SRC_DIR="${SRC_DIR:-/usr/local/src/secbuild}"
readonly BIN_DIR="${BIN_DIR:-/usr/local/bin}"
readonly LOG_DIR="${WORK_DIR}/logs"
readonly CACHE_DIR="${WORK_DIR}/cache"
readonly VENDOR_DIR="${WORK_DIR}/vendor"
readonly CONFIG_DIR="${WORK_DIR}/config"
readonly BACKUP_DIR="${WORK_DIR}/backups"

# Arquivos de configuração e logs
readonly CONFIG_FILE="${CONFIG_DIR}/secbuild.conf"
readonly LOG_FILE="${LOG_DIR}/secbuild_$(date +%Y%m%d_%H%M%S).log"
readonly ERROR_LOG="${LOG_DIR}/secbuild_errors_$(date +%Y%m%d_%H%M%S).log"
readonly DEPS_LOCK="${WORK_DIR}/.deps.lock"

# URLs de recursos
readonly PACKAGE_INI_URL="https://raw.githubusercontent.com/DonatoReis/Secbuild/master/package-dist.ini"
readonly PROGRESSBAR_URL="https://github.com/NRZCode/progressbar"
readonly INI_PARSER_URL="https://github.com/NRZCode/bash-ini-parser"

# Configurações de sistema
readonly DOWNLOAD_TIMEOUT=300
readonly RETRY_COUNT=3
readonly RETRY_DELAY=5
readonly CACHE_TTL=86400
readonly HASH_ALGORITHM="sha256"

# Flags globais
FORCE_UPDATE=0
VERBOSE_MODE=0
SILENT_MODE=0
INTERACTIVE_MODE=1
DRY_RUN=0
PARALLEL_INSTALL=0
MAX_PARALLEL_JOBS=4
APT_UPDATE_DONE=0
USE_LATEST_RELEASE=1  # Sempre usar versão mais recente e estável do GitHub
DISTRO=""
PKG_MANAGER=""

# Arrays para ferramentas
declare -A TOOLS_REGISTRY
declare -A TOOLS_STATUS
declare -A TOOLS_PROFILES
declare -A PROFILE_TOOLS
declare -a FAILED_TOOLS=()
declare -a INSTALLED_TOOLS=()
declare -a SKIPPED_TOOLS=()

# ==============================================================================
# FUNÇÕES AUXILIARES PARA ARRAYS COM SEGURANÇA
# ==============================================================================

# Contar elementos de um array com segurança (compatível com set -u)
safe_array_count() {
    local array_name="$1"
    local count=0
    
    # Desabilitar temporariamente set -u
    set +u
    
    # Verificar se o array existe e tem elementos
    if declare -p "$array_name" &>/dev/null; then
        eval "count=\${#${array_name}[@]}"
    fi
    
    # Reabilitar set -u
    set -u
    
    echo "$count"
}

# Verificar se array tem elementos
array_has_elements() {
    local array_name="$1"
    local count
    count=$(safe_array_count "$array_name")
    [[ $count -gt 0 ]]
}

# Validar que arrays foram inicializados corretamente
validate_arrays() {
    local arrays=("FAILED_TOOLS" "INSTALLED_TOOLS" "SKIPPED_TOOLS" "TOOLS_REGISTRY")
    for arr in "${arrays[@]}"; do
        if ! declare -p "$arr" &>/dev/null; then
            echo "Erro: Array $arr não foi inicializado corretamente" >&2
            return 1
        fi
    done
    return 0
}

# ==============================================================================
# CARREGAR MÓDULOS
# ==============================================================================

# Carregar módulos na ordem correta
load_modules() {
    # 1. i18n primeiro (para traduções)
    if [[ -f "$LIB_DIR/i18n.sh" ]]; then
        source "$LIB_DIR/i18n.sh"
        init_i18n
    else
        echo "Erro: Módulo i18n.sh não encontrado!" >&2
        exit 1
    fi
    
    # 2. system (cores, diretórios)
    if [[ -f "$LIB_DIR/system.sh" ]]; then
        source "$LIB_DIR/system.sh"
    else
        echo "Erro: Módulo system.sh não encontrado!" >&2
        exit 1
    fi
    
    # 3. logging
    if [[ -f "$LIB_DIR/logging.sh" ]]; then
        source "$LIB_DIR/logging.sh"
        init_logging
    else
        echo "Erro: Módulo logging.sh não encontrado!" >&2
        exit 1
    fi
    
    # 4. cache
    if [[ -f "$LIB_DIR/cache.sh" ]]; then
        source "$LIB_DIR/cache.sh"
    fi
    
    # 5. validation
    if [[ -f "$LIB_DIR/validation.sh" ]]; then
        source "$LIB_DIR/validation.sh"
    fi
    
    # 6. config
    if [[ -f "$LIB_DIR/config.sh" ]]; then
        source "$LIB_DIR/config.sh"
    fi
    
    # 7. install
    if [[ -f "$LIB_DIR/install.sh" ]]; then
        source "$LIB_DIR/install.sh"
    else
        echo "Erro: Módulo install.sh não encontrado!" >&2
        exit 1
    fi
    
    # 8. ui (opcional - funções de interface)
    if [[ -f "$LIB_DIR/ui.sh" ]]; then
        source "$LIB_DIR/ui.sh"
    fi
}

# ==============================================================================
# CLEANUP E TRATAMENTO DE SINAIS
# ==============================================================================

# Cleanup em caso de interrupção ou saída
cleanup_on_exit() {
    local exit_code=$?
    
    # Matar processos filhos (jobs em background) - compatível com macOS e Linux
    local child_pids
    child_pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$child_pids" ]]; then
        echo "$child_pids" | while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done
    fi
    
    # Limpar arquivos temporários de instalação paralela
    rm -f /tmp/secbuild_*_$$.tmp 2>/dev/null || true
    
    # Limpar outros arquivos temporários
    rm -f /tmp/secbuild_* 2>/dev/null || true
    
    # Se houve erro, mostrar mensagem
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]] && [[ $exit_code -ne 143 ]]; then
        # Só mostrar erro se logging estiver inicializado
        if command -v error &>/dev/null; then
            error "Script interrompido com código de saída: $exit_code"
        fi
    fi
    
    exit "$exit_code"
}

# Configurar traps para cleanup
trap cleanup_on_exit EXIT INT TERM

# ==============================================================================
# FUNÇÕES AUXILIARES (UI e Progresso)
# ==============================================================================

print_banner() {
    cat << 'EOF'

███████╗███████╗ ██████╗██████╗ ██╗   ██╗██╗██╗     ██████╗     ██╗   ██╗██████╗ 
██╔════╝██╔════╝██╔════╝██╔══██╗██║   ██║██║██║     ██╔══██╗    ██║   ██║╚════██╗
███████╗█████╗  ██║     ██████╔╝██║   ██║██║██║     ██║  ██║    ██║   ██║ ██████╔╝
╚════██║██╔══╝  ██║     ██╔══██╗██║   ██║██║██║     ██║  ██║    ╚██╗ ██╔╝ ╚════██╗
███████║███████╗╚██████╗██████╔╝╚██████╔╝██║███████╗██████╔╝     ╚████╔╝ ██████╔╝
╚══════╝╚══════╝ ╚═════╝╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝       ╚═══╝  ╚═════╝ 

EOF
    echo -e "${CYAN}$(t 'usage.title' "$SCRIPT_VERSION")${RESET}"
    echo -e "${BLUE}$(t 'usage.subtitle')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
}

# Função auxiliar para formatar tempo
format_time() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%dh%02dm%02ds" "$hours" "$minutes" "$secs"
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm%02ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

# Barra de progresso melhorada (NOVA MELHORIA)
show_progress() {
    local current=$1
    local total=$2
    local msg="${3:-Processing...}"
    local width=50
    
    [[ $total -eq 0 ]] && total=1
    
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    
    # Calcular tempo decorrido e estimativa (se START_TIME estiver definido)
    local elapsed_str=""
    local remaining_str=""
    local speed_str=""
    
    if [[ -n "${START_TIME:-}" ]]; then
        local elapsed=$(($(date +%s) - START_TIME))
        elapsed_str=$(format_time "$elapsed")
        
        # Calcular estimativa baseada na velocidade média
        if [[ $current -gt 0 ]] && [[ $elapsed -gt 0 ]]; then
            local avg_time_per_item=$((elapsed / current))
            local remaining=$((avg_time_per_item * (total - current)))
            remaining_str=$(format_time "$remaining")
            
            # Calcular velocidade (itens por minuto)
            local speed=$((current * 60 / elapsed))
            [[ $speed -gt 0 ]] && speed_str="${speed}/min"
        fi
    fi
    
    # Cores baseadas em progresso
    local color=""
    [[ $percentage -lt 33 ]] && color="\033[0;31m"  # Vermelho
    [[ $percentage -ge 33 && $percentage -lt 66 ]] && color="\033[0;33m"  # Amarelo
    [[ $percentage -ge 66 ]] && color="\033[0;32m"  # Verde
    
    # Construir barra visual
    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="█"
    done
    for ((i=filled; i<width; i++)); do
        bar+="░"
    done
    
    # Output formatado melhorado
    printf "\r\033[K"
    printf "${color}[%3d%%]${RESET} " "$percentage"
    printf "[${color}%s${RESET}] " "$bar"
    printf "(%d/%d) " "$current" "$total"
    printf "${CYAN}%-20s${RESET} " "${msg:0:20}"
    
    # Adicionar informações de tempo se disponíveis
    if [[ -n "$elapsed_str" ]]; then
        printf "[${YELLOW}%s${RESET}" "$elapsed_str"
        [[ -n "$remaining_str" ]] && printf " / ${YELLOW}%s${RESET}" "$remaining_str"
        printf "]"
        [[ -n "$speed_str" ]] && printf " [${GREEN}%s${RESET}]" "$speed_str"
    fi
}

print_installation_summary() {
    echo
    echo -e "${CYAN}$(t 'summary.title')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    # Usar função helper para contar arrays com segurança
    local installed_count failed_count skipped_count
    installed_count=$(safe_array_count "INSTALLED_TOOLS")
    failed_count=$(safe_array_count "FAILED_TOOLS")
    skipped_count=$(safe_array_count "SKIPPED_TOOLS")
    
    if array_has_elements "INSTALLED_TOOLS"; then
        echo -e "${GREEN}$(t 'summary.installed' "$installed_count")${RESET}"
        set +u
        for tool in "${INSTALLED_TOOLS[@]}"; do
            echo "  ✓ $tool"
        done
        set -u
    fi
    
    if array_has_elements "FAILED_TOOLS"; then
        echo
        echo -e "${RED}$(t 'summary.failed' "$failed_count")${RESET}"
        set +u
        for tool in "${FAILED_TOOLS[@]}"; do
            echo "  ✗ $tool"
        done
        set -u
    fi
    
    if array_has_elements "SKIPPED_TOOLS"; then
        echo
        echo -e "${YELLOW}$(t 'summary.skipped' "$skipped_count")${RESET}"
        set +u
        for tool in "${SKIPPED_TOOLS[@]}"; do
            echo "  ⊘ $tool"
        done
        set -u
    fi
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    local total=$((installed_count + failed_count + skipped_count))
    local success_rate=0
    [[ $total -gt 0 ]] && success_rate=$(( (installed_count + skipped_count) * 100 / total ))
    
    echo -e "$(t 'summary.success_rate' "$success_rate")"
    
    [[ $failed_count -gt 0 ]] && warning "$(t 'summary.check_log')\n$ERROR_LOG"
}

# ==============================================================================
# MENU INTERATIVO (Simplificado - UI completa pode ser extraída depois)
# ==============================================================================

show_main_menu() {
    while true; do
        clear
        print_banner
        
        echo -e "${CYAN}$(t 'menu.main')${RESET}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo
        echo -e "  ${GREEN}1)${RESET} $(t 'menu.install_all')"
        echo -e "  ${GREEN}2)${RESET} $(t 'menu.install_specific')"
        echo -e "  ${GREEN}3)${RESET} $(t 'menu.install_profile')"
        echo -e "  ${GREEN}4)${RESET} $(t 'menu.list_tools')"
        echo -e "  ${GREEN}5)${RESET} $(t 'menu.check_installed')"
        echo -e "  ${GREEN}6)${RESET} $(t 'menu.update_tools')"
        echo -e "  ${GREEN}7)${RESET} $(t 'menu.settings')"
        echo -e "  ${GREEN}8)${RESET} $(t 'menu.view_logs')"
        echo -e "  ${GREEN}9)${RESET} $(t 'menu.about')"
        echo -e "  ${RED}0)${RESET} $(t 'menu.exit')"
        echo
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo
        
        read -rp "$(t 'menu.choose') " choice
        
        case "$choice" in
            1) menu_install_all ;;
            2) menu_install_specific ;;
            3) menu_install_profile ;;
            4) menu_list_tools ;;
            5) menu_check_installed ;;
            6) menu_update_tools ;;
            7) menu_settings ;;
            8) menu_view_logs ;;
            9) menu_about ;;
            0) exit_script ;;
            *) warning "$(t 'menu.invalid')" && sleep 2 ;;
        esac
    done
}

menu_install_all() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.install_all')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    info "Esta operação instalará todas as ${#TOOLS_REGISTRY[@]} ferramentas disponíveis."
    warning "Isso pode levar bastante tempo!"
    echo
    read -rp "Deseja continuar? (s/N): " confirm
    [[ "$confirm" =~ ^[Ss]$ ]] && install_all_tools
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_install_specific() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.install_specific')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -rp "Digite o nome da ferramenta (ou 'voltar'): " tool_name
    [[ "$tool_name" == "voltar" ]] && return
    tool_name="${tool_name,,}"
    [[ -n "${TOOLS_REGISTRY[$tool_name]:-}" ]] && install_single_tool "$tool_name"
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_install_profile() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.install_profile')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    
    # Verificar se há perfis disponíveis
    set +u
    local profile_count=${#PROFILE_TOOLS[@]}
    set -u
    
    if [[ $profile_count -eq 0 ]]; then
        warning "profile.none"
        echo
        info "profile.defined"
        echo "  $(t 'profile.example')"
        echo
        read -rp "Pressione ENTER para continuar..."
        return
    fi
    
    # Listar perfis com numeração
    echo -e "${GREEN}$(t 'profile.available')${RESET}"
    echo
    
    local profile_num=1
    declare -A profile_map
    local sorted_profiles
    
    # Ordenar perfis alfabeticamente
    set +u
    sorted_profiles=$(printf '%s\n' "${!PROFILE_TOOLS[@]}" | sort)
    set -u
    
    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        
        set +u
        local tool_list="${PROFILE_TOOLS[$profile]}"
        set -u
        local tool_count
        tool_count=$(echo "$tool_list" | wc -w)
        
        # Obter descrição do perfil se disponível (do tools_config.yaml)
        local profile_desc=""
        case "$profile" in
            recon) profile_desc="Reconhecimento e coleta de informações" ;;
            dns) profile_desc="Análise e enumeração DNS" ;;
            subdomains) profile_desc="Descoberta de subdomínios" ;;
            web) profile_desc="Segurança de aplicações web" ;;
            fuzzing) profile_desc="Fuzzing e brute force" ;;
            ssl) profile_desc="Análise SSL/TLS" ;;
            network) profile_desc="Varredura de rede" ;;
            osint) profile_desc="Inteligência de código aberto" ;;
            wifi) profile_desc="Segurança WiFi" ;;
            automation) profile_desc="Automação de testes" ;;
            parameters) profile_desc="Descoberta de parâmetros" ;;
            takeover) profile_desc="Detecção de subdomain takeover" ;;
            cloud) profile_desc="Segurança cloud" ;;
            social) profile_desc="Engenharia social" ;;
            utilities) profile_desc="Utilitários auxiliares" ;;
            pentest) profile_desc="Kit completo de pentesting" ;;
            bugbounty) profile_desc="Ferramentas para bug bounty" ;;
            all) profile_desc="Todas as ferramentas" ;;
        esac
        
        if [[ -n "$profile_desc" ]]; then
            echo -e "  ${GREEN}$profile_num)${RESET} ${CYAN}$profile${RESET} - $profile_desc (${YELLOW}$tool_count${RESET} ferramentas)"
        else
            echo -e "  ${GREEN}$profile_num)${RESET} ${CYAN}$profile${RESET} - ${YELLOW}$tool_count${RESET} ferramentas"
        fi
        
        profile_map[$profile_num]="$profile"
        ((profile_num++))
    done <<< "$sorted_profiles"
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -rp "$(t 'menu.choose') " choice
    
    # Verificar se é número ou nome
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        # Seleção por número
        if [[ -n "${profile_map[$choice]:-}" ]]; then
            profile="${profile_map[$choice]}"
        else
            error "profile.invalid"
            sleep 2
            return
        fi
    elif [[ "$choice" == "voltar" || "$choice" == "back" ]]; then
        return
    else
        # Seleção por nome
        profile="${choice,,}"
    fi
    
    # Confirmar instalação
    echo
    set +u
    local tool_list="${PROFILE_TOOLS[$profile]}"
    set -u
    
    if [[ -z "$tool_list" ]]; then
        error "profile.not_found" "$profile"
        sleep 2
        return
    fi
    
    local tool_count
    tool_count=$(echo "$tool_list" | wc -w)
    
    warning "Esta operação instalará $tool_count ferramenta(s) do perfil '$profile'"
    echo
    read -rp "Deseja continuar? (s/N): " confirm
    
    if [[ "$confirm" =~ ^[Ss]$ ]]; then
        install_profile "$profile"
    else
        info "Instalação cancelada"
    fi
    
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_list_tools() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.list_tools')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    local count=0
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        ((count++))
        local status="${RED}✗${RESET}"
        is_installed_tool "$tool" && status="${GREEN}✓${RESET}"
        printf "%3d. [%b] %-20s" "$count" "$status" "$tool"
        [[ $((count % 3)) -eq 0 ]] && echo
    done
    [[ $((count % 3)) -ne 0 ]] && echo
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_check_installed() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.check_installed')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    local installed_count=0
    local not_installed_count=0
    
    echo -e "${GREEN}Instaladas:${RESET}"
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        if is_installed_tool "$tool"; then
            echo "  ✓ $tool"
            ((installed_count++))
        fi
    done
    
    echo
    echo -e "${RED}Não instaladas:${RESET}"
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        if ! is_installed_tool "$tool"; then
            echo "  ✗ $tool"
            ((not_installed_count++))
        fi
    done
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "Resumo: ${GREEN}$installed_count instaladas${RESET} | ${RED}$not_installed_count não instaladas${RESET}"
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_update_tools() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.update_tools')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    info "Verificando atualizações para ferramentas Git..."
    echo
    
    local updated=0
    local failed=0
    
    while IFS= read -r -d '' git_dir; do
        local repo_dir="${git_dir%/.git}"
        local repo_name="${repo_dir##*/}"
        echo -n "Atualizando $repo_name... "
        if git -C "$repo_dir" pull -q --all >>"$LOG_FILE" 2>&1; then
            echo -e "${GREEN}✓${RESET}"
            ((updated++))
        else
            echo -e "${RED}✗${RESET}"
            ((failed++))
        fi
    done < <(find "$SRC_DIR" -type d -name .git -print0 2>/dev/null)
    
    [[ $((updated + failed)) -eq 0 ]] && warning "Nenhum repositório Git encontrado"
    echo
    echo -e "Resultado: ${GREEN}$updated atualizadas${RESET} | ${RED}$failed falharam${RESET}"
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_settings() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.settings')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo "  1) Modo verbose: $([ $VERBOSE_MODE -eq 1 ] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
    echo "  2) Modo silencioso: $([ $SILENT_MODE -eq 1 ] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
    echo "  3) Atualizar lista de ferramentas"
    echo "  4) Forçar reinstalação de dependências"
    echo "  5) Resetar configurações"
    echo "  6) Voltar"
    echo
    read -rp "$(t 'menu.choose') " choice
    
    case "$choice" in
        1) 
            VERBOSE_MODE=$((1 - VERBOSE_MODE))
            success "Modo verbose: $([ $VERBOSE_MODE -eq 1 ] && echo "ativado" || echo "desativado")"
            save_config
            sleep 1
            ;;
        2) 
            SILENT_MODE=$((1 - SILENT_MODE))
            success "Modo silencioso: $([ $SILENT_MODE -eq 1 ] && echo "ativado" || echo "desativado")"
            save_config
            sleep 1
            ;;
        3)
            download_package_ini && parse_package_ini
            success "Lista de ferramentas atualizada"
            sleep 2
            ;;
        4)
            rm -f "$DEPS_LOCK"
            install_core_dependencies
            install_vendor_tools
            touch "$DEPS_LOCK"
            success "Dependências reinstaladas"
            sleep 2
            ;;
        5) 
            rm -f "$CONFIG_FILE"
            warning "Configurações resetadas"
            sleep 2
            ;;
        6) 
            return
            ;;
        *) 
            warning "$(t 'menu.invalid')"
            sleep 2
            ;;
    esac
}

menu_view_logs() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'menu.view_logs')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo "  1) Log completo"
    echo "  2) Log de erros"
    echo "  3) Últimas 50 linhas"
    echo "  4) Listar todos os logs"
    echo "  5) Limpar logs antigos"
    echo "  6) Voltar"
    echo
    read -rp "$(t 'menu.choose') " choice
    
    case "$choice" in
        1) 
            if [[ -f "$LOG_FILE" ]]; then
                less "$LOG_FILE"
            else
                warning "Log não encontrado"
                sleep 2
            fi
            ;;
        2) 
            if [[ -f "$ERROR_LOG" ]]; then
                less "$ERROR_LOG"
            else
                warning "Log de erros não encontrado"
                sleep 2
            fi
            ;;
        3)
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 50 "$LOG_FILE" | less
            else
                warning "Log não encontrado"
                sleep 2
            fi
            ;;
        4)
            ls -lah "$LOG_DIR" | less
            ;;
        5)
            find "$LOG_DIR" -type f -mtime +7 -delete 2>/dev/null
            success "Logs com mais de 7 dias removidos"
            sleep 2
            ;;
        6) 
            return
            ;;
        *) 
            warning "$(t 'menu.invalid')"
            sleep 2
            ;;
    esac
}

menu_about() {
    clear
    print_banner
    echo -e "${CYAN}$(t 'about.title')${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo -e "${GREEN}$(t 'about.version' "$SCRIPT_VERSION")${RESET}"
    echo
    echo "$(t 'about.description')"
    echo
    echo -e "${CYAN}$(t 'about.features')${RESET}"
    echo "  • $(t 'about.feature1')"
    echo "  • $(t 'about.feature2')"
    echo "  • $(t 'about.feature3')"
    echo "  • $(t 'about.feature4')"
    echo "  • $(t 'about.feature5')"
    echo "  • $(t 'about.feature6')"
    echo "  • $(t 'about.feature7')"
    echo
    echo -e "${CYAN}$(t 'about.compatibility')${RESET}"
    echo "  • $(t 'about.compat1')"
    echo "  • $(t 'about.compat2')"
    echo "  • $(t 'about.compat3')"
    echo
    echo -e "${CYAN}$(t 'about.directories')${RESET}"
    echo "  • $(t 'about.work' "$WORK_DIR")"
    echo "  • $(t 'about.sources' "$SRC_DIR")"
    echo "  • $(t 'about.binaries' "$BIN_DIR")"
    echo "  • $(t 'about.logs' "$LOG_DIR")"
    echo
    read -rp "Pressione ENTER para continuar..."
}

exit_script() {
    echo
    info "Encerrando SecBuild..."
    rm -f /tmp/secbuild_* 2>/dev/null
    
    # Usar função helper para contar arrays com segurança
    local installed_count failed_count skipped_count
    installed_count=$(safe_array_count "INSTALLED_TOOLS")
    failed_count=$(safe_array_count "FAILED_TOOLS")
    skipped_count=$(safe_array_count "SKIPPED_TOOLS")
    
    if [[ $((installed_count + failed_count + skipped_count)) -gt 0 ]]; then
        print_installation_summary
    fi
    
    success "SecBuild encerrado com sucesso!"
    exit 0
}

# ==============================================================================
# TRATAMENTO DE ERROS
# ==============================================================================

on_error() {
    local line="$1"
    local code="$2"
    local cmd="${3:-}"
    
    error "╔════════════════════════════════════════╗"
    error "║  ERRO DETECTADO                        ║"
    error "╠════════════════════════════════════════╣"
    error "║  Linha: $line"
    error "║  Código: $code"
    [[ -n "$cmd" ]] && error "║  Comando: $cmd"
    error "║  Log: $LOG_FILE"
    error "╚════════════════════════════════════════╝"
    
    # Dump do estado atual para debug
    if [[ ${VERBOSE_MODE:-0} -eq 1 ]]; then
        {
            echo "=== Estado dos Arrays ==="
            echo "INSTALLED_TOOLS: $(safe_array_count 'INSTALLED_TOOLS')"
            echo "FAILED_TOOLS: $(safe_array_count 'FAILED_TOOLS')"
            echo "SKIPPED_TOOLS: $(safe_array_count 'SKIPPED_TOOLS')"
        } >> "${ERROR_LOG:-/dev/null}" 2>/dev/null || true
    fi
}

trap 'on_error ${LINENO} $? "${BASH_COMMAND}"' ERR

trap_handler() {
    echo
    warning "Interrompido pelo usuário!"
    exit_script
}

trap trap_handler INT TERM

# ==============================================================================
# FUNÇÃO PRINCIPAL
# ==============================================================================

show_usage() {
    cat <<EOF
${CYAN}$(t 'usage.title' "$SCRIPT_VERSION")${RESET}
${BLUE}$(t 'usage.subtitle')${RESET}

${GREEN}$(t 'usage.usage')${RESET}
  sudo $SCRIPT_NAME [OPÇÕES]

${GREEN}$(t 'usage.options')${RESET}
  -h, --help          Mostrar esta ajuda
  -v, --verbose       Modo verboso (debug)
  -f, --force         Forçar atualização de dependências
  -s, --silent        Modo silencioso (não-interativo)
  -l, --list          Listar ferramentas disponíveis
  -i, --install TOOL  Instalar ferramenta específica
  -u, --update        Atualizar todas as ferramentas instaladas
  --dry-run           Modo simulação (não executa comandos reais)
  -p, --parallel [N]  Instalação paralela (N = número de jobs, padrão: 4)
  --profile NAME      Instalar perfil específico
  --list-profiles     Listar perfis disponíveis
  --no-latest-release Desabilitar instalação da versão mais recente (usar branch padrão)

${GREEN}$(t 'usage.examples')${RESET}
  sudo $SCRIPT_NAME                    # Modo interativo
  sudo $SCRIPT_NAME -i nmap            # Instalar ferramenta específica
  sudo $SCRIPT_NAME -l                 # Listar ferramentas
  sudo $SCRIPT_NAME --dry-run           # Simular instalação
  sudo $SCRIPT_NAME -p 8                # Instalar em paralelo
  sudo $SCRIPT_NAME --profile recon     # Instalar perfil

EOF
}

main() {
    # Validar arrays antes de começar
    validate_arrays || exit 1
    
    # Carregar módulos
    load_modules
    
    # Configurar cores
    setup_colors
    
    # Criar diretórios
    create_directories
    
    # Detectar sistema primeiro (pode permitir modo de teste no macOS)
    detect_system
    
    # Verificar root (passar argumentos para verificar se é comando de listagem)
    check_root "$@"
    
    # Carregar configurações
    load_config
    
    # Carregar tools_config.yaml
    load_tools_config_yaml
    
    # Parse argumentos
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_usage; exit 0 ;;
            -v|--verbose) VERBOSE_MODE=1; shift ;;
            --debug) set -x; VERBOSE_MODE=1; shift ;;
            -f|--force) FORCE_UPDATE=1; shift ;;
            -s|--silent) SILENT_MODE=1; INTERACTIVE_MODE=0; shift ;;
            -l|--list)
                [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
                parse_package_ini
                menu_list_tools
                exit 0
                ;;
            -i|--install)
                shift
                [[ -n "${1:-}" ]] && {
                    INTERACTIVE_MODE=0
                    [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
                    parse_package_ini
                    install_single_tool "$1"
                    exit $?
                } || { error "Nome da ferramenta necessário"; exit 1; }
                ;;
            -u|--update) INTERACTIVE_MODE=0; menu_update_tools; exit 0 ;;
            --dry-run) DRY_RUN=1; info "dryrun.mode"; shift ;;
            -p|--parallel)
                PARALLEL_INSTALL=1
                shift
                [[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]] && { MAX_PARALLEL_JOBS="$1"; shift; }
                info "Instalação paralela ativada (máx: $MAX_PARALLEL_JOBS jobs)"
                ;;
            --profile)
                shift
                [[ -n "${1:-}" ]] && {
                    INTERACTIVE_MODE=0
                    [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
                    parse_package_ini
                    install_profile "$1"
                    exit $?
                } || { error "Nome do perfil necessário"; exit 1; }
                ;;
            --list-profiles)
                [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
                parse_package_ini
                list_profiles
                exit 0
                ;;
            --no-latest-release)
                USE_LATEST_RELEASE=0
                info "Instalação da versão mais recente desabilitada"
                shift
                ;;
            *) warning "Argumento desconhecido: $1"; shift ;;
        esac
    done
    
    # Modo não-interativo
    if [[ $INTERACTIVE_MODE -eq 0 ]]; then
        info "Executando em modo não-interativo"
        [[ ! -f "$DEPS_LOCK" || $FORCE_UPDATE -eq 1 ]] && {
            install_core_dependencies
            install_vendor_tools
            touch "$DEPS_LOCK"
        }
        download_package_ini
        parse_package_ini
        # Usar função helper para verificar arrays
        local installed_count failed_count
        installed_count=$(safe_array_count "INSTALLED_TOOLS")
        failed_count=$(safe_array_count "FAILED_TOOLS")
        [[ $installed_count -eq 0 && $failed_count -eq 0 ]] && install_all_tools
        exit 0
    fi
    
    # Modo interativo
    print_banner
    info "Iniciando SecBuild v$SCRIPT_VERSION"
    
    [[ ! -f "$DEPS_LOCK" || $FORCE_UPDATE -eq 1 ]] && {
        install_core_dependencies
        install_vendor_tools
        touch "$DEPS_LOCK"
    }
    
    [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
    parse_package_ini
    
    show_main_menu
}

# Executar apenas se não estiver sendo sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
