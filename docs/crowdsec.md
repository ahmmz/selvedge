# CrowdSec in Selvedge

The CrowdSec add-on reads Traefik access logs and stores its decisions under
`data/crowdsec/`. After you attach `crowdsec@file` to a router, the Traefik
bouncer plugin queries CrowdSec LAPI and blocks requests.

This guide covers the files shipped with Selvedge. For product behavior and
installation details, use the [CrowdSec documentation](https://docs.crowdsec.net/).

## Enable request filtering

Enable CrowdSec and start the stack:

```bash
make enable crowdsec
make start
```

Create a key for the Traefik bouncer:

```bash
docker exec crowdsec cscli bouncers add traefik-bouncer
```

Copy the generated key to `.env`:

```dotenv
CROWDSEC_BOUNCER_API_KEY=<generated-key>
```

Restart Selvedge:

```bash
make restart
```

Attach the middleware to each protected router. For a Docker label, use:

```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=crowdsec@file"
```

If a router already has middleware, keep the required order and separate the
names with commas.

The middleware is per-route. Until you attach it, CrowdSec parses logs and
raises alerts but blocks no request. To protect every route at once, uncomment
`- crowdsec` in the `default` chain in `etc/traefik/available/default.yml`. The
`websecure` entrypoint applies that chain to all routers.

Run `make report` to see whether filtering is live. An empty bouncer section
means that no request goes through the middleware yet.

## Files and data flow

- [`etc/compose/services-available/crowdsec.yml`](../etc/compose/services-available/crowdsec.yml)
  runs CrowdSec and makes Traefik write JSON access logs.
- [`etc/config/crowdsec/acquis.yaml`](../etc/config/crowdsec/acquis.yaml) defines
  the Traefik and optional host log sources.
- [`etc/traefik/available/crowdsec.yml`](../etc/traefik/available/crowdsec.yml)
  defines the `crowdsec@file` middleware.
- `data/log/traefik/` contains the access log.
- `data/crowdsec/` contains generated CrowdSec configuration and database files.

The CrowdSec service mounts its configuration and data directories as writable.
Do not force a Compose `user` on this service. If CrowdSec runs as a non-root
user, notification plugins can fail. See
[CrowdSec issue #3562](https://github.com/crowdsecurity/crowdsec/issues/3562).

## Optional overrides

Each CrowdSec override declares `crowdsec` as a dependency. Enabling an override
also enables the service.

| Override | Change |
| --- | --- |
| `crowdsec-host` | Mount host log directories and bind LAPI to `127.0.0.1:8080` |
| `crowdsec-appsec` | Add CrowdSec AppSec collections to the installed collection set |
| `crowdsec-lapi` | Route LAPI through Traefik with the Cloudflare IP allowlist |
| `crowdsec-cti` | Push decisions to VictoriaMetrics for the Grafana CTI dashboard |

Enable an override, then restart the stack:

```bash
make enable crowdsec-host
make restart
```

### Host log collection

`crowdsec-host` mounts `/var/log` at `/var/log/host` and mounts the systemd journal
directory read-only. Where these host files exist, the supplied acquisition file
reads them:

- `auth.log` or `secure`
- `syslog` or `messages`
- `kern.log`

CrowdSec detects events and creates decisions. It does not apply those decisions
to host firewall traffic by itself. Install a supported CrowdSec firewall bouncer
on the host, register it with the local LAPI, and configure it to use
`http://127.0.0.1:8080/`. Follow the
[official firewall bouncer guide](https://docs.crowdsec.net/u/bouncers/firewall/)
for your distribution.

The journal mount is available for a custom journal acquisition rule. The
default `acquis.yaml` reads log files only.

### AppSec collection override

`crowdsec-appsec` adds the CRS and virtual-patching collections. This fragment
does not create an AppSec acquisition listener or configure the Traefik plugin to
send request bodies to it. Treat it as collection preparation until those parts
are configured for your deployment.

### Remote LAPI access

`crowdsec-lapi` creates an HTTPS router for the hostname in
`CROWDSEC_LAPI_HOST`. The router accepts requests only from the Cloudflare IP
ranges in `whitelist-cloudflare@file`.

Before you enable it:

1. Set `CROWDSEC_LAPI_HOST` to a real DNS name.
2. Put that hostname behind the Cloudflare proxy. A DNS-only record cannot reach
   a route that permits only Cloudflare source addresses.
3. Check that your proxy trust configuration uses current Cloudflare address
   ranges.
4. Create a separate bouncer key for the remote client.

```bash
make enable crowdsec-lapi
docker exec crowdsec cscli bouncers add remote-bouncer
make restart
```

### Threat intelligence dashboard

`crowdsec-cti` adds a Grafana dashboard with a world map of attacking IP
addresses, plus country, ASN, and scenario breakdowns.

Prometheus scrapes CrowdSec engine counters. Those counters carry no attacking
IP country or coordinates, so a map cannot be built from them. This override runs
VictoriaMetrics beside Prometheus, and a notification handler pushes every
decision to it as a labelled sample.

```bash
make enable crowdsec-cti
make start
```

The override sets `PARSERS`, so the engine installs `crowdsecurity/geoip-enrich`
on start. That parser supplies the country and coordinate labels the map plots.

Add the handler to the remediation profile in
`data/crowdsec/config/profiles.yaml`:

```yaml
notifications:
  - http_victoriametrics
```

Restart, then create a test decision:

```bash
make restart
docker exec crowdsec cscli decisions add --ip 192.0.2.10 --duration 10m
```

The dashboard fills only after a decision fires. An engine that detects but
never bans leaves it empty. Prometheus stays the datasource for Traefik and
engine metrics.

## Notifications

Selvedge includes notification definitions for Discord, Slack, and Telegram:

| Channel | Environment variables | Notification name |
| --- | --- | --- |
| Discord | `CROWDSEC_DISCORD_WEBHOOK`, optional `CROWDSEC_GEOAPIFY_KEY` | `discord_default` |
| Slack | `CROWDSEC_SLACK_WEBHOOK` | `slack_default` |
| Telegram | `CROWDSEC_TELEGRAM_BOT_TOKEN`, `CROWDSEC_TELEGRAM_CHAT_ID` | `telegram_default` |

Set only the credentials for the channels that you use.

After the first CrowdSec start, edit `data/crowdsec/config/profiles.yaml`. Add the
notification names to the applicable remediation profile:

```yaml
notifications:
  - discord_default
  - slack_default
  - telegram_default
```

Restart CrowdSec after the change:

```bash
docker compose restart crowdsec
```

Test one channel at a time:

```bash
docker exec crowdsec cscli notifications test discord_default
```

## Custom CrowdSec rules

Store local configuration in the mounted directories under
`etc/config/crowdsec/`:

| Path | Content |
| --- | --- |
| `acquis.d/` | Additional acquisition sources |
| `scenarios/` | Local detection scenarios |
| `whitelists/` | Local parser-stage allowlists |

Check custom YAML before you restart the service. Then inspect the CrowdSec
logs for parser, scenario, and permission errors.

## Console enrollment

Enrollment in the CrowdSec Console is optional. Copy an enrollment key from the
Console, then run:

```bash
docker exec crowdsec cscli console enroll <enrollment-key>
```

Accept the pending engine in the Console. The local bouncer key remains separate
from the enrollment key.

## Operations

List decisions and recent alerts:

```bash
docker exec crowdsec cscli decisions list
docker exec crowdsec cscli alerts list -l 20
```

Add and remove a test decision:

```bash
docker exec crowdsec cscli decisions add \
  --ip 192.0.2.10 \
  --duration 10m \
  --reason "Selvedge test"
docker exec crowdsec cscli decisions delete --ip 192.0.2.10
```

`192.0.2.10` comes from the RFC 5737 documentation range, so the test decision
blocks no real host.

Check the service and LAPI:

```bash
docker compose ps crowdsec
docker exec crowdsec cscli lapi status
docker compose logs --tail 200 crowdsec
```

If the middleware does not block a decision, check these items in order:

1. CrowdSec is healthy.
2. `CROWDSEC_BOUNCER_API_KEY` matches a key listed by `cscli bouncers list`.
3. The target router includes `crowdsec@file`.
4. Traefik writes JSON records to `data/log/traefik/access.log`.
5. CrowdSec reads that file without parser or permission errors.
6. Traefik receives the real client address from a trusted proxy.
