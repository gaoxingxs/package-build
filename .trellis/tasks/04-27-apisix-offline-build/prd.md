# Build APISIX Offline Packages via GitHub Actions

## Goal

Add a repository-local GitHub Actions workflow that compiles Apache APISIX from source and produces offline-installable artifacts for CentOS 7 compatible systems, with architecture selected by workflow input and APISIX version defaulting to `3.13.0`.

## Requirements

- Build APISIX from source code in GitHub Actions.
- Support `amd64` and `arm64`.
- Let the workflow caller choose `amd64`, `arm64`, or both.
- Default APISIX version to `3.13.0`.
- Build in a CentOS 7 userspace so the resulting binaries stay compatible with CentOS 7 class systems.
- Produce an RPM artifact for offline installation.
- Also produce a non-RPM fallback artifact.
- Ensure the final install on the target host does not need network access for APISIX or Lua/OpenResty dependencies.

## Acceptance Criteria

- [x] A workflow exists under `.github/workflows/` with `workflow_dispatch` inputs for APISIX version and target architecture.
- [x] The workflow produces CentOS 7 oriented artifacts for `amd64` and `arm64`.
- [x] The workflow emits at least one RPM artifact and one tarball artifact.
- [x] The RPM contents include OpenResty, APISIX, and the APISIX Lua dependency tree.
- [x] The repository includes documentation for offline installation and constraints.

## Technical Approach

- Run a CentOS 7 container per target architecture from GitHub Actions.
- Compile OpenResty from source inside that container.
- Download the APISIX GitHub tag source tarball and build it with `make deps` and `make install`.
- Copy the generated `deps` tree into `/usr/local/apisix/deps`, matching the installed CLI runtime expectations.
- Stage the final filesystem, then build an RPM plus a local repository tarball.

## Out of Scope

- Bundling etcd itself.
- Producing distro-specific DEB packages.
- Validating every APISIX plugin against CentOS 7 at build time.
- Building APISIX Dashboard or Ingress Controller.

## Technical Notes

- APISIX upstream documentation states source builds require OpenResty first, then `make deps` and `make install`.
- APISIX upstream installation docs describe both RPM installation and offline RPM folder installation.
- APISIX’s installed CLI expects Lua dependencies under `/usr/local/apisix/deps`.
- `arm64` support depends on the availability of an `arm64v8/centos:7` compatible container image and QEMU on GitHub runners.
