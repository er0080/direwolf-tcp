# dw-iface Docker test node
# Build context: repo root (compose.yml sets context: ..)
#
# Stage 1: build tncattach (not in Ubuntu apt)
FROM ubuntu:24.04 AS builder
RUN apt-get update && apt-get install -y gcc make && rm -rf /var/lib/apt/lists/*
COPY tncattach/ /build/tncattach/
WORKDIR /build/tncattach
RUN make

# Stage 2: runtime image
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
        direwolf \
        openssh-server \
        openssh-client \
        nginx \
        curl \
        iproute2 \
        iputils-ping \
        netcat-openbsd \
        alsa-utils \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /var/log/nginx /etc/dw-iface

COPY --from=builder /build/tncattach/tncattach /usr/local/sbin/tncattach
COPY docker/sshd_config   /etc/ssh/sshd_config.d/90-dw-iface.conf
COPY docker/nginx.conf    /etc/nginx/nginx.conf
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/sbin/tncattach

ENTRYPOINT ["/entrypoint.sh"]
