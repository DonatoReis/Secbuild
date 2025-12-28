#!/usr/bin/env bash
################################################################################
# system.sh - Detecção e Configuração do Sistema
# Gerencia detecção de OS, criação de diretórios, verificação de root
################################################################################

# Detectar sistema operacional
detect_system() {
    info "sys.detecting"
    
    # Verificar se é Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        warning "sys.incompatible"
        warning "sys.detected" "$OSTYPE"
        
        # No macOS, permitir modo de teste (não instalar, apenas listar)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            warning "Este script foi projetado para Linux (Kali/Ubuntu)"
            warning "No macOS, apenas funcionalidades de listagem funcionam"
            warning "Instalação de ferramentas requer Linux"
            
            # Definir variáveis para modo de teste
            DISTRO="darwin"
            PKG_MANAGER="none"
            
            # Não sair, apenas avisar
            return 0
        fi
        
        # Para outros sistemas não-Linux, sair
        error "Sistema não suportado: $OSTYPE"
        exit 1
    fi
    
    # Detectar distribuição Linux
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="${ID:-unknown}"
        debug "sys.detected" "$DISTRO"
        
        # Verificar compatibilidade
        case "$DISTRO" in
            kali|ubuntu|debian)
                success "sys.compatible" "$DISTRO"
                ;;
            *)
                warning "sys.incompatible" "$DISTRO"
                if [[ $INTERACTIVE_MODE -eq 1 ]]; then
                    read -p "$(t 'sys.continue' 'Deseja continuar mesmo assim? (s/N): ')" -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
                        exit 1
                    fi
                fi
                ;;
        esac
    else
        error "sys.detection_failed"
        exit 1
    fi
    
    # Detectar gerenciador de pacotes
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        debug "sys.pkg_manager" "APT"
    else
        # No macOS, não há apt-get, mas não é erro fatal se for modo de teste
        if [[ "$DISTRO" == "darwin" ]]; then
            PKG_MANAGER="none"
            warning "APT não disponível no macOS (modo de teste)"
        else
            error "sys.apt_not_found"
            exit 1
        fi
    fi
    
    success "sys.system" "$DISTRO" "$PKG_MANAGER"
}

# Verificar se está executando como root
check_root() {
    # No macOS, permitir comandos de listagem sem root
    if [[ "${OSTYPE:-}" == "darwin"* ]]; then
        # Verificar argumentos passados para ver se é comando de listagem
        local is_list_cmd=0
        for arg in "$@"; do
            if [[ "$arg" == "-l" ]] || [[ "$arg" == "--list" ]] || [[ "$arg" == "--list-profiles" ]] || [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
                is_list_cmd=1
                break
            fi
        done
        
        if [[ $is_list_cmd -eq 1 ]]; then
            # Comandos de listagem não precisam de root
            return 0
        fi
    fi
    
    if [[ $EUID -ne 0 ]]; then
        error "root.required"
        info "root.usage" "$SCRIPT_NAME"
        exit 1
    fi
}

# Criar estrutura de diretórios
create_directories() {
    info "dir.creating"
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
                error "dir.failed" "$dir"
                exit 1
            }
            debug "dir.created" "$dir"
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
    
    success "dir.structure"
}

# Configurar cores do terminal
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

