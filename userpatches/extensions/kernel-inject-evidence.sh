#!/usr/bin/env bash

# This hook must live in userpatches/extensions rather than lib.config.
# Armbian initializes its extension manager before it sources lib.config, so a
# hook implementation declared there is invisible to the real packaging path.
function pre_package_kernel_image__kernel_inject_evidence() {
	local kernel_root="${kernel_work_dir:-}"
	local package_root="${package_directory:-}"
	local final_config
	local evidence_parent
	local evidence_dir
	local evidence_id
	local staging
	local baseline_dir
	local baseline_status="unavailable"
	local diff_count=0
	local kbuild_arch
	local kernel_release
	local tcp_commit
	local awg_commit
	local nf_commit
	local armbian_build_commit
	local kernel_source_commit
	local config_sha256

	_kernel_inject_log info "Build evidence" \
		"pre_package_kernel_image hook is running for ${kernel_version_family:-unknown}"
	if [[ -z "${kernel_root}" || ! -d "${kernel_root}" ]]; then
		_kernel_inject_log err "Build evidence" "kernel_work_dir is unavailable during linux-image packaging"
		return 1
	fi
	if [[ -z "${package_root}" || ! -d "${package_root}" ]]; then
		_kernel_inject_log err "Build evidence" "package_directory is unavailable during linux-image packaging"
		return 1
	fi
	final_config="${kernel_root}/.config"
	if [[ ! -s "${final_config}" ]]; then
		_kernel_inject_log err "Build evidence" "final kernel config is missing: ${final_config}"
		return 1
	fi

	tcp_commit="$(_kernel_inject_revision_commit "${kernel_root}/net/ipv4/tcp_brutal/.source-revision")"
	awg_commit="$(_kernel_inject_revision_commit "${kernel_root}/drivers/net/amneziawg/.source-revision")"
	nf_commit="$(_kernel_inject_revision_commit "${kernel_root}/net/netfilter/nf_deaf/.source-revision")"
	if [[ "${tcp_commit}" != "${TCP_BRUTAL_COMMIT}" || \
		"${awg_commit}" != "${AMNEZIAWG_COMMIT}" || \
		"${nf_commit}" != "${NF_DEAF_COMMIT}" ]]; then
		_kernel_inject_log err "Build evidence" \
			"source pins do not match the injected tree (tcp=${tcp_commit:-missing}, awg=${awg_commit:-missing}, nf=${nf_commit:-missing})"
		return 1
	fi

	evidence_id="${kernel_version_family:-}"
	if [[ -z "${evidence_id}" || ! "${evidence_id}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
		_kernel_inject_log err "Build evidence" \
			"unsafe or empty kernel_version_family: ${evidence_id:-<empty>}"
		return 1
	fi
	evidence_parent="${package_root}/usr/lib/armbian-kernel-build"
	mkdir -p "${evidence_parent}"
	staging="$(mktemp -d "${evidence_parent}/.evidence.XXXXXX")"
	evidence_dir="${evidence_parent}/${evidence_id}"
	cp -- "${final_config}" "${staging}/kernel.config"
	if ! _kernel_inject_scan_defined_symbols "${kernel_root}" > "${staging}/defined-symbols.txt" || \
		[[ ! -s "${staging}/defined-symbols.txt" ]]; then
		_kernel_inject_log err "Build evidence" "could not persist the kernel Kconfig symbol inventory"
		rm -rf -- "${staging}"
		return 1
	fi

	kbuild_arch="$(_kernel_inject_kbuild_arch "${KERNEL_SRC_ARCH:-${ARCH:-}}")"
	if [[ -z "${kbuild_arch}" || ! "${kbuild_arch}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		_kernel_inject_log err "Build evidence" "unsafe or empty Kbuild architecture: ${kbuild_arch:-<empty>}"
		rm -rf -- "${staging}"
		return 1
	fi
	baseline_dir="$(mktemp -d "${WORKDIR:-${TMPDIR:-/tmp}}/kernel-inject-defconfig.XXXXXX")"
	if make -s -C "${kernel_root}" O="${baseline_dir}" ARCH="${kbuild_arch}" defconfig \
		> "${staging}/${kbuild_arch}-defconfig-build.log" 2>&1; then
		if [[ -x "${kernel_root}/scripts/diffconfig" ]] && \
			"${kernel_root}/scripts/diffconfig" "${baseline_dir}/.config" "${final_config}" \
				> "${staging}/config-vs-${kbuild_arch}-defconfig.txt"; then
			baseline_status="generated"
			diff_count="$(awk 'NF { count++ } END { print count + 0 }' \
				"${staging}/config-vs-${kbuild_arch}-defconfig.txt")"
		else
			printf 'Unable to run scripts/diffconfig against %s defconfig.\n' "${kbuild_arch}" \
				> "${staging}/config-vs-${kbuild_arch}-defconfig.txt"
		fi
	else
		printf 'Unable to generate a %s defconfig baseline; see %s-defconfig-build.log.\n' \
			"${kbuild_arch}" "${kbuild_arch}" \
			> "${staging}/config-vs-${kbuild_arch}-defconfig.txt"
	fi
	rm -rf -- "${baseline_dir}"

	kernel_release="$(make -s -C "${kernel_root}" ARCH="${kbuild_arch}" kernelrelease 2>/dev/null || true)"
	kernel_release="${kernel_release:-${kernel_version_family:-unknown}}"
	armbian_build_commit="$(git -C "${SRC:-.}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
	kernel_source_commit="$(git -C "${kernel_root}" rev-parse HEAD 2>/dev/null || printf 'unknown')"
	config_sha256="$(sha256sum "${staging}/kernel.config" | awk '{print $1}')"
	{
		printf 'evidence_format=1\n'
		printf 'branch=%s\n' "${BRANCH:-unknown}"
		printf 'board=%s\n' "${BOARD:-unknown}"
		printf 'linuxfamily=%s\n' "${LINUXFAMILY:-unknown}"
		printf 'debian_arch=%s\n' "${ARCH:-unknown}"
		printf 'kbuild_arch=%s\n' "${kbuild_arch}"
		printf 'linuxconfig=%s\n' "${LINUXCONFIG:-unknown}"
		printf 'kernel_major_minor=%s\n' "${KERNEL_MAJOR_MINOR:-unknown}"
		printf 'kernel_release=%s\n' "${kernel_release}"
		printf 'armbian_build_commit=%s\n' "${armbian_build_commit}"
		printf 'kernel_source_commit=%s\n' "${kernel_source_commit}"
		printf 'tcp_brutal_commit=%s\n' "${tcp_commit}"
		printf 'amneziawg_commit=%s\n' "${awg_commit}"
		printf 'nf_deaf_commit=%s\n' "${nf_commit}"
		printf 'config_sha256=%s\n' "${config_sha256}"
		printf 'baseline_status=%s\n' "${baseline_status}"
		printf 'diff_count=%s\n' "${diff_count}"
	} > "${staging}/source-manifest.env"

	rm -rf -- "${evidence_dir}"
	mv -- "${staging}" "${evidence_dir}"
	_kernel_inject_log info "Build evidence" \
		"embedded final config, source pins and ${kbuild_arch} defconfig diff in linux-image (${kernel_release})"
}
