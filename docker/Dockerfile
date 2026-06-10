FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="tulan-binaries" \
      org.opencontainers.image.description="Apache2 + kubectl + docker-compose + minio client"

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/opt/tulan-tools/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
      apache2 \
      ca-certificates \
      curl \
      tini \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/tulan-tools/bin /var/www/html

COPY docker/install-tools.sh /tmp/install-tools.sh
RUN chmod +x /tmp/install-tools.sh && /tmp/install-tools.sh && rm -f /tmp/install-tools.sh

COPY docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY docker/apache/index.html /var/www/html/index.html
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && a2enmod rewrite \
    && echo "ServerName localhost" >> /etc/apache2/apache2.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsSL http://localhost/ || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
