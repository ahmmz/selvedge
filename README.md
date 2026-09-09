# Selvedge

Selvedge is a shared Traefik edge stack for independent Docker Compose
projects. It creates an external Docker network named `selvedge`. Other stacks
join that network and publish services through Traefik labels.

One Selvedge instance can route public services and private internal services.
Each router selects its DNS name, certificate, access rules, and authentication.
Internal and public routes can run together without publishing application ports
on the host.

The base stack runs only Traefik. Optional Compose fragments add authentication,
request filtering, logs, monitoring, error pages, and Docker socket isolation.
Make targets enable these components and resolve their declared dependencies.

## Main features

- One Traefik instance for multiple Compose projects
- Internal and public routes with per-router access controls
- Docker and file-provider routes
- HTTP-to-HTTPS redirection, strict SNI, TLS 1.3, and security headers
- Local `mkcert` certificates and Let's Encrypt wildcard certificates
- Optional Authelia, CrowdSec, Dozzle, Prometheus, Grafana, and error pages
- Optional shared socket proxy for Traefik and Dozzle
- Compose validation across all supported service and override combinations
- Backup, report, and systemd targets

## Requirements

The base stack needs Linux, Docker Compose v2, GNU Make, Python 3, and OpenSSL.
Install `mkcert` for local certificates. Install `envsubst` for service creation
and systemd installation.

## Quick start

Prepare the environment file:

```bash
cp .env.example .env
chmod 600 .env
${EDITOR:-vi} .env
```

Replace the example `*.selvedge.local` hostnames with names that resolve to this
host. Authelia also has domain values in
`etc/config/authelia/configuration.yml`.

Validate and start Selvedge:

```bash
make validate
make start
```

Selvedge publishes ports 80 and 443 and creates the `selvedge` Docker network.
The Docker provider does not expose containers by default.

## Connect another Compose stack

Declare `selvedge` as an external network in the other stack:

```yaml
networks:
  app:
    name: app
    driver: bridge

  selvedge:
    external: true
```

Attach only the service that Traefik must reach. Add its route labels:

```yaml
services:
  web:
    image: vendor/web:latest
    networks:
      - app
      - selvedge
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.web.rule=Host(`web.example.com`)"
      - "traefik.http.routers.web.entrypoints=websecure"
      - "traefik.http.services.web.loadbalancer.server.port=3000"
```

Start Selvedge before the application stack so that the external network exists:

```bash
docker network inspect selvedge
docker compose up -d
```

The application does not need a published host port for HTTP traffic. Traefik
connects to port 3000 through the shared network. Keep databases and internal
workers on the application network only.

Selvedge configures `selvedge` as the default network for the Traefik Docker
provider. Application stacks do not need a network-selection label.

## Internal and public applications

Joining the `selvedge` network does not make a service public. Traefik creates a
route only for a service that has `traefik.enable=true` and router labels.

Use these controls for each route:

| Route | DNS and certificate | Access controls |
| --- | --- | --- |
| Internal | Private DNS with a local `mkcert` certificate | `rfc1918@file` and optional `authelia@file` |
| Public | Public DNS with a Let's Encrypt certificate | Optional `crowdsec@file`, `rate-limit@file`, `geoblock@file`, and `authelia@file` |

For an internal application, restrict the router by source network:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.admin.rule=Host(`admin.internal.example`)"
  - "traefik.http.routers.admin.entrypoints=websecure"
  - "traefik.http.routers.admin.middlewares=rfc1918@file"
  - "traefik.http.services.admin.loadbalancer.server.port=3000"
```

If the internal route also needs user authentication, add `authelia@file`. For
a public route, select the public hostname and the middleware required by that
application.

Private DNS alone is not an access control. Keep `rfc1918@file`, a firewall, or
another explicit access policy on every private route. If a proxy or VPN is in
front of Selvedge, configure `TRUSTED_IPS` so Traefik evaluates the correct
client address.

## Components

Enable or disable a component by name:

```bash
make enable crowdsec
make enable authelia
make disable authelia
make restart
```

`make enable NAME` activates matching service, override, and Traefik files.
Dependencies come from `Selvedge-Depends-On` metadata in each override.

### Services

| Name | Purpose | Required configuration |
| --- | --- | --- |
| `authelia` | Forward authentication and two-factor access policy | Secrets, hostname, and domain configuration |
| `crowdsec` | Analyze Traefik access logs and provide bouncer decisions | Bouncer API key |
| `dozzle` | View container logs | Hostname |
| `error-pages` | Serve responses for HTTP errors | Optional theme |
| `monitoring` | Run Prometheus, Grafana, Loki, and Promtail | Grafana password, hostnames, and `TRAEFIK_ACCESSLOG_FORMAT=json` for logs |

### Overrides

| Name | Purpose |
| --- | --- |
| `rootless` | Run Traefik as `PUID:PGID` and use a restricted socket proxy |
| `rootless-dozzle` | Connect Dozzle to the same proxy. Selvedge manages this automatically |
| `crowdsec-host` | Read host logs and bind CrowdSec LAPI to `127.0.0.1:8080` |
| `crowdsec-appsec` | Install additional CrowdSec AppSec collections |
| `crowdsec-lapi` | Route CrowdSec LAPI through Traefik |
| `crowdsec-cti` | Add a Grafana Crowdsec CTI dashboard, backed by VictoriaMetrics |
| `node-exporter` | Add host CPU, memory, disk, and network metrics |

### Middleware

The default file provides security headers, compression, rate limits, private
network rules, Cloudflare allowlists, and TLS profiles. Optional files provide
Authelia, CrowdSec, geoblocking, and error-page middleware.

Reference file-provider middleware from Docker labels with the `@file` suffix:

```yaml
labels:
  - "traefik.http.routers.web.middlewares=crowdsec@file,authelia@file"
```

Middleware order changes request behavior. Add only the middleware required by
the route.

#### What every route gets by default

Every route on the `websecure` entrypoint runs the `default` chain from
`etc/traefik/available/default.yml`. Router labels add to this chain, they do not
replace it.

Out of the box that chain applies security headers and nothing else. CrowdSec,
geoblocking, error pages, and compression are in the file but commented out.
Enabling an add-on starts its service and defines its middleware, but no request
passes through that middleware until you attach it.

You have two ways to attach one:

- To protect a single route, name the middleware on that router.
- To protect every route at once, uncomment its line in the `default` chain.

Define a middleware before you add it to the chain. A chain that names a missing
middleware breaks every route on the entrypoint.

## Docker socket modes

Traefik mounts `/var/run/docker.sock` read-only by default. Without `rootless`,
Dozzle uses its own read-only mount.

Enable the socket proxy with:

```bash
make enable rootless
make restart
```

This override runs Traefik as `PUID:PGID` and limits Docker API requests through
one proxy. If Dozzle is enabled, Selvedge activates `rootless-dozzle` and reuses
the same proxy.

Set `DOCKER_GID` to the group that owns the host socket:

```bash
stat -c '%g' /var/run/docker.sock
```

The selected `PUID` and `PGID` also need write access to `etc/letsencrypt/` and
`data/log/traefik/`.

## Certificates

The bootstrap process creates an anonymous OpenSSL fallback certificate.

For local domains, install `mkcert` and run:

```bash
make cert-add app.internal
make cert-list
make restart
```

Each internal client must trust the local `mkcert` certificate authority.

For public domains, set `CF_DNS_API_TOKEN` in `.env` and run:

```bash
make le-add example.com
make le-list
make restart
```

The Let's Encrypt workflow requests the base domain and its wildcard through a
DNS-01 challenge. The default DNS provider is Cloudflare.

`etc/mkcert/` and `etc/letsencrypt/` hold private keys. Restrict access to these
directories and include them in your backups.

## CrowdSec

Enable CrowdSec and create a bouncer key:

```bash
make enable crowdsec
make start
docker exec crowdsec cscli bouncers add traefik-bouncer
```

Set `CROWDSEC_BOUNCER_API_KEY` in `.env`. Restart Selvedge and attach
`crowdsec@file` to each protected router.

CrowdSec reads logs and raises alerts as soon as the service runs. It blocks
nothing until a router carries `crowdsec@file`, either from a label or from the
default chain. To validate that filtering is live, run `make report`. An empty
bouncer section means that no request goes through the middleware yet.

The [CrowdSec guide](docs/crowdsec.md) covers host log collection,
notifications, LAPI exposure, console enrollment, and the current AppSec limit.

## Route a service outside Docker

Use `etc/templates/external.template` as the starting point for a file-provider
route to a host process, virtual machine, or remote service.

Traefik renders the environment expressions in this Go template. Add the
required variables to the Traefik container through a Compose override, or use
literal values in the final dynamic file.

## Add a service to Selvedge

Create an optional service fragment:

```bash
make create-service whoami
```

Edit `etc/compose/services-available/whoami.yml`. Then validate and enable it:

```bash
docker compose \
  -f docker-compose.yml \
  -f etc/compose/services-available/whoami.yml \
  config --quiet
make enable whoami
make restart
```

`make validate` covers the active files only, which are the ones linked in
`etc/compose/services-enabled/` and `etc/compose/overrides-enabled/`, plus
`docker-compose.override.yml`. An error in a component you do not enable stays
hidden. To validate every supported service and override combination, run:

```bash
./scripts/compose.sh validate
```

## Operations

| Command | Result |
| --- | --- |
| `make help` | List available targets |
| `make start` | Prepare generated files and start the stack |
| `make stop` | Stop the stack |
| `make restart` | Stop and start the stack |
| `make update` | Pull images, prune unused layers, and restart |
| `make logs` | Follow container logs |
| `make validate` | Validate the active Compose configuration without printing it |
| `make config-show` | Print the resolved configuration, which can contain secrets |
| `make backup` | Archive `.env`, configuration, certificates, and persistent data |
| `make restore` | Restore the newest Selvedge backup |
| `make report` | Show CrowdSec bouncer, alert, and decision metrics |


Install the optional systemd unit with:

```bash
sudo make systemd-install
sudo systemctl enable --now selvedge
```

Two more templates live under `etc/templates/`. Copy `traefik.logrotate` to
`/etc/logrotate.d/` to rotate the access log daily and keep seven days. Paste
`zshrc_function.sh` into your shell profile to run `make` targets as
`selvedge <target>` from any directory.

## License

Selvedge is available under the [Apache License 2.0](LICENSE).
