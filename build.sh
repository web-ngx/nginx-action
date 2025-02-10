#!/bin/bash

set -eou pipefail

__compress() {
    XZ_OPT="-9T $(nproc)" tar --preserve-permissions -Jcf "${@}"
}

__crc() {
    echo -n "${1}" | cksum -z | awk '{printf("%X", $1);}'
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

__git_clone() {
    local __sha
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
    pushd "${3}" >/dev/null
    __sha=$(git rev-parse HEAD 2>/dev/null)
    popd >/dev/null
    if [[ ${COMMIT_LIST[*]/${__sha}/} == "${COMMIT_LIST[*]}" ]]; then
        COMMIT_LIST+=("${3}@${__sha}")
    fi
}

__git_github() {
    __git_clone "https://github.com/${1}.git" "${2}" "${3}"
}

__compile_cmake() {
    local -a __cmake_flags
    local __param
    for __param in "${@}"; do
        local __r="${__param}"
        if [[ ${__param//[[:space:]]/} != "${__param}" ]]; then
            __r=$(echo "${__param}" | sed -E "s/\s+$//g;s/(-[^=]+=)\s*(.*)/\1'\2'/g")
        fi
        __cmake_flags+=("${__r}")
    done
    __cmake_flags+=(
        "-DBUILD_SHARED_LIBS=OFF"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCMAKE_INSTALL_PREFIX=${__install_dir}"
    )
    local __build_temp_dir="objs"
    if [[ -d ${__build_temp_dir} ]]; then
        rm -rf "${__build_temp_dir}"
    fi
    cmake -B "${__build_temp_dir}" "${__cmake_flags[@]}"
    cmake --build "${__build_temp_dir}" --config Release --target install/strip -j "$(nproc)"
}

compile_jemalloc() {
    local name="jemalloc"
    if [[ ! -d ${name} ]]; then
        __git_github "jemalloc/jemalloc" "dev" ${name}
    fi
    pushd ${name} >/dev/null
    if [[ -f "Makefile" ]]; then
        make relclean
    fi
    local __cflags="-Wno-discarded-qualifiers -Wno-unused-function"
    __cflags+=" ${CFLAGS}"
    CFLAGS="${__cflags}" ./autogen.sh \
        --prefix="${__install_dir}" \
        --disable-cxx \
        --disable-doc \
        --disable-prof-libgcc \
        --disable-prof-gcc \
        --disable-shared \
        --disable-stats \
        --disable-user-config \
        --enable-lazy-lock \
        --enable-pageid
    make -j "$(nproc)"
    make install_include install_lib
    popd >/dev/null
    __ldflags+=" -l${name}"
}

compile_zlib() {
    local name="zlib"
    if [[ ! -d ${name} ]]; then
        __git_github "zlib-ng/zlib-ng" "develop" ${name}
    fi
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
    if [[ ! -d ${name} ]]; then
        __git_github "google/brotli" "master" ${name}
    fi
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
    if [[ ! -d ${name} ]]; then
        __git_github "facebook/zstd" "dev" ${name}
    fi
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
    if [[ ! -d ${name} ]]; then
        __git_github "PCRE2Project/pcre2" "master" ${name}
    fi
    pushd ${name} >/dev/null
    __compile_cmake \
        -DPCRE2_SUPPORT_JIT=ON \
        -DPCRE2_SUPPORT_JIT_SEALLOC=ON \
        -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF \
        -DPCRE2_STATIC_PIC=OFF \
        -DPCRE2_LINK_SIZE=4
    popd >/dev/null
}

compile_openssl() {
    local name="openssl"
    if [[ ! -d ${name} ]]; then
        __git_github "openssl/openssl" "master" ${name}
    fi
    pushd ${name} >/dev/null
    if [[ -f "Makefile" ]]; then
        make clean
    fi
    local __openssldir="${prefix_root}/ssl"
    if [[ -d ${__openssldir} ]]; then
        rm -rf "${__openssldir}"
    fi
    local __cflags
    __cflags="-Ofast -std=gnu17"
    __cflags+=" ${CFLAGS}"
    __cflags+=" -Wno-stringop-overflow"
    __cflags+=" -DOPENSSL_TLS_SECURITY_LEVEL=3"
    __cflags+=" -DSSL_OP_CLEANSE_PLAINTEXT=1"
    __cflags+=" -DSSL_OP_ENABLE_KTLS=1"
    __cflags+=" -DSSL_OP_ENABLE_KTLS_TX_ZEROCOPY_SENDFILE=1"
    __cflags+=" -UDSO_DLFCN"
    CFLAGS="${__cflags}" ./config \
        -static \
        --prefix="${__install_dir}" \
        --libdir=lib \
        --openssldir="${__openssldir}" \
        --release \
        --api=3.0.0 no-deprecated \
        no-shared no-pinshared \
        no-asm \
        no-apps \
        no-docs no-tests \
        no-makedepend \
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
        no-tls1-method no-tls1_1-method \
        enable-ec_nistp_64_gcc_128 \
        enable-ktls \
        enable-tfo \
        enable-brotli enable-brotli-dynamic \
        enable-zlib enable-zlib-dynamic \
        enable-zstd enable-zstd-dynamic
    perl configdata.pm --dump
    make -j "$(nproc)"
    make install
    find "${__openssldir}" -type f -name "*.dist" -exec rm -f {} \;
    popd >/dev/null
}

__add_ngx_module_http_trim_filter() {
    local name="ngx_trim"
    if [[ ! -d ${name} ]]; then
        local __repo="alibaba/tengine"
        local __repo_branche="master"
        local __repo_path="modules/ngx_http_trim_filter_module"
        __curl_github_raw "${__repo}" "${__repo_branche}" "${__repo_path}/config" "${name}/config"
        __curl_github_raw "${__repo}" "${__repo_branche}" "${__repo_path}/ngx_http_trim_filter_module.c" "${name}/ngx_http_trim_filter_module.c"
    fi
    __ngx_module+=("--add-module=../${name}")
}

__add_ngx_module_headers_more() {
    local name="ngx_headers_more"
    if [[ ! -d ${name} ]]; then
        __git_github "openresty/headers-more-nginx-module" "master" ${name}
    fi
    __ngx_module+=("--add-module=../${name}")
}

__add_ngx_module_brotli() {
    local name="ngx_brotli"
    if [[ ! -d ${name} ]]; then
        __git_github "google/ngx_brotli" "master" ${name}
        rm -rf "${__build_temp}/${name}/deps/brotli"
        ln -s "${__build_temp}/brotli/" "${__build_temp}/${name}/deps/brotli"
    fi
    __ngx_module+=("--add-module=../${name}")
}

__add_ngx_module_zstd() {
    local name="ngx_zstd"
    if [[ ! -d ${name} ]]; then
        __git_github "web-ngx/ngx_zstd" "master" ${name}
    fi
    __ngx_module+=("--add-module=../${name}")
}

compile_ngx() {
    local __ngx_module=()
    __add_ngx_module_headers_more
    __add_ngx_module_http_trim_filter
    __add_ngx_module_zstd
    __add_ngx_module_brotli
    local name="nginx"
    local __prefix="${prefix_root}/${name}"
    local __pid_path="/run/${name}.pid"
    local __ngx_bin="${__prefix}/sbin/${name}"
    local __ngx_conf="${__prefix}/conf/${name}.conf"
    local __ngx_service_name="${name}.service"
    local __ngx_service="${prefix_root}/${__ngx_service_name}"
    local __ngx_user="nobody"
    local __ngx_group="nogroup"
    if [[ ! -d ${name} ]]; then
        __git_github "web-ngx/nginx" "modify" ${name}
        sed -i '/ngx_write_stderr("configure arguments:" NGX_CONFIGURE NGX_LINEFEED);/d' "${name}/src/core/nginx.c"
    fi
    pushd ${name} >/dev/null
    if [[ ${BUILD_STEP} == "PROFILE_USE" ]]; then
        if [[ -f "Makefile" ]]; then
            make clean
        fi
        rm -rf "${__prefix}"
    fi
    local __cflags __ldflags
    __cflags="-O3"
    __cflags+=" ${CFLAGS}"
    __cflags+=" -flto=auto -flto-partition=one -ffat-lto-objects"
    __cflags+=" -fwhole-program"
    __cflags+=" -ffreestanding"
    __cflags+=" -DNGX_HAVE_DLOPEN=0"
    __ldflags="-no-pie"
    __ldflags+=" -static-libgcc -static-libstdc++"
    __ldflags+=" -L."
    __ldflags+=" ${LDFLAGS}"
    __ldflags+=" -Wl,-z,start-stop-visibility=hidden"
    ln -sf "$(gcc --print-file-name=libgomp.a)" .
    BUILD_HASH="$(__crc "${COMMIT_LIST[*]}")"
    CFLAGS="${__cflags}" ./auto/configure \
        --build="${BUILD_HASH}" \
        --prefix="${__prefix}" \
        --user="${__ngx_user}" \
        --group="${__ngx_group}" \
        --lock-path="/var/lock/${name}.lock" \
        --pid-path="${__pid_path}" \
        --http-client-body-temp-path="tmp/body" \
        --http-fastcgi-temp-path="tmp/fastcgi" \
        --http-proxy-temp-path="tmp/proxy" \
        --http-scgi-temp-path="tmp/scgi" \
        --http-uwsgi-temp-path="tmp/uwsgi" \
        --with-ld-opt="${__ldflags}" \
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
        --with-stream \
        --with-stream_realip_module \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --without-poll_module \
        --without-select_module \
        --without-http_access_module \
        --without-http_autoindex_module \
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
    if [[ ! -d "${__prefix}/tmp" ]]; then
        mkdir -p "${__prefix}/tmp"
    fi
    ngx_config
    chown -R "${__ngx_user}:${__ngx_group}" "${__prefix}"
    if [[ ${BUILD_STEP} == "PROFILE_GEN" ]]; then
        __ngx_config_test
    fi
    popd >/dev/null
    if [[ ${BUILD_STEP} == "PROFILE_USE" ]]; then
        pushd "${prefix_root}" >/dev/null
        COMPRESS_FILE_NAME="${name}.tar.xz"
        __compress "${WORKSPACE}/${COMPRESS_FILE_NAME}" "${name}" "ssl" "${name}.service"
        popd >/dev/null
        gen_deploy_script
    fi
}

__compile_flags() {
    local option_arch="${option_arch:-}"
    local option_tune="${option_tune:-}"
    local option_mold="${option_mold:-}"
    if [[ ${BUILD_STEP} == "PROFILE_USE" ]]; then
        if [[ -n ${option_arch} ]]; then
            __cflags+=" -march=${option_arch}"
        fi
        if [[ -n ${option_tune} ]]; then
            __cflags+=" -mtune=${option_tune}"
        fi
    fi
    __cflags+=" -I\"${__install_dir}/include\""
    __cflags+=" -mtls-dialect=gnu2"
    __cflags+=" -maccumulate-outgoing-args -mno-push-args"
    __cflags+=" -minline-all-stringops"
    __cflags+=" -mvzeroupper"
    __cflags+=" -mnoreturn-no-callee-saved-registers"
    __cflags+=" -mno-red-zone"
    __cflags+=" -Wa,-O2"
    __cflags+=" -Wa,-acdn"
    __cflags+=" -Wa,-momit-lock-prefix=yes"
    __cflags+=" -Wa,-no-pad-sections"
    __cflags+=" -Wa,--64"
    __cflags+=" -Wa,--strip-local-absolute"
    __cflags+=" -fallow-store-data-races"
    __cflags+=" -ffast-math"
    __cflags+=" -fgcse -fgcse-lm -fgcse-sm -fgcse-las -fgcse-after-reload"
    __cflags+=" -fmodulo-sched -fmodulo-sched-allow-regmoves"
    __cflags+=" -fmerge-all-constants"
    __cflags+=" -fomit-frame-pointer"
    __cflags+=" -fforce-addr"
    __cflags+=" -fipa-pta"
    __cflags+=" -fdevirtualize-speculatively -fdevirtualize-at-ltrans"
    __cflags+=" -fgraphite-identity"
    __cflags+=" -ffinite-loops"
    __cflags+=" -finhibit-size-directive"
    __cflags+=" -fopenmp -fopenmp-simd"
    __cflags+=" -fsimd-cost-model=unlimited"
    __cflags+=" -fvect-cost-model=unlimited"
    __cflags+=" -fvariable-expansion-in-unroller"
    __cflags+=" -ftrivial-auto-var-init=zero"
    __cflags+=" -fzero-call-used-regs=used-gpr"
    __cflags+=" -floop-nest-optimize"
    __cflags+=" -floop-parallelize-all"
    __cflags+=" -ftree-vectorize"
    __cflags+=" -ftree-parallelize-loops=4"
    __cflags+=" -fshort-wchar -funsigned-char"
    __cflags+=" -ffunction-sections -fdata-sections"
    __cflags+=" -fsection-anchors"
    __cflags+=" -fvisibility=hidden"
    __cflags+=" -fcf-protection=none"
    __cflags+=" -fdelete-null-pointer-checks"
    __cflags+=" -fno-bounds-check"
    __cflags+=" -fno-stack-check"
    __cflags+=" -fno-stack-protector"
    __cflags+=" -fno-stack-clash-protection"
    __cflags+=" -fno-sanitize=all"
    __cflags+=" -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-jump-tables"
    __cflags+=" -fno-exceptions -fdelete-dead-exceptions"
    __cflags+=" -fno-semantic-interposition"
    __cflags+=" -fno-var-tracking-assignments"
    __cflags+=" -fno-printf-return-value"
    __cflags+=" -fno-plt"
    __cflags+=" -fno-common"
    __cflags+=" -fno-signed-zeros"
    __cflags+=" -fno-trapping-math"
    __cflags+=" -U_FORTIFY_SOURCE"
    __cflags+=" -D_LARGEFILE64_SOURCE=1 -D_FILE_OFFSET_BITS=64"
    __cflags+=" --param dse-max-alias-queries-per-store=2048"
    __cflags+=" --param dse-max-object-size=8192"
    __cflags+=" --param gcse-cost-distance-ratio=100"
    __cflags+=" --param gcse-unrestricted-cost=0"
    __cflags+=" --param max-gcse-memory=2147483647"
    __cflags+=" --param graphite-max-arrays-per-scop=0"
    __cflags+=" --param graphite-max-nb-scop-params=0"
    __cflags+=" --param inline-min-speedup=1"
    __cflags+=" --param large-unit-insns=0"
    __cflags+=" --param loop-invariant-max-bbs-in-loop=1073741824"
    __cflags+=" --param loop-max-datarefs-for-datadeps=1073741824"
    __cflags+=" --param lto-min-partition=50000"
    __cflags+=" --param max-combine-insns=4"
    __cflags+=" --param max-crossjump-edges=100000"
    __cflags+=" --param max-cse-insns=2147483647"
    __cflags+=" --param max-cselib-memory-locations=2147483647"
    __cflags+=" --param max-hoist-depth=0"
    __cflags+=" --param max-isl-operations=0"
    __cflags+=" --param max-partial-antic-length=2147483647"
    __cflags+=" --param max-reload-search-insns=5000"
    __cflags+=" --param max-sched-ready-insns=5000"
    __cflags+=" --param max-ssa-name-query-depth=10"
    __cflags+=" --param max-tail-merge-comparisons=2147483647"
    __cflags+=" --param max-tail-merge-iterations=2147483647"
    __cflags+=" --param max-variable-expansions-in-unroller=100"
    __cflags+=" --param min-spec-prob=0"
    __cflags+=" --param parloops-chunk-size=65536"
    __cflags+=" --param parloops-schedule=dynamic"
    __cflags+=" --param prefetch-latency=0"
    __cflags+=" --param simultaneous-prefetches=0"
    __cflags+=" --param sink-frequency-threshold=100"
    __cxxflags+=" ${__cflags}"
    __cxxflags+=" -faligned-new"
    __cxxflags+=" -fcoroutines"
    __cxxflags+=" -fsized-deallocation"
    __cxxflags+=" -fnothrow-opt"
    __cxxflags+=" -fno-rtti"
    __cxxflags+=" -fno-enforce-eh-specs"
    __cxxflags+=" -fvisibility-inlines-hidden"
    __ldflags+=" -L\"${__install_dir}/lib\""
    if [[ -n ${option_mold} ]]; then
        __ldflags+=" -fuse-ld=mold"
    fi
    __ldflags+=" -fuse-linker-plugin"
    __ldflags+=" -Wl,-O2"
    __ldflags+=" -Wl,--strip-all"
    __ldflags+=" -Wl,--discard-all"
    __ldflags+=" -Wl,--as-needed"
    __ldflags+=" -Wl,--gc-sections"
    __ldflags+=" -Wl,--build-id=none"
    __ldflags+=" -Wl,--hash-style=gnu"
    __ldflags+=" -Wl,--enable-new-dtags"
    __ldflags+=" -Wl,--no-eh-frame-hdr"
    __ldflags+=" -Wl,--no-undefined"
    if [[ -n ${option_mold} ]]; then
        __ldflags+=" -Wl,--icf=all"
        __ldflags+=" -Wl,--ignore-data-address-equality"
        __ldflags+=" -Wl,--relocatable-merge-sections"
        __ldflags+=" -Wl,-z,nokeep-text-section-prefix"
        __ldflags+=" -Wl,-z,rewrite-endbr"
    fi
    if [[ -z ${option_mold} ]]; then
        __ldflags+=" -Wl,--demangle"
        __ldflags+=" -Wl,--relax"
        __ldflags+=" -Wl,--sort-common=ascending"
        __ldflags+=" -Wl,--sort-section=alignment"
        __ldflags+=" -Wl,--no-allow-shlib-undefined"
        __ldflags+=" -Wl,--no-ctf-variables"
        __ldflags+=" -Wl,--no-ld-generated-unwind-info"
        __ldflags+=" -Wl,--no-whole-archive"
        __ldflags+=" -Wl,-z,combreloc"
        __ldflags+=" -Wl,-z,nodynamic-undefined-weak"
        __ldflags+=" -Wl,-z,pack-relative-relocs"
        __ldflags+=" -Wl,-z,unique-symbol"
        __ldflags+=" -Wl,-z,now"
        __ldflags+=" -Wl,-z,x86-64-v3"
    fi
    __ldflags+=" -Wl,-z,nosectionheader"
    __ldflags+=" -Wl,-z,nodump"
    __ldflags+=" -lgomp"
}

compile() {
    if [[ ${BUILD_STEP} == "PROFILE_GEN" ]]; then
        if [[ -d ${__build_temp} ]]; then
            rm -rf "${__build_temp}"
        fi
        mkdir -p "${__build_temp}"
    fi
    pushd "${__build_temp}" >/dev/null
    local __cflags __cxxflags __ldflags
    __compile_flags
    __cflags+=" ${CFLAGS}"
    __cxxflags+=" ${CXXFLAGS}"
    __ldflags+=" ${LDFLAGS}"
    __cflags="$(echo "${__cflags}" | sed -E 's/^\s+|\s+$//g')"
    __cxxflags="$(echo "${__cxxflags}" | sed -E 's/^\s+|\s+$//g')"
    __ldflags="$(echo "${__ldflags}" | sed -E 's/^\s+|\s+$//g')"
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_jemalloc
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_zlib
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_brotli
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_zstd
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_pcre
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_openssl
    CFLAGS="${__cflags}" CXXFLAGS="${__cxxflags}" LDFLAGS="${__ldflags}" compile_ngx
    popd >/dev/null
}

build() {
    local CFLAGS CXXFLAGS LDFLAGS
    local __cflags __ldflags
    local __profile_dir="/tmp/profile"
    local __build_temp="/tmp/build"
    local __install_dir="${__build_temp}/install"
    case "${BUILD_STEP:-}" in
        "PROFILE_GEN")
            if [[ -d ${__profile_dir} ]]; then
                rm -rf "${__profile_dir}"
            fi
            __cflags="-fprofile-generate=${__profile_dir}"
            __ldflags="-lgcov"
            CFLAGS="${__cflags}" CXXFLAGS="${__cflags}" LDFLAGS="${__ldflags}" compile
            rm -rf "${__install_dir}"
            BUILD_STEP="PROFILE_USE" build
            ;;
        "PROFILE_USE")
            __cflags="-fprofile-use=${__profile_dir} -fprofile-correction"
            __cflags+=" -Wno-coverage-mismatch -Wno-missing-profile"
            __ldflags=""
            CFLAGS="${__cflags}" CXXFLAGS="${__cflags}" LDFLAGS="${__ldflags}" compile
            ;;
        *)
            BUILD_STEP="PROFILE_GEN" build
            ;;
    esac
}

__write_line() {
    if [[ -n ${1:-} ]]; then
        __context+="${1}"
    fi
    __context+="\n"
}

__ngx_config_write() {
    local __str=${1:-}
    if [[ ${__str: -1} == "}" ]]; then
        __level=$((__level - 1))
    fi
    if [[ ${__level} -gt 0 ]]; then
        if [[ -n ${__str} ]]; then
            __context+=$(eval "printf ' %.0s' {1..$((__level * 4))}")
        fi
    fi
    __write_line "${__str}"
    if [[ ${__str: -1} == "{" ]]; then
        __level=$((__level + 1))
    fi
}

__ngx_config_service() {
    local -i __level=0
    local __context
    __write_line "[Unit]"
    __write_line "Description=The ${name} HTTP and reverse proxy server"
    __write_line "After=network-online.target remote-fs.target nss-lookup.target"
    __write_line "Wants=network-online.target"
    __write_line
    __write_line "[Service]"
    __write_line "Type=forking"
    __write_line "PIDFile=${__pid_path}"
    __write_line "ExecStartPre=${__ngx_bin} -t -q -c '${__ngx_conf}' -g 'daemon on; master_process on;'"
    __write_line "ExecStart=${__ngx_bin} -c '${__ngx_conf}' -g 'daemon on; master_process on;'"
    __write_line "ExecReload=${__ngx_bin} -c '${__ngx_conf}' -g 'daemon on; master_process on;' -s reload"
    __write_line "ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile '${__pid_path}'"
    __write_line "PrivateTmp=true"
    __write_line "TimeoutStopSec=5"
    __write_line "KillMode=mixed"
    __write_line
    __write_line "[Install]"
    __write_line "WantedBy=multi-user.target"
    echo -e -n "${__context}" >"${__ngx_service}"
}

__ngx_config_index() {
    local -i __level=0
    local __context
    __ngx_config_write "user ${__ngx_user} ${__ngx_group};"
    __ngx_config_write
    __ngx_config_write "worker_processes auto;"
    __ngx_config_write "worker_cpu_affinity auto;"
    __ngx_config_write "worker_priority -20;"
    __ngx_config_write "worker_rlimit_nofile 262140;"
    __ngx_config_write "worker_shutdown_timeout 5s;"
    __ngx_config_write
    __ngx_config_write "pid ${__pid_path};"
    __ngx_config_write
    __ngx_config_write "thread_pool default threads=16 max_queue=65536;"
    __ngx_config_write
    __ngx_config_write "error_log logs/error.log emerg;"
    __ngx_config_write
    __ngx_config_write "pcre_jit on;"
    if [[ ${BUILD_STEP} == "PROFILE_USE" ]]; then
        __ngx_config_write "quic_bpf on;"
    fi
    __ngx_config_write
    __ngx_config_write "timer_resolution 500ms;"
    __ngx_config_write
    __ngx_config_write "events {"
    __ngx_config_write "use epoll;"
    __ngx_config_write "multi_accept on;"
    __ngx_config_write "worker_connections 1024;"
    __ngx_config_write "worker_aio_requests 256;"
    __ngx_config_write "accept_mutex on;"
    __ngx_config_write "accept_mutex_delay 50ms;"
    __ngx_config_write "}"
    __ngx_config_write
    __ngx_config_write "http {"
    __ngx_config_write "charset utf-8;"
    __ngx_config_write
    __ngx_config_write "include mime.types;"
    __ngx_config_write "default_type application/octet-stream;"
    __ngx_config_write
    __ngx_config_write "merge_slashes off;"
    __ngx_config_write
    __ngx_config_write "log_not_found off;"
    __ngx_config_write
    __ngx_config_write "aio threads=default;"
    __ngx_config_write "aio_write on;"
    __ngx_config_write
    __ngx_config_write "tcp_nopush on;"
    __ngx_config_write "tcp_nodelay on;"
    __ngx_config_write
    __ngx_config_write "reset_timedout_connection on;"
    __ngx_config_write
    __ngx_config_write "sendfile on;"
    __ngx_config_write "sendfile_max_chunk 512k;"
    __ngx_config_write
    __ngx_config_write "send_timeout 10s;"
    __ngx_config_write
    __ngx_config_write "connection_pool_size 4k;"
    __ngx_config_write "request_pool_size 32k;"
    __ngx_config_write
    __ngx_config_write "directio 4m;"
    __ngx_config_write "directio_alignment 4k;"
    __ngx_config_write
    __ngx_config_write "server_names_hash_max_size 2048;"
    __ngx_config_write "server_names_hash_bucket_size 128;"
    __ngx_config_write "types_hash_max_size 2048;"
    __ngx_config_write "types_hash_bucket_size 128;"
    __ngx_config_write "variables_hash_max_size 2048;"
    __ngx_config_write "variables_hash_bucket_size 128;"
    __ngx_config_write "output_buffers 1 256k;"
    __ngx_config_write
    __ngx_config_write "client_body_buffer_size 128k;"
    __ngx_config_write "client_body_timeout 3s;"
    __ngx_config_write "client_header_buffer_size 16k;"
    __ngx_config_write "client_header_timeout 3s;"
    __ngx_config_write "client_max_body_size 0;"
    __ngx_config_write "large_client_header_buffers 4 32k;"
    __ngx_config_write
    __ngx_config_write "http3_stream_buffer_size 512k;"
    __ngx_config_write
    __ngx_config_write "postpone_output 0;"
    __ngx_config_write
    __ngx_config_write "keepalive_time 10m;"
    __ngx_config_write "keepalive_timeout 10s;"
    __ngx_config_write "keepalive_requests 50000;"
    __ngx_config_write "keepalive_disable msie6;"
    __ngx_config_write
    __ngx_config_write "lingering_time 10s;"
    __ngx_config_write "lingering_timeout 5s;"
    __ngx_config_write
    __ngx_config_write "server_tokens off;"
    __ngx_config_write
    __ngx_config_write "more_clear_headers 'Server';"
    __ngx_config_write "more_clear_headers 'X-Powered-By';"
    __ngx_config_write
    __ngx_config_write "zstd on;"
    __ngx_config_write "zstd_static on;"
    __ngx_config_write "zstd_comp_level 9;"
    __ngx_config_write "zstd_min_length 256;"
    __ngx_config_write "zstd_types *;"
    __ngx_config_write
    __ngx_config_write "brotli on;"
    __ngx_config_write "brotli_static on;"
    __ngx_config_write "brotli_comp_level 6;"
    __ngx_config_write "brotli_buffers 16 8k;"
    __ngx_config_write "brotli_min_length 256;"
    __ngx_config_write "brotli_types *;"
    __ngx_config_write
    __ngx_config_write "gzip on;"
    __ngx_config_write "gzip_static on;"
    __ngx_config_write "gzip_comp_level 5;"
    __ngx_config_write "gzip_min_length 256;"
    __ngx_config_write "gzip_buffers 16 8k;"
    __ngx_config_write "gzip_proxied any;"
    __ngx_config_write "gzip_vary on;"
    __ngx_config_write "gzip_types *;"
    __ngx_config_write
    __ngx_config_write "quic_gso on;"
    __ngx_config_write "quic_retry on;"
    __ngx_config_write
    __ngx_config_write "http2 on;"
    __ngx_config_write "http3 on;"
    __ngx_config_write "http3_hq on;"
    __ngx_config_write
    __ngx_config_write "ssl_buffer_size 512;"
    __ngx_config_write "ssl_ciphers HIGH:!CBC;"
    __ngx_config_write "ssl_ecdh_curve X25519:x448:secp384r1:secp521r1;"
    __ngx_config_write "ssl_protocols TLSv1.2 TLSv1.3;"
    __ngx_config_write "ssl_prefer_server_ciphers on;"
    __ngx_config_write
    __ngx_config_write "ssl_early_data on;"
    __ngx_config_write
    __ngx_config_write "ssl_ocsp on;"
    __ngx_config_write "ssl_ocsp_cache shared:OCSP:1m;"
    __ngx_config_write
    __ngx_config_write "ssl_stapling on;"
    __ngx_config_write "ssl_stapling_verify on;"
    __ngx_config_write
    __ngx_config_write "ssl_session_tickets on;"
    __ngx_config_write "ssl_session_cache shared:SESSION:1m;"
    __ngx_config_write
    __ngx_config_write "ssl_dyn_rec_enable on;"
    __ngx_config_write "ssl_dyn_rec_size_hi 4229;"
    __ngx_config_write "ssl_dyn_rec_size_lo 1369;"
    __ngx_config_write "ssl_dyn_rec_threshold 40;"
    __ngx_config_write "ssl_dyn_rec_timeout 1000;"
    __ngx_config_write
    __ngx_config_write "resolver 8.8.8.8 1.1.1.1 valid=60s ipv6=off;"
    __ngx_config_write "resolver_timeout 2s;"
    __ngx_config_write
    __ngx_config_write "access_log off;"
    __ngx_config_write
    __ngx_config_write "server {"
    __ngx_config_write "listen 80 deferred reuseport fastopen=3 default_server;"
    __ngx_config_write "listen [::]:80 deferred reuseport fastopen=3 default_server;"
    __ngx_config_write "return 444;"
    __ngx_config_write "}"
    __ngx_config_write
    __ngx_config_write "server {"
    __ngx_config_write "listen 443 quic reuseport default_server;"
    __ngx_config_write "listen 443 deferred ssl reuseport fastopen=3 default_server;"
    __ngx_config_write "listen [::]:443 quic reuseport default_server;"
    __ngx_config_write "listen [::]:443 deferred ssl reuseport fastopen=3 default_server;"
    __ngx_config_write "ssl_reject_handshake on;"
    __ngx_config_write "}"
    __ngx_config_write
    __ngx_config_write "include '${www_root}/*.conf';"
    __ngx_config_write "}"
    echo -e -n "${__context}" >"${__prefix}/conf/${name}.conf"
}

__ngx_config_server() {
    local -i __h3_port=443
    local -i __level=0
    local __context __server_name
    __server_name="${1/./_}"
    __ngx_config_write "server {"
    __ngx_config_write "listen 80;"
    __ngx_config_write "listen [::]:80;"
    __ngx_config_write "server_name $1;"
    __ngx_config_write
    __ngx_config_write "set \$alt_svc '';"
    __ngx_config_write
    __ngx_config_write "if (\$http3 = '') {"
    __ngx_config_write "set \$alt_svc 'h3=\":${__h3_port}\"; ma=31536000; persist=1';"
    __ngx_config_write "}"
    __ngx_config_write
    __ngx_config_write "add_header Alt-Svc '\$alt_svc' always;"
    __ngx_config_write
    __ngx_config_write "return 301 'https://\$host\$request_uri';"
    __ngx_config_write "}"
    __ngx_config_write
    __ngx_config_write "server {"
    __ngx_config_write "listen 443 ssl;"
    __ngx_config_write "listen [::]:443 ssl;"
    __ngx_config_write "listen ${__h3_port} quic;"
    __ngx_config_write "listen [::]:${__h3_port} quic;"
    __ngx_config_write "server_name $1;"
    __ngx_config_write
    __ngx_config_write "set \$alt_svc '';"
    __ngx_config_write
    __ngx_config_write "if (\$http3 = '') {"
    __ngx_config_write "set \$alt_svc 'h3=\":${__h3_port}\"; ma=31536000; persist=1';"
    __ngx_config_write "}"
    __ngx_config_write
    __ngx_config_write "add_header Alt-Svc '\$alt_svc' always;"
    __ngx_config_write
    __ngx_config_write "add_header Cache-Control 'no-transform' always;"
    __ngx_config_write "add_header Priority 'u=0, i' always;"
    __ngx_config_write "add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains; preload' always;"
    __ngx_config_write "add_header Timing-Allow-Origin '*' always;"
    __ngx_config_write "add_header X-Content-Type-Options 'nosniff' always;"
    __ngx_config_write "add_header X-Frame-Options 'SAMEORIGIN' always;"
    __ngx_config_write "add_header X-XSS-Protection '1; mode=block' always;"
    __ngx_config_write
    __ngx_config_write "include '${www_root}/${1}.d/*.conf';"
    __ngx_config_write
    __ngx_config_write "access_log logs/${__server_name}.log;"
    __ngx_config_write "}"
    echo -e -n "${__context}" >"${www_root}/${__server_name}.conf"
}

__ngx_config_test() {
    local __cert_dir="${__build_temp}/certs"
    if [[ ! -d ${__cert_dir} ]]; then
        mkdir -p "${__cert_dir}"
    fi
    local __ser_name="localhost"
    __ngx_config_server "${__ser_name}"
    __local_cert_gen "${__ser_name}"
    "${__ngx_bin}" -t -q -c "${__ngx_conf}" -g 'daemon on; master_process on;'
    "${__ngx_bin}" -c "${__ngx_conf}" -g 'daemon on; master_process on;' &
    sleep 2
    "${__ngx_bin}" -c "${__ngx_conf}" -g 'daemon on; master_process on;' -s reload
    curl -kL "http://${__ser_name}/" >/dev/null
    curl -kL -4 "http://${__ser_name}/" >/dev/null
    curl -kL -6 "http://${__ser_name}/" >/dev/null
    curl -kL --http0.9 "http://${__ser_name}/" >/dev/null
    curl -kL --http1.0 "http://${__ser_name}/" >/dev/null
    curl -kL --http1.1 "http://${__ser_name}/" >/dev/null
    curl -kL --http2 "https://${__ser_name}/" >/dev/null
    curl -kL --http2-prior-knowledge "https://${__ser_name}/" >/dev/null
    curl -kL --http3 "https://${__ser_name}/" >/dev/null
    curl -kL --http3-only "https://${__ser_name}/" >/dev/null
    curl -kL --tr-encoding "https://${__ser_name}/" >/dev/null
    curl -kL --compressed "https://${__ser_name}/" >/dev/null
    curl -kL --compressed -H "Accept-Encoding: deflate" "https://${__ser_name}/" >/dev/null
    curl -kL --compressed -H "Accept-Encoding: br" "https://${__ser_name}/" >/dev/null
    curl -kL --compressed -H "Accept-Encoding: gzip" "https://${__ser_name}/" >/dev/null
    curl -kL --compressed -H "Accept-Encoding: zstd" "https://${__ser_name}/" >/dev/null
    curl -kL --mptcp "https://${__ser_name}/" >/dev/null
    curl -kL --tlsv1.2 "https://${__ser_name}/" >/dev/null
    curl -kL --tlsv1.3 "https://${__ser_name}/" >/dev/null
    curl -kL --tls-earlydata "https://${__ser_name}/" >/dev/null
    curl -kL --tcp-fastopen "https://${__ser_name}/" >/dev/null
    curl -kL --tcp-nodelay "https://${__ser_name}/" >/dev/null
    start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile "${__pid_path}"
    rm -rf "${www_root}"
}

__local_cert_gen() {
    local -i __level=0
    local __context
    __write_line "authorityInfoAccess = @ocsp_section"
    __write_line "basicConstraints = critical, CA:FALSE"
    __write_line "certificatePolicies = 2.23.140.1.2.1"
    __write_line "crlDistributionPoints = @crl_section"
    __write_line "extendedKeyUsage = critical, serverAuth, clientAuth"
    __write_line "keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment, keyAgreement"
    __write_line "subjectAltName = @alt_names"
    __write_line "subjectKeyIdentifier = hash"
    __write_line "tlsfeature = status_request"
    __write_line "[ alt_names ]"
    __write_line "DNS.1=$1"
    __write_line "[ crl_section ]"
    __write_line "URI.0 = http://$1/crl"
    __write_line "[ ocsp_section ]"
    __write_line "caIssuers;URI.0 = http://$1/ca"
    __write_line "OCSP;URI.0 = http://$1/ocsp"
    local __name="${1/./_}"
    openssl ecparam -genkey -name secp384r1 -out "${__cert_dir}/ca_ecc.key"
    openssl req -new -x509 -sha384 -days 1 -subj "/C=US/ST=Test/L=Test/O=Test/CN=Test Root CA" \
        -key "${__cert_dir}/ca_ecc.key" -out "${__cert_dir}/ca_ecc.crt"
    openssl ecparam -genkey -name secp384r1 -out "${__cert_dir}/${__name}_ecc.key"
    openssl req -new -subj "/CN=$1" \
        -key "${__cert_dir}/${__name}_ecc.key" -out "${__cert_dir}/${__name}_ecc.csr"
    openssl x509 -req -days 1 -sha384 \
        -CA "${__cert_dir}/ca_ecc.crt" -CAkey "${__cert_dir}/ca_ecc.key" \
        -in "${__cert_dir}/${__name}_ecc.csr" -out "${__cert_dir}/${__name}_ecc.crt" \
        -extfile <(echo -e "${__context}")
    cat "${__cert_dir}/${__name}_ecc.crt" <(echo) "${__cert_dir}/ca_ecc.crt" >"${__cert_dir}/${__name}_fullchain_ecc.crt"
    if [[ ! -d "${www_root}/${1}.d" ]]; then
        mkdir -p "${www_root}/${1}.d"
    fi
    echo "ssl_certificate '${__cert_dir}/${__name}_fullchain_ecc.crt';" >>"${www_root}/${1}.d/cert.conf"
    echo "ssl_certificate_key '${__cert_dir}/${__name}_ecc.key';" >>"${www_root}/${1}.d/cert.conf"
}

ngx_config() {
    __ngx_config_index
    __ngx_config_service
    find "${__prefix}/conf" -type f -name "*.default" -exec rm -f {} \;
    mkdir -p "${www_root}"
}

gen_deploy_script() {
    local -i __level=0
    local __context
    local deploy_tmp="${deploy_tmp:-}"
    if [[ -n ${deploy_tmp} ]]; then
        deploy_tmp+="/"
    fi
    __write_line "#!/bin/bash"
    __write_line
    __write_line "if [[ -f \"${__ngx_bin}\" ]]; then"
    __write_line "    mv \"${__ngx_bin}\" \"${__ngx_bin}.old\""
    __write_line "fi"
    __write_line
    __write_line "tar -xf \"${deploy_tmp}${COMPRESS_FILE_NAME}\" -C \"${prefix_root}\""
    __write_line "mv -f \"${__ngx_service}\" \"/usr/lib/systemd/system/${__ngx_service_name}\""
    __write_line "ln -sf \"${__ngx_bin}\" \"/usr/local/bin/${name}\""
    __write_line
    __write_line "if [[ ! -d \"${www_root}\" ]]; then"
    __write_line "    mkdir -p \"${www_root}\""
    __write_line "fi"
    __write_line
    __write_line "if [[ \"\$(systemctl is-enabled ${__ngx_service_name})\" == \"disabled\" ]]; then"
    __write_line "    systemctl enable ${__ngx_service_name}"
    __write_line "else"
    __write_line "    systemctl reenable ${__ngx_service_name}"
    __write_line "fi"
    __write_line
    __write_line "if ((\$(pgrep -c \"${name}\") > 0)); then"
    __write_line "    kill -USR2 \$(cat ${__pid_path})"
    __write_line "    sleep 2"
    __write_line "    if [[ -f \"${__pid_path}.oldbin\" ]]; then"
    __write_line "        kill -QUIT \$(cat \"${__pid_path}.oldbin\")"
    __write_line "        rm -f \"${__pid_path}.oldbin\""
    __write_line "    fi"
    __write_line "else"
    __write_line "    systemctl start ${__ngx_service_name}"
    __write_line "fi"
    __write_line
    __write_line "rm -f \"${__ngx_bin}.old\""
    __write_line "rm -f \"${deploy_tmp}${COMPRESS_FILE_NAME}\""
    # shellcheck disable=SC2016
    __write_line 'rm -f "$(realpath $0)"'
    local __script="deploy_${name}.sh"
    echo -e -n "${__context}" >"${WORKSPACE}/${__script}"
    if [[ -n ${IS_CI} ]]; then
        echo "deploy_script=${__script}" >>"${GITHUB_OUTPUT}"
    fi
}

main() {
    local WORKSPACE BUILD_HASH BUILD_STEP COMPRESS_FILE_NAME
    local COMMIT_LIST=()
    local IS_CI="${CI:-}"

    if [[ -n ${IS_CI} ]]; then
        WORKSPACE="${GITHUB_WORKSPACE}"
    else
        WORKSPACE="$(pwd)"
    fi

    local prefix_root="${prefix:-/opt}"
    local www_root="${prefix_root}/www"

    if [[ "$(gcc -dumpversion)" != "14" ]]; then
        while IFS= read -r file; do
            ln -sf "${file}" "${file%-*}"
        done < <(find /usr/bin -type l -name "*-14")
    fi

    build

    if [[ -n ${IS_CI} ]]; then
        {
            echo "build_hash=${BUILD_HASH}"
            echo "file_name=${COMPRESS_FILE_NAME}"
            echo "www=${www_root}"
        } >>"${GITHUB_OUTPUT}"
    fi

    exit 0
}

main
