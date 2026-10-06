#!/usr/bin/env bash
# Target profiles: declaration, validation and introspection.
#
# A "target" is one buildable board+family combination. Everything a target
# needs lives in a single file under userpatches/config/build-targets/, named
# after the target id. The profile is trusted, version-controlled Bash data --
# never downloaded and never eval'd.
#
# Adding a target therefore means adding exactly one file. This module owns the
# schema, so the field list below is the single place where a new field has to
# be declared; loading, resetting, validation and documentation all derive from
# it instead of repeating hand-written field names.

# Diagnostics go through log_error so they land in BUILD_LOG_FILE and in the
# replayed failure context. That makes the logger a real dependency of this
# module, and it has to be resolved here rather than assumed: the regression
# tests source this file directly and the Docker wrapper sources it as
# BUILD_LIBRARY_ROOT/targets.sh, neither of which loads the full library set.
if ! declare -F log_error > /dev/null 2>&1; then
	_targets_logging_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
	# shellcheck disable=SC1091
	source "${_targets_logging_dir}/logging.sh"
	unset _targets_logging_dir
fi

# The authoritative target schema.
#
# Format: <field>|<kind>|<required>|<validator>|<default>
#   kind       scalar | ident | path | list | map
#   required   yes | no   -- "no" means a declared default is materialised
#   validator  ident | abspath | relative-config | deb-prefix | dtb | branch
#              | series | archpair | list-ident | list-branch | choice:<a|b>
#              | any (no format constraint beyond "non-empty when required")
#   default    literal substituted when the profile leaves the field unset
#
# Keeping this table declarative is what makes "add a field" a one-line change:
# load_build_target derives the reset list, the required check and the format
# check from it, so a field can no longer be half-implemented.
TARGET_SCHEMA=(
    'TARGET_BOARD|scalar|yes|ident|'
    'TARGET_FAMILY|scalar|yes|ident|'
    'TARGET_ARCH|scalar|yes|ident|'
    'TARGET_KBUILD_ARCH|scalar|yes|ident|'
    'TARGET_RUNNER|scalar|yes|ident|'
    'TARGET_VERSION_CONFIG|scalar|yes|relative-config|'
    'TARGET_RELEASE_PREFIX|scalar|no|deb-prefix|'
    'TARGET_ADAPTER|scalar|yes|ident|'
    'TARGET_BOARD_DTB|scalar|no|dtb|'
    # Board-level kernel source patches, as a path relative to
    # USERPATCHES_PATH. Armbian applies these itself, from the directory
    # userpatches/kernel/archive/<family>-<major.minor>/; declaring them here
    # only lets the build assert that each one was actually applied, since a
    # patch that silently does not apply does not fail the Armbian build.
    'TARGET_BOARD_PATCHES|scalar|no|relative-patches|'
    # Board boot-contract knobs, checked after the kernel is built. They are
    # data rather than code so a similar board needs no new script: the ophub-tar
    # packaging reads whatever is declared and skips the rest.
    #   TARGET_BOOT_TEXT_OFFSET    required leading text_offset in the ARM64 Image
    #   TARGET_DTB_MMC_ALIASES     mmc0..N alias targets, in controller order
    #   TARGET_DTB_MEMORY_REG      expected /memory@0 reg value
    'TARGET_BOOT_TEXT_OFFSET|scalar|no|hex|'
    'TARGET_DTB_MMC_ALIASES|list|no|list-hex|'
    'TARGET_DTB_MEMORY_REG|scalar|no|memory-reg|'
    'TARGET_BRANCHES|list|yes|list-branch|'
    'TARGET_SERIES|map|no|series|'
    'TARGET_REQUIRED_Y|list|no|list-ident|'
    # Armbian's own board variables. These keep their upstream names on purpose:
    # Armbian sources this profile through config/boards/<board>.conf and reads
    # them by those exact names, so they are a contract, not our naming choice.
    # BOARDFAMILY (the board's DTS family) is deliberately distinct from
    # TARGET_FAMILY (the kernel linuxfamily).
    'BOARD_NAME|scalar|no|any|'
    'BOARD_VENDOR|scalar|no|any|'
    'BOARDFAMILY|scalar|no|any|'
    'KERNEL_TARGET|scalar|no|branch|'
    'BOOT_FDT_FILE|scalar|no|dtb|'
    'SERIALCON|scalar|no|any|'
    'BOOTCONFIG|scalar|no|any|'
    # The kernel config fragment Armbian picks up for this target, recorded so a
    # missing fragment is discoverable and the expectation is explicit. Armbian
    # resolves it by the linux-<family>-<branch>.config convention; declaring it
    # is documentation, not an override.
    'TARGET_KERNEL_CONFIG|scalar|no|config-fragment|'
)

# Fields that are lists or maps rather than scalars, so a reset has to
# re-declare them with the right type.
target_schema_field() {
    local name="$1" index
    for index in "${!TARGET_SCHEMA[@]}"; do
        [[ "${TARGET_SCHEMA[index]%%|*}" == "${name}" ]] || continue
        printf '%s\n' "${TARGET_SCHEMA[index]}"
        return 0
    done
    return 1
}

target_schema_names() {
    local entry
    for entry in "${TARGET_SCHEMA[@]}"; do
        printf '%s\n' "${entry%%|*}"
    done
}

build_targets_directory() {
    printf '%s\n' "${BUILD_TARGETS_DIR:-${BUILD_PROJECT_ROOT}/userpatches/config/build-targets}"
}

list_build_targets() {
    local directory path
    directory="$(build_targets_directory)"
    for path in "${directory}"/*.conf; do
        [[ -f "${path}" ]] || continue
        path="${path##*/}"
        printf '%s\n' "${path%.conf}"
    done
}

# Emit the target list as a GitHub Actions matrix object.
#
# The scheduled workflow builds every target, so it needs each target's runner as
# well as its id -- hk1box needs an arm64 runner and rockchip64 an x86_64 one.
# Resolving the runner here rather than in the workflow is the point: a new
# target declares its own runner in its profile, and the schedule picks it up
# with no edit to any workflow. Emitting a hand-written "target: [a, b]" list in
# YAML would guarantee the two drift apart.
#
# One describe per target, not one per field: the loader is cheap but the whole
# point of running it is to fail here rather than in a matrix leg.
list_build_targets_json() {
    local target described runner board family first=1
    printf '{"include":['
    while read -r target; do
        [[ -n "${target}" ]] || continue
        # describe_build_target reports the already-loaded profile; it does not
        # load one. Assign BUILD_TARGET first rather than as a command prefix:
        # a prefix assignment applies to the command it precedes, so the
        # function body would still see the previous value and report an empty
        # target. Reset too, so each target starts from the schema defaults
        # instead of inheriting the previous one's fields.
        _target_reset_schema
        BUILD_TARGET="${target}"
        described=''
        if load_build_target >/dev/null 2>&1; then
            described="$(describe_build_target 2>/dev/null || true)"
        fi
        runner="$(sed -n 's/^runner=//p' <<< "${described}")"
        board="$(sed -n 's/^board=//p' <<< "${described}")"
        family="$(sed -n 's/^family=//p' <<< "${described}")"
        ((first)) || printf ','
        first=0
        # Quote by hand rather than with %q: %q only adds quotes when the value
        # contains something that needs them, so a plain id would come out as a
        # bare token and the whole document would stop being valid JSON. These
        # values are target ids, runner labels, board names and family names --
        # none may contain a quote or a backslash, and the loader rejects a
        # target id that does, so escaping those two characters is sufficient.
        _target_json_escape() {
            local value="$1"
            value="${value//\\/\\\\}"
            value="${value//\"/\\\"}"
            printf '"%s"' "${value}"
        }
        printf '{"target":%s,"runner":%s,"board":%s,"family":%s}' \
            "$(_target_json_escape "${target}")" \
            "$(_target_json_escape "${runner}")" \
            "$(_target_json_escape "${board}")" \
            "$(_target_json_escape "${family}")"
    done < <(list_build_targets)
    printf ']}\n'
}

target_profile_path() {
    local target="$1"
    printf '%s\n' "$(build_targets_directory)/${target}.conf"
}

# Reset every schema field so sequential loads in one shell cannot leak data
# from a previously loaded target. Derived from TARGET_SCHEMA so a newly added
# field is reset without anyone remembering to extend a hand-written list.
_target_reset_schema() {
    local entry name kind
    for entry in "${TARGET_SCHEMA[@]}"; do
        name="${entry%%|*}"
        kind="${entry#*|}"; kind="${kind%%|*}"
        case "${kind}" in
            list)
                # unset first: re-declaring an existing *scalar* of the same
                # name with () would leave the literal string "()" in place of
                # an array, and every later "${arr[@]}" would then see garbage.
                unset "${name}"
                declare -ga "${name}=()"
                ;;
            map)
                unset "${name}"
                declare -gA "${name}=()"
                ;;
            *) unset "${name}" ;;
        esac
    done
    # Adapter callbacks are defined by the adapter, not the profile.
    unset -f target_package_artifacts target_extra_release_assets target_adapter_validate
}

# Apply declared defaults for fields the profile left unset.
_target_apply_defaults() {
    local entry name default
    for entry in "${TARGET_SCHEMA[@]}"; do
        name="${entry%%|*}"
        default="${entry##*|}"
        [[ -n "${default}" ]] || continue
        [[ -n "${!name:-}" ]] && continue
        printf -v "${name}" '%s' "${default}"
    done
}

# Validate one field against its declared validator. Returns non-zero on the
# first problem so the caller can report it with profile context.
_target_validate_field() {
    local entry="$1" name kind required validator value
    name="${entry%%|*}"
    local rest="${entry#*|}"
    kind="${rest%%|*}"; rest="${rest#*|}"
    required="${rest%%|*}"; rest="${rest#*|}"
    validator="${rest%%|*}"

    case "${kind}" in
        list)
            # Indirect access to a list held in a dynamically named variable.
            # ${!name[@]} cannot be used here: for an indexed array it yields the
            # subscripts rather than the values. A nameref is the correct way.
            local -n values="${name}"
            local item
            if [[ "${validator}" == list-branch ]]; then
                for item in "${values[@]}"; do
                    [[ "${item}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
                        log_error '%s contains an invalid branch name: %s' "${name}" "${item}"
                        return 1
                    }
                done
            elif [[ "${validator}" == list-ident ]]; then
                for item in "${values[@]}"; do
                    [[ "${item}" =~ ^[A-Za-z0-9_]+$ ]] || {
                        log_error '%s contains an invalid identifier: %s' "${name}" "${item}"
                        return 1
                    }
                done
            elif [[ "${validator}" == list-hex ]]; then
                for item in "${values[@]}"; do
                    [[ "${item}" =~ ^[0-9a-fA-F]{4,16}$ ]] || {
                        log_error '%s must hold hex controller addresses, got %s' "${name}" "${item}"
                        return 1
                    }
                done
            fi
            if [[ "${required}" == yes && "${#values[@]}" -eq 0 ]]; then
                log_error '%s must declare at least one entry' "${name}"
                return 1
            fi
            unset -n values
            return 0
            ;;
        map)
            # A nameref, for the same reason as the list case above: a plain
            # ${!name[@]} degrades to indexed access and yields the array's own
            # name as a value instead of the per-branch locks.
            local -n locks="${name}"
            local branch series
            for branch in "${!locks[@]}"; do
                series="${locks[$branch]}"
                [[ "${series}" =~ ^[0-9]+\.[0-9]+$ ]] || {
                    log_error '%s[%s] must be a major.minor series, got %s' "${name}" "${branch}" "${series}"
                    return 1
                }
            done
            unset -n locks
            return 0
            ;;
    esac

    value="${!name:-}"
    if [[ -z "${value}" ]]; then
        if [[ "${required}" == yes ]]; then
            log_error '%s is required but missing or empty' "${name}"
            return 1
        fi
        return 0
    fi

    case "${validator}" in
        ident)
            [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
                log_error '%s has an unsupported value: %s' "${name}" "${value}"
                return 1
            }
            ;;
        relative-config)
            [[ "${value}" =~ ^([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(inc|conf)$ ]] || {
                log_error '%s must be a family-relative include: %s' "${name}" "${value}"
                return 1
            }
            ;;
        relative-patches)
            # A directory of .patch files, relative to USERPATCHES_PATH. No
            # traversal: the value is concatenated onto USERPATCHES_PATH and
            # then read, so a leading ../ would read outside the tree the user
            # is supposed to be declaring patches for. Dots are allowed because
            # the directory Armbian reads is named after the kernel series
            # (archive/meson64-7.2), so a versioned name is the normal case.
            [[ "${value}" =~ ^([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+$ ]] || {
                log_error '%s must be a directory path relative to USERPATCHES_PATH: %s' "${name}" "${value}"
                return 1
            }
            ;;
        deb-prefix)
            [[ "${value}" =~ ^[A-Za-z0-9._-]*$ ]] || {
                log_error '%s must be a safe filename prefix: %s' "${name}" "${value}"
                return 1
            }
            ;;
        dtb)
            [[ "${value}" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9._-]+\.dtb$ ]] || {
                log_error '%s must be vendor/device.dtb: %s' "${name}" "${value}"
                return 1
            }
            ;;
        branch)
            [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
                log_error '%s must be an Armbian branch name: %s' "${name}" "${value}"
                return 1
            }
            ;;
        config-fragment)
            [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.config$ ]] || {
                log_error '%s must be a kernel config fragment name: %s' "${name}" "${value}"
                return 1
            }
            ;;
        hex)
            [[ "${value}" =~ ^[0-9a-fA-F]{4,16}$ ]] || {
                log_error '%s must be a hex value: %s' "${name}" "${value}"
                return 1
            }
            ;;
        memory-reg)
            # fdtget prints /memory@0 reg as space-separated hex cells.
            [[ "${value}" =~ ^[0-9a-fA-F]+([[:space:]][0-9a-fA-F]+)*$ ]] || {
                log_error '%s must be space-separated hex cells: %s' "${name}" "${value}"
                return 1
            }
            ;;
        any) ;;
        *)
            log_error '%s declares unknown validator %s' "${name}" "${validator}"
            return 1
            ;;
    esac
}

load_build_target() {
    BUILD_TARGET="${BUILD_TARGET:-rockchip64}"
    [[ "${BUILD_TARGET}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        log_error 'Unsafe BUILD_TARGET identifier: %s' "${BUILD_TARGET}"; return 1
    }
    local profile entry branch found=no
    profile="$(target_profile_path "${BUILD_TARGET}")"
    if [[ ! -f "${profile}" ]]; then
        log_error 'Unknown BUILD_TARGET: %s' "${BUILD_TARGET}"
        log_error 'Available targets: %s' "$(list_build_targets | tr '\n' ' ')"
        return 1
    fi

    _target_reset_schema
    # shellcheck disable=SC1090
    source "${profile}"
    _target_apply_defaults

    for entry in "${TARGET_SCHEMA[@]}"; do
        _target_validate_field "${entry}" || {
            log_error 'Invalid target profile: %s' "${profile}"
            return 1
        }
    done

    # Debian and Kbuild architectures must be a known pairing; an arbitrary
    # combination would produce DEBs that cannot be installed.
    case "${TARGET_ARCH}:${TARGET_KBUILD_ARCH}" in
        arm64:arm64|armhf:arm|amd64:x86|riscv64:riscv) ;;
        *) log_error 'Invalid Debian/Kbuild architecture mapping: %s:%s' "${TARGET_ARCH}" "${TARGET_KBUILD_ARCH}"; return 1 ;;
    esac

    local -a declared_branches=()
    mapfile -t declared_branches < <(printf '%s\n' "${TARGET_BRANCHES[@]}")
    for branch in "${declared_branches[@]}"; do
        [[ "${BUILD_BRANCH:-auto}" != "${branch}" ]] || found=yes
    done
    branch_list=("${declared_branches[@]}")
    if [[ "${BUILD_BRANCH:-auto}" != auto ]]; then
        if [[ "${found}" != yes ]]; then
            log_error 'Branch %s is not supported by target %s (declares: %s)' "${BUILD_BRANCH}" "${BUILD_TARGET}" "${declared_branches[*]}"
            return 1
        fi
        branch_list=("${BUILD_BRANCH}")
    fi

    # A series lock is only meaningful for a branch the target actually builds.
    local locked
    for locked in "${!TARGET_SERIES[@]}"; do
        [[ " ${declared_branches[*]} " == *" ${locked} "* ]] || {
            log_error '%s pins a series for %s but does not build that branch' "${BUILD_TARGET}" "${locked}"
            return 1
        }
    done

    case "${BUILD_PUBLISH:-yes}" in yes|no) ;; *) return 1 ;; esac
    case "${BUILD_FORCE:-no}" in yes|no) ;; *) return 1 ;; esac

    # Kernel config fragment: per-target when declared, otherwise the shared
    # <family>-<branch> fragment. Centralising the lookup keeps every caller
    # from re-deriving the same filename.
    TARGET_KERNEL_CONFIG="${TARGET_KERNEL_CONFIG:-linux-${TARGET_FAMILY}-${branch_list[0]}.config}"

    local adapter="${BUILD_LIBRARY_ROOT:-${BUILD_PROJECT_ROOT}/scripts/lib}/adapters/${TARGET_ADAPTER}.sh"
    [[ -f "${adapter}" ]] || {
        log_error 'Unknown packaging adapter: %s' "${TARGET_ADAPTER}"
        log_error 'Available adapters: %s' "$(cd -- "$(dirname -- "${adapter}")" && printf '%s ' ./*.sh | sed 's/\.sh//g')"
        return 1
    }
    # shellcheck disable=SC1090
    source "${adapter}"
    declare -F target_package_artifacts >/dev/null || return 1
    declare -F target_extra_release_assets >/dev/null || return 1
    declare -F target_adapter_validate >/dev/null || return 1
    target_adapter_validate || return 1
    # Armbian resolves the board through config/boards/<board>.conf. Catching a
    # missing shim here costs a second; catching it in compile.sh costs an hour.
    # Only enforced for the real profile directory: a caller that redirects
    # BUILD_TARGETS_DIR is exercising profiles in isolation, not a full build.
    if [[ -z "${BUILD_TARGETS_DIR:-}" ]]; then
        validate_target_boards "${TARGET_BOARD}" || return 1
    fi

    BUILD_BOARD="${TARGET_BOARD}"
    BUILD_FAMILY="${TARGET_FAMILY}"
    BUILD_ARCH="${TARGET_ARCH}"
    RELEASE_PREFIX="${TARGET_RELEASE_PREFIX:-}"
    export BUILD_TARGET BUILD_FAMILY BUILD_ARCH
}

validate_target_series() {
    local branch="$1" series="$2" expected="${TARGET_SERIES[$1]:-}"
    [[ -z "${expected}" || "${expected}" == "${series}" ]] && return 0
    # Armbian moves a branch to a new major.minor over time. A series lock means
    # "this target's board patches are only proven against this series", so the
    # actionable fix is to rebase/verify the patches and bump TARGET_SERIES in the
    # profile -- not to retry or to relax the check silently.
    log_error '%s / %s is pinned to kernel series %s but Armbian now configures %s' "${BUILD_TARGET}" "${branch}" "${expected}" "${series}"
    log_error "Rebase and re-verify this target's patches for the %s series, then update TARGET_SERIES in %s" "${series}" "$(target_profile_path "${BUILD_TARGET}")"
    return 1
}

describe_build_target() {
    local entry name value key item
    printf 'target=%s\n' "${BUILD_TARGET}"
    # Emit the schema itself so callers (and the CI prepare job) can see every
    # resolved field without this function enumerating them by hand. The output
    # key is the field name without its TARGET_ prefix, which is the contract
    # the workflow's prepare step reads (runner / board / family / arch).
    for entry in "${TARGET_SCHEMA[@]}"; do
        name="${entry%%|*}"
        key="${name#TARGET_}"
        key="${key,,}"
        # A nameref covers the list and map cases alike; ${name[@]} on a plain
        # string variable would only ever yield element 0.
        local -n field="${name}"
        case "${name}" in
            # Report the branch actually selected, not every declared branch.
            TARGET_BRANCHES) value="${branch_list[*]}" ;;
            TARGET_REQUIRED_Y) value="${#field[@]} symbols" ;;
            TARGET_SERIES|TARGET_DTB_MMC_ALIASES)
                value=""
                for item in "${!field[@]}"; do
                    [[ -n "${value}" ]] && value+=" "
                    if [[ "${name}" == TARGET_SERIES ]]; then
                        value+="${item}=${field[$item]}"
                    else
                        value+="${field[$item]}"
                    fi
                done
                ;;
            *) value="${field:-}" ;;
        esac
        unset -n field
        printf '%s=%s\n' "${key}" "${value}"
    done
}

# --- Self-check and scaffolding ------------------------------------------
# Adding a target should be one command and one file, so the invariants a
# profile must satisfy are checked here for every target at once instead of
# being discovered halfway through a kernel build.

# A target needs an Armbian board shim, because Armbian looks the board up at
# config/boards/<board>.conf. The lookup key is the Armbian board id
# (TARGET_BOARD), which is not always the same as the target id -- rockchip64
# builds nanopi-r5s. Report the missing shim rather than letting the build fail
# with "no board configuration" after Docker has already started.
validate_target_boards() {
    local board="$1" problems=0 board_conf
    board_conf="${BUILD_PROJECT_ROOT}/userpatches/config/boards/${board}.conf"
    if [[ ! -f "${board_conf}" ]]; then
        log_error 'Board %s has no Armbian board file: %s' "${board}" "${board_conf}"
        log_error 'Create it as a shim sourcing config/build-targets/%s.conf' "${BUILD_TARGET}"
        problems=$((problems + 1))
    fi
    return "${problems}"
}

# Load every declared target and report the ones that do not resolve. Used by
# `build.sh --check-targets` so a profile edit cannot break a target that is not
# currently being built.
check_all_targets() {
    local target diagnostics failed=0
    while read -r target; do
        [[ -n "${target}" ]] || continue
        # Capture the diagnostic in a variable rather than re-running the loader:
        # a second run under `set -e` would abort the whole check on the first
        # failure and hide every remaining target.
        if diagnostics="$(BUILD_TARGET="${target}" load_build_target 2>&1 > /dev/null)"; then
            BUILD_TARGET="${target}" load_build_target > /dev/null 2>&1
            printf '[OK]   %-12s %s / %s\n' "${target}" "${TARGET_BOARD}" "${TARGET_FAMILY}"
        else
            printf '[FAIL] %s\n' "${target}"
            [[ -n "${diagnostics}" ]] && printf '%s\n' "${diagnostics}" | sed 's/^/       /'
            failed=$((failed + 1))
        fi
    done < <(list_build_targets)
    if ((failed > 0)); then
        printf '\n%d target(s) failed to load\n' "${failed}" >&2
        return 1
    fi
    printf '\nAll targets load cleanly\n'
}

# Emit a commented starting profile. Board differences belong in this file, so
# the scaffold documents the fields instead of leaving the author to discover
# them; anything left commented is optional.
scaffold_target_profile() {
    local target="$1" path
    [[ "${target}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        log_error 'Unsafe target id: %s' "${target}"
        return 1
    }
    path="$(target_profile_path "${target}")"
    if [[ -e "${path}" ]]; then
        log_error 'Target profile already exists: %s' "${path}"
        return 1
    fi
    mkdir -p -- "$(dirname -- "${path}")" "${BUILD_PROJECT_ROOT}/userpatches/config/boards"
    cat > "${path}" <<PROFILE
# ${target}: single source of truth for this target.
#
# Build identity, kernel series lock, DTB, built-in driver requirements, the
# Armbian board variables and the custom_kernel_config / post_family_config
# hooks all live in this file. userpatches/config/boards/${target}.conf is a
# one-line shim that sources it, because Armbian requires a board file there.
#
# Fields marked required must be set; the rest are optional and their defaults
# come from the schema in scripts/lib/targets.sh. Run
#   bash build.sh --describe-target ${target}
# to see the fully resolved profile, and --check-targets to validate every one.

# --- Build identity (required) -------------------------------------------
TARGET_BOARD=${target}
TARGET_FAMILY=rockchip64
TARGET_ARCH=arm64
TARGET_KBUILD_ARCH=arm64
TARGET_RUNNER=ubuntu-24.04
TARGET_VERSION_CONFIG=include/rockchip64_common.inc
# deb     : plain Armbian DEBs, no extra packaging
# ophub-tar: armbian-update tar bundle; requires a series lock and a DTB
TARGET_ADAPTER=deb
TARGET_BRANCHES=(current)

# --- Optional: series lock ------------------------------------------------
# Armbian moves a branch to a new major.minor over time. Pin the series your
# board patches are proven against; omit it to track Armbian. Assign into the
# declared map -- a bare TARGET_SERIES=([branch]=x.y) literal makes bash parse
# [branch] as an arithmetic subscript and fails under 'set -u'.
# declare -gA TARGET_SERIES=()
# TARGET_SERIES["current"]=6.18

# --- Optional: board artifact contract ------------------------------------
# Verified against the built DEBs after the kernel is compiled.
# TARGET_BOARD_DTB=vendor/device.dtb
# TARGET_BOOT_TEXT_OFFSET=01080000
# TARGET_DTB_MMC_ALIASES=(ffe03000 ffe05000 ffe07000)
# TARGET_DTB_MEMORY_REG='0 0 0 ffffffff'

# --- Optional: built-in drivers for a headless boot -----------------------
# Forced to =y so boot never depends on a module loaded from disk.
# TARGET_REQUIRED_Y=(MMC MMC_BLOCK BLK_DEV_INITRD EXT4_FS)

# --- Optional: Armbian board variables ------------------------------------
# BOARD_NAME=${target}
# BOARD_VENDOR=amlogic
# BOARDFAMILY=meson-sm1
# KERNEL_TARGET=current
# BOOT_FDT_FILE=vendor/device.dtb
# SERIALCON=ttyAML0
# BOOTCONFIG=none

# --- Optional: Armbian hooks ----------------------------------------------
# Both are optional; omit whichever the board does not need. A custom hook must
# be named <hook_point>__<suffix> so the Extension Manager dispatches it.
#
# function post_family_config__${target}_family_tweaks() {
#     BOOTCONFIG=none
# }
#
# function custom_kernel_config__999_${target}_required_drivers() {
#     local symbol
#     for symbol in "\${TARGET_REQUIRED_Y[@]}"; do
#         _kernel_inject_force_mode "\${symbol}" y || return 1
#         kernel_config_modifying_hashes+=("${target}-required=\${symbol}=y")
#     done
# }
PROFILE

    local board_conf="${BUILD_PROJECT_ROOT}/userpatches/config/boards/${target}.conf"
    # The shim derives the profile name from its own filename, so its content is
    # identical for every target and needs no expansion here.
    cat > "${board_conf}" <<'BOARD'
# Armbian requires a board file at this conventional path and sources it by
# board id. All configuration lives in the target profile; do not add any here
# or it will silently drift from the profile.
_target_profile="${USERPATCHES_PATH}/config/build-targets/${BASH_SOURCE[0]##*/}"
_target_profile="${_target_profile%.conf}.conf"
if [[ ! -f "${_target_profile}" ]]; then
    log_error 'Board %s has no target profile: %s' "${BASH_SOURCE[0]##*/}" "${_target_profile}"
    return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1090
source "${_target_profile}"
unset _target_profile
BOARD

    printf 'Created %s\n' "${path}"
    printf 'Created %s\n' "${board_conf}"
    printf '\nNext: set the required identity fields, then validate with\n'
    printf '  bash build.sh --describe-target %s\n' "${target}"
}

# Create a new target from the scaffold.
new_build_target() {
    [[ $# -eq 1 ]] || {
        printf 'Usage: build.sh --new-target <id>\n' >&2
        return 1
    }
    scaffold_target_profile "$1"
}
