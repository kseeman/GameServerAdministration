FROM ubuntu:22.04

# Set environment variables to avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMCMD_DIR=/opt/steamcmd
ENV PALWORLD_DIR=/opt/palworld

# Install dependencies including gettext-base for envsubst
RUN apt-get update && apt-get install -y \
    curl \
    lib32gcc-s1 \
    lib32stdc++6 \
    wget \
    tar \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Create palworld user and directories
RUN useradd -m -s /bin/bash palworld \
    && mkdir -p $STEAMCMD_DIR $PALWORLD_DIR \
    && chown -R palworld:palworld $STEAMCMD_DIR $PALWORLD_DIR

# Switch to palworld user
USER palworld

# Download and install SteamCMD
RUN cd $STEAMCMD_DIR \
    && wget https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    && tar -xvzf steamcmd_linux.tar.gz \
    && rm steamcmd_linux.tar.gz

# Install Palworld server via SteamCMD
RUN $STEAMCMD_DIR/steamcmd.sh +force_install_dir $PALWORLD_DIR +login anonymous +app_update 2394010 validate +quit

# Create the server configuration directory
RUN mkdir -p $PALWORLD_DIR/Pal/Saved/Config/LinuxServer

# Copy the configuration template and startup script
COPY PalWorldSettings.ini.template $PALWORLD_DIR/PalWorldSettings.ini.template
COPY start_server.sh $PALWORLD_DIR/start_server.sh

# Make sure the startup script is executable and owned by palworld
USER root
RUN chown palworld:palworld $PALWORLD_DIR/PalWorldSettings.ini.template $PALWORLD_DIR/start_server.sh && chmod +x $PALWORLD_DIR/start_server.sh
USER palworld

# Set working directory
WORKDIR $PALWORLD_DIR

# Expose ports (default Palworld ports)
EXPOSE 8215/udp 27019/udp 25577/tcp

# Start the server
CMD ["./start_server.sh"]
