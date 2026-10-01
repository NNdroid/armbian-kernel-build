#!/usr/bin/env bash
# HK1 Box builds run in an isolated arm64 container, never on the target's /boot.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${HK1BOX_KERNEL_SERIES:=6.12}"
: "${HK1BOX_KERNEL_COMMIT:=}"
: "${HK1BOX_CONFIG_COMMIT:=}"
: "${HK1BOX_JOBS:=$(nproc)}"
: "${HK1BOX_PUBLISH:=no}"
: "${HK1BOX_DOCKER_IMAGE:=ubuntu:24.04}"
case "${HK1BOX_KERNEL_SERIES}" in 6.12|6.18) ;; *) echo '[ERROR] HK1BOX_KERNEL_SERIES must be 6.12 or 6.18' >&2; exit 1 ;; esac
[[ "${HK1BOX_JOBS}" =~ ^[1-9][0-9]*$ ]] || { echo '[ERROR] Invalid HK1BOX_JOBS' >&2; exit 1; }
case "${HK1BOX_PUBLISH}" in yes|no) ;; *) echo '[ERROR] HK1BOX_PUBLISH must be yes or no' >&2; exit 1 ;; esac
resolve_commit() {
    local repository="$1" commit="$2"
    if [[ -z "${commit}" ]]; then
        commit="$(git ls-remote --exit-code "${repository}" refs/heads/main | awk '{print $1}')"
    fi
    [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo '[ERROR] Expected a full source/config SHA' >&2; return 1; }
    printf '%s\n' "${commit}"
}
HK1BOX_KERNEL_COMMIT="$(resolve_commit "https://github.com/ophub/linux-${HK1BOX_KERNEL_SERIES}.y.git" "${HK1BOX_KERNEL_COMMIT}")"
HK1BOX_CONFIG_COMMIT="$(resolve_commit https://github.com/ophub/kernel.git "${HK1BOX_CONFIG_COMMIT}")"
echo "[INFO] HK1 Box: series=${HK1BOX_KERNEL_SERIES}, source=${HK1BOX_KERNEL_COMMIT}, config=${HK1BOX_CONFIG_COMMIT}"
mkdir -p "${repo}/build/output"
work="$(mktemp -d "${repo}/build/hk1box-work.XXXXXX")"
echo "[INFO] Build work directory: ${work} (retained for diagnosis)"
docker pull --platform linux/arm64 "${HK1BOX_DOCKER_IMAGE}"
image_id="$(docker image inspect --format '{{.Id}}' "${HK1BOX_DOCKER_IMAGE}")"
docker run --rm --platform linux/arm64 \
    --mount "type=bind,src=${repo},dst=/repo,readonly" \
    --mount "type=bind,src=${work},dst=/builder" \
    --mount "type=bind,src=${repo}/build/output,dst=/output" \
    --env "HK1BOX_KERNEL_SERIES=${HK1BOX_KERNEL_SERIES}" \
    --env "HK1BOX_KERNEL_COMMIT=${HK1BOX_KERNEL_COMMIT}" \
    --env "HK1BOX_CONFIG_COMMIT=${HK1BOX_CONFIG_COMMIT}" \
    --env "HK1BOX_JOBS=${HK1BOX_JOBS}" \
    --env "HK1BOX_IMAGE_ID=${image_id}" \
    --env "BUILD_REPOSITORY_COMMIT=$(git -C "${repo}" rev-parse HEAD)" \
    "${image_id}" bash /repo/scripts/hk1box_kernel.sh

# The worker emits this only after validating every packaged component.
release="$(cat "${work}/kernel-release")"
[[ "${release}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-hk1box$ ]] || { echo '[ERROR] Invalid packaged kernel release' >&2; exit 1; }
artifact="${repo}/build/output/hk1box/${release}.tar.gz"
notes="${repo}/build/output/release-metadata/hk1box/build-summary.md"
[[ -s "${artifact}" && -s "${notes}" ]] || { echo '[ERROR] Missing completed HK1 Box artifacts' >&2; exit 1; }
echo "[INFO] HK1 Box installation bundle: ${artifact}"
if [[ "${HK1BOX_PUBLISH}" == yes ]]; then
    command -v gh >/dev/null || { echo '[ERROR] Install gh to publish' >&2; exit 1; }
    tag="hk1box-${release}"
    # Fail rather than silently replace an existing custom kernel release.
    gh release create "${tag}" "${artifact}" "${artifact}.sha256" \
        "${repo}/build/output/release-metadata/hk1box/"hk1box-* \
        --target "${GITHUB_SHA:-$(git -C "${repo}" rev-parse HEAD)}" \
        --title "HK1 Box ${release}" --notes-file "${notes}"
fi
