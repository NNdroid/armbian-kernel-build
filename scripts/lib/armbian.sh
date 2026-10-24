#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
run_armbian_build() {
	local build_root="$1"
	local log_file="${BUILD_LOG_FILE:-}"
	local ansi_esc=$'\033'
	shift

	# Armbian's own output is the only place the evidence lives. assert_board_
	# patches_applied greps it for "Using kernel patch dir:" and for one line per
	# applied patch, so if that stream is not copied into BUILD_LOG_FILE the check
	# is unsatisfiable by construction: it can only ever report absence of
	# evidence, whatever the kernel actually contains. The live stream is left
	# untouched -- the caller still sees every line on stderr -- and the copy is
	# ANSI-stripped, because the wrapper's own lines into the same file already
	# are, and a file that is colorless in half its lines is unreadable.
	(
		cd "${build_root}"
		if [[ -n "${log_file}" ]]; then
			./build_with_diy.sh "$@" 2>&1 |
				sed "s/${ansi_esc}\[[0-9;]*[A-Za-z]//g" |
				tee -a "${log_file}"
		else
			./build_with_diy.sh "$@"
		fi
	)
}

# Match Armbian's board search paths before paying the Docker startup cost.
validate_armbian_board_registration() {
    local build_root="$1" board="$2" directory type
    for directory in "${build_root}/config/boards" "${build_root}/userpatches/config/boards"; do
        for type in conf wip csc eos tvb; do
            if [[ -f "${directory}/${board}.${type}" ]]; then
                log_info "Board configuration located: ${directory}/${board}.${type}"
                return 0
            fi
        done
    done
    log_error "No board configuration for ${board}; expected config/boards or userpatches/config/boards inside ${build_root}"
    return 1
}

# The kernel patches under userpatches/kernel/archive/<family>-<major.minor>/
# are read by Armbian itself: patching.py derives KERNELPATCHDIR from
# KERNEL_PATCH_ARCHIVE_BASE (which defaults to LINUXFAMILY) and KERNEL_MAJOR_MINOR,
# then looks for both the framework copy and the userpatches copy of that
# directory. So nothing in this repository has to name the directory for the
# patches to be picked up -- which is exactly why a mistake there is invisible.
#
# Both checks below reproduce that arithmetic instead of trusting a path, and
# through this one helper so the two cannot drift apart.
kernel_patch_archive_dir() {
    printf 'archive/%s-%s' "${BUILD_FAMILY}" "$1"
}

# The profile stores this relative to USERPATCHES_PATH, because that is the one
# anchor guaranteed to hold both on the host, where these checks run, and for a
# reader comparing the profile value against Armbian's own path spelling.
board_patch_dir_path() {
    printf '%s/%s' "${USERPATCHES_PATH:-userpatches}" "${TARGET_BOARD_PATCHES}"
}

# Locate the target's board patch directory, refusing to treat an absent one as
# an empty set. Shared by both checks, because the distinction matters: a target
# that declares no patches skips them, but a target that names a directory which
# does not exist is broken, and Armbian would happily compile an unpatched
# kernel and finish green.
board_patch_dir() {
    local patch_dir="${USERPATCHES_PATH:-userpatches}/${TARGET_BOARD_PATCHES}"
    [[ -d "${patch_dir}" ]] || return 1
    printf '%s' "${patch_dir}"
}

# Strip colour escapes from stdin. Armbian's stream is ANSI, and the escapes sit
# inside the tokens being matched rather than only around them -- the patch
# directory is printed as "[bold green] archive/meson64-7.3 [reset]" -- so a
# literal grep over the raw stream depends on which side of a token the escape
# happens to fall on, and on which theme Armbian happens to be using. Stripping
# first makes the match depend on what a reader sees.
strip_ansi_escapes() {
    sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"
}

# True if the log contains a literal substring. Called as
# log_contains <log-file> <needle>.
#
# Two choices here are regressions that were actually hit, not preferences:
#
#   - the needle is matched literally (-F). Patch names and directory paths hold
#     dots and dashes, so a regex match turns them into wildcards.
#
#   - the output is discarded instead of using -q. build.sh sets pipefail, and
#     grep -q closes its stdin the moment it matches. sed then dies of SIGPIPE
#     with status 141, so pipefail fails the whole pipeline. On a small log sed
#     happens to finish first and the defect stays invisible; on a real
#     multi-megabyte CI log it fires on evidence that is present, so the caller
#     reports the patch set as not applied when it was.
log_contains() {
    strip_ansi_escapes < "$1" | grep -F -- "$2" >/dev/null
}

# True if the log names this patch as applied. Called as
# log_has_patch <base-name> <log-file>.
#
# Armbian reports a patch by its base name, not by its file name: a patch file
# 0001-hk1box-mainline-dtb.patch shows up in the log as
# "-> 002/100: 0001-hk1box-mainline-dtb(:1) (+256/-0) ...". Grepping for the
# file name therefore never matches a real build, which turned this check into a
# permanent failure once the evidence actually existed. Match the base name, with
# the .patch suffix tolerated rather than required, so either spelling proves it.
#
# The match is bounded so a coincidence inside a longer token -- a path, a URL,
# or another identifier that happens to contain the name -- cannot count as
# application. That matters because absence of evidence is treated as failure, so
# a false positive is a published kernel that is wrong in a way nothing else
# reports.
log_has_patch() {
    strip_ansi_escapes < "$2" |
        grep -E -- "(^|[^A-Za-z0-9_.-])$1(\.patch)?([^A-Za-z0-9_.-]|$)" >/dev/null
}

# The scope half of the board patch guarantee, run before the kernel is
# compiled.
#
# A patch set that silently does not apply does not fail the build. Armbian
# prints one "Using kernel patch dir" line, applies whatever it finds, and moves
# on, so a target can publish a kernel built from an unpatched tree for as long
# as nothing downstream reads the bytes that patch would have changed. Those
# downstream readers exist (the ophub-tar packaging validates the ARM64 Image
# text_offset, and the board contract demands the DTB the patch adds) but they
# run after an hour of compiling, and they report a byte mismatch or a missing
# key rather than "your patch did not apply".
#
# This check needs no build log, only the KERNEL_MAJOR_MINOR Armbian declared
# for the branch, which is known before anything is compiled. It catches the
# cheap-to-diagnose half -- Armbian moved the branch, so the directory name
# no longer matches -- in seconds instead of hours.
#
# Call with the configured major.minor. Does nothing when the target declares
# no patches, so a target without board patches needs no special casing here.
assert_board_patches_in_scope() {
    local configured_major_minor="$1" patch_dir patch_dir_name

    [[ -n "${TARGET_BOARD_PATCHES:-}" ]] || return 0
    if ! patch_dir="$(board_patch_dir)"; then
        log_error "Board patches are declared as ${TARGET_BOARD_PATCHES} but $(board_patch_dir_path) does not exist"
        log_error "Create the directory or clear TARGET_BOARD_PATCHES; an absent set is not a passing one"
        return 1
    fi

    patch_dir_name="${patch_dir##*/}"
    if [[ "${patch_dir_name}" != "${BUILD_FAMILY}-${configured_major_minor}" ]]; then
        log_error "Board patches target ${patch_dir_name} but this branch is configured for ${BUILD_FAMILY} ${configured_major_minor}; they are out of scope and Armbian will not read them"
        log_error "Rebase or drop the patch set in ${patch_dir}, or pin the branch with TARGET_SERIES"
        return 1
    fi
    log_info "Board patches in scope: ${patch_dir_name} matches ${BUILD_FAMILY} ${configured_major_minor}"
    return 0
}

# The evidence half of the board patch guarantee, run right after the compile:
# it reads the build log this run has been mirroring into BUILD_LOG_FILE and
# requires positive evidence that each expected patch was applied. Absence of
# evidence is treated as failure, because a board whose patch set silently
# stopped applying looks exactly like a board that is working right up until it
# is flashed.
#
# The expected directory is derived from the kernel version that was actually
# built, not from the patch directory in the profile. That distinction is the
# point: these patches are written against one upstream series, and the moment
# Armbian moves the branch they stop being in scope. Deriving from the built
# version turns that into a named failure here instead of a boot problem later.
# The scope comparison above already used the configured series; this one uses
# the version the artifacts carry, so a disagreement between the two is caught
# too.
#
# Call with the built kernel version. Does nothing when the target declares no
# patches, so a target without board patches needs no special casing here.
assert_board_patches_applied() {
    local built_version="$1"
    local patch_dir patch_dir_name expected_dir patch_name log_file applied missing
    local -a expected_patches=()

    [[ -n "${TARGET_BOARD_PATCHES:-}" ]] || return 0
    if ! patch_dir="$(board_patch_dir)"; then
        log_error "Board patches are declared as ${TARGET_BOARD_PATCHES} but $(board_patch_dir_path) does not exist"
        log_error "Create the directory or clear TARGET_BOARD_PATCHES; an absent set is not a passing one"
        return 1
    fi

    patch_dir_name="${patch_dir##*/}"
    expected_dir="$(kernel_patch_archive_dir "${built_version%.*}")"

    # Sorted so the failure message lists patches in apply order, which is also
    # the order they must appear in the log.
    while IFS= read -r patch_name; do
        [[ -n "${patch_name}" ]] || continue
        expected_patches+=("${patch_name}")
    done < <(find "${patch_dir}" -maxdepth 1 -type f -name '*.patch' -printf '%f\n' | LC_ALL=C sort)

    if ((${#expected_patches[@]} == 0)); then
        return 0
    fi

    log_file="${BUILD_LOG_FILE:-}"
    if [[ -z "${log_file}" || ! -f "${log_file}" ]]; then
        log_error "Cannot verify board patches: no readable build log (BUILD_LOG_FILE='${log_file}')"
        log_error "Set BUILD_LOG_FILE so patch application can be proven, or the ${patch_dir_name} patch set stays unverified"
        return 1
    fi

    # The patches were written against one upstream series. If Armbian moved the
    # branch, they are no longer in scope and the kernel that just got built
    # does not have them. Say that plainly instead of reporting each patch as
    # individually missing.
    if [[ "${patch_dir_name}" != "${expected_dir##*/}" ]]; then
        log_error "Board patches target ${patch_dir_name} but this build produced ${built_version}; they are out of scope"
        log_error "Rebase or drop the patch set in ${patch_dir}, or pin the branch with TARGET_SERIES"
        return 1
    fi

    # A different patch directory means the patches in this tree were never in
    # scope. Report it as its own failure: the log would otherwise look fine,
    # because Armbian happily patches whatever directory it was told to use.
    if ! log_contains "${log_file}" "Using kernel patch dir:" \
        || ! log_contains "${log_file}" "${expected_dir}"; then
        log_error "Armbian did not report using patch dir '${expected_dir}'; the board patch set was never in scope"
        log_error "Expected patches live in ${patch_dir} and apply only when KERNELPATCHDIR resolves to ${expected_dir}"
        return 1
    fi

    missing=()
    applied=0
    for patch_name in "${expected_patches[@]}"; do
        if log_has_patch "${patch_name%.patch}" "${log_file}"; then
            applied=$((applied + 1))
        else
            missing+=("${patch_name}")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_error "${#missing[@]} of ${#expected_patches[@]} board patches were not applied; the built kernel is missing them"
        for patch_name in "${missing[@]}"; do
            log_error "  not applied: ${patch_name}"
        done
        log_error "A patch that does not apply does not fail the Armbian build; check it against ${BUILD_FAMILY} ${built_version} sources"
        return 1
    fi

    log_info "Verified ${applied}/${#expected_patches[@]} board patches applied from ${expected_dir}"
    return 0
}
