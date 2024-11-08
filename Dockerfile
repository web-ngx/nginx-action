FROM debian:sid

RUN apt-get update && apt-get -y --no-install-recommends --no-install-suggests --allow-change-held-packages --allow-downgrades --allow-remove-essential full-upgrade
RUN apt-get -y --purge autoremove
RUN apt-get update && apt-get install -y --no-install-recommends --no-install-suggests \
    cpp-14 gcc-14 g++-14 \
    autoconf automake cmake make binutils-dev \
    linux-headers-amd64 \
    gawk libtool mold patch xsltproc \
    ca-certificates curl git xz-utils
RUN apt-get autoclean && apt-get clean

COPY build.sh /build.sh

ENTRYPOINT ["/build.sh"]
