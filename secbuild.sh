#!/usr/bin/env bash

################################################################################
# SecBuild v3.1 - Security Tools Automated Installer (Modular Version)
# Author: SecBuild Team
# Description: Robust and optimized tool for automated installation
#              of security tools on Kali Linux and Ubuntu
# Compatibility: Kali Linux, Ubuntu 20.04+
################################################################################

# Check Bash version (requires 4.0+ for associative arrays)
if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
    echo "Error: This script requires Bash 4.0 or higher." >&2
    echo "Current version: $BASH_VERSION" >&2
    echo "" >&2
    echo "On macOS, install updated Bash via Homebrew:" >&2
    echo "  brew install bash" >&2
    echo "" >&2
    echo "Then run with:" >&2
    echo "  /usr/local/bin/bash $0" >&2
    echo "" >&2
    echo "Or add to /etc/shells and set as default shell." >&2
    exit 1
fi

set -uo pipefail
IFS=$'\n\t'

export BASH_INI_PARSER_DEBUG=0   # Disable bash-ini-parser debug


# ==============================================================================
# GLOBAL CONFIGURATIONS
# ==============================================================================

readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
# LOCALES_DIR removed - i18n system removed

# Work directories
readonly WORK_DIR="${WORK_DIR:-$HOME/.secbuild}"
readonly SRC_DIR="${SRC_DIR:-/usr/local/src/secbuild}"
readonly BIN_DIR="${BIN_DIR:-/usr/local/bin}"
readonly LOG_DIR="${WORK_DIR}/logs"
readonly CACHE_DIR="${WORK_DIR}/cache"
readonly VENDOR_DIR="${WORK_DIR}/vendor"
readonly CONFIG_DIR="${WORK_DIR}/config"
readonly BACKUP_DIR="${WORK_DIR}/backups"

# Configuration and log files
readonly CONFIG_FILE="${CONFIG_DIR}/secbuild.conf"
readonly LOG_FILE="${LOG_DIR}/secbuild_$(date +%Y%m%d_%H%M%S).log"
readonly ERROR_LOG="${LOG_DIR}/secbuild_errors_$(date +%Y%m%d_%H%M%S).log"
readonly DEPS_LOCK="${WORK_DIR}/.deps.lock"

# Resource URLs
readonly PACKAGE_INI_URL="https://raw.githubusercontent.com/DonatoReis/Secbuild/master/package-dist.ini"
readonly PROGRESSBAR_URL="https://github.com/NRZCode/progressbar"
readonly INI_PARSER_URL="https://github.com/NRZCode/bash-ini-parser"

# System settings
readonly DOWNLOAD_TIMEOUT=300
readonly RETRY_COUNT=3
readonly RETRY_DELAY=5
readonly CACHE_TTL=86400
readonly HASH_ALGORITHM="sha256"

# Global flags
FORCE_UPDATE=0
VERBOSE_MODE=0
SILENT_MODE=0
INTERACTIVE_MODE=1
DRY_RUN=0
PARALLEL_INSTALL=0
MAX_PARALLEL_JOBS=4
APT_UPDATE_DONE=0
USE_LATEST_RELEASE=1  # Always use latest stable version from GitHub
DISTRO=""
PKG_MANAGER=""

# Arrays for tools
declare -A TOOLS_REGISTRY
declare -A TOOLS_STATUS
declare -A TOOLS_PROFILES
declare -A PROFILE_TOOLS
declare -a FAILED_TOOLS=()
declare -a INSTALLED_TOOLS=()
declare -a SKIPPED_TOOLS=()

# ==============================================================================
# HELPER FUNCTIONS FOR ARRAYS WITH SAFETY
# ==============================================================================

# Count array elements safely (compatible with set -u)
safe_array_count() {
    local array_name="$1"
    local count=0
    
    # Temporarily disable set -u
    set +u
    
    # Check if array exists and has elements
    if declare -p "$array_name" &>/dev/null; then
        eval "count=\${#${array_name}[@]}"
    fi
    
    # Re-enable set -u
    set -u
    
    echo "$count"
}

# Check if array has elements
array_has_elements() {
    local array_name="$1"
    local count
    count=$(safe_array_count "$array_name")
    [[ $count -gt 0 ]]
}

# Validate that arrays were initialized correctly
validate_arrays() {
    local arrays=("FAILED_TOOLS" "INSTALLED_TOOLS" "SKIPPED_TOOLS" "TOOLS_REGISTRY")
    for arr in "${arrays[@]}"; do
        if ! declare -p "$arr" &>/dev/null; then
            echo "Error: Array $arr was not initialized correctly" >&2
            return 1
        fi
    done
    return 0
}

# ==============================================================================
# LOAD MODULES
# ==============================================================================

# Load modules in correct order
load_modules() {
    # Load modules in order
    
    # 2. system (cores, diretórios)
    if [[ -f "$LIB_DIR/system.sh" ]]; then
        source "$LIB_DIR/system.sh"
    else
        echo "Error: Module system.sh not found!" >&2
        exit 1
    fi
    
    # 3. logging
    if [[ -f "$LIB_DIR/logging.sh" ]]; then
        source "$LIB_DIR/logging.sh"
        init_logging
    else
        echo "Error: Module logging.sh not found!" >&2
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
        echo "Error: Module install.sh not found!" >&2
        exit 1
    fi
    
    # 8. ui (opcional - funções de interface)
    if [[ -f "$LIB_DIR/ui.sh" ]]; then
        source "$LIB_DIR/ui.sh"
    fi
}

# ==============================================================================
# CLEANUP AND SIGNAL HANDLING
# ==============================================================================

# Cleanup on interruption or exit
cleanup_on_exit() {
    local exit_code=$?
    
    # Kill child processes (background jobs) - compatible with macOS and Linux
    local child_pids
    child_pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$child_pids" ]]; then
        echo "$child_pids" | while IFS= read -r pid; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done
    fi
    
    # Clean temporary files from parallel installation
    rm -f /tmp/secbuild_*_$$.tmp 2>/dev/null || true
    
    # Clean other temporary files
    rm -f /tmp/secbuild_* 2>/dev/null || true
    
    # If there was an error, show message
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]] && [[ $exit_code -ne 143 ]]; then
        # Only show error if logging is initialized
        if command -v error &>/dev/null; then
            error "Script interrupted with exit code: $exit_code"
        fi
    fi
    
    exit "$exit_code"
}

# Configure traps for cleanup
trap cleanup_on_exit EXIT INT TERM

# ==============================================================================
# HELPER FUNCTIONS (UI and Progress)
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
    echo -e "${CYAN}SecBuild v$SCRIPT_VERSION${RESET}"
    echo -e "${BLUE}Advanced Security Tools Installer for Kali/Ubuntu${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
}

# Helper function to format time
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

# Improved progress bar (NEW IMPROVEMENT)
show_progress() {
    local current=$1
    local total=$2
    local msg="${3:-Processing...}"
    local width=50
    
    [[ $total -eq 0 ]] && total=1
    
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    
    # Calculate elapsed time and estimate (if START_TIME is defined)
    local elapsed_str=""
    local remaining_str=""
    local speed_str=""
    
    if [[ -n "${START_TIME:-}" ]]; then
        local elapsed=$(($(date +%s) - START_TIME))
        elapsed_str=$(format_time "$elapsed")
        
        # Calculate estimate based on average speed
        if [[ $current -gt 0 ]] && [[ $elapsed -gt 0 ]]; then
            local avg_time_per_item=$((elapsed / current))
            local remaining=$((avg_time_per_item * (total - current)))
            remaining_str=$(format_time "$remaining")
            
            # Calculate speed (items per minute)
            local speed=$((current * 60 / elapsed))
            [[ $speed -gt 0 ]] && speed_str="${speed}/min"
        fi
    fi
    
    # Colors based on progress
    local color=""
    [[ $percentage -lt 33 ]] && color="\033[0;31m"  # Vermelho
    [[ $percentage -ge 33 && $percentage -lt 66 ]] && color="\033[0;33m"  # Amarelo
    [[ $percentage -ge 66 ]] && color="\033[0;32m"  # Verde
    
    # Build visual bar
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
    
    # Add time information if available
    if [[ -n "$elapsed_str" ]]; then
        printf "[${YELLOW}%s${RESET}" "$elapsed_str"
        [[ -n "$remaining_str" ]] && printf " / ${YELLOW}%s${RESET}" "$remaining_str"
        printf "]"
        [[ -n "$speed_str" ]] && printf " [${GREEN}%s${RESET}]" "$speed_str"
    fi
}

print_installation_summary() {
    echo
    echo -e "${CYAN}Installation Summary${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    # Use helper function to count arrays safely
    local installed_count failed_count skipped_count
    installed_count=$(safe_array_count "INSTALLED_TOOLS")
    failed_count=$(safe_array_count "FAILED_TOOLS")
    skipped_count=$(safe_array_count "SKIPPED_TOOLS")
    
    if array_has_elements "INSTALLED_TOOLS"; then
        echo -e "${GREEN}Successfully installed ($installed_count):${RESET}"
        set +u
        for tool in "${INSTALLED_TOOLS[@]}"; do
            echo "  ✓ $tool"
        done
        set -u
    fi
    
    if array_has_elements "FAILED_TOOLS"; then
        echo
        echo -e "${RED}Failed ($failed_count):${RESET}"
        set +u
        for tool in "${FAILED_TOOLS[@]}"; do
            echo "  ✗ $tool"
        done
        set -u
    fi
    
    if array_has_elements "SKIPPED_TOOLS"; then
        echo
        echo -e "${YELLOW}Skipped/Already installed ($skipped_count):${RESET}"
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
    
    echo -e "Success rate: ${success_rate}%"
    
    [[ $failed_count -gt 0 ]] && warning "Check log for more details about failures:\n$ERROR_LOG"
}

# ==============================================================================
# INTERACTIVE MENU (Simplified - full UI can be extracted later)
# ==============================================================================

show_main_menu() {
    while true; do
        clear
        print_banner
        
        echo -e "${CYAN}Main Menu${RESET}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo
        echo -e "  ${GREEN}1)${RESET} Install all tools"
        echo -e "  ${GREEN}2)${RESET} Install specific tools"
        echo -e "  ${GREEN}3)${RESET} Install by profile"
        echo -e "  ${GREEN}4)${RESET} List available tools"
        echo -e "  ${GREEN}5)${RESET} Check installed tools"
        echo -e "  ${GREEN}6)${RESET} Update existing tools"
        echo -e "  ${GREEN}7)${RESET} Settings"
        echo -e "  ${GREEN}8)${RESET} View logs"
        echo -e "  ${GREEN}9)${RESET} About"
        echo -e "  ${RED}0)${RESET} Exit"
        echo
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo
        
        read -rp "Choose an option: " choice
        
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
            *) warning "Invalid option!" && sleep 2 ;;
        esac
    done
}

menu_install_all() {
    clear
    print_banner
    echo -e "${CYAN}Install all tools${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    info "This operation will install all ${#TOOLS_REGISTRY[@]} available tools."
    warning "This may take a long time!"
    echo
    read -rp "Do you want to continue? (y/N): " confirm
    [[ "$confirm" =~ ^[Ss]$ ]] && install_all_tools
    echo
    read -rp "Press ENTER to continue..."
}

menu_install_specific() {
    clear
    print_banner
    echo -e "${CYAN}Install specific tools${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -rp "Enter tool name (or 'back'): " tool_name
    [[ "$tool_name" == "back" ]] && return
    tool_name="${tool_name,,}"
    [[ -n "${TOOLS_REGISTRY[$tool_name]:-}" ]] && install_single_tool "$tool_name"
    echo
    read -rp "Press ENTER to continue..."
}

menu_install_profile() {
    clear
    print_banner
    echo -e "${CYAN}Install by profile${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    
    # Check if profiles are available
    set +u
    local profile_count=${#PROFILE_TOOLS[@]}
    set -u
    
    if [[ $profile_count -eq 0 ]]; then
        warning "No profiles configured"
        echo
        info "Profiles can be defined in package.ini using:"
        echo "  [Tool]"
        echo "    profile=recon,web"
        echo
        read -rp "Press ENTER to continue..."
        return
    fi
    
    # List profiles with numbering
    echo -e "${GREEN}Available profiles:${RESET}"
    echo
    
    local profile_num=1
    declare -A profile_map
    local sorted_profiles
    
    # Sort profiles alphabetically
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
        
        # Get profile description if available (from tools_config.yaml)
        local profile_desc=""
        case "$profile" in
            recon) profile_desc="Reconnaissance and information gathering" ;;
            dns) profile_desc="DNS analysis and enumeration" ;;
            subdomains) profile_desc="Subdomain discovery" ;;
            web) profile_desc="Web application security" ;;
            fuzzing) profile_desc="Fuzzing and brute force" ;;
            ssl) profile_desc="SSL/TLS analysis" ;;
            network) profile_desc="Network scanning" ;;
            osint) profile_desc="Open source intelligence" ;;
            wifi) profile_desc="WiFi security" ;;
            automation) profile_desc="Test automation" ;;
            parameters) profile_desc="Parameter discovery" ;;
            takeover) profile_desc="Subdomain takeover detection" ;;
            cloud) profile_desc="Cloud security" ;;
            social) profile_desc="Social engineering" ;;
            utilities) profile_desc="Auxiliary utilities" ;;
            pentest) profile_desc="Complete pentesting toolkit" ;;
            bugbounty) profile_desc="Bug bounty tools" ;;
            all) profile_desc="All tools" ;;
        esac
        
        if [[ -n "$profile_desc" ]]; then
            echo -e "  ${GREEN}$profile_num)${RESET} ${CYAN}$profile${RESET} - $profile_desc (${YELLOW}$tool_count${RESET} tools)"
        else
            echo -e "  ${GREEN}$profile_num)${RESET} ${CYAN}$profile${RESET} - ${YELLOW}$tool_count${RESET} tools"
        fi
        
        profile_map[$profile_num]="$profile"
        ((profile_num++))
    done <<< "$sorted_profiles"
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    read -rp "Choose an option: " choice
    
    # Check if it's a number or name
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        # Selection by number
        if [[ -n "${profile_map[$choice]:-}" ]]; then
            profile="${profile_map[$choice]}"
        else
            error "Invalid profile!"
            sleep 2
            return
        fi
    elif [[ "$choice" == "back" ]]; then
        return
    else
        # Selection by name
        profile="${choice,,}"
    fi
    
    # Confirm installation
    echo
    set +u
    local tool_list="${PROFILE_TOOLS[$profile]}"
    set -u
    
    if [[ -z "$tool_list" ]]; then
        error "Profile '$profile' not found"
        sleep 2
        return
    fi
    
    local tool_count
    tool_count=$(echo "$tool_list" | wc -w)
    
    warning "This operation will install $tool_count tool(s) from profile '$profile'"
    echo
    read -rp "Do you want to continue? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Ss]$ ]]; then
        install_profile "$profile"
    else
        info "Installation cancelled"
    fi
    
    echo
    read -rp "Press ENTER to continue..."
}

menu_list_tools() {
    clear
    print_banner
    echo -e "${CYAN}List available tools${RESET}"
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
    read -rp "Press ENTER to continue..."
}

menu_check_installed() {
    clear
    print_banner
    echo -e "${CYAN}Check installed tools${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    local installed_count=0
    local not_installed_count=0
    
    echo -e "${GREEN}Installed:${RESET}"
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        if is_installed_tool "$tool"; then
            echo "  ✓ $tool"
            ((installed_count++))
        fi
    done
    
    echo
    echo -e "${RED}Not installed:${RESET}"
    for tool in $(echo "${!TOOLS_REGISTRY[@]}" | tr ' ' '\n' | sort); do
        if ! is_installed_tool "$tool"; then
            echo "  ✗ $tool"
            ((not_installed_count++))
        fi
    done
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "Summary: ${GREEN}$installed_count installed${RESET} | ${RED}$not_installed_count not installed${RESET}"
    echo
    read -rp "Press ENTER to continue..."
}

menu_update_tools() {
    clear
    print_banner
    echo -e "${CYAN}Update existing tools${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    info "Checking for updates for Git tools..."
    echo
    
    local updated=0
    local failed=0
    
    while IFS= read -r -d '' git_dir; do
        local repo_dir="${git_dir%/.git}"
        local repo_name="${repo_dir##*/}"
        echo -n "Updating $repo_name... "
        if git -C "$repo_dir" pull -q --all >>"$LOG_FILE" 2>&1; then
            echo -e "${GREEN}✓${RESET}"
            ((updated++))
        else
            echo -e "${RED}✗${RESET}"
            ((failed++))
        fi
    done < <(find "$SRC_DIR" -type d -name .git -print0 2>/dev/null)
    
    [[ $((updated + failed)) -eq 0 ]] && warning "No Git repositories found"
    echo
    echo -e "Result: ${GREEN}$updated updated${RESET} | ${RED}$failed failed${RESET}"
    echo
    read -rp "Press ENTER to continue..."
}

menu_settings() {
    clear
    print_banner
    echo -e "${CYAN}Settings${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo "  1) Verbose mode: $([ $VERBOSE_MODE -eq 1 ] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
    echo "  2) Silent mode: $([ $SILENT_MODE -eq 1 ] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
    echo "  3) Update tool list"
    echo "  4) Force reinstall dependencies"
    echo "  5) Reset settings"
    echo "  6) Back"
    echo
    read -rp "Choose an option: " choice
    
    case "$choice" in
        1) 
            VERBOSE_MODE=$((1 - VERBOSE_MODE))
            success "Verbose mode: $([ $VERBOSE_MODE -eq 1 ] && echo "enabled" || echo "disabled")"
            save_config
            sleep 1
            ;;
        2) 
            SILENT_MODE=$((1 - SILENT_MODE))
            success "Silent mode: $([ $SILENT_MODE -eq 1 ] && echo "enabled" || echo "disabled")"
            save_config
            sleep 1
            ;;
        3)
            download_package_ini && parse_package_ini
            success "Tool list updated"
            sleep 2
            ;;
        4)
            rm -f "$DEPS_LOCK"
            install_core_dependencies
            install_vendor_tools
            touch "$DEPS_LOCK"
            success "Dependencies reinstalled"
            sleep 2
            ;;
        5) 
            rm -f "$CONFIG_FILE"
            warning "Settings reset"
            sleep 2
            ;;
        6) 
            return
            ;;
        *) 
            warning "Invalid option!"
            sleep 2
            ;;
    esac
}

menu_view_logs() {
    clear
    print_banner
    echo -e "${CYAN}View logs${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo "  1) Full log"
    echo "  2) Error log"
    echo "  3) Last 50 lines"
    echo "  4) List all logs"
    echo "  5) Clean old logs"
    echo "  6) Back"
    echo
    read -rp "Choose an option: " choice
    
    case "$choice" in
        1) 
            if [[ -f "$LOG_FILE" ]]; then
                less "$LOG_FILE"
            else
                warning "Log not found"
                sleep 2
            fi
            ;;
        2) 
            if [[ -f "$ERROR_LOG" ]]; then
                less "$ERROR_LOG"
            else
                warning "Error log not found"
                sleep 2
            fi
            ;;
        3)
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 50 "$LOG_FILE" | less
            else
                warning "Log not found"
                sleep 2
            fi
            ;;
        4)
            ls -lah "$LOG_DIR" | less
            ;;
        5)
            find "$LOG_DIR" -type f -mtime +7 -delete 2>/dev/null
            success "Logs older than 7 days removed"
            sleep 2
            ;;
        6) 
            return
            ;;
        *) 
            warning "Invalid option!"
            sleep 2
            ;;
    esac
}

menu_about() {
    clear
    print_banner
    echo -e "${CYAN}About SecBuild${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo
    echo -e "${GREEN}SecBuild v$SCRIPT_VERSION${RESET}"
    echo
    echo "Robust and optimized tool for automated installation"
    echo "of security and pentesting tools."
    echo
    echo -e "${CYAN}Features:${RESET}"
    echo "  • Automated installation of 100+ tools"
    echo "  • Optimized for Kali Linux and Ubuntu"
    echo "  • Smart detection of installed tools"
    echo "  • Advanced dependency management"
    echo "  • Detailed logging system"
    echo "  • Robust error handling"
    echo "  • Friendly interactive interface"
    echo
    echo -e "${CYAN}Compatibility:${RESET}"
    echo "  • Kali Linux (all versions)"
    echo "  • Ubuntu 20.04+"
    echo "  • Debian 10+"
    echo
    echo -e "${CYAN}Directories:${RESET}"
    echo "  • Work: $WORK_DIR"
    echo "  • Sources: $SRC_DIR"
    echo "  • Binaries: $BIN_DIR"
    echo "  • Logs: $LOG_DIR"
    echo
    read -rp "Press ENTER to continue..."
}

exit_script() {
    echo
    info "Shutting down SecBuild..."
    rm -f /tmp/secbuild_* 2>/dev/null
    
    # Use helper function to count arrays safely
    local installed_count failed_count skipped_count
    installed_count=$(safe_array_count "INSTALLED_TOOLS")
    failed_count=$(safe_array_count "FAILED_TOOLS")
    skipped_count=$(safe_array_count "SKIPPED_TOOLS")
    
    if [[ $((installed_count + failed_count + skipped_count)) -gt 0 ]]; then
        print_installation_summary
    fi
    
    success "SecBuild Successfully closed!"
    exit 0
}

# ==============================================================================
# ERROR HANDLING
# ==============================================================================

on_error() {
    local line="$1"
    local code="$2"
    local cmd="${3:-}"
    
    error "╔════════════════════════════════════════╗"
    error "║  ERROR DETECTED                        ║"
    error "╠════════════════════════════════════════╣"
    error "║  Line: $line"
    error "║  Code: $code"
    [[ -n "$cmd" ]] && error "║  Command: $cmd"
    error "║  Log: $LOG_FILE"
    error "╚════════════════════════════════════════╝"
    
    # Dump current state for debug
    if [[ ${VERBOSE_MODE:-0} -eq 1 ]]; then
        {
            echo "=== Array State ==="
            echo "INSTALLED_TOOLS: $(safe_array_count 'INSTALLED_TOOLS')"
            echo "FAILED_TOOLS: $(safe_array_count 'FAILED_TOOLS')"
            echo "SKIPPED_TOOLS: $(safe_array_count 'SKIPPED_TOOLS')"
        } >> "${ERROR_LOG:-/dev/null}" 2>/dev/null || true
    fi
}

trap 'on_error ${LINENO} $? "${BASH_COMMAND}"' ERR

trap_handler() {
    echo
    warning "Interrupted by user!"
    exit_script
}

trap trap_handler INT TERM

# ==============================================================================
# FUNÇÃO PRINCIPAL
# ==============================================================================

show_usage() {
    cat <<EOF
${CYAN}SecBuild v$SCRIPT_VERSION${RESET}
${BLUE}Advanced Security Tools Installer for Kali/Ubuntu${RESET}

${GREEN}Usage:${RESET}
  sudo $SCRIPT_NAME [OPTIONS]

${GREEN}Options:${RESET}
  -h, --help          Show this help
  -v, --verbose       Verbose mode (debug)
  -f, --force         Force dependency update
  -s, --silent        Silent mode (non-interactive)
  -l, --list          List available tools
  -i, --install TOOL  Install specific tool
  -u, --update        Update all installed tools
  --dry-run           Simulation mode (does not execute real commands)
  -p, --parallel [N]  Parallel installation (N = number of jobs, default: 4)
  --profile NAME      Install specific profile
  --list-profiles     List available profiles
  --no-latest-release Disable latest release installation (use default branch)

${GREEN}Examples:${RESET}
  sudo $SCRIPT_NAME                    # Interactive mode
  sudo $SCRIPT_NAME -i nmap            # Install specific tool
  sudo $SCRIPT_NAME -l                 # List tools
  sudo $SCRIPT_NAME --dry-run           # Simulate installation
  sudo $SCRIPT_NAME -p 8                # Install in parallel
  sudo $SCRIPT_NAME --profile recon     # Install profile

EOF
}

main() {
    # Validar arrays antes de começar
    validate_arrays || exit 1
    
    # Load modules
    load_modules
    
    # Setup colors
    setup_colors
    
    # Criar diretórios
    create_directories
    
    # Detect system first (may allow test mode on macOS)
    detect_system
    
    # Check root (pass arguments to check if it's a listing command)
    check_root "$@"
    
    # Load configuration
    load_config
    
    # Load tools_config.yaml
    load_tools_config_yaml
    
    # Parse arguments
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
                } || { error "Tool name required"; exit 1; }
                ;;
            -u|--update) INTERACTIVE_MODE=0; menu_update_tools; exit 0 ;;
            --dry-run) DRY_RUN=1; info "DRY-RUN mode enabled - no changes will be made"; shift ;;
            -p|--parallel)
                PARALLEL_INSTALL=1
                shift
                [[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]] && { MAX_PARALLEL_JOBS="$1"; shift; }
                info "Parallel installation enabled (max: $MAX_PARALLEL_JOBS jobs)"
                ;;
            --profile)
                shift
                [[ -n "${1:-}" ]] && {
                    INTERACTIVE_MODE=0
                    [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
                    parse_package_ini
                    install_profile "$1"
                    exit $?
                } || { error "Profile name required"; exit 1; }
                ;;
            --list-profiles)
                [[ ! -f "$CONFIG_DIR/package.ini" ]] && download_package_ini
                parse_package_ini
                list_profiles
                exit 0
                ;;
            --no-latest-release)
                USE_LATEST_RELEASE=0
                info "Latest release installation disabled"
                shift
                ;;
            *) warning "Unknown argument: $1"; shift ;;
        esac
    done
    
    # Non-interactive mode
    if [[ $INTERACTIVE_MODE -eq 0 ]]; then
        info "Running in non-interactive mode"
        [[ ! -f "$DEPS_LOCK" || $FORCE_UPDATE -eq 1 ]] && {
            install_core_dependencies
            install_vendor_tools
            touch "$DEPS_LOCK"
        }
        download_package_ini
        parse_package_ini
        # Use helper function to check arrays
        local installed_count failed_count
        installed_count=$(safe_array_count "INSTALLED_TOOLS")
        failed_count=$(safe_array_count "FAILED_TOOLS")
        [[ $installed_count -eq 0 && $failed_count -eq 0 ]] && install_all_tools
        exit 0
    fi
    
    # Interactive mode
    print_banner
    info "Starting SecBuild v$SCRIPT_VERSION"
    
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
