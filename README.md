# Nexus Agents — Docker Compose Unificado

Stack unificado de los 5 agentes CLI de **Xtreme Diagnostics** listo para
levantar en cualquier servidor con Docker.

## Agentes incluidos

| Agente | Puerto | URL |
|--------|--------|-----|
| **DeepSeek TUI / CodeWhale** | 7681 | `https://deepseek.xtremediagnostics.com` |
| **Gemini CLI** | 7682 | `https://gemini.xtremediagnostics.com` |
| **Antigravity CLI** | 7683 | `https://antigravity.xtremediagnostics.com` |
| **Minimax CLI** | 7684 | `https://minimax.xtremediagnostics.com` |
| **Codex CLI** | 7685 | `https://codex.xtremediagnostics.com` |

## Requisitos

- Docker Engine 24+ con `docker compose` (no el legacy `docker-compose`)
- Credenciales de túneles Cloudflare (archivos JSON en `./tunnels/`)
- Conexión a internet (los contenedores descargan `cloudflared` al iniciar)
- API keys de cada agente configuradas en `.env`

## Instalación rápida

```bash
# 1. Clonar
git clone <repo-url> nexus-agents
cd nexus-agents

# 2. Configurar variables
cp .env.example .env
# Editar .env con tus API keys reales

# 3. Crear carpeta de credenciales y colocar los JSON de Cloudflare
mkdir -p tunnels
# Copia cada tunnel-ID.json a tunnels/gemini.json, tunnels/antigravity.json, etc.

# 4. Crear el workspace (o usar uno existente)
mkdir -p /config/ERP-DOCKER-STACK

# 5. Levantar
docker compose up -d

# 6. Verificar
docker compose ps
docker compose logs -f
```

## Workspace compartido

Todos los agentes comparten el mismo workspace:
- **Dentro del contenedor**: `/workspace`
- **En el host**: definido por `WORKSPACE_PATH` en `.env` (default: `/config/ERP-DOCKER-STACK`)

## Estructura de archivos

```
nexus-agents/
├── docker-compose.yml    # Stack unificado
├── .env.example          # Plantilla de variables
├── .env                  # Variables (gitignored)
├── .gitignore
├── README.md
└── tunnels/              # Credenciales Cloudflare (gitignored)
    ├── gemini.json
    ├── antigravity.json
    ├── minimax.json
    └── codex.json
```

## Notas

- Todos los agentes usan `network_mode: host` para máxima compatibilidad
- Los túneles Cloudflare se auto-levantan dentro de cada contenedor
- DeepSeek usa un túnel separado (`cloudflared-deepseek`) con configuración remota
- Las imágenes Docker (`nexus-*`) deben existir o construirse previamente
