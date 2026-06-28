# syntax=docker/dockerfile:1.7

# Builder stage: fetch and verify xray-core release archive for the target arch.
ARG ALPINE_VERSION=3.21
ARG XRAY_VERSION=26.6.1

FROM alpine:${ALPINE_VERSION} AS xray-fetch
ARG XRAY_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

# coreutils replaces busybox sha256sum/install with GNU variants that accept
# long flags (--check, --status, --mode, --owner, --group, -D for path-create).
RUN apk add --no-cache curl unzip ca-certificates coreutils

WORKDIR /work

RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT:+-$TARGETVARIANT}" in \
        amd64)        XRAY_ARCH=64 ;; \
        arm64)        XRAY_ARCH=arm64-v8a ;; \
        arm-v7)       XRAY_ARCH=arm32-v7a ;; \
        arm-v6)       XRAY_ARCH=arm32-v6 ;; \
        386)          XRAY_ARCH=32 ;; \
        *) echo "unsupported platform ${TARGETARCH}${TARGETVARIANT:+-$TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}"; \
    curl --silent --show-error --fail --location --output xray.zip "${base}/Xray-linux-${XRAY_ARCH}.zip"; \
    curl --silent --show-error --fail --location --output xray.zip.dgst "${base}/Xray-linux-${XRAY_ARCH}.zip.dgst"; \
    expected=$(awk -F'= ' '/^SHA2-256=/ {print $2}' xray.zip.dgst); \
    if [ -z "${expected}" ]; then echo "missing SHA2-256 in dgst file" >&2; exit 1; fi; \
    echo "${expected}  xray.zip" | sha256sum --check --status; \
    unzip -q xray.zip -d dist; \
    mkdir --parents /out/share/xray; \
    install --mode=0755                        dist/xray        /out/xray; \
    install --mode=0644 --owner=0 --group=0    dist/geoip.dat   /out/share/xray/geoip.dat; \
    install --mode=0644 --owner=0 --group=0    dist/geosite.dat /out/share/xray/geosite.dat


# Runtime stage: minimal Alpine with xray + supervisor toolchain.
FROM alpine:${ALPINE_VERSION}
ARG XRAY_VERSION

RUN apk add --no-cache \
        bash \
        ca-certificates \
        coreutils \
        curl \
        iproute2 \
        iptables \
        ip6tables \
        jq \
        shadow \
        tini \
        tzdata \
    && groupadd --system --gid 65532 xray \
    && useradd  --system --uid 65532 --gid xray --no-create-home --shell /sbin/nologin xray \
    && mkdir --parents /var/lib/xray /var/log/xray /etc/xray \
    && chown --recursive xray:xray /var/lib/xray /var/log/xray /etc/xray

COPY --from=xray-fetch /out/xray              /usr/local/bin/xray
COPY --from=xray-fetch /out/share/xray/       /usr/local/share/xray/
COPY scripts/entrypoint.sh                    /usr/local/bin/entrypoint.sh

RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENV SUBSCRIPTION_URL="" \
    SUBSCRIPTION_USER_AGENT="Xray/26.6.1" \
    SUBSCRIPTION_FORMAT="auto" \
    REFRESH_INTERVAL_SECONDS="43200" \
    TPROXY_PORT="12345" \
    SOCKS_PORT="10808" \
    DNS_PORT="10853" \
    BALANCER_STRATEGY="leastPing" \
    OBSERVATORY_INTERVAL="5m" \
    LOG_LEVEL="warning" \
    XRAY_CONFIG_DIR="/etc/xray" \
    XRAY_STATE_DIR="/var/lib/xray" \
    BYPASS_PRIVATE="1"

VOLUME ["/var/lib/xray", "/var/log/xray"]

EXPOSE 12345/tcp 12345/udp 10808/tcp 10853/udp

LABEL org.opencontainers.image.title="xray-container" \
      org.opencontainers.image.description="xray-core with Remnawave subscription auto-fetch, balancer, and TPROXY inbound for MikroTik RouterOS containers" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.source="https://github.com/davydovd/xray-container" \
      org.opencontainers.image.version="${XRAY_VERSION}"

# Healthcheck: end-to-end probe through the SOCKS inbound. Proves xray is not
# just alive but actually proxying — the same generate_204 target the
# observatory uses. start-period covers the initial subscription fetch.
# RouterOS surfaces the result as the HEALTHY/UNHEALTHY container flag; pair
# with stop-on-unhealthy on the host if automatic restart-on-hang is wanted.
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl --silent --fail --max-time 8 \
        --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
        --output /dev/null \
        "http://www.gstatic.com/generate_204" || exit 1

# tini reaps zombies and forwards signals so xray/refresher exit cleanly.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
