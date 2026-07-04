#!/bin/sh

PROFILE_DIR=/root/profiles
PROFILE_JSON=/www/custom-miner-profile.json
STATE_FILE=/root/g1m-state.env

. /usr/bin/g1m-policy source-only || exit 1
/usr/bin/g1m-config ensure >/dev/null 2>&1 || true
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

shell_escape_sq() {
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

save_state() {
	local tmp
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

profile_record() {
	case "$1" in
		stable-1872-v1080)
			echo "label='Stable 1872 MHz / Vddr 1300 / Vcore 1080'"
			echo "firmware='$PROFILE_DIR/Mini-G22-stable-1872-v1080.bin'"
			echo "profile='ddr9c-isl-vddr1300-vcore1080-bridge-telemetry'"
			echo "tier='safe'"
			echo "ddr_raw='0x9c'"
			echo "ddr_mhz='1872'"
			echo "vddr_mv='1300'"
			echo "vcore_mv='1080'"
			;;
		perf-2004-v1080)
			echo "label='Performance 2004 MHz / Vddr 1300 / Vcore 1080'"
			echo "firmware='$PROFILE_DIR/Mini-G22-perf-2004-v1080.bin'"
			echo "profile='ddra7-isl-vddr1300-vcore1080-bridge-telemetry'"
			echo "tier='balanced'"
			echo "ddr_raw='0xa7'"
			echo "ddr_mhz='2004'"
			echo "vddr_mv='1300'"
			echo "vcore_mv='1080'"
			;;
		exp-2100-vddr1480-vcore1060)
			echo "label='Experimental 2100 MHz / Vddr 1480 / Vcore 1060'"
			echo "firmware='$PROFILE_DIR/Mini-G22-exp-2100-vddr1480-vcore1060.bin'"
			echo "profile='ddraf-isl-vddr1480-vcore1060-bridge-telemetry'"
			echo "tier='experimental'"
			echo "ddr_raw='0xaf'"
			echo "ddr_mhz='2100'"
			echo "vddr_mv='1480'"
			echo "vcore_mv='1060'"
			;;
		*) return 1 ;;
	esac
}

write_profile_json() {
	cat > "$PROFILE_JSON" <<EOF
{
  "profile": "$(json_escape "$1")",
  "label": "$(json_escape "$2")",
  "artifact": "$(json_escape "$3")",
  "source": "$(json_escape "$4")",
  "class": "$(json_escape "$5")",
  "ddr_raw": "$(json_escape "$6")",
  "ddr_mhz": $7,
  "vddr_mv": $8,
  "vcore_mv": $9,
  "power_note": "live PMBus input power via bridge telemetry",
  "miner_base": "G1M-v028"
}
EOF
}

remember_prior() {
	PRIOR_PROFILE_ID="${ACTIVE_PROFILE_ID:-}"
	PRIOR_PROFILE_LABEL="${ACTIVE_PROFILE_LABEL:-}"
}

set_active() {
	ACTIVE_PROFILE_ID="$1"
	ACTIVE_PROFILE_LABEL="$2"
	ACTIVE_PROFILE_CLASS="$3"
	save_state
	/usr/bin/g1m-config set active_profile_id "$1" >/dev/null 2>&1 || true
	/usr/bin/g1m-config set active_profile_label "$2" >/dev/null 2>&1 || true
	/usr/bin/g1m-config set active_profile_class "$3" >/dev/null 2>&1 || true
}

mark_good() {
	BOOT_ATTEMPTS=0
	LAST_SUCCESS_EPOCH="$(date +%s)"
	LAST_FAILURE_REASON=""
	save_state
}

apply_builtin() {
	local id="$1" label firmware profile tier ddr_raw ddr_mhz vddr_mv vcore_mv
	eval "$(profile_record "$id")" || return 1
	[ -f "$firmware" ] || return 1
	validate_profile_values "$ddr_mhz" "$vddr_mv" "$vcore_mv" "$ddr_raw" || return 1
	remember_prior
	cp "$firmware" /root/Mini-G22.bin || return 1
	write_profile_json "$profile" "$label" "$(basename "$firmware")" "builtin-profile" "$tier" "$ddr_raw" "$ddr_mhz" "$vddr_mv" "$vcore_mv"
	LAST_ARTIFACT="$(basename "$firmware")"
	set_active "$id" "$label" "$tier"
}

apply_uploaded() {
	local source="$1" manifest="$2" profile label ddr_raw ddr_mhz vddr_mv vcore_mv
	[ -f "$source" ] || return 1
	[ -f "$manifest" ] || return 1
	validate_manifest "$manifest" || return 1
	profile="$(jsonfilter -i "$manifest" -e '@.profile' 2>/dev/null || echo "uploaded-$(basename "$source")")"
	label="$(jsonfilter -i "$manifest" -e '@.label' 2>/dev/null || true)"
	[ -n "$label" ] || label="$profile"
	ddr_raw="$(jsonfilter -i "$manifest" -e '@.settings.ddr_raw_hex' 2>/dev/null || true)"
	ddr_mhz="$(jsonfilter -i "$manifest" -e '@.settings.ddr_effective_mhz' 2>/dev/null || true)"
	vddr_mv="$(jsonfilter -i "$manifest" -e '@.settings.vddr_mv' 2>/dev/null || true)"
	vcore_mv="$(jsonfilter -i "$manifest" -e '@.settings.vcore_mv' 2>/dev/null || true)"
	remember_prior
	cp "$source" /root/Mini-G22.bin || return 1
	write_profile_json "$profile" "$label" "$(basename "$source")" "uploaded-firmware" "experimental" "$ddr_raw" "$ddr_mhz" "$vddr_mv" "$vcore_mv"
	LAST_ARTIFACT="$(basename "$source")"
	set_active "uploaded-$(basename "$source")" "$label" "experimental"
}

recover_safe() {
	LAST_RECOVERY_REASON="${1:-recover-safe}"
	LAST_RECOVERY_EPOCH="$(date +%s)"
	save_state
	apply_builtin "$(safe_profile_id)"
}

case "$1" in
	apply-builtin) apply_builtin "$2" ;;
	apply-uploaded) apply_uploaded "$2" "$3" ;;
	recover-safe) recover_safe "$2" ;;
	mark-good) mark_good ;;
	*) echo "usage: $0 apply-builtin <id>|apply-uploaded <bin> <manifest>|recover-safe [reason]|mark-good" >&2; exit 1 ;;
esac
