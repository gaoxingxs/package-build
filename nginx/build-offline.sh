#!/usr/bin/env bash
# Nginx 离线构建脚本（在容器内运行，CentOS 7 / Anolis 8 等 yum 系通用）
# 用法: bash build-offline.sh [nginx版本，留空=最新稳定版] [输出目录]
# 产物: nginx-<版本>-linux-<架构>-glibc<版本>.tar.gz
#       包含: nginx 安装目录(prefix)、打包的动态库、systemd 服务文件、install.sh
set -euo pipefail

NGINX_VERSION="${1:-}"
OUT_DIR="${2:-/dist/output}"
PREFIX=/usr/local/nginx

ARCH="$(uname -m)"
GLIBC_VER="$(ldd --version | awk 'NR==1{print $NF}')"

log() { echo "[nginx-build] $*"; }

# ---------- 1. 构建依赖 ----------
if grep -q 'VERSION_ID="7"' /etc/os-release 2>/dev/null; then
  log "检测到 CentOS 7，切换 yum 源到 vault"
  sed -i -e 's|^mirrorlist=|#mirrorlist=|g' \
         -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
         /etc/yum.repos.d/*.repo
fi
if command -v dnf >/dev/null 2>&1; then PKG=dnf; else PKG=yum; fi
log "安装构建依赖 ($PKG)"
$PKG install -y -q gcc make pcre2-devel pcre-devel zlib-devel openssl-devel curl tar gzip

# ---------- 2. 确定 nginx 版本（留空 = 最新稳定版）----------
if [ -z "$NGINX_VERSION" ]; then
  log "未指定版本，获取 nginx.org 最新稳定版"
  # 下载页第一个 tar.gz 是 Mainline，第二个是 Stable
  mapfile -t VERSIONS < <(curl -fsSL https://nginx.org/en/download.html | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | uniq)
  [ "${#VERSIONS[@]}" -ge 2 ] || { log "错误: 版本检测失败"; exit 1; }
  NGINX_VERSION="${VERSIONS[1]#nginx-}"
  NGINX_VERSION="${NGINX_VERSION%.tar.gz}"
fi
log "构建 nginx ${NGINX_VERSION} (${ARCH}, glibc ${GLIBC_VER})"

# ---------- 3. 下载编译 ----------
cd /tmp
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tar.gz
tar xzf nginx.tar.gz
cd "nginx-${NGINX_VERSION}"
./configure \
  --prefix="$PREFIX" \
  --with-threads \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_realip_module \
  --with-http_stub_status_module \
  --with-http_gzip_static_module \
  --with-http_sub_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_realip_module \
  --with-ld-opt="-Wl,-rpath,${PREFIX}/lib"
make -j"$(nproc)"
make install

# ---------- 3.5 按部署约定修改默认配置 ----------
# 全局配置在安装目录 conf/nginx.conf；业务站点配置由服务器本地 /etc/nginx/conf.d 导入；隐藏版本号
sed -i 's|^http {|http {\n    # 隐藏 nginx 版本号\n    server_tokens off;\n\n    # 业务站点配置目录（服务器本地维护）\n    include /etc/nginx/conf.d/*.conf;|' "$PREFIX/conf/nginx.conf"

# ---------- 4. 打包运行时动态库（自包含，rpath 指向 $PREFIX/lib）----------
mkdir -p "$PREFIX/lib"
ldd "$PREFIX/sbin/nginx" | awk '{print $3}' | grep -E '/lib(ssl|crypto|pcre|z)[^/]*\.so' | sort -u | while read -r so; do
  cp -L "$so" "$PREFIX/lib/"
done
strip "$PREFIX/sbin/nginx"

# ---------- 5. 生成 systemd 服务与安装脚本 ----------
PKG_NAME="nginx-${NGINX_VERSION}-linux-${ARCH}-glibc${GLIBC_VER}"
STAGE="/tmp/$PKG_NAME"
mkdir -p "$STAGE"
cp -a "$PREFIX" "$STAGE/nginx"

cat > "$STAGE/nginx.service" <<'EOF'
[Unit]
Description=nginx - high performance web server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/usr/local/nginx/logs/nginx.pid
ExecStartPre=/usr/local/nginx/sbin/nginx -t
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/usr/local/nginx/sbin/nginx -s quit
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat > "$STAGE/install.sh" <<'EOF'
#!/usr/bin/env bash
# nginx 离线安装脚本（root 运行）
set -e
cd "$(dirname "$0")"

PREFIX=/usr/local/nginx
[ "$(id -u)" -eq 0 ] || { echo "错误: 请使用 root 运行"; exit 1; }
if [ -d "$PREFIX" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "错误: $PREFIX 已存在。确认覆盖请: FORCE=1 ./install.sh"
  exit 1
fi

mkdir -p "$PREFIX"
mkdir -p /etc/nginx/conf.d
cp -a nginx/. "$PREFIX/"
cp nginx.service /etc/systemd/system/nginx.service
systemctl daemon-reload
systemctl enable nginx >/dev/null 2>&1

echo "安装完成: $PREFIX"
echo "启动: systemctl start nginx"
echo "默认站点: http://127.0.0.1"
EOF
chmod +x "$STAGE/install.sh"

# ---------- 6. 压缩 ----------
mkdir -p "$OUT_DIR"
tar czf "$OUT_DIR/$PKG_NAME.tar.gz" -C /tmp "$PKG_NAME"
log "产物: $OUT_DIR/$PKG_NAME.tar.gz"
ls -lh "$OUT_DIR/"
