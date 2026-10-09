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

# ---------- 3.5 生成默认配置（整文件写出，不再 sed 改上游模板）----------
# 全局配置在安装目录 conf/nginx.conf；业务站点配置由服务器本地 /etc/nginx/conf.d 导入；隐藏版本号
# 关键: log_format main 必须定义在 include /etc/nginx/conf.d/*.conf 之前，
#       否则 conf.d 里的站点写 access_log ... main 会在 nginx -t 时报 unknown log format
cat > "$PREFIX/conf/nginx.conf" <<'NGINX_CONF'
# nginx 全局配置（由 build-offline.sh 生成）
# 业务站点配置请放到 /etc/nginx/conf.d/*.conf，不要直接改本文件
worker_processes  auto;

error_log  logs/error.log warn;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    # 隐藏 nginx 版本号
    server_tokens off;

    # 日志格式，供 /etc/nginx/conf.d 下的站点引用（必须在下面的 include 之前定义）
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  logs/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    keepalive_timeout  65;

    # 包内默认站点（欢迎页）。nginx 规则: 同端口第一个 server 块即默认 server，
    # 因此它优先于下面 include 进来的站点；conf.d 里的站点若要接管 80 端口，
    # 在自己的 listen 上加 default_server 即可（例如 listen 80 default_server;）。
    server {
        listen       80;
        server_name  localhost;

        location / {
            root   html;
            index  index.html index.htm;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   html;
        }
    }

    # 业务站点配置目录（服务器本地维护）
    include /etc/nginx/conf.d/*.conf;
}
NGINX_CONF

# 构建期自检: 配置解析不过就不许进包（容器内 /etc/nginx/conf.d 不存在会让 glob include 报错，先建空目录）
mkdir -p /etc/nginx/conf.d
log "校验生成的 nginx.conf"
"$PREFIX/sbin/nginx" -t

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

# 安装后自检: 配置解析不过就不要报告"安装完成"，避免"装好了却起不来"的假象
if ! "$PREFIX/sbin/nginx" -t; then
  echo "错误: nginx -t 校验失败，请检查 $PREFIX/conf/nginx.conf 与 /etc/nginx/conf.d/*.conf" >&2
  exit 1
fi

cp nginx.service /etc/systemd/system/nginx.service
systemctl daemon-reload
systemctl enable nginx >/dev/null 2>&1

echo "安装完成: $PREFIX (nginx -t 已通过)"
echo "启动: systemctl start nginx"
echo "业务站点: 放到 /etc/nginx/conf.d/*.conf（接管 80 端口时写 listen 80 default_server;）"
echo "日志: $PREFIX/logs/{access,error}.log，格式为 log_format main"
EOF
chmod +x "$STAGE/install.sh"

# ---------- 6. 压缩 ----------
mkdir -p "$OUT_DIR"
tar czf "$OUT_DIR/$PKG_NAME.tar.gz" -C /tmp "$PKG_NAME"
log "产物: $OUT_DIR/$PKG_NAME.tar.gz"
ls -lh "$OUT_DIR/"
