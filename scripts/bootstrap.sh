#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

if [ ! -f "${PROJECT_ROOT}/.env" ]; then
    echo "[+] Creating .env from .env.example..."
    cp "${PROJECT_ROOT}/.env.example" "${PROJECT_ROOT}/.env"
fi
chmod 600 "${PROJECT_ROOT}/.env"

if [ ! -d "${PROJECT_ROOT}/data/log/traefik" ]; then
    echo "[+] Creating Traefik log directory..."
    mkdir -p "${PROJECT_ROOT}/data/log/traefik"
fi

if [ ! -d "${PROJECT_ROOT}/etc/traefik/enabled" ]; then
    mkdir -p "${PROJECT_ROOT}/etc/traefik/enabled"
fi

if [ ! -f "${PROJECT_ROOT}/etc/traefik/enabled/default.yml" ] && [ -f "${PROJECT_ROOT}/etc/traefik/available/default.yml" ]; then
    echo "[+] Initializing default Traefik dynamic configuration..."
    cp "${PROJECT_ROOT}/etc/traefik/available/default.yml" "${PROJECT_ROOT}/etc/traefik/enabled/default.yml"
fi

cleanup_stale_networks() {
    local containers
    containers=$(docker compose ps -a --format '{{.Name}}' 2>/dev/null || true)
    for c in ${containers}; do
        [ -z "${c}" ] && continue
        if [ "$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || true)" = "false" ]; then
            local networks
            networks=$(docker inspect "${c}" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)
            for n in ${networks}; do
                [ -z "${n}" ] && continue
                docker network disconnect -f "${n}" "${c}" &>/dev/null || true
            done
        fi
    done
}

cleanup_stale_networks

exit 0
