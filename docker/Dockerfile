# dw-iface Docker test node
# Build context: repo root (compose.yml sets context: ..)
#
# Stage 1: build tncattach (not in Ubuntu apt)
FROM ubuntu:24.04 AS tncattach-builder
RUN apt-get update && apt-get install -y gcc make && rm -rf /var/lib/apt/lists/*
COPY tncattach/ /build/
WORKDIR /build
RUN make

# Stage 2: build the dw-iface .deb from package/ source.
# This is the core purpose of this stage — prove that the package builds
# cleanly and can be installed with dpkg -i on a fresh Ubuntu 24.04 machine.
FROM ubuntu:24.04 AS deb-builder
RUN apt-get update && apt-get install -y debhelper && rm -rf /var/lib/apt/lists/*
COPY package/ /build/dw-iface-0.1.0/
WORKDIR /build/dw-iface-0.1.0
# -d: don't enforce runtime deps at build time (direwolf installed in stage 3)
RUN dpkg-buildpackage -b -us -uc -d
# Output: /build/dw-iface_0.1.0-1_amd64.deb

# Stage 3: runtime image
FROM ubuntu:24.04

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
        direwolf \
        iproute2 \
        iputils-ping \
        netcat-openbsd \
        openssh-server \
        openssh-client \
        nginx \
        curl \
        alsa-utils \
    && rm -rf /var/lib/apt/lists/*

# Install tncattach (not in apt — built from source in stage 1)
COPY --from=tncattach-builder /build/tncattach /usr/local/sbin/tncattach
RUN chmod +x /usr/local/sbin/tncattach

# Install dw-iface from the .deb we built — this is the packaging proof
COPY --from=deb-builder /build/dw-iface_0.1.0-1_amd64.deb /tmp/dw-iface.deb
RUN dpkg -i /tmp/dw-iface.deb && rm /tmp/dw-iface.deb

# Container-specific service configs
COPY docker/sshd_config /etc/ssh/sshd_config.d/90-dw-iface.conf
COPY docker/nginx.conf  /etc/nginx/nginx.conf

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /run/sshd /run/dw-iface /var/log/dw-iface

ENTRYPOINT ["/entrypoint.sh"]
