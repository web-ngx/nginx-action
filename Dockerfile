FROM debian:sid-slim

RUN apt-get update && apt-get -y --no-install-recommends --no-install-suggests --allow-change-held-packages --allow-downgrades --allow-remove-essential full-upgrade; \
    apt-get -y --purge autoremove; \
    ARCH=$(dpkg --print-architecture 2>/dev/null); \
    apt-get update && apt-get install -y --no-install-recommends --no-install-suggests \
    cpp cpp-14 gcc gcc-14 g++ g++-14 \
    autoconf automake bison cmake make \
    linux-headers-$ARCH \
    binutils-dev libbsd-dev \
    gawk libtool mold patch gettext texinfo xsltproc \
    ca-certificates curl git python3 xz-utils zstd; \
    apt-get autoclean; \
    apt-get clean;

COPY build.sh /usr/local/bin/build.sh

ENTRYPOINT ["/usr/local/bin/build.sh"]
