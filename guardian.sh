#!/bin/sh
# =============================================================================
# Nexus Guardian — Monitor de recursos y limpieza automática (POSIX sh)
# =============================================================================
# Mantiene todos los agentes CLI bajo 500 MB de RAM combinados.
# Estrategia: 3 niveles de acción según uso de RAM.
# Ejecutar cada 60s vía cron o como daemon.
# =============================================================================

# Configuración
MAX_RAM_MB=500
WARN_RAM_MB=400
CRIT_RAM_MB=480
LOG_FILE="/var/log/nexus-guardian.log"
TARGET_CONTAINERS="nexus-deepseek nexus-antigravity nexus-codex nexus-opencode cloudflared-deepseek"

# =============================================================================
# Logging
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# =============================================================================
# Obtener memoria total de los contenedores objetivo (en MB)
# =============================================================================
get_total_ram() {
    total=0
    for container in $TARGET_CONTAINERS; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            mem_line=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null | head -1)
            if [ -n "$mem_line" ]; then
                mb=$(echo "$mem_line" | sed 's/\..*//' | grep -oE '[0-9]+' | head -1)
                total=$((total + ${mb:-0}))
            fi
        fi
    done
    echo "$total"
}

# =============================================================================
# Nivel 1: Limpiar sesiones viejas
# =============================================================================
clean_sessions() {
    log "  [NIVEL 1] Limpiando sesiones viejas..."

    # DeepSeek: limpiar tmux sessions excepto la principal
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "nexus-deepseek"; then
        sessions=$(docker exec nexus-deepseek tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
        count=0
        for s in $sessions; do
            count=$((count + 1))
            if [ $count -gt 3 ] && [ "$s" != "deepseek" ]; then
                docker exec nexus-deepseek tmux kill-session -t "$s" 2>/dev/null || true
                log "    -> tmux session '$s' eliminada (deepseek)"
            fi
        done
    fi

    # Gemini, Antigravity, Codex: matar procesos extras
    for container in nexus-antigravity nexus-codex; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$container"; then
            pids=$(docker exec "$container" sh -c "ps | grep -E 'bash|sh' | grep -v grep | grep -v ttyd | awk '{print \$1}' | head -5" 2>/dev/null || true)
            for pid in $pids; do
                if [ -n "$pid" ] && [ "$pid" -gt 10 ] 2>/dev/null; then
                    docker exec "$container" kill "$pid" 2>/dev/null || true
                    log "    -> Proceso $pid eliminado ($container)"
                fi
            done
        fi
    done
}

# =============================================================================
# Nivel 2: Recargar agentes ligeros
# =============================================================================
restart_lights() {
    log "  [NIVEL 2] Recargando agentes ligeros..."

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "cloudflared-deepseek"; then
        docker restart cloudflared-deepseek >/dev/null 2>&1 || true
        log "    -> Reiniciado: cloudflared-deepseek"
        sleep 3
    fi

    for container in nexus-deepseek nexus-antigravity nexus-codex; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$container"; then
            docker exec "$container" sh -c 'sync 2>/dev/null; true' 2>/dev/null || true
        fi
    done
}

# =============================================================================
# Nivel 3: Reiniciar el contenedor más pesado
# =============================================================================
restart_heaviest() {
    log "  [NIVEL 3] Buscando contenedor mas pesado..."

    heaviest=""
    max_mem=0

    for container in $TARGET_CONTAINERS; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
            mem_line=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null | head -1)
            mb=$(echo "$mem_line" | sed 's/\..*//' | grep -oE '[0-9]+' | head -1)
            mb=${mb:-0}
            if [ "$mb" -gt "$max_mem" ]; then
                max_mem=$mb
                heaviest=$container
            fi
        fi
    done

    if [ -n "$heaviest" ]; then
        log "    -> Reiniciando contenedor mas pesado: $heaviest (${max_mem} MB)"
        docker restart "$heaviest" >/dev/null 2>&1 || true
        log "    -> $heaviest reiniciado"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
log "========================================"
log "Guardian: verificando agentes..."

TOTAL_RAM=$(get_total_ram)
log "RAM total agentes: ${TOTAL_RAM} MB / ${MAX_RAM_MB} MB"

if [ "$TOTAL_RAM" -ge "$CRIT_RAM_MB" ]; then
    log "!! CRITICO: ${TOTAL_RAM} MB — ejecutando nivel 3"
    clean_sessions
    restart_lights
    sleep 2
    restart_heaviest
elif [ "$TOTAL_RAM" -ge "$WARN_RAM_MB" ]; then
    log "!! ALTO: ${TOTAL_RAM} MB — ejecutando nivel 2"
    clean_sessions
    restart_lights
elif [ "$TOTAL_RAM" -ge 350 ]; then
    log ">> MEDIO: ${TOTAL_RAM} MB — ejecutando nivel 1"
    clean_sessions
else
    log "OK: ${TOTAL_RAM} MB — dentro del limite"
fi

# Verificar estado post-limpieza
sleep 3
FINAL_RAM=$(get_total_ram)
log "RAM post-limpieza: ${FINAL_RAM} MB"

if [ "$FINAL_RAM" -ge "$MAX_RAM_MB" ]; then
    log "!! No se pudo reducir bajo ${MAX_RAM_MB} MB. Forzando reinicio total..."
    docker restart nexus-deepseek nexus-antigravity nexus-codex >/dev/null 2>&1 || true
    sleep 5
    EMERGENCY_RAM=$(get_total_ram)
    log "RAM post-emergencia: ${EMERGENCY_RAM} MB"
fi

log "========================================"
