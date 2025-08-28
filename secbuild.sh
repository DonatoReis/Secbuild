#!/usr/bin/env bash

################################################################################
# SecBuild v3.0 - Security Tools Automated Installer
# Author: SecBuild Team (Production Version)
# Description: Ferramenta robusta e otimizada para instalação automatizada
#              de ferramentas de segurança em Kali Linux e Ubuntu
# Compatibility: Kali Linux, Ubuntu 20.04+
################################################################################

set -uo pipefail  # Modo seguro: falha em erros, variáveis não definidas e pipes
IFS=$'\n\t'        # Separador de campo seguro

# ==============================================================================
# CONFIGURAÇÕES GLOBAIS
# ==============================================================================

readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Flags globais
FORCE_UPDATE=0
VERBOSE_MODE=0
SILENT_MODE=0
INTERACTIVE_MODE=1
DISTRO=""
PKG_MANAGER=""

# Arrays para ferramentas
declare -A TOOLS_REGISTRY
declare -A TOOLS_STATUS
declare -a FAILED_TOOLS
declare -a INSTALLED_TOOLS
declare -a SKIPPED_TOOLS

# ==============================================================================
# CORES E FORMATAÇÃO
# ==============================================================================

setup_colors() {
    if [[ -t 1 ]] && command -v tput &>/dev/null; then
        BOLD="$(tput bold)"
        RESET="$(tput sgr0)"
        RED="$(tput setaf 1)"
        GREEN="$(tput setaf 2)"
        YELLOW="$(tput setaf 3)"
        BLUE="$(tput setaf 4)"
        MAGENTA="$(tput setaf 5)"
        CYAN="$(tput setaf 6)"
        WHITE="$(tput setaf 7)"
    else
        BOLD=""
        RESET=""
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        MAGENTA=""
        CYAN=""
        WHITE=""
    fi
}

# ==============================================================================
# TRATAMENTO DE ERROS AVANÇADO
# ==============================================================================

on_error() {
    local line="$1"
    local code="$2"
    local cmd="${3:-}"
    error "Erro na linha $line (código: $code)"
    [[ -n "$cmd" ]] && error "Comando: $cmd"
    error "Verifique o log em: $LOG_FILE"
}

trap 'on_error ${LINENO} $? "${BASH_COMMAND}"' ERR

trap_handler() {
    echo
    warning "Interrompido pelo usuário!"
    exit_script
}

trap trap_handler INT TERM

# ==============================================================================
# FUNÇÕES DE LOGGING E OUTPUT
# ==============================================================================

log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Garante que os caminhos existem antes de gravar
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
    : > "$ERROR_LOG" 2>/dev/null || true

    # Log para arquivo
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Log de erros específico
    [[ "$level" == "ERROR" ]] && echo "[$timestamp] $message" >> "$ERROR_LOG"

    # Output no terminal (se não silencioso)
    if [[ $SILENT_MODE -eq 0 ]]; then
        case "$level" in
            ERROR)   echo -e "${RED}[✗]${RESET} $message" >&2 ;;
            SUCCESS) echo -e "${GREEN}[✓]${RESET} $message" ;;
            WARNING) echo -e "${YELLOW}[!]${RESET} $message" ;;
            INFO)    echo -e "${BLUE}[i]${RESET} $message" ;;
            DEBUG)   [[ $VERBOSE_MODE -eq 1 ]] && echo -e "${CYAN}[D]${RESET} $message" ;;
            *)       echo "$message" ;;
        esac
    fi
}

error() { log "ERROR" "$@"; }
success() { log "SUCCESS" "$@"; }
warning() { log "WARNING" "$@"; }
info() { log "INFO" "$@"; }
debug() { log "DEBUG" "$@"; }

print_banner() {
    cat << 'EOF'

███████╗███████╗ ██████╗██████╗ ██╗   ██╗██╗██╗     ██████╗     ██╗   ██╗██████╗ 
██╔════╝██╔════╝██╔════╝██╔══██╗██║   ██║██║██║     ██╔══██╗    ██║   ██║╚════██╗
███████╗█████╗  ██║     ██████╔╝██║   ██║██║██║     ██║  ██║    ██║   ██║ ██████╔╝
╚════██║██╔══╝  ██║     ██╔══██╗██║   ██║██║██║     ██║  ██║    ╚██╗ ██╔╝ ╚════██╗
███████║███████╗╚██████╗██████╔╝╚██████╔╝██║███████╗██████╔╝     ╚████╔╝ ██████╔╝
╚══════╝╚══════╝ ╚═════╝╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝       ╚═══╝  ╚═════╝ 

EOF
    echo -e "${CYAN}Advanced Security Tools Installer - Version $SCRIPT_VERSION${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
}

# Barra de progresso corrigida
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

# Função de progresso melhorada com cores e animação
show_progress() {
    local current=$1
    local total=$2
    local msg="${3:-Processing...}"
    local width=50
    
    if [[ $total -eq 0 ]]; then
        total=1
    fi
    
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    
    # Cores baseadas no progresso
    local color=""
    if [[ $percentage -lt 33 ]]; then
        color="\033[0;31m"  # Vermelho
    elif [[ $percentage -lt 66 ]]; then
        color="\033[0;33m"  # Amarelo
    else
        color="\033[0;32m"  # Verde
    fi
    
    # Limpar linha e construir barra
    printf "\r\033[K"
    printf "[%3d%%] " $percentage
    printf "${color}["
    
    # Parte preenchida com animação
    for ((i=0; i<filled; i++)); do
        if [[ $i -eq $((filled-1)) ]] && [[ $filled -lt $width ]]; then
            printf "▶"
        else
            printf "█"
        fi
    done
    
    # Parte vazia
    for ((i=filled; i<width; i++)); do
        printf "░"
    done
    
    printf "]\033[0m ${msg:0:40}"
}

# Função melhorada para instalar ferramentas Go
install_go_tool_with_retry() {
    local tool_name="$1"
    local package="$2"
    local attempts=3
    local count=0
    
    while [[ $count -lt $attempts ]]; do
        count=$((count + 1))
        debug "Tentativa $count de $attempts para instalar $tool_name"
        
        # Tentar diferentes métodos de instalação
        if go install "${package}@latest" &>>"$LOG_FILE" 2>&1; then
            return 0
        elif go get -u "${package}" &>>"$LOG_FILE" 2>&1; then
            return 0
        elif GO111MODULE=on go get "${package}" &>>"$LOG_FILE" 2>&1; then
            return 0
        fi
        
        [[ $count -lt $attempts ]] && sleep 2
    done
    
    return 1
}

# Melhorar tratamento de requirements Python
install_requirements_safe() {
    local req_file="$1"
    local tool_name="$2"
    
    if [[ ! -f "$req_file" ]]; then
        return 0
    fi
    
    # Atualizar pip primeiro
    python3 -m pip install --upgrade pip &>>"$LOG_FILE" 2>&1
    
    # Tentar instalar com diferentes estratégias
    if python3 -m pip install -r "$req_file" --no-warn-script-location &>>"$LOG_FILE" 2>&1; then
        return 0
    elif python3 -m pip install -r "$req_file" --user --no-warn-script-location &>>"$LOG_FILE" 2>&1; then
        return 0
    elif python3 -m pip install -r "$req_file" --break-system-packages &>>"$LOG_FILE" 2>&1; then
        return 0
    fi
    
    return 1
}



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

# ==============================================================================
# FUNÇÕES DE SISTEMA E DETECÇÃO
# ==============================================================================

detect_system() {
    info "Detectando sistema operacional..."
    
    # Verificar se é Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        error "Este script suporta apenas sistemas Linux (Kali/Ubuntu)"
        error "Sistema detectado: $OSTYPE"
        exit 1
    fi
    
    # Detectar distribuição Linux
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="${ID:-unknown}"
        debug "Distribuição detectada: $DISTRO"
        
        # Verificar compatibilidade
        case "$DISTRO" in
            kali|ubuntu|debian)
                success "Sistema compatível detectado: $DISTRO"
                ;;
            *)
                warning "Distribuição '$DISTRO' não testada. O script pode não funcionar corretamente."
                read -p "Deseja continuar mesmo assim? (s/N): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Ss]$ ]]; then
                    exit 1
                fi
                ;;
        esac
    else
        error "Não foi possível detectar a distribuição Linux"
        exit 1
    fi
    
    # Detectar gerenciador de pacotes
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        debug "Gerenciador de pacotes: APT"
    else
        error "APT não encontrado. Este script requer APT (Kali/Ubuntu)"
        exit 1
    fi
    
    success "Sistema: $DISTRO | Gerenciador: $PKG_MANAGER"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Este script precisa ser executado como root!"
        info "Use: sudo $SCRIPT_NAME"
        exit 1
    fi
}

create_directories() {
    info "Criando estrutura de diretórios..."
    local dirs=(
        "$WORK_DIR"
        "$SRC_DIR"
        "$LOG_DIR"
        "$CACHE_DIR"
        "$VENDOR_DIR"
        "$CONFIG_DIR"
        "$BACKUP_DIR"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || {
                error "Falha ao criar diretório: $dir"
                exit 1
            }
            debug "Diretório criado: $dir"
        fi
    done
    
    # Garantir BIN_DIR no PATH
    case ":$PATH:" in
        *":$BIN_DIR:"*) 
            debug "BIN_DIR já está no PATH"
            ;;
        *) 
            export PATH="$BIN_DIR:$PATH"
            debug "BIN_DIR adicionado ao PATH"
            ;;
    esac
    
    success "Estrutura de diretórios criada"
}

# ==============================================================================
# INSTALAÇÃO DE DEPENDÊNCIAS CRÍTICAS (MELHORADA)
# ==============================================================================

# Verificação melhorada de pacotes instalados
pkg_installed_apt() {
    local package="$1"
    
    # Primeiro tenta verificar via dpkg-query
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
        return 0
    fi
    
    # Fallback: verificar se o comando existe
    if command -v "$package" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

install_core_dependencies() {
    info "Instalando dependências principais do sistema..."
    
    local core_deps=(
        "curl"
        "wget"
        "git"
        "build-essential"
        "python3"
        "python3-pip"
        "golang-go"
        "cargo"
        "cmake"
        "jq"
        "dialog"
        "bc"
        "realpath"
    )
    
    # Atualizar repositórios
    info "Atualizando repositórios APT..."
    if ! apt-get update -qq 2>>"$ERROR_LOG"; then
        warning "Falha ao atualizar repositórios"
    fi
    
    # Instalar dependências
    local failed_deps=()
    for dep in "${core_deps[@]}"; do
        if ! pkg_installed_apt "$dep"; then
            info "Instalando $dep..."
            if ! apt-get install -y -qq "$dep" &>>"$LOG_FILE"; then
                warning "Falha ao instalar $dep"
                failed_deps+=("$dep")
            else
                debug "$dep instalado com sucesso"
            fi
        else
            debug "$dep já está instalado"
        fi
    done
    
    # Relatar falhas
    if [[ ${#failed_deps[@]} -gt 0 ]]; then
        warning "Algumas dependências falharam: ${failed_deps[*]}"
        warning "Você pode precisar instalá-las manualmente"
    else
        success "Todas as dependências principais instaladas"
    fi
    
    # Configurar pip se necessário
    if command -v pip3 &>/dev/null; then
        debug "Atualizando pip..."
        pip3 install --upgrade pip &>>"$LOG_FILE" || warning "Falha ao atualizar pip"
    fi
}

install_vendor_tools() {
    info "Baixando ferramentas auxiliares..."
    
    # Instalar progressbar
    if [[ ! -d "$VENDOR_DIR/progressbar" ]]; then
        info "Instalando progressbar..."
        if git clone -q "$PROGRESSBAR_URL" "$VENDOR_DIR/progressbar" &>>"$LOG_FILE"; then
            debug "Progressbar instalado"
        else
            warning "Falha ao instalar progressbar"
        fi
    fi
    
    # Instalar bash-ini-parser
    if [[ ! -d "$VENDOR_DIR/bash-ini-parser" ]]; then
        info "Instalando bash-ini-parser..."
        if git clone -q "$INI_PARSER_URL" "$VENDOR_DIR/bash-ini-parser" &>>"$LOG_FILE"; then
            debug "Bash-ini-parser instalado"
        else
            warning "Falha ao instalar bash-ini-parser"
        fi
    fi
    
    # Verificar e carregar o parser
    if [[ -f "$VENDOR_DIR/bash-ini-parser/bash-ini-parser" ]]; then
        source "$VENDOR_DIR/bash-ini-parser/bash-ini-parser"
        success "Ferramentas auxiliares instaladas"
    else
        warning "Bash-ini-parser não encontrado, usando parser manual"
    fi
}

# ==============================================================================
# DOWNLOAD E PARSE DO ARQUIVO INI (MELHORADO)
# ==============================================================================

download_package_ini() {
    local ini_file="$CONFIG_DIR/package.ini"
    
    info "Baixando arquivo de configuração das ferramentas..."
    
    # Fazer backup se existir
    if [[ -f "$ini_file" ]]; then
        local backup_file="$BACKUP_DIR/package.ini.$(date +%Y%m%d_%H%M%S)"
        cp "$ini_file" "$backup_file"
        debug "Backup criado: $backup_file"
    fi
    
    # Primeiro tentar copiar o arquivo local
    if [[ -f "$SCRIPT_DIR/package-dist.ini" ]]; then
        cp "$SCRIPT_DIR/package-dist.ini" "$ini_file"
        success "Arquivo de configuração copiado localmente"
    else
        # Baixar do repositório com retry
        local attempt=1
        while [[ $attempt -le $RETRY_COUNT ]]; do
            if wget -q -O "$ini_file" --timeout="$DOWNLOAD_TIMEOUT" "$PACKAGE_INI_URL"; then
                success "Arquivo de configuração baixado"
                break
            else
                warning "Tentativa $attempt/$RETRY_COUNT falhou"
                ((attempt++))
                [[ $attempt -le $RETRY_COUNT ]] && sleep "$RETRY_DELAY"
            fi
        done
        
        if [[ $attempt -gt $RETRY_COUNT ]]; then
            error "Falha ao baixar arquivo de configuração após $RETRY_COUNT tentativas"
            return 1
        fi
    fi
    
    [[ -r "$ini_file" ]] || {
        error "Arquivo de configuração não encontrado ou sem permissão de leitura"
        return 1
    }
}

parse_package_ini() {
    local ini_file="$CONFIG_DIR/package.ini"
    
    info "Processando configuração das ferramentas..."
    
    if [[ ! -f "$ini_file" ]]; then
        error "Arquivo package.ini não encontrado"
        return 1
    fi
    
    # Limpar registro anterior
    TOOLS_REGISTRY=()
    
    # Parse manual do arquivo INI (melhorado)
    local current_tool=""
    local url=""
    local script=""
    local depends=""
    local post_install=""
    
    while IFS= read -r line; do
        # Remove espaços em branco
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Pular linhas vazias e comentários (# ou ;)
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*[\#\;] ]] && continue
        
        # Nova seção (ferramenta)
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            # Salvar ferramenta anterior se existir
            if [[ -n "$current_tool" ]]; then
                TOOLS_REGISTRY["$current_tool"]="$url|$script|$depends|$post_install"
                debug "Registrada ferramenta: $current_tool"
            fi
            
            # Iniciar nova ferramenta
            current_tool="${BASH_REMATCH[1],,}"  # Converter para minúsculas
            url=""
            script=""
            depends=""
            post_install=""
            
        # Processar atributos (key=value ou key = value)
        elif [[ "$line" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Remover espaços extras
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            # Remover aspas se existirem
            value="${value#\'}"
            value="${value%\'}"
            value="${value#\"}"
            value="${value%\"}"
            
            case "$key" in
                url) url="$value" ;;
                script) script="$value" ;;
                depends) depends="$value" ;;
                post_install) post_install="$value" ;;
            esac
        fi
    done < "$ini_file"
    
    # Salvar última ferramenta
    if [[ -n "$current_tool" ]]; then
        TOOLS_REGISTRY["$current_tool"]="$url|$script|$depends|$post_install"
        debug "Registrada ferramenta: $current_tool"
    fi
    
    local tool_count="${#TOOLS_REGISTRY[@]}"
    success "Configuração processada: $tool_count ferramentas disponíveis"
    
    # Debug: listar ferramentas carregadas
    if [[ $VERBOSE_MODE -eq 1 ]]; then
        debug "Ferramentas carregadas:"
        for tool in "${!TOOLS_REGISTRY[@]}"; do
            debug "  - $tool"
        done
    fi
}

# ==============================================================================
# FUNÇÕES AUXILIARES PARA DETECÇÃO DE FERRAMENTAS
# ==============================================================================

# Obtém os possíveis nomes de binário para uma ferramenta
binary_names_for_tool() {
    local tool="$1"
    IFS='|' read -r _url script _deps _post <<< "${TOOLS_REGISTRY[$tool]}"
    
    local guess="$tool"
    if [[ -n "$script" ]]; then
        guess="${script##*/}"
        guess="${guess%.*}"
    fi
    
    # Retorna ambos: nome da ferramenta e nome inferido do script
    printf '%s\n' "$tool" "$guess" | sort -u
}

# Verifica se uma ferramenta está instalada
is_installed_tool() {
    local tool="$1"
    local binary
    
    while IFS= read -r binary; do
        if command -v "$binary" >/dev/null 2>&1; then
            return 0
        fi
        if [[ -L "$BIN_DIR/$binary" ]] || [[ -x "$BIN_DIR/$binary" ]]; then
            return 0
        fi
    done < <(binary_names_for_tool "$tool")
    
    return 1
}

# ==============================================================================
# FUNÇÕES DE INSTALAÇÃO DE FERRAMENTAS (MELHORADAS)
# ==============================================================================

install_from_git() {
    local repo_url="$1"
    local script_name="$2"
    local tool_name="$3"
    
    # Extrair nome do repositório
    local repo_name="${repo_url##*/}"
    repo_name="${repo_name%.git}"
    local vendor="${repo_url%/*}"
    vendor="${vendor##*/}"
    
    local install_path="$SRC_DIR/$vendor/$repo_name"
    
    debug "Instalando $tool_name do Git: $repo_url"
    
    # Clone ou update
    if [[ -d "$install_path/.git" ]]; then
        debug "Atualizando repositório existente..."
        if git -C "$install_path" pull -q --all &>>"$LOG_FILE"; then
            debug "Repositório atualizado: $repo_name"
        else
            warning "Falha ao atualizar $repo_name"
            return 1
        fi
    else
        debug "Clonando repositório..."
        mkdir -p "$(dirname "$install_path")"
        if git clone -q "$repo_url" "$install_path" &>>"$LOG_FILE"; then
            debug "Repositório clonado: $repo_name"
        else
            error "Falha ao clonar $repo_name"
            return 1
        fi
    fi
    
    # Instalar dependências Python se existirem
    if [[ -f "$install_path/requirements.txt" ]]; then
        debug "Instalando dependências Python..."
        if pip3 install -q -r "$install_path/requirements.txt" &>>"$LOG_FILE"; then
            debug "Requirements.txt instalado para $tool_name"
        else
            warning "Falha ao instalar requirements.txt para $tool_name"
        fi
    fi
    
    # Instalar via setup.py se existir
    if [[ -f "$install_path/setup.py" ]]; then
        debug "Executando setup.py..."
        if (cd "$install_path" && python3 setup.py -q install) &>>"$LOG_FILE"; then
            debug "Setup.py executado para $tool_name"
        else
            warning "Falha ao executar setup.py para $tool_name"
        fi
    fi
    
    # Criar link simbólico se script especificado
    if [[ -n "$script_name" ]]; then
        local script_path="$install_path/$script_name"
        if [[ -f "$script_path" ]]; then
            chmod +x "$script_path"
            local bin_name="${script_name##*/}"
            bin_name="${bin_name%.*}"
            ln -sf "$script_path" "$BIN_DIR/$bin_name"
            debug "Link criado: $BIN_DIR/$bin_name -> $script_path"
        else
            warning "Script não encontrado: $script_path"
        fi
    fi
    
    return 0
}

# Instalação via Go (melhorada com @latest automático)
install_with_go() {
    local go_package="$1"
    local tool_name="$2"
    
    debug "Instalando $tool_name via Go: $go_package"
    
    export GOPATH="$SRC_DIR/go"
    export GOBIN="$BIN_DIR"
    
    # Adicionar @latest se não tiver versão especificada
    [[ "$go_package" != *@* ]] && go_package="${go_package}@latest"
    
    if install_go_tool_with_retry "$tool_name" "$go_package"; then
        debug "$tool_name instalado via Go"
        validate_installation "$tool_name" "/usr/local/bin/$tool_name"
        return 0
    else
        error "Falha ao instalar $tool_name via Go ($go_package)"
        return 1
    fi
}

# Execução segura de comandos pós-instalação
execute_post_install() {
    local commands="$1"
    local tool_name="$2"
    
    debug "Executando comandos pós-instalação para $tool_name"
    
    # Substituir variáveis
    commands="${commands//\$installdir/$SRC_DIR}"
    commands="${commands//\$bindir/$BIN_DIR}"
    commands="${commands//\$srcdir/$SRC_DIR}"
    
    debug "post_install($tool_name): $commands"
    
    # Executar com shell restrito e modo seguro
    if /usr/bin/env bash -euo pipefail -c "$commands" &>>"$LOG_FILE"; then
        debug "Pós-instalação concluída para $tool_name"
        return 0
    else
        error "Falha no pós-instalação de $tool_name"
        return 1
    fi
}

install_single_tool() {
    local tool_name="$1"
    
    # Verificar se a ferramenta existe no registro
    if [[ -z "${TOOLS_REGISTRY[$tool_name]:-}" ]]; then
        warning "Ferramenta '$tool_name' não encontrada no registro"
        return 1
    fi
    
    # Verificar se já está instalada
    if is_installed_tool "$tool_name"; then
        info "$tool_name já está instalado"
        SKIPPED_TOOLS+=("$tool_name")
        return 0
    fi
    
    info "Instalando $tool_name..."
    
    # Extrair informações da ferramenta
    IFS='|' read -r url script depends post_install <<< "${TOOLS_REGISTRY[$tool_name]}"
    
    local install_success=0
    
    # Instalar dependências primeiro
    if [[ -n "$depends" ]]; then
        debug "Instalando dependências: $depends"
        if apt-get install -y -qq $depends &>>"$LOG_FILE"; then
            debug "Dependências instaladas: $depends"
        else
            warning "Falha ao instalar dependências: $depends"
        fi
    fi
    
    # Instalar a ferramenta
    if [[ -n "$url" ]]; then
        install_from_git "$url" "$script" "$tool_name" && install_success=1
    fi
    
    if [[ -n "$post_install" ]]; then
        # Verificar se é instalação Go
        if [[ "$post_install" =~ go[[:space:]]install ]]; then
            local go_pkg="${post_install#*go install }"
            go_pkg="${go_pkg%% *}"
            install_with_go "$go_pkg" "$tool_name" && install_success=1
        else
            execute_post_install "$post_install" "$tool_name" && install_success=1
        fi
    fi
    
    # Se não tem URL nem post_install, tentar instalar via APT
    if [[ -z "$url" && -z "$post_install" ]]; then
        debug "Tentando instalar $tool_name via APT"
        if apt-get install -y -qq "$tool_name" &>>"$LOG_FILE"; then
            install_success=1
        fi
    fi
    
    if [[ $install_success -eq 1 ]]; then
        TOOLS_STATUS["$tool_name"]="installed"
        INSTALLED_TOOLS+=("$tool_name")
        success "✓ $tool_name instalado com sucesso"
        return 0
    else
        TOOLS_STATUS["$tool_name"]="failed"
        FAILED_TOOLS+=("$tool_name")
        error "✗ Falha ao instalar $tool_name"
        return 1
    fi
}

install_all_tools() {
    info "Iniciando instalação de todas as ferramentas..."
    
    local total="${#TOOLS_REGISTRY[@]}"
    local current=0
    
    for tool in "${!TOOLS_REGISTRY[@]}"; do
        ((current++))
        show_progress "$current" "$total" "Instalando $tool..."
        install_single_tool "$tool" || true  # Continua mesmo se falhar
    done
    
    echo  # Nova linha após progress bar
    print_installation_summary
}

# ==============================================================================
# MENU INTERATIVO
# ==============================================================================

show_main_menu() {
    while true; do
        clear
        print_banner
        
        echo -e "${CYAN}Menu Principal${RESET}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo
        echo -e "  ${GREEN}1)${RESET} Instalar todas as ferramentas"
        echo -e "  ${GREEN}2)${RESET} Instalar ferramentas específicas"
        echo -e "  ${GREEN}3)${RESET} Listar ferramentas disponíveis"
        echo -e "  ${GREEN}4)${RESET} Verificar ferramentas instaladas"
        echo -e "  ${GREEN}5)${RESET} Atualizar ferramentas existentes"
        echo -e "  ${GREEN}6)${RESET} Configurações"
        echo -e "  ${GREEN}7)${RESET} Ver logs"
        echo -e "  ${GREEN}8)${RESET} Sobre"
        echo -e "  ${RED}0)${RESET} Sair"
        echo
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo
        
        read -rp "Escolha uma opção: " choice
        
        case "$choice" in
            1) menu_install_all ;;
            2) menu_install_specific ;;
            3) menu_list_tools ;;
            4) menu_check_installed ;;
            5) menu_update_tools ;;
            6) menu_settings ;;
            7) menu_view_logs ;;
            8) menu_about ;;
            0) exit_script ;;
            *) warning "Opção inválida!" && sleep 2 ;;
        esac
    done
}

menu_install_all() {
    clear
    print_banner
    
    echo -e "${CYAN}Instalação Completa${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    info "Esta operação instalará todas as ${#TOOLS_REGISTRY[@]} ferramentas disponíveis."
    warning "Isso pode levar bastante tempo!"
    echo
    
    read -rp "Deseja continuar? (s/N): " confirm
    if [[ "$confirm" =~ ^[Ss]$ ]]; then
        install_all_tools
        echo
        read -rp "Pressione ENTER para continuar..."
    fi
}

menu_install_specific() {
    clear
    print_banner
    
    echo -e "${CYAN}Instalação Específica${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    
    # Criar array ordenado de ferramentas
    local tools_array=()
    for tool in "${!TOOLS_REGISTRY[@]}"; do
        tools_array+=("$tool")
    done
    IFS=$'\n' sorted_tools=($(sort <<<"${tools_array[*]}"))
    
    # Mostrar ferramentas em colunas
    local cols=3
    local per_col=$(( (${#sorted_tools[@]} + cols - 1) / cols ))
    
    for ((i=0; i<per_col; i++)); do
        for ((j=0; j<cols; j++)); do
            local idx=$((i + j * per_col))
            if [[ $idx -lt ${#sorted_tools[@]} ]]; then
                local tool="${sorted_tools[$idx]}"
                local status=""
                if is_installed_tool "$tool"; then
                    status="${GREEN}✓${RESET}"
                else
                    status="${RED}✗${RESET}"
                fi
                printf "[%b] %-25s" "$status" "$tool"
            fi
        done
        echo
    done
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -rp "Digite o nome da ferramenta (ou 'voltar'): " tool_name
    
    if [[ "$tool_name" == "voltar" ]]; then
        return
    fi
    
    tool_name="${tool_name,,}"  # Converter para minúsculas
    
    if [[ -n "${TOOLS_REGISTRY[$tool_name]:-}" ]]; then
        install_single_tool "$tool_name"
        echo
        read -rp "Pressione ENTER para continuar..."
    else
        error "Ferramenta '$tool_name' não encontrada!"
        sleep 2
    fi
}

menu_list_tools() {
    clear
    print_banner
    
    echo -e "${CYAN}Ferramentas Disponíveis${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    
    local count=0
    local installed_count=0
    
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        ((count++))
        
        # Verificar se está instalada usando a função melhorada
        local status="${RED}✗${RESET}"
        if is_installed_tool "$tool"; then
            status="${GREEN}✓${RESET}"
            ((installed_count++))
        fi
        
        printf "%3d. [%b] %-20s" "$count" "$status" "$tool"
        
        # Adicionar quebra de linha a cada 3 itens
        if [[ $((count % 3)) -eq 0 ]]; then
            echo
        fi
    done
    
    [[ $((count % 3)) -ne 0 ]] && echo
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "Total: ${GREEN}$count${RESET} ferramentas | Instaladas: ${GREEN}$installed_count${RESET}"
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_check_installed() {
    clear
    print_banner
    
    echo -e "${CYAN}Verificando Ferramentas Instaladas${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    
    local installed_count=0
    local not_installed_count=0
    
    echo -e "${GREEN}Instaladas:${RESET}"
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        if is_installed_tool "$tool"; then
            # Mostrar os binários encontrados
            local binaries=$(binary_names_for_tool "$tool" | tr '\n' ', ' | sed 's/, $//')
            echo "  ✓ $tool [$binaries]"
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
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "Resumo: ${GREEN}$installed_count instaladas${RESET} | ${RED}$not_installed_count não instaladas${RESET}"
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_update_tools() {
    clear
    print_banner
    
    echo -e "${CYAN}Atualizar Ferramentas${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    info "Verificando atualizações para ferramentas Git..."
    echo
    
    local updated=0
    local failed=0
    
    # Usar find para buscar repositórios Git
    while IFS= read -r -d '' git_dir; do
        local repo_dir="${git_dir%/.git}"
        local repo_name="${repo_dir##*/}"
        
        echo -n "Atualizando $repo_name... "
        
        if git -C "$repo_dir" pull -q --all &>>"$LOG_FILE"; then
            echo -e "${GREEN}✓${RESET}"
            ((updated++))
        else
            echo -e "${RED}✗${RESET}"
            ((failed++))
        fi
    done < <(find "$SRC_DIR" -type d -name .git -print0 2>/dev/null)
    
    if [[ $((updated + failed)) -eq 0 ]]; then
        warning "Nenhum repositório Git encontrado"
    else
        echo
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "Resultado: ${GREEN}$updated atualizadas${RESET} | ${RED}$failed falharam${RESET}"
    fi
    
    echo
    read -rp "Pressione ENTER para continuar..."
}

menu_about() {
    clear
    print_banner
    
    echo -e "${CYAN}Sobre o SecBuild${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo -e "${GREEN}SecBuild v$SCRIPT_VERSION${RESET}"
    echo
    echo "Ferramenta robusta e otimizada para instalação automatizada"
    echo "de ferramentas de segurança e pentesting."
    echo
    echo -e "${CYAN}Características:${RESET}"
    echo "  • Instalação automatizada de 100+ ferramentas"
    echo "  • Otimizado para Kali Linux e Ubuntu"
    echo "  • Detecção inteligente de ferramentas instaladas"
    echo "  • Gerenciamento avançado de dependências"
    echo "  • Sistema de logs detalhado"
    echo "  • Tratamento robusto de erros"
    echo "  • Interface interativa amigável"
    echo
    echo -e "${CYAN}Compatibilidade:${RESET}"
    echo "  • Kali Linux (todas as versões)"
    echo "  • Ubuntu 20.04+"
    echo "  • Debian 10+"
    echo
    echo -e "${CYAN}Diretórios:${RESET}"
    echo "  • Trabalho: $WORK_DIR"
    echo "  • Fontes:   $SRC_DIR"
    echo "  • Binários: $BIN_DIR"
    echo "  • Logs:     $LOG_DIR"
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -rp "Pressione ENTER para continuar..."
}

# ==============================================================================
# FUNÇÕES AUXILIARES
# ==============================================================================

print_installation_summary() {
    echo
    echo -e "${CYAN}Resumo da Instalação${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    if [[ ${#INSTALLED_TOOLS[@]} -gt 0 ]]; then
        echo -e "${GREEN}Instaladas com sucesso (${#INSTALLED_TOOLS[@]}):${RESET}"
        for tool in "${INSTALLED_TOOLS[@]}"; do
            echo "  ✓ $tool"
        done
    fi
    
    if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
        echo
        echo -e "${RED}Falharam (${#FAILED_TOOLS[@]}):${RESET}"
        for tool in "${FAILED_TOOLS[@]}"; do
            echo "  ✗ $tool"
        done
    fi
    
    if [[ ${#SKIPPED_TOOLS[@]} -gt 0 ]]; then
        echo
        echo -e "${YELLOW}Puladas/Já instaladas (${#SKIPPED_TOOLS[@]}):${RESET}"
        for tool in "${SKIPPED_TOOLS[@]}"; do
            echo "  ⊘ $tool"
        done
    fi
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    local total=$((${#INSTALLED_TOOLS[@]} + ${#FAILED_TOOLS[@]} + ${#SKIPPED_TOOLS[@]}))
    local success_rate=0
    if [[ $total -gt 0 ]]; then
        success_rate=$(( (${#INSTALLED_TOOLS[@]} + ${#SKIPPED_TOOLS[@]}) * 100 / total ))
    fi
    
    echo -e "Taxa de sucesso: ${GREEN}${success_rate}%${RESET}"
    
    if [[ ${#FAILED_TOOLS[@]} -gt 0 ]]; then
        echo
        warning "Verifique o log para mais detalhes sobre as falhas:"
        warning "$ERROR_LOG"
    fi
}

menu_view_logs() {
    clear
    print_banner
    
    echo -e "${CYAN}Visualizar Logs${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo "  1) Log completo"
    echo "  2) Log de erros"
    echo "  3) Últimas 50 linhas do log"
    echo "  4) Listar todos os logs"
    echo "  5) Limpar logs antigos"
    echo "  6) Voltar"
    echo
    
    read -rp "Escolha uma opção: " choice
    
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
            warning "Opção inválida!"
            sleep 2
            ;;
    esac
}

menu_settings() {
    clear
    print_banner
    
    echo -e "${CYAN}Configurações${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo "  1) Modo verbose: $([ $VERBOSE_MODE -eq 1 ] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
    echo "  2) Modo silencioso: $([ $SILENT_MODE -eq 1 ] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
    echo "  3) Atualizar lista de ferramentas"
    echo "  4) Forçar reinstalação de dependências"
    echo "  5) Resetar configurações"
    echo "  6) Voltar"
    echo
    
    read -rp "Escolha uma opção: " choice
    
    case "$choice" in
        1) 
            VERBOSE_MODE=$((1 - VERBOSE_MODE))
            success "Modo verbose: $([ $VERBOSE_MODE -eq 1 ] && echo "ativado" || echo "desativado")"
            sleep 1
            ;;
        2) 
            SILENT_MODE=$((1 - SILENT_MODE))
            success "Modo silencioso: $([ $SILENT_MODE -eq 1 ] && echo "ativado" || echo "desativado")"
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
            warning "Opção inválida!"
            sleep 2
            ;;
    esac
    
    # Salvar configurações
    save_config
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# SecBuild Configuration File
# Generated: $(date)

VERBOSE_MODE=$VERBOSE_MODE
SILENT_MODE=$SILENT_MODE
FORCE_UPDATE=$FORCE_UPDATE
EOF
    debug "Configurações salvas em $CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        debug "Configurações carregadas de $CONFIG_FILE"
    fi
}

exit_script() {
    echo
    info "Encerrando SecBuild..."
    
    # Limpar arquivos temporários
    rm -f /tmp/secbuild_* 2>/dev/null
    
    # Salvar estatísticas se houver
    if [[ ${#INSTALLED_TOOLS[@]} -gt 0 || ${#FAILED_TOOLS[@]} -gt 0 || ${#SKIPPED_TOOLS[@]} -gt 0 ]]; then
        print_installation_summary
    fi
    
    success "SecBuild encerrado com sucesso!"
    exit 0
}

# ==============================================================================
# FUNÇÃO PRINCIPAL
# ==============================================================================

main() {
    # Configurar cores
    setup_colors

    # Criar diretórios e configurar PATH
    create_directories
    
    # Verificar root
    check_root
    
    # Detectar sistema (apenas Kali/Ubuntu)
    detect_system
    
    # Carregar configurações se existirem
    load_config
    
    # Parse argumentos da linha de comando
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE_MODE=1
                shift
                ;;
            -f|--force)
                FORCE_UPDATE=1
                shift
                ;;
            -s|--silent)
                SILENT_MODE=1
                INTERACTIVE_MODE=0
                shift
                ;;
            -l|--list)
                # Garantir que temos o package.ini
                if [[ ! -f "$CONFIG_DIR/package.ini" ]]; then
                    download_package_ini
                fi
                parse_package_ini
                menu_list_tools
                exit 0
                ;;
            -i|--install)
                shift
                if [[ -n "${1:-}" ]]; then
                    INTERACTIVE_MODE=0
                    # Garantir que temos o package.ini
                    if [[ ! -f "$CONFIG_DIR/package.ini" ]]; then
                        download_package_ini
                    fi
                    parse_package_ini
                    install_single_tool "$1"
                    exit $?
                else
                    error "Nome da ferramenta necessário para -i/--install"
                    exit 1
                fi
                ;;
            -u|--update)
                INTERACTIVE_MODE=0
                info "Atualizando todas as ferramentas instaladas..."
                menu_update_tools
                exit 0
                ;;
            *)
                warning "Argumento desconhecido: $1"
                shift
                ;;
        esac
    done
    
    # Modo não-interativo
    if [[ $INTERACTIVE_MODE -eq 0 ]]; then
        info "Executando em modo não-interativo"
        
        # Verificar e instalar dependências se necessário
        if [[ ! -f "$DEPS_LOCK" ]] || [[ $FORCE_UPDATE -eq 1 ]]; then
            install_core_dependencies
            install_vendor_tools
            touch "$DEPS_LOCK"
        fi
        
        # Baixar e processar package.ini
        download_package_ini
        parse_package_ini
        
        # Se não foi especificada ação, instalar tudo
        if [[ ${#INSTALLED_TOOLS[@]} -eq 0 && ${#FAILED_TOOLS[@]} -eq 0 ]]; then
            install_all_tools
        fi
        
        exit 0
    fi
    
    # Modo interativo
    print_banner
    info "Iniciando SecBuild v$SCRIPT_VERSION"
    
    # Verificar e instalar dependências se necessário
    if [[ ! -f "$DEPS_LOCK" ]] || [[ $FORCE_UPDATE -eq 1 ]]; then
        install_core_dependencies
        install_vendor_tools
        touch "$DEPS_LOCK"
    fi
    
    # Baixar e processar package.ini
    if [[ ! -f "$CONFIG_DIR/package.ini" ]]; then
        download_package_ini
    fi
    parse_package_ini
    
    # Mostrar menu principal
    show_main_menu
}

show_usage() {
    cat <<EOF
${CYAN}SecBuild v$SCRIPT_VERSION${RESET}
${BLUE}Advanced Security Tools Installer for Kali/Ubuntu${RESET}

${GREEN}Uso:${RESET}
  sudo $SCRIPT_NAME [OPÇÕES]

${GREEN}Opções:${RESET}
  -h, --help          Mostrar esta ajuda
  -v, --verbose       Modo verboso (debug)
  -f, --force         Forçar atualização de dependências
  -s, --silent        Modo silencioso (não-interativo)
  -l, --list          Listar ferramentas disponíveis
  -i, --install TOOL  Instalar ferramenta específica
  -u, --update        Atualizar todas as ferramentas instaladas

${GREEN}Exemplos:${RESET}
  sudo $SCRIPT_NAME                    # Modo interativo
  sudo $SCRIPT_NAME -i nmap            # Instalar ferramenta específica
  sudo $SCRIPT_NAME -l                 # Listar ferramentas
  sudo $SCRIPT_NAME -u                 # Atualizar ferramentas
  sudo $SCRIPT_NAME -f -s              # Reinstalação forçada silenciosa

${GREEN}Diretórios:${RESET}
  Trabalho:  $WORK_DIR
  Fontes:    $SRC_DIR
  Binários:  $BIN_DIR
  Logs:      $LOG_DIR

${GREEN}Compatibilidade:${RESET}
  • Kali Linux (todas as versões)
  • Ubuntu 20.04+
  • Debian 10+

${CYAN}Mais informações:${RESET}
  https://github.com/DonatoReis/Secbuild

EOF
}

# ==============================================================================
# EXECUÇÃO
# ==============================================================================

# Executar apenas se não estiver sendo sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

# Função para validar instalação de ferramenta
validate_installation() {
    local tool_name="$1"
    local expected_path="${2:-/usr/local/bin/$tool_name}"
    
    # Verificar se o binário existe no caminho esperado
    if [[ -f "$expected_path" ]] || command -v "$tool_name" &>/dev/null; then
        return 0
    fi
    
    # Verificar em caminhos comuns
    local common_paths=(
        "/usr/local/bin"
        "$HOME/go/bin"
        "/root/go/bin"
        "$HOME/.local/bin"
        "/opt/$tool_name"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -f "$path/$tool_name" ]]; then
            # Criar link simbólico se encontrado
            ln -sf "$path/$tool_name" "/usr/local/bin/$tool_name" 2>/dev/null && return 0
        fi
    done
    
    return 1
}
