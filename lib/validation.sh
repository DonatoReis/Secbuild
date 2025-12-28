#!/usr/bin/env bash
################################################################################
# validation.sh - Validações e Verificações
# Valida arquivos, comandos, integridade
################################################################################

# Validar estrutura do package.ini
validate_package_ini() {
    local ini_file="$1"
    local errors=0
    local warnings=0
    
    info "val.validating"
    
    # Verificar se arquivo existe e é legível
    if [[ ! -f "$ini_file" ]]; then
        error "val.not_found" "$ini_file"
        return 1
    fi
    
    if [[ ! -r "$ini_file" ]]; then
        error "val.no_read" "$ini_file"
        return 1
    fi
    
    # Verificar se arquivo não está vazio
    if [[ ! -s "$ini_file" ]]; then
        error "val.empty"
        return 1
    fi
    
    # Validar estrutura básica
    local line_num=0
    local current_section=""
    local has_sections=0
    local invalid_lines=()
    local duplicate_sections=()
    declare -A seen_sections
    declare -A first_occurrence
    
    # Atributos válidos
    local valid_attrs=("url" "script" "depends" "post_install" "profile" "hash" "signature")
    
    while IFS= read -r line; do
        ((line_num++))
        
        # Remover espaços em branco
        local clean_line="${line#"${line%%[![:space:]]*}"}"
        clean_line="${clean_line%"${clean_line##*[![:space:]]}"}"
        
        # Pular linhas vazias e comentários
        [[ -z "$clean_line" ]] && continue
        [[ "$clean_line" =~ ^[[:space:]]*[\#\;] ]] && continue
        
        # Verificar seção [ToolName]
        if [[ "$clean_line" =~ ^\[([^]]+)\]$ ]]; then
            local section_name="${BASH_REMATCH[1],,}"
            
            if [[ -n "${seen_sections[$section_name]:-}" ]]; then
                local first_line="${first_occurrence[$section_name]}"
                duplicate_sections+=("Linha $line_num: Seção duplicada [$section_name] (primeira ocorrência na linha $first_line, esta será ignorada)")
                ((warnings++))
            else
                seen_sections["$section_name"]=1
                first_occurrence["$section_name"]=$line_num
                has_sections=1
            fi
            
            current_section="$section_name"
            
        # Verificar atributos key=value
        elif [[ "$clean_line" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Remover espaços do key
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            key="${key,,}"  # Converter para minúsculas
            
            # Verificar se está dentro de uma seção
            if [[ -z "$current_section" ]]; then
                invalid_lines+=("Linha $line_num: Atributo '$key' fora de seção")
                ((errors++))
                continue
            fi
            
            # Verificar se atributo é válido
            local valid=0
            for attr in "${valid_attrs[@]}"; do
                if [[ "$key" == "$attr" ]]; then
                    valid=1
                    break
                fi
            done
            
            if [[ $valid -eq 0 ]]; then
                invalid_lines+=("Linha $line_num: Atributo desconhecido '$key' em [$current_section]")
                ((warnings++))
            fi
            
            # Validar URL se presente
            if [[ "$key" == "url" && -n "$value" ]]; then
                value="${value#\'}"
                value="${value%\'}"
                value="${value#\"}"
                value="${value%\"}"
                
                if [[ ! "$value" =~ ^https?:// ]] && [[ ! "$value" =~ ^git@ ]]; then
                    invalid_lines+=("Linha $line_num: URL inválida em [$current_section]: $value")
                    ((errors++))
                fi
            fi
            
            # Validar post_install básico (comandos perigosos)
            if [[ "$key" == "post_install" && -n "$value" ]]; then
                local cmd_check="${value#\'}"
                cmd_check="${cmd_check%\'}"
                cmd_check="${cmd_check#\"}"
                cmd_check="${cmd_check%\"}"
                
                if [[ "$cmd_check" =~ (rm\s+-rf|format|mkfs|dd\s+if=|>.*/dev/) ]]; then
                    invalid_lines+=("Linha $line_num: Comando potencialmente perigoso em [$current_section]")
                    ((warnings++))
                fi
            fi
            
        # Linha não reconhecida
        else
            invalid_lines+=("Linha $line_num: Formato inválido: $clean_line")
            ((errors++))
        fi
    done < "$ini_file"
    
    # Verificar se tem pelo menos uma seção
    if [[ $has_sections -eq 0 ]]; then
        error "val.no_sections"
        return 1
    fi
    
    # Reportar problemas
    if [[ ${#duplicate_sections[@]} -gt 0 ]]; then
        warning "val.duplicate"
        for dup in "${duplicate_sections[@]}"; do
            warning "  $dup"
        done
        info "val.duplicate_note"
    fi
    
    if [[ ${#invalid_lines[@]} -gt 0 ]]; then
        if [[ $errors -gt 0 ]]; then
            error "val.errors"
            for err in "${invalid_lines[@]}"; do
                warning "  $err"
            done
        else
            warning "val.warnings"
            for warn in "${invalid_lines[@]}"; do
                warning "  $warn"
            done
        fi
    fi
    
    # Retornar status
    if [[ $errors -gt 0 ]]; then
        error "val.failed" "$errors" "$warnings"
        return 1
    elif [[ $warnings -gt 0 ]]; then
        warning "val.completed_warnings" "$warnings"
        return 0
    else
        success "val.completed"
        return 0
    fi
}

# Validar comandos post_install
validate_post_install() {
    local commands="$1"
    local tool_name="$2"
    
    # Lista de comandos/permissões perigosas
    local dangerous_patterns=(
        "rm\s+-rf\s+/"
        "rm\s+-rf\s+\$HOME"
        "rm\s+-rf\s+\$HOME/"
        "format"
        "mkfs"
        "dd\s+if=.*of=/dev/"
        ">.*/dev/"
        "chmod\s+777\s+/"
        "chown\s+.*\s+/"
        "sudo\s+rm\s+-rf"
        "curl\s+.*\s+\|.*bash"
        "wget\s+.*\s+\|.*bash"
    )
    
    # Verificar padrões perigosos
    for pattern in "${dangerous_patterns[@]}"; do
        if [[ "$commands" =~ $pattern ]]; then
            error "post.dangerous" "$tool_name"
            error "post.blocked" "$pattern"
            return 1
        fi
    done
    
    # Verificar se não tenta modificar arquivos críticos do sistema
    if [[ "$commands" =~ (\/etc\/passwd|\/etc\/shadow|\/etc\/sudoers|\/boot|\/sys) ]]; then
        error "post.critical_file" "$tool_name"
        return 1
    fi
    
    return 0
}

# Calcular hash de arquivo
calculate_hash() {
    local file="$1"
    local algorithm="${2:-$HASH_ALGORITHM}"
    
    case "$algorithm" in
        sha256)
            sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || sha256 -q "$file" 2>/dev/null
            ;;
        sha1)
            sha1sum "$file" 2>/dev/null | cut -d' ' -f1 || shasum -a 1 "$file" 2>/dev/null | cut -d' ' -f1
            ;;
        md5)
            md5sum "$file" 2>/dev/null | cut -d' ' -f1 || md5 -q "$file" 2>/dev/null
            ;;
        *)
            error "Hash algorithm not supported: $algorithm"
            return 1
            ;;
    esac
}

# Verificar integridade de arquivo
verify_file_integrity() {
    local file="$1"
    local expected_hash="${2:-}"
    local algorithm="${3:-$HASH_ALGORITHM}"
    
    if [[ -z "$expected_hash" ]]; then
        debug "No expected hash provided, skipping verification"
        return 0
    fi
    
    if [[ ! -f "$file" ]]; then
        error "integrity.failed" "$file"
        return 1
    fi
    
    local actual_hash
    actual_hash=$(calculate_hash "$file" "$algorithm")
    
    if [[ "$actual_hash" == "$expected_hash" ]]; then
        success "integrity.verified" "$file"
        return 0
    else
        error "integrity.failed" "$file"
        error "integrity.expected" "$expected_hash"
        error "integrity.obtained" "$actual_hash"
        return 1
    fi
}

