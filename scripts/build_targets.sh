#!/usr/bin/env bash
# Compatibility include for callers predating scripts/lib/targets.sh.
BUILD_PROJECT_ROOT="${BUILD_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
source "${BUILD_PROJECT_ROOT}/scripts/lib/targets.sh"
