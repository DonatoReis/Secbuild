#!/usr/bin/env bash
################################################################################
# logging.sh - Sistema de Logging Avançado
# Fornece funções para logging estruturado com níveis e cores
################################################################################

# Inicializar sistema de logging
init_logging() {
    # Garantir que diretório de logs existe
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Criar arquivos de log se não existirem
    : > "$LOG_FILE" 2>/dev/null || true
    : > "$ERROR_LOG" 2>/dev/null || true
}

# Função principal de logging
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Garantir que os caminhos existem antes de gravar
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
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

# Funções de conveniência
error() { 
    # Verificar se traduções estão disponíveis e função t existe
    set +u
    local has_i18n=0
    local array_size=0
    
    # Verificar tamanho do array de forma segura
    if [[ -v I18N_STRINGS[@] ]] 2>/dev/null; then
        array_size=${#I18N_STRINGS[@]}
    fi
    
    if command -v t &>/dev/null && [[ $array_size -gt 0 ]]; then
        has_i18n=1
    fi
    set -u
    
    if [[ $has_i18n -eq 1 ]]; then
        log "ERROR" "$(t "$@")"
    else
        log "ERROR" "$*"
    fi
}

success() { 
    set +u
    local has_i18n=0
    local array_size=0
    
    if [[ -v I18N_STRINGS[@] ]] 2>/dev/null; then
        array_size=${#I18N_STRINGS[@]}
    fi
    
    if command -v t &>/dev/null && [[ $array_size -gt 0 ]]; then
        has_i18n=1
    fi
    set -u
    
    if [[ $has_i18n -eq 1 ]]; then
        log "SUCCESS" "$(t "$@")"
    else
        log "SUCCESS" "$*"
    fi
}

warning() { 
    set +u
    local has_i18n=0
    local array_size=0
    
    if [[ -v I18N_STRINGS[@] ]] 2>/dev/null; then
        array_size=${#I18N_STRINGS[@]}
    fi
    
    if command -v t &>/dev/null && [[ $array_size -gt 0 ]]; then
        has_i18n=1
    fi
    set -u
    
    if [[ $has_i18n -eq 1 ]]; then
        log "WARNING" "$(t "$@")"
    else
        log "WARNING" "$*"
    fi
}

info() { 
    set +u
    local has_i18n=0
    local array_size=0
    
    if [[ -v I18N_STRINGS[@] ]] 2>/dev/null; then
        array_size=${#I18N_STRINGS[@]}
    fi
    
    if command -v t &>/dev/null && [[ $array_size -gt 0 ]]; then
        has_i18n=1
    fi
    set -u
    
    if [[ $has_i18n -eq 1 ]]; then
        log "INFO" "$(t "$@")"
    else
        log "INFO" "$*"
    fi
}

debug() { 
    set +u
    local has_i18n=0
    local array_size=0
    
    if [[ -v I18N_STRINGS[@] ]] 2>/dev/null; then
        array_size=${#I18N_STRINGS[@]}
    fi
    
    if command -v t &>/dev/null && [[ $array_size -gt 0 ]]; then
        has_i18n=1
    fi
    set -u
    
    if [[ $has_i18n -eq 1 ]]; then
        log "DEBUG" "$(t "$@")"
    else
        log "DEBUG" "$*"
    fi
}

