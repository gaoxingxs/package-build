#!/usr/bin/env bash

set -euo pipefail

APISIX_VERSION="${APISIX_VERSION:-3.13.0}"
OPENRESTY_VERSION="${OPENRESTY_VERSION:-1.21.4.3}"
LUAROCKS_VERSION="${LUAROCKS_VERSION:-3.11.1}"
RPM_RELEASE="${RPM_RELEASE:-1}"
PACKAGE_ARCH="${PACKAGE_ARCH:-amd64}"
RPM_ARCH="${RPM_ARCH:-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-/work/output/apisix/${PACKAGE_ARCH}}"
PACKAGE_NAME="${PACKAGE_NAME:-apisix-offline}"
WORK_ROOT="${WORK_ROOT:-/tmp/apisix-offline-build}"
SOURCE_URL_BASE="${SOURCE_URL_BASE:-https://github.com/apache/apisix/archive/refs/tags}"

BUILD_DEPENDENCIES=(
  epel-release
  centos-release-scl
  yum-utils
  sudo
  devtoolset-9
  gcc
  gcc-c++
  make
  curl
  wget
  git
  tar
  unzip
  xz
  patch
  which
  perl
  perl-devel
  perl-ExtUtils-Embed
  openssl-devel
  pcre
  pcre-devel
  zlib-devel
  libyaml-devel
  openldap-devel
  readline-devel
  ncurses-devel
  rpm-build
  rpmdevtools
  createrepo
  cpio
  diffutils
  findutils
  file
)

readonly APISIX_VERSION
readonly OPENRESTY_VERSION
readonly LUAROCKS_VERSION
readonly RPM_RELEASE
readonly PACKAGE_ARCH
readonly RPM_ARCH
readonly OUTPUT_DIR
readonly PACKAGE_NAME
readonly WORK_ROOT
readonly SOURCE_URL_BASE

log() {
  printf '[apisix-build] %s\n' "$*" >&2
}

fail_with_log() {
  local log_file="$1"
  if [[ -f "$log_file" ]]; then
    cat "$log_file"
  fi
  exit 1
}

reset_centos7_repos() {
  log "Switching CentOS 7 repositories to Vault"

  if compgen -G '/etc/yum.repos.d/CentOS-*.repo' >/dev/null; then
    sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS-*.repo
    sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS-*.repo
    sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS-*.repo
  fi

  if compgen -G '/etc/yum.repos.d/CentOS-SCLo-*.repo' >/dev/null; then
    sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/CentOS-SCLo-*.repo
    sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/CentOS-SCLo-*.repo
    sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/CentOS-SCLo-*.repo
  fi

  yum clean all
  yum makecache
}

install_build_dependencies() {
  log "Installing build dependencies"
  yum install -y "${BUILD_DEPENDENCIES[@]}"

  # shellcheck disable=SC1091
  if [[ -f /opt/rh/devtoolset-9/enable ]]; then
    source /opt/rh/devtoolset-9/enable
  else
    gcc --version || true
  fi
}

write_build_dependency_manifest() {
  local manifest_path="${OUTPUT_DIR}/build-dependencies.txt"

  mkdir -p "${OUTPUT_DIR}"
  printf '%s\n' "${BUILD_DEPENDENCIES[@]}" >"${manifest_path}"
}

prepare_workspace() {
  log "Preparing workspace at ${WORK_ROOT}"
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORK_ROOT}" "${OUTPUT_DIR}"
}

build_openresty() {
  local archive="${WORK_ROOT}/openresty-${OPENRESTY_VERSION}.tar.gz"
  local source_dir="${WORK_ROOT}/openresty-${OPENRESTY_VERSION}"
  local build_log="${WORK_ROOT}/openresty-build.log"

  log "Building OpenResty ${OPENRESTY_VERSION}"
  curl -fsSL "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" -o "${archive}"
  tar -xzf "${archive}" -C "${WORK_ROOT}"

  pushd "${source_dir}" >/dev/null
  ./configure \
    --prefix=/usr/local/openresty \
    --with-pcre-jit \
    --with-http_ssl_module \
    --with-http_v2_module \
    >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  make -j"$(nproc)" >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  make install >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  popd >/dev/null

  export PATH="/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:${PATH}"

  # Newer APISIX Makefiles infer OpenSSL from the OpenResty prefix.
  mkdir -p /usr/local/openresty/openssl
  ln -sfn /usr/include /usr/local/openresty/openssl/include
  ln -sfn /usr/lib64 /usr/local/openresty/openssl/lib
}

install_luarocks_from_source() {
  local archive="${WORK_ROOT}/luarocks-${LUAROCKS_VERSION}.tar.gz"
  local source_dir="${WORK_ROOT}/luarocks-${LUAROCKS_VERSION}"
  local build_log="${WORK_ROOT}/luarocks-build.log"

  log "Installing LuaRocks ${LUAROCKS_VERSION} from source"
  curl -fsSL "https://luarocks.org/releases/luarocks-${LUAROCKS_VERSION}.tar.gz" -o "${archive}"
  tar -xzf "${archive}" -C "${WORK_ROOT}"

  pushd "${source_dir}" >/dev/null
  ./configure \
    --prefix=/usr/local \
    --with-lua=/usr/local/openresty/luajit \
    --with-lua-bin=/usr/local/openresty/luajit/bin \
    --lua-suffix=jit \
    --with-lua-include=/usr/local/openresty/luajit/include/luajit-2.1 \
    >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  make build >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  make install >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  popd >/dev/null
}

download_apisix_source() {
  local archive="${WORK_ROOT}/apisix-${APISIX_VERSION}.tar.gz"
  local extracted_root

  log "Downloading APISIX source ${APISIX_VERSION}"
  curl -fsSL "${SOURCE_URL_BASE}/${APISIX_VERSION}.tar.gz" -o "${archive}"
  tar -xzf "${archive}" -C "${WORK_ROOT}"

  extracted_root="$(tar -tzf "${archive}" | head -n1 | cut -d/ -f1)"
  if [[ -z "${extracted_root}" || ! -d "${WORK_ROOT}/${extracted_root}" ]]; then
    echo "Failed to determine extracted APISIX source directory" >&2
    exit 1
  fi

  printf '%s\n' "${WORK_ROOT}/${extracted_root}"
}

build_apisix() {
  local source_dir="$1"
  local build_log="${WORK_ROOT}/apisix-build.log"

  log "Installing APISIX dependencies and files"
  pushd "${source_dir}" >/dev/null

  if [[ -x ./utils/linux-install-luarocks.sh ]]; then
    ./utils/linux-install-luarocks.sh >"${WORK_ROOT}/luarocks-script.log" 2>&1 || install_luarocks_from_source
  else
    install_luarocks_from_source
  fi

  export PATH="/usr/local/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:${PATH}"
  make deps >"${build_log}" 2>&1 || fail_with_log "${build_log}"
  make install >"${build_log}" 2>&1 || fail_with_log "${build_log}"

  rm -rf /usr/local/apisix/deps
  cp -a "${source_dir}/deps" /usr/local/apisix/deps
  popd >/dev/null
}

write_systemd_unit() {
  log "Writing systemd unit"
  mkdir -p /usr/lib/systemd/system
  cat >/usr/lib/systemd/system/apisix.service <<'EOF'
[Unit]
Description=Apache APISIX
After=network.target
Wants=network.target

[Service]
Type=forking
ExecStartPre=/usr/bin/apisix init
ExecStart=/usr/bin/apisix start
ExecReload=/usr/bin/apisix reload
ExecStop=/usr/bin/apisix quit
PIDFile=/usr/local/apisix/logs/nginx.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

verify_installation() {
  log "Verifying installation"
  /usr/local/openresty/bin/openresty -V
  /usr/bin/apisix help >/dev/null
  file /usr/local/openresty/nginx/sbin/nginx
}

copy_tree() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
}

copy_tree_if_exists() {
  local src="$1"
  local dst="$2"

  if [[ -e "${src}" ]]; then
    copy_tree "${src}" "${dst}"
  fi
}

stage_files() {
  local stage_root="${WORK_ROOT}/stage"

  log "Staging files into ${stage_root}"
  rm -rf "${stage_root}"
  mkdir -p "${stage_root}"

  copy_tree /usr/local/openresty "${stage_root}/usr/local/openresty"
  copy_tree /usr/local/apisix "${stage_root}/usr/local/apisix"
  copy_tree_if_exists /usr/local/share/lua "${stage_root}/usr/local/share/lua"
  copy_tree_if_exists /usr/local/lib/lua "${stage_root}/usr/local/lib/lua"
  copy_tree_if_exists /usr/local/lib64/lua "${stage_root}/usr/local/lib64/lua"
  copy_tree_if_exists /usr/local/lib/luarocks "${stage_root}/usr/local/lib/luarocks"
  copy_tree_if_exists /usr/local/share/lua/5.1/apisix "${stage_root}/usr/local/share/lua/5.1/apisix"
  copy_tree /usr/bin/apisix "${stage_root}/usr/bin/apisix"
  copy_tree /usr/lib/systemd/system/apisix.service "${stage_root}/usr/lib/systemd/system/apisix.service"

  mkdir -p "${stage_root}/usr/share/doc/${PACKAGE_NAME}"
  cat >"${stage_root}/usr/share/doc/${PACKAGE_NAME}/README.offline.txt" <<EOF
Offline Apache APISIX package
=============================

Version: ${APISIX_VERSION}
Architecture: ${RPM_ARCH}
OpenResty: ${OPENRESTY_VERSION}

This package contains:
- /usr/local/openresty
- /usr/local/apisix
- /usr/local/share/lua/5.1/apisix
- /usr/bin/apisix
- /usr/lib/systemd/system/apisix.service

Notes:
- etcd is not bundled. Use external etcd or APISIX standalone mode.
- The package is built inside a CentOS 7 userspace to keep glibc compatibility at the CentOS 7 level.
- Install is fully offline after you copy the artifacts to the target host.
EOF

  printf '%s\n' "${stage_root}"
}

collect_runtime_reports() {
  local report_dir="${OUTPUT_DIR}/reports"

  log "Collecting runtime and RPM dependency reports"
  mkdir -p "${report_dir}"

  {
    echo '# openresty'
    ldd /usr/local/openresty/nginx/sbin/nginx || true
    echo
    echo '# luajit'
    ldd /usr/local/openresty/luajit/bin/luajit || true
  } >"${report_dir}/linked-libraries.txt"

  /usr/local/openresty/bin/openresty -V >"${report_dir}/openresty-version.txt" 2>&1 || true
  /usr/bin/apisix version >"${report_dir}/apisix-version.txt" 2>&1 || true
}

create_file_manifest() {
  local stage_root="$1"
  local manifest="$2"

  {
    (
      cd "${stage_root}"
      find . -mindepth 1 -type d | LC_ALL=C sort | sed 's#^\./#%dir /#'
    )
    (
      cd "${stage_root}"
      find . -type f -o -type l | LC_ALL=C sort | sed 's#^\./#/#'
    )
  } >"${manifest}"
}

build_rpm() {
  local stage_root="$1"
  local rpm_topdir="${WORK_ROOT}/rpmbuild"
  local archive_name="${PACKAGE_NAME}-${APISIX_VERSION}-${RPM_RELEASE}.${RPM_ARCH}.tar.gz"
  local archive_path="${rpm_topdir}/SOURCES/${archive_name}"
  local manifest_path="${rpm_topdir}/SOURCES/${PACKAGE_NAME}.files"
  local spec_path="${rpm_topdir}/SPECS/${PACKAGE_NAME}.spec"

  log "Building RPM package"
  rm -rf "${rpm_topdir}"
  mkdir -p "${rpm_topdir}/BUILD" "${rpm_topdir}/BUILDROOT" "${rpm_topdir}/RPMS" "${rpm_topdir}/SOURCES" "${rpm_topdir}/SPECS" "${rpm_topdir}/SRPMS"

  tar -C "${stage_root}" -czf "${archive_path}" .
  create_file_manifest "${stage_root}" "${manifest_path}"

  cat >"${spec_path}" <<EOF
Name: ${PACKAGE_NAME}
Version: ${APISIX_VERSION}
Release: ${RPM_RELEASE}%{?dist}
Summary: Self-contained offline Apache APISIX build for CentOS 7 compatible systems
License: Apache-2.0
URL: https://github.com/apache/apisix
BuildArch: ${RPM_ARCH}
Source0: ${archive_name}
Source1: ${PACKAGE_NAME}.files

%description
Self-contained Apache APISIX package built from source inside a CentOS 7 userspace.
It bundles OpenResty, APISIX, and Lua dependencies for offline installation.

%prep
%setup -q -c -T
tar -xzf %{SOURCE0}

%build

%install
mkdir -p %{buildroot}
cp -a . %{buildroot}

%post
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

%preun
if [ \$1 -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now apisix >/dev/null 2>&1 || true
fi

%postun
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

%files -f %{SOURCE1}
%defattr(-,root,root,-)
EOF

  rpmbuild -bb "${spec_path}" --define "_topdir ${rpm_topdir}"
  find "${rpm_topdir}/RPMS" -type f -name '*.rpm' -print -quit
}

write_repo_install_script() {
  local repo_dir="$1"
  local rpm_file="$2"
  local rpm_base
  rpm_base="$(basename "${rpm_file}")"

  cat >"${repo_dir}/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
RPM_PATH="\${SCRIPT_DIR}/${rpm_base}"

if command -v yum >/dev/null 2>&1; then
  yum install -y "\${RPM_PATH}"
else
  rpm -Uvh "\${RPM_PATH}"
fi
EOF
  chmod +x "${repo_dir}/install.sh"
}

create_artifacts() {
  local stage_root="$1"
  local rpm_path="$2"
  local repo_dir="${OUTPUT_DIR}/repo"
  local tarball_name="${PACKAGE_NAME}-${APISIX_VERSION}-el7-${RPM_ARCH}.tar.gz"
  local repo_bundle_name="${PACKAGE_NAME}-${APISIX_VERSION}-el7-${RPM_ARCH}-repo.tar.gz"
  local sha_file="${OUTPUT_DIR}/SHA256SUMS"
  local install_guide="${OUTPUT_DIR}/INSTALL.txt"

  log "Creating artifact bundles under ${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}/rpm" "${repo_dir}"

  cp -a "${rpm_path}" "${OUTPUT_DIR}/rpm/"
  cp -a "${rpm_path}" "${repo_dir}/"
  write_repo_install_script "${repo_dir}" "${rpm_path}"
  createrepo "${repo_dir}" >/dev/null

  rpm -qpR "${rpm_path}" >"${OUTPUT_DIR}/reports/rpm-requires.txt"

  tar -C "${stage_root}" -czf "${OUTPUT_DIR}/${tarball_name}" .
  tar -C "${OUTPUT_DIR}" -czf "${OUTPUT_DIR}/${repo_bundle_name}" repo

  cat >"${install_guide}" <<EOF
Offline Apache APISIX install guide
===================================

Artifacts:
- rpm/$(basename "${rpm_path}")
- ${tarball_name}
- ${repo_bundle_name}

Recommended RPM install on CentOS 7 / RHEL 7 compatible hosts:
  tar -xzf ${repo_bundle_name}
  cd repo
  ./install.sh

Direct RPM install:
  yum install -y ./rpm/$(basename "${rpm_path}")
  # or: rpm -Uvh ./rpm/$(basename "${rpm_path}")

Tarball install:
  tar -C / -xzf ${tarball_name}
  systemctl daemon-reload
  systemctl enable --now apisix

Notes:
- Built inside a CentOS 7 userspace for glibc 2.17 compatibility.
- Target host still needs base system runtime libraries already present.
- etcd is not bundled. Use an external etcd cluster or standalone mode.
- Runtime linkage reports are in reports/linked-libraries.txt and reports/rpm-requires.txt.
EOF

  cat >"${OUTPUT_DIR}/build-info.txt" <<EOF
APISIX_VERSION=${APISIX_VERSION}
OPENRESTY_VERSION=${OPENRESTY_VERSION}
LUAROCKS_VERSION=${LUAROCKS_VERSION}
RPM_RELEASE=${RPM_RELEASE}
PACKAGE_ARCH=${PACKAGE_ARCH}
RPM_ARCH=${RPM_ARCH}
EOF

  (
    cd "${OUTPUT_DIR}"
    sha256sum \
      "rpm/$(basename "${rpm_path}")" \
      "${tarball_name}" \
      "${repo_bundle_name}" \
      "INSTALL.txt" \
      "build-info.txt" \
      "build-dependencies.txt" \
      "reports/linked-libraries.txt" \
      "reports/openresty-version.txt" \
      "reports/apisix-version.txt" \
      "reports/rpm-requires.txt" \
      >"${sha_file}"
  )
}

main() {
  local apisix_source_dir
  local stage_root
  local rpm_path

  reset_centos7_repos
  install_build_dependencies
  prepare_workspace
  write_build_dependency_manifest
  build_openresty
  apisix_source_dir="$(download_apisix_source)"
  build_apisix "${apisix_source_dir}"
  write_systemd_unit
  verify_installation
  stage_root="$(stage_files)"
  collect_runtime_reports
  rpm_path="$(build_rpm "${stage_root}")"
  create_artifacts "${stage_root}" "${rpm_path}"

  log "Artifacts created successfully"
  find "${OUTPUT_DIR}" -maxdepth 2 -type f | LC_ALL=C sort
}

main "$@"
