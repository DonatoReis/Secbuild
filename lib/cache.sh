#!/usr/bin/env bash
################################################################################
# cache.sh - Sistema de Cache
# Gerencia cache de downloads e builds
################################################################################

# Gerar chave de cache a partir de URL
get_cache_key() {
    local url="$1"
    echo -n "$url" | sha256sum | cut -d' ' -f1
}

# Verificar se cache é válido
is_cache_valid() {
    local cache_key="$1"
    local cache_file="$CACHE_DIR/$cache_key"
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    # Verificar idade do cache
    local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)))
    
    if [[ $cache_age -gt $CACHE_TTL ]]; then
        debug "Cache expired for $cache_key (age: ${cache_age}s)"
        return 1
    fi
    
    return 0
}

# Salvar no cache
save_to_cache() {
    local cache_key="$1"
    local content="$2"
    local cache_file="$CACHE_DIR/$cache_key"
    
    mkdir -p "$CACHE_DIR"
    echo "$content" > "$cache_file"
    debug "Content saved to cache: $cache_key"
}

# Obter do cache
get_from_cache() {
    local cache_key="$1"
    local cache_file="$CACHE_DIR/$cache_key"
    
    if is_cache_valid "$cache_key"; then
        cat "$cache_file"
        return 0
    fi
    
    return 1
}

