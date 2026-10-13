# Caddy + Route 53: HTTPS for a home network

Real HTTPS certificates for self-hosted services on a LAN, with no ports opened to the internet. `http://192.0.2.20:8080` becomes `https://app.example.com` with a lock icon.

Caddy runs as a reverse proxy, gets one wildcard certificate from Let's Encrypt using the Route 53 DNS challenge, and Pi-hole points every service name at it. It pairs with [pihole-unbound-docker](https://github.com/JCBRobeson/pihole-unbound-docker).

Throughout this README, `example.com` is the domain, `192.0.2.10` is the machine running Caddy, and `192.0.2.20` is a server running an app. Those addresses are from a range reserved for documentation. Swap in your own.

## How it works

| Piece | Job |
|---|---|
| Route 53 | Holds the domain. Its only job is proving to Let's Encrypt that you own it. |
| Let's Encrypt | Issues the certificate. |
| Caddy | Holds the certificate, handles HTTPS, forwards each name to the right app and port. |
| Pi-hole | Points every service name at Caddy, inside your network only. |

```
browser asks for app.example.com
    → Pi-hole: "everything under example.com is 192.0.2.10"
    → Caddy (443): "app" goes to 192.0.2.20:8080
    → the app, over plain HTTP on your LAN
```

**Getting the certificate (the DNS challenge):** Caddy asks Let's Encrypt for a certificate. Let's Encrypt replies with a random string to publish as a TXT record. Caddy writes the record into Route 53 with its AWS keys, Let's Encrypt checks it, and the certificate goes straight to Caddy, which then deletes the record. Nothing on your network is ever contacted from outside.

**Renewal:** Caddy checks its certificates every 10 minutes and renews when about a third of the lifetime is left (around 30 days on a 90-day certificate), while still serving traffic.

**Why a wildcard:** every certificate is published in public Certificate Transparency logs. Per-service certificates would publish a list of everything you run. One `*.example.com` certificate doesn't.

**Why outsiders can't reach it:** the service names exist only in your Pi-hole, never in public DNS, nothing is forwarded from the router, and Caddy sits on a private address.

## What you need

- Pi-hole (ideally two) from pihole-unbound-docker
- Docker Engine and the Compose plugin on the Caddy machine, with ports 80 and 443 free
- An AWS account with MFA on root and a separate admin user

## 1. The domain

Register it in Route 53. That creates the hosted zone and points the domain's nameservers at it, so there's nothing to connect. If you register elsewhere, point the domain's NS records at Route 53 or use that registrar's Caddy DNS module instead.

| Setting | Why |
|---|---|
| WHOIS privacy | Keeps your name and address out of the public registration record. A WHOIS lookup should show Amazon's details. |
| Auto-renew | A lapsed domain can be bought by someone else. |
| Transfer lock | Stops the domain being moved without unlocking it first. |

Check the nameservers match the hosted zone:

```bash
dig NS example.com +short
```

The four answers should match the NS record in **Route 53 → Hosted zones**.

**Root or subdomain?** `*.example.com` gives short names, but Pi-hole will answer every name under the domain with Caddy's IP, so you can't use the domain for anything public from inside your network. `*.lab.example.com` keeps the rest of the domain free. Decide now: the IAM policy locks Caddy to one record name.

## 2. AWS permissions

Create an IAM user named `caddy` with **no console access**, no groups, and only this policy. Replace `YOUR_ZONE_ID` (it starts with `Z`):

```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "WriteChallengeOnly",
			"Effect": "Allow",
			"Action": "route53:ChangeResourceRecordSets",
			"Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID",
			"Condition": {
				"ForAllValues:StringEquals": {
					"route53:ChangeResourceRecordSetsRecordTypes": "TXT",
					"route53:ChangeResourceRecordSetsNormalizedRecordNames": "_acme-challenge.example.com"
				}
			}
		},
		{
			"Sid": "ListRecordSets",
			"Effect": "Allow",
			"Action": "route53:ListResourceRecordSets",
			"Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID"
		}
	]
}
```

It can write one TXT record name in one zone and read that zone. Nothing else. A leaked key can't redirect your domain.

- **The record name must match your wildcard.** `*.example.com` uses `_acme-challenge.example.com`; `*.lab.example.com` uses `_acme-challenge.lab.example.com`. Lowercase, no trailing dot.
- **Why only two actions:** the module's documented minimum has five. Setting `hosted_zone_id` in the Caddyfile removes the need for `ListHostedZones` and `ListHostedZonesByName`, the only two that need `*`. `GetChange` is only used by `wait_for_route53_sync`, which has been off by default since module version 1.6.2. If something is missing, Caddy's log names the denied action. Add back only that one.
- **Don't add an `aws:SourceIp` condition.** AWS never sees your LAN addresses, and residential public IPs change, which breaks renewals without any warning.

Then **Security credentials → Create access key → Application running outside AWS.** The secret is shown once. Put it straight into `.env` (next step). Use one key per Caddy machine.

## 3. Files

```bash
sudo mkdir /srv/caddy
sudo chown youruser:youruser /srv/caddy
git clone https://github.com/JCBRobeson/caddy.git /srv/caddy
cd /srv/caddy
cp .env.example .env
chmod 600 .env                          # private before any secret goes in
cp conf/Caddyfile.example conf/Caddyfile
```

The repo only holds templates. Your real `.env` and `conf/Caddyfile` are copies that Git ignores, so `git pull` never touches them and `git add .` can't publish them.

Or if you like doing it yourself, do the below.

```bash
sudo mkdir -p /srv/caddy/conf
sudo chown youruser:youruser /srv/caddy
cd /srv/caddy
touch .env && chmod 600 .env    # private before any secret goes in
```

### `.env`

```
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
ROUTE53_ZONE_ID=
```

The module reads the two `AWS_` names automatically.

### `Dockerfile`

The stock image doesn't include the Route 53 module, so build one that does:

```Dockerfile
FROM caddy:2.11-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/route53@v1.6.2

FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

The first stage compiles Caddy with the module. The second copies that binary onto the normal, small image. Pin the module to the newest [release](https://github.com/caddy-dns/route53/releases); Caddy 2.10 and newer need 1.6 or newer.

### `docker-compose.yaml`

```yaml
services:
  caddy:
    build: .
    image: caddy-route53:local
    restart: unless-stopped
    environment:
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      ROUTE53_ZONE_ID: ${ROUTE53_ZONE_ID}
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./conf:/etc/caddy:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

| Setting | Why |
|---|---|
| `environment:` | Compose only uses `.env` to fill in `${...}`. It does **not** pass it into the container. Without this block, Caddy never sees the keys. |
| `443/udp` | HTTP/3. |
| `./conf:/etc/caddy:ro` | Read-only. Mount the folder, not the file: editors that replace files break single-file mounts. |
| `caddy_data` | Certificates and private keys. Never delete it, copy it, or commit it. Losing it means re-requesting certificates and hitting rate limits. |

Listing three variables instead of using `env_file: .env` means nothing else in `.env` leaks into the container.

### `conf/Caddyfile`

Edit your copy (not the `.example`) with your domain and services:

```
{
	acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}

*.example.com {
	tls {
		dns route53 {
			hosted_zone_id {$ROUTE53_ZONE_ID}
		}
	}
	abort
}

app.example.com {
	reverse_proxy 192.0.2.20:8080
}
```

- **The global block** (no name, at the top) points Caddy at Let's Encrypt's **staging** server. Staging certificates aren't trusted, but failures there don't count against the real server's rate limits. Delete the block once it works.
- **The wildcard block** gets the certificate. `abort` drops requests for names you haven't configured.
- **Each service** gets its own small block. Since Caddy 2.10, they reuse the wildcard certificate automatically.
- **No AWS keys in the Caddyfile.** The module reads them from the environment.
- `{$VAR}` is filled in from the container's environment before the Caddyfile is parsed.
- With more than one site block, every block needs braces.

## 4. Build and verify

Run these in `/srv/caddy`:

| Command | You want |
|---|---|
| `sudo docker compose config --quiet` | No output. Never run it without `--quiet`: it prints your secret. |
| `sudo docker compose build` | A successful build. Slow the first time on a Pi. |
| `sudo docker compose run --rm caddy caddy list-modules \| grep route53` | `dns.providers.route53` |
| `sudo docker compose run --rm caddy caddy validate --config /etc/caddy/Caddyfile` | `Valid configuration` |
| `sudo docker compose up -d` | Caddy starts |
| `sudo docker compose logs -f caddy 2>&1 \| grep -iE 'obtain\|error\|denied'` | Certificate obtained |

A "not formatted" warning from `validate` is cosmetic. `caddy fmt /etc/caddy/Caddyfile` prints the corrected version.

Once the staging certificate works, delete the global block and run `sudo docker compose restart caddy` for a real certificate.

## 5. Pi-hole wildcard

One rule points every name under the domain at Caddy:

```
address=/example.com/192.0.2.10
```

It's a raw dnsmasq line, set through Pi-hole v6's `misc.dnsmasq_lines` setting. To avoid editing the pihole-unbound-docker compose file (and fighting merge conflicts on every `git pull`), add an override file next to it. Compose merges `docker-compose.override.yaml` automatically.

`docker-compose.override.yaml`:

```yaml
services:
  pihole:
    environment:
      FTLCONF_misc_dnsmasq_lines: ${PIHOLE_DNSMASQ_LINES}
```

In that folder's `.env`:

```
PIHOLE_DNSMASQ_LINES=address=/example.com/192.0.2.10
```

Apply and check:

```bash
sudo docker compose config | grep dnsmasq_lines
sudo docker compose up -d
sudo docker exec pihole pihole-FTL --config misc.dnsmasq_lines
dig +short app.example.com @127.0.0.1
```

- The service name in the override (`pihole`) must match the main compose file. Check with `sudo docker compose config --services`.
- The pihole-unbound-docker `.gitignore` already keeps the override file out of Git.
- **Do this on every Pi-hole.** Sync tools that copy lists and Local DNS records don't copy this setting.
- A typo here can stop Pi-hole's DNS. Change one Pi-hole, test it, then the next.

## 6. Day-to-day and updates
 
The build creates a local image (`caddy-route53:local`). Restarting reuses it, so you only rebuild when the Dockerfile changes.
 
| What changed | Command |
|---|---|
| Nothing, just restarting | `sudo docker compose restart caddy` |
| The Caddyfile | `sudo docker compose exec -w /etc/caddy caddy caddy reload` (no downtime) |
| `.env` or `docker-compose.yaml` | `sudo docker compose up -d` |
| Caddy or the module | `sudo docker compose build --pull && sudo docker compose up -d` |
 
**Updating, every few months:**
 
1. Read the [Caddy](https://github.com/caddyserver/caddy/releases) and [module](https://github.com/caddy-dns/route53/releases) release notes.
2. New module version: change it in the Dockerfile. Caddy patch releases (2.11.x) come in with `--pull`, with no edit. A new minor version (2.12) means changing both `FROM` lines.
3. Rebuild: `sudo docker compose build --pull && sudo docker compose up -d`. `--pull` fetches fresh base images; without it, Docker reuses the old ones. `docker compose pull` does nothing here, because the image is built locally.
4. Check: `sudo docker compose exec caddy caddy list-modules | grep route53`, then load a site.

Certificates live in `caddy_data`, not in the image, so rebuilds never touch them.

## Gotchas

| Symptom | Cause |
|---|---|
| `AccessDenied` on `ChangeResourceRecordSets` | The record name in the policy doesn't match the wildcard, the zone ID differs, or the policy isn't attached. Add `debug_logging true` inside the `route53` block and `debug` to the global block to see what Caddy sends. Caddy retries on its own once it's fixed. |
| A changed setting has no effect | `docker compose restart` reuses the old container. After changing `.env`, a compose file or an override, use `docker compose up -d`. In `docker ps`, a recent STATUS with an old CREATED means it was only restarted. |
| `reverse_proxy :8080` doesn't work | A bare port means the Caddy container itself. Use the app's IP. |
| The Pi-hole machine can't resolve the names | Expected if its own DNS points at a public resolver (as it should). Test with `curl -I --resolve app.example.com:443:192.0.2.10 https://app.example.com` |
| `curl` complains about the certificate | You're still on staging. Use `-k` until you switch. |
| A UDP buffer warning in the logs | HTTP/3 asking for bigger buffers. Harmless. |

Before sharing logs anywhere, blank out your AWS account number and zone ID.

## Security summary

- The domain has WHOIS privacy, auto-renew, a transfer lock, and MFA on the account
- A dedicated IAM user with no console access, limited to one TXT record and one zone
- No `*` resources and no IP condition
- Keys only in `.env` (mode 600), never in the Caddyfile, passed in explicitly
- The Caddyfile is mounted read-only
- One wildcard certificate, so certificate logs don't list your services
- Service names only in Pi-hole; nothing forwarded from the router
- `.env`, `caddy_data`, the real Caddyfile and the Pi-hole override never reach Git

## Layout

```
caddy/
├── Dockerfile
├── docker-compose.yaml
├── .env.example            # template, committed
├── .env                    # your AWS keys and zone ID; never committed
└── conf/
    ├── Caddyfile.example   # template, committed
    └── Caddyfile           # your domain, services and IPs; never committed
```

`.gitignore` (allowlist):

```
*
!*/
!.gitignore
!README.md
!Dockerfile
!docker-compose.yaml
!.env.example
!conf/Caddyfile.example
```

`!*/` lets Git look inside folders, so the `conf/Caddyfile.example` line can match. The real `conf/Caddyfile` isn't on the list, so it stays ignored.

## Roadmap

- Firewall app ports so they only accept Caddy
- Put the Pi-hole dashboards behind Caddy
- Set the `email` global option for certificate problem notices
- Log limits and `no-new-privileges` on the container
- A second Caddy behind a floating IP (keepalived), with shared certificate storage