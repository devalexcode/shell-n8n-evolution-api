#!/usr/bin/env bash
set -euo pipefail

# Colores ANSI
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color (reset)

# ─────────────────────────────────────────────────────────────────────────────
# Cargar variables de entorno del .env (requiere que exista en el mismo directorio)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f .env ]]; then
    set -a && source .env && set +a
else
    echo "ERROR: No se encontró el archivo .env. Crea uno."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Determinar protocolo y configuración de cookie según N8N_HOST
# ─────────────────────────────────────────────────────────────────────────────

# Obtener IP pública (global)
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com || curl -s https://icanhazip.com)

if [[ $N8N_URL == "PUBLIC_IP" ]]; then
    N8N_URL="http://${PUBLIC_IP}:${N8N_PORT}"
fi

if [[ $N8N_URL =~ https ]]; then
    N8N_PROTOCOL="https"
    N8N_SECURE_COOKIE="true"
else
    N8N_PROTOCOL="http"
    N8N_SECURE_COOKIE="false"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Determinar el host mediante N8N_URL
# ─────────────────────────────────────────────────────────────────────────────

tmp=${N8N_URL#*://}
N8N_HOST=${tmp%%[:/]*}

# ─────────────────────────────────────────────────────────────────────────────
# Actualizar repositorios y paquetes
# ─────────────────────────────────────────────────────────────────────────────
sudo apt update && sudo apt upgrade -y

# ─────────────────────────────────────────────────────────────────────────────
# Instalar prerequisitos (si faltan)
# ─────────────────────────────────────────────────────────────────────────────
sudo apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# ─────────────────────────────────────────────────────────────────────────────
# Instalación de Docker (si no está instalado)
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker no encontrado. Instalando Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
        sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" |
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    echo -e "${GREEN}Docker instalado: $(docker --version)${NC}"
else
    echo "Docker ya está instalado: $(docker --version)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Instalación de Docker Compose CLI plugin (si no está instalado)
# ─────────────────────────────────────────────────────────────────────────────
if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose CLI plugin no encontrado. Instalando..."
    sudo apt-get install -y docker-compose-plugin
    echo -e "${GREEN}Docker Compose instalado: $(docker compose version)${NC}"
else
    echo "Docker Compose ya está instalado: $(docker compose version)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Instalación de n8n (si no está instalado)
# ─────────────────────────────────────────────────────────────────────────────
if sudo docker container inspect n8n >/dev/null 2>&1; then
    echo "n8n ya está instalado y configurado."
else
    echo "Instalando n8n..."
    sudo docker volume create n8n_data

    sudo docker run -d --name n8n --restart=always \
        -p "${N8N_PORT}":5678 \
        -v n8n_data:/home/node/.n8n \
        -e TZ="${N8N_TIME_ZONE}" \
        -e GENERIC_TIMEZONE="${N8N_TIME_ZONE}" \
        -e N8N_SECURE_COOKIE="${N8N_SECURE_COOKIE}" \
        -e N8N_PROTOCOL="${N8N_PROTOCOL}" \
        -e N8N_HOST="${N8N_HOST}" \
        -e N8N_EDITOR_BASE_URL="${N8N_URL}" \
        -e WEBHOOK_URL="${N8N_URL}" \
        n8nio/n8n:latest

    echo -e "${GREEN}n8n instalado${NC}"

    # Notificar si se ha deshabilitado la cookie secure
    if [[ "${N8N_SECURE_COOKIE}" == "false" ]]; then
        echo "ADVERTENCIA: la cookie 'secure' está deshabilitada (N8N_SECURE_COOKIE=false)."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Instalación de Evolution API (si no está instalado)
# ─────────────────────────────────────────────────────────────────────────────
if sudo docker container evolution_api >/dev/null 2>&1; then
    echo "Evolution API ya está instalado y configurado."
else
    echo "Instalando  Evolution API y servicios (corriendo docker-compose.yml) ..."
    sudo docker compose up -d

    echo -e "${GREEN} Evolution API y servicios instalados${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Instalación de Portainer (si no está instalado)
# ─────────────────────────────────────────────────────────────────────────────
if sudo docker container inspect portainer >/dev/null 2>&1; then
    echo "Portainer ya está instalado y configurado."
else
    echo "Instalando Portainer..."
    sudo docker volume create portainer_data
    sudo docker run -d --name portainer --restart=always \
        -p 8000:8000 -p "${PORTAINER_PORT}":9000 \
        -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
        portainer/portainer-ce
    sudo docker restart portainer
    echo -e "${GREEN}Portainer instalado${NC}"
fi

CHECK_APP_MAX_ATTEMPTS=5
CHECK_APP_DELAY_SECONDS=5

# Función para validar que un puerto esté accesible externamente para una aplicación
# Recibe Puerto y Nombre de la Aplicación
# Realiza hasta CHECK_APP_MAX_ATTEMPTS intentos con CHECK_APP_DELAY_SECONDS segundos de delay. Si tras CHECK_APP_MAX_ATTEMPTS fallos, muestra error y termina.
check_port_open() {
    local PORT=$1
    local APP_NAME=$2
    local attempt=1

    while ((attempt <= CHECK_APP_MAX_ATTEMPTS)); do

        echo -e "Verificando acceso a ${APP_NAME} . . . "

        sleep ${CHECK_APP_DELAY_SECONDS}
        # Verificar respuesta del VPS
        if nc -z -w5 "${PUBLIC_IP}" "${PORT}"; then
            echo -e "${GREEN}¡Instalación completada! ${APP_NAME} funcionando y accesible: http://${PUBLIC_IP}:${PORT}${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
    done

    # Si llegamos aquí, todos los intentos fallaron
    echo -e "${RED}Error: El puerto ${PORT} para ${APP_NAME} no es accesible externamente en ${PUBLIC_IP}:${PORT}. Verifica las reglas de entrada / firewall de tu servidor VPS.${NC}"
}

check_port_open "${N8N_PORT}" "n8n"
check_port_open "${EVOLUTION_API_PORT}" "Evolution API"
check_port_open "${PORTAINER_PORT}" "Portainer"

# Refrescar grupos para la sesión actual
newgrp docker
