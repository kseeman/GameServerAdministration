# PixARK dedicated server image.
#
# Inherits from silentmecha/steamcmd-wine (wine + steamcmd only, no PixARK) —
# the grandparent of silentmecha/pixark-linux. We install PixARK at runtime
# via steamcmd into a named volume instead of baking it into an image layer,
# which means we stay current with releases instead of being frozen at
# whatever date upstream last rebuilt.
#
# This matches the acekorneya/asa_server pattern used by our ARK plugin.

FROM silentmecha/steamcmd-wine:latest

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates procps winbind && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/wine /usr/bin/wine64

COPY entrypoint.sh /home/steam/entrypoint.sh
RUN chown steam:steam /home/steam/entrypoint.sh && \
    chmod +x /home/steam/entrypoint.sh

# Keep USER as root so entrypoint can fix volume ownership before dropping privs
# to steam (UID 1000). Docker named volumes mount as root-owned by default.
ENV PIXARK_DIR=/home/steam/PixARK-dedicated
WORKDIR /home/steam

EXPOSE 27015/udp 27016/udp 27017/tcp 27018/tcp
ENTRYPOINT ["/home/steam/entrypoint.sh"]
