#!/bin/sh

device="${1:-/dev/ttyS2}"
output="${2:-/tmp/ttyS2-debug-raw.bin}"
baud="${3:-3000000}"
max_bytes="${4:-262144}"
chunk_bytes="${5:-256}"

case "$max_bytes" in ''|*[!0-9]*) max_bytes=262144 ;; esac
case "$chunk_bytes" in ''|*[!0-9]*) chunk_bytes=256 ;; esac

[ -c "$device" ] || exit 0
mkdir -p "$(dirname "$output")" 2>/dev/null || true
: > "$output"

stty -F "$device" "$baud" cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo 2>/dev/null || exit 0

while :; do
	dd if="$device" bs="$chunk_bytes" count=1 2>/dev/null >> "$output" || {
		sleep 1
		continue
	}

	size="$(wc -c < "$output" 2>/dev/null || echo 0)"
	case "$size" in ''|*[!0-9]*) size=0 ;; esac
	if [ "$size" -gt "$max_bytes" ]; then
		tmp="${output}.$$"
		tail -c "$max_bytes" "$output" > "$tmp" 2>/dev/null && mv "$tmp" "$output"
	fi
done
