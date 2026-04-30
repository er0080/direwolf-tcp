# dw-iface Docker test node
# Build context: repo root (compose.yml sets context: ..)
#
# Stage 1: build the dw-iface .deb from package/ source.
# tncattach is now vendored in package/vendor/tncattach/ and compiled here.
# A successful image build means 'dpkg -i dw-iface.deb' completed cleanly.
FROM ubuntu:24.04 AS deb-builder
RUN apt-get update && apt-get install -y debhelper gcc make && rm -rf /var/lib/apt/lists/*
COPY package/ /build/dw-iface-0.1.2/
WORKDIR /build/dw-iface-0.1.2
RUN dpkg-buildpackage -b -us -uc
# Output: /build/dw-iface_0.1.2-1_amd64.deb

# Stage 2: runtime image
FROM ubuntu:24.04

# Install runtime dependencies (tncattach comes from the .deb)
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

# Install dw-iface (includes tncattach) from the .deb we built
COPY --from=deb-builder /build/dw-iface_0.1.2-1_amd64.deb /tmp/dw-iface.deb
RUN dpkg -i /tmp/dw-iface.deb && rm /tmp/dw-iface.deb

# Container-specific service configs
COPY docker/sshd_config /etc/ssh/sshd_config.d/90-dw-iface.conf
COPY docker/nginx.conf  /etc/nginx/nginx.conf

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /run/sshd /var/log/dw-iface

ENTRYPOINT ["/entrypoint.sh"]
