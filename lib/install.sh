#!/usr/bin/env bash
################################################################################
# install.sh - Installation Module
# Manages installation via Git, Go, Python, APT
################################################################################

# ==============================================================================
# BASH VERSION CHECK (requires Bash 4+ for associative arrays)
# ==============================================================================
if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
    echo "Error: This script requires Bash 4.0 or higher." >&2
    echo "Current version: $BASH_VERSION" >&2
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "On macOS, install Bash 4+ via Homebrew: brew install bash" >&2
        echo "Then run this script with: /usr/local/bin/bash $0" >&2
    fi
    exit 1
fi

# ==============================================================================
# FUNÇÕES AUXILIARES DE SEGURANÇA E PERFORMANCE
# ==============================================================================

# Command cache to avoid multiple command -v calls
declare -gA COMMAND_CACHE

# Installation verification cache (new improvement)
declare -gA INSTALLED_CACHE

# Check if command exists (with cache)
cached_command_exists() {
    local cmd="$1"
    
    # Check cache first (safe array access without modifying set -u)
    if [[ ${COMMAND_CACHE[$cmd]+_} ]]; then
        return "${COMMAND_CACHE[$cmd]}"
    fi
    
    # Check command
    if command -v "$cmd" &>/dev/null 2>&1; then
        COMMAND_CACHE[$cmd]=0
        return 0
    else
        COMMAND_CACHE[$cmd]=1
        return 1
    fi
}

# Validar URL antes de usar
validate_url() {
    local url="$1"
    
    # Verificar formato básico
    [[ "$url" =~ ^https?:// ]] || return 1
    
    # Verificar se URL é acessível (com timeout curto)
    if curl -sSf --max-time 5 --head "$url" &>/dev/null 2>&1; then
        return 0
    fi
    
    # Se curl falhou, tentar wget
    if wget --spider --timeout=5 --tries=1 "$url" &>/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# ==============================================================================
# FUNÇÕES PARA BUSCAR VERSÃO MAIS RECENTE DO GITHUB
# ==============================================================================

# Converter URL do GitHub para formato API
github_url_to_api() {
    local repo_url="$1"
    
    # Remover .git do final se existir
    repo_url="${repo_url%.git}"
    
    # Converter https://github.com/user/repo para API
    if [[ "$repo_url" =~ github\.com[:/]([^/]+)/([^/]+) ]]; then
        local user="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        echo "https://api.github.com/repos/${user}/${repo}"
    else
        return 1
    fi
}

# Generate SHA256 hash (portable: works on Linux and macOS)
sha256_hex() {
    local str="$1"
    if command -v sha256sum &>/dev/null; then
        echo -n "$str" | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        echo -n "$str" | shasum -a 256 | awk '{print $1}'
    else
        # Fallback: simple hash-like string
        echo "$str" | tr -d '/:.' | head -c 32
    fi
}

# Gerar hash de string (compatível com macOS e Linux)
generate_hash() {
    local str="$1"
    if command -v md5sum &>/dev/null; then
        echo -n "$str" | md5sum | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        echo -n "$str" | md5 | cut -d' ' -f1
    else
        # Fallback: usar hash simples baseado em caracteres
        sha256_hex "$str" | head -c 16
    fi
}

# Buscar última release estável do GitHub
get_latest_github_release() {
    local repo_url="$1"
    local repo_hash
    repo_hash=$(generate_hash "$repo_url")
    local cache_root="${CACHE_DIR:-${WORK_DIR:-/tmp}/cache}"
    local cache_file="${cache_root}/github_release_${repo_hash}.cache"
    local cache_ttl=3600  # 1 hora
    
    # Verificar cache
    if [[ -f "$cache_file" ]]; then
        local cache_timestamp=0
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_timestamp=$(stat -f %m "$cache_file" 2>/dev/null || echo "0")
        else
            cache_timestamp=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
        fi
        local cache_age=$(($(date +%s) - cache_timestamp))
        if [[ $cache_age -lt $cache_ttl ]]; then
            local cached_version
            cached_version=$(cat "$cache_file" 2>/dev/null)
            if [[ -n "$cached_version" ]]; then
                debug "Using cached version for $repo_url: $cached_version"
                echo "$cached_version" >&1
                return 0
            fi
        fi
    fi
    
    # Converter URL para API
    local api_url
    api_url=$(github_url_to_api "$repo_url")
    [[ -z "$api_url" ]] && return 1
    
    # Search for latest release (not pre-release)
    # Support GITHUB_TOKEN for rate limit avoidance
    # Remove -f to capture http_code even on 403/404
    local curl_opts=(-sS --max-time 10)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl_opts+=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    
    # Use mktemp to avoid race conditions and symlink attacks
    local tmp_file
    tmp_file=$(mktemp) || return 1
    
    local http_code
    local latest_release
    if command -v grep &>/dev/null && grep --version 2>&1 | grep -q "GNU"; then
        # GNU grep com suporte a -P
        http_code=$(curl "${curl_opts[@]}" -w "%{http_code}" -o "$tmp_file" \
            "${api_url}/releases/latest" 2>/dev/null | tail -1 || echo "000")
        if [[ "$http_code" == "200" ]]; then
            latest_release=$(grep -oP '"tag_name":\s*"\K[^"]+' "$tmp_file" 2>/dev/null | head -1)
        elif [[ "$http_code" == "403" ]] || [[ "$http_code" == "429" ]]; then
            # Rate limited - increase cache TTL and use cached value if available
            warning "GitHub API rate limited (HTTP $http_code). Using cached version or default branch."
            cache_ttl=86400  # 24 hours instead of 1 hour
            rm -f "$tmp_file"
            return 1
        fi
    else
        # Fallback para grep sem -P (macOS)
        http_code=$(curl "${curl_opts[@]}" -w "%{http_code}" -o "$tmp_file" \
            "${api_url}/releases/latest" 2>/dev/null | tail -1 || echo "000")
        if [[ "$http_code" == "200" ]]; then
            latest_release=$(grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_file" 2>/dev/null | \
                sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
        elif [[ "$http_code" == "403" ]] || [[ "$http_code" == "429" ]]; then
            # Rate limited - increase cache TTL and use cached value if available
            warning "GitHub API rate limited (HTTP $http_code). Using cached version or default branch."
            cache_ttl=86400  # 24 hours instead of 1 hour
            rm -f "$tmp_file"
            return 1
        fi
    fi
    rm -f "$tmp_file"
    
    if [[ -n "$latest_release" ]]; then
        # Salvar no cache
        mkdir -p "$(dirname "$cache_file")"
        echo "$latest_release" > "$cache_file"
        debug "Latest stable release found: $latest_release"
        echo "$latest_release" >&1
        return 0
    fi
    
    # If no release found, try latest tag
    local latest_tag
    latest_tag=$(get_latest_github_tag "$repo_url")
    if [[ -n "$latest_tag" ]]; then
        mkdir -p "$(dirname "$cache_file")"
        echo "$latest_tag" > "$cache_file"
        echo "$latest_tag"
        return 0
    fi
    
    return 1
}

# Buscar última tag do GitHub
get_latest_github_tag() {
    local repo_url="$1"
    local repo_hash
    repo_hash=$(generate_hash "$repo_url")
    local cache_root="${CACHE_DIR:-${WORK_DIR:-/tmp}/cache}"
    local cache_file="${cache_root}/github_tag_${repo_hash}.cache"
    local cache_ttl=3600  # 1 hora
    
    # Verificar cache
    if [[ -f "$cache_file" ]]; then
        local cache_timestamp=0
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_timestamp=$(stat -f %m "$cache_file" 2>/dev/null || echo "0")
        else
            cache_timestamp=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
        fi
        local cache_age=$(($(date +%s) - cache_timestamp))
        if [[ $cache_age -lt $cache_ttl ]]; then
            local cached_tag
            cached_tag=$(cat "$cache_file" 2>/dev/null)
            if [[ -n "$cached_tag" ]]; then
                debug "Usando tag em cache para $repo_url: $cached_tag"
                echo "$cached_tag"
                return 0
            fi
        fi
    fi
    
    # Converter URL para API
    local api_url
    api_url=$(github_url_to_api "$repo_url")
    [[ -z "$api_url" ]] && return 1
    
    # Buscar última tag
    local latest_tag
    # Support GITHUB_TOKEN for rate limit avoidance
    # Remove -f to capture http_code even on 403/404
    local curl_opts=(-sS --max-time 10)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl_opts+=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi
    
    # Use mktemp to avoid race conditions and symlink attacks
    local tmp_file
    tmp_file=$(mktemp) || return 1
    
    local http_code
    local latest_tag
    if command -v grep &>/dev/null && grep --version 2>&1 | grep -q "GNU"; then
        # GNU grep com suporte a -P
        http_code=$(curl "${curl_opts[@]}" -w "%{http_code}" -o "$tmp_file" \
            "${api_url}/tags?per_page=1" 2>/dev/null | tail -1 || echo "000")
        if [[ "$http_code" == "200" ]]; then
            latest_tag=$(grep -oP '"name":\s*"\K[^"]+' "$tmp_file" 2>/dev/null | head -1)
        elif [[ "$http_code" == "403" ]] || [[ "$http_code" == "429" ]]; then
            # Rate limited - increase cache TTL
            cache_ttl=86400  # 24 hours instead of 1 hour
            rm -f "$tmp_file"
            return 1
        fi
    else
        # Fallback para grep sem -P (macOS)
        http_code=$(curl "${curl_opts[@]}" -w "%{http_code}" -o "$tmp_file" \
            "${api_url}/tags?per_page=1" 2>/dev/null | tail -1 || echo "000")
        if [[ "$http_code" == "200" ]]; then
            latest_tag=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_file" 2>/dev/null | \
                sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
        elif [[ "$http_code" == "403" ]] || [[ "$http_code" == "429" ]]; then
            # Rate limited - increase cache TTL
            cache_ttl=86400  # 24 hours instead of 1 hour
            rm -f "$tmp_file"
            return 1
        fi
    fi
    rm -f "$tmp_file"
    
    if [[ -n "$latest_tag" ]]; then
        # Salvar no cache
        mkdir -p "$(dirname "$cache_file")"
        echo "$latest_tag" > "$cache_file"
        debug "Última tag encontrada: $latest_tag"
        echo "$latest_tag"
        return 0
    fi
    
    return 1
}

# NOVA MELHORIA: Verificar integridade de repositório Git
verify_git_repository_integrity() {
    local repo_path="$1"
    local tool_name="$2"
    local expected_version="${3:-}"
    
    if [[ ! -d "$repo_path/.git" ]]; then
        return 0  # Not a Git repository, skip verification
    fi
    
    # Verify repository integrity (only in paranoid mode for performance)
    if [[ ${PARANOID_MODE:-0} -eq 1 ]]; then
        if ! git -C "$repo_path" fsck --no-progress --quiet >>"$LOG_FILE" 2>&1; then
            warning "Git repository may be corrupted: $repo_path"
            return 1
        fi
    fi
    
    # If we have expected version, verify commit hash
    if [[ -n "$expected_version" ]]; then
        local current_hash
        current_hash=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
        local expected_hash
        expected_hash=$(git -C "$repo_path" rev-parse "$expected_version" 2>/dev/null || echo "")
        
        if [[ -n "$current_hash" ]] && [[ -n "$expected_hash" ]] && [[ "$current_hash" != "$expected_hash" ]]; then
            warning "Commit hash does not match expected version for $tool_name"
            warning "Expected: ${expected_hash:0:12}, Got: ${current_hash:0:12}"
            # Does not fail, only warns (may be different branch)
        elif [[ -n "$current_hash" ]]; then
            debug "Integrity verified: hash ${current_hash:0:12} matches for $tool_name"
        fi
    fi
    
    return 0
}

# Verificar espaço em disco disponível
check_disk_space() {
    local required_mb="${1:-500}"
    local available=0
    local mount_point="${SRC_DIR:-/usr/local}"
    
    # Detectar espaço disponível
    if [[ "$OSTYPE" == "darwin"* ]]; then
        available=$(df -m "$mount_point" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    else
        available=$(df -m "$mount_point" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    fi
    
    # Verificar se conseguiu obter valor
    if [[ -z "$available" ]] || [[ "$available" == "0" ]]; then
        warning "Could not verify disk space, continuing..."
        return 0
    fi
    
    if [[ $available -lt $required_mb ]]; then
        error "Insufficient space: ${available}MB available, ${required_mb}MB required"
        return 1
    fi
    
    debug "Espaço em disco OK: ${available}MB disponível"
    return 0
}

# Detectar arquitetura do sistema para Go
detect_go_arch() {
    local goarch
    
    case "$(uname -m)" in
        x86_64)
            goarch="amd64"
            ;;
        aarch64|arm64)
            goarch="arm64"
            ;;
        armv7l)
            goarch="arm"
            ;;
        *)
            # Tentar obter do Go
            goarch=$(go env GOARCH 2>/dev/null || echo "amd64")
            ;;
    esac
    
    echo "$goarch"
}

# Post-installation health check (improved - more comprehensive)
# Portable timeout wrapper (works on Linux and macOS)
run_timeout() {
    local timeout_sec="$1"
    shift
    
    if command -v timeout &>/dev/null; then
        timeout "$timeout_sec" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$timeout_sec" "$@"
    else
        # No timeout available, run without timeout
        "$@"
    fi
}

# Fast health check for bulk installations (optimized)
health_check_tool_fast() {
    local tool="$1"
    
    # 1. Check if command exists
    if ! command -v "$tool" &>/dev/null; then
        return 1
    fi
    
    local tool_path
    tool_path=$(command -v "$tool")
    
    # 2. Check if executable (fix if needed)
    [[ -x "$tool_path" ]] || chmod +x "$tool_path" 2>/dev/null || return 1
    
    # 3. Quick version check (1s timeout, single attempt)
    run_timeout 1 "$tool" --version &>/dev/null 2>&1 || true
    
    return 0
}

# Comprehensive health check (for paranoid mode or verbose)
health_check_tool() {
    local tool="$1"
    
    # Use fast mode if not in paranoid mode
    if [[ ${PARANOID_MODE:-0} -eq 0 ]]; then
        health_check_tool_fast "$tool"
        return $?
    fi
    
    # Full health check (original logic)
    local issues=()
    
    # 1. Verificar se comando existe no PATH
    local tool_path=""
    if command -v "$tool" &>/dev/null; then
        tool_path=$(command -v "$tool")
    else
        # Verificar em diretórios comuns
        local common_paths=(
            "/usr/local/bin"
            "$HOME/go/bin"
            "/root/go/bin"
            "$HOME/.local/bin"
            "${BIN_DIR:-/usr/local/bin}"
        )
        
        for path in "${common_paths[@]}"; do
            if [[ -x "$path/$tool" ]]; then
                tool_path="$path/$tool"
                break
            fi
        done
        
        if [[ -z "$tool_path" ]]; then
            debug "Health check: command not found in PATH"
            return 1
        fi
    fi
    
    # 2. Check execution permissions
    if [[ ! -x "$tool_path" ]]; then
        debug "Health check: no execution permission, attempting to fix..."
        chmod +x "$tool_path" 2>/dev/null || {
            warning "Could not add execution permission for $tool_path"
            return 1
        }
    fi
    
    # 3. Check if file is not empty
    if [[ -f "$tool_path" ]] && [[ ! -s "$tool_path" ]]; then
        warning "Health check: empty or corrupted file: $tool_path"
        return 1
    fi
    
    # 4. Check if it's a broken link
    if [[ -L "$tool_path" ]] && [[ ! -e "$tool_path" ]]; then
        warning "Health check: broken symbolic link: $tool_path"
        return 1
    fi
    
    # 5. Check if it executes without fatal errors (5s timeout)
    if ! run_timeout 5 "$tool" --version &>/dev/null 2>&1; then
        # Tentar versão alternativa
        if ! run_timeout 5 "$tool" -version &>/dev/null 2>&1; then
            # Tentar help
            if ! run_timeout 5 "$tool" --help &>/dev/null 2>&1; then
                # Se todas falharam, verificar se é binário válido
                if [[ -f "$tool_path" ]]; then
                    # For ELF binaries, check if it's a valid executable
                    if file "$tool_path" 2>/dev/null | grep -q "ELF"; then
                        # Valid binary, may not have --version, but it's OK
                        debug "Health check: valid ELF binary (no --version)"
                        return 0
                    else
                        # Not a binary, may be script - check if it has shebang
                        if head -1 "$tool_path" 2>/dev/null | grep -q "^#!"; then
                            debug "Health check: valid script (no --version)"
                            return 0
                        else
                            warning "Health check: failed to execute command (timeout or fatal error)"
                            return 1
                        fi
                    fi
                else
                    warning "Health check: failed to execute command"
                    return 1
                fi
            fi
        fi
    fi
    
    # 6. For ELF binaries: check dynamic dependencies (optional, does not fail)
    if [[ -f "$tool_path" ]] && command -v ldd &>/dev/null && file "$tool_path" 2>/dev/null | grep -q "ELF"; then
        local missing_deps
        missing_deps=$(ldd "$tool_path" 2>&1 | grep -c "not found" 2>/dev/null || echo "0")
        # Ensure it's a valid number (remove any newlines or extra characters)
        missing_deps=$(echo "$missing_deps" | tr -d '\n\r' | head -1)
        # Default to 0 if not a valid number
        [[ "$missing_deps" =~ ^[0-9]+$ ]] || missing_deps=0
        
        if [[ $missing_deps -gt 0 ]]; then
            warning "Health check: $missing_deps dynamic dependency(ies) may be missing for $tool"
            # Does not fail, only warns
        fi
    fi
    
    # If we got here, everything is OK
    debug "Health check: $tool passed all verifications"
    return 0
}

# Add tool to array in thread-safe way (for parallel installation)
# Use PARENT_PID instead of $$ to ensure all jobs write to same files
add_to_installed() {
    local tool="$1"
    local result_file="/tmp/secbuild_installed_${PARENT_PID:-$$}.tmp"
    echo "$tool" >> "$result_file" 2>/dev/null || true
}

add_to_failed() {
    local tool="$1"
    local result_file="/tmp/secbuild_failed_${PARENT_PID:-$$}.tmp"
    echo "$tool" >> "$result_file" 2>/dev/null || true
}

add_to_skipped() {
    local tool="$1"
    local result_file="/tmp/secbuild_skipped_${PARENT_PID:-$$}.tmp"
    echo "$tool" >> "$result_file" 2>/dev/null || true
}

# Consolidate results from temporary files to global arrays
consolidate_parallel_results() {
    local pid="${PARENT_PID:-$$}"
    
    # Consolidate installed tools
    if [[ -f "/tmp/secbuild_installed_${pid}.tmp" ]]; then
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && INSTALLED_TOOLS+=("$tool")
        done < "/tmp/secbuild_installed_${pid}.tmp"
        rm -f "/tmp/secbuild_installed_${pid}.tmp" 2>/dev/null
    fi
    
    # Consolidate failures
    if [[ -f "/tmp/secbuild_failed_${pid}.tmp" ]]; then
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && FAILED_TOOLS+=("$tool")
        done < "/tmp/secbuild_failed_${pid}.tmp"
        rm -f "/tmp/secbuild_failed_${pid}.tmp" 2>/dev/null
    fi
    
    # Consolidate skipped tools
    if [[ -f "/tmp/secbuild_skipped_${pid}.tmp" ]]; then
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && SKIPPED_TOOLS+=("$tool")
        done < "/tmp/secbuild_skipped_${pid}.tmp"
        rm -f "/tmp/secbuild_skipped_${pid}.tmp" 2>/dev/null
    fi
}

# Collect installation metrics
collect_metrics() {
    local cache_root="${CACHE_DIR:-${WORK_DIR:-/tmp}/cache}"
    local metrics_file="${cache_root}/metrics_$(date +%Y%m%d).json"
    local start_time="${START_TIME:-$(date +%s)}"
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    mkdir -p "$(dirname "$metrics_file")"
    
    cat > "$metrics_file" << EOF
{
    "date": "$(date -Iseconds)",
    "total_tools": $(safe_array_count "TOOLS_REGISTRY"),
    "installed": $(safe_array_count "INSTALLED_TOOLS"),
    "failed": $(safe_array_count "FAILED_TOOLS"),
    "skipped": $(safe_array_count "SKIPPED_TOOLS"),
    "duration_seconds": $duration,
    "parallel_jobs": ${MAX_PARALLEL_JOBS:-4}
}
EOF
    
    debug "Métricas salvas em: $metrics_file"
}

# Função genérica de retry com backoff adaptativo (NOVA MELHORIA)
retry_with_adaptive_backoff() {
    local max_attempts="${1:-5}"
    local base_delay="${2:-2}"
    local max_delay="${3:-60}"
    shift 3
    local cmd=("$@")
    local attempt=1
    local last_error=""
    
    while [[ $attempt -le $max_attempts ]]; do
        # Execute command and capture error
        if "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
            return 0
        else
            last_error=$?
        fi
        
        # If not last attempt, calculate adaptive delay
        if [[ $attempt -lt $max_attempts ]]; then
            # Exponential backoff base
            local delay=$((base_delay * (2 ** (attempt - 1))))
            
            # Random jitter to avoid "thundering herd" (10% of delay)
            local jitter=$((RANDOM % (delay / 10 + 1)))
            delay=$((delay + jitter))
            
            # Limit maximum delay
            [[ $delay -gt $max_delay ]] && delay=$max_delay
            
            debug "Attempt $attempt/$max_attempts failed. Waiting ${delay}s before retrying..."
            sleep "$delay"
        fi
        
        ((attempt++))
    done
    
    return 1
}

# Improved function to install Go tools (with adaptive retry)
install_go_tool_with_retry() {
    local tool_name="$1"
    local package="$2"
    
    # Detect architecture
    local goarch
    goarch=$(detect_go_arch)
    
    # Check if package already has a version specifier (@version)
    local package_with_version="$package"
    if [[ "$package" != *@* ]]; then
        package_with_version="${package}@latest"
    fi
    
    # Try methods in order: simple first (most reliable), then optimized
    # Method 1: Simple install without flags (most reliable, try 2 times quickly)
    debug "Attempting to install $tool_name via: GOARCH=$goarch go install $package_with_version"
    if retry_with_adaptive_backoff 2 1 5 env GOARCH="$goarch" go install "$package_with_version"; then
        return 0
    fi
    
    # Method 2: With optimization flags (execute directly to preserve proper quoting)
    debug "Attempting to install $tool_name via: GOARCH=$goarch go install -ldflags=\"-s -w\" -trimpath $package_with_version"
    # Execute directly without bash -c to preserve flag quoting
    local attempt=1
    local max_attempts=2
    local base_delay=1
    local max_delay=5
    
    while [[ $attempt -le $max_attempts ]]; do
        if GOARCH="$goarch" go install -ldflags="-s -w" -trimpath "$package_with_version" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            local delay=$((base_delay * (2 ** (attempt - 1))))
            [[ $delay -gt $max_delay ]] && delay=$max_delay
            debug "Attempt $attempt/$max_attempts failed. Waiting ${delay}s before retrying..."
            sleep "$delay"
        fi
        ((attempt++))
    done
    
    # Method 3: Fallback methods (legacy, try once each)
    debug "Attempting to install $tool_name via: go get -u $package"
    if go get -u "$package" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    
    debug "Attempting to install $tool_name via: GO111MODULE=on go get $package"
    if env GO111MODULE=on go get "$package" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    
    error "Failed to install $tool_name after all attempts"
    return 1
}

# Safe lock acquisition using mkdir (atomic operation, prevents zombie locks)
acquire_lock_dir() {
    local lock_dir="$1"
    local timeout="${2:-300}"
    local t0
    t0=$(date +%s)
    
    while ! mkdir "$lock_dir" 2>/dev/null; do
        local elapsed=$(($(date +%s) - t0))
        if [[ $elapsed -ge $timeout ]]; then
            # Timeout reached - check if lock is stale by PID (not mtime)
            if [[ -f "$lock_dir/pid" ]]; then
                local lock_pid
                lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
                if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                    # PID doesn't exist - process is dead, remove stale lock
                    rm -rf "$lock_dir" 2>/dev/null && continue
                fi
            fi
            return 1
        fi
        sleep 0.1
    done
    
    # Store PID in lock directory for stale detection
    echo "$$" > "$lock_dir/pid" 2>/dev/null || true
    return 0
}

# Generic lock wrapper (safe, no bash -c, uses arguments directly, dynamic FD)
with_lock() {
    local lock_file="$1"
    shift
    local lock_dir="${lock_file}.dir"
    local fd rc
    
    if command -v flock &>/dev/null; then
        # Use flock with dynamic FD (safe for nested locks)
        exec {fd}>"$lock_file" || return 1
        if flock -w 300 "$fd"; then
            "$@"
            rc=$?
            exec {fd}>&-
            return $rc
        else
            exec {fd}>&-
            return 1
        fi
    else
        # Fallback: mkdir-based lock (atomic, safe, with timeout)
        if acquire_lock_dir "$lock_dir" 300; then
            "$@"
            rc=$?
            # Use rm -rf because lock_dir contains pid file
            rm -rf "$lock_dir" 2>/dev/null || true
            return $rc
        else
            return 1
        fi
    fi
}

# Pip install with lock for thread-safe parallel operations
pip_with_lock() {
    local lock_file="/tmp/secbuild_pip.lock"
    with_lock "$lock_file" "$@"
}

# Install Python requirements safely (optimized: no pip upgrade, uses lock)
install_requirements_safe() {
    local req_file="$1"
    local tool_name="$2"
    
    if [[ ! -f "$req_file" ]]; then
        return 0
    fi
    
    # Use lock for parallel safety and disable progress bar for speed
    if pip_with_lock python3 -m pip install -r "$req_file" --no-warn-script-location --quiet --disable-pip-version-check >>"$LOG_FILE" 2>&1; then
        return 0
    elif pip_with_lock python3 -m pip install -r "$req_file" --user --no-warn-script-location --quiet --disable-pip-version-check >>"$LOG_FILE" 2>&1; then
        return 0
    elif pip_with_lock python3 -m pip install -r "$req_file" --break-system-packages --quiet --disable-pip-version-check >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    
    return 1
}

# Git operations with lock per install_path to prevent race conditions
# Validate Git ref/tag to prevent injection attacks
# Validate Git ref/tag using Git's own validation (more robust than regex)
is_safe_git_ref() {
    # Use Git's built-in validation (handles edge cases like .., //, etc.)
    if command -v git &>/dev/null; then
        git check-ref-format --allow-onelevel "$1" >/dev/null 2>&1
    else
        # Fallback: basic validation if git is not available
        [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *..* ]] && [[ "$1" != *//* ]]
    fi
}

git_with_path_lock() {
    local install_path="$1"
    shift
    # Create lock file based on path hash to prevent concurrent operations on same repo
    local path_hash
    path_hash=$(sha256_hex "$install_path")
    local lock_file="/tmp/secbuild_git_${path_hash}.lock"
    
    with_lock "$lock_file" "$@"
}

# Instalar do Git (com shallow clone, validação de URL e versão mais recente)
install_from_git() {
    local repo_url="$1"
    local script_name="$2"
    local tool_name="$3"
    
    # Validate URL only if VALIDATE_URLS is enabled or in debug mode
    if [[ ${VALIDATE_URLS:-0} -eq 1 ]] || [[ ${VERBOSE_MODE:-0} -eq 1 ]]; then
        if ! validate_url "$repo_url"; then
            warning "Invalid or inaccessible URL: $repo_url"
            # Continue anyway, may be a temporary network issue
        fi
    fi
    
    local repo_name="${repo_url##*/}"
    repo_name="${repo_name%.git}"
    local vendor="${repo_url%/*}"
    vendor="${vendor##*/}"
    
    local install_path="$SRC_DIR/$vendor/$repo_name"
    local cache_key
    cache_key=$(get_cache_key "$repo_url")
    
    # Buscar versão mais recente se habilitado e for repositório GitHub
    local target_version=""
    local expected_hash=""
    
    if [[ "${USE_LATEST_RELEASE:-1}" -eq 1 ]] && [[ "$repo_url" =~ github\.com ]]; then
        debug "Searching for latest stable version for $tool_name..."
        target_version=$(get_latest_github_release "$repo_url" 2>/dev/null | head -1)
        # Validate that target_version is actually a version (starts with number or 'v')
        # Also validate it's safe to use as Git ref (prevent injection)
        if [[ -n "$target_version" ]] && ([[ "$target_version" =~ ^[0-9] ]] || [[ "$target_version" =~ ^v[0-9] ]]); then
            if ! is_safe_git_ref "$target_version"; then
                warning "Unsafe tag/ref from GitHub: $target_version. Falling back to default branch."
                target_version=""
            else
                # Keep target_version intact for checkout/clone, only adjust display
                local display_version="$target_version"
                [[ "$display_version" != v* ]] && display_version="v$display_version"
                info "Latest version found: $display_version"
            fi
        else
            target_version=""
            debug "Could not get specific version, using default branch"
        fi
    fi
    
    # NEW IMPROVEMENT: Check if there's expected hash in registry (integrity validation)
    IFS='|' read -r _url _script _deps _post <<< "${TOOLS_REGISTRY[$tool_name]:-}"
    # Hash may be in package.ini as separate attribute (to be implemented)
    # For now, we verify Git commit hash after clone
    
    # Display version without duplicating 'v' prefix
    local version_display=""
    if [[ -n "$target_version" ]]; then
        version_display=" (${target_version})"
    fi
    debug "Installing $tool_name from Git: $repo_url$version_display"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would clone/update repository: $repo_url${target_version:+@$target_version} -> $install_path"
        return 0
    fi
    
    # Clone ou update
    if [[ -d "$install_path/.git" ]]; then
        debug "Updating existing repository..."
        
        # Se temos uma versão específica, verificar se precisa atualizar
        if [[ -n "$target_version" ]]; then
            local current_version
            current_version=$(git -C "$install_path" describe --tags --exact-match 2>/dev/null || \
                             git -C "$install_path" rev-parse --short HEAD 2>/dev/null || echo "")
            
            # Buscar tags remotas (with lock)
            git_with_path_lock "$install_path" git -C "$install_path" fetch --tags --quiet >>"$LOG_FILE" 2>&1
            
            # Verificar se já está na versão correta (use -- to prevent tag injection)
            if [[ "$current_version" == "$target_version" ]] || \
               [[ "$(git -C "$install_path" rev-parse --verify --quiet HEAD 2>/dev/null)" == "$(git -C "$install_path" rev-parse --verify --quiet "${target_version}^{commit}" 2>/dev/null)" ]]; then
                debug "Already at version $target_version"
                save_to_cache "$cache_key" "$(date +%s)"
                # Verify repository integrity (non-blocking)
                verify_git_repository_integrity "$install_path" "$tool_name" "$target_version" || true
            else
                # Fazer checkout da versão específica (tentar múltiplos formatos, with lock)
                local checkout_success=0
                for checkout_method in "$target_version" "tags/$target_version" "refs/tags/$target_version"; do
                    # Use -- to prevent tag injection (tags starting with -)
                    if git_with_path_lock "$install_path" git -C "$install_path" checkout -q -- "$checkout_method" >>"$LOG_FILE" 2>&1; then
                        debug "Updated to version $target_version"
                        save_to_cache "$cache_key" "$(date +%s)"
                        checkout_success=1
                        # Verify repository integrity (non-blocking)
                        verify_git_repository_integrity "$install_path" "$tool_name" "$target_version" || true
                        break
                    fi
                done
                
                if [[ $checkout_success -eq 0 ]]; then
                    warning "Failed to checkout version $target_version, using default branch"
                    if git_with_path_lock "$install_path" git -C "$install_path" pull -q --ff-only >>"$LOG_FILE" 2>&1; then
                        # Verify repository integrity (non-blocking)
                        verify_git_repository_integrity "$install_path" "$tool_name" || true
                    fi
                fi
            fi
        else
            # Sem versão específica, usar pull normal (skip fetch --dry-run for performance, with lock)
            if git_with_path_lock "$install_path" git -C "$install_path" pull -q --ff-only >>"$LOG_FILE" 2>&1; then
                debug "Repository updated: $repo_name"
                save_to_cache "$cache_key" "$(date +%s)"
                # Verify repository integrity (non-blocking)
                verify_git_repository_integrity "$install_path" "$tool_name" || true
            else
                # Check if already up to date (pull returns 1 if no changes)
                # origin/HEAD may not exist in newly cloned repos or detached tags
                if git -C "$install_path" rev-parse --verify origin/HEAD >/dev/null 2>&1 && \
                   git -C "$install_path" diff --quiet HEAD origin/HEAD 2>/dev/null; then
                    debug "Repository already up to date: $repo_name"
                    save_to_cache "$cache_key" "$(date +%s)"
                    # Verify repository integrity (non-blocking)
                    verify_git_repository_integrity "$install_path" "$tool_name" || true
                else
                    warning "Failed to update $repo_name"
                    return 1
                fi
            fi
        fi
    else
        if [[ -d "$install_path" ]] && [[ ! -d "$install_path/.git" ]]; then
            debug "Directory exists but is not a Git repository, removing..."
            rm -rf "$install_path"
        fi
        
        debug "Cloning repository..."
        mkdir -p "$(dirname "$install_path")"
        
        # Se temos versão específica, tentar clonar direto no branch/tag (mais rápido, with lock)
        if [[ -n "$target_version" ]]; then
            # Try cloning directly to the tag/branch (fastest method)
            local clone_success=0
            # Tentar com --branch primeiro
            if git_with_path_lock "$install_path" git clone --filter=blob:none --depth 1 --branch "$target_version" -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                debug "Repository cloned: $repo_name (version $target_version)"
                clone_success=1
            elif git_with_path_lock "$install_path" git clone --filter=blob:none --depth 1 --branch "tags/$target_version" -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                debug "Repository cloned: $repo_name (version $target_version)"
                clone_success=1
            else
                # Fallback: clone shallow then checkout
                if git_with_path_lock "$install_path" git clone --filter=blob:none --depth 1 -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                    git_with_path_lock "$install_path" git -C "$install_path" fetch --tags --quiet >>"$LOG_FILE" 2>&1 || true
                    for checkout_method in "$target_version" "tags/$target_version" "refs/tags/$target_version"; do
                        if git_with_path_lock "$install_path" git -C "$install_path" checkout -q -- "$checkout_method" >>"$LOG_FILE" 2>&1; then
                            debug "Repository cloned: $repo_name (version $target_version)"
                            clone_success=1
                            break
                        fi
                    done
                fi
            fi
            
            if [[ $clone_success -eq 0 ]]; then
                # Last resort: full clone
                warning "Optimized clone failed for $target_version, trying full clone..."
                rm -rf "$install_path"
                if git_with_path_lock "$install_path" git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                    for checkout_method in "$target_version" "tags/$target_version" "refs/tags/$target_version"; do
                        if git_with_path_lock "$install_path" git -C "$install_path" checkout -q -- "$checkout_method" >>"$LOG_FILE" 2>&1; then
                            debug "Repository cloned: $repo_name (version $target_version)"
                            clone_success=1
                            break
                        fi
                    done
                    [[ $clone_success -eq 0 ]] && debug "Using default branch for $repo_name"
                else
                    error "Failed to clone $repo_name"
                    return 1
                fi
            fi
            
            save_to_cache "$cache_key" "$(date +%s)"
            # Verify repository integrity (non-blocking)
            verify_git_repository_integrity "$install_path" "$tool_name" "${target_version:-}" || true
        else
            # Sem versão específica, clonar shallow otimizado (with lock)
            if git_with_path_lock "$install_path" git clone --filter=blob:none --depth 1 -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                debug "Repository cloned: $repo_name"
                save_to_cache "$cache_key" "$(date +%s)"
                # Verify repository integrity (non-blocking)
                verify_git_repository_integrity "$install_path" "$tool_name" || true
            else
                # Verificar tipo de erro
                local git_error=""
                if grep -q "Authentication failed\|Username for\|Permission denied" "$LOG_FILE" 2>/dev/null; then
                    git_error="auth"
                elif grep -q "Repository not found\|404" "$LOG_FILE" 2>/dev/null; then
                    git_error="notfound"
                elif grep -q "fatal:" "$LOG_FILE" 2>/dev/null; then
                    git_error="fatal"
                fi
                
                # Fallback to full clone
                if [[ "$git_error" != "auth" ]] && [[ "$git_error" != "notfound" ]]; then
                    if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                        status_inline "Retrying $tool_name (full clone)..."
                    else
                        warning "Shallow clone failed, trying full clone..."
                    fi
                    if git_with_path_lock "$install_path" git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                        debug "Repository cloned: $repo_name"
                        save_to_cache "$cache_key" "$(date +%s)"
                        # Verify repository integrity (non-blocking)
                        verify_git_repository_integrity "$install_path" "$tool_name" || true
                    else
                        if [[ "$git_error" == "auth" ]]; then
                            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                                error_inline "Git auth failed for $repo_name"
                            else
                                error "Falha de autenticação ao clonar $repo_name"
                                error "Configure credenciais Git ou use SSH:"
                                error "  git remote set-url origin git@github.com:USER/REPO.git"
                            fi
                        elif [[ "$git_error" == "notfound" ]]; then
                            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                                error_inline "Repository not found: $repo_name"
                            else
                                error "Repositório não encontrado: $repo_url"
                            fi
                        else
                            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                                error_inline "Failed to clone $repo_name"
                            else
                                error "Failed to clone $repo_name"
                                error "Verifique os logs em: $LOG_FILE"
                            fi
                        fi
                        return 1
                    fi
                else
                    # Erro de autenticação ou repositório não encontrado
                    if [[ "$git_error" == "auth" ]]; then
                        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                            error_inline "Git auth failed for $repo_name"
                        else
                            error "Falha de autenticação ao clonar $repo_name"
                            error "Configure credenciais Git ou use SSH:"
                            error "  git remote set-url origin git@github.com:USER/REPO.git"
                        fi
                    else
                        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                            error_inline "Repository not found: $repo_name"
                        else
                            error "Repositório não encontrado: $repo_url"
                        fi
                    fi
                    return 1
                fi
            fi
        fi
    fi
    
    # Install Python dependencies
    if [[ -f "$install_path/requirements.txt" ]]; then
        debug "Installing Python dependencies..."
        if install_requirements_safe "$install_path/requirements.txt" "$tool_name"; then
            debug "Requirements.txt installed for $tool_name"
        else
            warning "Failed to install requirements.txt for $tool_name"
        fi
    fi
    
    # Install via setup.py
    if [[ -f "$install_path/setup.py" ]]; then
        debug "Running setup.py..."
        if (cd "$install_path" && python3 setup.py -q install) >>"$LOG_FILE" 2>&1; then
            debug "Setup.py executed for $tool_name"
        else
            warning "Failed to execute setup.py for $tool_name"
        fi
    fi
    
    # Create symbolic link
    if [[ -n "$script_name" ]]; then
        local script_path="$install_path/$script_name"
        if [[ -f "$script_path" ]]; then
            chmod +x "$script_path"
            local bin_name="${script_name##*/}"
            bin_name="${bin_name%.*}"
            ln -sf "$script_path" "$BIN_DIR/$bin_name"
            debug "Link created: $BIN_DIR/$bin_name -> $script_path"
        else
            warning "Script not found: $script_path"
        fi
    fi
    
    return 0
}

# Instalar via Go
install_with_go() {
    local go_package="$1"
    local tool_name="$2"
    
    debug "Installing $tool_name via Go: $go_package"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would install via Go: $go_package"
        return 0
    fi
    
    export GOPATH="$SRC_DIR/go"
    export GOBIN="$BIN_DIR"
    
    # Only add @latest if package doesn't already have a version specifier
    if [[ "$go_package" != *@* ]]; then
        go_package="${go_package}@latest"
    fi
    
    if install_go_tool_with_retry "$tool_name" "$go_package"; then
        debug "$tool_name installed via Go"
        validate_installation "$tool_name" "/usr/local/bin/$tool_name"
        return 0
    else
        error "Failed to install $tool_name via Go ($go_package)"
        return 1
    fi
}

# Install Rust tool via Cargo (from Git repository)
# Supports: standard projects, workspaces, subdirectories, multiple binaries
install_with_cargo() {
    local repo_url="$1"
    local tool_name="$2"
    local binary_name="${3:-$tool_name}"
    local build_dir="${4:-}"  # Optional: subdirectory with Cargo.toml
    
    debug "Installing $tool_name via Cargo from: $repo_url"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would install via Cargo: $repo_url"
        return 0
    fi
    
    # Check if cargo is installed, try to install if not
    # Add common cargo paths to PATH (for both regular user and root)
    export PATH="$HOME/.cargo/bin:/root/.cargo/bin:/usr/local/cargo/bin:/home/$SUDO_USER/.cargo/bin:$PATH"
    
    # First, try to find cargo in current PATH
    local cargo_found=0
    if command -v cargo &>/dev/null; then
        cargo_found=1
        debug "Cargo found in PATH: $(command -v cargo)"
    fi
    
    # If not found, search in common locations
    if [[ $cargo_found -eq 0 ]]; then
        for cargo_path in "/root/.cargo/bin/cargo" "$HOME/.cargo/bin/cargo" "/home/$SUDO_USER/.cargo/bin/cargo" "/usr/local/bin/cargo" "/usr/bin/cargo"; do
            if [[ -x "$cargo_path" ]]; then
                export PATH="$(dirname "$cargo_path"):$PATH"
                cargo_found=1
                debug "Cargo found at: $cargo_path"
                break
            fi
        done
    fi
    
    if [[ $cargo_found -eq 0 ]]; then
        warning "Cargo (Rust) is not installed. Attempting to install..."
        apt_update_once
        
        # Try to install rust via rustup (recommended) or apt
        if command -v curl &>/dev/null; then
            info "Installing Rust via rustup (recommended method)..."
            # Determine home directory (could be /root when running with sudo)
            local rust_home="${HOME:-/root}"
            
            if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >>"$LOG_FILE" 2>&1; then
                # Source cargo path for current and root user
                export PATH="$rust_home/.cargo/bin:/root/.cargo/bin:$PATH"
                
                # Verify cargo is now available
                if "$rust_home/.cargo/bin/cargo" --version &>/dev/null || command -v cargo &>/dev/null; then
                    success "Rust installed successfully via rustup"
                    # Use full path if command -v still doesn't find it
                    if ! command -v cargo &>/dev/null; then
                        export CARGO_BIN="$rust_home/.cargo/bin/cargo"
                    fi
                else
                    error "Rust installation completed but cargo not found in PATH"
                    return 1
                fi
            else
                warning "rustup installation failed, trying apt..."
            fi
        fi
        
        # Fallback to apt installation
        if ! command -v cargo &>/dev/null && [[ -z "${CARGO_BIN:-}" ]]; then
            info "Installing Rust via apt..."
            if apt_with_lock apt-get install -y -qq rustc cargo >>"$LOG_FILE" 2>&1; then
                export PATH="/usr/bin:/usr/local/bin:$PATH"
                if command -v cargo &>/dev/null; then
                    success "Rust installed successfully via apt"
                else
                    error "Rust installation completed but cargo not found. Please install Rust manually."
                    return 1
                fi
            else
                error "Failed to install Rust. Please install Rust manually: https://rustup.rs/"
                return 1
            fi
        fi
    fi
    
    # Use CARGO_BIN if set, otherwise use cargo from PATH
    local cargo_cmd="${CARGO_BIN:-cargo}"
    if ! command -v "$cargo_cmd" &>/dev/null && [[ -n "${CARGO_BIN:-}" ]]; then
        cargo_cmd="$CARGO_BIN"
    fi
    
    if ! command -v "$cargo_cmd" &>/dev/null && [[ ! -x "$cargo_cmd" ]]; then
        error "Cargo command not found: $cargo_cmd"
        return 1
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Clone repository
    if ! git clone --depth 1 "$repo_url" "$temp_dir" >>"$LOG_FILE" 2>&1; then
        error "Failed to clone $repo_url"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Determine build directory (handle subdirectories and workspaces)
    local cargo_dir="$temp_dir"
    if [[ -n "$build_dir" ]]; then
        cargo_dir="$temp_dir/$build_dir"
    elif [[ ! -f "$temp_dir/Cargo.toml" ]]; then
        # Try to find Cargo.toml in subdirectories
        local found_toml
        found_toml=$(find "$temp_dir" -maxdepth 2 -name "Cargo.toml" -type f 2>/dev/null | head -1)
        if [[ -n "$found_toml" ]]; then
            cargo_dir=$(dirname "$found_toml")
            debug "Found Cargo.toml in subdirectory: $cargo_dir"
        fi
    fi
    
    if [[ ! -f "$cargo_dir/Cargo.toml" ]]; then
        error "Cargo.toml not found in repository"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Try to detect binary name from Cargo.toml if not specified
    if [[ "$binary_name" == "$tool_name" ]]; then
        local detected_name
        detected_name=$(grep -m 1 "^name\s*=" "$cargo_dir/Cargo.toml" 2>/dev/null | sed 's/.*=\s*"\([^"]*\)".*/\1/' | tr -d '[:space:]')
        if [[ -n "$detected_name" ]]; then
            binary_name="$detected_name"
            debug "Detected binary name from Cargo.toml: $binary_name"
        fi
    fi
    
    # Build with cargo
    info "Building $tool_name with Cargo (this may take a while)..."
    
    # Get the original user who ran sudo (if applicable)
    local original_user="${SUDO_USER:-$USER}"
    local original_home
    if [[ -n "$original_user" ]] && [[ "$original_user" != "root" ]]; then
        original_home=$(getent passwd "$original_user" 2>/dev/null | cut -d: -f6)
    else
        original_home="$HOME"
    fi
    
    # Ensure PATH includes common cargo locations (for both root and original user)
    export PATH="$original_home/.cargo/bin:$HOME/.cargo/bin:/root/.cargo/bin:/usr/local/cargo/bin:/usr/bin:/usr/local/bin:$PATH"
    
    # Find cargo - try multiple methods
    local cargo_cmd=""
    
    # Method 1: Try command -v (uses PATH)
    if command -v cargo &>/dev/null; then
        cargo_cmd=$(command -v cargo)
        debug "Cargo found via PATH: $cargo_cmd"
    fi
    
    # Method 2: Try common paths directly (including original user's home)
    if [[ -z "$cargo_cmd" ]]; then
        for cargo_path in "$original_home/.cargo/bin/cargo" "/root/.cargo/bin/cargo" "$HOME/.cargo/bin/cargo" "/usr/local/bin/cargo" "/usr/bin/cargo"; do
            if [[ -x "$cargo_path" ]]; then
                cargo_cmd="$cargo_path"
                debug "Cargo found at: $cargo_cmd"
                break
            fi
        done
    fi
    
    # Method 3: Use CARGO_BIN if set
    if [[ -z "$cargo_cmd" ]] && [[ -n "${CARGO_BIN:-}" ]]; then
        cargo_cmd="$CARGO_BIN"
        debug "Using CARGO_BIN: $cargo_cmd"
    fi
    
    # Final verification
    if [[ -z "$cargo_cmd" ]] || [[ ! -x "$cargo_cmd" ]]; then
        error "Cargo command not found. Please install Rust: https://rustup.rs/"
        debug "Searched in: $original_home/.cargo/bin, $HOME/.cargo/bin, /root/.cargo/bin, /usr/bin, /usr/local/bin"
        debug "Original user: $original_user, Home: $original_home"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Verify cargo works
    if ! "$cargo_cmd" --version &>>"$LOG_FILE" 2>&1; then
        error "Cargo found but not working: $cargo_cmd"
        rm -rf "$temp_dir"
        return 1
    fi
    
    local cargo_version
    cargo_version=$("$cargo_cmd" --version 2>/dev/null | head -1)
    debug "Using cargo: $cargo_cmd ($cargo_version)"
    
    # Build command - use array to properly handle arguments
    local build_args=("build" "--release")
    
    # Check if we need to build a specific binary (for projects with multiple binaries)
    if "$cargo_cmd" metadata --no-deps --format-version 1 --manifest-path "$cargo_dir/Cargo.toml" 2>/dev/null | grep -q "\"$binary_name\""; then
        build_args+=("--bin" "$binary_name")
        debug "Building specific binary: $binary_name"
    fi
    
    # Execute cargo build
    if (cd "$cargo_dir" && "$cargo_cmd" "${build_args[@]}" >>"$LOG_FILE" 2>&1); then
        # Find the binary - try multiple strategies
        local built_binary=""
        
        # Strategy 1: Look for exact binary name
        built_binary=$(find "$cargo_dir/target/release" -type f -executable -name "$binary_name" 2>/dev/null | head -1)
        
        # Strategy 2: Look for tool_name (lowercase)
        if [[ -z "$built_binary" ]]; then
            built_binary=$(find "$cargo_dir/target/release" -type f -executable -name "${tool_name,,}" 2>/dev/null | head -1)
        fi
        
        # Strategy 3: Look for any executable matching the pattern
        if [[ -z "$built_binary" ]]; then
            built_binary=$(find "$cargo_dir/target/release" -type f -executable \( -name "*${tool_name}*" -o -name "*${binary_name}*" \) 2>/dev/null | head -1)
        fi
        
        # Strategy 4: Find any executable (last resort)
        if [[ -z "$built_binary" ]]; then
            built_binary=$(find "$cargo_dir/target/release" -type f -executable 2>/dev/null | grep -v ".so" | grep -v ".dylib" | head -1)
        fi
        
        if [[ -n "$built_binary" && -f "$built_binary" ]]; then
            local final_binary_name
            final_binary_name=$(basename "$built_binary")
            
            # Copy to bin directory
            cp "$built_binary" "$BIN_DIR/$final_binary_name" 2>/dev/null || {
                sudo cp "$built_binary" "$BIN_DIR/$final_binary_name" 2>/dev/null || {
                    error "Failed to copy binary to $BIN_DIR"
                    rm -rf "$temp_dir"
                    return 1
                }
            }
            chmod +x "$BIN_DIR/$final_binary_name"
            
            # Create symlink with tool_name if binary name is different
            if [[ "$final_binary_name" != "$tool_name" ]]; then
                ln -sf "$BIN_DIR/$final_binary_name" "$BIN_DIR/$tool_name" 2>/dev/null || {
                    sudo ln -sf "$BIN_DIR/$final_binary_name" "$BIN_DIR/$tool_name" 2>/dev/null || true
                }
            fi
            
            success "$tool_name built and installed successfully (binary: $final_binary_name)"
            rm -rf "$temp_dir"
            return 0
        else
            error "Built binary not found for $tool_name"
            debug "Searched in: $cargo_dir/target/release"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        error "Cargo build failed for $tool_name"
        debug "Check build logs in: $LOG_FILE"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Executar post_install
execute_post_install() {
    local commands="$1"
    local tool_name="$2"
    
    debug "Executing post-install commands for $tool_name"
    
    if ! validate_post_install "$commands" "$tool_name"; then
        error "Post-install commands rejected for security: $tool_name"
        return 1
    fi
    
    commands="${commands//\$installdir/$SRC_DIR}"
    commands="${commands//\$bindir/$BIN_DIR}"
    commands="${commands//\$srcdir/$SRC_DIR}"
    
    debug "post_install($tool_name): $commands"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would execute: $commands"
        return 0
    fi
    
    local safe_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    # Use a temporary script file to avoid quote escaping issues
    local temp_script
    temp_script=$(mktemp)
    echo "$commands" > "$temp_script"
    chmod +x "$temp_script"
    
    if env -i PATH="$safe_path" HOME="$HOME" USER="$USER" bash -euo pipefail "$temp_script" >>"$LOG_FILE" 2>&1; then
        rm -f "$temp_script"
        debug "Post-installation completed for $tool_name"
        return 0
    else
        rm -f "$temp_script"
        error "Post-installation failed for $tool_name"
        return 1
    fi
}

# Get binary names for tool
binary_names_for_tool() {
    local tool="$1"
    IFS='|' read -r _url script _deps _post <<< "${TOOLS_REGISTRY[$tool]}"
    
    local guess="$tool"
    if [[ -n "$script" ]]; then
        guess="${script##*/}"
        guess="${guess%.*}"
    fi
    
    printf '%s\n' "$tool" "$guess" | sort -u
}

# Check if tool is installed (using command cache + installation cache)
is_installed_tool() {
    local tool="$1"
    
    # NEW IMPROVEMENT: Check installation cache first (much faster)
    # Safe array access without modifying set -u
    if [[ ${INSTALLED_CACHE[$tool]+_} ]]; then
        # Cache hit! Return immediately (0.001s vs 0.1-0.5s)
        return "${INSTALLED_CACHE[$tool]}"
    fi
    
    # Cache miss: check for real
    local binary
    local found=0
    
    while IFS= read -r binary; do
        if cached_command_exists "$binary"; then
            found=1
            break
        fi
        if [[ -L "$BIN_DIR/$binary" ]] || [[ -x "$BIN_DIR/$binary" ]]; then
            found=1
            break
        fi
    done < <(binary_names_for_tool "$tool")
    
    # Save result to cache for next verifications
    if [[ $found -eq 1 ]]; then
        INSTALLED_CACHE[$tool]=0
        return 0
    else
        INSTALLED_CACHE[$tool]=1
        return 1
    fi
}

# Validate installation (using command cache)
validate_installation() {
    local tool_name="$1"
    local expected_path="${2:-/usr/local/bin/$tool_name}"
    
    if [[ -f "$expected_path" ]] || cached_command_exists "$tool_name"; then
        return 0
    fi
    
    local common_paths=(
        "/usr/local/bin"
        "$HOME/go/bin"
        "/root/go/bin"
        "$HOME/.local/bin"
        "/opt/$tool_name"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -f "$path/$tool_name" ]]; then
            ln -sf "$path/$tool_name" "/usr/local/bin/$tool_name" 2>/dev/null && return 0
        fi
    done
    
    return 1
}

# Install single tool (with health check and thread-safe arrays)
install_single_tool() {
    local tool_name="$1"
    local use_thread_safe="${2:-0}"  # Flag para usar arrays thread-safe em paralelo
    
    if [[ -z "${TOOLS_REGISTRY[$tool_name]:-}" ]]; then
        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
            warning_inline "Tool '$tool_name' not found"
        else
            warning "Tool '$tool_name' not found in registry"
        fi
        [[ $use_thread_safe -eq 1 ]] && add_to_failed "$tool_name"
        return 1
    fi
    
    if is_installed_tool "$tool_name"; then
        # Suprimir mensagens "already installed" em modo normal
        if [[ ${VERBOSE_MODE:-0} -eq 1 ]]; then
            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                status_inline "✓ $tool_name (já instalado)"
            else
                info "$tool_name already installed"
            fi
        else
            # Em modo normal, apenas contar (não mostrar)
            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                status_inline "✓ $tool_name (já instalado)"
            fi
        fi
        if [[ $use_thread_safe -eq 1 ]]; then
            add_to_skipped "$tool_name"
        else
            SKIPPED_TOOLS+=("$tool_name")
        fi
        return 0
    fi
    
    # Mostrar status na barra (modo inline) ou mensagem normal
    if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
        status_inline "Installing $tool_name..."
    else
        info "Installing $tool_name..."
    fi
    
    # Check disk space before installing
    if ! check_disk_space 500; then
        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
            error_inline "Insufficient space for $tool_name"
        else
            error "Insufficient space to install $tool_name"
        fi
        [[ $use_thread_safe -eq 1 ]] && add_to_failed "$tool_name"
        return 1
    fi
    
    IFS='|' read -r url script depends post_install <<< "${TOOLS_REGISTRY[$tool_name]}"
    
    local install_success=0
    
    # Dependencies are now installed in batch during two-phase install
    # Only install if not already done (for single tool installs or if batch failed)
    if [[ -n "$depends" ]]; then
        # Check if dependencies are already installed (from batch install)
        local deps_array
        IFS=',' read -ra deps_array <<< "$depends"
        local missing_deps=()
        
        for dep in "${deps_array[@]}"; do
            # Trim whitespace
            dep=$(echo "$dep" | xargs)
            
            if [[ -n "$dep" ]] && ! pkg_installed_apt "$dep"; then
                missing_deps+=("$dep")
            fi
        done
        
        # Only install missing dependencies (should be rare after batch install)
        # Use lock to prevent parallel conflicts
        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            debug "Installing missing dependencies: ${missing_deps[*]}"
            apt_update_once
            if ! apt_with_lock apt-get install -y -qq --no-install-recommends "${missing_deps[@]}" >>"$LOG_FILE" 2>&1; then
                warning "Failed to install some dependencies: ${missing_deps[*]}"
            fi
        fi
    fi
    
    # Install tool
    # Check if post_install is cargo build first (skip normal git install)
    local is_cargo_build=0
    if [[ -n "$post_install" ]] && [[ "$post_install" =~ cargo[[:space:]]+build ]]; then
        is_cargo_build=1
        debug "Detected Cargo build for $tool_name"
    fi
    
    if [[ -n "$url" ]] && [[ $is_cargo_build -eq 0 ]]; then
        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
            status_inline "Cloning $tool_name..."
        fi
        install_from_git "$url" "$script" "$tool_name" && install_success=1
    fi
    
    if [[ -n "$post_install" ]]; then
        if [[ "$post_install" =~ go[[:space:]]install ]]; then
            # Extract Go package from post_install command
            # Remove "go install" prefix
            local go_pkg="${post_install#*go install }"
            # Remove leading/trailing whitespace
            go_pkg=$(echo "$go_pkg" | xargs)
            # Remove common Go flags (-v, -x, -race, etc.) from the beginning
            while [[ "$go_pkg" =~ ^-[a-zA-Z]+[[:space:]] ]]; do
                go_pkg="${go_pkg#*-[a-zA-Z]*[[:space:]]}"
                go_pkg=$(echo "$go_pkg" | xargs)
            done
            # Extract the package path (everything until space or end)
            # Package paths typically don't have spaces, but handle @version
            go_pkg=$(echo "$go_pkg" | awk '{print $1}')
            debug "Extracted Go package: $go_pkg"
            if [[ -z "$go_pkg" ]] || [[ "$go_pkg" =~ ^- ]]; then
                if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                    error_inline "Failed to extract Go package"
                else
                    error "Failed to extract Go package from: $post_install"
                fi
                return 1
            fi
            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                status_inline "Building $tool_name (Go)..."
            fi
            install_with_go "$go_pkg" "$tool_name" && install_success=1
        elif [[ "$post_install" =~ cargo[[:space:]]+build ]]; then
            # Detect cargo build - install from Git URL if available
            debug "Processing Cargo build for $tool_name"
            if [[ -n "$url" ]]; then
                if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                    status_inline "Building $tool_name (Rust)..."
                fi
                install_with_cargo "$url" "$tool_name" && install_success=1
            else
                if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                    error_inline "Cargo build: no Git URL"
                else
                    error "Cargo build requested but no Git URL provided for $tool_name"
                fi
            fi
        else
            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                status_inline "Configuring $tool_name..."
            fi
            execute_post_install "$post_install" "$tool_name" && install_success=1
        fi
    fi
    
    if [[ -z "$url" && -z "$post_install" ]]; then
        debug "Tentando instalar $tool_name via APT"
        apt_update_once
        if apt_with_lock apt-get install -y -qq "$tool_name" >>"$LOG_FILE" 2>&1; then
            install_success=1
        fi
    fi
    
    # Post-installation health check
    if [[ $install_success -eq 1 ]]; then
        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
            status_inline "Verifying $tool_name..."
        fi
        if health_check_tool "$tool_name"; then
            TOOLS_STATUS["$tool_name"]="installed"
            if [[ $use_thread_safe -eq 1 ]]; then
                add_to_installed "$tool_name"
            else
                INSTALLED_TOOLS+=("$tool_name")
            fi
            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                success_inline "$tool_name installed"
            else
                success "✓ $tool_name installed successfully"
            fi
            return 0
        else
            # Consider as installed anyway (may be PATH issue)
            TOOLS_STATUS["$tool_name"]="installed"
            if [[ $use_thread_safe -eq 1 ]]; then
                add_to_installed "$tool_name"
            else
                INSTALLED_TOOLS+=("$tool_name")
            fi
            if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
                warning_inline "$tool_name installed (health check failed)"
            else
                warning "Tool $tool_name installed but did not pass health check"
                success "✓ $tool_name installed successfully"
            fi
            return 0
        fi
    else
        TOOLS_STATUS["$tool_name"]="failed"
        if [[ $use_thread_safe -eq 1 ]]; then
            add_to_failed "$tool_name"
        else
            FAILED_TOOLS+=("$tool_name")
        fi
        if [[ ${INLINE_MODE:-0} -eq 1 ]]; then
            error_inline "Failed to install $tool_name"
        else
            error "Failed to install $tool_name"
        fi
        return 1
    fi
}

# Performance timing helper
time_tool() {
    local name="$1"
    shift
    local t0=$(date +%s)
    "$@"
    local rc=$?
    local t1=$(date +%s)
    local duration=$((t1 - t0))
    local cache_root="${CACHE_DIR:-${WORK_DIR:-/tmp}/cache}"
    local timings_file="${cache_root}/timings.jsonl"
    mkdir -p "$(dirname "$timings_file")"
    # Use lock for thread-safe writing (even in serial mode for consistency)
    local lock_file="/tmp/secbuild_timings.lock"
    local json_line="{\"tool\":\"$name\",\"cmd\":\"$*\",\"rc\":$rc,\"sec\":$duration,\"ts\":$(date +%s)}"
    # Use printf with argumentos posicionais to avoid shell injection
    with_lock "$lock_file" bash -c 'printf "%s\n" "$1" >> "$2"' _ "$json_line" "$timings_file" 2>/dev/null || true
    return $rc
}

# Collect all APT dependencies from all tools (two-phase install optimization)
collect_all_apt_dependencies() {
    declare -A all_deps=()
    
    info "Collecting all APT dependencies..."
    
    for tool_name in "${!TOOLS_REGISTRY[@]}"; do
        IFS='|' read -r _url _script depends _post <<< "${TOOLS_REGISTRY[$tool_name]:-}"
        
        if [[ -n "$depends" ]]; then
            # Split dependencies by comma
            IFS=',' read -ra deps_array <<< "$depends"
            for dep in "${deps_array[@]}"; do
                # Trim whitespace
                dep=$(echo "$dep" | xargs)
                if [[ -n "$dep" ]]; then
                    all_deps["$dep"]=1
                fi
            done
        fi
    done
    
    # Convert to array
    local deps_list=()
    for dep in "${!all_deps[@]}"; do
        deps_list+=("$dep")
    done
    
    echo "${deps_list[@]}"
}

# APT operations with lock to prevent parallel conflicts
apt_with_lock() {
    local lock_file="/tmp/secbuild_apt.lock"
    with_lock "$lock_file" "$@"
}

# Install all APT dependencies in batch (two-phase install: Phase A)
# Install in chunks to avoid command length limits
install_all_apt_dependencies() {
    local deps_list
    deps_list=($(collect_all_apt_dependencies))
    
    if [[ ${#deps_list[@]} -eq 0 ]]; then
        debug "No APT dependencies to install"
        return 0
    fi
    
    info "Installing ${#deps_list[@]} APT dependencies in batch..."
    apt_update_once
    
    # Install in chunks of 50 packages to avoid command length limits
    local chunk_size=50
    local total=${#deps_list[@]}
    local installed=0
    local failed=0
    
    for ((i=0; i<total; i+=chunk_size)); do
        local chunk=("${deps_list[@]:i:chunk_size}")
        local chunk_num=$((i/chunk_size + 1))
        local total_chunks=$(( (total + chunk_size - 1) / chunk_size ))
        
        debug "Installing chunk $chunk_num/$total_chunks (${#chunk[@]} packages)..."
        
        if apt_with_lock apt-get install -y -qq --no-install-recommends "${chunk[@]}" >>"$LOG_FILE" 2>&1; then
            ((installed += ${#chunk[@]}))
        else
            ((failed += ${#chunk[@]}))
            warning "Failed to install chunk $chunk_num"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        success "All APT dependencies installed successfully ($installed packages)"
        return 0
    else
        warning "Some APT dependencies failed to install ($failed failed, $installed installed)"
        return 1
    fi
}

# Install all tools
install_all_tools() {
    info "Starting installation of all tools..."
    
    # Ativar modo inline para manter barra única
    export INLINE_MODE=1
    
    # Register start time
    export START_TIME=$(date +%s)
    
    # TWO-PHASE INSTALL: Phase A - Install all APT dependencies in batch
    if [[ $DRY_RUN -eq 0 ]]; then
        status_inline "Installing dependencies..."
        install_all_apt_dependencies || warning "Some dependencies may need manual installation"
    fi
    
    local tools_array=()
    for tool in "${!TOOLS_REGISTRY[@]}"; do
        tools_array+=("$tool")
    done
    
    if [[ $PARALLEL_INSTALL -eq 1 ]]; then
        install_tools_parallel "${tools_array[@]}"
    else
        local total=${#tools_array[@]}
        local current=0
        
        # Mostrar barra inicial
        show_progress 0 "$total" "Starting..."
        
        for tool in "${tools_array[@]}"; do
            ((current++))
            show_progress "$current" "$total" "$tool"
            time_tool "$tool" install_single_tool "$tool" || true
            # Atualizar barra após cada instalação
            show_progress "$current" "$total" "$tool"
        done
        
        # Limpar linha de progresso no final
        clear_progress_line
        echo  # Nova linha após limpar
    fi
    
    # Desativar modo inline
    export INLINE_MODE=0
    
    # Coletar métricas
    collect_metrics
    
    print_installation_summary
}

# Parallel installation (with wait -n and thread-safe arrays)
install_tools_parallel() {
    # CRITICAL: Ensure PARENT_PID is set and exported before any background jobs
    : "${PARENT_PID:=$$}"
    export PARENT_PID
    
    local tools=("$@")
    local total=${#tools[@]}
    local current=0
    local running=0
    local max_jobs=$MAX_PARALLEL_JOBS
    declare -a pids=()
    declare -A pid_to_tool=()
    
    # Check if Bash supports wait -n (Bash 4.3+)
    local supports_wait_n=0
    if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
        local minor_version="${BASH_VERSION#*.}"
        minor_version="${minor_version%%.*}"
        if [[ $minor_version -ge 3 ]]; then
            supports_wait_n=1
        fi
    fi
    
    info "Installing $total tools in parallel (max: $max_jobs jobs)"
    
    for tool in "${tools[@]}"; do
        # Wait for available slot
        while [[ $running -ge $max_jobs ]]; do
            if [[ $supports_wait_n -eq 1 ]]; then
                # Use wait -n (more efficient, Bash 4.3+)
                # Note: -p is only available in Bash 5.1+, so we use polling
                # but more efficient than the old method
                local found=0
                for pid in "${pids[@]}"; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        local finished_tool="${pid_to_tool[$pid]}"
                        wait "$pid"
                        local exit_code=$?
                        
                        if [[ $exit_code -eq 0 ]]; then
                            success "✓ $finished_tool completed"
                        else
                            error "✗ $finished_tool failed"
                        fi
                        
                        # Remover PID do array
                        local new_pids=()
                        for p in "${pids[@]}"; do
                            [[ "$p" != "$pid" ]] && new_pids+=("$p")
                        done
                        pids=("${new_pids[@]}")
                        unset pid_to_tool[$pid]
                        ((running--))
                        ((current++))
                        show_progress "$current" "$total" "$(t 'install.progress' '...')"
                        found=1
                        break
                    fi
                done
                [[ $found -eq 0 ]] && sleep 0.1
            else
                # Fallback: polling with kill -0
                for pid in "${pids[@]}"; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        local finished_tool="${pid_to_tool[$pid]}"
                        wait "$pid"
                        local exit_code=$?
                        
                        if [[ $exit_code -eq 0 ]]; then
                            success "✓ $finished_tool completed"
                        else
                            error "✗ $finished_tool failed"
                        fi
                        
                        # Remover PID do array
                        local new_pids=()
                        for p in "${pids[@]}"; do
                            [[ "$p" != "$pid" ]] && new_pids+=("$p")
                        done
                        pids=("${new_pids[@]}")
                        unset pid_to_tool[$pid]
                        ((running--))
                        ((current++))
                        show_progress "$current" "$total" "$(t 'install.progress' '...')"
                        break
                    fi
                done
                sleep 0.5
            fi
        done
        
        # Start installation in background (with thread-safe flag and timing)
        (
            local t0=$(date +%s)
            install_single_tool "$tool" 1 >/dev/null 2>&1
            local rc=$?
            local t1=$(date +%s)
            local duration=$((t1 - t0))
            local cache_root="${CACHE_DIR:-${WORK_DIR:-/tmp}/cache}"
    local timings_file="${cache_root}/timings.jsonl"
            mkdir -p "$(dirname "$timings_file")"
            # Use lock for thread-safe writing
            local lock_file="/tmp/secbuild_timings.lock"
            local json_line="{\"tool\":\"$tool\",\"rc\":$rc,\"sec\":$duration,\"ts\":$(date +%s)}"
            # Use printf with argumentos posicionais to avoid shell injection
            with_lock "$lock_file" bash -c 'printf "%s\n" "$1" >> "$2"' _ "$json_line" "$timings_file" 2>/dev/null || true
            exit $rc
        ) &
        
        local pid=$!
        pids+=("$pid")
        pid_to_tool[$pid]="$tool"
        ((running++))
        
        debug "Started: $tool (PID: $pid)"
    done
    
    # Wait for all remaining processes
    for pid in "${pids[@]}"; do
        local finished_tool="${pid_to_tool[$pid]}"
        wait "$pid"
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            success "✓ $finished_tool completed"
        else
            error "✗ $finished_tool failed"
        fi
        
        ((current++))
        show_progress "$current" "$total" "$(t 'install.progress' '...')"
    done
    
    # Consolidate results from temporary files
    consolidate_parallel_results
    
    echo
}

# Instalar perfil
install_profile() {
    local profile="$1"
    profile="${profile,,}"
    
    if [[ -z "$profile" ]]; then
        error "Invalid profile!"
        return 1
    fi
    
    info "Installing profile: $profile"
    
    # Ativar modo inline para manter barra única
    export INLINE_MODE=1
    export START_TIME=$(date +%s)
    
    # Verificar se o perfil existe (safe array access)
    local tools=""
    if [[ ${PROFILE_TOOLS[$profile]+_} ]]; then
        tools="${PROFILE_TOOLS[$profile]}"
    fi
    
    if [[ -z "$tools" ]]; then
        export INLINE_MODE=0
        error "Profile '$profile' not found"
        echo
        info "Available profiles:"
        for p in "${!PROFILE_TOOLS[@]}"; do
            echo "  - $p"
        done
        return 1
    fi
    
    # Converter string de ferramentas em array
    local tool_array=()
    read -ra tool_array <<< "$tools"
    
    if [[ ${#tool_array[@]} -eq 0 ]]; then
        export INLINE_MODE=0
        error "Profile '$profile' not found"
        return 1
    fi
    
    info "Tools in profile '$profile': ${#tool_array[@]}"
    echo
    
    # Show tools that will be installed
    if [[ ${VERBOSE_MODE:-0} -eq 1 ]]; then
        echo -e "${CYAN}Tools in profile '$profile':${RESET}"
        for tool in "${tool_array[@]}"; do
            echo "  • $tool"
        done
        echo
    fi
    
    # Install tools
    local installed=0
    local failed=0
    
    if [[ ${PARALLEL_INSTALL:-0} -eq 1 ]]; then
        install_tools_parallel "${tool_array[@]}"
    else
        local total=${#tool_array[@]}
        local current=0
        
        # Mostrar barra inicial
        show_progress 0 "$total" "Starting..."
        
        for tool in "${tool_array[@]}"; do
            ((current++))
            show_progress "$current" "$total" "$tool"
            if install_single_tool "$tool"; then
                ((installed++))
            else
                ((failed++))
            fi
            show_progress "$current" "$total" "$tool"
        done
        
        # Limpar linha de progresso
        clear_progress_line
        echo
    fi
    
    # Desativar modo inline
    export INLINE_MODE=0
    
    print_installation_summary
    
    if [[ $installed -gt 0 ]]; then
        success "Profile '$profile' processed: $installed installed, $failed failed"
    fi
}

# Obter ferramentas por perfil
get_tools_by_profile() {
    local profile="$1"
    profile="${profile,,}"
    
    if [[ -z "$profile" ]]; then
        return 1
    fi
    
    # Verificar se o perfil existe (safe array access)
    local tools=""
    if [[ ${PROFILE_TOOLS[$profile]+_} ]]; then
        tools="${PROFILE_TOOLS[$profile]}"
    fi
    
    if [[ -z "$tools" ]]; then
        return 1
    fi
    
    echo "$tools"
}

# Listar perfis
list_profiles() {
    echo -e "${CYAN}$(t 'profile.available')${RESET}"
    echo
    
    # Safe array access
    local profile_count=0
    if [[ ${#PROFILE_TOOLS[@]} -gt 0 ]]; then
        profile_count=${#PROFILE_TOOLS[@]}
    fi
    
    if [[ $profile_count -eq 0 ]]; then
        warning "No profiles configured"
        return 0
    fi
    
    # Ordenar perfis alfabeticamente
    local sorted_profiles
    sorted_profiles=$(printf '%s\n' "${!PROFILE_TOOLS[@]}" | sort)
    
    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        
        local tool_list=""
        if [[ ${PROFILE_TOOLS[$profile]+_} ]]; then
            tool_list="${PROFILE_TOOLS[$profile]}"
        fi
        local tool_count
        tool_count=$(echo "$tool_list" | wc -w)
        
        echo -e "  ${GREEN}$profile${RESET} - ${YELLOW}$tool_count${RESET} tool(s)"
    done <<< "$sorted_profiles"
}

# Verificar pacote instalado (APT)
pkg_installed_apt() {
    local package="$1"
    
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
        return 0
    fi
    
    if command -v "$package" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Instalar dependências principais
install_core_dependencies() {
    info "Installing core system dependencies..."
    
    # Pacotes básicos essenciais
    local core_deps=(
        "curl" "wget" "git" "build-essential" "python3" "python3-pip"
        "golang-go" "cargo" "cmake" "jq" "dialog" "bc" "realpath"
    )
    
    # Adicionar pacotes do tools_config.yaml se disponível
    if [[ ${#YAML_ESSENTIAL_PACKAGES[@]} -gt 0 ]]; then
        debug "Adding ${#YAML_ESSENTIAL_PACKAGES[@]} packages from tools_config.yaml"
        for yaml_pkg in "${YAML_ESSENTIAL_PACKAGES[@]}"; do
            # Evitar duplicatas
            local found=0
            for core_dep in "${core_deps[@]}"; do
                if [[ "$core_dep" == "$yaml_pkg" ]]; then
                    found=1
                    break
                fi
            done
            [[ $found -eq 0 ]] && core_deps+=("$yaml_pkg")
        done
    fi
    
    apt_update_once
    
    # Filter out already installed packages
    local missing_deps=()
    for dep in "${core_deps[@]}"; do
        if ! pkg_installed_apt "$dep"; then
            missing_deps+=("$dep")
        else
            debug "$dep already installed"
        fi
    done
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        success "All core dependencies already installed"
        return 0
    fi
    
    info "Installing ${#missing_deps[@]} core dependencies in batch..."
    
    # Install all missing core deps in batch (with lock)
    if apt_with_lock apt-get install -y -qq --no-install-recommends "${missing_deps[@]}" >>"$LOG_FILE" 2>&1; then
        success "Core dependencies installed successfully"
        return 0
    else
        warning "Some core dependencies failed to install"
        return 1
    fi
}

# Install vendor tools
install_vendor_tools() {
    info "Downloading auxiliary tools..."
    
    if [[ ! -d "$VENDOR_DIR/progressbar" ]]; then
        info "Installing progressbar..."
        if git clone -q "$PROGRESSBAR_URL" "$VENDOR_DIR/progressbar" >>"$LOG_FILE" 2>&1; then
            debug "Progressbar installed"
        else
            warning "Failed to install progressbar"
        fi
    fi
    
    if [[ ! -d "$VENDOR_DIR/bash-ini-parser" ]]; then
        info "Installing bash-ini-parser..."
        if git clone -q "$INI_PARSER_URL" "$VENDOR_DIR/bash-ini-parser" >>"$LOG_FILE" 2>&1; then
            debug "Bash-ini-parser installed"
        else
            warning "Failed to install bash-ini-parser"
        fi
    fi
    
    if [[ -f "$VENDOR_DIR/bash-ini-parser/bash-ini-parser" ]]; then
        source "$VENDOR_DIR/bash-ini-parser/bash-ini-parser"
        success "Auxiliary tools installed"
    else
        warning "Bash-ini-parser not found, using manual parser"
    fi
}

# Otimização APT update
apt_update_once() {
    if [[ $APT_UPDATE_DONE -eq 1 ]]; then
        debug "APT update já foi executado nesta sessão"
        return 0
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would execute: apt-get update"
        APT_UPDATE_DONE=1
        return 0
    fi
    
    info "Updating APT repositories..."
    # Use lock to prevent conflicts with parallel installs
    if apt_with_lock apt-get update -qq >>"$ERROR_LOG" 2>&1; then
        APT_UPDATE_DONE=1
        success "APT repositories updated"
        return 0
    else
        warning "Failed to update repositories"
        return 1
    fi
}

# Modo dry-run (seguro, sem eval)
dry_run_exec() {
    local cmd="$*"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "Would execute: $cmd"
        return 0
    fi
    
    # Validate command before executing (block dangerous commands)
    if [[ "$cmd" =~ (rm\s+-rf\s+/|format\s+|mkfs|dd\s+if=.*of=/dev/|mkfs\.|fdisk\s+/dev/) ]]; then
        error "Dangerous command blocked for security: $cmd"
        return 1
    fi
    
    # Executar de forma segura usando bash -c
    if bash -c "$cmd" >>"$LOG_FILE" 2>&1; then
        return 0
    else
        return $?
    fi
}

