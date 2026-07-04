#!/bin/sh

CONFIG_PKG=g1m
CONFIG_SECTION=core
STATE_FILE=/root/g1m-state.env
RELEASE_FILE=/etc/g1m-release.json

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

shell_escape_sq() {
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

safe_string() {
	printf '%s' "$1" | tr -d '\r'
}

ensure_config() {
	uci -q get "$CONFIG_PKG.$CONFIG_SECTION" >/dev/null 2>&1 && return 0
	uci -q batch <<'EOF' >/dev/null
set g1m.core=miner
set g1m.core.pool_coin=grin
set g1m.core.grin_pool_url=stratum+tcp://grin.2miners.com:3030
set g1m.core.grin_pool_user=
set g1m.core.grin_pool_password=x
set g1m.core.active_profile_id=stable-1872-v1080
set g1m.core.active_profile_label=Stable 1872 MHz / Vddr 1300 / Vcore 1080
set g1m.core.active_profile_class=safe
set g1m.core.fan_auto=1
set g1m.core.fan_target_c=65
set g1m.core.fan_min_percent=50
set g1m.core.fan_max_percent=100
set g1m.core.fan_hard_c=70
set g1m.core.rail_telemetry_enabled=1
set g1m.core.rail_telemetry_required=0
set g1m.core.rail_telemetry_start_delay_seconds=180
set g1m.core.rail_telemetry_interval_seconds=30
set g1m.core.debug_uart_readback_enabled=0
set g1m.core.debug_uart_readback_source=stock
set g1m.core.debug_uart_readback_file=/tmp/ttyS2-debug-raw.bin
set g1m.core.debug_uart_readback_baud=3000000
set g1m.core.debug_uart_readback_stale_seconds=30
set g1m.core.boot_health_enabled=0
set g1m.core.boot_health_grace_seconds=900
set g1m.core.boot_health_max_attempts=3
set g1m.core.support_bundle_enabled=1
set g1m.core.migrated_from_cgminer=0
set g1m.core.network_mode=dhcp
set g1m.core.network_ipaddr=192.168.1.113
set g1m.core.network_netmask=255.255.255.0
set g1m.core.network_gateway=192.168.1.1
set g1m.core.network_dns=192.168.1.1
commit g1m
EOF
}

load_state() {
	if [ -f "$STATE_FILE" ]; then
		# shellcheck disable=SC1090
		. "$STATE_FILE"
	fi
}

save_state() {
	local tmp
	umask 077
	tmp="${STATE_FILE}.$$"
	cat > "$tmp" <<EOF
ACTIVE_PROFILE_ID='$(shell_escape_sq "${ACTIVE_PROFILE_ID:-}")'
ACTIVE_PROFILE_LABEL='$(shell_escape_sq "${ACTIVE_PROFILE_LABEL:-}")'
ACTIVE_PROFILE_CLASS='$(shell_escape_sq "${ACTIVE_PROFILE_CLASS:-}")'
PRIOR_PROFILE_ID='$(shell_escape_sq "${PRIOR_PROFILE_ID:-}")'
PRIOR_PROFILE_LABEL='$(shell_escape_sq "${PRIOR_PROFILE_LABEL:-}")'
LAST_ARTIFACT='$(shell_escape_sq "${LAST_ARTIFACT:-}")'
BOOT_ATTEMPTS='$(shell_escape_sq "${BOOT_ATTEMPTS:-0}")'
LAST_SUCCESS_EPOCH='$(shell_escape_sq "${LAST_SUCCESS_EPOCH:-0}")'
LAST_RECOVERY_REASON='$(shell_escape_sq "${LAST_RECOVERY_REASON:-}")'
LAST_RECOVERY_EPOCH='$(shell_escape_sq "${LAST_RECOVERY_EPOCH:-0}")'
LAST_FAILURE_REASON='$(shell_escape_sq "${LAST_FAILURE_REASON:-}")'
EOF
	mv "$tmp" "$STATE_FILE"
}

ensure_state() {
	load_state
	[ -n "${ACTIVE_PROFILE_ID:-}" ] || ACTIVE_PROFILE_ID="$(uci -q get "$CONFIG_PKG.$CONFIG_SECTION.active_profile_id" 2>/dev/null || echo stable-1872-v1080)"
	[ -n "${ACTIVE_PROFILE_LABEL:-}" ] || ACTIVE_PROFILE_LABEL="$(uci -q get "$CONFIG_PKG.$CONFIG_SECTION.active_profile_label" 2>/dev/null || echo Stable\ 1872\ MHz\ /\ Vddr\ 1300\ /\ Vcore\ 1080)"
	[ -n "${ACTIVE_PROFILE_CLASS:-}" ] || ACTIVE_PROFILE_CLASS="$(uci -q get "$CONFIG_PKG.$CONFIG_SECTION.active_profile_class" 2>/dev/null || echo safe)"
	[ -n "${BOOT_ATTEMPTS:-}" ] || BOOT_ATTEMPTS=0
	[ -n "${LAST_SUCCESS_EPOCH:-}" ] || LAST_SUCCESS_EPOCH=0
	save_state
}

migrate_from_cgminer() {
	local migrated coin url user pw fan_auto fan_target fan_min fan_max fan_hard
	migrated="$(uci -q get "$CONFIG_PKG.$CONFIG_SECTION.migrated_from_cgminer" 2>/dev/null || echo 0)"
	[ "$migrated" = "1" ] && return 0
	coin="$(uci -q get cgminer.default.select_coin 2>/dev/null || echo grin)"
	url="$(uci -q get cgminer.default.${coin}_pool1url 2>/dev/null || true)"
	user="$(uci -q get cgminer.default.${coin}_pool1user 2>/dev/null || true)"
	pw="$(uci -q get cgminer.default.${coin}_pool1pw 2>/dev/null || true)"
	fan_auto="$(uci -q get cgminer.default.fan_auto 2>/dev/null || true)"
	fan_target="$(uci -q get cgminer.default.fan_target_c 2>/dev/null || true)"
	fan_min="$(uci -q get cgminer.default.fan_min_percent 2>/dev/null || true)"
	fan_max="$(uci -q get cgminer.default.fan_max_percent 2>/dev/null || true)"
	fan_hard="$(uci -q get cgminer.default.fan_hard_c 2>/dev/null || true)"
	[ -n "$coin" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.pool_coin=$coin"
	[ -n "$url" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.grin_pool_url=$url"
	[ -n "$user" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.grin_pool_user=$user"
	[ -n "$pw" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.grin_pool_password=$pw"
	[ -n "$fan_auto" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.fan_auto=$fan_auto"
	[ -n "$fan_target" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.fan_target_c=$fan_target"
	[ -n "$fan_min" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.fan_min_percent=$fan_min"
	[ -n "$fan_max" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.fan_max_percent=$fan_max"
	[ -n "$fan_hard" ] && uci -q set "$CONFIG_PKG.$CONFIG_SECTION.fan_hard_c=$fan_hard"
	uci -q set "$CONFIG_PKG.$CONFIG_SECTION.migrated_from_cgminer=1"
	uci -q set "$CONFIG_PKG.$CONFIG_SECTION.last_migration_epoch=$(date +%s)"
	uci -q commit "$CONFIG_PKG"
}

cfg_get() {
	local key="$1" fallback="${2:-}"
	local value
	value="$(uci -q get "$CONFIG_PKG.$CONFIG_SECTION.$key" 2>/dev/null || true)"
	[ -n "$value" ] || value="$fallback"
	printf '%s\n' "$value"
}

cfg_set() {
	local key="$1" value="$2"
	uci -q set "$CONFIG_PKG.$CONFIG_SECTION.$key=$(safe_string "$value")" || return 1
	uci -q commit "$CONFIG_PKG" || return 1
}

pool_json() {
	local coin url user pw
	coin="$(cfg_get pool_coin grin)"
	url="$(cfg_get grin_pool_url "")"
	user="$(cfg_get grin_pool_user "")"
	pw="$(cfg_get grin_pool_password x)"
	printf '{"coin":"%s","url":"%s","user":"%s","password":"%s"}\n' \
		"$(json_escape "$coin")" "$(json_escape "$url")" "$(json_escape "$user")" "$(json_escape "$pw")"
}

network_json() {
	local mode ipaddr netmask gateway dns
	mode="$(cfg_get network_mode dhcp)"
	ipaddr="$(cfg_get network_ipaddr 192.168.1.113)"
	netmask="$(cfg_get network_netmask 255.255.255.0)"
	gateway="$(cfg_get network_gateway 192.168.1.1)"
	dns="$(cfg_get network_dns 192.168.1.1)"
	printf '{"mode":"%s","ipaddr":"%s","netmask":"%s","gateway":"%s","dns":"%s"}\n' \
		"$(json_escape "$mode")" "$(json_escape "$ipaddr")" "$(json_escape "$netmask")" "$(json_escape "$gateway")" "$(json_escape "$dns")"
}

state_json() {
	load_state
	printf '{"active_profile_id":"%s","active_profile_label":"%s","active_profile_class":"%s","prior_profile_id":"%s","prior_profile_label":"%s","last_artifact":"%s","boot_attempts":%s,"last_success_epoch":%s,"last_recovery_reason":"%s","last_recovery_epoch":%s,"last_failure_reason":"%s"}\n' \
		"$(json_escape "${ACTIVE_PROFILE_ID:-}")" "$(json_escape "${ACTIVE_PROFILE_LABEL:-}")" "$(json_escape "${ACTIVE_PROFILE_CLASS:-}")" \
		"$(json_escape "${PRIOR_PROFILE_ID:-}")" "$(json_escape "${PRIOR_PROFILE_LABEL:-}")" \
		"$(json_escape "${LAST_ARTIFACT:-}")" "${BOOT_ATTEMPTS:-0}" "${LAST_SUCCESS_EPOCH:-0}" \
		"$(json_escape "${LAST_RECOVERY_REASON:-}")" "${LAST_RECOVERY_EPOCH:-0}" "$(json_escape "${LAST_FAILURE_REASON:-}")"
}

ensure_core() {
	ensure_config
	migrate_from_cgminer
	ensure_state
}

ensure_all() {
	ensure_core
}

case "$1" in
	ensure)
		ensure_core
		;;
	migrate)
		ensure_config
		migrate_from_cgminer
		;;
	get)
		ensure_config
		cfg_get "$2" "$3"
		;;
	set)
		ensure_config
		cfg_set "$2" "$3"
		;;
	pool-json)
		ensure_core
		pool_json
		;;
	network-json)
		ensure_core
		network_json
		;;
	state-json)
		ensure_core
		state_json
		;;
	release-json)
		cat "$RELEASE_FILE" 2>/dev/null || echo '{}'
		;;
	*)
		echo "usage: $0 ensure|migrate|get <key> [default]|set <key> <value>|pool-json|network-json|state-json|release-json" >&2
		exit 1
		;;
esac
