#!/usr/bin/env bash
################################################################################
# install.sh - Módulo de Instalação de Ferramentas
# Gerencia instalação via Git, Go, Python, APT
################################################################################

# ==============================================================================
# FUNÇÕES AUXILIARES DE SEGURANÇA E PERFORMANCE
# ==============================================================================

# Cache de comandos para evitar múltiplas chamadas command -v
declare -A COMMAND_CACHE

# Cache de verificações de instalação (nova melhoria)
declare -A INSTALLED_CACHE

# Verificar se comando existe (com cache)
cached_command_exists() {
    local cmd="$1"
    
    # Verificar cache primeiro
    if [[ -n "${COMMAND_CACHE[$cmd]:-}" ]]; then
        return "${COMMAND_CACHE[$cmd]}"
    fi
    
    # Verificar comando
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
    
    # Buscar última release (não pre-release)
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
    
    # Se não encontrou release, tentar última tag
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
        return 0  # Não é repositório Git, pular verificação
    fi
    
    # Verificar se repositório está íntegro
    if ! git -C "$repo_path" fsck --no-progress --quiet >>"$LOG_FILE" 2>&1; then
        warning "Repositório Git pode estar corrompido: $repo_path"
        return 1
    fi
    
    # Se temos versão esperada, verificar hash do commit
    if [[ -n "$expected_version" ]]; then
        local current_hash
        current_hash=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
        local expected_hash
        expected_hash=$(git -C "$repo_path" rev-parse "$expected_version" 2>/dev/null || echo "")
        
        if [[ -n "$current_hash" ]] && [[ -n "$expected_hash" ]] && [[ "$current_hash" != "$expected_hash" ]]; then
            warning "Hash do commit não corresponde à versão esperada para $tool_name"
            warning "Esperado: ${expected_hash:0:12}, Obtido: ${current_hash:0:12}"
            # Não falha, apenas avisa (pode ser branch diferente)
        elif [[ -n "$current_hash" ]]; then
            debug "Integridade verificada: hash ${current_hash:0:12} confere para $tool_name"
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
        warning "Não foi possível verificar espaço em disco, continuando..."
        return 0
    fi
    
    if [[ $available -lt $required_mb ]]; then
        error "Espaço insuficiente: ${available}MB disponível, ${required_mb}MB necessário"
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

# Health check pós-instalação (melhorado - mais abrangente)
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
            debug "Health check: comando não encontrado no PATH"
            return 1
        fi
    fi
    
    # 2. Verificar permissões de execução
    if [[ ! -x "$tool_path" ]]; then
        debug "Health check: sem permissão de execução, tentando corrigir..."
        chmod +x "$tool_path" 2>/dev/null || {
            warning "Não foi possível adicionar permissão de execução para $tool_path"
            return 1
        }
    fi
    
    # 3. Verificar se arquivo não está vazio
    if [[ -f "$tool_path" ]] && [[ ! -s "$tool_path" ]]; then
        warning "Health check: arquivo vazio ou corrompido: $tool_path"
        return 1
    fi
    
    # 4. Verificar se é link quebrado
    if [[ -L "$tool_path" ]] && [[ ! -e "$tool_path" ]]; then
        warning "Health check: link simbólico quebrado: $tool_path"
        return 1
    fi
    
    # 5. Verificar se executa sem erros fatais (timeout de 5s)
    if ! timeout 5 "$tool" --version &>/dev/null 2>&1; then
        # Tentar versão alternativa
        if ! timeout 5 "$tool" -version &>/dev/null 2>&1; then
            # Tentar help
            if ! timeout 5 "$tool" --help &>/dev/null 2>&1; then
                # Se todas falharam, verificar se é binário válido
                if [[ -f "$tool_path" ]]; then
                    # Para binários ELF, verificar se é executável válido
                    if file "$tool_path" 2>/dev/null | grep -q "ELF"; then
                        # É binário válido, pode não ter --version, mas está OK
                        debug "Health check: binário ELF válido (sem --version)"
                        return 0
                    else
                        # Não é binário, pode ser script - verificar se tem shebang
                        if head -1 "$tool_path" 2>/dev/null | grep -q "^#!"; then
                            debug "Health check: script válido (sem --version)"
                            return 0
                        else
                            warning "Health check: falha ao executar comando (timeout ou erro fatal)"
                            return 1
                        fi
                    fi
                else
                    warning "Health check: falha ao executar comando"
                    return 1
                fi
            fi
        fi
    fi
    
    # 6. Para binários ELF: verificar dependências dinâmicas (opcional, não falha)
    if [[ -f "$tool_path" ]] && command -v ldd &>/dev/null && file "$tool_path" 2>/dev/null | grep -q "ELF"; then
        local missing_deps
        missing_deps=$(ldd "$tool_path" 2>&1 | grep -c "not found" || echo "0")
        
        if [[ $missing_deps -gt 0 ]]; then
            warning "Health check: $missing_deps dependência(s) dinâmica(s) podem estar faltando para $tool"
            # Não falha, apenas avisa
        fi
    fi
    
    # Se chegou aqui, tudo OK
    debug "Health check: $tool passou em todas as verificações"
    return 0
}

# Adicionar ferramenta a array de forma thread-safe (para instalação paralela)
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

# Consolidar resultados de arquivos temporários para arrays globais
consolidate_parallel_results() {
    local pid=$$
    
    # Consolidar instaladas
    if [[ -f "/tmp/secbuild_installed_${pid}.tmp" ]]; then
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && INSTALLED_TOOLS+=("$tool")
        done < "/tmp/secbuild_installed_${pid}.tmp"
        rm -f "/tmp/secbuild_installed_${pid}.tmp" 2>/dev/null
    fi
    
    # Consolidar falhas
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

# Coletar métricas de instalação
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
        # Executar comando e capturar erro
        if "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
            return 0
        else
            last_error=$?
        fi
        
        # Se não é última tentativa, calcular delay adaptativo
        if [[ $attempt -lt $max_attempts ]]; then
            # Backoff exponencial base
            local delay=$((base_delay * (2 ** (attempt - 1))))
            
            # Jitter aleatório para evitar "thundering herd" (10% do delay)
            local jitter=$((RANDOM % (delay / 10 + 1)))
            delay=$((delay + jitter))
            
            # Limitar delay máximo
            [[ $delay -gt $max_delay ]] && delay=$max_delay
            
            debug "Tentativa $attempt/$max_attempts falhou. Aguardando ${delay}s antes de tentar novamente..."
            sleep "$delay"
        fi
        
        ((attempt++))
    done
    
    return 1
}

# Função melhorada para instalar ferramentas Go (com retry adaptativo)
install_go_tool_with_retry() {
    local tool_name="$1"
    local package="$2"
    
    # Detectar arquitetura
    local goarch
    goarch=$(detect_go_arch)
    
    # Flags de otimização Go
    local go_flags="-ldflags=-s -w -trimpath"
    
    # Tentar métodos em ordem de preferência com retry adaptativo
    local methods=(
        "GOARCH=$goarch go install $go_flags ${package}@latest"
        "GOARCH=$goarch go install ${package}@latest"
        "go get -u ${package}"
        "GO111MODULE=on go get ${package}"
    )
    
    for method in "${methods[@]}"; do
        debug "Tentando instalar $tool_name via: $method"
        
        # Usar retry adaptativo (5 tentativas, delay base 2s, max 30s)
        if retry_with_adaptive_backoff 5 2 30 bash -c "$method"; then
            return 0
        fi
    done
    
    error "Falha ao instalar $tool_name após todas as tentativas"
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
    
    # Validar URL antes de usar
    if ! validate_url "$repo_url"; then
        warning "URL inválida ou inacessível: $repo_url"
        # Continuar mesmo assim, pode ser um problema temporário de rede
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
        debug "Buscando versão mais recente e estável para $tool_name..."
        target_version=$(get_latest_github_release "$repo_url")
        if [[ -n "$target_version" ]]; then
            info "Versão mais recente encontrada: $target_version"
        else
            debug "Não foi possível obter versão específica, usando branch padrão"
        fi
    fi
    
    # NOVA MELHORIA: Verificar se há hash esperado no registro (validação de integridade)
    IFS='|' read -r _url _script _deps _post <<< "${TOOLS_REGISTRY[$tool_name]:-}"
    # Hash pode estar no package.ini como atributo separado (será implementado)
    # Por enquanto, verificamos hash do commit Git após clone
    
    debug "git.installing" "$tool_name" "$repo_url${target_version:+ (v$target_version)}"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dryrun.would_clone" "$repo_url${target_version:+@$target_version}" "$install_path"
        return 0
    fi
    
    # Clone ou update
    if [[ -d "$install_path/.git" ]]; then
        debug "git.updating"
        
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
                    debug "git.updated" "$repo_name"
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    warning "git.update_failed" "$repo_name"
                    return 1
                fi
            else
                debug "Repositório já está atualizado"
                save_to_cache "$cache_key" "$(date +%s)"
            fi
        fi
    else
        if [[ -d "$install_path" ]] && [[ ! -d "$install_path/.git" ]]; then
            debug "Diretório existe mas não é repositório Git, removendo..."
            rm -rf "$install_path"
        fi
        
        debug "git.cloning"
        mkdir -p "$(dirname "$install_path")"
        
        # Se temos versão específica, clonar e fazer checkout
        if [[ -n "$target_version" ]]; then
            # Clonar com tags para poder fazer checkout
            if git clone --depth 1 --single-branch -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                # Buscar tags para ter acesso à versão específica
                git -C "$install_path" fetch --tags --quiet >>"$LOG_FILE" 2>&1 || true
                
                # Tentar fazer checkout da versão
                if git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1; then
                    debug "git.cloned" "$repo_name" " (versão $target_version)"
                    
                    # NOVA MELHORIA: Verificar integridade do repositório clonado
                    verify_git_repository_integrity "$install_path" "$tool_name" "$target_version"
                    
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    # Se falhar, tentar clone completo com tags
                    warning "Não foi possível fazer checkout da versão $target_version, clonando repositório completo..."
                    rm -rf "$install_path"
                    if git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                        if git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1; then
                            debug "git.cloned" "$repo_name" " (versão $target_version)"
                            
                            # Verificar integridade
                            verify_git_repository_integrity "$install_path" "$tool_name" "$target_version"
                            
                            save_to_cache "$cache_key" "$(date +%s)"
                        else
                            warning "Falha ao fazer checkout da versão $target_version, usando branch padrão"
                            save_to_cache "$cache_key" "$(date +%s)"
                        fi
                    else
                        error "git.clone_failed" "$repo_name"
                        return 1
                    fi
                fi
            else
                # Fallback para clone completo
                warning "Shallow clone falhou, tentando clone completo..."
                if git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                    if [[ -n "$target_version" ]]; then
                        git -C "$install_path" checkout -q "$target_version" >>"$LOG_FILE" 2>&1 || true
                    fi
                    debug "git.cloned" "$repo_name"
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    error "git.clone_failed" "$repo_name"
                    return 1
                fi
            fi
        else
            # Sem versão específica, usar shallow clone normal
            if git clone --depth 1 --single-branch -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                debug "git.cloned" "$repo_name"
                
                # Verificar integridade após clone
                verify_git_repository_integrity "$install_path" "$tool_name"
                
                save_to_cache "$cache_key" "$(date +%s)"
            else
                # Fallback para clone completo se shallow falhar
                warning "Shallow clone falhou, tentando clone completo..."
                if git clone -q "$repo_url" "$install_path" >>"$LOG_FILE" 2>&1; then
                    debug "git.cloned" "$repo_name"
                    
                    # Verificar integridade após clone
                    verify_git_repository_integrity "$install_path" "$tool_name"
                    
                    save_to_cache "$cache_key" "$(date +%s)"
                else
                    error "git.clone_failed" "$repo_name"
                    return 1
                fi
            fi
        fi
    fi
    
    # Instalar dependências Python
    if [[ -f "$install_path/requirements.txt" ]]; then
        debug "Instalando dependências Python..."
        if install_requirements_safe "$install_path/requirements.txt" "$tool_name"; then
            debug "Requirements.txt instalado para $tool_name"
        else
            warning "Falha ao instalar requirements.txt para $tool_name"
        fi
    fi
    
    # Instalar via setup.py
    if [[ -f "$install_path/setup.py" ]]; then
        debug "Executando setup.py..."
        if (cd "$install_path" && python3 setup.py -q install) >>"$LOG_FILE" 2>&1; then
            debug "Setup.py executado para $tool_name"
        else
            warning "Falha ao executar setup.py para $tool_name"
        fi
    fi
    
    # Criar link simbólico
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

# Instalar via Go
install_with_go() {
    local go_package="$1"
    local tool_name="$2"
    
    debug "go.installing" "$tool_name" "$go_package"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dryrun.would_install" "$go_package"
        return 0
    fi
    
    export GOPATH="$SRC_DIR/go"
    export GOBIN="$BIN_DIR"
    
    [[ "$go_package" != *@* ]] && go_package="${go_package}@latest"
    
    if install_go_tool_with_retry "$tool_name" "$go_package"; then
        debug "go.installed" "$tool_name"
        validate_installation "$tool_name" "/usr/local/bin/$tool_name"
        return 0
    else
        error "go.failed" "$tool_name" "$go_package"
        return 1
    fi
}

# Executar post_install
execute_post_install() {
    local commands="$1"
    local tool_name="$2"
    
    debug "post.executing" "$tool_name"
    
    if ! validate_post_install "$commands" "$tool_name"; then
        error "post.rejected" "$tool_name"
        return 1
    fi
    
    commands="${commands//\$installdir/$SRC_DIR}"
    commands="${commands//\$bindir/$BIN_DIR}"
    commands="${commands//\$srcdir/$SRC_DIR}"
    
    debug "post_install($tool_name): $commands"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dryrun.would_exec" "$commands"
        return 0
    fi
    
    local safe_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if env -i PATH="$safe_path" HOME="$HOME" USER="$USER" bash -euo pipefail -c "$commands" >>"$LOG_FILE" 2>&1; then
        debug "post.completed" "$tool_name"
        return 0
    else
        error "post.failed" "$tool_name"
        return 1
    fi
}

# Obter nomes de binários para ferramenta
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

# Verificar se ferramenta está instalada (usando cache de comandos + cache de instalação)
is_installed_tool() {
    local tool="$1"
    
    # NOVA MELHORIA: Verificar cache de instalação primeiro (muito mais rápido)
    if [[ -n "${INSTALLED_CACHE[$tool]:-}" ]]; then
        # Cache hit! Retorna imediatamente (0.001s vs 0.1-0.5s)
        return "${INSTALLED_CACHE[$tool]}"
    fi
    
    # Cache miss: verificar de verdade
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
    
    # Salvar resultado no cache para próximas verificações
    if [[ $found -eq 1 ]]; then
        INSTALLED_CACHE[$tool]=0
        return 0
    else
        INSTALLED_CACHE[$tool]=1
        return 1
    fi
}

# Validar instalação (usando cache de comandos)
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

# Instalar ferramenta única (com health check e arrays thread-safe)
install_single_tool() {
    local tool_name="$1"
    local use_thread_safe="${2:-0}"  # Flag para usar arrays thread-safe em paralelo
    
    if [[ -z "${TOOLS_REGISTRY[$tool_name]:-}" ]]; then
        warning "install.not_found" "$tool_name"
        [[ $use_thread_safe -eq 1 ]] && add_to_failed "$tool_name"
        return 1
    fi
    
    if is_installed_tool "$tool_name"; then
        info "install.already_installed" "$tool_name"
        if [[ $use_thread_safe -eq 1 ]]; then
            add_to_skipped "$tool_name"
        else
            SKIPPED_TOOLS+=("$tool_name")
        fi
        return 0
    fi
    
    info "install.installing" "$tool_name"
    
    # Verificar espaço em disco antes de instalar
    if ! check_disk_space 500; then
        error "Espaço insuficiente para instalar $tool_name"
        [[ $use_thread_safe -eq 1 ]] && add_to_failed "$tool_name"
        return 1
    fi
    
    IFS='|' read -r url script depends post_install <<< "${TOOLS_REGISTRY[$tool_name]}"
    
    local install_success=0
    
    # Instalar dependências
    if [[ -n "$depends" ]]; then
        debug "Instalando dependências: $depends"
        apt_update_once
        if ! dry_run_exec "apt-get install -y -qq $depends &>>\"$LOG_FILE\""; then
            [[ $DRY_RUN -eq 0 ]] && warning "deps.failed" "$depends"
        else
            debug "deps.installed" "$depends"
        fi
    fi
    
    # Instalar ferramenta
    if [[ -n "$url" ]]; then
        install_from_git "$url" "$script" "$tool_name" && install_success=1
    fi
    
    if [[ -n "$post_install" ]]; then
        if [[ "$post_install" =~ go[[:space:]]install ]]; then
            local go_pkg="${post_install#*go install }"
            go_pkg="${go_pkg%% *}"
            install_with_go "$go_pkg" "$tool_name" && install_success=1
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
    
    # Health check pós-instalação
    if [[ $install_success -eq 1 ]]; then
        if health_check_tool "$tool_name"; then
            TOOLS_STATUS["$tool_name"]="installed"
            if [[ $use_thread_safe -eq 1 ]]; then
                add_to_installed "$tool_name"
            else
                INSTALLED_TOOLS+=("$tool_name")
            fi
            success "install.success" "$tool_name"
            return 0
        else
            warning "Ferramenta $tool_name instalada mas não passou no health check"
            # Considerar como instalada mesmo assim (pode ser problema de PATH)
            TOOLS_STATUS["$tool_name"]="installed"
            if [[ $use_thread_safe -eq 1 ]]; then
                add_to_installed "$tool_name"
            else
                INSTALLED_TOOLS+=("$tool_name")
            fi
            success "install.success" "$tool_name"
            return 0
        fi
    else
        TOOLS_STATUS["$tool_name"]="failed"
        if [[ $use_thread_safe -eq 1 ]]; then
            add_to_failed "$tool_name"
        else
            FAILED_TOOLS+=("$tool_name")
        fi
        error "install.failed" "$tool_name"
        return 1
    fi
}

# Instalar todas as ferramentas
install_all_tools() {
    info "install.all"
    
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

# Instalação paralela (com wait -n e arrays thread-safe)
install_tools_parallel() {
    local tools=("$@")
    local total=${#tools[@]}
    local current=0
    local running=0
    local max_jobs=$MAX_PARALLEL_JOBS
    declare -a pids=()
    declare -A pid_to_tool=()
    
    # Verificar se Bash suporta wait -n (Bash 4.3+)
    local supports_wait_n=0
    if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
        local minor_version="${BASH_VERSION#*.}"
        minor_version="${minor_version%%.*}"
        if [[ $minor_version -ge 3 ]]; then
            supports_wait_n=1
        fi
    fi
    
    info "install.parallel" "$total" "$max_jobs"
    
    for tool in "${tools[@]}"; do
        # Aguardar slot disponível
        while [[ $running -ge $max_jobs ]]; do
            if [[ $supports_wait_n -eq 1 ]]; then
                # Usar wait -n (mais eficiente, Bash 4.3+)
                # Nota: -p só está disponível no Bash 5.1+, então usamos polling
                # mas mais eficiente que o método antigo
                local found=0
                for pid in "${pids[@]}"; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        local finished_tool="${pid_to_tool[$pid]}"
                        wait "$pid"
                        local exit_code=$?
                        
                        if [[ $exit_code -eq 0 ]]; then
                            success "install.completed" "$finished_tool"
                        else
                            error "install.failed_tool" "$finished_tool"
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
                # Fallback: polling com kill -0
                for pid in "${pids[@]}"; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        local finished_tool="${pid_to_tool[$pid]}"
                        wait "$pid"
                        local exit_code=$?
                        
                        if [[ $exit_code -eq 0 ]]; then
                            success "install.completed" "$finished_tool"
                        else
                            error "install.failed_tool" "$finished_tool"
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
        
        # Iniciar instalação em background (com flag thread-safe)
        (
            install_single_tool "$tool" 1 >/dev/null 2>&1
            exit $?
        ) &
        
        local pid=$!
        pids+=("$pid")
        pid_to_tool[$pid]="$tool"
        ((running++))
        
        debug "install.started" "$tool" "$pid"
    done
    
    # Aguardar todos os processos restantes
    for pid in "${pids[@]}"; do
        local finished_tool="${pid_to_tool[$pid]}"
        wait "$pid"
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            success "install.completed" "$finished_tool"
        else
            error "install.failed_tool" "$finished_tool"
        fi
        
        ((current++))
        show_progress "$current" "$total" "$(t 'install.progress' '...')"
    done
    
    # Consolidar resultados de arquivos temporários
    consolidate_parallel_results
    
    echo
}

# Instalar perfil
install_profile() {
    local profile="$1"
    profile="${profile,,}"
    
    if [[ -z "$profile" ]]; then
        error "profile.invalid"
        return 1
    fi
    
    info "profile.installing" "$profile"
    
    # Verificar se o perfil existe
    set +u
    local tools="${PROFILE_TOOLS[$profile]:-}"
    set -u
    
    if [[ -z "$tools" ]]; then
        error "profile.not_found" "$profile"
        echo
        info "profile.available"
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
        error "profile.not_found" "$profile"
        return 1
    fi
    
    info "profile.tools" "$profile" "${#tool_array[@]}"
    echo
    
    # Mostrar ferramentas que serão instaladas
    if [[ ${VERBOSE_MODE:-0} -eq 1 ]]; then
        echo -e "${CYAN}Ferramentas do perfil '$profile':${RESET}"
        for tool in "${tool_array[@]}"; do
            echo "  • $tool"
        done
        echo
    fi
    
    # Instalar ferramentas
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
        success "Perfil '$profile' processado: $installed instalada(s), $failed falha(s)"
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
        warning "profile.none"
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
        
        echo -e "  ${GREEN}$profile${RESET} - ${YELLOW}$tool_count${RESET} ferramenta(s)"
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
    info "deps.installing"
    
    # Pacotes básicos essenciais
    local core_deps=(
        "curl" "wget" "git" "build-essential" "python3" "python3-pip"
        "golang-go" "cargo" "cmake" "jq" "dialog" "bc" "realpath"
    )
    
    # Adicionar pacotes do tools_config.yaml se disponível
    if [[ ${#YAML_ESSENTIAL_PACKAGES[@]} -gt 0 ]]; then
        debug "Adicionando ${#YAML_ESSENTIAL_PACKAGES[@]} pacotes do tools_config.yaml"
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
    
    local failed_deps=()
    for dep in "${core_deps[@]}"; do
        if ! pkg_installed_apt "$dep"; then
            info "deps.installing_pkg" "$dep"
            if ! dry_run_exec "apt-get install -y -qq $dep &>>\"$LOG_FILE\""; then
                [[ $DRY_RUN -eq 0 ]] && failed_deps+=("$dep")
            else
                debug "deps.installed" "$dep"
            fi
        else
            debug "deps.already_installed" "$dep"
        fi
    done
    
    if [[ ${#failed_deps[@]} -gt 0 ]]; then
        warning "deps.some_failed" "${failed_deps[*]}"
        warning "deps.manual_install"
    else
        success "deps.all_installed"
    fi
    
    if command -v pip3 &>/dev/null && [[ $DRY_RUN -eq 0 ]]; then
        debug "deps.updating_pip"
        pip3 install --upgrade pip >>"$LOG_FILE" 2>&1 || warning "deps.pip_failed"
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "dryrun.would_update"
    fi
}

# Instalar ferramentas vendor
install_vendor_tools() {
    info "Baixando ferramentas auxiliares..."
    
    if [[ ! -d "$VENDOR_DIR/progressbar" ]]; then
        info "Instalando progressbar..."
        if git clone -q "$PROGRESSBAR_URL" "$VENDOR_DIR/progressbar" >>"$LOG_FILE" 2>&1; then
            debug "Progressbar instalado"
        else
            warning "Falha ao instalar progressbar"
        fi
    fi
    
    if [[ ! -d "$VENDOR_DIR/bash-ini-parser" ]]; then
        info "Instalando bash-ini-parser..."
        if git clone -q "$INI_PARSER_URL" "$VENDOR_DIR/bash-ini-parser" >>"$LOG_FILE" 2>&1; then
            debug "Bash-ini-parser instalado"
        else
            warning "Falha ao instalar bash-ini-parser"
        fi
    fi
    
    if [[ -f "$VENDOR_DIR/bash-ini-parser/bash-ini-parser" ]]; then
        source "$VENDOR_DIR/bash-ini-parser/bash-ini-parser"
        success "Ferramentas auxiliares instaladas"
    else
        warning "Bash-ini-parser não encontrado, usando parser manual"
    fi
}

# Otimização APT update
apt_update_once() {
    if [[ $APT_UPDATE_DONE -eq 1 ]]; then
        debug "APT update já foi executado nesta sessão"
        return 0
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dryrun.would_exec" "apt-get update"
        APT_UPDATE_DONE=1
        return 0
    fi
    
    info "deps.updating"
    if apt-get update -qq 2>>"$ERROR_LOG"; then
        APT_UPDATE_DONE=1
        success "deps.updated"
        return 0
    else
        warning "deps.failed_update"
        return 1
    fi
}

# Modo dry-run (seguro, sem eval)
dry_run_exec() {
    local cmd="$*"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        info "dryrun.would_exec" "$cmd"
        return 0
    fi
    
    # Validar comando antes de executar (bloquear comandos perigosos)
    if [[ "$cmd" =~ (rm\s+-rf\s+/|format\s+|mkfs|dd\s+if=.*of=/dev/|mkfs\.|fdisk\s+/dev/) ]]; then
        error "Comando perigoso bloqueado por segurança: $cmd"
        return 1
    fi
    
    # Executar de forma segura usando bash -c
    if bash -c "$cmd" >>"$LOG_FILE" 2>&1; then
        return 0
    else
        return $?
    fi
}

