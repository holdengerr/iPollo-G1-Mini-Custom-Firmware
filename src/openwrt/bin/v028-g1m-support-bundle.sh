#!/bin/sh

OUT_DIR=/tmp
BASENAME="g1m-support-$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="$OUT_DIR/$BASENAME"
ARCHIVE="$OUT_DIR/$BASENAME.tgz"

mkdir -p "$WORK_DIR" || exit 1

cp /tmp/custom-miner-stats.json "$WORK_DIR/custom-miner-stats.json" 2>/dev/null || true
cp /tmp/custom-miner.log "$WORK_DIR/custom-miner.log" 2>/dev/null || true
cp /tmp/g1-rail-telemetry.json "$WORK_DIR/g1-rail-telemetry.json" 2>/dev/null || true
cp /www/custom-miner-profile.json "$WORK_DIR/custom-miner-profile.json" 2>/dev/null || true
cp /root/g1m-state.env "$WORK_DIR/g1m-state.env" 2>/dev/null || true
cp /root/custom-miner-ddr-accounting.json "$WORK_DIR/custom-miner-ddr-accounting.json" 2>/dev/null || true
cp /etc/config/g1m "$WORK_DIR/config-g1m" 2>/dev/null || true
cp /etc/g1m-version "$WORK_DIR/g1m-version" 2>/dev/null || true
cp /etc/g1m-release.json "$WORK_DIR/g1m-release.json" 2>/dev/null || true
cp /tmp/g1m-history.jsonl "$WORK_DIR/g1m-history.jsonl" 2>/dev/null || true

{
	echo "generated_at=$(date -u +%FT%TZ)"
	echo "uptime=$(uptime 2>/dev/null || true)"
	echo "ps:"
	ps w 2>/dev/null || true
	echo
	echo "df:"
	df -h 2>/dev/null || true
	echo
	echo "dmesg tail:"
	dmesg | tail -n 120 2>/dev/null || true
} > "$WORK_DIR/system.txt"

tar -czf "$ARCHIVE" -C "$OUT_DIR" "$BASENAME" >/dev/null 2>&1 || exit 1
echo "$ARCHIVE"
