#
# checkov:skip=CKV_DOCKER_2:Disable HEALTHCHECK
# ^^^ Healhcheck doesn't make sense, because we are building a CLI tool, not server program
# checkov:skip=CKV_DOCKER_7:Disable FROM :latest
# ^^^ false positive for `--platform=$BUILDPLATFORM`

# hadolint global ignore=DL3042
# ^^^ Allow pip's cache, because we use it for cache mount
# hadolint global ignore=SC1091
# ^^^ False positives for sourcing files into current shell

### Reusable components ###

## Gitman ##

FROM --platform=$BUILDPLATFORM debian:12.7-slim AS gitman--base
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        python3-pip python3 >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY docker-utils/dependencies/gitman/requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install --requirement requirements.txt --target python-vendor --quiet

FROM --platform=$BUILDPLATFORM debian:12.7-slim AS gitman--final
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        ca-certificates git python3 >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=gitman--base /app/ ./
ENV PATH="/app/python-vendor/bin:$PATH" \
    PYTHONPATH=/app/python-vendor

## Custom NodeJS ##

FROM --platform=$BUILDPLATFORM gitman--final AS nodenv--gitman
WORKDIR /app
COPY docker-utils/dependencies/gitman/nodenv/gitman.yml ./
RUN --mount=type=cache,target=/root/.gitcache \
    gitman install --quiet && \
    find . -type d -name .git -prune -exec rm -rf {} \;

FROM --platform=$BUILDPLATFORM gitman--final AS node-build--gitman
WORKDIR /app
COPY docker-utils/dependencies/gitman/node-build/gitman.yml ./
RUN --mount=type=cache,target=/root/.gitcache \
    gitman install --quiet && \
    find . -type d -name .git -prune -exec rm -rf {} \;

# TODO: Run on current architecture
FROM debian:12.7-slim AS nodejs--build1
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        g++ gcc make >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=nodenv--gitman /app/gitman-repositories/nodenv/ ./nodenv/
ENV NODENV_ROOT=/app/nodenv
RUN ./nodenv/src/configure && \
    make -C ./nodenv/src
COPY --from=node-build--gitman /app/gitman-repositories/node-build/ ./nodenv/plugins/node-build/

# TODO: Setup cross compilation variables
FROM --platform=$BUILDPLATFORM debian:12.7-slim AS nodejs--build2
ARG TARGETARCH TARGETVARIANT
WORKDIR /app
RUN export CFLAGS="-s" && \
    export CXXFLAGS="-s" && \
    export CC="gcc-11" && \
    export CXX="g++-11" && \
    export CONFIGURE_OPTS="" && \
    export NODE_CONFIGURE_OPTS="" && \
    export NODE_CONFIGURE_OPTS2="--cross-compiling --dest-os=linux" && \
    export NODE_MAKE_OPTS="" && \
    export NODE_MAKE_OPTS2="-j$(nproc --all)" && \
    export MAKE_OPTS2="-j$(nproc --all)" && \
    if [ "$TARGETARCH" = 386 ] || [ "$TARGETARCH" = amd64 ]; then \
        export CFLAGS2="$CFLAGS -mtune=generic" && \
        export CXXFLAGS2="$CXXFLAGS -mtune=generic" && \
        if [ "$TARGETARCH" = 386 ]; then \
            export CONFIGURE_OPTS="--openssl-no-asm" && \
            export NODE_CONFIGURE_OPTS="--openssl-no-asm" && \
            export CFLAGS2="$CFLAGS -march=i686 -msse2" && \
            export CXXFLAGS2="$CXXFLAGS -march=i686 -msse2" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=x86" && \
        true; elif [ "$TARGETARCH" = amd64 ]; then \
            export CFLAGS2="$CFLAGS -march=x86-64" && \
            export CXXFLAGS2="$CXXFLAGS -march=x86-64" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=x86_64" && \
        true; else \
            printf 'Unsupported architecture %s/%s\n' "$TARGETARCH" "$TARGETVARIANT" && \
            exit 1 && \
        true; fi && \
    true; elif [ "$TARGETARCH" = arm ] || [ "$TARGETARCH" = arm32 ] || [ "$TARGETARCH" = arm64 ]; then \
        export CFLAGS2="$CFLAGS -mtune=generic-arch" && \
        export CXXFLAGS2="$CXXFLAGS -mtune=generic-arch" && \
        if [ "$TARGETVARIANT" = v5 ] || ( [ "$TARGETARCH" = arm ] && [ "$TARGETVARIANT" = '' ] ) || ( [ "$TARGETARCH" = arm32 ] && [ "$TARGETVARIANT" = '' ] ); then \
            export CFLAGS2="$CFLAGS -march=armv5t -mfloat-abi=soft" && \
            export CXXFLAGS2="$CXXFLAGS -march=armv5t -mfloat-abi=soft" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=arm --with-arm-float-abi=soft" && \
        true; elif [ "$TARGETVARIANT" = v6 ]; then \
            # TODO: If running the produced executable has problems
            # First try "-march=armv6z+fp -mfloat-abi=softfp"
            # Alternatively try out "-march=armv6z+nofp -mfloat-abi=soft"
            export CFLAGS2="$CFLAGS -march=armv6z+fp -mfloat-abi=hard" && \
            export CXXFLAGS2="$CXXFLAGS -march=armv6z+fp -mfloat-abi=hard" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=arm --with-arm-float-abi=hard --with-arm-fpu=vfp" && \
        true; elif [ "$TARGETVARIANT" = v7 ]; then \
            export CFLAGS2="$CFLAGS -march=armv7-a+vfpv4 -mfloat-abi=hard" && \
            export CXXFLAGS2="$CXXFLAGS -march=armv7-a+vfpv4 -mfloat-abi=hard" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=arm --with-arm-float-abi=hard --with-arm-fpu=vfpv3" && \
        true; elif [ "$TARGETVARIANT" = v8 ] || ( [ "$TARGETARCH" = arm64 ] && [ "$TARGETVARIANT" = '' ] ); then \
            export CFLAGS2="$CFLAGS -march=armv8-a+simd -mfloat-abi=hard" && \
            export CXXFLAGS2="$CXXFLAGS -march=armv8-a+simd -mfloat-abi=hard" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=arm64 --with-arm-float-abi=hard --with-arm-fpu=neon" && \
        true; elif [ "$TARGETVARIANT" = v9 ]; then \
            export CFLAGS2="$CFLAGS -march=armv9-a -mfloat-abi=hard" && \
            export CXXFLAGS2="$CXXFLAGS -march=armv9-a -mfloat-abi=hard" && \
            export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=arm64 --with-arm-float-abi=hard --with-arm-fpu=neon" && \
        true; else \
            printf 'Unsupported architecture %s/%s\n' "$TARGETARCH" "$TARGETVARIANT" && \
            exit 1 && \
        true; fi && \
    true; elif [ "$TARGETARCH" = ppc64le ]; then \
        export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=ppc64" && \
    true; elif [ "$TARGETARCH" = mips64le ]; then \
        export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=mips64el" && \
    true; elif [ "$TARGETARCH" = s390x ]; then \
        export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=s390x" && \
    true; elif [ "$TARGETARCH" = riscv64 ]; then \
        export NODE_CONFIGURE_OPTS2="$NODE_CONFIGURE_OPTS2 --dest-cpu=riscv64" && \
    true; else \
        printf 'Unsupported architecture %s/%s\n' "$TARGETARCH" "$TARGETVARIANT" && \
        exit 1 && \
    true; fi && \
    printf 'export CC="%s"\n' "$CC" >>build-env.sh && \
    printf 'export CXX="%s"\n' "$CXX" >>build-env.sh && \
    printf 'export CFLAGS="%s"\n' "$CFLAGS" >>build-env.sh && \
    printf 'export CXXFLAGS="%s"\n' "$CXXFLAGS" >>build-env.sh && \
    printf 'export CONFIGURE_OPTS="%s"\n' "$CONFIGURE_OPTS" >>build-env.sh && \
    printf 'export NODE_CONFIGURE_OPTS="%s"\n' "$NODE_CONFIGURE_OPTS" >>build-env.sh && \
    printf 'export NODE_MAKE_OPTS="%s"\n' "$NODE_MAKE_OPTS" >>build-env.sh
COPY .node-version ./
RUN printf 'export _NODE_VERSION="%s"\n' "$(cat .node-version)" >>build-env.sh
COPY --from=nodejs--build1 /app/ ./

# TODO: Test optimization options from https://www.reddit.com/r/cpp/comments/d74hfi/additional_optimization_options_in_gcc/
# -fdevirtualize-at-ltrans
# -fipa-pta
# TODO: Maybe try ccache for speedup? https://ccache.dev https://github.com/nodejs/node/blob/main/BUILDING.md#speeding-up-frequent-rebuilds-when-developing
# export CC="ccache $CC"
# export CXX="ccache $CXX"
# TODO: Cross-compile NodeJS in this stage
# - CONFIGURE_OPTS="--cross-compiling"
# - NODE_CONFIGURE_OPTS="--cross-compiling"
# TODO: Setup cache downloads directory
# TODO: Setup cache builds directory
# TODO: Enable LTO:
# - CONFIGURE_OPTS="--enable-lto"
# - NODE_CONFIGURE_OPTS="--enable-lto"
# - CFLAGS="-flto"
# - CXXFLAGS="-flto"
# Compile NodeJS
FROM debian:12.7-slim AS nodejs--build3
WORKDIR /app
# There is a probably bug with GCC-12, that's why GCC-11 is installed instead
# See more: https://github.com/nodejs/node/issues/53633
# TODO: Use default GCC(-12) after this problem is fixed or GCC-13 if it's available in stable debian
# TODO: Remove binutils
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        binutils ca-certificates curl g++-11 gcc-11 git libc6 make moreutils python3 time >/dev/null && \
    rm -rf /var/lib/apt/lists/*
ENV NODENV_ROOT=/app/nodenv \
    PATH="/app/nodenv/bin:$PATH"
COPY --from=nodejs--build2 /app/ ./
# TODO: Enable build cache
# RUN --mount=type=cache,target=/app/node-downloads \
#     --mount=type=cache,target=/app/node-builds \
# TODO: Run compilation under "chronic"
# TODO: Remove debug multiple builds
RUN export NODE_BUILD_CACHE_PATH="/app/node-downloads/$(cat .node-version)" && \
    export NODE_BUILD_BUILD_PATH="/app/node-builds/$(shasum /app/build-env.sh | sed 's~ .*$~~')" && \
    mkdir -p "$NODE_BUILD_CACHE_PATH" "$NODE_BUILD_BUILD_PATH" && \
    find "$NODE_BUILD_CACHE_PATH" >downloads-dir-before.txt && \
    find "$NODE_BUILD_BUILD_PATH" >builds-dir-before.txt && \
    . /app/build-env.sh && \
    printf 'Time 1:\n' >>time.txt && \
    ( time chronic nodenv install --compile --keep --verbose "$(cat .node-version)" 2>&1 ) 2>>time.txt && \
    find "$NODE_BUILD_CACHE_PATH" >downloads-dir-after.txt && \
    find "$NODE_BUILD_BUILD_PATH" >builds-dir-after.txt && \
    mv "./nodenv/versions/$(cat .node-version)" './nodenv/versions/default' && \
    rm -rf "./nodenv/versions/default/share" "./nodenv/versions/default/include" && \
    strip --strip-all './nodenv/versions/default/bin/node' && \
    printf 'Time 2:\n' >>time.txt && \
    ( time chronic nodenv install --compile --keep --verbose "$(cat .node-version)" 2>&1 ) 2>>time.txt && \
    find "$NODE_BUILD_CACHE_PATH" >downloads-dir-after2.txt && \
    find "$NODE_BUILD_BUILD_PATH" >builds-dir-after2.txt && \
    mv "./nodenv/versions/$(cat .node-version)" './nodenv/versions/default2' && \
    rm -rf "./nodenv/versions/default2/share" "./nodenv/versions/default2/include" && \
    strip --strip-all './nodenv/versions/default2/bin/node' && \
    printf 'Time 3:\n' >>time.txt && \
    ( time chronic nodenv install --keep --verbose "$(cat .node-version)" 2>&1 ) 2>>time.txt && \
    find "$NODE_BUILD_CACHE_PATH" >downloads-dir-after3.txt && \
    find "$NODE_BUILD_BUILD_PATH" >builds-dir-after3.txt && \
    mv "./nodenv/versions/$(cat .node-version)" './nodenv/versions/default3' && \
    rm -rf "./nodenv/versions/default2/share" "./nodenv/versions/default3/include" && \
    strip --strip-all './nodenv/versions/default3/bin/node'

# TODO: Optimize and minify /app/nodenv/versions/default/lib/node_modules
# TODO: Minify files /app/nodenv/versions/default/bin/{corepack,npm,npx}

FROM debian:12.7-slim AS nodejs-build--final
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        moreutils >/dev/null && \
    if [ "$(dpkg --print-architecture)" = armel ]; then \
        dpkg --add-architecture armhf && \
        apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
            libatomic1:armhf libc6:armhf libstdc++6:armhf >/dev/null && \
    true; elif [ "$(dpkg --print-architecture)" = armhf ]; then \
        DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
            libatomic1 >/dev/null && \
    true; fi && \
    rm -rf /var/lib/apt/lists/*
COPY --from=nodejs--build3 /app/nodenv/versions/default/ ./.node/
ENV PATH="/app/.node/bin:$PATH"
# Validate installation
RUN chronic node --version && \
    chronic npm --version

# Python ##

# Ruby ##

### Main CLI ###

FROM --platform=$BUILDPLATFORM node:22.9.0-slim AS cli--build
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        moreutils \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY cli/package.json cli/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    NODE_OPTIONS=--dns-result-order=ipv4first npm ci --unsafe-perm --no-progress --no-audit --no-fund --loglevel=error && \
    chronic npx modclean --patterns default:safe --run --error-halt --no-progress
COPY cli/tsconfig.json ./
COPY cli/rollup.config.js ./
COPY cli/src/ ./src/
RUN npm run --silent build && \
    npm prune --production --silent --no-progress --no-audit
COPY docker-utils/prune-dependencies/prune-npm.sh docker-utils/prune-dependencies/.common.sh /utils/
RUN sh /utils/prune-npm.sh

FROM debian:12.7-slim AS cli--final
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        moreutils nodejs npm \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=cli--build /app/node_modules ./node_modules
COPY --from=cli--build /app/package.json ./package.json
COPY --from=cli--build /app/dist/ ./dist/
COPY docker-utils/sanity-checks/check-minifiers-custom.sh /utils/check-minifiers-custom.sh
RUN chronic sh /utils/check-minifiers-custom.sh

### 3rd party minifiers ###

# NodeJS #

FROM --platform=$BUILDPLATFORM node:22.9.0-slim AS minifiers-nodejs--build1
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        moreutils \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY minifiers/package.json minifiers/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    NODE_OPTIONS=--dns-result-order=ipv4first npm ci --unsafe-perm --no-progress --no-audit --no-fund --loglevel=error && \
    chronic npx modclean --patterns default:safe --run --error-halt --no-progress && \
    npm prune --production --silent --no-progress --no-audit

FROM --platform=$BUILDPLATFORM debian:12.7-slim AS minifiers-nodejs--build2
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        moreutils nodejs inotify-tools psmisc \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=minifiers-nodejs--build1 /app/node_modules/ ./node_modules/
COPY --from=minifiers-nodejs--build1 /app/package.json ./package.json
COPY docker-utils/sanity-checks/check-minifiers-nodejs.sh /utils/
ENV PATH="/app/node_modules/.bin:$PATH"
# TODO: Reenable
# RUN touch /usage-list.txt && \
#     inotifywait --daemon --recursive --event access /app/node_modules --outfile /usage-list.txt --format '%w%f' && \
#     chronic sh /utils/check-minifiers-nodejs.sh && \
#     killall inotifywait
# COPY docker-utils/prune-dependencies/prune-inotifylist.sh /utils/prune-inotifylist.sh
# RUN sh /utils/prune-inotifylist.sh ./node_modules /usage-list.txt

FROM debian:12.7-slim AS minifiers-nodejs--final
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        moreutils nodejs \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=minifiers-nodejs--build2 /app/node_modules ./node_modules/
COPY --from=minifiers-nodejs--build2 /app/package.json ./package.json
COPY docker-utils/sanity-checks/check-minifiers-nodejs.sh /utils/
ENV PATH="/app/node_modules/.bin:$PATH"
RUN chronic sh /utils/check-minifiers-nodejs.sh

# Python #

FROM --platform=$BUILDPLATFORM debian:12.7-slim AS minifiers-python--build1
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        jq moreutils python3 python3-pip \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY minifiers/requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install --requirement requirements.txt --target "$PWD/python-vendor" --quiet && \
    find /app/python-vendor -type f -iname '*.py[co]' -delete && \
    find /app/python-vendor -type d -iname '__pycache__' -prune -exec rm -rf {} \;

FROM --platform=$BUILDPLATFORM debian:12.7-slim AS minifiers-python--build2
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        jq moreutils python3 inotify-tools psmisc \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=minifiers-python--build1 /app/python-vendor/ ./python-vendor/
COPY docker-utils/sanity-checks/check-minifiers-python.sh /utils/
ENV PATH="/app/python-vendor/bin:$PATH" \
    PYTHONPATH=/app/python-vendor \
    PYTHONDONTWRITEBYTECODE=1
# TODO: Reenable
# RUN touch /usage-list.txt && \
#     inotifywait --daemon --recursive --event access /app/python-vendor --outfile /usage-list.txt --format '%w%f' && \
#     chronic sh /utils/check-minifiers-python.sh && \
#     killall inotifywait
# COPY docker-utils/prune-dependencies/prune-inotifylist.sh /utils/prune-inotifylist.sh
# RUN sh /utils/prune-inotifylist.sh ./python-vendor /usage-list.txt

FROM debian:12.7-slim AS minifiers-python--final
WORKDIR /app
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        jq moreutils python3 \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/*
COPY --from=minifiers-python--build2 /app/python-vendor ./python-vendor/
COPY docker-utils/sanity-checks/check-minifiers-python.sh /utils/
ENV PATH="/app/python-vendor/bin:$PATH" \
    PYTHONPATH=/app/python-vendor \
    PYTHONDONTWRITEBYTECODE=1
RUN chronic sh /utils/check-minifiers-python.sh

# Pre-Final #
# The purpose of this stage is to be 99% the same as the final stage
# Mainly the apt install scripts should be the same
# But since it's not actually final we can run some sanity-checks, which fo not baloon the size of the output docker image

FROM debian:12.7-slim AS prefinal
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        jq moreutils nodejs python3 \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/* && \
    printf '%s\n%s\n%s\n' '#!/bin/sh' 'set -euf' 'node /app/dist/cli.js $@' >/usr/bin/uniminify && \
    chmod a+x /usr/bin/uniminify
COPY docker-utils/sanity-checks/check-system.sh /utils/
RUN chronic sh /utils/check-system.sh
WORKDIR /app
COPY VERSION.txt ./
COPY --from=cli--final /app/ ./
WORKDIR /app/minifiers
COPY --from=minifiers-nodejs--final /app/ ./
COPY --from=minifiers-python--final /app/ ./

### Final stage ###

FROM debian:12.7-slim
RUN find / -type f -not -path '/proc/*' -not -path '/sys/*' >/filelist.txt 2>/dev/null && \
    apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive DEBCONF_TERSE=yes DEBCONF_NOWARNINGS=yes apt-get install -qq --yes --no-install-recommends \
        nodejs python3 \
        >/dev/null && \
    rm -rf /var/lib/apt/lists/* /var/log/apt /var/cache/apt && \
    find /usr/share/bug /usr/share/doc /var/cache /var/lib/apt /var/log -type f | while read -r file; do \
        if ! grep -- "$file" </filelist.txt >/dev/null; then \
            rm -f "$file" && \
        true; fi && \
    true; done && \
    rm -f /filelist.txt && \
    printf '%s\n%s\n%s\n' '#!/bin/sh' 'set -euf' 'node /app/dist/cli.js $@' >/usr/bin/uniminify && \
    chmod a+x /usr/bin/uniminify && \
    useradd --create-home --no-log-init --shell /bin/sh --user-group --system uniminify
COPY --from=prefinal /app/ /app/
ENV NODE_OPTIONS=--dns-result-order=ipv4first \
    PYTHONDONTWRITEBYTECODE=1
USER uniminify
WORKDIR /project
ENTRYPOINT ["uniminify"]
CMD []
