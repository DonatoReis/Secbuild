#!/usr/bin/env bash
################################################################################
# logging.sh - Advanced Logging System
# Provides functions for structured logging with levels and colors
# Supports inline mode for progress bar integration
################################################################################

# Variável global para armazenar mensagem de status atual (modo inline)
CURRENT_STATUS_MESSAGE=""

# Main logging function with inline mode support
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local inline_mode="${INLINE_MODE:-0}"  # Flag para modo inline
    
    # Ensure paths exist before writing
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Log to file (sempre)
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Specific error log
    [[ "$level" == "ERROR" ]] && echo "[$timestamp] $message" >> "$ERROR_LOG"
    
    # Output to terminal (if not silent)
    if [[ $SILENT_MODE -eq 0 ]]; then
        # Se modo inline está ativo, não imprime linha nova (exceto erros críticos)
        if [[ $inline_mode -eq 1 ]] && [[ "$level" != "ERROR" ]] && [[ "$level" != "STATUS" ]]; then
            # Apenas atualiza status para mostrar na barra
            CURRENT_STATUS_MESSAGE="$message"
            return 0
        fi
        
        case "$level" in
            ERROR)   
                # Erros sempre aparecem
                if [[ $inline_mode -eq 1 ]]; then
                    CURRENT_STATUS_MESSAGE="${RED}[✗]${RESET} $message"
                else
                    echo -e "${RED}[✗]${RESET} $message" >&2
                fi
                ;;
            SUCCESS) 
                if [[ $inline_mode -eq 1 ]]; then
                    CURRENT_STATUS_MESSAGE="${GREEN}[✓]${RESET} $message"
                else
                    echo -e "${GREEN}[✓]${RESET} $message"
                fi
                ;;
            WARNING) 
                if [[ $inline_mode -eq 1 ]]; then
                    CURRENT_STATUS_MESSAGE="${YELLOW}[!]${RESET} $message"
                else
                    echo -e "${YELLOW}[!]${RESET} $message"
                fi
                ;;
            INFO)    
                if [[ $inline_mode -eq 1 ]]; then
                    CURRENT_STATUS_MESSAGE="${BLUE}[i]${RESET} $message"
                else
                    echo -e "${BLUE}[i]${RESET} $message"
                fi
                ;;
            DEBUG)   
                # Debug apenas com -v
                [[ $VERBOSE_MODE -eq 1 ]] && {
                    if [[ $inline_mode -eq 1 ]]; then
                        CURRENT_STATUS_MESSAGE="${CYAN}[D]${RESET} $message"
                    else
                        echo -e "${CYAN}[D]${RESET} $message"
                    fi
                }
                ;;
            STATUS)  
                # Status messages vão direto para a barra (não logam no terminal)
                CURRENT_STATUS_MESSAGE="$message"
                ;;
            *)       
                if [[ $inline_mode -eq 1 ]]; then
                    CURRENT_STATUS_MESSAGE="$message"
                else
                    echo "$message"
                fi
                ;;
        esac
    fi
}

# Convenience functions (modo normal)
error() { 
    log "ERROR" "$*"
}

success() { 
    log "SUCCESS" "$*"
}

warning() { 
    log "WARNING" "$*"
}

info() { 
    log "INFO" "$*"
}

debug() { 
    # Debug apenas com -v
    [[ ${VERBOSE_MODE:-0} -eq 1 ]] && log "DEBUG" "$*" || true
}

# Funções para modo inline (integração com barra de progresso)
status_inline() {
    local message="$*"
    CURRENT_STATUS_MESSAGE="$message"
    # Loga no arquivo mas não imprime no terminal
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "[$timestamp] [STATUS] $message" >> "$LOG_FILE"
}

info_inline() {
    INLINE_MODE=1 log "INFO" "$*"
}

success_inline() {
    INLINE_MODE=1 log "SUCCESS" "$*"
}

warning_inline() {
    INLINE_MODE=1 log "WARNING" "$*"
}

error_inline() {
    INLINE_MODE=1 log "ERROR" "$*"
}

# Função para limpar mensagem de status
clear_status() {
    CURRENT_STATUS_MESSAGE=""
}
