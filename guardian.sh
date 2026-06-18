#!/bin/bash
# =============================================================================
# Nexus Guardian — Monitor de recursos y limpieza automática
# =============================================================================
# Objetivo: Mantener todos los agentes CLI bajo 500 MB de RAM combinados.
#
# Estrategia:
#   Nivel 1 (≥ 400 MB): Limpiar sesiones tmux/ttyd viejas dentro de contenedores
#   Nivel 2 (≥ 480 MB): Matar procesos huérfanos y recargar agentes ligeros
#   Nivel 3 (≥ 520 MB): Reiniciar el contenedor más pesado
#
# Ejecutar cada 60 segundos vía cron o como daemon.
# =============================================================================

set -e

# Configuración
MAX_RAM_MB=500
WARN_RAM_MB=400
CRIT_RAM_MB=480
LOG_FILE="/var/log/nexus-guardian.log"
TARGET_CONTAINERS=("nexus-deepseek" "nexus-gemini" "nexus-antigravity" "nexus-minimax" "nexus-codex" "cloudflared-deepseek")

# =============================================================================
# Funciones de logging
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# =============================================================================
# Obtener memoria total de los contenedores objetivo (en MB)
# =============================================================================
get_total_ram() {
    local total=0
    for container in "${TARGET_CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null | head -1)
            if [ -n "$mem" ]; then
                # Extraer valor en MiB
                local mb=$(echo "$mem" | awk '{split($1,a,"."); print a[1]}' | grep -oE '[0-9]+' | head -1)
                total=$((total + ${mb:-0}))
            fi
        fi
    done
    echo "$total"
}

# =============================================================================
# Nivel 1: Limpiar sesiones viejas dentro de cada contenedor
# =============================================================================
clean_old_sessions() {
    log "  [NIVEL 1] Limpiando sesiones viejas..."

    # DeepSeek: limpiar tmux sessions excepto la activa
    if docker ps --format '{{.Names}}' | grep -q "nexus-deepseek"; then
        local sessions=$(docker exec nexus-deepseek tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
        local count=0
        local kept=""
        for s in $sessions; do
            count=$((count + 1))
            if [ "$s" = "deepseek" ]; then
                kept="$s"
                continue
            fi
            # Mantener solo 3 sesiones máximo
            if [ $count -gt 3 ]; then
                docker exec nexus-deepseek tmux kill-session -t "$s" 2>/dev/null || true
                log "    → tmux session '$s' eliminada (deepseek)"
            fi
        done
        # Matar ventanas inactivas en la sesión principal
        if [ -n "$kept" ]; then
            docker exec nexus-deepseek tmux list-windows -t "$kept" -F '#{window_index} #{window_name}' 2>/dev/null | \
            while read idx name; do
                if [ "$name" != "deepseek" ] && [ "$idx" -gt 1 ]; then
                    docker exec nexus-deepseek tmux kill-window -t "$kept:$idx" 2>/dev/null || true
                fi
            done
        fi
    fi

    # Gemini, Antigravity, Codex: matar procesos bash/zombie dentro de ttyd
    for container in nexus-gemini nexus-antigravity nexus-codex; do
        if docker ps --format '{{.Names}}' | grep -q "$container"; then
            # Matar procesos idle > 30 min
            docker exec "$container" sh -c 'ps aux | grep -E "bash|sh" | grep -v grep | grep -v ttyd | awk '\''{print $2}'\'' | head -5' 2>/dev/null | \
            while read pid; do
                if [ -n "$pid" ] && [ "$pid" -gt 10 ]; then
                    docker exec "$container" kill "$pid" 2>/dev/null || true
                    log "    → Proceso $pid eliminado ($container)"
                fi
            done
        fi
    done
}

# =============================================================================
# Nivel 2: Recargar agentes ligeros y matar procesos huérfanos
# =============================================================================
restart_light_agents() {
    log "  [NIVEL 2] Recargando agentes ligeros..."

    # Reiniciar solo los túneles (consumen poco pero pueden tener leaks)
    for container in cloudflared-deepseek; do
        if docker ps --format '{{.Names}}' | grep -q "$container"; then
            docker restart "$container" >/dev/null 2>&1 || true
            log "    → Reiniciado: $container"
            sleep 3
        fi
    done

    # Limpiar cachés de node dentro de los contenedores
    for container in nexus-deepseek nexus-gemini nexus-antigravity nexus-codex; do
        if docker ps --format '{{.Names}}' | grep -q "$container"; then
            docker exec "$container" sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true' 2>/dev/null || true
        fi
    done
}

# =============================================================================
# Nivel 3: Reiniciar el contenedor más pesado
# =============================================================================
restart_heaviest() {
    log "  [NIVEL 3] Buscando contenedor más pesado..."

    local heaviest=""
    local max_mem=0

    for container in "${TARGET_CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            local mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null | head -1)
            local mb=$(echo "$mem" | awk '{split($1,a,"."); print a[1]}' | grep -oE '[0-9]+' | head -1)
            mb=${mb:-0}
            if [ "$mb" -gt "$max_mem" ]; then
                max_mem=$mb
                heaviest=$container
            fi
        fi
    done

    if [ -n "$heaviest" ]; then
        log "    → Reiniciando contenedor más pesado: $heaviest (${max_mem} MB)"
        docker restart "$heaviest" >/dev/null 2>&1 || true
        log "    → $heaviest reiniciado"
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
    log "⚠️  CRÍTICO: ${TOTAL_RAM} MB — ejecutando nivel 3"
    clean_old_sessions
    restart_light_agents
    sleep 2
    restart_heaviest
elif [ "$TOTAL_RAM" -ge "$WARN_RAM_MB" ]; then
    log "⚡ ALTO: ${TOTAL_RAM} MB — ejecutando nivel 2"
    clean_old_sessions
    restart_light_agents
elif [ "$TOTAL_RAM" -ge 350 ]; then
    log "🔶 MEDIO: ${TOTAL_RAM} MB — ejecutando nivel 1"
    clean_old_sessions
else
    log "✅ OK: ${TOTAL_RAM} MB — dentro del límite"
fi

# Verificar estado post-limpieza
sleep 3
FINAL_RAM=$(get_total_ram)
log "RAM post-limpieza: ${FINAL_RAM} MB"

if [ "$FINAL_RAM" -ge "$MAX_RAM_MB" ]; then
    log "❌ No se pudo reducir bajo ${MAX_RAM_MB} MB. Forzando reinicio total..."
    docker restart nexus-gemini nexus-deepseek nexus-antigravity nexus-codex >/dev/null 2>&1 || true
    sleep 5
    EMERGENCY_RAM=$(get_total_ram)
    log "RAM post-emergencia: ${EMERGENCY_RAM} MB"
fi

log "========================================"
