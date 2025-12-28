#!/usr/bin/env bash
################################################################################
# i18n.sh - Sistema de Internacionalização
# Suporta Português (Brasil) e Inglês (EUA)
################################################################################

# Idioma padrão (pode ser sobrescrito por variável de ambiente)
readonly DEFAULT_LANG="${LANG:-pt_BR}"

# LOCALES_DIR já está definido em secbuild.sh, não redefinir
# readonly LOCALES_DIR="${SCRIPT_DIR}/locales"

# Array associativo para armazenar traduções
# Declarar globalmente para garantir visibilidade
declare -gA I18N_STRINGS 2>/dev/null || true

# Inicializar array vazio explicitamente
I18N_STRINGS=()

# Carregar traduções do arquivo de idioma
load_translations() {
    local lang="${1:-$DEFAULT_LANG}"
    local lang_file="${LOCALES_DIR}/${lang}.lang"
    
    # Se arquivo não existe, tentar fallback
    if [[ ! -f "$lang_file" ]]; then
        # Tentar variante sem região (pt -> pt_BR, en -> en_US)
        local lang_base="${lang%%_*}"
        if [[ "$lang_base" == "pt" ]]; then
            lang_file="${LOCALES_DIR}/pt_BR.lang"
        elif [[ "$lang_base" == "en" ]]; then
            lang_file="${LOCALES_DIR}/en_US.lang"
        else
            # Fallback para inglês
            lang_file="${LOCALES_DIR}/en_US.lang"
        fi
    fi
    
    # Se ainda não existe, usar inglês como último recurso
    if [[ ! -f "$lang_file" ]]; then
        warning "Translation file not found, using English" 2>/dev/null || true
        lang_file="${LOCALES_DIR}/en_US.lang"
    fi
    
    # Limpar traduções anteriores
    I18N_STRINGS=()
    
    # Carregar traduções
    if [[ -f "$lang_file" ]]; then
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            # Pular linhas vazias e comentários
            [[ -z "$key" ]] && continue
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            
            # Remover espaços do key
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            # Remover espaços do value e preservar o resto
            value="${value# }"
            
            # Armazenar tradução
            if [[ -n "$key" && -n "$value" ]]; then
                I18N_STRINGS["$key"]="$value"
            fi
        done < "$lang_file"
        
        # Verificar se carregou alguma tradução
        # Desabilitar temporariamente set -u para verificação
        set +u
        local size=${#I18N_STRINGS[@]}
        set -u
        
        if [[ $size -eq 0 ]]; then
            # Se não carregou nada, pode ser problema no arquivo
            return 1
        fi
        
        # Retornar sucesso
        return 0
    else
        # error só está disponível após logging.sh ser carregado
        # [[ -n "$(command -v error)" ]] && error "No translation file found!"
        return 1
    fi
}

# Obter tradução
# Uso: t "chave" [arg1] [arg2] ...
t() {
    local key="$1"
    shift
    
    # Verificar se o array existe e está declarado
    # Desabilitar temporariamente set -u para verificação segura
    set +u
    local array_size=${#I18N_STRINGS[@]}
    local translation="${I18N_STRINGS[$key]}"
    set -u
    
    # Se array está vazio ou tradução não encontrada, retornar a chave
    if [[ $array_size -eq 0 ]] || [[ -z "$translation" ]]; then
        echo "$key"
        return 0
    fi
    
    # Substituir placeholders %s pelos argumentos
    local result="$translation"
    
    while [[ $# -gt 0 ]]; do
        result="${result//%s/$1}"
        shift
    done
    
    # Processar \n como quebra de linha
    result="${result//\\n/$'\n'}"
    
    echo "$result"
}

# Detectar idioma do sistema
detect_language() {
    # Verificar múltiplas variáveis de ambiente (ordem de prioridade)
    local system_lang=""
    
    # 1. Variável específica do SecBuild
    if [[ -n "${SECBUILD_LANG:-}" ]]; then
        system_lang="$SECBUILD_LANG"
    # 2. LANG (padrão do sistema)
    elif [[ -n "${LANG:-}" ]]; then
        system_lang="$LANG"
    # 3. LC_ALL (locale completo)
    elif [[ -n "${LC_ALL:-}" ]]; then
        system_lang="$LC_ALL"
    # 4. LC_MESSAGES (mensagens)
    elif [[ -n "${LC_MESSAGES:-}" ]]; then
        system_lang="$LC_MESSAGES"
    # 5. Fallback
    else
        system_lang="en_US"
    fi
    
    # Remover encoding (en_US.UTF-8 -> en_US)
    system_lang="${system_lang%%.*}"
    
    # Mapear para idiomas suportados
    case "$system_lang" in
        pt_*|pt|pt_BR|pt_PT)
            echo "pt_BR"
            ;;
        en_*|en|en_US|en_GB)
            echo "en_US"
            ;;
        *)
            # Fallback: tentar detectar pelo sistema
            # No macOS, verificar preferências do sistema
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # Tentar detectar idioma do sistema macOS
                local macos_lang
                macos_lang=$(defaults read -g AppleLanguages 2>/dev/null | grep -o '"[^"]*"' | head -1 | tr -d '"' || echo "")
                if [[ "$macos_lang" =~ ^pt ]]; then
                    echo "pt_BR"
                else
                    echo "en_US"
                fi
            else
                echo "en_US"  # Fallback para inglês
            fi
            ;;
    esac
}

# Inicializar i18n
init_i18n() {
    # Garantir que o array existe antes de inicializar (global)
    declare -gA I18N_STRINGS 2>/dev/null || true
    
    # Detectar idioma
    local lang="${SECBUILD_LANG:-$(detect_language)}"
    
    # Debug: mostrar idioma detectado
    if [[ "${VERBOSE_MODE:-0}" -eq 1 ]]; then
        echo "i18n: Idioma detectado: $lang" >&2
        echo "i18n: Arquivo esperado: ${LOCALES_DIR}/${lang}.lang" >&2
    fi
    
    # Carregar traduções
    if ! load_translations "$lang"; then
        # Se falhou, tentar inglês como fallback
        if [[ "$lang" != "en_US" ]]; then
            if [[ "${VERBOSE_MODE:-0}" -eq 1 ]]; then
                echo "i18n: Falha ao carregar $lang, tentando en_US..." >&2
            fi
            load_translations "en_US" || true
        fi
    fi
    
    # Verificar se carregou traduções
    set +u
    local translation_count=${#I18N_STRINGS[@]}
    set -u
    
    # Debug: mostrar resultado
    if [[ "${VERBOSE_MODE:-0}" -eq 1 ]]; then
        echo "i18n: Traduções carregadas: $translation_count" >&2
        if [[ $translation_count -gt 0 ]]; then
            # Mostrar algumas chaves de exemplo
            local count=0
            for k in "${!I18N_STRINGS[@]}"; do
                [[ $count -lt 3 ]] && echo "i18n: Exemplo - $k = ${I18N_STRINGS[$k]}" >&2
                ((count++))
            done
        fi
    fi
    
    if [[ $translation_count -eq 0 ]]; then
        echo "i18n: ERRO - Nenhuma tradução foi carregada!" >&2
        echo "i18n: Verificando arquivo: ${LOCALES_DIR}/${lang}.lang" >&2
        [[ -f "${LOCALES_DIR}/${lang}.lang" ]] && echo "i18n: Arquivo existe" >&2 || echo "i18n: Arquivo NÃO existe" >&2
    fi
}