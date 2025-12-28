#!/usr/bin/env bash
################################################################################
# config.sh - Gerenciamento de Configuração
# Carrega e processa package.ini, tools_config.yaml
################################################################################

# Download do package.ini
download_package_ini() {
    local ini_file="$CONFIG_DIR/package.ini"
    
    [[ $VERBOSE_MODE -eq 1 ]] && info "Downloading tools configuration file..."
    
    # Force update if FORCE_UPDATE is set
    if [[ ${FORCE_UPDATE:-0} -eq 1 ]] && [[ -f "$ini_file" ]]; then
        local backup_file="$BACKUP_DIR/package.ini.$(date +%Y%m%d_%H%M%S)"
        cp "$ini_file" "$backup_file" 2>/dev/null || true
        debug "Backup created: $backup_file"
        rm -f "$ini_file"
    elif [[ -f "$ini_file" ]]; then
        local backup_file="$BACKUP_DIR/package.ini.$(date +%Y%m%d_%H%M%S)"
        cp "$ini_file" "$backup_file" 2>/dev/null || true
        debug "Backup created: $backup_file"
    fi
    
    # First try to copy local file (always update if exists)
    if [[ -f "$SCRIPT_DIR/package-dist.ini" ]]; then
        # Always copy local file to ensure it's up to date
        # This ensures profiles and other updates are applied
        cp -f "$SCRIPT_DIR/package-dist.ini" "$ini_file" 2>/dev/null || {
            sudo cp -f "$SCRIPT_DIR/package-dist.ini" "$ini_file" 2>/dev/null || {
                error "Failed to copy package-dist.ini to $ini_file"
                return 1
            }
        }
        [[ $VERBOSE_MODE -eq 1 ]] && success "Configuration file copied locally"
    else
        # Download from repository with retry
        local attempt=1
        while [[ $attempt -le $RETRY_COUNT ]]; do
            if wget -q -O "$ini_file" --timeout="$DOWNLOAD_TIMEOUT" "$PACKAGE_INI_URL"; then
                [[ $VERBOSE_MODE -eq 1 ]] && success "Configuration file downloaded"
                break
            else
                warning "Attempt $attempt/$RETRY_COUNT failed"
                ((attempt++))
                [[ $attempt -le $RETRY_COUNT ]] && sleep "$RETRY_DELAY"
            fi
        done
        
        if [[ $attempt -gt $RETRY_COUNT ]]; then
            error "Failed to download configuration file after $RETRY_COUNT attempts"
            return 1
        fi
    fi
    
    [[ -r "$ini_file" ]] || {
        error "Configuration file not found or not readable"
        return 1
    }
    
    # Validate downloaded file (structure)
    if ! validate_package_ini "$ini_file"; then
        error "Invalid configuration file. Check errors above."
        return 1
    fi
    
    # Check basic integrity (minimum size and structure)
    local file_size
    file_size=$(stat -f%z "$ini_file" 2>/dev/null || stat -c%s "$ini_file" 2>/dev/null || echo "0")
    
    if [[ $file_size -lt 100 ]]; then
        error "package.ini file appears to be corrupted (too small: ${file_size} bytes)"
        return 1
    fi
    
    # Check if it has at least one valid section
    if ! grep -q "^\[" "$ini_file" 2>/dev/null; then
        error "package.ini file does not contain valid sections"
        return 1
    fi
    
    debug "Basic integrity of package.ini verified (${file_size} bytes)"
}

# Parse do package.ini
parse_package_ini() {
    local ini_file="$CONFIG_DIR/package.ini"
    
    [[ $VERBOSE_MODE -eq 1 ]] && info "Processing tools configuration..."
    
    if [[ ! -f "$ini_file" ]]; then
        error "package.ini file not found"
        return 1
    fi
    
    # Clear previous registry
    TOOLS_REGISTRY=()
    TOOLS_PROFILES=()
    PROFILE_TOOLS=()
    
    # Manual parse of INI file
    local current_tool=""
    local url=""
    local script=""
    local depends=""
    local post_install=""
    
    while IFS= read -r line; do
        # Remove whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip empty lines and comments (# or ;)
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*[\#\;] ]] && continue
        
        # New section (tool)
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            # Save previous tool if exists
            if [[ -n "$current_tool" ]]; then
                TOOLS_REGISTRY["$current_tool"]="$url|$script|$depends|$post_install"
                # Removed verbose "Tool registered" messages for cleaner output
            fi
            
            # Start new tool
            current_tool="${BASH_REMATCH[1],,}"  # Convert to lowercase
            url=""
            script=""
            depends=""
            post_install=""
            
        # Process attributes (key=value or key = value)
        elif [[ "$line" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Remove extra spaces
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            # Remove quotes if present
            value="${value#\'}"
            value="${value%\'}"
            value="${value#\"}"
            value="${value%\"}"
            
            case "$key" in
                url) url="$value" ;;
                script) script="$value" ;;
                depends) depends="$value" ;;
                post_install) post_install="$value" ;;
                profile) 
                    # Process profiles (comma-separated)
                    local profile_value="$value"
                    IFS=',' read -ra profiles <<< "$profile_value"
                    for profile in "${profiles[@]}"; do
                        profile="${profile#"${profile%%[![:space:]]*}"}"
                        profile="${profile%"${profile##*[![:space:]]}"}"
                        profile="${profile,,}"
                        
                        if [[ -n "$profile" ]]; then
                            if [[ -z "${TOOLS_PROFILES[$current_tool]:-}" ]]; then
                                TOOLS_PROFILES["$current_tool"]="$profile"
                            else
                                TOOLS_PROFILES["$current_tool"]="${TOOLS_PROFILES[$current_tool]} $profile"
                            fi
                            
                            if [[ -z "${PROFILE_TOOLS[$profile]:-}" ]]; then
                                PROFILE_TOOLS["$profile"]="$current_tool"
                            else
                                PROFILE_TOOLS["$profile"]="${PROFILE_TOOLS[$profile]} $current_tool"
                            fi
                        fi
                    done
                    ;;
            esac
        fi
    done < "$ini_file"
    
    # Save last tool
    if [[ -n "$current_tool" ]]; then
        TOOLS_REGISTRY["$current_tool"]="$url|$script|$depends|$post_install"
        # Removed verbose "Tool registered" messages for cleaner output
    fi
    
    local tool_count="${#TOOLS_REGISTRY[@]}"
    [[ $VERBOSE_MODE -eq 1 ]] && success "Configuration processed: $tool_count tools available"
    
    # Debug: list loaded tools in columns
    if [[ $VERBOSE_MODE -eq 1 ]]; then
        debug "Loaded tools:"
        local count=0
        local tools_sorted
        tools_sorted=$(printf '%s\n' "${!TOOLS_REGISTRY[@]}" | sort)
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            printf "  %-25s" "$tool"
            ((count++))
            [[ $((count % 3)) -eq 0 ]] && echo
        done <<< "$tools_sorted"
        [[ $((count % 3)) -ne 0 ]] && echo
    fi
}

# Arrays globais para pacotes do YAML
declare -a YAML_ESSENTIAL_PACKAGES
declare -a YAML_SECURITY_TOOLS

# Carregar tools_config.yaml e retornar pacotes essenciais
load_tools_config_yaml() {
    local yaml_file="$SCRIPT_DIR/tools_config.yaml"
    
    if [[ ! -f "$yaml_file" ]]; then
        debug "tools_config.yaml Not found, jumping"
        return 0
    fi
    
    [[ $VERBOSE_MODE -eq 1 ]] && info "Loading configuration from tools_config.yaml..."
    
    # Check if yq is available
    if ! command -v yq &>/dev/null && ! command -v python3 &>/dev/null; then
        warning "yq or python3 not found, skipping tools_config.yaml"
        return 0
    fi
    
    # Clear arrays
    YAML_ESSENTIAL_PACKAGES=()
    YAML_SECURITY_TOOLS=()
    
    # Try yq first
    if command -v yq &>/dev/null; then
        # Load essential packages
        while IFS= read -r package; do
            [[ -n "$package" ]] && YAML_ESSENTIAL_PACKAGES+=("$package")
        done < <(yq eval '.system_packages.essential[]' "$yaml_file" 2>/dev/null)
        
        # Load security tools
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && YAML_SECURITY_TOOLS+=("$tool")
        done < <(yq eval '.system_packages.security_tools[]?' "$yaml_file" 2>/dev/null)
        
        if [[ ${#YAML_ESSENTIAL_PACKAGES[@]} -gt 0 ]]; then
            debug "Essential packages from YAML loaded: ${#YAML_ESSENTIAL_PACKAGES[@]} packages"
        fi
        
        if [[ ${#YAML_SECURITY_TOOLS[@]} -gt 0 ]]; then
            debug "Security tools from YAML loaded: ${#YAML_SECURITY_TOOLS[@]} tools"
        fi
    elif command -v python3 &>/dev/null; then
        # Fallback to Python (basic parse)
        debug "Using Python for basic YAML parsing"
        # Basic Python implementation would be here if needed
    fi
    
    [[ $VERBOSE_MODE -eq 1 ]] && success "YAML configuration loaded"
    return 0
}

# Get essential packages from YAML
get_yaml_essential_packages() {
    echo "${YAML_ESSENTIAL_PACKAGES[@]}"
}

# Get security tools from YAML
get_yaml_security_tools() {
    echo "${YAML_SECURITY_TOOLS[@]}"
}

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" <<EOF
# SecBuild Configuration File
# Generated: $(date)

VERBOSE_MODE=$VERBOSE_MODE
SILENT_MODE=$SILENT_MODE
FORCE_UPDATE=$FORCE_UPDATE
DRY_RUN=$DRY_RUN
PARALLEL_INSTALL=$PARALLEL_INSTALL
MAX_PARALLEL_JOBS=$MAX_PARALLEL_JOBS
EOF
    debug "Configurações salvas em $CONFIG_FILE"
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        debug "Configuration loaded from $CONFIG_FILE"
    fi
}

