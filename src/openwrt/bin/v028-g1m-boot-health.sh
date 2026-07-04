#!/bin/sh

STATS_FILE=/tmp/custom-miner-stats.json
PID_FILE=/var/run/custom-miner.pid

cfg() { /usr/bin/g1m-config get "$1" "$2"; }
read_stat() { jsonfilter -i "$STATS_FILE" -e "$1" 2>/dev/null || true; }

monitor() {
	local enabled grace require_telemetry accepted rail_ok
	enabled="$(cfg boot_health_enabled 1)"
	[ "$enabled" = "1" ] || exit 0
	grace="$(cfg boot_health_grace_seconds 900)"
	require_telemetry="$(cfg rail_telemetry_required 0)"
	sleep "$grace"
	[ -f "$PID_FILE" ] || exit 0
	miner_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
	[ -n "$miner_pid" ] && kill -0 "$miner_pid" 2>/dev/null || exit 0
	accepted="$(read_stat '@.accepted')"
	case "$accepted" in ''|*[!0-9]*) accepted=0 ;; esac
	rail_ok="$(jsonfilter -i /tmp/g1-rail-telemetry.json -e '@.ok' 2>/dev/null || echo false)"
	if [ "$accepted" -gt 0 ]; then
		/usr/bin/g1m-apply-profile mark-good >/dev/null 2>&1 || true
		exit 0
	fi
	if [ "$require_telemetry" = "1" ] && [ "$rail_ok" != "true" ]; then
		logger -t g1m-boot-health "telemetry invalid after boot; observation only, auto-recovery disabled"
		exit 0
	fi
	logger -t g1m-boot-health "no accepts after boot grace window; observation only, auto-recovery disabled"
}

case "$1" in
	monitor) monitor ;;
	*) echo "usage: $0 monitor" >&2; exit 1 ;;
esac
