#!/usr/bin/env bash
#
# Selvedge Compose helper.
#
# Manages component dependency wiring and validates every supported Compose
# combination. Both subcommands read the same Selvedge-Depends-On /
# Selvedge-Auto-Enable metadata, so the parsing lives in one place here.
#
# Usage:
#   compose.sh sync <enable|disable> <name>   Resolve and (de)activate deps
#   compose.sh validate                       Validate all Compose combinations
#   compose.sh help                           Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SELVEDGE_PROJECT_ROOT:-$(dirname "${SCRIPT_DIR}")}"
COMPOSE_DIR="${PROJECT_ROOT}/etc/compose"
TRAEFIK_DIR="${PROJECT_ROOT}/etc/traefik"

usage() {
    sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# Shared metadata parsing
# --------------------------------------------------------------------------

# Print the space-separated dependency list a fragment declares, or nothing.
dependencies_for() {
    local file="$1"
    [ -f "${file}" ] || return 0
    sed -n 's/^# Selvedge-Depends-On:[[:space:]]*//p' "${file}" | head -n 1
}

# Print the Selvedge-Auto-Enable value a fragment declares, or nothing.
auto_enable_value_for() {
    local file="$1"
    [ -f "${file}" ] || return 0
    sed -n 's/^# Selvedge-Auto-Enable:[[:space:]]*//p' "${file}" | head -n 1
}

# Dependencies declared by a component, looked up by name (override fragments).
component_dependencies() {
    dependencies_for "${COMPOSE_DIR}/overrides-available/${1}.yml"
}

# --------------------------------------------------------------------------
# sync: resolve dependencies and (de)activate components
# --------------------------------------------------------------------------

component_exists() {
    local name="$1"
    [ -f "${COMPOSE_DIR}/services-available/${name}.yml" ] ||
        [ -f "${COMPOSE_DIR}/overrides-available/${name}.yml" ] ||
        [ -f "${TRAEFIK_DIR}/available/${name}.yml" ]
}

component_enabled() {
    local name="$1"
    [ -e "${COMPOSE_DIR}/services-enabled/${name}.yml" ] ||
        [ -e "${COMPOSE_DIR}/overrides-enabled/${name}.yml" ] ||
        [ -e "${TRAEFIK_DIR}/enabled/${name}.yml" ]
}

enable_component() {
    local name="$1"

    if ! component_enabled "${name}"; then
        echo "==> Enabling dependency '${name}' ..."
    fi
    if [ -f "${COMPOSE_DIR}/services-available/${name}.yml" ]; then
        ln -sf "${COMPOSE_DIR}/services-available/${name}.yml" \
            "${COMPOSE_DIR}/services-enabled/${name}.yml"
    fi
    if [ -f "${COMPOSE_DIR}/overrides-available/${name}.yml" ]; then
        ln -sf "${COMPOSE_DIR}/overrides-available/${name}.yml" \
            "${COMPOSE_DIR}/overrides-enabled/${name}.yml"
    fi
    if [ -f "${TRAEFIK_DIR}/available/${name}.yml" ]; then
        cp -f "${TRAEFIK_DIR}/available/${name}.yml" \
            "${TRAEFIK_DIR}/enabled/${name}.yml"
    fi
}

declare -A resolving=()

enable_with_dependencies() {
    local name="$1"
    local dependency

    if [ "${resolving[${name}]:-}" = "true" ]; then
        echo "Dependency cycle detected at '${name}'" >&2
        exit 1
    fi
    resolving["${name}"]=true

    for dependency in $(component_dependencies "${name}"); do
        if ! component_exists "${dependency}"; then
            echo "Unknown dependency '${dependency}' declared by '${name}'" >&2
            exit 1
        fi
        enable_with_dependencies "${dependency}"
    done

    enable_component "${name}"
    unset "resolving[${name}]"
}

cmd_sync() {
    local action="${1:-}"
    local requested="${2:-}"

    if [ -z "${action}" ] || [ -z "${requested}" ]; then
        echo "Usage: compose.sh sync <enable|disable> <name>" >&2
        exit 1
    fi
    if [ "${action}" != "enable" ] && [ "${action}" != "disable" ]; then
        echo "Unsupported dependency action: ${action}" >&2
        exit 1
    fi

    if [ "${action}" = "enable" ]; then
        enable_with_dependencies "${requested}"
    fi

    # Only explicitly marked integration overrides are activated automatically.
    local available name dependencies dependency dependencies_ready enabled
    for available in "${COMPOSE_DIR}"/overrides-available/*.yml; do
        [ -e "${available}" ] || continue
        [ "$(auto_enable_value_for "${available}")" = "true" ] || continue
        name="$(basename "${available}" .yml)"
        dependencies="$(component_dependencies "${name}")"
        dependencies_ready=true
        for dependency in ${dependencies}; do
            if ! component_enabled "${dependency}"; then
                dependencies_ready=false
                break
            fi
        done

        if [ -n "${dependencies}" ] && [ "${dependencies_ready}" = "true" ]; then
            if [ ! -e "${COMPOSE_DIR}/overrides-enabled/${name}.yml" ]; then
                echo "==> Enabling dependent override '${name}' ..."
            fi
            enable_with_dependencies "${name}"
        fi
    done

    # Remove an enabled override when any declared dependency is off.
    for enabled in "${COMPOSE_DIR}"/overrides-enabled/*.yml; do
        if [ -L "${enabled}" ] && [ ! -e "${enabled}" ]; then
            echo "==> Removing stale override '$(basename "${enabled}" .yml)' ..."
            rm -f "${enabled}"
            continue
        fi
        [ -e "${enabled}" ] || continue
        name="$(basename "${enabled}" .yml)"
        for dependency in $(component_dependencies "${name}"); do
            if ! component_enabled "${dependency}"; then
                echo "==> Disabling dependent override '${name}' ..."
                rm -f "${enabled}"
                break
            fi
        done
    done
}

# --------------------------------------------------------------------------
# validate: check every supported Compose combination
# --------------------------------------------------------------------------

cmd_validate() {
    local COMPOSE=(docker compose --env-file "${PROJECT_ROOT}/.env.example" --project-directory "${PROJECT_ROOT}")
    local BASE=(-f "${PROJECT_ROOT}/docker-compose.yml")

    # Required production secrets use harmless values during structural checks.
    export AUTHELIA_JWT_SECRET="${AUTHELIA_JWT_SECRET:-validation-only-jwt-secret-0000000000000000000000000000000000000000}"
    export AUTHELIA_SESSION_SECRET="${AUTHELIA_SESSION_SECRET:-validation-only-session-secret-0000000000000000000000000000000000000}"
    export AUTHELIA_STORAGE_KEY="${AUTHELIA_STORAGE_KEY:-validation-only-storage-key-00000000000000000000000000000000000000}"
    export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-validation-only-grafana-password}"

    validate() {
        "${COMPOSE[@]}" "${BASE[@]}" "$@" config --quiet
    }

    validate

    local service_files override_files crowdsec_file
    service_files=("${PROJECT_ROOT}"/etc/compose/services-available/*.yml)
    override_files=("${PROJECT_ROOT}"/etc/compose/overrides-available/*.yml)
    crowdsec_file="${PROJECT_ROOT}/etc/compose/services-available/crowdsec.yml"

    local override_file dependencies auto_enable dependency
    for override_file in "${override_files[@]}"; do
        dependencies="$(dependencies_for "${override_file}")"
        auto_enable="$(auto_enable_value_for "${override_file}")"
        if [ "${auto_enable}" = "true" ] && [ -z "${dependencies}" ]; then
            echo "$(basename "${override_file}"): automatic overrides must declare dependencies" >&2
            exit 1
        fi
        for dependency in ${dependencies}; do
            if [ ! -f "${PROJECT_ROOT}/etc/compose/services-available/${dependency}.yml" ] && \
                [ ! -f "${PROJECT_ROOT}/etc/compose/overrides-available/${dependency}.yml" ] && \
                [ ! -f "${PROJECT_ROOT}/etc/traefik/available/${dependency}.yml" ]; then
                echo "$(basename "${override_file}"): unknown dependency ${dependency}" >&2
                exit 1
            fi
        done
    done

    local service_file
    for service_file in "${service_files[@]}"; do
        validate -f "${service_file}"
    done

    for override_file in "${override_files[@]}"; do
        case "$(basename "${override_file}")" in
            rootless-dozzle.yml)
                validate \
                    -f "${PROJECT_ROOT}/etc/compose/services-available/dozzle.yml" \
                    -f "${PROJECT_ROOT}/etc/compose/overrides-available/rootless.yml" \
                    -f "${override_file}"
                ;;
            crowdsec-cti.yml)
                validate \
                    -f "${crowdsec_file}" \
                    -f "${PROJECT_ROOT}/etc/compose/services-available/monitoring.yml" \
                    -f "${override_file}"
                ;;
            crowdsec-*.yml)
                validate -f "${crowdsec_file}" -f "${override_file}"
                ;;
            node-exporter.yml)
                validate \
                    -f "${PROJECT_ROOT}/etc/compose/services-available/monitoring.yml" \
                    -f "${override_file}"
                ;;
            *)
                validate -f "${override_file}"
                ;;
        esac
    done

    local all_flags=()
    for service_file in "${service_files[@]}"; do
        all_flags+=(-f "${service_file}")
    done
    for override_file in "${override_files[@]}"; do
        all_flags+=(-f "${override_file}")
    done
    validate "${all_flags[@]}"

    verify_socket_layout() {
        local mode="$1"
        shift
        "${COMPOSE[@]}" "${BASE[@]}" "$@" config --format json \
            | python3 "${SCRIPT_DIR}/verify_socket.py" "${mode}"
    }

    verify_socket_layout base
    verify_socket_layout dozzle -f "${PROJECT_ROOT}/etc/compose/services-available/dozzle.yml"
    verify_socket_layout rootless -f "${PROJECT_ROOT}/etc/compose/overrides-available/rootless.yml"
    verify_socket_layout rootless-dozzle \
        -f "${PROJECT_ROOT}/etc/compose/services-available/dozzle.yml" \
        -f "${PROJECT_ROOT}/etc/compose/overrides-available/rootless.yml" \
        -f "${PROJECT_ROOT}/etc/compose/overrides-available/rootless-dozzle.yml"
    verify_socket_layout full "${all_flags[@]}"

    if command -v envsubst >/dev/null 2>&1; then
        local rendered_template
        rendered_template="$(mktemp "${TMPDIR:-/tmp}/selvedge-service.XXXXXX.yml")"
        ARGX_LOCASED=validation envsubst '${ARGX_LOCASED}' \
            < "${PROJECT_ROOT}/etc/templates/service.template" \
            > "${rendered_template}"
        validate -f "${rendered_template}"
        rm -f "${rendered_template}"
    fi

    echo "All Selvedge Compose configurations are valid."
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------

main() {
    local command="${1:-help}"
    shift || true

    case "${command}" in
        sync)      cmd_sync "$@" ;;
        validate)  cmd_validate "$@" ;;
        help|-h|--help)  usage ;;
        *)
            echo "Unknown command: ${command}" >&2
            echo >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
