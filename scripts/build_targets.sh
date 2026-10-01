#!/usr/bin/env bash
# Platform differences only. All targets use build.sh and build_with_diy.sh.
load_build_target() {
    BUILD_TARGET="${BUILD_TARGET:-rockchip64}"
    case "${BUILD_TARGET}" in
        rockchip64)
            BUILD_BOARD=nanopi-r5s
            BUILD_FAMILY=rockchip64
            RELEASE_PREFIX=''
            branch_list=(current edge bleedingedge)
            ;;
        hk1box)
            BUILD_BOARD=hk1box
            BUILD_FAMILY=meson64
            RELEASE_PREFIX=hk1box-
            branch_list=(edge)
            ;;
        *) printf '[ERROR] Unknown BUILD_TARGET: %s\n' "${BUILD_TARGET}" >&2; return 1 ;;
    esac
    case "${BUILD_BRANCH:-auto}" in
        auto) ;;
        current|edge|bleedingedge)
            if [[ "${BUILD_TARGET}" == hk1box && "${BUILD_BRANCH}" != edge ]]; then
                echo '[ERROR] HK1 Box adaptation currently supports edge / 7.2 only' >&2
                return 1
            fi
            branch_list=("${BUILD_BRANCH}")
            ;;
        *) echo '[ERROR] BUILD_BRANCH must be auto/current/edge/bleedingedge' >&2; return 1 ;;
    esac
    case "${BUILD_PUBLISH:-yes}" in yes|no) ;; *) return 1 ;; esac
    case "${BUILD_FORCE:-no}" in yes|no) ;; *) return 1 ;; esac
    export BUILD_FAMILY
}
