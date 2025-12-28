#!/usr/bin/env bash
################################################################################
# system.sh - System Detection and Configuration
# Manages OS detection, directory creation, root verification
################################################################################

# Detect operating system
detect_system() {
    [[ $VERBOSE_MODE -eq 1 ]] && info "Detecting operating system..."
    
    # Check if it's Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        warning "This script only supports Linux systems (Kali/Ubuntu)"
        warning "System detected: $OSTYPE"
        
        # On macOS, allow test mode (no installation, list only)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            warning "This script is designed for Linux (Kali/Ubuntu)"
            warning "On macOS, only listing features work"
            warning "Tool installation requires Linux"
            
            # Set variables for test mode
            DISTRO="darwin"
            PKG_MANAGER="none"
            
            # Don't exit, just warn
            return 0
        fi
        
        # For other non-Linux systems, exit
        error "Unsupported system: $OSTYPE"
        exit 1
    fi
    
    # Detect Linux distribution
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="${ID:-unknown}"
        debug "System detected: $DISTRO"
        
        # Check compatibility
        case "$DISTRO" in
            kali|ubuntu|debian)
                [[ $VERBOSE_MODE -eq 1 ]] && success "Compatible system detected: $DISTRO"
                ;;
            *)
                warning "This script only supports Linux systems (Kali/Ubuntu)"
                if [[ $INTERACTIVE_MODE -eq 1 ]]; then
                    read -p "Do you want to continue anyway? (y/N): " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[YySs]$ ]]; then
                        exit 1
                    fi
                fi
                ;;
        esac
    else
        error "Could not detect Linux distribution"
        exit 1
    fi
    
    # Detect package manager
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        debug "Package manager: APT"
    else
        # On macOS, there's no apt-get, but it's not a fatal error if in test mode
        if [[ "$DISTRO" == "darwin" ]]; then
            PKG_MANAGER="none"
            warning "APT not available on macOS (test mode)"
        else
            error "APT not found. This script requires APT (Kali/Ubuntu)"
            exit 1
        fi
    fi
    
    [[ $VERBOSE_MODE -eq 1 ]] && success "System: $DISTRO | Manager: $PKG_MANAGER"
}

# Check if running as root
check_root() {
    # On macOS, allow listing commands without root
    if [[ "${OSTYPE:-}" == "darwin"* ]]; then
        # Check passed arguments to see if it's a listing command
        local is_list_cmd=0
        for arg in "$@"; do
            if [[ "$arg" == "-l" ]] || [[ "$arg" == "--list" ]] || [[ "$arg" == "--list-profiles" ]] || [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
                is_list_cmd=1
                break
            fi
        done
        
        if [[ $is_list_cmd -eq 1 ]]; then
            # Listing commands don't need root
            return 0
        fi
    fi
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root!"
        info "Use: sudo $SCRIPT_NAME"
        exit 1
    fi
}

# Create directory structure
create_directories() {
    [[ $VERBOSE_MODE -eq 1 ]] && info "Creating directory structure..."
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
                error "Failed to create directory: $dir"
                exit 1
            }
            debug "Directory created: $dir"
        fi
    done
    
    # Ensure BIN_DIR is in PATH
    case ":$PATH:" in
        *":$BIN_DIR:"*) 
            debug "BIN_DIR is already in PATH"
            ;;
        *) 
            export PATH="$BIN_DIR:$PATH"
            debug "BIN_DIR added to PATH"
            ;;
    esac
    
    [[ $VERBOSE_MODE -eq 1 ]] && success "Directory structure created"
}

# Configure terminal colors
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

