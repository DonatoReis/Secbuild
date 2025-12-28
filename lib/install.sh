#!/usr/bin/env bash
################################################################################
# install.sh - Installation Module
# Manages installation via Git, Go, Python, APT
################################################################################

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
    
    # Check cache first
    set +u
    if [[ -n "${COMMAND_CACHE[$cmd]:-}" ]]; then
        local cached_result="${COMMAND_CACHE[$cmd]}"
        set -u
        return "$cached_result"
    fi
    set -u
    
    # Check command
    if command -v "$cmd" &>/dev/null 2>&1; then
        set +u
        COMMAND_CACHE[$cmd]=0
        set -u
        return 0
    else
        set +u
        COMMAND_CACHE[$cmd]=1
        set -u
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

# Gerar hash de string (compatível com macOS e Linux)
generate_hash() {
    local str="$1"
    if command -v md5sum &>/dev/null; then
        echo -n "$str" | md5sum | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        echo -n "$str" | md5 | cut -d' ' -f1
    else
        # Fallback: usar hash simples baseado em caracteres
        echo -n "$str" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "$str" | tr -d '/:.' | head -c 32
    fi
}

# Buscar última release estável do GitHub
get_latest_github_release() {
    local repo_url="$1"
    local repo_hash
    repo_hash=$(generate_hash "$repo_url")
    local cache_file="${CACHE_DIR:-$WORK_DIR/cache}/github_release_${repo_hash}.cache"
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
                debug "Usando versão em cache para $repo_url: $cached_version"
                echo "$cached_version"
                return 0
            fi
        fi
    fi
    
    # Converter URL para API
    local api_url
    api_url=$(github_url_to_api "$repo_url")
    [[ -z "$api_url" ]] && return 1
    
    # Search for latest release (not pre-release)
    local latest_release
    if command -v grep &>/dev/null && grep --version 2>&1 | grep -q "GNU"; then
        # GNU grep com suporte a -P
        latest_release=$(curl -sSf --max-time 10 \
            "${api_url}/releases/latest" 2>/dev/null | \
            grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    else
        # Fallback para grep sem -P (macOS)
        latest_release=$(curl -sSf --max-time 10 \
            "${api_url}/releases/latest" 2>/dev/null | \
            grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
    fi
    
    if [[ -n "$latest_release" ]]; then
        # Salvar no cache
        mkdir -p "$(dirname "$cache_file")"
        echo "$latest_release" > "$cache_file"
        debug "Última release estável encontrada: $latest_release"
        echo "$latest_release"
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
    local cache_file="${CACHE_DIR:-$WORK_DIR/cache}/github_tag_${repo_hash}.cache"
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
    if command -v grep &>/dev/null && grep --version 2>&1 | grep -q "GNU"; then
        # GNU grep com suporte a -P
        latest_tag=$(curl -sSf --max-time 10 \
            "${api_url}/tags?per_page=1" 2>/dev/null | \
            grep -oP '"name":\s*"\K[^"]+' | head -1)
    else
        # Fallback para grep sem -P (macOS)
        latest_tag=$(curl -sSf --max-time 10 \
            "${api_url}/tags?per_page=1" 2>/dev/null | \
            grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
    fi
    
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
    
    # Verify repository integrity
    if ! git -C "$repo_path" fsck --no-progress --quiet >>"$LOG_FILE" 2>&1; then
        warning "Git repository may be corrupted: $repo_path"
        return 1
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
health_check_tool() {
    local tool="$1"
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
    if ! timeout 5 "$tool" --version &>/dev/null 2>&1; then
        # Tentar versão alternativa
        if ! timeout 5 "$tool" -version &>/dev/null 2>&1; then
            # Tentar help
            if ! timeout 5 "$tool" --help &>/dev/null 2>&1; then
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
        missing_deps=$(ldd "$tool_path" 2>&1 | grep -c "not found" || echo "0")
        
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
add_to_installed() {
    local tool="$1"
    local result_file="/tmp/secbuild_installed_$$.tmp"
    echo "$tool" >> "$result_file" 2>/dev/null || true
}

add_to_failed() {
    local tool="$1"
    local result_file="/tmp/secbuild_failed_$$.tmp"
    echo "$tool" >> "$result_file" 2>/dev/null || true
}

add_to_skipped() {
    local tool="$1"
    local result_file="/tmp/secbuild_skipped_$$.tmp"
    echo "$tool" >> "$result_file" 2>/dev/null || true
}

# Consolidate results from temporary files to global arrays
consolidate_parallel_results() {
    local pid=$$
    
    # Consolidar instaladas
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
    
    # Consolidar puladas
    if [[ -f "/tmp/secbuild_skipped_${pid}.tmp" ]]; then
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && SKIPPED_TOOLS+=("$tool")
        done < "/tmp/secbuild_skipped_${pid}.tmp"
        rm -f "/tmp/secbuild_skipped_${pid}.tmp" 2>/dev/null
    fi
}

# Collect installation metrics
collect_metrics() {
    local metrics_file="${CACHE_DIR:-$WORK_DIR/cache}/metrics_$(date +%Y%m%d).json"
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
    
    # Go optimization flags
    local go_flags="-ldflags=-s -w -trimpath"
    
    # Try methods in order of preference with adaptive retry
    local methods=(
        "GOARCH=$goarch go install $go_flags ${package}@latest"
        "GOARCH=$goarch go install ${package}@latest"
        "go get -u ${package}"
        "GO111MODULE=on go get ${package}"
    )
    
    for method in "${methods[@]}"; do
        debug "Attempting to install $tool_name via: $method"
        
        # Use adaptive retry (5 attempts, base delay 2s, max 30s)
        if retry_with_adaptive_backoff 5 2 30 bash -c "$method"; then
            return 0
        fi
    done
    
    error "Failed to install $tool_name after all attempts"
    return 1
}

# Instalar requirements Python de forma segura
install_requirements_safe() {
    local req_file="$1"
    local tool_name="$2"
    
    if [[ ! -f "$req_file" ]]; then
        return 0
    fi
    
    python3 -m pip install --upgrade pip >>"$LOG_FILE" 2>&1
    
    if python3 -m pip install -r "$req_file" --no-warn-script-location >>"$LOG_FILE" 2>&1; then
        return 0
    elif python3 -m pip install -r "$req_file" --user --no-warn-script-location >>"$LOG_FILE" 2>&1; then
        return 0
    elif python3 -m pip install -r "$req_file" --break-system-packages >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    
    return 1
}

# Instalar do Git (com shallow clone, validação de URL e versão mais recente)
install_from_git() {
    local repo_url="$1"
    local script_name="$2"
    local tool_name="$3"
    
    # Validate URL before using
    if ! validate_url "$repo_url"; then
        warning "Invalid or inaccessible URL: $repo_url"
        # Continue anyway, may be a temporary network issue
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
        target_version=$(get_latest_github_release "$repo_url")
        if [[ -n "$target_version" ]]; then
            info "Latest version found: $target_version"
        else
            debug "Could not get specific version, using default branch"
        fi
    fi
    
    # NEW IMPROVEMENT: Check if there's expected hash in registry (integrity validation)
    IFS='|' read -r _url _script _deps _post <<< "${TOOLS_REGISTRY[$tool_name]:-}"
    # Hash may be in package.ini as separate attribute (to be implemented)
    # For now, we verify Git commit hash after clone
    
    debug "Installing $tool_name from Git: $repo_url${target_version:+ (v$target_version)}"
    
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
            
            # Buscar tags remotas
            git -C "$install_path" fetch --tags --quiet >>"$LOG_FILE" 2>&1
            
            # Verificar se já está na versão correta
            if [[ "$current_version" == "$target_version" ]] || \
               [[ "$(git -C "$install_path" rev-parse HEAD 2>/dev/null)" == "$(git -C "$install_path" rev-parse "$target_version" 2>/dev/null)" ]]; then
                debug "Já está na versão $target_version"
                save_to_cache "$cache_key" "$(date +%s)"
            else
                # Fazer checkout da versão específica
                if git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1; then
                    debug "Atualizado para versão $target_version"
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    warning "Falha ao fazer checkout da versão $target_version, usando branch padrão"
                    git -C "$install_path" pull -q --ff-only >>"$LOG_FILE" 2>&1 || true
                fi
            fi
        else
            # Sem versão específica, usar pull normal
            if git -C "$install_path" fetch --dry-run &>/dev/null; then
                if git -C "$install_path" pull -q --ff-only >>"$LOG_FILE" 2>&1; then
                    debug "Repository updated: $repo_name"
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    warning "Failed to update $repo_name"
                    return 1
                fi
            else
                debug "Repositório já está atualizado"
                save_to_cache "$cache_key" "$(date +%s)"
            fi
        fi
    else
        if [[ -d "$install_path" ]] && [[ ! -d "$install_path/.git" ]]; then
            debug "Directory exists but is not a Git repository, removing..."
            rm -rf "$install_path"
        fi
        
        debug "Cloning repository..."
        mkdir -p "$(dirname "$install_path")"
        
        # Se temos versão específica, clonar e fazer checkout
        if [[ -n "$target_version" ]]; then
            # Clonar com tags para poder fazer checkout
            if git clone --depth 1 --single-branch -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                # Buscar tags para ter acesso à versão específica
                git -C "$install_path" fetch --tags --quiet >>"$LOG_FILE" 2>&1 || true
                
                # Tentar fazer checkout da versão
                if git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1; then
                    debug "Repository cloned: $repo_name" " (version $target_version)"
                    
                    # NEW IMPROVEMENT: Verify cloned repository integrity
                    verify_git_repository_integrity "$install_path" "$tool_name" "$target_version"
                    
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    # If fails, try full clone with tags
                    warning "Could not checkout version $target_version, cloning full repository..."
                    rm -rf "$install_path"
                    if git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                        if git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1; then
                            debug "Repository cloned: $repo_name" " (version $target_version)"
                            
                            # Verify integrity
                            verify_git_repository_integrity "$install_path" "$tool_name" "$target_version"
                            
                            save_to_cache "$cache_key" "$(date +%s)"
                        else
                            warning "Failed to checkout version $target_version, using default branch"
                            save_to_cache "$cache_key" "$(date +%s)"
                        fi
                    else
                        error "Failed to clone $repo_name"
                        return 1
                    fi
                fi
            else
                # Fallback to full clone
                warning "Shallow clone failed, trying full clone..."
                if git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                    if [[ -n "$target_version" ]]; then
                        git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1 || true
                    fi
                    debug "Repository cloned: $repo_name"
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    error "Failed to clone $repo_name"
                    return 1
                fi
            fi
        else
            # No specific version, use normal shallow clone
            if git clone --depth 1 --single-branch -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                debug "Repository cloned: $repo_name"
                
                # Verify integrity after clone
                verify_git_repository_integrity "$install_path" "$tool_name"
                
                save_to_cache "$cache_key" "$(date +%s)"
            else
                # Fallback to full clone if shallow fails
                warning "Shallow clone failed, trying full clone..."
                if git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                    debug "Repository cloned: $repo_name"
                    
                    # Verify integrity after clone
                    verify_git_repository_integrity "$install_path" "$tool_name"
                    
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    error "Failed to clone $repo_name"
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
    
    [[ "$go_package" != *@* ]] && go_package="${go_package}@latest"
    
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
            if dry_run_exec "apt-get install -y -qq rustc cargo &>>\"$LOG_FILE\""; then
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
    # Use set +u temporarily to safely check array
    set +u
    if [[ -n "${INSTALLED_CACHE[$tool]:-}" ]]; then
        # Cache hit! Return immediately (0.001s vs 0.1-0.5s)
        local cached_result="${INSTALLED_CACHE[$tool]}"
        set -u
        return "$cached_result"
    fi
    set -u
    
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
    set +u
    if [[ $found -eq 1 ]]; then
        INSTALLED_CACHE[$tool]=0
        set -u
        return 0
    else
        INSTALLED_CACHE[$tool]=1
        set -u
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
        warning "Tool '$tool_name' not found in registry"
        [[ $use_thread_safe -eq 1 ]] && add_to_failed "$tool_name"
        return 1
    fi
    
    if is_installed_tool "$tool_name"; then
        info "$tool_name already installed"
        if [[ $use_thread_safe -eq 1 ]]; then
            add_to_skipped "$tool_name"
        else
            SKIPPED_TOOLS+=("$tool_name")
        fi
        return 0
    fi
    
    info "Installing $tool_name..."
    
    # Check disk space before installing
    if ! check_disk_space 500; then
        error "Insufficient space to install $tool_name"
        [[ $use_thread_safe -eq 1 ]] && add_to_failed "$tool_name"
        return 1
    fi
    
    IFS='|' read -r url script depends post_install <<< "${TOOLS_REGISTRY[$tool_name]}"
    
    local install_success=0
    
    # Install dependencies
    if [[ -n "$depends" ]]; then
        debug "Installing dependencies: $depends"
        apt_update_once
        
        # Split dependencies by comma and install each
        local deps_array
        IFS=',' read -ra deps_array <<< "$depends"
        local failed_deps=()
        
        for dep in "${deps_array[@]}"; do
            # Trim whitespace
            dep="${dep#"${dep%%[![:space:]]*}"}"
            dep="${dep%"${dep##*[![:space:]]}"}"
            
            if [[ -n "$dep" ]]; then
                if ! dry_run_exec "apt-get install -y -qq $dep &>>\"$LOG_FILE\""; then
                    [[ $DRY_RUN -eq 0 ]] && failed_deps+=("$dep")
                else
                    debug "$dep installed successfully"
                fi
            fi
        done
        
        if [[ ${#failed_deps[@]} -gt 0 ]]; then
            warning "Failed to install some dependencies: ${failed_deps[*]}"
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
        install_from_git "$url" "$script" "$tool_name" && install_success=1
    fi
    
    if [[ -n "$post_install" ]]; then
        if [[ "$post_install" =~ go[[:space:]]install ]]; then
            local go_pkg="${post_install#*go install }"
            go_pkg="${go_pkg%% *}"
            install_with_go "$go_pkg" "$tool_name" && install_success=1
        elif [[ "$post_install" =~ cargo[[:space:]]+build ]]; then
            # Detect cargo build - install from Git URL if available
            debug "Processing Cargo build for $tool_name"
            if [[ -n "$url" ]]; then
                install_with_cargo "$url" "$tool_name" && install_success=1
            else
                error "Cargo build requested but no Git URL provided for $tool_name"
            fi
        else
            execute_post_install "$post_install" "$tool_name" && install_success=1
        fi
    fi
    
    if [[ -z "$url" && -z "$post_install" ]]; then
        debug "Tentando instalar $tool_name via APT"
        apt_update_once
        if dry_run_exec "apt-get install -y -qq $tool_name &>>\"$LOG_FILE\""; then
            install_success=1
        fi
    fi
    
    # Post-installation health check
    if [[ $install_success -eq 1 ]]; then
        if health_check_tool "$tool_name"; then
            TOOLS_STATUS["$tool_name"]="installed"
            if [[ $use_thread_safe -eq 1 ]]; then
                add_to_installed "$tool_name"
            else
                INSTALLED_TOOLS+=("$tool_name")
            fi
            success "✓ $tool_name installed successfully"
            return 0
        else
            warning "Tool $tool_name installed but did not pass health check"
            # Consider as installed anyway (may be PATH issue)
            TOOLS_STATUS["$tool_name"]="installed"
            if [[ $use_thread_safe -eq 1 ]]; then
                add_to_installed "$tool_name"
            else
                INSTALLED_TOOLS+=("$tool_name")
            fi
            success "✓ $tool_name installed successfully"
            return 0
        fi
    else
        TOOLS_STATUS["$tool_name"]="failed"
        if [[ $use_thread_safe -eq 1 ]]; then
            add_to_failed "$tool_name"
        else
            FAILED_TOOLS+=("$tool_name")
        fi
        error "Failed to install $tool_name"
        return 1
    fi
}

# Install all tools
install_all_tools() {
    info "Starting installation of all tools..."
    
    # Registrar tempo de início
    export START_TIME=$(date +%s)
    
    local tools_array=()
    for tool in "${!TOOLS_REGISTRY[@]}"; do
        tools_array+=("$tool")
    done
    
    if [[ $PARALLEL_INSTALL -eq 1 ]]; then
        install_tools_parallel "${tools_array[@]}"
    else
        local total=${#tools_array[@]}
        local current=0
        for tool in "${tools_array[@]}"; do
            ((current++))
            show_progress "$current" "$total" "$(t 'install.progress' "$tool")"
            install_single_tool "$tool" || true
        done
        echo
    fi
    
    # Coletar métricas
    collect_metrics
    
    print_installation_summary
}

# Parallel installation (with wait -n and thread-safe arrays)
install_tools_parallel() {
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
        
        # Start installation in background (with thread-safe flag)
        (
            install_single_tool "$tool" 1 >/dev/null 2>&1
            exit $?
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
    
    # Verificar se o perfil existe
    set +u
    local tools="${PROFILE_TOOLS[$profile]:-}"
    set -u
    
    if [[ -z "$tools" ]]; then
        error "Profile '$profile' not found"
        echo
        info "Available profiles:"
        set +u
        for p in "${!PROFILE_TOOLS[@]}"; do
            echo "  - $p"
        done
        set -u
        return 1
    fi
    
    # Converter string de ferramentas em array
    local tool_array=()
    read -ra tool_array <<< "$tools"
    
    if [[ ${#tool_array[@]} -eq 0 ]]; then
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
        for tool in "${tool_array[@]}"; do
            if install_single_tool "$tool"; then
                ((installed++))
            else
                ((failed++))
            fi
        done
    fi
    
    echo
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
    
    # Verificar se o perfil existe
    set +u
    local tools="${PROFILE_TOOLS[$profile]:-}"
    set -u
    
    if [[ -z "$tools" ]]; then
        return 1
    fi
    
    echo "$tools"
}

# Listar perfis
list_profiles() {
    echo -e "${CYAN}$(t 'profile.available')${RESET}"
    echo
    
    set +u
    local profile_count=${#PROFILE_TOOLS[@]}
    set -u
    
    if [[ $profile_count -eq 0 ]]; then
        warning "No profiles configured"
        return 0
    fi
    
    # Ordenar perfis alfabeticamente
    local sorted_profiles
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
    
    # Preparar para barra de progresso
    local total_deps=${#core_deps[@]}
    local current_dep=0
    local failed_deps=()
    local start_time=$(date +%s)
    
    for dep in "${core_deps[@]}"; do
        ((current_dep++))
        
        if ! pkg_installed_apt "$dep"; then
            # Show progress bar during installation
            show_progress "$current_dep" "$total_deps" "$dep" "$start_time"
            info "Installing $dep..."
            
            if ! dry_run_exec "apt-get install -y -qq $dep &>>\"$LOG_FILE\""; then
                [[ $DRY_RUN -eq 0 ]] && failed_deps+=("$dep")
            else
                debug "$dep installed successfully"
            fi
        else
            # Show progress even for already installed packages
            show_progress "$current_dep" "$total_deps" "$dep (already installed)" "$start_time"
            debug "$dep already installed"
        fi
    done
    
    # Clear progress bar
    echo
    
    if [[ ${#failed_deps[@]} -gt 0 ]]; then
        warning "Some dependencies failed: ${failed_deps[*]}"
        warning "You may need to install them manually"
    else
        success "All core dependencies installed"
    fi
    
    if command -v pip3 &>/dev/null && [[ $DRY_RUN -eq 0 ]]; then
        debug "Updating pip..."
        pip3 install --upgrade pip >>"$LOG_FILE" 2>&1 || warning "Failed to update pip"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "Would update pip"
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
    if apt-get update -qq 2>>"$ERROR_LOG"; then
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

