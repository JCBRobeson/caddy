FROM caddy:2.11-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/route53@v1.6.2

FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
