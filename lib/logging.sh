#!/usr/bin/env bash
################################################################################
# logging.sh - Advanced Logging System
# Provides functions for structured logging with levels and colors
################################################################################

# Initialize logging system
init_logging() {
    # Ensure log directory exists
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Create log files if they don't exist
    : > "$LOG_FILE" 2>/dev/null || true
    : > "$ERROR_LOG" 2>/dev/null || true
}

# Main logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Ensure paths exist before writing
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Specific error log
    [[ "$level" == "ERROR" ]] && echo "[$timestamp] $message" >> "$ERROR_LOG"
    
    # Output to terminal (if not silent)
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

# Convenience functions
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
    log "DEBUG" "$*"
}
