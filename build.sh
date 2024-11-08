#!/bin/bash

set -eou pipefail

__compress() {
    XZ_OPT="-9T $(nproc)" tar --preserve-permissions -Jcf "${@}"
}

__sha256() {
    echo -n "${1}" | sed 's/[[:space:]]//g' | sha256sum | awk '{print $1;}'
}

__curl_base() {
    curl -ksLS \
        --parallel --parallel-immediate \
        --retry 8 --retry-delay 3 --retry-max-time 10 \
        --compressed \
        "${@}" 2>/dev/null
}

__curl_github_raw() {
    __curl_base --create-dirs -o "${4}" "https://raw.githubusercontent.com/${1}/${2}/${3}"
}

__curl_sha_github() {
    local -i _code=1
    if _sha=$(__curl_base "https://github.com/${1}/commits/${2}/" | grep -o '"currentOid":"[^"]*' | grep -o '[^"]*$'); then
        if [[ ${#_sha} == 40 ]]; then
            _code=0
        fi
    fi
    return ${_code}
}

__git_clone() {
    git clone \
        --no-tags \
        --recursive \
        --recurse-submodules \
        --remote-submodules \
        --shallow-submodules \
        --single-branch \
        --depth 1 \
        -b "${2}" \
        "${1}" "${3}"
}

__git_github() {
    local _sha
    __git_clone "https://github.com/${1}.git" "${2}" "${3}"
    __curl_sha_github "${1}" "${2}"
    SHA+=("${_sha}")
}

__compile_cmake() {
    local -a __cmake_flags
    local __param
    for __param in "${@}"; do
        local __r="${__param}"
        if [[ "${__param//[[:space:]]/}" != "${__param}" ]]; then
            __r=$(echo "${__param}" | sed -E "s/\s+$//g;s/(-[^=]+=)\s*(.*)/\1'\2'/g")
        fi
        __cmake_flags+=("${__r}")
    done
    __cmake_flags+=(
        "-DBUILD_SHARED_LIBS=OFF"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCMAKE_INSTALL_PREFIX=${install_dir}"
    )
    local __build_temp_dir="objs"
    cmake -B "${__build_temp_dir}" "${__cmake_flags[@]}"
    cmake --build "${__build_temp_dir}" --config Release --target install/strip -j "$(nproc)"
}

compile_jemalloc() {
    local name="jemalloc"
    __git_github "jemalloc/jemalloc" "dev" ${name}
    pushd ${name} >/dev/null
    ./autogen.sh \
        --prefix="${install_dir}" \
        --disable-cxx \
        --disable-doc \
        --disable-prof-gcc \
        --disable-prof-libgcc \
        --disable-shared \
        --disable-stats \
        --enable-pageid
    make -j "$(nproc)"
    make install_include install_lib
    popd >/dev/null
    LDFLAGS+=" -l${name}"
}

compile_zlib() {
    local name="zlib"
    __git_github "zlib-ng/zlib-ng" "develop" ${name}
    pushd ${name} >/dev/null
    __compile_cmake \
        -DZLIB_ENABLE_TESTS=OFF \
        -DZLIBNG_ENABLE_TESTS=OFF \
        -DZLIB_COMPAT=ON \
        -DWITH_GTEST=OFF \
        -DWITH_SANITIZER=OFF \
        -DWITH_NATIVE_INSTRUCTIONS=OFF
    popd >/dev/null
}

compile_brotli() {
    local name="brotli"
    __git_github "google/brotli" "master" ${name}
    pushd ${name} >/dev/null
    __compile_cmake \
        -DBROTLI_BUILD_TOOLS=OFF \
        -DBROTLI_BUNDLED_MODE=OFF \
        -DBROTLI_DISABLE_TESTS=ON \
        -DBROTLI_EMSCRIPTEN=OFF
    popd >/dev/null
}

compile_zstd() {
    local name="zstd"
    __git_github "facebook/zstd" "dev" ${name}
    pushd ${name} >/dev/null
    __compile_cmake \
        -S "build/cmake" \
        -DZSTD_BUILD_PROGRAMS=OFF \
        -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_STATIC=ON
    popd >/dev/null
}

compile_pcre() {
    local name="pcre"
    __git_github "PCRE2Project/pcre2" "master" ${name}
    pushd ${name} >/dev/null
    __compile_cmake \
        -DPCRE2_SUPPORT_JIT=ON \
        -DPCRE2_SUPPORT_JIT_SEALLOC=ON \
        -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF \
        -DPCRE2_STATIC_PIC=ON \
        -DPCRE2_LINK_SIZE=4
    popd >/dev/null
}

compile_openssl() {
    local name="openssl"
    __git_github "openssl/openssl" "master" ${name}
    pushd ${name} >/dev/null
    CFLAGS="-O3 ${CFLAGS}" ./config \
        -DOPENSSL_TLS_SECURITY_LEVEL=3 \
        --prefix="${install_dir}" --libdir=lib -static \
        --release \
        --api=3.0.0 no-deprecated \
        enable-ec_nistp_64_gcc_128 \
        enable-ktls \
        enable-tfo \
        enable-brotli enable-brotli-dynamic \
        enable-zlib enable-zlib-dynamic \
        enable-zstd enable-zstd-dynamic \
        no-shared no-pinshared \
        no-apps \
        no-docs no-tests \
        no-legacy \
        no-dso \
        no-dynamic-engine \
        no-autoerrinit \
        no-autoload-config \
        no-err \
        no-filenames \
        no-sctp no-srp no-srtp \
        no-bf \
        no-blake2 \
        no-camellia \
        no-cms \
        no-des \
        no-gost \
        no-idea \
        no-psk \
        no-md4 no-mdc2 \
        no-rc2 no-rc4 \
        no-rmd160 \
        no-seed \
        no-whirlpool \
        no-ui-console \
        no-ssl-trace no-unstable-qlog \
        no-tls1-method no-tls1_1-method
    perl configdata.pm --dump
    make -j "$(nproc)"
    make install
    popd >/dev/null
}

__add_ngx_module_http_trim_filter() {
    local name="ngx_trim"
    local __repo="alibaba/tengine"
    local __repo_branche="master"
    local __repo_path="modules/ngx_http_trim_filter_module"
    __curl_github_raw "${__repo}" "${__repo_branche}" "${__repo_path}/config" "${name}/config"
    __curl_github_raw "${__repo}" "${__repo_branche}" "${__repo_path}/ngx_http_trim_filter_module.c" "${name}/ngx_http_trim_filter_module.c"
    __ngx_module+=("--add-module=../${name}")
}

__add_ngx_module_headers_more() {
    local name="ngx_headers_more"
    __git_github "openresty/headers-more-nginx-module" "master" ${name}
    __ngx_module+=("--add-module=../${name}")
}

__add_ngx_module_brotli() {
    local name="ngx_brotli"
    __git_github "google/ngx_brotli" "master" ${name}
    rm -rf "${build_temp}/${name}/deps/brotli"
    ln -s "${build_temp}/brotli/" "${build_temp}/${name}/deps/brotli"
    __ngx_module+=("--add-module=../${name}")
}

__add_ngx_module_zstd() {
    local name="ngx_zstd"
    __git_github "web-ngx/ngx_zstd" "master" ${name}
    __ngx_module+=("--add-module=../${name}")
}

compile_ngx() {
    local __ngx_module=()
    __add_ngx_module_headers_more
    __add_ngx_module_http_trim_filter
    __add_ngx_module_zstd
    __add_ngx_module_brotli
    local name="nginx"
    local install_dir="/opt"
    local __prefix="${install_dir}/${name}"
    local __ngx_user="nobody"
    local __ngx_group="nogroup"
    COMPRESS_FILE_NAME="${name}.tar.xz"
    __git_github "web-ngx/nginx" "modify" ${name}
    pushd ${name} >/dev/null
    sed -i '/ngx_write_stderr("configure arguments:" NGX_CONFIGURE NGX_LINEFEED);/d' src/core/nginx.c
    CFLAGS="-Ofast ${CFLAGS}" ./auto/configure \
        --prefix="${__prefix}" \
        --user="${__ngx_user}" \
        --group="${__ngx_group}" \
        --lock-path="/var/lock/${name}.lock" \
        --pid-path="/run/${name}.pid" \
        --http-client-body-temp-path="tmp/body" \
        --http-proxy-temp-path="tmp/proxy" \
        --http-fastcgi-temp-path="tmp/fastcgi" \
        --http-uwsgi-temp-path="tmp/uwsgi" \
        --http-scgi-temp-path="tmp/scgi" \
        --with-cc=gcc \
        --with-cc-opt="-fweb -fwhole-program -flto=auto -flto-partition=one -ffat-lto-objects -fPIC" \
        --with-ld-opt="-pie ${LDFLAGS}" \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-http_degradation_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_realip_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --without-poll_module \
        --without-select_module \
        --without-http_access_module \
        --without-http_autoindex_module \
        --without-http_empty_gif_module \
        --without-http_geo_module \
        --without-http_fastcgi_module \
        --without-http_uwsgi_module \
        --without-http_scgi_module \
        --without-http_grpc_module \
        --without-http_memcached_module \
        --without-http_mirror_module \
        "${__ngx_module[@]}"
    make -j "$(nproc)"
    make install
    popd >/dev/null
    if [[ ! -d "${__prefix}/tmp" ]]; then
        mkdir -p "${__prefix}/tmp"
    fi
    __sha256 "${SHA[*]}" >"${__prefix}/build.sha"
    echo "build_sha=$(cat "${__prefix}/build.sha")" >>"${GITHUB_OUTPUT}"
    chown -R "${__ngx_user}:${__ngx_group}" "${__prefix}"
    pushd "${install_dir}" >/dev/null
    __compress "${wk_path}/${COMPRESS_FILE_NAME}" "${name}"
    popd >/dev/null
}

wk_path=$(pwd)
temp_path=/tmp
build_temp=${temp_path}/build_temp
install_dir=${build_temp}/install

SHA=()
COMPRESS_FILE_NAME=

CFLAGS="-I${install_dir}/include"
if [[ -n "${option_arch}" ]]; then
    CFLAGS+=" -march=${option_arch}"
fi
if [[ -n "${option_tune}" ]]; then
    CFLAGS+=" -mtune=${option_tune}"
fi
CFLAGS+=" -mtls-dialect=gnu2"
CFLAGS+=" -maccumulate-outgoing-args -mno-push-args"
CFLAGS+=" -mno-red-zone"
CFLAGS+=" -fshort-wchar -funsigned-char"
CFLAGS+=" -ffast-math -funsafe-math-optimizations -fno-math-errno -fno-trapping-math"
CFLAGS+=" -fgcse -fgcse-lm -fgcse-sm -fgcse-las -fgcse-after-reload"
CFLAGS+=" -fno-exceptions -fdelete-dead-exceptions"
CFLAGS+=" -ffunction-sections -fdata-sections -fvisibility=hidden"
CFLAGS+=" -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-jump-tables"
CFLAGS+=" -fmodulo-sched -fmodulo-sched-allow-regmoves"
CFLAGS+=" -fno-common -fno-plt"
CFLAGS+=" -fno-sanitize=all"
CFLAGS+=" -fno-semantic-interposition"
CFLAGS+=" -fno-stack-check"
CFLAGS+=" -fno-stack-protector"
CFLAGS+=" -fno-stack-clash-protection"
CFLAGS+=" -fno-var-tracking-assignments"
CFLAGS+=" -freg-struct-return"
CFLAGS+=" -finhibit-size-directive"
CFLAGS+=" -fomit-frame-pointer"
CFLAGS+=" -frename-registers"
CFLAGS+=" -fgraphite-identity -floop-nest-optimize -ftree-loop-linear -floop-strip-mine"
CFLAGS+=" -fdevirtualize-at-ltrans"
CFLAGS+=" -fforce-addr"
CFLAGS+=" -ftracer"
CFLAGS+=" -fivopts"
CFLAGS+=" -fipa-pta"
CFLAGS+=" -ftree-vectorize -fvect-cost-model=unlimited -fsimd-cost-model=unlimited"
CFLAGS+=" -fvariable-expansion-in-unroller"
CFLAGS+=" -ftrivial-auto-var-init=zero"
CFLAGS+=" -fzero-call-used-regs=used-gpr"
if [[ -n "${option_openmp}" && "${option_openmp}" == "true" ]]; then
    CFLAGS+=" -fopenmp"
fi
CFLAGS+=" -Wa,-O2,--64,-acdn,-no-pad-sections,--strip-local-absolute"
CFLAGS+=" --param gcse-unrestricted-cost=0 --param max-gcse-memory=2147483647"
CFLAGS+=" --param max-hoist-depth=0"
CFLAGS+=" --param max-partial-antic-length=0"
CFLAGS+=" --param max-isl-operations=0"
CFLAGS+=" --param max-vartrack-size=0"
CXXFLAGS="${CFLAGS}"
CXXFLAGS+=" -fno-rtti"
CXXFLAGS+=" -fsection-anchors"
CXXFLAGS+=" -fvisibility-inlines-hidden"
CXXFLAGS+=" -fno-enforce-eh-specs"
CXXFLAGS+=" -fno-module-lazy"
CXXFLAGS+=" -fnothrow-opt"
CXXFLAGS+=" -faligned-new"
LDFLAGS="-fuse-ld=mold -fuse-linker-plugin"
LDFLAGS+=" -static -static-libgcc -static-libstdc++"
LDFLAGS+=" -Wl,-O2,-s,-x,-X"
LDFLAGS+=",--gc-sections"
LDFLAGS+=",--as-needed"
LDFLAGS+=",--sort-common"
LDFLAGS+=",--exclude-libs=ALL"
LDFLAGS+=",--hash-style=gnu"
LDFLAGS+=",--no-build-id"
LDFLAGS+=",--no-detach"
LDFLAGS+=",--no-eh-frame-hdr"
LDFLAGS+=",--no-undefined"
LDFLAGS+=",--demangle"
LDFLAGS+=",--icf=all,--ignore-data-address-equality"
LDFLAGS+=",--relocatable-merge-sections"
LDFLAGS+=",-z,nocopyreloc"
LDFLAGS+=",-z,nokeep-text-section-prefix"
LDFLAGS+=",-z,nosectionheader"
LDFLAGS+=",-z,nodlopen"
LDFLAGS+=",-z,nodump"
LDFLAGS+=",-z,notext"
LDFLAGS+=",-z,now"
LDFLAGS+=",-z,relro"
LDFLAGS+=",-z,start-stop-visibility=hidden"
LDFLAGS+=" -L${install_dir}/lib -lrt"
if [[ -n "${option_openmp}" && "${option_openmp}" == "true" ]]; then
    LDFLAGS+=" -lgomp"
fi
export CFLAGS
export CXXFLAGS
export LDFLAGS

while IFS= read -r file; do
    ln -sf "${file}" "${file%-*}"
done < <(find /usr/bin -type l -name "*-14")

mkdir -p "${build_temp}"
pushd "${build_temp}" >/dev/null

compile_jemalloc
compile_zlib
compile_brotli
compile_zstd
compile_pcre
compile_openssl
compile_ngx

popd >/dev/null

echo "file_name=${COMPRESS_FILE_NAME}" >>"${GITHUB_OUTPUT}"

exit 0
