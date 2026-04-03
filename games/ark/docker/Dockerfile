FROM ubuntu:22.04

# ARK Survival Ascended has NO native Linux server binary.
# It must run through GE-Proton (a Proton/Wine compatibility layer).
# Reference: https://github.com/Acekorneya/Ark-Survival-Ascended-Server
#
# HOST REQUIREMENT: vm.max_map_count=262144
#   echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf && sudo sysctl -p

ENV DEBIAN_FRONTEND=noninteractive
ENV ARK_DIR=/home/ark/arkserver
ENV STEAMCMD_DIR=/home/ark/steamcmd
ENV PROTON_DIR=/home/ark/proton

# Wine prefix and Proton environment paths
ENV WINEPREFIX=/home/ark/.steam/steam/steamapps/compatdata/2430930/pfx
ENV STEAM_COMPAT_CLIENT_INSTALL_PATH=/home/ark/.steam/steam
ENV STEAM_COMPAT_DATA_PATH=/home/ark/.steam/steam/steamapps/compatdata/2430930
ENV DISPLAY=:0.0

# Proton performance settings
ENV WINEDLLOVERRIDES="version=n,b"
ENV WINEDEBUG=-all

# --- Install system dependencies ---
RUN dpkg --add-architecture i386 \
    && apt-get update && apt-get install -y \
    # Core utilities
    curl wget tar unzip jq iproute2 procps ca-certificates gnupg2 \
    # SteamCMD dependencies
    lib32gcc-s1 lib32stdc++6 \
    # Wine/Proton dependencies
    cabextract winbind \
    # Graphics/Vulkan (Proton needs these even headless)
    libvulkan1 libgl1-mesa-dri \
    # Audio libs (ARK checks for these)
    libpulse0 libopenal1 libasound2 \
    # Display (Xvfb virtual framebuffer for headless Proton)
    xvfb x11-xserver-utils xauth \
    # Other libs ARK expects
    libglib2.0-0 libnss3 libfontconfig1 libfreetype6 libcups2 libncurses6 \
    # Build tools for mcrcon
    build-essential git \
    # Init process manager
    tini \
    && rm -rf /var/lib/apt/lists/*

# --- Install mcrcon from source (RCON client for admin commands) ---
RUN cd /tmp \
    && git clone https://github.com/Tiiffi/mcrcon.git \
    && cd mcrcon \
    && make \
    && cp mcrcon /usr/local/bin/ \
    && cd / && rm -rf /tmp/mcrcon

# --- Create ark user ---
RUN useradd -m -s /bin/bash -u 7777 ark \
    && mkdir -p $STEAMCMD_DIR $ARK_DIR $PROTON_DIR \
    && mkdir -p $WINEPREFIX \
    && mkdir -p /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix \
    && chown -R ark:ark /home/ark

USER ark

# --- Install SteamCMD and ARK SA server ---
# Both steps must be in the same RUN so SteamCMD's client state from the
# initial +quit run is available when we install the game. Separating them
# into different RUN layers causes "Missing configuration" errors.
RUN cd $STEAMCMD_DIR \
    && wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    && tar -xzf steamcmd_linux.tar.gz \
    && rm steamcmd_linux.tar.gz \
    && $STEAMCMD_DIR/steamcmd.sh +quit \
    && $STEAMCMD_DIR/steamcmd.sh \
       +force_install_dir $ARK_DIR \
       +login anonymous \
       +app_info_update 1 \
       +app_update 2430930 validate \
       +quit

# --- Install GE-Proton ---
# Download latest GE-Proton release for running Windows binaries
RUN cd /tmp \
    && PROTON_URL=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
       | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url' | head -1) \
    && wget -q "$PROTON_URL" -O ge-proton.tar.gz \
    && tar -xzf ge-proton.tar.gz -C $PROTON_DIR --strip-components=1 \
    && rm ge-proton.tar.gz \
    && ln -sf $PROTON_DIR /home/ark/GE-Proton-Current

# Generate machine-id (ARK/UE5 needs this for initialization)
USER root
RUN dbus-uuidgen > /etc/machine-id
USER ark

# Create config directories
RUN mkdir -p $ARK_DIR/ShooterGame/Saved/Config/WindowsServer \
    && mkdir -p $ARK_DIR/ShooterGame/Saved/Logs

# --- Copy startup scripts ---
COPY --chown=ark:ark start_server.sh /home/ark/start_server.sh
RUN chmod +x /home/ark/start_server.sh

WORKDIR $ARK_DIR

# Game port (UDP+TCP), Peer port (UDP), Query port (UDP), RCON port (TCP)
EXPOSE 7777/udp 7777/tcp 7778/udp 27015/udp 27020/tcp

ENTRYPOINT ["tini", "--"]
CMD ["/home/ark/start_server.sh"]
