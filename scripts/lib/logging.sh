#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
log_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log_info()  { printf '\e[32m[INFO]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1"; }
log_debug() { printf '\e[34m[DEBUG]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }
log_warn()  { printf '\e[33m[WARN]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }
log_error() { printf '\e[31m[ERROR]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }

STEP_START=0
begin_step() {
	STEP_START=$SECONDS
	log_info "──── $1 ────"
}
end_step() {
	log_info "──── $1 completed (elapsed $((SECONDS - STEP_START))s) ────"
}

report_unhandled_error() {
	local exit_code="$1"
	local line_number="$2"
	local failed_command="$3"

	trap - ERR
	log_error "Command failed: exit=${exit_code}, line=${line_number}, command=${failed_command}"
	log_error "Working directory at failure: ${PWD}"
	exit "${exit_code}"
}
