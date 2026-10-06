#!/usr/bin/env bash
# The single orchestration path shared by all registered build targets.
build_main() {
    cd "${BUILD_PROJECT_ROOT}"

    # Installed before the profile is loaded, not after. Loading is where an
    # unsupported branch or a malformed profile fails, which makes it the single
    # most likely place for a run to die -- and with the trap set afterwards
    # those failures produced a bare error line with no failing command, no
    # elapsed time and no replayed context.
    trap 'report_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

    load_build_target

    # Echo the resolved configuration before anything can fail. When a build
    # produces the wrong artifact -- the classic version of this bug -- the
    # question is always "which profile, which board, which branch did it
    # actually use", and answering it from a failure five hours later means
    # scrolling back through a log that may no longer be available.
    log_info "Resolved profile: ${BUILD_TARGET} (board=${BUILD_BOARD} family=${BUILD_FAMILY} arch=${BUILD_ARCH} adapter=${TARGET_ADAPTER})"
    log_info "Branches in scope: ${branch_list[*]}"

    # Declared once so every step banner can report "n/total" and so a failing
    # step names itself without the caller having to remember what it called.
    _log_declare_steps 5

    begin_step "Environment initialization"
    ensure_host_dependencies

    FAMILY_CONFIG_FILE="./${BUILD_FAMILY}_common.inc"
    FAMILY_CONFIG_TMP="$(mktemp "${FAMILY_CONFIG_FILE}.XXXXXX")"
    # The download is retried on failure, and any later early return between here
    # and the mv would otherwise leave the temp file next to the family config in
    # the working tree, where the next run would treat it as stale state.
    trap 'rm -f -- "${FAMILY_CONFIG_TMP}"' RETURN
    log_debug "Downloading ${FAMILY_CONFIG_FILE}..."
    if curl --fail --location --silent --show-error --retry 4 --retry-all-errors \
        --output "${FAMILY_CONFIG_TMP}" \
        "https://raw.githubusercontent.com/armbian/build/refs/heads/main/config/sources/families/${TARGET_VERSION_CONFIG}"; then
        mv -- "${FAMILY_CONFIG_TMP}" "${FAMILY_CONFIG_FILE}"
        # The file has been renamed into place; nothing left to clean up.
        trap - RETURN
    else
        rm -f -- "${FAMILY_CONFIG_TMP}"
        log_error "Failed to download family version config. Check network connectivity."
        return 1
    fi
    if [[ ! -s "${FAMILY_CONFIG_FILE}" ]]; then
        log_error "Failed to download family version config or the file is empty. Check network connectivity."
        return 1
    fi
    log_info "${BUILD_FAMILY}_common.inc downloaded ($(wc -l < "${FAMILY_CONFIG_FILE}" | tr -d ' ') lines)"
    end_step "Environment initialization"

    if ! CUR_GIT_REPO_URL="$(resolve_repository_url "${PWD}")"; then
        log_error "Unable to determine the current GitHub repository. Check GITHUB_REPOSITORY or the origin remote."
        return 1
    fi
    log_info "Release repository: ${CUR_GIT_REPO_URL}"

    begin_step "Version comparison"
    declare -A BRANCH_UPSTREAM_VER=()
    declare -A NEED_BUILD=()

    for branch in "${branch_list[@]}"; do
        CONFIG_KERNEL_VER="$(get_kernel_version "${branch}" "${FAMILY_CONFIG_FILE}" || true)"
        if [[ -z "${CONFIG_KERNEL_VER}" ]]; then
            log_warn "${branch}: no KERNEL_MAJOR_MINOR entry exists for this branch in the Armbian config; skipping"
            continue
        fi
        log_info "${branch}: Armbian configured major version = ${CONFIG_KERNEL_VER}"
        validate_target_series "${branch}" "${CONFIG_KERNEL_VER}" || return 1

        KERNEL_ORG_VER="$(load_kernel_org_version "${branch}" "${CONFIG_KERNEL_VER}")" || return 1
        if [[ -z "${KERNEL_ORG_VER}" ]]; then
            continue
        fi

        RELEASED_TAG="$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "${RELEASE_PREFIX}${branch}-${CONFIG_KERNEL_VER}" || true)"
        RELEASED_VER="${RELEASED_TAG#"${RELEASE_PREFIX}${branch}-"}"

        if [[ "${BUILD_FORCE:-no}" == yes ]] || needs_update "${RELEASED_VER}" "${KERNEL_ORG_VER}"; then
            NEED_BUILD["${branch}"]=yes
            BRANCH_UPSTREAM_VER["${branch}"]="${KERNEL_ORG_VER}"
            if [[ -z "${RELEASED_TAG}" ]]; then
                log_info "${branch}: no release exists yet; upstream is ${KERNEL_ORG_VER} -> build planned"
            else
                log_info "${branch}: released ${RELEASED_TAG} < upstream ${KERNEL_ORG_VER} -> build planned"
            fi
        else
            log_info "${branch}: released ${RELEASED_TAG} >= upstream ${KERNEL_ORG_VER} -> no build needed"
        fi
    done
    end_step "Version comparison"

    planned_branches=()
    for branch in "${branch_list[@]}"; do
        if [[ "${NEED_BUILD[${branch}]:-}" == yes ]]; then
            planned_branches+=("${branch}")
        fi
    done

    if ((${#planned_branches[@]} == 0)); then
        log_info "All branch kernel versions are current; no build is required. Exiting."
        return 0
    fi
    log_info "Branches scheduled for build: ${planned_branches[*]}"

    begin_step "Prepare Armbian build environment"
    if [[ -d build && ! -f build/compile.sh ]]; then
        log_error "Existing build directory is not an Armbian checkout; move it aside before building."
        return 1
    fi
    if [ -d "build" ]; then
        log_info "Updating existing build directory..."
        git -C build checkout .
        git -C build clean -fd
        git -C build pull --ff-only
        sync_tree ./overwrite ./build
        sync_tree ./userpatches ./build/userpatches
        sync_tree ./scripts/lib ./build/kernel-build/lib
    else
        log_info "Cloning build directory..."
        git clone https://github.com/armbian/build
        sync_tree ./overwrite ./build
        sync_tree ./userpatches ./build/userpatches
        sync_tree ./scripts/lib ./build/kernel-build/lib
    fi
    validate_armbian_board_registration ./build "${BUILD_BOARD}" || return 1
    end_step "Prepare Armbian build environment"

    for branch in "${planned_branches[@]}"; do
        # Steps inside a loop legitimately run more than once, so the banner
        # reports "seq/total" rather than a hardcoded ordinal that would be
        # wrong for every branch after the first.
        begin_step "Build ${branch} kernel (upstream ${BRANCH_UPSTREAM_VER[${branch}]})"
        BUILD_MARKER="$(mktemp "${TMPDIR:-/tmp}/kernel-build-${branch}.XXXXXX")"
        if ! run_armbian_build ./build kernel BOARD="${BUILD_BOARD}" BRANCH="${branch}" RELEASE=trixie KERNEL_HEADERS=yes; then
            rm -f -- "${BUILD_MARKER}"
            log_error "${branch}: Armbian kernel build failed"
            return 1
        fi

        BUILT_KERNEL_VER="$(resolve_built_version "${branch}" "${BUILD_MARKER}")" || {
            rm -f -- "${BUILD_MARKER}"
            return 1
        }
        log_info "${branch}: derived kernel version from artifact = ${BUILT_KERNEL_VER}"
        # Before packaging, not after: packaging validates the boot contract
        # against the built bytes and would report a text_offset mismatch, which
        # says nothing about the patch that should have set it. Runs while the
        # log that proves patch application is still on disk.
        if ! assert_board_patches_applied "${BUILT_KERNEL_VER}"; then
            rm -f -- "${BUILD_MARKER}"
            return 1
        fi
        end_step "Build ${branch} kernel"

        target_package_artifacts "${branch}" "${BUILD_MARKER}" "${BUILT_KERNEL_VER}"
        rm -f -- "${BUILD_MARKER}"
        if [[ "${BUILD_PUBLISH:-yes}" == no ]]; then
            log_info "Publishing disabled; validated artifacts remain in build/output"
            continue
        fi
        begin_step "Publish ${RELEASE_PREFIX}${branch}-${BUILT_KERNEL_VER}"
        upload_to_github_release "${RELEASE_PREFIX}${branch}-${BUILT_KERNEL_VER}" "${branch}" \
            "${BUILT_KERNEL_VER}" "${BRANCH_UPSTREAM_VER[${branch}]}" \
            "./build/output/debs/*-${branch}-${BUILD_FAMILY}_*__${BUILT_KERNEL_VER}-*.deb"
        end_step "Publish ${branch}-${BUILT_KERNEL_VER}"
    done

    log_info "All automation steps completed successfully."
    log_info "Total elapsed: $(_log_elapsed)"
}
