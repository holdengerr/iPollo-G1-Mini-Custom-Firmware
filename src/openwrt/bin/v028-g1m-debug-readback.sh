#!/bin/sh

cfg() { /usr/bin/g1m-config get "$1" "$2" 2>/dev/null; }

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

read_last_line() {
	local pattern="$1" file="$2"
	grep -aE "$pattern" "$file" 2>/dev/null | tail -n 1
}

extract_scaled_mv() {
	local line="$1" label="$2"
	printf '%s\n' "$line" | sed -n "s/.*$label 0*\\([0-9][0-9]*\\) \\/ 1000.*/\\1/p" | tail -n 1
}

extract_ddr_mhz() {
	local line="$1"
	printf '%s\n' "$line" | sed -n 's/.*Set DDR at 0*\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

extract_reset_count() {
	local line="$1"
	printf '%s\n' "$line" | sed -n 's/.*reset grin core, reset count 0*\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

derive_ddr_raw_hex() {
	local mhz="$1" raw
	case "$mhz" in ''|*[!0-9]*) return 1 ;; esac
	[ "$mhz" -gt 0 ] || return 1
	[ $((mhz % 12)) -eq 0 ] || return 1
	raw=$(( mhz / 12 ))
	[ "$raw" -ge 0 ] && [ "$raw" -le 255 ] || return 1
	printf '0x%02x\n' "$raw"
}

read_mcu_reg_dec() {
	local reg="$1" out
	[ -x /usr/bin/custom-mcu-read ] || return 1
	out="$(/usr/bin/custom-mcu-read "$reg" 2>/dev/null)" || return 1
	printf '%s\n' "$out" | sed -n 's/.*value=0x\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p' | tail -n 1 | {
		read -r hex || exit 1
		[ -n "$hex" ] || exit 1
		printf '%d\n' "0x$hex" 2>/dev/null || exit 1
	}
}

file="${1:-$(cfg debug_uart_readback_file /tmp/ttyS2-debug-raw.bin)}"
bytes="${2:-131072}"
stale_seconds="${3:-$(cfg debug_uart_readback_stale_seconds 30)}"
tmp="/tmp/g1m-debug-tail.$$"
now="$(date +%s)"

[ -r "$file" ] || {
	printf '{"ok":false,"error":"%s","source":"debug-uart","capture_file":"%s"}\n' \
		"capture file missing" "$(json_escape "$file")"
	exit 0
}

case "$stale_seconds" in ''|*[!0-9]*) stale_seconds=30 ;; esac
mtime="$(date -r "$file" +%s 2>/dev/null || echo 0)"
case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
age=$((now - mtime))
if [ "$mtime" -le 0 ] || [ "$age" -gt "$stale_seconds" ]; then
	printf '{"ok":false,"error":"%s","source":"debug-uart","capture_file":"%s","updated_epoch":%s,"age_seconds":%s}\n' \
		"capture stale" "$(json_escape "$file")" "$mtime" "$age"
	exit 0
fi

tail -c "$bytes" "$file" 2>/dev/null | strings -a -n 4 | tr '\r' '\n' > "$tmp"

vddr_line="$(read_last_line 'ISL Vddr out[[:space:]]+[0-9]+[[:space:]]+/[[:space:]]+1000' "$tmp")"
vcore_line="$(read_last_line 'ISL Vcore out[[:space:]]+[0-9]+[[:space:]]+/[[:space:]]+1000' "$tmp")"
ddr_line="$(read_last_line 'Set DDR at[[:space:]]+[0-9]+' "$tmp")"
reset_line="$(read_last_line 'reset grin core, reset count[[:space:]]+[0-9]+' "$tmp")"

vddr_mv="$(extract_scaled_mv "$vddr_line" 'ISL Vddr out')"
vcore_mv="$(extract_scaled_mv "$vcore_line" 'ISL Vcore out')"
ddr_mhz="$(extract_ddr_mhz "$ddr_line")"
core_reset_count="$(extract_reset_count "$reset_line")"
ddr_raw_hex="$(derive_ddr_raw_hex "$ddr_mhz" 2>/dev/null || true)"

if [ -z "$core_reset_count" ]; then
	core_reset_count="$(read_mcu_reg_dec 0x00006de0 2>/dev/null || true)"
fi

rm -f "$tmp"

ok=false
[ -n "$vddr_mv" ] && ok=true
[ -n "$vcore_mv" ] && ok=true
[ -n "$ddr_mhz" ] && ok=true
[ -n "$core_reset_count" ] && ok=true

printf '{"ok":%s,"source":"debug-uart","capture_file":"%s","updated_epoch":%s,"vddr_mv":%s,"vcore_mv":%s,"ddr_mhz":%s,"ddr_raw_hex":"%s","core_reset_count":%s}\n' \
	"$ok" "$(json_escape "$file")" "$mtime" "${vddr_mv:-0}" "${vcore_mv:-0}" "${ddr_mhz:-0}" "$(json_escape "$ddr_raw_hex")" "${core_reset_count:-0}"
