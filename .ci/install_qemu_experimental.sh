#!/bin/bash
#
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

cidir=$(dirname "$0")
source "${cidir}/lib.sh"
source "${cidir}/../lib/common.bash"
source /etc/os-release || source /usr/lib/os-release

KATA_DEV_MODE="${KATA_DEV_MODE:-}"

CURRENT_QEMU_TAG=$(get_version "assets.hypervisor.qemu-experimental.tag")
QEMU_TAR="kata-static-qemu-virtiofsd.tar.gz"
arch=$("${cidir}"/kata-arch.sh -d)
QEMU_PATH="${DESTDIR:-}/opt/kata/bin/qemu-virtiofs-system-x86_64"
VIRTIOFS_PATH="${DESTDIR:-}/opt/kata/bin/virtiofsd"
bindir="${DESTDIR:-}/usr/bin"
qemu_experimental_latest_build_url="${jenkins_url}/job/qemu-experimental-nightly-$(uname -m)/${cached_artifacts_path}"

uncompress_experimental_qemu() {
	local qemu_tar_location="$1"
	[ -n "$qemu_tar_location" ] || die "provide the location of the QEMU compressed file"
	sudo tar -xvf "${qemu_tar_location}" -C ${DESTDIR:-/}
}

install_cached_qemu_experimental() {
	info "Installing cached experimental QEMU"
	curl -fL --progress-bar "${qemu_experimental_latest_build_url}/${QEMU_TAR}" -o "${QEMU_TAR}" || return 1
	curl -fsOL "${qemu_experimental_latest_build_url}/sha256sum-${QEMU_TAR}" || return 1
	sha256sum -c "sha256sum-${QEMU_TAR}" || return 1
	uncompress_experimental_qemu "${QEMU_TAR}"
	sudo -E ln -sf "${QEMU_PATH}" $bindir
	sudo -E ln -sf "${VIRTIOFS_PATH}" $bindir
	sudo mkdir -p "${KATA_TESTS_CACHEDIR}"
	sudo mv "${QEMU_TAR}" "${KATA_TESTS_CACHEDIR}"
}

build_and_install_static_experimental_qemu() {
	build_experimental_qemu
	uncompress_experimental_qemu "${KATA_TESTS_CACHEDIR}/${QEMU_TAR}"
	sudo -E ln -sf "${QEMU_PATH}" $bindir
	sudo -E ln -sf "${VIRTIOFS_PATH}" $bindir
}

build_experimental_qemu() {
	mkdir -p "${GOPATH}/src"
	go get -d "$packaging_repo" || true
	"${GOPATH}/src/${packaging_repo}/static-build/qemu-virtiofs/build-static-qemu-virtiofs.sh"
	sudo mkdir -p "${KATA_TESTS_CACHEDIR}"
	sudo mv "${QEMU_TAR}" "${KATA_TESTS_CACHEDIR}"
}

main() {
	if [ "$arch" != "x86_64" ]; then
		die "Unsupported architecture: $arch"
	fi
	cached_qemu_experimental_version=$(curl -sfL "${qemu_experimental_latest_build_url}/latest") || cached_qemu_experimental_version="none"
	info "Cached qemu experimental version: $cached_qemu_experimental_version"
	info "Current qemu experimental version: $CURRENT_QEMU_TAG"
	if [ "$cached_qemu_experimental_version" == "$CURRENT_QEMU_TAG" ]; then
		install_cached_qemu_experimental || build_and_install_static_experimental_qemu
	else
		build_and_install_static_experimental_qemu
	fi
}

main
