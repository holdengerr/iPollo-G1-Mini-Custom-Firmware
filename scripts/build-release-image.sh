#!/usr/bin/env bash
set -euo pipefail

# Transitional release builder.
#
# This script was copied from the working release environment so the current
# image path stays reproducible while the repo split is being completed.
# Source pages, CGI, and helper scripts now live in this repo, but some vendor
# inputs and generated dependencies still come from the adjacent workspace.
#
# Expected near-term cleanup:
# - move all source asset references to this repo
# - read vendor images/rootfs from ./inputs
# - build native helper binaries from ./src/miner/native
# - generate bundled MCU profiles from documented local inputs

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${WORKSPACE_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
OUT="$ROOT/openwrt-test"
SYNC_ROOT="$ROOT/work/release-sync"
RELEASE_VERSION="${RELEASE_VERSION:-1.2.0}"
MINER_VERSION="${MINER_VERSION:-G1M-1.2.0}"
COMPAT_TAG="${COMPAT_TAG:-stock-host-h3-mini-g22}"
RELEASE_BASENAME="G1M-${RELEASE_VERSION}"
STOCK_IMG="$ROOT/firmware-images/iPolloG1-TFcard-sysupgrade-squashfs-firmware.img"
STOCK_SQFS="$ROOT/firmware-images/partitions/root_squashfs.img"
SRC_OWRT="$OUT/owrt25-rootfs-extracted"
WORK=/tmp/g1m-release-rootfs
ROOTFS="$OUT/${RELEASE_BASENAME}-rootfs.squashfs"
IMG="$OUT/${RELEASE_BASENAME}.img"
GZ="$OUT/${RELEASE_BASENAME}.img.gz"
REPORT="$ROOT/outputs/${RELEASE_BASENAME}.md"
RELEASE_DIR="$ROOT/outputs/releases/$RELEASE_VERSION"

pick_live() {
	local live_path="$1"
	local fallback_path="$2"
	if [ -f "$live_path" ]; then
		printf '%s\n' "$live_path"
	else
		printf '%s\n' "$fallback_path"
	fi
}

LIVE_CUSTOM_MINER_STATUS="$(pick_live "$SYNC_ROOT/usr-bin/custom-miner-status" "$REPO_ROOT/src/openwrt/bin/v028-custom-miner-status")"
LIVE_G1M_DEBUG_READBACK="$(pick_live "$SYNC_ROOT/usr-bin/g1m-debug-readback" "$REPO_ROOT/src/openwrt/bin/v028-g1m-debug-readback.sh")"
LIVE_G1M_HISTORY="$(pick_live "$SYNC_ROOT/usr-bin/g1m-history" "$REPO_ROOT/src/openwrt/bin/v028-g1m-history.sh")"
LIVE_G1M_APPLY_PROFILE="$(pick_live "$SYNC_ROOT/usr-bin/g1m-apply-profile" "$REPO_ROOT/src/openwrt/bin/v028-g1m-apply-profile.sh")"
LIVE_G1M_GENERATE_FIRMWARE="$(pick_live "$SYNC_ROOT/usr-bin/g1m-generate-firmware" "$REPO_ROOT/src/openwrt/bin/v028-g1m-generate-firmware.lua")"
LIVE_G1M_SUPPORT_BUNDLE="$(pick_live "$SYNC_ROOT/usr-bin/g1m-support-bundle" "$REPO_ROOT/src/openwrt/bin/v028-g1m-support-bundle.sh")"
LIVE_CUSTOM_MINER_INIT="$(pick_live "$SYNC_ROOT/init/custom-miner" "$REPO_ROOT/src/openwrt/init/custom-miner.init")"
LIVE_CUSTOM_MINER_STATUS_CGI="$(pick_live "$SYNC_ROOT/cgi-bin/custom-miner-status" "$REPO_ROOT/src/openwrt/cgi/custom-miner-status")"
LIVE_CUSTOM_MINER_HISTORY_CGI="$(pick_live "$SYNC_ROOT/cgi-bin/custom-miner-history" "$REPO_ROOT/src/openwrt/cgi/custom-miner-history")"
LIVE_G1_ADMIN_CGI="$(pick_live "$SYNC_ROOT/cgi-bin/g1-admin" "$REPO_ROOT/src/openwrt/cgi/g1-admin")"
LIVE_INDEX_HTML="$(pick_live "$SYNC_ROOT/index.html" "$REPO_ROOT/src/web/index.html")"
LIVE_METRICS_HTML="$(pick_live "$SYNC_ROOT/metrics.html" "$REPO_ROOT/src/web/metrics.html")"
LIVE_ADMIN_HTML="$(pick_live "$SYNC_ROOT/admin.html" "$REPO_ROOT/src/web/admin.html")"
LIVE_LOGIN_HTML="$(pick_live "$SYNC_ROOT/login.html" "$REPO_ROOT/src/web/login.html")"

normalize_text_file() {
	local target="$1"
	[ -f "$target" ] || return 0
	sed -i '1s/^\xEF\xBB\xBF//' "$target"
	sed -i 's/\r$//' "$target"
}

rm -rf "$WORK"
unsquashfs -q -d "$WORK" "$STOCK_SQFS" || true

cd "$WORK"

rm -f usr/bin/cgminer usr/bin/cgminer-api usr/bin/cgminer-monitor usr/bin/cgminer-monitor.sh usr/bin/cgminer.stock usr/bin/appmonitor
rm -f etc/init.d/cgminer etc/init.d/appmonitor
rm -f etc/rc.d/S99cgminer etc/rc.d/K10cgminer etc/rc.d/S99appmonitor etc/rc.d/K10appmonitor
rm -f etc/config/cgminer etc/uci-defaults/*cgminer* var/run/cgminer.pid tmp/.uci/cgminer 2>/dev/null || true
rm -f usr/lib/opkg/info/cgminer.* usr/lib/opkg/info/appmonitor.* 2>/dev/null || true
rm -f usr/lib/lua/luci/model/cbi/microcomputer/cgminerstatus.lua 2>/dev/null || true
rm -f usr/lib/lua/luci/view/microcomputer/cgminerapi.htm usr/lib/lua/luci/view/microcomputer/cgminerdebug.htm 2>/dev/null || true

cat > etc/g1m-version <<EOF
$MINER_VERSION
base=stock-vendor-rootfs
ip=192.168.1.113
miner_autostart=custom
mcu_init=custom-mcu-loader
miner_base=G1M-v022-livepatch
profile=ddr9c-isl-vddr1300-vcore1080-bridge-telemetry
rail_telemetry=mcu-bridge-pmbus-readonly
duplicate_control=adjacent-tail-quarantine
EOF

cat > etc/config/network <<'EOF'
config 'interface' 'loopback'
	option 'ifname' 'lo'
	option 'proto' 'static'
	option 'ipaddr' '127.0.0.1'
	option 'netmask' '255.0.0.0'

config 'interface' 'lan'
	option 'ifname' 'eth0'
	option 'type' 'bridge'
	option 'proto' 'dhcp'
EOF

cat > etc/config/dropbear <<'EOF'
config dropbear
	option PasswordAuth 'on'
	option RootPasswordAuth 'on'
	option RootLogin 'on'
	option Port '22'
	option MaxAuthTries '10'
EOF

cat > etc/config/g1m <<'EOF'
config miner 'core'
	option pool_coin 'grin'
	option grin_pool_url 'stratum+tcp://grin.2miners.com:3030'
	option grin_pool_user 'grin15xpsf0sdst6zncmq7vs099egmdln92qnc6v6nwmv5hse2j0ur8aq8kpf33.g1m113'
	option grin_pool_password 'x'
	option active_profile_id 'stable-1872-v1080'
	option active_profile_label 'Stable 1872 MHz / Vddr 1300 / Vcore 1080'
	option active_profile_class 'safe'
	option fan_auto '1'
	option fan_target_c '65'
	option fan_min_percent '50'
	option fan_max_percent '100'
	option fan_hard_c '70'
	option rail_telemetry_enabled '1'
	option rail_telemetry_required '0'
	option rail_telemetry_start_delay_seconds '180'
	option rail_telemetry_interval_seconds '30'
	option debug_uart_readback_enabled '0'
	option debug_uart_readback_source 'stock'
	option debug_uart_readback_file '/tmp/ttyS2-debug-raw.bin'
	option debug_uart_readback_baud '3000000'
	option debug_uart_readback_stale_seconds '30'
	option boot_health_enabled '0'
	option boot_health_grace_seconds '900'
	option boot_health_max_attempts '3'
	option support_bundle_enabled '1'
	option migrated_from_cgminer '1'
	option network_mode 'dhcp'
	option network_ipaddr '192.168.1.113'
	option network_netmask '255.255.255.0'
	option network_gateway '192.168.1.1'
	option network_dns '192.168.1.1'
EOF

cat > etc/config/system <<'EOF'
config system
	option hostname 'g1m-110'
	option timezone 'UTC'
	option ttylogin '0'
	option log_size '64'
	option urandom_seed '0'
EOF

# root/admin/iPollo password: admin. Use md5-crypt because this stock
# LuCI/dropbear stack rejects the SHA-512 crypt hashes accepted by newer Linux.
ADMIN_HASH='$1$g1mini$hWvwi3rH1ndoexzV1opZz1'
grep -q '^root:' etc/passwd || sed -i '1iroot:x:0:0:root:/root:/bin/ash' etc/passwd
grep -q '^root:' etc/shadow || sed -i "1iroot:${ADMIN_HASH}:18442:0:99999:7:::" etc/shadow
sed -i "s#^root:[^:]*:#root:${ADMIN_HASH}:#" etc/shadow
sed -i "s#^admin:[^:]*:#admin:${ADMIN_HASH}:#" etc/shadow
sed -i "s#^iPollo:[^:]*:#iPollo:${ADMIN_HASH}:#" etc/shadow

mkdir -p root/.ssh etc/dropbear tmp
install -m 0600 "$OUT/keys/g1mini_openwrt_ed25519.pub" root/.ssh/authorized_keys
install -m 0600 "$OUT/keys/g1mini_openwrt_ed25519.pub" etc/dropbear/authorized_keys

install -m 0755 "$ROOT/Custom Miner/work/custom-grin-miner-live-v028.lua" usr/bin/custom-grin-miner.lua
install -m 0755 "$SRC_OWRT/usr/bin/custom-fantach" usr/bin/custom-fantach
install -m 0755 "$SRC_OWRT/usr/bin/custom-mcu-read" usr/bin/custom-mcu-read
install -m 0755 "$ROOT/Custom Miner/outputs/bin/custom-mcu-loader" usr/bin/custom-mcu-loader
install -m 0755 "$SRC_OWRT/usr/bin/custom-pwmctl" usr/bin/custom-pwmctl
install -m 0755 "$SRC_OWRT/usr/bin/custom-serialctl" usr/bin/custom-serialctl
install -m 0755 "$SRC_OWRT/usr/bin/custom-miner-bootcheck" usr/bin/custom-miner-bootcheck
install -m 0755 "$LIVE_CUSTOM_MINER_STATUS" usr/bin/custom-miner-status
install -m 0755 "$SRC_OWRT/usr/bin/g1-debug" usr/bin/g1-debug
install -m 0755 "$SRC_OWRT/usr/bin/g1-perf-setup" usr/bin/g1-perf-setup
install -m 0755 "$ROOT/Custom Miner/outputs/bin/g1-railmon" usr/bin/g1-railmon
install -m 0755 "$OUT/v028-g1m-config.sh" usr/bin/g1m-config
install -m 0755 "$OUT/v028-g1m-policy.sh" usr/bin/g1m-policy
install -m 0755 "$OUT/v028-g1m-debug-capture.sh" usr/bin/g1m-debug-capture
install -m 0755 "$LIVE_G1M_DEBUG_READBACK" usr/bin/g1m-debug-readback
install -m 0755 "$LIVE_G1M_GENERATE_FIRMWARE" usr/bin/g1m-generate-firmware
install -m 0755 "$LIVE_G1M_SUPPORT_BUNDLE" usr/bin/g1m-support-bundle
install -m 0755 "$LIVE_G1M_HISTORY" usr/bin/g1m-history
install -m 0755 "$LIVE_G1M_APPLY_PROFILE" usr/bin/g1m-apply-profile
install -m 0755 "$OUT/v028-g1m-boot-health.sh" usr/bin/g1m-boot-health
install -m 0644 "$ROOT/outputs/v027/Mini-G22-v027-ddr9c-vddr1300-vcore1080-bridge-telemetry.bin" root/Mini-G22.bin
mkdir -p root/firmware-base
install -m 0644 "$ROOT/firmware/Mini-G22.bin" root/firmware-base/Mini-G22-base.bin
rm -f etc/rc.d/S99custom-miner etc/rc.d/K10custom-miner
install -m 0755 "$LIVE_CUSTOM_MINER_INIT" etc/init.d/custom-miner
normalize_text_file usr/bin/custom-miner-status
normalize_text_file usr/bin/g1m-debug-readback
normalize_text_file usr/bin/g1m-generate-firmware
normalize_text_file usr/bin/g1m-support-bundle
normalize_text_file usr/bin/g1m-history
normalize_text_file usr/bin/g1m-apply-profile
normalize_text_file etc/init.d/custom-miner

sed -i '/cgminer-monitor/d' etc/crontabs/root 2>/dev/null || true

mkdir -p www/cgi-bin
install -m 0755 "$LIVE_CUSTOM_MINER_STATUS_CGI" www/cgi-bin/custom-miner-status
install -m 0755 "$LIVE_CUSTOM_MINER_HISTORY_CGI" www/cgi-bin/custom-miner-history
install -m 0755 "$LIVE_G1_ADMIN_CGI" www/cgi-bin/g1-admin
normalize_text_file www/cgi-bin/custom-miner-status
normalize_text_file www/cgi-bin/custom-miner-history
normalize_text_file www/cgi-bin/g1-admin

cat > www/cgi-bin/g1-debug <<'EOF'
#!/bin/sh
echo "Content-Type: text/plain"
echo
token="$(printf '%s' "$QUERY_STRING" | sed -n 's/.*token=\([^&]*\).*/\1/p')"
cmd="$(printf '%s' "$QUERY_STRING" | sed -n 's/.*cmd=\([^&]*\).*/\1/p')"
[ "$token" = "g1mini-debug-113" ] || { echo "bad token"; exit 0; }
[ -n "$cmd" ] || cmd=bootcheck
case "$cmd" in
	bootcheck|devices|uart-test|pool|get-pool|mcu-status) ;;
	*) echo "unsupported command"; exit 0 ;;
esac
G1_DEBUG_WEB=1 /usr/bin/g1-debug "$cmd" 2>&1
EOF
chmod 0755 www/cgi-bin/g1-debug

cat > www/cgi-bin/g1-rail-telemetry <<'EOF'
#!/bin/sh
echo "Content-Type: application/json"
echo
cat /tmp/g1-rail-telemetry.json 2>/dev/null || echo '{"ok":false,"error":"rail telemetry not ready"}'
EOF
chmod 0755 www/cgi-bin/g1-rail-telemetry

cat > www/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>G1 Mini Dashboard</title>
<style>
:root{color-scheme:dark;--bg:#0d1014;--panel:#151a20;--panel2:#10151b;--line:#2a333d;--text:#e8eef5;--muted:#91a0ad;--good:#4fd083;--warn:#f0bd4e;--bad:#ef6b6b;--blue:#68a8ff}
*{box-sizing:border-box}html,body{min-height:100%}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,Arial,sans-serif}
header{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 22px;border-bottom:1px solid var(--line);background:#11161c}
h1{font-size:20px;margin:0;font-weight:650}.sub{color:var(--muted);font-size:12px}.wrap{width:100%;max-width:1760px;margin:0 auto;padding:18px}
.grid{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:12px}.tile,.panel{background:var(--panel);border:1px solid var(--line);border-radius:8px}
.tile{padding:14px;min-height:88px}.label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}.value{font-size:26px;font-weight:700;margin-top:8px;white-space:nowrap}.unit{font-size:13px;color:var(--muted);margin-left:4px}
.ok{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}.blue{color:var(--blue)}
.main{display:grid;grid-template-columns:minmax(0,3fr) minmax(300px,1fr);gap:12px;margin-top:12px}.panel{padding:14px}.panel h2{font-size:14px;margin:0;color:#cbd6df;font-weight:650}
.panel-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:10px}.ranges{display:flex;gap:6px;flex-wrap:wrap}.range{appearance:none;border:1px solid #2a333d;background:#10151b;color:var(--muted);border-radius:6px;padding:4px 8px;font:12px system-ui,Segoe UI,Arial;cursor:pointer}.range.active{border-color:#68a8ff;color:#e8eef5;background:#172334}
canvas{display:block;width:100%;height:min(58vh,620px);min-height:360px;background:var(--panel2);border:1px solid #222b34;border-radius:6px}
.rows{display:grid;gap:8px}.row{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid #202831}.row:last-child{border-bottom:0}.row span:first-child{color:var(--muted)}
.fans{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.fan{background:var(--panel2);border:1px solid #222b34;border-radius:6px;padding:10px}.fan b{display:block;font-size:20px;margin-top:4px}
.foot{margin-top:12px;color:var(--muted);font-size:12px;display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
@media(max-width:1180px){.grid{grid-template-columns:repeat(4,minmax(0,1fr))}}@media(max-width:900px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.main{grid-template-columns:1fr}.value{font-size:24px}canvas{height:420px}}@media(max-width:520px){header{align-items:flex-start;flex-direction:column}.grid{grid-template-columns:1fr}.fans{grid-template-columns:1fr}canvas{height:320px;min-height:260px}}
</style>
</head>
<body>
<header><div><h1>G1 Mini</h1><div class="sub">v022 custom miner dashboard</div></div><div id="state" class="sub">loading</div></header>
<main class="wrap">
  <section class="grid">
    <div class="tile"><div class="label">Hashrate</div><div class="value"><span id="hashrate">--</span><span class="unit" id="hashunit">G/s</span></div></div>
    <div class="tile"><div class="label">Shares / Min</div><div class="value"><span id="spm">--</span></div></div>
    <div class="tile"><div class="label">Shares 5m</div><div class="value"><span id="spm5">--</span></div></div>
    <div class="tile"><div class="label">Shares 1m</div><div class="value"><span id="spm1">--</span></div></div>
    <div class="tile"><div class="label">Chip Temp</div><div class="value"><span id="temp">--</span><span class="unit">C</span></div></div>
    <div class="tile"><div class="label">Fan Avg</div><div class="value"><span id="fanavg">--</span><span class="unit">rpm</span></div></div>
    <div class="tile"><div class="label">Rejected</div><div class="value"><span id="rejectpct">--</span><span class="unit">%</span></div></div>
  </section>
  <section class="main">
    <div class="panel"><div class="panel-head"><h2>Mining Trend</h2><div class="ranges"><button class="range active" data-range="900">15m</button><button class="range" data-range="1800">30m</button><button class="range" data-range="3600">1h</button></div></div><canvas id="chart" width="1200" height="560"></canvas><div class="foot"><span>Blue: cgminer-style hashrate</span><span>Green: overall shares/min</span></div></div>
    <div class="panel"><h2>Runtime</h2><div class="rows">
      <div class="row"><span>Status</span><b id="runstatus">--</b></div>
      <div class="row"><span>Elapsed</span><b id="elapsed">--</b></div>
      <div class="row"><span>Accepted</span><b id="accepted">--</b></div>
      <div class="row"><span>Rejected</span><b id="rejected">--</b></div>
      <div class="row"><span>Duplicates</span><b id="duplicates">--</b></div>
      <div class="row"><span>DDR</span><b id="ddr">--</b></div>
      <div class="row"><span>Pool</span><b id="pool">--</b></div>
      <div class="row"><span>Last Accept</span><b id="lastaccept">--</b></div>
    </div></div>
  </section>
  <section class="main">
    <div class="panel"><h2>Fans</h2><div class="fans" id="fans"></div></div>
    <div class="panel"><h2>Health</h2><div class="rows">
      <div class="row"><span>UART ACK/NACK</span><b id="uartHealth">--</b></div>
      <div class="row"><span>Frame resync</span><b id="frameHealth">--</b></div>
      <div class="row"><span>Unknowns</span><b id="unknowns">--</b></div>
      <div class="row"><span>Stale suppressed</span><b id="staleSuppressed">--</b></div>
      <div class="row"><span>Submit errors</span><b id="submitErrors">--</b></div>
      <div class="row"><span>Adjacent refreshes</span><b id="adjacentRefreshes">--</b></div>
      <div class="row"><span>Fault</span><b id="fault">--</b></div>
      <div class="row"><span>MCU resets</span><b id="mcuResets">--</b></div>
      <div class="row"><span>Stratum reconnects</span><b id="reconnects">--</b></div>
    </div></div>
  </section>
  <div class="foot"><span id="updated">never updated</span><span><a href="/cgi-bin/custom-miner-status">raw json</a></span></div>
</main>
<script>
const sampleSeconds=10, maxStoredSeconds=3600, storageKey="g1mini_dashboard_history_v1"; let selectedRange=900;
const hist=loadHist();
const $=id=>document.getElementById(id);
function num(v,d=0){v=Number(v);return Number.isFinite(v)?v:d}
function hasNum(v){return Number.isFinite(Number(v))}
function numOr(v,d=0){return hasNum(v)?Number(v):d}
function fmt(v,d=2){return Number.isFinite(Number(v))?Number(v).toFixed(d):"--"}
function sumObj(o){let n=0;if(o&&typeof o==="object")for(const k in o)n+=num(o[k]);return n}
function rel(ts){ts=num(ts);if(!ts)return"--";let s=Math.max(0,Math.floor(Date.now()/1000-ts));if(s<60)return s+"s ago";let m=Math.floor(s/60);if(m<60)return m+"m ago";return Math.floor(m/60)+"h ago"}
function dur(sec){sec=Math.max(0,Math.floor(num(sec)));let h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60),s=sec%60;if(h)return h+"h "+String(m).padStart(2,"0")+"m";if(m)return m+"m "+String(s).padStart(2,"0")+"s";return s+"s"}
function pickShares(s){return num(s.shares_per_min)||num(s.accepted_per_min_avg)||num(s.accepted_per_min)||0}
function pickHashrate(s){return num(s.cgminer_estats_hashrate)||num(s.cgminer_hashrate)||num(s.hashrate)||num(s.hashrate_gps_avg)||0}
function pickHashUnit(s){return s.cgminer_hashrate_unit||s.hashrate_unit||"G/s"}
function loadHist(){try{let a=JSON.parse(localStorage.getItem(storageKey)||"[]");let cutoff=Date.now()/1000-maxStoredSeconds;return Array.isArray(a)?a.filter(p=>num(p.t)>cutoff&&hasNum(p.h)&&hasNum(p.s)).slice(-Math.ceil(maxStoredSeconds/sampleSeconds)-6):[]}catch(e){return[]}}
function saveHist(){try{localStorage.setItem(storageKey,JSON.stringify(hist.slice(-Math.ceil(maxStoredSeconds/sampleSeconds)-6)))}catch(e){}}
function setRange(sec){selectedRange=sec;document.querySelectorAll(".range").forEach(b=>b.classList.toggle("active",num(b.dataset.range)===sec));draw()}
document.querySelectorAll(".range").forEach(b=>b.addEventListener("click",()=>setRange(num(b.dataset.range,900))));
function draw(){
 const c=$("chart"),rect=c.getBoundingClientRect(),dpr=Math.max(1,window.devicePixelRatio||1);
 const cssW=Math.max(320,Math.floor(rect.width)),cssH=Math.max(240,Math.floor(rect.height));
 if(c.width!==Math.floor(cssW*dpr)||c.height!==Math.floor(cssH*dpr)){c.width=Math.floor(cssW*dpr);c.height=Math.floor(cssH*dpr)}
 const x=c.getContext("2d"),w=cssW,h=cssH,pl=58,pr=58,pt=14,pb=34,gw=w-pl-pr,gh=h-pt-pb;
 x.setTransform(dpr,0,0,dpr,0,0);
 x.clearRect(0,0,w,h); x.font="12px system-ui,Segoe UI,Arial"; x.textBaseline="middle";
 const now=Date.now()/1000, visible=hist.filter(p=>p.t>=now-selectedRange);
 const points=visible.length?visible:hist.slice(-1);
 const vals=(key)=>points.map(p=>num(p[key])).filter(Number.isFinite);
 const axis=(arr)=>{if(!arr.length)return{min:0,max:1};let mn=Math.min(...arr),mx=Math.max(...arr);if(mn===mx){let pad=Math.max(Math.abs(mx)*0.05,0.05);return{min:mn-pad,max:mx+pad}}let pad=(mx-mn)*0.12;return{min:mn-pad,max:mx+pad}};
 const hAxis=axis(vals("h")), sAxis=axis(vals("s"));
 x.strokeStyle="#24303a"; x.fillStyle="#91a0ad"; x.lineWidth=1;
 for(let i=0;i<=4;i++){
   let y=pt+gh*i/4, hv=hAxis.max-(hAxis.max-hAxis.min)*i/4, sv=sAxis.max-(sAxis.max-sAxis.min)*i/4;
   x.beginPath(); x.moveTo(pl,y); x.lineTo(pl+gw,y); x.stroke();
   x.fillText(hv.toFixed(hv<10?1:0),8,y); x.fillText(sv.toFixed(sv<10?1:0),pl+gw+10,y);
 }
 x.textBaseline="alphabetic"; x.fillStyle="#68a8ff"; x.fillText("hash",8,12); x.fillStyle="#4fd083"; x.fillText("shares/min",pl+gw-5,12);
 x.fillStyle="#91a0ad"; x.textAlign="center";
 for(let i=0;i<=4;i++){
   let px=pl+gw*i/4, secAgo=(4-i)*selectedRange/4, label=secAgo<60?("-"+Math.round(secAgo)+"s"):("-"+Math.round(secAgo/60)+"m");
   x.beginPath(); x.moveTo(px,pt+gh); x.lineTo(px,pt+gh+5); x.stroke(); x.fillText(i===4?"now":label,px,h-10);
 }
 x.textAlign="left";
 function line(key,ax,color){x.strokeStyle=color;x.lineWidth=2;x.beginPath();let started=false;points.forEach(p=>{let px=pl+((p.t-(now-selectedRange))/selectedRange)*gw;let py=pt+gh-((p[key]-ax.min)/(ax.max-ax.min))*gh;if(started)x.lineTo(px,py);else{x.moveTo(px,py);started=true}});x.stroke()}
 line("h",hAxis,"#68a8ff"); line("s",sAxis,"#4fd083");
}
function render(s){
 const h=pickHashrate(s), spm=pickShares(s), temp=num(s.fan_control_temp_c)||num(s.temp)||((s.board_temps_c&&s.board_temps_c[0])?num(s.board_temps_c[0]):0);
 const spm5=num(s.accepted_per_min_5m), spm1=num(s.accepted_per_min_1m);
 const fans=Array.isArray(s.fan_rpm)?s.fan_rpm.map(Number).filter(Number.isFinite):[]; const favg=fans.length?fans.reduce((a,b)=>a+b,0)/fans.length:0;
 const accepted=numOr(s.accepted,sumObj(s.accepted_by_ddr)), rejected=numOr(s.rejected,sumObj(s.rejected_by_ddr)), submitErrors=numOr(s.submit_error,numOr(s.submit_errors,sumObj(s.submit_errors_by_ddr)));
 const rejectPct=(accepted+rejected+submitErrors)>0?100*(rejected+submitErrors)/(accepted+rejected+submitErrors):0;
 $("hashrate").textContent=fmt(h,2); $("hashunit").textContent=pickHashUnit(s); $("spm").textContent=fmt(spm,2); $("spm5").textContent=fmt(spm5,2); $("spm1").textContent=fmt(spm1,2); $("temp").textContent=temp?fmt(temp,1):"--"; $("fanavg").textContent=favg?Math.round(favg):"--"; $("rejectpct").textContent=fmt(rejectPct,1);
 $("runstatus").textContent=s.status||((num(s.seconds_since_valid_job,999)<120)?"running":"waiting"); $("elapsed").textContent=dur(s.uptime_seconds); $("accepted").textContent=accepted; $("rejected").textContent=rejected+submitErrors; $("duplicates").textContent=numOr(s.duplicates,numOr(s.duplicate_result_frames,sumObj(s.duplicates_by_ddr)));
 $("ddr").textContent=(s.mcu_ddr_raw_hex||"--")+" / "+(s.mcu_ddr_effective_mhz||s.mcu_ddr_effective||"--")+" MHz"; $("pool").textContent=s.configured_pool_url||s.pool_url||"configured"; $("lastaccept").textContent=rel(s.last_accept_epoch);
 $("uartHealth").textContent=num(s.uart_result_acks)+"/"+num(s.uart_result_nacks); $("frameHealth").textContent=num(s.crc_resync)+" resync, "+num(s.crc_resync_recovered_frames)+" recovered"; $("unknowns").textContent=numOr(s.unknowns,numOr(s.unknown_result_frames,sumObj(s.unknowns_by_ddr))); $("staleSuppressed").textContent=num(s.stale_submit_suppressed); $("submitErrors").textContent=submitErrors; $("adjacentRefreshes").textContent=num(s.adjacent_duplicate_result_refreshes); $("fault").textContent=s.fault?(Array.isArray(s.fault_reasons)?s.fault_reasons.join(", "):"yes"):"no"; $("mcuResets").textContent=num(s.mcu_progress_counter_resets); $("reconnects").textContent=num(s.stratum_reconnects);
 $("fans").innerHTML=(fans.length?fans:[0,0,0,0]).map((v,i)=>'<div class="fan"><span class="label">Fan '+(i+1)+'</span><b>'+(v?Math.round(v):"--")+'</b><span class="sub">rpm</span></div>').join("");
 $("state").textContent="online"; $("state").className="sub ok"; $("updated").textContent="updated "+new Date().toLocaleTimeString();
 const now=Date.now()/1000, last=hist[hist.length-1]; if(!last||now-last.t>=sampleSeconds*0.8){hist.push({t:now,h:h,s:spm}); while(hist.length>Math.ceil(maxStoredSeconds/sampleSeconds)+6)hist.shift(); saveHist()}else{last.t=now;last.h=h;last.s=spm}
 draw();
}
async function tick(){try{let r=await fetch("/cgi-bin/custom-miner-status",{cache:"no-store"});render(await r.json())}catch(e){$("state").textContent="status unavailable";$("state").className="sub bad"}}
tick(); setInterval(tick,10000); window.addEventListener("resize",draw);
</script>
</body>
</html>
EOF

install -m 0644 "$LIVE_INDEX_HTML" www/index.html
install -m 0644 "$LIVE_METRICS_HTML" www/metrics.html
install -m 0644 "$LIVE_ADMIN_HTML" www/admin.html
install -m 0644 "$LIVE_LOGIN_HTML" www/login.html
mkdir -p root/profiles
install -m 0644 "$ROOT/outputs/v027/Mini-G22-v027-ddr9c-vddr1300-vcore1080-bridge-telemetry.bin" root/profiles/Mini-G22-stable-1872-v1080.bin
install -m 0644 "$ROOT/outputs/freq-voltage-tests/Mini-G22-ddra7-isl-vddr1300-vcore1080-bridge-telemetry.bin" root/profiles/Mini-G22-perf-2004-v1080.bin
install -m 0644 "$ROOT/outputs/pc-generated-firmware/Mini-G22-2100-1480-1060.bin" root/profiles/Mini-G22-exp-2100-vddr1480-vcore1060.bin
cat > etc/g1m-release.json <<EOF
{
  "firmware_version": "$RELEASE_VERSION",
  "miner_version": "$MINER_VERSION",
  "compatibility_tag": "$COMPAT_TAG",
  "build_date_utc": "__BUILD_DATE_UTC__",
  "git_commit": "__GIT_COMMIT__",
  "config_model": "g1m-uci-v1"
}
EOF
sed -i "s/__BUILD_DATE_UTC__/$(date -u '+%Y-%m-%dT%H:%M:%SZ')/" etc/g1m-release.json
sed -i "s/__GIT_COMMIT__/$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)/" etc/g1m-release.json
cat > www/custom-miner-profile.json <<EOF
{
  "profile": "ddr9c-isl-vddr1300-vcore1080-bridge-telemetry",
  "label": "Stable 1872 MHz / Vddr 1300 / Vcore 1080",
  "ddr_raw": "0x9c",
  "ddr_mhz": 1872,
  "vddr_mv": 1300,
  "vcore_mv": 1080,
  "power_w": "PMBus input power via delayed rail telemetry helper",
  "miner_base": "$MINER_VERSION",
  "mcu_bridge": "read-only PMBus telemetry bridge enabled after startup delay"
}
EOF
cat > root/g1m-state.env <<'EOF'
ACTIVE_PROFILE_ID='stable-1872-v1080'
ACTIVE_PROFILE_LABEL='Stable 1872 MHz / Vddr 1300 / Vcore 1080'
ACTIVE_PROFILE_CLASS='safe'
PRIOR_PROFILE_ID=''
PRIOR_PROFILE_LABEL=''
LAST_ARTIFACT='Mini-G22-stable-1872-v1080.bin'
BOOT_ATTEMPTS='0'
LAST_SUCCESS_EPOCH='0'
LAST_RECOVERY_REASON=''
LAST_RECOVERY_EPOCH='0'
LAST_FAILURE_REASON=''
EOF
chmod 0600 root/g1m-state.env

if [ -x www/cgi-bin/luci ] && [ ! -e www/cgi-bin/luci-stock ]; then
	mv www/cgi-bin/luci www/cgi-bin/luci-stock
fi
cat > www/cgi-bin/luci <<'EOF'
#!/bin/sh
printf 'Status: 302 Found\r\n'
printf 'Location: /\r\n'
printf 'Content-Type: text/plain\r\n'
printf '\r\n'
printf 'redirecting to G1 Mini dashboard\n'
EOF
chmod 0755 www/cgi-bin/luci

cat > etc/rc.local <<EOF
# G1M-v028 minimal boot marker and bridge route fix.
sleep 3
sysctl -p >/tmp/g1m-sysctl.log 2>&1 || true

(
	sleep 20
	echo $MINER_VERSION >/tmp/${MINER_VERSION}-booted
	rm -f /etc/rc.d/S99cgminer /etc/rc.d/K10cgminer 2>/dev/null || true
	sed -i '/cgminer-monitor/d' /etc/crontabs/root 2>/dev/null || true
	for svc in cron rpcd odhcpd dnsmasq firewall; do
		/etc/init.d/\$svc stop >/dev/null 2>&1 || true
	done
	ip link set eth0 up 2>/dev/null || true
	ip route del default dev eth0 2>/dev/null || true
	mode="$(uci -q get g1m.core.network_mode 2>/dev/null || echo dhcp)"
	if [ "\$mode" = "static" ]; then
		ip addr del 192.168.1.113/24 dev eth0 2>/dev/null || true
		gateway="$(uci -q get g1m.core.network_gateway 2>/dev/null || echo 192.168.1.1)"
		[ -n "\$gateway" ] && ip route replace default via "\$gateway" dev br-lan 2>/dev/null || true
	fi
	mkdir -p /root/.ssh
	cp /etc/dropbear/authorized_keys /root/.ssh/authorized_keys 2>/dev/null || true
	chmod 700 /root/.ssh 2>/dev/null || true
	chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys 2>/dev/null || true
	/etc/init.d/dropbear start >/tmp/g1m-dropbear-start.log 2>&1 || true
	/etc/init.d/uhttpd start >/tmp/g1m-uhttpd-start.log 2>&1 || true
	logger -t ${MINER_VERSION} "boot marker reached, network mode \${mode}"
) &

exit 0
EOF
chmod 0755 etc/rc.local

mkdir -p etc/rc.d
for link in \
	K10gpio_switch:gpio_switch K50dropbear:dropbear K89log:log K90network:network K90sysfixtime:sysfixtime K98boot:boot K99umount:umount \
	S00sysfixtime:sysfixtime S10boot:boot S10system:system S11sysctl:sysctl S12log:log \
	S20network:network S50dropbear:dropbear S50uhttpd:uhttpd S94gpio_switch:gpio_switch S95done:done \
	S96led:led S97factest:factest S98sysntpd:sysntpd S99custom-miner:custom-miner S99urandom_seed:urandom_seed
do
	name="${link%%:*}"
	target="${link#*:}"
	ln -sfn "../init.d/$target" "etc/rc.d/$name"
done
rm -f etc/rc.d/K10factest etc/rc.d/S99cgminer etc/rc.d/K10cgminer etc/rc.d/S99appmonitor etc/rc.d/K10appmonitor
rm -f etc/rc.d/S12rpcd etc/rc.d/S19dnsmasq etc/rc.d/S19firewall etc/rc.d/S35odhcpd etc/rc.d/S50cron etc/rc.d/K85odhcpd

cd /
find "$WORK/dev" \( -type c -o -type b \) -delete 2>/dev/null || true
mksquashfs "$WORK" "$ROOTFS" -noappend -comp xz -b 262144 -all-root >/tmp/g1m-release-mksquashfs.log
ROOTFS_SIZE="$(stat -c '%s' "$ROOTFS")"
SPI_ROOTFS_LIMIT=$((0x00bf0000))
SPI_TOTAL_SIZE=$((16 * 1024 * 1024))
if [ "$ROOTFS_SIZE" -gt "$SPI_ROOTFS_LIMIT" ]; then
	echo "ERROR: rootfs payload $ROOTFS_SIZE exceeds SPI rootfs partition limit $SPI_ROOTFS_LIMIT" >&2
	exit 1
fi
cp "$STOCK_IMG" "$IMG"
dd if="$ROOTFS" of="$IMG" bs=512 seek=36864 conv=notrunc status=none
gzip -c -9 "$IMG" > "$GZ"

ROOTFS_HASH="$(sha256sum "$ROOTFS" | awk '{print $1}')"
IMG_HASH="$(sha256sum "$IMG" | awk '{print $1}')"
GZ_HASH="$(sha256sum "$GZ" | awk '{print $1}')"
IMG_SIZE="$(stat -c '%s' "$IMG")"
GZ_SIZE="$(stat -c '%s' "$GZ")"

cat > "$REPORT" <<EOF
# ${RELEASE_BASENAME} Stock-Based Miner Flasher Image

Built: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

## Files

- \`$IMG\`
- \`$GZ\`
- \`$ROOTFS\`

## Hashes

- \`${RELEASE_BASENAME}-rootfs.squashfs\`: \`$ROOTFS_HASH\`
- \`${RELEASE_BASENAME}.img\`: \`$IMG_HASH\`
- \`${RELEASE_BASENAME}.img.gz\`: \`$GZ_HASH\`

## Sizes

- rootfs: \`$ROOTFS_SIZE\`
- img: \`$IMG_SIZE\`
- img.gz: \`$GZ_SIZE\`
- SPI total: \`$SPI_TOTAL_SIZE\`
- SPI rootfs partition limit: \`$SPI_ROOTFS_LIMIT\`
- SPI rootfs spare bytes: \`$((SPI_ROOTFS_LIMIT - ROOTFS_SIZE))\`

## Behavior

- Release version: \`$RELEASE_VERSION\`
- Miner version: \`$MINER_VERSION\`
- Compatibility tag: \`$COMPAT_TAG\`
- Base: stock vendor SD image/rootfs, not OpenWrt 25 rootfs.
- This is the public release image. Booting this image from SD restores the stock \`factest\` autostart path so it writes the image's \`rootfs\`, \`kernel\`, \`dtb\`, and \`u-boot\` sections into internal SPI-NOR.
- Internal SPI-NOR fit check: the build fails if the release rootfs exceeds the live \`rootfs\` MTD partition size \`0x00bf0000\`; the full SD image is larger than 16 MB because it is only the source container.
- Network defaults to DHCP, with optional static IP settings available from the admin page.
- SSH and stock LuCI root/admin/iPollo password: \`admin\`.
- SSH key auth also installed.
- Custom miner and debug helpers installed.
- Proper custom dashboard installed at \`/\` with cgminer-style hashrate, lifetime/5m/1m shares/min, temperature, fan RPM, rejected percentage, elapsed time, and live trend graph.
- Dashboard graph includes 15m/30m/1h/6h/24h windows, 48h on-miner history, and range-focused vertical scaling.
- Dashboard replaces per-fan RPM cards with operator activity telemetry: valid-job age, work-refresh age, result-frame age, rail monitor state, and cooling target.
- Dashboard health panel is simplified to end-user summaries: overall status, share path, UART link, controller state, and fault reason.
- Fan auto-control defaults to on: target \`65C\`, minimum \`50%\`, hard limit \`70C\`.
- Runtime load is reduced by default: dashboard polling \`10s\`, miner stats writes \`10s\`, fan control \`20s\`, PWM reapply \`120s\`, sensor polling \`10s\`, MCU DDR polling \`60s\`.
- Red status LED is off during normal mining and turns on only for miner fault conditions; reset LEDs are not used for status.
- Diagnostic sample buffers are capped by default to keep overnight stats JSON small.
- Runtime stats and persisted DDR accounting are flushed on miner startup by default so a previous run cannot seed stale dashboard values.
- Unused stock services are disabled for this single-purpose image: \`rpcd\`, \`dnsmasq\`, \`firewall\`, \`odhcpd\`, and \`cron\`.
- Work refresh policy keeps no dwell/soft refresh, uses a 20s result refresh guard, duplicate threshold 8, adjacent duplicate burst threshold 2 within 90s, a 20s adjacent duplicate quarantine window, and a 30s minimum accept-age before adjacent refresh is allowed.
- Web debug CGI is limited to fixed diagnostic commands; arbitrary command dispatch is disabled.
- \`/cgi-bin/luci\` redirects to the custom dashboard; stock LuCI is preserved at \`/cgi-bin/luci-stock\`.
- Patched \`Mini-G22.bin\` is the tested \`ddr9c-isl-vddr1300-vcore1080\` image plus the read-only MCU bridge telemetry patch.
- Custom miner suppresses immediate stock-style repeated result CRC frames and exposes \`duplicate_stock_adjacent_repeat\`.
- Custom miner adds a tagged mid4 nonce alias for result matching. This targets unknown frames where nonce bytes 3-6 match sent work while outer nonce bytes advance in the ASIC result stream.
- Custom miner keeps v016's CRC-bad frame behavior: bad \`0x04\` result frames are NACKed/dropped and embedded \`ff55\` candidates are never recovered into the parser.
- Custom miner records CRC diagnostic counters: embedded-header candidates, invalid CRC candidates, unknown command candidates, short-buffer candidates, discarded bytes, and early/mid/tail embedded-header buckets.
- Custom miner uses a 30 ms default inter-work-frame delay to reduce UART/ASIC burst pressure.
- Custom miner suppresses stale pool submits before they hit stratum when a result belongs to an old reconnect generation, exceeds the submit-age limit, or trails the current pool job beyond the grace window.
- This release is built from the miner currently running on the device: the preserved \`G1M-v022-livepatch\` Lua core with the current delayed-railmon service wrapper.
- This release keeps the stable default miner startup on \`lane_mode=1\`; the v020 all-lane trial showed the result lane byte tracks the work nonce F4 byte rather than a separate usable work lane.
- This release force-loads the MCU firmware on bus 0 at miner start so a restart recovers UART status/result traffic after failed lane experiments.
- This release records additional adjacent-duplicate phase telemetry so repeated result frames can be separated into before-submit, after-submit, after-reject, and rollover-driven buckets.
- This release adds a short stock-tail quarantine for repeated adjacent duplicate result frames so known repeats stop provoking result-refresh churn while accepted shares are still flowing.
- This release only allows adjacent-duplicate refreshes after a real accept drought, instead of refreshing purely on duplicate count.
- This release keeps the delayed, low-rate read-only MCU bridge telemetry helper for PMBus rail telemetry so miner/MCU startup stays isolated.
- Custom miner avoids redundant immediate stats writes inside duplicate suppression paths; the normal frame-level stats write still records the event.
- Custom MCU loader handles MCU firmware load directly with the stock-compatible I2C write semantics; no cgminer MCU preload fallback is used.
- Custom miner autostart is on.
- Stock \`factest\` autostart is intentionally enabled in this release image because the goal is to update internal SPI-NOR from SD.
- Stock \`cgminer\`, \`cgminer-api\`, \`cgminer-monitor\`, and \`appmonitor\` binaries are removed from the rootfs.
- Pool, fan, telemetry, and profile settings now live in dedicated \`/etc/config/g1m\`; vendor \`cgminer.default\` is no longer the primary runtime config store.
- Admin login defaults to \`admin/admin\` and stays authenticated by browser cookie session.
- Default route is corrected to \`br-lan\` after boot; the extra \`eth0\` address is removed.
- Pool is baked to \`stratum+tcp://grin.2miners.com:3030\` with worker \`grin15xpsf0sdst6zncmq7vs099egmdln92qnc6v6nwmv5hse2j0ur8aq8kpf33.g1m113\`.
- OpenWrt 25.12 is not promoted to this mining image because the modern stack still needs ASIC UART/mining validation before it can be considered production-safe.

## First Checks

\`\`\`powershell
ping 192.168.1.113
ssh root@192.168.1.113
curl.exe -sS "http://192.168.1.113/cgi-bin/g1-debug?token=g1mini-debug-113&cmd=bootcheck"
\`\`\`
EOF

mkdir -p "$RELEASE_DIR"
cp "$IMG" "$RELEASE_DIR/${RELEASE_BASENAME}.img"
cp "$GZ" "$RELEASE_DIR/${RELEASE_BASENAME}.img.gz"
cp "$ROOTFS" "$RELEASE_DIR/${RELEASE_BASENAME}-rootfs.squashfs"
cat > "$RELEASE_DIR/checksums.txt" <<EOF
$ROOTFS_HASH  ${RELEASE_BASENAME}-rootfs.squashfs
$IMG_HASH  ${RELEASE_BASENAME}.img
$GZ_HASH  ${RELEASE_BASENAME}.img.gz
EOF
cat > "$RELEASE_DIR/manifest.json" <<EOF
{
  "version": "$RELEASE_VERSION",
  "miner_version": "$MINER_VERSION",
  "compatibility_tag": "$COMPAT_TAG",
  "build_date_utc": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "git_commit": "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)",
  "artifacts": [
    {"name":"${RELEASE_BASENAME}-rootfs.squashfs","sha256":"$ROOTFS_HASH","size":$ROOTFS_SIZE},
    {"name":"${RELEASE_BASENAME}.img","sha256":"$IMG_HASH","size":$IMG_SIZE},
    {"name":"${RELEASE_BASENAME}.img.gz","sha256":"$GZ_HASH","size":$GZ_SIZE}
  ],
  "safe_profile": {
    "id": "stable-1872-v1080",
    "label": "Stable 1872 MHz / Vddr 1300 / Vcore 1080"
  },
  "balanced_profile": {
    "id": "perf-2004-v1080",
    "label": "Performance 2004 MHz / Vddr 1300 / Vcore 1080"
  },
  "experimental_profile": {
    "id": "exp-2100-vddr1480-vcore1060",
    "label": "Experimental 2100 MHz / Vddr 1480 / Vcore 1060"
  }
}
EOF
cp "$OUT/public-release/recovery.md" "$RELEASE_DIR/recovery.md"
cp "$OUT/public-release/installation.md" "$RELEASE_DIR/installation.md"
cp "$OUT/public-release/profile-guide.md" "$RELEASE_DIR/profile-guide.md"
cp "$OUT/public-release/safe-tuning.md" "$RELEASE_DIR/safe-tuning.md"
cp "$OUT/public-release/known-limitations.md" "$RELEASE_DIR/known-limitations.md"
cp "$OUT/public-release/support-matrix.md" "$RELEASE_DIR/support-matrix.md"
cp "$OUT/public-release/qualification-matrix.md" "$RELEASE_DIR/qualification-matrix.md"
cp "$OUT/public-release/release-notes-template.md" "$RELEASE_DIR/release-notes.md"

echo "$GZ"
echo "$GZ_HASH"
