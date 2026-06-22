# =============================================================================
# 基于 CentOS 7 编译 PostgreSQL（glibc 2.17 兼容）+ 精选扩展
# 兼容: CentOS 7+, Ubuntu 18.04+, Debian 10+, Amazon Linux 2, RHEL 7+ 等
# =============================================================================
FROM centos:7

# ---------- 可调版本参数 ----------
ARG PG_VERSION=17.5
ARG PG_CRON_VERSION=1.6.4
ARG PGVECTOR_VERSION=0.8.0

# ---------- 1. 切换到 vault.centos.org（CentOS 7 已 EOL，官方源已下线）----------
RUN set -eux; \
    sed -i 's|^mirrorlist=|#mirrorlist=|g'                       /etc/yum.repos.d/CentOS-*.repo; \
    sed -i 's|^#\?baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo; \
    yum clean all; \
    yum makecache fast

# ---------- 2. 安装 SCL 源 + devtoolset-11（GCC 11）+ 构建依赖 ----------
# centos-release-scl 装的 SCLo 仓库默认指向 mirrorlist.centos.org（已下线），
# 这里直接用 printf 覆写为 vault 直链，避免 sed 匹配脆弱的问题。
#
# 路径分发：
#   x86_64  → vault.centos.org/centos/7/sclo/x86_64/...
#   aarch64 → vault.centos.org/altarch/7/sclo/aarch64/...   ← non-x86 在 altarch 树下
RUN set -eux; \
    yum install -y centos-release-scl; \
    ARCH="$(uname -m)"; \
    if [ "$ARCH" = "x86_64" ]; then \
      SCLO_BASE="https://vault.centos.org/centos/7/sclo/${ARCH}"; \
    else \
      SCLO_BASE="https://vault.centos.org/altarch/7/sclo/${ARCH}"; \
    fi; \
    printf '%s\n' \
      '[centos-sclo-sclo]' \
      'name=CentOS-7 - SCLo sclo (vault)' \
      "baseurl=${SCLO_BASE}/sclo/" \
      'gpgcheck=0' \
      'enabled=1' \
      > /etc/yum.repos.d/CentOS-SCLo-scl.repo; \
    printf '%s\n' \
      '[centos-sclo-rh]' \
      'name=CentOS-7 - SCLo rh (vault)' \
      "baseurl=${SCLO_BASE}/rh/" \
      'gpgcheck=0' \
      'enabled=1' \
      > /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo; \
    yum clean all; \
    yum makecache fast; \
    yum install -y \
        devtoolset-11-gcc \
        devtoolset-11-gcc-c++ \
        devtoolset-11-binutils \
        glibc-devel \
        glibc-headers \
        make \
        git \
        wget \
        tar \
        bzip2 \
        perl \
        perl-IPC-Cmd \
        perl-Data-Dumper \
        bison \
        flex \
        readline-devel \
        zlib-devel \
        openssl-devel \
        libxml2-devel \
        libxslt-devel \
        pam-devel \
        krb5-devel \
        openldap-devel \
        python3 \
        python3-devel \
        libuuid-devel; \
    yum clean all; \
    rm -rf /var/cache/yum

# 让 devtoolset-11 的 gcc/g++ 默认生效
ENV PATH=/opt/rh/devtoolset-11/root/usr/bin:/usr/local/pgsql/bin:/usr/local/bin:/usr/bin:/bin \
    LD_LIBRARY_PATH=/opt/rh/devtoolset-11/root/usr/lib64:/usr/local/pgsql/lib:/usr/local/lib \
    CC=/opt/rh/devtoolset-11/root/usr/bin/gcc \
    CXX=/opt/rh/devtoolset-11/root/usr/bin/g++

# 暂存目录：所有编译产物通过 DESTDIR 收集到此处，便于打包
ENV STAGE=/stage/postgresql-${PG_VERSION}
RUN mkdir -p "${STAGE}"

WORKDIR /build

# ---------- 3. 编译 PostgreSQL ----------
RUN set -eux; \
    wget -q "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"; \
    tar xf "postgresql-${PG_VERSION}.tar.bz2"; \
    cd "postgresql-${PG_VERSION}"; \
    # CentOS 7 的 libicu 太旧 (50.x)，PG 17 要求 ICU 54+，故关闭 ICU（使用 libc 排序）
    ./configure \
        --prefix=/usr/local/pgsql \
        --without-icu \
        --with-openssl \
        --with-libxml \
        --with-libxslt \
        --with-pam \
        --with-ldap \
        --with-python \
        --with-uuid=e2fs || { cat config.log; exit 1; }; \
    make -j"$(nproc)" world-bin; \
    # 安装到 STAGE（不污染镜像内 /usr/local），同时也在镜像内安装一份给后续扩展编译使用
    make install-world-bin DESTDIR="${STAGE}"; \
    make install-world-bin; \
    # 安装所有 contrib 扩展（pg_stat_statements / pg_trgm / hstore / btree_gin / btree_gist / postgres_fdw 等）
    cd contrib; \
    make -j"$(nproc)"; \
    make install DESTDIR="${STAGE}"; \
    make install

ENV PG_CONFIG=/usr/local/pgsql/bin/pg_config

# ---------- 4. 编译 pg_cron ----------
RUN set -eux; \
    cd /build; \
    wget -q "https://github.com/citusdata/pg_cron/archive/refs/tags/v${PG_CRON_VERSION}.tar.gz" -O pg_cron.tar.gz; \
    tar xf pg_cron.tar.gz; \
    cd "pg_cron-${PG_CRON_VERSION}"; \
    make PG_CONFIG="${PG_CONFIG}" -j"$(nproc)"; \
    make PG_CONFIG="${PG_CONFIG}" install DESTDIR="${STAGE}"; \
    make PG_CONFIG="${PG_CONFIG}" install

# ---------- 5. 编译 pgvector ----------
RUN set -eux; \
    cd /build; \
    wget -q "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" -O pgvector.tar.gz; \
    tar xf pgvector.tar.gz; \
    cd "pgvector-${PGVECTOR_VERSION}"; \
    make PG_CONFIG="${PG_CONFIG}" OPTFLAGS="" -j"$(nproc)"; \
    make PG_CONFIG="${PG_CONFIG}" install DESTDIR="${STAGE}"; \
    make PG_CONFIG="${PG_CONFIG}" install

# ---------- 6. 打包产物到 /build-output ----------
# 工作流里用 `tar -xzf ... -C / --strip-components=1` 解压，
# 因此 tar 的顶层目录是 postgresql-${PG_VERSION}，剥掉后内容落到 /usr/local/pgsql/...
RUN set -eux; \
    mkdir -p /build-output; \
    # 生成扩展清单（基于 .control 文件）
    ls "${STAGE}/usr/local/pgsql/share/extension/"*.control \
        | xargs -n1 basename \
        | sed 's/\.control$//' \
        | sort -u > /build-output/EXTENSIONS.txt; \
    echo "=== 已安装扩展清单 ==="; \
    cat /build-output/EXTENSIONS.txt; \
    # 重命名 STAGE 的顶层目录后打包（按容器架构生成文件名：x86_64 / aarch64）
    ARCH="$(uname -m)"; \
    tar -czf "/build-output/postgresql-${PG_VERSION}-glibc217-${ARCH}.tar.gz" \
        -C /stage "postgresql-${PG_VERSION}"; \
    ls -lh /build-output/

# 默认入口（仅用于人工进入容器查看）
WORKDIR /build-output
CMD ["/bin/bash"]
