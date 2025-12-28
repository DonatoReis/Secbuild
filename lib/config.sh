#!/usr/bin/env bash
################################################################################
# config.sh - Gerenciamento de Configuração
# Carrega e processa package.ini, tools_config.yaml
################################################################################

# Download do package.ini
download_package_ini() {
    local ini_file="$CONFIG_DIR/package.ini"
    
    info "config.downloading"
    
    # Fazer backup se existir
    if [[ -f "$ini_file" ]]; then
        local backup_file="$BACKUP_DIR/package.ini.$(date +%Y%m%d_%H%M%S)"
        cp "$ini_file" "$backup_file" 2>/dev/null || true
        debug "Backup criado: $backup_file"
    fi
    
    # Primeiro tentar copiar o arquivo local (sempre atualizar se existir)
    if [[ -f "$SCRIPT_DIR/package-dist.ini" ]]; then
        # Sempre copiar o arquivo local para garantir que está atualizado
        # Isso garante que perfis e outras atualizações sejam aplicadas
        cp "$SCRIPT_DIR/package-dist.ini" "$ini_file"
        success "config.copied"
    else
        # Baixar do repositório com retry
        local attempt=1
        while [[ $attempt -le $RETRY_COUNT ]]; do
            if wget -q -O "$ini_file" --timeout="$DOWNLOAD_TIMEOUT" "$PACKAGE_INI_URL"; then
                success "config.downloaded"
                break
            else
                warning "config.attempt" "$attempt" "$RETRY_COUNT"
                ((attempt++))
                [[ $attempt -le $RETRY_COUNT ]] && sleep "$RETRY_DELAY"
            fi
        done
        
        if [[ $attempt -gt $RETRY_COUNT ]]; then
            error "config.failed" "$RETRY_COUNT"
            return 1
        fi
    fi
    
    [[ -r "$ini_file" ]] || {
        error "config.not_found"
        return 1
    }
    
    # Validar arquivo baixado (estrutura)
    if ! validate_package_ini "$ini_file"; then
        error "config.invalid"
        return 1
    fi
    
    # Verificar integridade básica (tamanho mínimo e estrutura)
    local file_size
    file_size=$(stat -f%z "$ini_file" 2>/dev/null || stat -c%s "$ini_file" 2>/dev/null || echo "0")
    
    if [[ $file_size -lt 100 ]]; then
        error "Arquivo package.ini parece estar corrompido (muito pequeno: ${file_size} bytes)"
        return 1
    fi
    
    # Verificar se tem pelo menos uma seção válida
    if ! grep -q "^\[" "$ini_file" 2>/dev/null; then
        error "Arquivo package.ini não contém seções válidas"
        return 1
    fi
    
    debug "Integridade básica do package.ini verificada (${file_size} bytes)"
}

# Parse do package.ini
parse_package_ini() {
    local ini_file="$CONFIG_DIR/package.ini"
    
    info "config.processing"
    
    if [[ ! -f "$ini_file" ]]; then
        error "config.not_found_file"
        return 1
    fi
    
    # Limpar registro anterior
    TOOLS_REGISTRY=()
    TOOLS_PROFILES=()
    PROFILE_TOOLS=()
    
    # Parse manual do arquivo INI
    local current_tool=""
    local url=""
    local script=""
    local depends=""
    local post_install=""
    
    while IFS= read -r line; do
        # Remove espaços em branco
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Pular linhas vazias e comentários (# ou ;)
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*[\#\;] ]] && continue
        
        # Nova seção (ferramenta)
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            # Salvar ferramenta anterior se existir
            if [[ -n "$current_tool" ]]; then
                TOOLS_REGISTRY["$current_tool"]="$url|$script|$depends|$post_install"
                debug "config.registered" "$current_tool"
            fi
            
            # Iniciar nova ferramenta
            current_tool="${BASH_REMATCH[1],,}"  # Converter para minúsculas
            url=""
            script=""
            depends=""
            post_install=""
            
        # Processar atributos (key=value ou key = value)
        elif [[ "$line" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Remover espaços extras
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            # Remover aspas se existirem
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
                    # Processar perfis (separados por vírgula)
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
    
    # Salvar última ferramenta
    if [[ -n "$current_tool" ]]; then
        TOOLS_REGISTRY["$current_tool"]="$url|$script|$depends|$post_install"
        debug "config.registered" "$current_tool"
    fi
    
    local tool_count="${#TOOLS_REGISTRY[@]}"
    success "config.processed" "$tool_count"
    
    # Debug: listar ferramentas carregadas
    if [[ $VERBOSE_MODE -eq 1 ]]; then
        debug "config.loaded"
        for tool in "${!TOOLS_REGISTRY[@]}"; do
            debug "  - $tool"
        done
    fi
}

# Arrays globais para pacotes do YAML
declare -a YAML_ESSENTIAL_PACKAGES
declare -a YAML_SECURITY_TOOLS

# Carregar tools_config.yaml e retornar pacotes essenciais
load_tools_config_yaml() {
    local yaml_file="$SCRIPT_DIR/tools_config.yaml"
    
    if [[ ! -f "$yaml_file" ]]; then
        debug "tools_config.yaml não encontrado, pulando"
        return 0
    fi
    
    info "Carregando configurações do tools_config.yaml..."
    
    # Verificar se yq está disponível
    if ! command -v yq &>/dev/null && ! command -v python3 &>/dev/null; then
        warning "yq ou python3 não encontrado, pulando tools_config.yaml"
        return 0
    fi
    
    # Limpar arrays
    YAML_ESSENTIAL_PACKAGES=()
    YAML_SECURITY_TOOLS=()
    
    # Tentar usar yq primeiro
    if command -v yq &>/dev/null; then
        # Carregar pacotes essenciais
        while IFS= read -r package; do
            [[ -n "$package" ]] && YAML_ESSENTIAL_PACKAGES+=("$package")
        done < <(yq eval '.system_packages.essential[]' "$yaml_file" 2>/dev/null)
        
        # Carregar ferramentas de segurança
        while IFS= read -r tool; do
            [[ -n "$tool" ]] && YAML_SECURITY_TOOLS+=("$tool")
        done < <(yq eval '.system_packages.security_tools[]?' "$yaml_file" 2>/dev/null)
        
        if [[ ${#YAML_ESSENTIAL_PACKAGES[@]} -gt 0 ]]; then
            debug "Pacotes essenciais do YAML carregados: ${#YAML_ESSENTIAL_PACKAGES[@]} pacotes"
        fi
        
        if [[ ${#YAML_SECURITY_TOOLS[@]} -gt 0 ]]; then
            debug "Ferramentas de segurança do YAML carregadas: ${#YAML_SECURITY_TOOLS[@]} ferramentas"
        fi
    elif command -v python3 &>/dev/null; then
        # Fallback para Python (parse básico)
        debug "Usando Python para parse básico do YAML"
        # Implementação básica com Python seria aqui se necessário
    fi
    
    success "Configurações do YAML carregadas"
    return 0
}

# Obter pacotes essenciais do YAML
get_yaml_essential_packages() {
    echo "${YAML_ESSENTIAL_PACKAGES[@]}"
}

# Obter ferramentas de segurança do YAML
get_yaml_security_tools() {
    echo "${YAML_SECURITY_TOOLS[@]}"
}

# Salvar configurações
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

# Carregar configurações
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        debug "Configurações carregadas de $CONFIG_FILE"
    fi
}

