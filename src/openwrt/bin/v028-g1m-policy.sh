#!/bin/sh

safe_profile_id() { echo "stable-1872-v1080"; }
safe_profile_label() { echo "Stable 1872 MHz / Vddr 1300 / Vcore 1080"; }
safe_profile_class() { echo "safe"; }
safe_profile_firmware() { echo "/root/profiles/Mini-G22-stable-1872-v1080.bin"; }
custom_ddr_min_mhz() { echo "1872"; }
custom_ddr_max_mhz() { echo "2220"; }
custom_vddr_min_mv() { echo "1200"; }
custom_vddr_max_mv() { echo "1600"; }
custom_vcore_min_mv() { echo "1000"; }
custom_vcore_max_mv() { echo "1100"; }

is_int() {
	case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

hex_to_dec() {
	printf '%d\n' "$(( $1 ))" 2>/dev/null
}

validate_raw_hex() {
	local raw="$1" dec
	case "$raw" in 0x*|0X*) ;; *) return 1 ;; esac
	dec="$(hex_to_dec "$raw" 2>/dev/null || true)"
	is_int "$dec" || return 1
	return 0
}

validate_profile_values() {
	local ddr_mhz="$1" vddr_mv="$2" vcore_mv="$3" ddr_raw="${4:-}"
	is_int "$ddr_mhz" || return 1
	is_int "$vddr_mv" || return 1
	is_int "$vcore_mv" || return 1
	[ -z "$ddr_raw" ] || validate_raw_hex "$ddr_raw" || return 1
	return 0
}

validate_custom_oc_values() {
	local ddr_mhz="$1" vddr_mv="$2" vcore_mv="$3"
	validate_profile_values "$ddr_mhz" "$vddr_mv" "$vcore_mv" || return 1
	[ $((ddr_mhz % 12)) -eq 0 ] || return 1
	[ "$ddr_mhz" -ge "$(custom_ddr_min_mhz)" ] && [ "$ddr_mhz" -le "$(custom_ddr_max_mhz)" ] || return 1
	[ "$vddr_mv" -ge "$(custom_vddr_min_mv)" ] && [ "$vddr_mv" -le "$(custom_vddr_max_mv)" ] || return 1
	[ "$vcore_mv" -ge "$(custom_vcore_min_mv)" ] && [ "$vcore_mv" -le "$(custom_vcore_max_mv)" ] || return 1
	[ $((vddr_mv % 2)) -eq 0 ] || return 1
	[ $((vcore_mv % 2)) -eq 0 ] || return 1
	return 0
}

validate_manifest() {
	local manifest="$1"
	local profile ddr_raw ddr_mhz vddr_mv vcore_mv
	[ -f "$manifest" ] || return 1
	profile="$(jsonfilter -i "$manifest" -e '@.profile' 2>/dev/null || true)"
	ddr_raw="$(jsonfilter -i "$manifest" -e '@.settings.ddr_raw_hex' 2>/dev/null || true)"
	ddr_mhz="$(jsonfilter -i "$manifest" -e '@.settings.ddr_effective_mhz' 2>/dev/null || true)"
	vddr_mv="$(jsonfilter -i "$manifest" -e '@.settings.vddr_mv' 2>/dev/null || true)"
	vcore_mv="$(jsonfilter -i "$manifest" -e '@.settings.vcore_mv' 2>/dev/null || true)"
	[ -n "$profile" ] || return 1
	validate_profile_values "$ddr_mhz" "$vddr_mv" "$vcore_mv" "$ddr_raw"
}

case "$1" in
	validate_manifest)
		validate_manifest "$2"
		;;
	validate_profile_values)
		validate_profile_values "$2" "$3" "$4" "$5"
		;;
	validate_custom_oc_values)
		validate_custom_oc_values "$2" "$3" "$4"
		;;
	safe_profile_id)
		safe_profile_id
		;;
	safe_profile_label)
		safe_profile_label
		;;
	safe_profile_class)
		safe_profile_class
		;;
	safe_profile_firmware)
		safe_profile_firmware
		;;
	custom_ddr_min_mhz)
		custom_ddr_min_mhz
		;;
	custom_ddr_max_mhz)
		custom_ddr_max_mhz
		;;
	custom_vddr_min_mv)
		custom_vddr_min_mv
		;;
	custom_vddr_max_mv)
		custom_vddr_max_mv
		;;
	custom_vcore_min_mv)
		custom_vcore_min_mv
		;;
	custom_vcore_max_mv)
		custom_vcore_max_mv
		;;
	""|source-only)
		;;
	*)
		echo "usage: $0 validate_manifest <path>|validate_profile_values <ddr_mhz> <vddr_mv> <vcore_mv> [ddr_raw]|validate_custom_oc_values <ddr_mhz> <vddr_mv> <vcore_mv>|safe_profile_id|safe_profile_label|safe_profile_class|safe_profile_firmware|custom_ddr_min_mhz|custom_ddr_max_mhz|custom_vddr_min_mv|custom_vddr_max_mv|custom_vcore_min_mv|custom_vcore_max_mv" >&2
		exit 1
		;;
esac
