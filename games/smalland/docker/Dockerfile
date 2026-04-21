FROM cm2network/steamcmd:latest

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates procps && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /home/steam/entrypoint.sh
RUN chown steam:steam /home/steam/entrypoint.sh && \
    chmod +x /home/steam/entrypoint.sh

USER steam
ENV SMALLAND_DIR=/home/steam/smalland
WORKDIR /home/steam

EXPOSE 7777/udp
ENTRYPOINT ["/home/steam/entrypoint.sh"]
