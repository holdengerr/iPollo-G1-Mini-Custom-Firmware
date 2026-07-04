#!/bin/sh

HISTORY_FILE=/tmp/g1m-history.jsonl
TMP_FILE=/tmp/g1m-history.jsonl.tmp
STATS_FILE=/tmp/custom-miner-stats.json
SAMPLE_SECONDS="${G1M_HISTORY_SAMPLE_SECONDS:-10}"
MAX_SECONDS=$((48 * 60 * 60))
MAX_LINES=$((MAX_SECONDS / SAMPLE_SECONDS + 64))

num_field() {
	local expr="$1"
	jsonfilter -i "$STATS_FILE" -e "$expr" 2>/dev/null
}

pick_hashrate() {
	local v
	for expr in '@.cgminer_estats_hashrate' '@.cgminer_hashrate' '@.hashrate' '@.hashrate_gps_avg'; do
		v="$(num_field "$expr")"
		case "$v" in ''|null) ;; *) printf '%s\n' "$v"; return 0 ;; esac
	done
	printf '0\n'
}

pick_spm() {
	local v
	for expr in '@.shares_per_min' '@.accepted_per_min_avg' '@.accepted_per_min'; do
		v="$(num_field "$expr")"
		case "$v" in ''|null) ;; *) printf '%s\n' "$v"; return 0 ;; esac
	done
	printf '0\n'
}

sample_once() {
	local now h spm spm1 spm5 accepted rejected dups temp last_accept secs_since last_line last_t
	[ -s "$STATS_FILE" ] || return 0
	now="$(num_field '@.time')"
	case "$now" in ''|*[!0-9]*) now="$(date +%s)" ;; esac
	last_line="$(tail -n 1 "$HISTORY_FILE" 2>/dev/null || true)"
	last_t="$(printf '%s' "$last_line" | sed -n 's/.*"t":\([0-9][0-9]*\).*/\1/p')"
	[ -n "$last_t" ] && [ "$last_t" = "$now" ] && return 0
	h="$(pick_hashrate)"
	spm="$(pick_spm)"
	spm1="$(num_field '@.accepted_per_min_1m')"
	spm5="$(num_field '@.accepted_per_min_5m')"
	accepted="$(num_field '@.accepted')"
	rejected="$(num_field '@.rejected')"
	dups="$(num_field '@.duplicate_result_frames')"
	temp="$(num_field '@.chip_temp_c')"
	last_accept="$(num_field '@.last_accept_epoch')"
	secs_since="$(num_field '@.seconds_since_last_accept')"
	cat >> "$HISTORY_FILE" <<EOF
{"t":${now:-0},"h":${h:-0},"s":${spm:-0},"s1":${spm1:-0},"s5":${spm5:-0},"a":${accepted:-0},"r":${rejected:-0},"d":${dups:-0},"temp":${temp:-0},"la":${last_accept:-0},"sla":${secs_since:-0}}
EOF
	prune_history
}

prune_history() {
	local cutoff
	cutoff=$(( $(date +%s) - MAX_SECONDS ))
	awk -v cutoff="$cutoff" '{
		if (match($0, /"t":[0-9][0-9]*/)) {
			t = substr($0, RSTART + 4, RLENGTH - 4) + 0
			if (t >= cutoff) print $0
		}
	}' "$HISTORY_FILE" 2>/dev/null | tail -n "$MAX_LINES" > "$TMP_FILE" || true
	[ -s "$TMP_FILE" ] && mv "$TMP_FILE" "$HISTORY_FILE" || rm -f "$TMP_FILE"
}

json_dump() {
	if [ ! -s "$HISTORY_FILE" ]; then
		echo '[]'
		return 0
	fi
	printf '['
	awk 'NR>1{printf ","} {printf "%s",$0} END{printf "]"}' "$HISTORY_FILE"
	printf '\n'
}

run_loop() {
	mkdir -p /tmp
	while :; do
		sample_once
		sleep "$SAMPLE_SECONDS"
	done
}

case "$1" in
	run) run_loop ;;
	sample) sample_once ;;
	json) json_dump ;;
	clear) : > "$HISTORY_FILE" ;;
	*) echo "usage: $0 run|sample|json|clear" >&2; exit 1 ;;
esac
