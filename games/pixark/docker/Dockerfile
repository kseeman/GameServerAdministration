# PixARK dedicated server image.
#
# Built directly on ubuntu:24.04 with Wine from WineHQ's own apt repo, rather
# than inheriting silentmecha/steamcmd-wine. That base is still maintained
# (rebuilt 2026-03-03) but ships Ubuntu's archive Wine 9.0, which is two years
# behind. Wine 11.0 brings NTSYNC — in-kernel Windows sync primitives instead
# of futex emulation — and a stable WoW64, both of which matter for a heavily
# threaded UE4 dedicated server.
#
# PixARK is still installed at runtime via steamcmd into a named volume rather
# than baked into an image layer, so we track upstream releases instead of
# being frozen at whatever date an image was last rebuilt. This matches the
# acekorneya/asa_server pattern used by our ARK plugin.
#
# Wine is pinned to an exact version so rebuilds are reproducible. To move it,
# bump WINE_VERSION to a version listed at
#   https://dl.winehq.org/wine-builds/ubuntu/dists/noble/main/binary-amd64/Packages
# WINE_BRANCH=staging carries more game-oriented patches at the cost of being a
# moving target; stable is the default because these are long-running servers.

FROM ubuntu:24.04

ARG WINE_BRANCH=stable
ARG WINE_VERSION=11.0.0.0~noble-1
ARG MCRCON_VERSION=0.7.2

ENV DEBIAN_FRONTEND=noninteractive

# Wine needs the i386 runtime, and steamcmd itself is a 32-bit binary.
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg procps winbind tar && \
    rm -rf /var/lib/apt/lists/*

# WineHQ repository. Their packages expect recommends to be installed.
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://dl.winehq.org/wine-builds/winehq.key \
        -o /etc/apt/keyrings/winehq-archive.key && \
    echo "deb [signed-by=/etc/apt/keyrings/winehq-archive.key] https://dl.winehq.org/wine-builds/ubuntu/ noble main" \
        > /etc/apt/sources.list.d/winehq.list && \
    apt-get update && \
    apt-get install -y --install-recommends "winehq-${WINE_BRANCH}=${WINE_VERSION}" && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /opt/wine-${WINE_BRANCH}/bin/wine /usr/local/bin/wine64

# steamcmd lives in multiverse and prompts for a licence, so preseed it.
RUN sed -i 's/^Components: main restricted universe$/Components: main restricted universe multiverse/' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    echo steam steam/question select "I AGREE" | debconf-set-selections && \
    echo steam steam/license note '' | debconf-set-selections && \
    apt-get update && \
    apt-get install -y --no-install-recommends steamcmd && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/games/steamcmd /usr/bin/steamcmd

# UID 1001 is not a preference — it is what the existing pixark-vol-* volumes
# are already owned by, and what the atmoz/sftp sidecar chowns its mount to.
RUN groupadd -g 1001 steam && \
    useradd -u 1001 -g 1001 -m -d /home/steam -s /bin/bash steam

# mcrcon drives the graceful-shutdown path in entrypoint.sh. The previous base
# image never actually shipped it, so saveworld-on-stop silently no-op'd.
RUN mkdir -p /tmp/mcrcon && \
    curl -fsSL "https://github.com/Tiiffi/mcrcon/releases/download/v${MCRCON_VERSION}/mcrcon-${MCRCON_VERSION}-linux-x86-64.tar.gz" \
        | tar -xz -C /tmp/mcrcon && \
    install -D -m 0755 /tmp/mcrcon/mcrcon /home/steam/mcrcon/mcrcon && \
    rm -rf /tmp/mcrcon

COPY entrypoint.sh /home/steam/entrypoint.sh
RUN chown -R steam:steam /home/steam && \
    chmod +x /home/steam/entrypoint.sh

# Keep USER as root so entrypoint can fix volume ownership before dropping privs
# to steam (UID 1001). Docker named volumes mount as root-owned by default.
ENV PIXARK_DIR=/home/steam/PixARK-dedicated
WORKDIR /home/steam

# Documentation only — the container runs with host networking, so these are
# not published by Docker. See docker-compose.template.yml for why.
EXPOSE 27015/udp 27016/udp 27017/tcp 27018/tcp
ENTRYPOINT ["/home/steam/entrypoint.sh"]
