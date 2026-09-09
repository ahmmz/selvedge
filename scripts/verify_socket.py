#!/usr/bin/env python3
"""Assert the Docker-socket layout of a resolved Compose configuration.

Reads `docker compose ... config --format json` on stdin and checks, for the
given mode, that only the expected services mount the socket and that the
rootless socket-proxy rewrites are in place. Exits non-zero with a message on
the first mismatch. Called by compose.sh validate.

Usage: verify_socket.py <mode>   # config JSON on stdin
"""
import json
import sys

# Services expected to reach the Docker socket in each mode.
EXPECTED_CONSUMERS = {
    "base": {"traefik"},
    "dozzle": {"traefik", "dozzle"},
    "rootless": {"traefik-socket-proxy"},
    "rootless-dozzle": {"traefik-socket-proxy"},
    "full": {"traefik-socket-proxy"},
}

PROXY_ENDPOINT = "tcp://traefik-socket-proxy:2375"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_socket.py <mode>  # config JSON on stdin")
    mode = sys.argv[1]
    if mode not in EXPECTED_CONSUMERS:
        raise SystemExit(f"Unknown mode: {mode}")

    config = json.load(sys.stdin)
    expected = EXPECTED_CONSUMERS[mode]

    consumers = set()
    for name, service in config.get("services", {}).items():
        for volume in service.get("volumes", []):
            if volume.get("source") == "/var/run/docker.sock":
                consumers.add(name)
    if consumers != expected:
        raise SystemExit(
            f"{mode}: expected socket consumers {sorted(expected)}, got {sorted(consumers)}"
        )

    if mode in {"rootless", "rootless-dozzle", "full"}:
        traefik = config["services"]["traefik"]
        socket_mounts = [
            v for v in traefik.get("volumes", []) if v.get("target") == "/var/run/docker.sock"
        ]
        if len(socket_mounts) != 1 or socket_mounts[0].get("source") != "/dev/null":
            raise SystemExit(f"{mode}: Traefik host socket mount was not replaced")
        endpoint = traefik.get("environment", {}).get("TRAEFIK_PROVIDERS_DOCKER_ENDPOINT")
        if endpoint != PROXY_ENDPOINT:
            raise SystemExit(f"{mode}: Traefik socket proxy endpoint is missing")
        if len(traefik.get("command", [])) < 30:
            raise SystemExit(f"{mode}: Traefik base command was unexpectedly replaced")

    if mode in {"rootless-dozzle", "full"}:
        dozzle = config["services"]["dozzle"]
        socket_mounts = [
            v for v in dozzle.get("volumes", []) if v.get("target") == "/var/run/docker.sock"
        ]
        if len(socket_mounts) != 1 or socket_mounts[0].get("source") != "/dev/null":
            raise SystemExit(f"{mode}: Dozzle host socket mount was not replaced")
        endpoint = dozzle.get("environment", {}).get("DOCKER_HOST")
        if endpoint != PROXY_ENDPOINT:
            raise SystemExit(f"{mode}: Dozzle socket proxy endpoint is missing")


if __name__ == "__main__":
    main()
