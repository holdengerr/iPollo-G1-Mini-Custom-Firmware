#!/usr/bin/lua
package.path = "/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;" .. package.path

local json = require "luci.json"
local stats

local duration = tonumber(arg[1] or "300")
local dwell = tonumber(arg[2] or "30")
local stats_path = arg[3] or "/tmp/custom-miner-stats.json"
local tty = arg[4] or "/dev/ttyS1"

local algo_frame_hex = "ff550200a4a4c9bc"
local ack_hex = "ff550500a5a5bb81"
local nack_hex = "ff550500f5f5efcb"
local nonce_trailer_hex = "0000000000000001"
local function env_number(name, default)
  local value = tonumber(os.getenv(name) or "")
  if value == nil then return default end
  return value
end

NO_RESULT_REFRESH_SECONDS = env_number("NO_RESULT_REFRESH_SECONDS", 60)
NO_ACCEPT_REFRESH_SECONDS = env_number("NO_ACCEPT_REFRESH_SECONDS", 120)
MIN_WORK_SET_INTERVAL_SECONDS = env_number("MIN_WORK_SET_INTERVAL_SECONDS", 20)
RESULT_REFRESH_MIN_INTERVAL_SECONDS = env_number("RESULT_REFRESH_MIN_INTERVAL_SECONDS", 45)
NO_ACCEPT_WORK_REFRESH_SECONDS = env_number("NO_ACCEPT_WORK_REFRESH_SECONDS", 600)
DUPLICATE_RESULT_REFRESH_THRESHOLD = env_number("DUPLICATE_RESULT_REFRESH_THRESHOLD", 48)
ADJACENT_DUPLICATE_REFRESH_THRESHOLD = env_number("ADJACENT_DUPLICATE_REFRESH_THRESHOLD", 2)
ADJACENT_DUPLICATE_REFRESH_WINDOW_SECONDS = env_number("ADJACENT_DUPLICATE_REFRESH_WINDOW_SECONDS", 90)
ADJACENT_DUPLICATE_QUARANTINE_SECONDS = env_number("ADJACENT_DUPLICATE_QUARANTINE_SECONDS", 20)
ADJACENT_DUPLICATE_REFRESH_MIN_ACCEPT_AGE_SECONDS = env_number("ADJACENT_DUPLICATE_REFRESH_MIN_ACCEPT_AGE_SECONDS", 30)
ADJACENT_DUPLICATE_REQUIRE_EXACT_SIGNATURE = env_number("ADJACENT_DUPLICATE_REQUIRE_EXACT_SIGNATURE", 1)
DUPLICATE_CMD04_EXTRA_NACK = env_number("DUPLICATE_CMD04_EXTRA_NACK", 1)
UNKNOWN_RESULT_REFRESH_THRESHOLD = env_number("UNKNOWN_RESULT_REFRESH_THRESHOLD", 12)
JOB_ID_DEBOUNCE_SECONDS = env_number("JOB_ID_DEBOUNCE_SECONDS", 0)
PREPOW_DEBOUNCE_SECONDS = env_number("PREPOW_DEBOUNCE_SECONDS", 0)
STRATUM_WATCHDOG_SECONDS = 90
PENDING_SUBMIT_TIMEOUT_SECONDS = 120
DUPLICATE_PROOF_RETENTION_SECONDS = 600
RESULT_SUBMIT_MAX_AGE_SECONDS = env_number("RESULT_SUBMIT_MAX_AGE_SECONDS", 900)
STALE_RESULT_GRACE_SECONDS = env_number("STALE_RESULT_GRACE_SECONDS", 5)
TWO_MINERS_STALE_GRACE_SECONDS = env_number("TWO_MINERS_STALE_GRACE_SECONDS", STALE_RESULT_GRACE_SECONDS)
DUPLICATE_PROOF_RELAX_MAX_PER_HOUR = env_number("DUPLICATE_PROOF_RELAX_MAX_PER_HOUR", 0)
FAN_CONTROL_INTERVAL_SECONDS = env_number("FAN_CONTROL_INTERVAL_SECONDS", 10)
FAN_TEMP_FAILSAFE_SECONDS = env_number("FAN_TEMP_FAILSAFE_SECONDS", 30)
SENSOR_POLL_INTERVAL_SECONDS = env_number("SENSOR_POLL_INTERVAL_SECONDS", 10)
STATS_WRITE_INTERVAL_SECONDS = env_number("STATS_WRITE_INTERVAL_SECONDS", 10)
DIAG_SAMPLE_LIMIT = env_number("DIAG_SAMPLE_LIMIT", 12)
DIAG_HEAVY_SAMPLE_LIMIT = env_number("DIAG_HEAVY_SAMPLE_LIMIT", DIAG_SAMPLE_LIMIT)
DIAG_DDR_SAMPLE_LIMIT = env_number("DIAG_DDR_SAMPLE_LIMIT", 20)
FAN_PWM_REAPPLY_SECONDS = env_number("FAN_PWM_REAPPLY_SECONDS", 120)
if DIAG_SAMPLE_LIMIT < 1 then DIAG_SAMPLE_LIMIT = 1 end
if DIAG_HEAVY_SAMPLE_LIMIT < 1 then DIAG_HEAVY_SAMPLE_LIMIT = 1 end
if DIAG_DDR_SAMPLE_LIMIT < 1 then DIAG_DDR_SAMPLE_LIMIT = 1 end
if FAN_PWM_REAPPLY_SECONDS < 10 then FAN_PWM_REAPPLY_SECONDS = 10 end

local function bxor(a, b)
  local r, bit = 0, 1
  while a > 0 or b > 0 do
    local aa = a % 2
    local bb = b % 2
    if aa ~= bb then r = r + bit end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return r
end

local function crc_ccitt(bytes, first, last)
  local crc = 0
  for i = first, last do
    crc = bxor(crc, bytes[i] * 256)
    for _ = 1, 8 do
      if crc >= 32768 then
        crc = bxor((crc * 2) % 65536, 0x1021)
      else
        crc = (crc * 2) % 65536
      end
    end
  end
  return crc
end

local function hex_to_bytes(hex)
  local out = {}
  for i = 1, #hex, 2 do
    out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
  end
  return table.concat(out)
end

local function bytes_to_table(s)
  local t = {}
  for i = 1, #s do t[#t + 1] = string.byte(s, i) end
  return t
end

local function hex_range(bytes, first, last)
  local t = {}
  for i = first, last do t[#t + 1] = string.format("%02x", bytes[i]) end
  return table.concat(t)
end

local function hex_u32(value)
  local digits = "0123456789abcdef"
  local n = math.floor(tonumber(value) or 0)
  if n < 0 then
    n = (n % 4294967296 + 4294967296) % 4294967296
  else
    n = n % 4294967296
  end
  local out = {}
  for i = 7, 0, -1 do
    local place = 16 ^ i
    local digit = math.floor(n / place) % 16
    out[#out + 1] = digits:sub(digit + 1, digit + 1)
  end
  return "0x" .. table.concat(out)
end

local function expected_len(typ)
  if typ == 0x01 or typ == 0x02 or typ == 0x03 or typ == 0x05 then return 8 end
  if typ == 0x04 then return 186 end
  return nil
end

local function shell_quote(s)
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function cmd_output(cmd)
  local p = io.popen(cmd)
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return trim(out)
end

local function json_escape(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
  return s
end

local function read_pool_config()
  local raw = cmd_output("/usr/bin/g1m-config pool-json 2>/dev/null")
  if raw ~= "" and raw:sub(1, 1) == "{" then
    local ok, parsed = pcall(json.decode, raw)
    if ok and type(parsed) == "table" then
      return {
        coin = parsed.coin or "grin",
        url = parsed.url or "",
        user = parsed.user or "",
        password = parsed.password or "x",
      }
    end
  end
  local coin = cmd_output("uci get cgminer.default.select_coin 2>/dev/null")
  if coin == "" then coin = "grin" end
  local prefix = "cgminer.default." .. coin
  return {
    coin = coin,
    url = cmd_output("uci get " .. prefix .. "_pool1url 2>/dev/null"),
    user = cmd_output("uci get " .. prefix .. "_pool1user 2>/dev/null"),
    password = cmd_output("uci get " .. prefix .. "_pool1pw 2>/dev/null"),
  }
end

local function capture_stock_sensors()
  for _ = 1, 10 do
    local raw = cmd_output("/usr/bin/cgminer-api stats 2>/dev/null")
    if raw ~= "" then
      local found = false
      local fan = raw:match("Fan%[(.-)%]")
      if fan and fan ~= "" then
        stats.fan = fan
        local rpms = {}
        for v in fan:gmatch("[-%d%.]+") do
          rpms[#rpms + 1] = tonumber(v) or 0
        end
        if #rpms > 0 then stats.fan_rpm = rpms end
        found = true
      end
      if found then return end
    end
    os.execute("sleep 2")
  end
end

local function parse_stratum_url(url)
  local host, port = tostring(url):match("^[%w%+%-]+://([^:/]+):?(%d*)")
  if not host then host, port = tostring(url):match("^([^:/]+):?(%d*)") end
  port = tonumber(port ~= "" and port or "3030")
  return host, port
end

local function random_hex(nbytes)
  local f = io.open("/dev/urandom", "rb")
  local s = f:read(nbytes)
  f:close()
  local t = {}
  for i = 1, #s do t[#t + 1] = string.format("%02x", string.byte(s, i)) end
  return table.concat(t)
end

local function build_work_frame(pre_pow_hex, nonce_hex)
  local frame_hex_no_crc = "ff550000" .. pre_pow_hex .. nonce_hex .. nonce_trailer_hex
  local bytes = bytes_to_table(hex_to_bytes(frame_hex_no_crc))
  local crc = crc_ccitt(bytes, 3, #bytes)
  return frame_hex_no_crc .. string.format("%04x", crc)
end

local function audit_work_frame(frame_hex, lane)
  local bytes = bytes_to_table(hex_to_bytes(frame_hex))
  local computed = crc_ccitt(bytes, 3, #bytes - 2)
  return {
    lane = lane,
    length = #bytes,
    starts = frame_hex:sub(1, 8),
    f2_f9 = frame_hex:sub((0xf2 * 2) + 1, (0xf9 * 2) + 2),
    f4 = frame_hex:sub((0xf4 * 2) + 1, (0xf4 * 2) + 2),
    f5 = frame_hex:sub((0xf5 * 2) + 1, (0xf5 * 2) + 2),
    fa_101 = frame_hex:sub((0xfa * 2) + 1, (0x101 * 2) + 2),
    crc_stored = frame_hex:sub((0x102 * 2) + 1, (0x103 * 2) + 2),
    crc_computed = string.format("%04x", computed),
    crc_ok = frame_hex:sub((0x102 * 2) + 1, (0x103 * 2) + 2) == string.format("%04x", computed),
  }
end

local function dec_mul_add(dec, mul, add)
  local carry = add
  local out = {}
  for i = #dec, 1, -1 do
    local n = tonumber(dec:sub(i, i)) * mul + carry
    out[#out + 1] = tostring(n % 10)
    carry = math.floor(n / 10)
  end
  while carry > 0 do
    out[#out + 1] = tostring(carry % 10)
    carry = math.floor(carry / 10)
  end
  local s = table.concat(out):reverse():gsub("^0+", "")
  if s == "" then return "0" end
  return s
end

local function u64_decimal(bytes, first, last)
  local dec = "0"
  for i = first, last do dec = dec_mul_add(dec, 256, bytes[i]) end
  return dec
end

local function u32_be(bytes, first)
  return bytes[first] * 16777216 + bytes[first + 1] * 65536 + bytes[first + 2] * 256 + bytes[first + 3]
end

local function hash_string32(s)
  local h = 5381
  for i = 1, #s do
    h = ((h * 33) + string.byte(s, i)) % 4294967296
  end
  return tostring(math.floor(h))
end

local function build_submit_json(msg_id, job, result_frame)
  local pow = {}
  for i = 13, 180, 4 do pow[#pow + 1] = tostring(u32_be(result_frame, i)) end
  local nonce_dec = u64_decimal(result_frame, 5, 12)
  return string.format(
    '{"jsonrpc":"2.0","method":"submit","id":"%s","params":{"edge_bits":32,"nonce":%s,"pow":[%s],"height":%d,"job_id":%d}}',
    tostring(msg_id),
    nonce_dec,
    table.concat(pow, ","),
    tonumber(job.height) or 0,
    tonumber(job.job_id) or 0
  ), hex_range(result_frame, 5, 12)
end

local function emit(obj)
  io.stdout:write(json.encode(obj), "\n")
  io.stdout:flush()
end

stats = {
  schema = "custom-ipollo-miner-v1",
  status = "starting",
  miner = "custom-grin-uart-lua",
  miner_version = "G1M-v028",
  algo = "grin",
  unit = "shares/min",
  hashrate = 0,
  hashrate_unit = "G/s",
  hashrate_gps = 0,
  hashrate_gps_1m = 0,
  hashrate_gps_5m = 0,
  hashrate_gps_15m = 0,
  hashrate_gps_avg = 0,
  estimated_hashrate_gps = 0,
  estimated_hashrate_source = "accepted_lifetime_fallback",
  hashrate_source = "cgminer_estats",
  cgminer_estats_hashrate = 0,
  cgminer_estats_hashrate_raw = 0,
  cgminer_hashrate = 0,
  cgminer_hashrate_unit = "G/s",
  cgminer_estats_progress_sum = 0,
  cgminer_estats_samples = 0,
  cgminer_estats_slots = {},
  shares_per_min = 0,
  instant_shares_per_min = 0,
  temp = "0.0",
  board_temps_c = {},
  sensor_temps_c = {},
  sensor_paths = {},
  sensor_source = "unavailable",
  sensor_updated_at = "",
  chip_temps_c = {},
  chip_status = {},
  uart_status_frames = 0,
  uart_status_crc_errors = 0,
  status_frame_samples = {},
  last_status_frame_time = "",
  last_status_frame_epoch = 0,
  fan = "5250 5220 5190 5160",
  fan_rpm = {5250, 5220, 5190, 5160},
  fan_source = "startup_cgminer_snapshot",
  fan_rpm_source = "startup_cgminer_snapshot",
  fan_rpm_updated_at = "",
  fan_rpm_edges = {},
  fan_auto_enabled = false,
  fan_target_c = 55,
  fan_control_temp_c = 0,
  fan_pwm_percent = 0,
  fan_pwm_duty = 0,
  fan_control_updated_at = "",
  fan_control_errors = {},
  mcu_ddr_raw = 0,
  mcu_ddr_raw_hex = "",
  mcu_ddr_effective = 0,
  mcu_ddr_effective_mhz = 0,
  mcu_ddr_derived_raw = 0,
  mcu_ddr_derived_hex = "",
  mcu_ddr_source = "",
  mcu_ddr_last_update = "",
  mcu_ddr_error = "",
  mcu_ddr_samples = {},
  mcu_progress_counter = 0,
  mcu_progress_delta_per_poll = 0,
  mcu_progress_counter_resets = 0,
  mcu_event_41000028 = 0,
  mcu_event_4100002c = 0,
  mcu_event_41000000 = 0,
  mcu_grin_reset_count = 0,
  mcu_recent_watchdog_resets = 0,
  mcu_unchanged_progress_samples = 0,
  mcu_governor_cooldown = 0,
  mcu_governor_source = "",
  mcu_governor_last_update = "",
  mcu_governor_error = "",
  mcu_governor_samples = {},
  started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  uptime_seconds = 0,
  jobs_sent = 0,
  work_sets_sent = 0,
  lanes_sent = 0,
  same_job_ignored = 0,
  tracked_jobs = 0,
  tracked_aliases = 0,
  unique_tracked_jobs = 0,
  pruned_jobs = 0,
  resends = 0,
  resend_frames = 0,
  soft_refreshes = 0,
  result_refreshes = 0,
  duplicate_result_refreshes = 0,
  adjacent_duplicate_result_refreshes = 0,
  adjacent_duplicate_refresh_threshold = 0,
  adjacent_duplicate_refresh_window_seconds = 0,
  adjacent_duplicate_quarantine_seconds = 0,
  adjacent_duplicate_refresh_min_accept_age_seconds = 0,
  adjacent_duplicate_burst_count = 0,
  adjacent_duplicate_quarantine_hits = 0,
  adjacent_duplicate_quarantine_armed = 0,
  adjacent_duplicate_refresh_blocked_by_accept_age = 0,
  adjacent_duplicate_tail_only_ignored = 0,
  duplicate_cmd04_extra_nacks = 0,
  adjacent_duplicate_class_before_submit = 0,
  adjacent_duplicate_class_after_submit = 0,
  adjacent_duplicate_class_after_reject = 0,
  adjacent_duplicate_class_job_rollover = 0,
  adjacent_duplicate_class_unknown = 0,
  unknown_result_refreshes = 0,
  no_accept_result_refreshes = 0,
  last_result_refresh_reason = "",
  last_soft_refresh_reason = "",
  pool_jobs = 0,
  stratum_connected = false,
  stratum_reconnects = 0,
  last_stratum_byte_time = "",
  last_valid_job_time = "",
  seconds_since_stratum_byte = 0,
  seconds_since_valid_job = 0,
  stratum_disconnect_reason = "",
  stale_job_work_suppressed = 0,
  template_requests = 0,
  pending_submit_timeouts = 0,
  duplicate_proof_suppressed = 0,
  stratum_pings = 0,
  stratum_client_reconnects = 0,
  partial_stratum_bytes = 0,
  cmd01_frames = 0,
  cmd01_ok = 0,
  cmd01_error = 0,
  cmd01_other = 0,
  cmd01_crc_errors = 0,
  cmd01_by_lane = {0, 0, 0},
  cmd01_ok_by_lane = {0, 0, 0},
  cmd01_error_by_lane = {0, 0, 0},
  cmd01_other_by_lane = {0, 0, 0},
  cmd01_samples = {},
  cmd01_last_by_lane = {},
  notify_count = 0,
  work_update_count = 0,
  duplicate_notify = 0,
  job_id_changed = 0,
  job_id_debounced = 0,
  difficulty_changed = 0,
  pre_pow_changed = 0,
  pre_pow_debounced = 0,
  missing_job_fields = 0,
  last_work_update_reason = "",
  last_job_id = "",
  last_difficulty = "",
  last_pre_pow_prefix = "",
  new_job_reason = "",
  notify_samples = {},
  uart_result_frames = 0,
  stale_result_frames = 0,
  inactive_result_frames = 0,
  stale_submit_suppressed = 0,
  stale_pool_generation_suppressed = 0,
  stale_current_job_suppressed = 0,
  stale_job_age_suppressed = 0,
  duplicate_result_frames = 0,
  stale_candidate_submits = 0,
  unknown_result_frames = 0,
  unknown_active_alias_miss = 0,
  unknown_recent_pruned_alias_hit = 0,
  unknown_recent_sent_work_hit = 0,
  unknown_alias_collision = 0,
  unknown_no_match = 0,
  unknown_lane_mismatch = 0,
  unknown_post_reconnect_late = 0,
  unknown_proof_context_mismatch = 0,
  unknown_stale_current_key_mismatch = 0,
  duplicate_true_repeat_after_submit = 0,
  duplicate_repeat_before_submit = 0,
  duplicate_after_reject = 0,
  duplicate_stock_tail_key_repeat = 0,
  duplicate_stock_adjacent_repeat = 0,
  duplicate_samples_compacted = 0,
  duplicate_submit_key_repeat = 0,
  duplicate_proof_key_repeat = 0,
  duplicate_proof_relax_max_per_hour = 0,
  duplicate_proof_relaxed_submits = 0,
  duplicate_proof_relaxed_limited = 0,
  unknown_stock_tail_key_repeat = 0,
  stock_tail_key_repeat_total = 0,
  duplicate_salvage_candidate = 0,
  alias_collision_count = 0,
  alias_overwrite_count = 0,
  result_mid4_alias_matches = 0,
  result_mid4_alias_submits = 0,
  result_mid4_alias_duplicates = 0,
  result_mid4_alias_unknowns = 0,
  unknown_result_samples = {},
  duplicate_result_samples = {},
  alias_collision_samples = {},
  recent_pruned_job_samples = {},
  recent_sent_work_samples = {},
  accepted_by_ddr = {},
  rejected_by_ddr = {},
  submit_errors_by_ddr = {},
  duplicates_by_ddr = {},
  unknowns_by_ddr = {},
  resets_by_ddr = {},
  seconds_by_ddr = {},
  ddr_bucket_metrics = {},
  ddr_accounting_source = "",
  ddr_accounting_updated_at = "",
  ddr_accounting_persist_error = "",
  cmd04_event_samples = {},
  work_field_samples = {},
  work_frame_audit_samples = {},
  result_lane_samples = {},
  uart_frame_samples = {},
  uart_frame_type_counts = {},
  accepted_by_lane = {0, 0, 0},
  results_by_lane = {0, 0, 0},
  decoded_results_by_lane = {0, 0, 0},
  decoded_result_lane_unknown = 0,
  crc_resync = 0,
  crc_resync_embedded_header = 0,
  crc_resync_no_header = 0,
  crc_resync_bytes_discarded = 0,
  crc_resync_cmd04_embedded_header = 0,
  crc_resync_cmd04_nacked = 0,
  crc_resync_cmd04_tail_silent_drops = 0,
  crc_resync_cmd04_alt_boundary_valid = 0,
  crc_resync_cmd04_alt_boundary_invalid = 0,
  crc_resync_cmd04_alt_boundary_samples = {},
  crc_resync_cmd01 = 0,
  crc_resync_cmd03 = 0,
  crc_resync_other = 0,
  crc_resync_embedded_early = 0,
  crc_resync_embedded_mid = 0,
  crc_resync_embedded_tail = 0,
  crc_resync_candidate_valid = 0,
  crc_resync_candidate_invalid_crc = 0,
  crc_resync_candidate_unknown_cmd = 0,
  crc_resync_candidate_short_buffer = 0,
  crc_resync_recovered_frames = 0,
  crc_resync_samples = {},
  uart_result_acks = 0,
  uart_result_nacks = 0,
  uart_drain_bytes = 0,
  accepted = 0,
  rejected = 0,
  submit_ok = 0,
  submit_error = 0,
  submit_error_job_not_found = 0,
  submit_error_solution_too_late = 0,
  submit_error_stale_pool = 0,
  submit_error_other = 0,
  submit_error_messages = {},
  skipped_results = 0,
  seconds_since_last_work_set = 0,
  seconds_since_last_result = 0,
  seconds_since_last_accept = 0,
  accepted_per_min = 0,
  accepted_per_min_1m = 0,
  accepted_per_min_5m = 0,
  accepted_per_min_15m = 0,
  accepted_per_min_avg = 0,
  fault = false,
  fault_reasons = {},
  led_state = "",
  stats_payload_bytes = 0,
  errors = {},
}

local start_time = os.time()
local ddr_account_path = os.getenv("DDR_ACCOUNT_PATH") or "/root/custom-miner-ddr-accounting.json"
local ddr_last_residency_epoch = nil
local ddr_last_persist_epoch = 0
local ddr_last_progress_resets = 0
local ddr_last_grin_resets = 0
local ddr_last_watchdog_resets = 0
local job_retention_seconds = tonumber(arg[5] or "1800")
local resend_interval_ms = tonumber(arg[6] or "0")
local enable_dwell_refresh = tostring(os.getenv("ENABLE_DWELL_REFRESH") or arg[7] or "0") == "1"
local enable_soft_refresh = tostring(os.getenv("ENABLE_SOFT_REFRESH") or arg[8] or "0") == "1"
local lane_mode = tostring(arg[9] or "1")
local enable_result_refresh = tostring(os.getenv("ENABLE_RESULT_REFRESH") or arg[10] or "1") == "1"
local shares_per_min_to_gps = tonumber(arg[11] or "0.614")
local frames_per_lane = tonumber(arg[12] or "1")
if not frames_per_lane or frames_per_lane < 1 then frames_per_lane = 1 end
frames_per_lane = math.floor(frames_per_lane)
local inter_work_frame_delay_ms = tonumber(os.getenv("INTER_WORK_FRAME_DELAY_MS") or arg[13] or "30") or 30
local fan_auto_enabled = tostring(os.getenv("FAN_AUTO") or "0") == "1"
local fan_target_c = tonumber(os.getenv("FAN_TARGET_C") or "55") or 55
local fan_min_percent = tonumber(os.getenv("FAN_MIN_PERCENT") or "30") or 30
local fan_max_percent = tonumber(os.getenv("FAN_MAX_PERCENT") or "100") or 100
local fan_hard_c = tonumber(os.getenv("FAN_HARD_C") or "70") or 70
local pwm_helper = os.getenv("PWM_HELPER") or "/usr/bin/custom-pwmctl"
local fan_tach_helper = os.getenv("FAN_TACH_HELPER") or "/usr/bin/custom-fantach"
local fan_tach_path = os.getenv("FAN_TACH_PATH") or "/tmp/custom-fan-rpm.txt"
local fault_led_path = os.getenv("FAULT_LED") or "/sys/class/leds/red:status"
local ok_led_path = os.getenv("OK_LED") or "/sys/class/leds/green:pwr"
local mcu_poll_mode = tostring(os.getenv("MCU_POLL_MODE") or "")
if mcu_poll_mode == "" then
  mcu_poll_mode = tostring(os.getenv("MCU_GOVERNOR_POLL") or "0") == "1" and "governor" or "ddr"
end
if mcu_poll_mode ~= "off" and mcu_poll_mode ~= "ddr" and mcu_poll_mode ~= "governor" then mcu_poll_mode = "off" end
local mcu_governor_poll_enabled = mcu_poll_mode ~= "off"
local mcu_read_helper = os.getenv("MCU_READ_HELPER") or "/usr/bin/custom-mcu-read"
local mcu_poll_interval_seconds = tonumber(os.getenv("MCU_POLL_INTERVAL_SECONDS") or "60") or 60
if mcu_poll_interval_seconds < 10 then mcu_poll_interval_seconds = 10 end
if mcu_poll_interval_seconds > 300 then mcu_poll_interval_seconds = 300 end
if fan_min_percent < 30 then fan_min_percent = 30 end
if fan_max_percent < fan_min_percent then fan_max_percent = fan_min_percent end
if fan_max_percent > 100 then fan_max_percent = 100 end
if lane_mode ~= "all" and lane_mode ~= "1" and lane_mode ~= "2" and lane_mode ~= "3" then
  lane_mode = "1"
end
local cfg = read_pool_config()
stats.pool = {url = cfg.url, user = cfg.user, coin = cfg.coin}
stats.lane_mode = lane_mode
stats.lane_encoding = "stock"
stats.frames_per_lane = frames_per_lane
stats.inter_work_frame_delay_ms = inter_work_frame_delay_ms
stats.job_id_debounce_seconds = JOB_ID_DEBOUNCE_SECONDS
stats.prepow_debounce_seconds = PREPOW_DEBOUNCE_SECONDS
stats.result_submit_max_age_seconds = RESULT_SUBMIT_MAX_AGE_SECONDS
stats.stale_result_grace_seconds = STALE_RESULT_GRACE_SECONDS
stats.two_miners_stale_grace_seconds = TWO_MINERS_STALE_GRACE_SECONDS
stats.duplicate_proof_relax_max_per_hour = DUPLICATE_PROOF_RELAX_MAX_PER_HOUR
stats.adjacent_duplicate_refresh_threshold = ADJACENT_DUPLICATE_REFRESH_THRESHOLD
stats.adjacent_duplicate_refresh_window_seconds = ADJACENT_DUPLICATE_REFRESH_WINDOW_SECONDS
stats.adjacent_duplicate_quarantine_seconds = ADJACENT_DUPLICATE_QUARANTINE_SECONDS
stats.adjacent_duplicate_refresh_min_accept_age_seconds = ADJACENT_DUPLICATE_REFRESH_MIN_ACCEPT_AGE_SECONDS
stats.adjacent_duplicate_require_exact_signature = ADJACENT_DUPLICATE_REQUIRE_EXACT_SIGNATURE
stats.duplicate_cmd04_extra_nack_enabled = DUPLICATE_CMD04_EXTRA_NACK
stats.fan_auto_enabled = fan_auto_enabled
stats.fan_target_c = fan_target_c
stats.fan_min_percent = fan_min_percent
stats.fan_max_percent = fan_max_percent
stats.fan_hard_c = fan_hard_c
stats.uart_lane_index = tonumber(os.getenv("UART_LANE_INDEX") or "1") or 1
if stats.uart_lane_index < 1 or stats.uart_lane_index > 3 then stats.uart_lane_index = 1 end
stats.mcu_poll_mode = mcu_poll_mode
stats.mcu_governor_poll_enabled = mcu_governor_poll_enabled
if not mcu_governor_poll_enabled then
  stats.mcu_governor_source = "disabled"
  stats.mcu_governor_error = "disabled"
end
local last_rate_sample_epoch = nil
local last_rate_sample_accepted = nil
local rate_1m = nil
local rate_5m = nil
local rate_15m = nil

local function ema(old, instant, window_seconds, dt)
  local alpha = dt / window_seconds
  if alpha > 1 then alpha = 1 end
  if old == nil then return instant end
  return old + alpha * (instant - old)
end

local function push_bounded(list, item, limit)
  list[#list + 1] = item
  while #list > limit do table.remove(list, 1) end
end

local last_led_state = ""

local function led_write(path, value)
  if not path or path == "" then return end
  os.execute("[ -d " .. shell_quote(path) .. " ] || exit 0; echo none > " .. shell_quote(path .. "/trigger") .. " 2>/dev/null || true; echo " .. tostring(value) .. " > " .. shell_quote(path .. "/brightness") .. " 2>/dev/null || true")
end

local function set_fault_led(fault)
  local state = fault and "fault" or "ok"
  if state == last_led_state then return end
  last_led_state = state
  stats.led_state = state
  if fault then
    led_write(fault_led_path, 255)
    led_write(ok_led_path, 0)
  else
    led_write(fault_led_path, 0)
    led_write(ok_led_path, 255)
  end
end

local cgminer_estats_slots = {}
local cgminer_estats_scale = 0.85 / 120.0

local function update_cgminer_estats(result_diag, decoded_lane)
  local progress_hex = result_diag and result_diag.stock_progress_key
  local progress_value = progress_hex and tonumber(progress_hex, 16)
  if not progress_value then return end

  local lane = tonumber(decoded_lane) or 0
  if lane < 1 or lane > 3 then lane = 0 end
  local slot_key = tostring(lane)
  local slot = cgminer_estats_slots[slot_key] or {count = 0, avg = 0}
  slot.avg = ((slot.avg * slot.count) + progress_value) / (slot.count + 1)
  slot.count = slot.count + 1
  cgminer_estats_slots[slot_key] = slot

  local sum, samples, public = 0, 0, {}
  for key, value in pairs(cgminer_estats_slots) do
    local avg = tonumber(value.avg) or 0
    local count = tonumber(value.count) or 0
    sum = sum + avg
    samples = samples + count
    public[key] = {count = count, avg = avg}
  end

  local raw_hashrate = sum * cgminer_estats_scale
  local display_hashrate = raw_hashrate
  local unit = "G/s"
  if display_hashrate >= 1000 then
    display_hashrate = display_hashrate / 1000
    unit = "KG/s"
  end

  stats.cgminer_estats_progress_sum = sum
  stats.cgminer_estats_samples = samples
  stats.cgminer_estats_hashrate_raw = raw_hashrate
  stats.cgminer_estats_hashrate = display_hashrate
  stats.cgminer_hashrate = display_hashrate
  stats.cgminer_hashrate_unit = unit
  stats.cgminer_estats_slots = public
end

local function record_fan_error(msg)
  push_bounded(stats.fan_control_errors, {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    error = tostring(msg),
  }, 10)
end

local last_sensor_poll_epoch = 0
local last_valid_live_temp_epoch = nil
local last_status_frame_epoch = 0
local max_valid_temp

local function parse_temp_value(raw)
  local n = tonumber(trim(raw or ""))
  if not n then return nil end
  if math.abs(n) > 1000 then n = n / 1000 end
  if n < -10 or n > 120 then return nil end
  return n
end

local function poll_live_sensors(force)
  local now = os.time()
  if not force and now - last_sensor_poll_epoch < SENSOR_POLL_INTERVAL_SECONDS then
    return #stats.board_temps_c > 0
  end
  last_sensor_poll_epoch = now

  local temps = {}
  local paths = {}
  local cmd = "for f in /sys/class/hwmon/hwmon*/temp*_input /sys/class/thermal/thermal_zone*/temp; do [ -f \"$f\" ] && printf '%s=%s\\n' \"$f\" \"$(cat \"$f\" 2>/dev/null)\"; done"
  local raw = cmd_output(cmd)
  for line in raw:gmatch("[^\r\n]+") do
    local path, value = line:match("^([^=]+)=(.*)$")
    local temp_c = parse_temp_value(value)
    if path and temp_c then
      temps[#temps + 1] = temp_c
      paths[#paths + 1] = path
    end
  end

  if #temps > 0 then
    stats.board_temps_c = temps
    stats.sensor_temps_c = temps
    stats.sensor_paths = paths
    stats.chip_temp_c = max_valid_temp(temps) or temps[1]
    stats.temp = string.format("%.1f", stats.chip_temp_c)
    stats.sensor_source = "live_sysfs"
    stats.sensor_updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    last_valid_live_temp_epoch = now
    return true
  end

  if last_status_frame_epoch > 0 and now - last_status_frame_epoch <= FAN_TEMP_FAILSAFE_SECONDS then
    stats.sensor_source = "uart_status"
    return #stats.board_temps_c > 0
  end

  stats.board_temps_c = {}
  stats.sensor_temps_c = {}
  stats.sensor_paths = {}
  stats.chip_temp_c = 0
  stats.temp = "0.0"
  if (not last_valid_live_temp_epoch) or now - last_valid_live_temp_epoch > FAN_TEMP_FAILSAFE_SECONDS then
    stats.sensor_source = "missing"
  else
    stats.sensor_source = "live_sysfs_stale"
  end
  return false
end

function max_valid_temp(values)
  local max_temp = nil
  for _, v in ipairs(values or {}) do
    local n = tonumber(v)
    if n and n > 0 and n < 150 then
      if not max_temp or n > max_temp then max_temp = n end
    end
  end
  return max_temp
end

local function plausible_temp(raw)
  local candidates = {
    raw / 10,
    raw / 100,
    raw / 1000,
    raw,
  }
  for _, temp_c in ipairs(candidates) do
    if temp_c >= -10 and temp_c <= 120 then return temp_c end
  end
  return nil
end

local function decode_uart_status_temp(frame)
  local be = (frame[5] or 0) * 256 + (frame[6] or 0)
  local le = (frame[6] or 0) * 256 + (frame[5] or 0)
  local be_temp = plausible_temp(be)
  local le_temp = plausible_temp(le)
  return {
    raw_be = be,
    raw_le = le,
    temp_be_c = be_temp,
    temp_le_c = le_temp,
    temp_c = be_temp or le_temp,
  }
end

local last_valid_fan_temp_epoch = nil
local last_fan_control_epoch = 0
local last_fan_pwm_percent = nil
local last_fan_pwm_apply_epoch = 0

local function apply_fan_pwm(percent)
  local duty = math.floor(percent * 40000 / 100 + 0.5)
  local helper_exists = os.execute("[ -x " .. shell_quote(pwm_helper) .. " ] >/dev/null 2>&1")
  if not (helper_exists == true or helper_exists == 0) then
    record_fan_error("pwm_helper_missing:" .. pwm_helper)
    return false, duty
  end
  local cmd = shell_quote(pwm_helper) .. " " .. tostring(percent)
  local ok = os.execute(cmd .. " >/dev/null 2>&1")
  if not (ok == true or ok == 0) then
    record_fan_error("pwm_helper_failed:" .. tostring(ok))
    return false, duty
  end
  return true, duty
end

local function maybe_update_fan_control()
  if not fan_auto_enabled then return end
  local now = os.time()
  if now - last_fan_control_epoch < FAN_CONTROL_INTERVAL_SECONDS then return end
  last_fan_control_epoch = now

  poll_live_sensors(false)
  local control_temp = max_valid_temp(stats.board_temps_c)
  local fan_percent = nil
  if control_temp then
    last_valid_fan_temp_epoch = now
    stats.fan_control_temp_c = control_temp
    if control_temp >= fan_hard_c then
      fan_percent = fan_max_percent
    else
      fan_percent = fan_min_percent + ((control_temp - fan_target_c) * 8)
      if fan_percent < fan_min_percent then fan_percent = fan_min_percent end
      if fan_percent > fan_max_percent then fan_percent = fan_max_percent end
    end
  elseif last_valid_live_temp_epoch and now - last_valid_live_temp_epoch > FAN_TEMP_FAILSAFE_SECONDS then
    fan_percent = fan_max_percent
    stats.sensor_source = "missing"
    record_fan_error("live_temp_stale_failsafe")
  elseif (not last_valid_fan_temp_epoch) and now - start_time > FAN_TEMP_FAILSAFE_SECONDS then
    fan_percent = fan_max_percent
    stats.sensor_source = "missing"
    record_fan_error("live_temp_missing_failsafe")
  elseif not last_valid_fan_temp_epoch then
    stats.sensor_source = "missing"
    record_fan_error("no_live_temp")
    return
  end

  if not fan_percent then return end
  if fan_percent < 30 then fan_percent = 30 end
  if fan_percent > 100 then fan_percent = 100 end
  fan_percent = math.floor(fan_percent + 0.5)

  local duty = math.floor(fan_percent * 40000 / 100 + 0.5)
  local ok = true
  if fan_percent ~= last_fan_pwm_percent or now - last_fan_pwm_apply_epoch >= FAN_PWM_REAPPLY_SECONDS then
    ok, duty = apply_fan_pwm(fan_percent)
    if ok then
      last_fan_pwm_percent = fan_percent
      last_fan_pwm_apply_epoch = now
    end
  end
  stats.fan_pwm_percent = fan_percent
  stats.fan_pwm_duty = duty
  stats.fan_pwm_source = "pwm_control"
  stats.fan_control_updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if not ok and (not last_valid_fan_temp_epoch or now - last_valid_fan_temp_epoch > FAN_TEMP_FAILSAFE_SECONDS) then
    stats.fan_pwm_percent = fan_max_percent
    stats.fan_pwm_duty = math.floor(fan_max_percent * 40000 / 100 + 0.5)
  end
end

local function start_fan_tach_monitor()
  os.execute("killall custom-fantach >/dev/null 2>&1 || true")
  local helper_exists = os.execute("[ -x " .. shell_quote(fan_tach_helper) .. " ] >/dev/null 2>&1")
  if not (helper_exists == true or helper_exists == 0) then
    stats.fan_rpm_source = "tach_helper_missing"
    return
  end
  os.execute(shell_quote(fan_tach_helper) .. " " .. shell_quote(fan_tach_path) .. " >/tmp/custom-fantach.log 2>&1 &")
end

local ddr_account_fields = {
  "accepted_by_ddr",
  "rejected_by_ddr",
  "submit_errors_by_ddr",
  "duplicates_by_ddr",
  "unknowns_by_ddr",
  "resets_by_ddr",
  "seconds_by_ddr",
}

local function ddr_key()
  if stats.mcu_ddr_raw_hex and stats.mcu_ddr_raw_hex ~= "" then return tostring(stats.mcu_ddr_raw_hex) end
  if tonumber(stats.mcu_ddr_raw or 0) and tonumber(stats.mcu_ddr_raw or 0) > 0 then
    return string.format("0x%02x", tonumber(stats.mcu_ddr_raw))
  end
  return "unknown"
end

local function ddr_inc(field, key, amount)
  key = key or ddr_key()
  amount = amount or 1
  stats[field] = stats[field] or {}
  stats[field][key] = (tonumber(stats[field][key]) or 0) + amount
end

function ddr_account_event(field, amount)
  ddr_inc(field, ddr_key(), amount or 1)
end

function ddr_load_accounting()
  local f = io.open(ddr_account_path, "r")
  if not f then
    stats.ddr_accounting_source = "new"
    return
  end
  local raw = f:read("*a") or ""
  f:close()
  local ok, obj = pcall(json.decode, raw)
  if not ok or type(obj) ~= "table" then
    stats.ddr_accounting_source = "load_failed"
    return
  end
  for _, field in ipairs(ddr_account_fields) do
    if type(obj[field]) == "table" then stats[field] = obj[field] end
  end
  stats.ddr_accounting_source = "persisted"
end

local function ddr_compute_metrics()
  local keys = {}
  for _, field in ipairs(ddr_account_fields) do
    for key in pairs(stats[field] or {}) do keys[key] = true end
  end
  local metrics = {}
  for key in pairs(keys) do
    local seconds = tonumber((stats.seconds_by_ddr or {})[key]) or 0
    local hours = seconds / 3600
    local minutes = seconds / 60
    local accepted = tonumber((stats.accepted_by_ddr or {})[key]) or 0
    local rejected = tonumber((stats.rejected_by_ddr or {})[key]) or 0
    local submit_errors = tonumber((stats.submit_errors_by_ddr or {})[key]) or 0
    local duplicates = tonumber((stats.duplicates_by_ddr or {})[key]) or 0
    local unknowns = tonumber((stats.unknowns_by_ddr or {})[key]) or 0
    local resets = tonumber((stats.resets_by_ddr or {})[key]) or 0
    local raw = tonumber(tostring(key):match("^0x(%x+)$") or "", 16)
    metrics[key] = {
      ddr_raw_hex = key,
      ddr_effective_mhz = raw and raw * 12 or 0,
      seconds = seconds,
      hours = hours,
      accepted = accepted,
      rejected = rejected,
      submit_errors = submit_errors,
      duplicates = duplicates,
      unknowns = unknowns,
      resets = resets,
      accepted_per_hour = hours > 0 and accepted / hours or 0,
      accepted_per_min = minutes > 0 and accepted / minutes or 0,
      rejects_per_hour = hours > 0 and rejected / hours or 0,
      submit_errors_per_hour = hours > 0 and submit_errors / hours or 0,
      unknowns_per_hour = hours > 0 and unknowns / hours or 0,
      duplicates_per_hour = hours > 0 and duplicates / hours or 0,
      resets_per_hour = hours > 0 and resets / hours or 0,
    }
  end
  stats.ddr_bucket_metrics = metrics
end

local function ddr_update_residency()
  local now = os.time()
  if not ddr_last_residency_epoch then
    ddr_last_residency_epoch = now
    return
  end
  local dt = now - ddr_last_residency_epoch
  ddr_last_residency_epoch = now
  if dt > 0 and dt < 3600 then ddr_inc("seconds_by_ddr", ddr_key(), dt) end
end

local function ddr_account_resets_if_changed()
  local progress_resets = tonumber(stats.mcu_progress_counter_resets or 0) or 0
  local grin_resets = tonumber(stats.mcu_grin_reset_count or 0) or 0
  local watchdog_resets = tonumber(stats.mcu_recent_watchdog_resets or 0) or 0
  local delta = 0
  if progress_resets > ddr_last_progress_resets then delta = delta + (progress_resets - ddr_last_progress_resets) end
  if grin_resets > ddr_last_grin_resets then delta = delta + (grin_resets - ddr_last_grin_resets) end
  if watchdog_resets > ddr_last_watchdog_resets then delta = delta + (watchdog_resets - ddr_last_watchdog_resets) end
  ddr_last_progress_resets = progress_resets
  ddr_last_grin_resets = grin_resets
  ddr_last_watchdog_resets = watchdog_resets
  if delta > 0 then ddr_account_event("resets_by_ddr", delta) end
end

local function ddr_persist_accounting(force)
  local now = os.time()
  if not force and now - ddr_last_persist_epoch < 60 then return end
  ddr_last_persist_epoch = now
  local obj = {}
  for _, field in ipairs(ddr_account_fields) do obj[field] = stats[field] or {} end
  obj.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  obj.source = "custom-grin-miner"
  local tmp = ddr_account_path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    stats.ddr_accounting_persist_error = "open_failed"
    return
  end
  f:write(json.encode(obj))
  f:write("\n")
  f:close()
  local ok = os.execute("mv " .. shell_quote(tmp) .. " " .. shell_quote(ddr_account_path))
  if ok == true or ok == 0 then
    stats.ddr_accounting_persist_error = ""
    stats.ddr_accounting_updated_at = obj.updated_at
  else
    stats.ddr_accounting_persist_error = "mv_failed"
  end
end

local function poll_fan_tach()
  local f = io.open(fan_tach_path, "r")
  if not f then return false end
  local line = f:read("*l") or ""
  f:close()
  local vals = {}
  for v in line:gmatch("%S+") do vals[#vals + 1] = tonumber(v) end
  if #vals < 9 then return false end
  local epoch = vals[1]
  if not epoch or os.time() - epoch > 5 then
    stats.fan_rpm_source = "gpio_tach_stale"
    return false
  end
  local rpms = {vals[2] or 0, vals[3] or 0, vals[4] or 0, vals[5] or 0}
  stats.fan_rpm = rpms
  stats.fan = table.concat(rpms, " ")
  stats.fan_rpm_edges = {vals[6] or 0, vals[7] or 0, vals[8] or 0, vals[9] or 0}
  stats.fan_source = "gpio_tach"
  stats.fan_rpm_source = "gpio_tach"
  stats.fan_rpm_updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
  return true
end

local last_mcu_poll_epoch = 0
local last_mcu_progress_counter = nil

local function parse_mcu_read_value(raw)
  local bus, reg, value = tostring(raw or ""):match("bus=(%d+)%s+reg=0x(%x+)%s+value=0x(%x+)")
  if not value then return nil, nil, nil end
  local parsed = tonumber(value, 16)
  if not parsed then return nil, nil, nil end
  return math.floor(parsed), tonumber(bus), tonumber(reg, 16)
end

local function read_mcu_register(reg_hex)
  local raw = cmd_output(shell_quote(mcu_read_helper) .. " " .. tostring(reg_hex) .. " 2>&1")
  local value = parse_mcu_read_value(raw)
  return value, raw
end

local function poll_mcu_governor(force)
  if not mcu_governor_poll_enabled then
    stats.mcu_governor_source = "disabled"
    stats.mcu_governor_error = "disabled"
    return
  end
  local now = os.time()
  if not force and now - last_mcu_poll_epoch < mcu_poll_interval_seconds then return end
  last_mcu_poll_epoch = now

  local helper_exists = os.execute("[ -x " .. shell_quote(mcu_read_helper) .. " ] >/dev/null 2>&1")
  if not (helper_exists == true or helper_exists == 0) then
    stats.mcu_ddr_error = "mcu_read_helper_missing:" .. mcu_read_helper
    stats.mcu_governor_error = stats.mcu_ddr_error
    return
  end

  local errors = {}
  local ddr_raw, raw_main = read_mcu_register("0x40000108")
  local derived_raw, raw_derived = read_mcu_register("0x40000120")

  if not ddr_raw then errors[#errors + 1] = "0x40000108=[" .. raw_main .. "]" end
  if not derived_raw then errors[#errors + 1] = "0x40000120=[" .. raw_derived .. "]" end

  if ddr_raw and derived_raw then
    ddr_raw = math.floor(tonumber(ddr_raw) or 0)
    derived_raw = math.floor(tonumber(derived_raw) or 0)
    stats.mcu_ddr_raw = ddr_raw
    stats.mcu_ddr_raw_hex = string.format("0x%02x", ddr_raw)
    stats.mcu_ddr_effective = ddr_raw * 12
    stats.mcu_ddr_effective_mhz = stats.mcu_ddr_effective
    stats.mcu_ddr_derived_raw = derived_raw
    stats.mcu_ddr_derived_hex = hex_u32(derived_raw)
    stats.mcu_ddr_source = "custom-mcu-read"
    stats.mcu_ddr_last_update = os.date("!%Y-%m-%dT%H:%M:%SZ")
    stats.mcu_ddr_error = ""
    push_bounded(stats.mcu_ddr_samples, {
      at = stats.mcu_ddr_last_update,
      raw = ddr_raw,
      raw_hex = stats.mcu_ddr_raw_hex,
      effective = stats.mcu_ddr_effective,
      derived_raw = derived_raw,
      derived_hex = stats.mcu_ddr_derived_hex,
    }, DIAG_DDR_SAMPLE_LIMIT)
  else
    stats.mcu_ddr_error = "read_failed main=[" .. raw_main .. "] derived=[" .. raw_derived .. "]"
  end

  if mcu_poll_mode == "ddr" then
    if #errors == 0 then
      stats.mcu_governor_source = "custom-mcu-read-ddr-only"
      stats.mcu_governor_last_update = stats.mcu_ddr_last_update
      stats.mcu_governor_error = ""
    else
      stats.mcu_governor_error = "read_failed " .. table.concat(errors, "; ")
    end
    return
  end

  local progress_raw, raw_progress = read_mcu_register("0x41000030")
  local event_28_raw, raw_event_28 = read_mcu_register("0x41000028")
  local event_2c_raw, raw_event_2c = read_mcu_register("0x4100002c")
  local event_00_raw, raw_event_00 = read_mcu_register("0x41000000")

  if not progress_raw then errors[#errors + 1] = "0x41000030=[" .. raw_progress .. "]" end
  if not event_28_raw then errors[#errors + 1] = "0x41000028=[" .. raw_event_28 .. "]" end
  if not event_2c_raw then errors[#errors + 1] = "0x4100002c=[" .. raw_event_2c .. "]" end
  if not event_00_raw then errors[#errors + 1] = "0x41000000=[" .. raw_event_00 .. "]" end

  local grin_reset_raw, raw_grin_reset = read_mcu_register("0x00006de0")
  local watchdog_raw, raw_watchdog = read_mcu_register("0x00006df0")
  local unchanged_raw, raw_unchanged = read_mcu_register("0x00006fd8")
  local cooldown_raw, raw_cooldown = read_mcu_register("0x00006dec")

  local optional_errors = {}
  if not grin_reset_raw then optional_errors[#optional_errors + 1] = "0x00006de0=[" .. raw_grin_reset .. "]" end
  if not watchdog_raw then optional_errors[#optional_errors + 1] = "0x00006df0=[" .. raw_watchdog .. "]" end
  if not unchanged_raw then optional_errors[#optional_errors + 1] = "0x00006fd8=[" .. raw_unchanged .. "]" end
  if not cooldown_raw then optional_errors[#optional_errors + 1] = "0x00006dec=[" .. raw_cooldown .. "]" end

  if progress_raw then
    stats.mcu_progress_counter = progress_raw
    if last_mcu_progress_counter then
      if progress_raw >= last_mcu_progress_counter then
        stats.mcu_progress_delta_per_poll = progress_raw - last_mcu_progress_counter
      else
        stats.mcu_progress_delta_per_poll = progress_raw
        stats.mcu_progress_counter_resets = stats.mcu_progress_counter_resets + 1
      end
    else
      stats.mcu_progress_delta_per_poll = 0
    end
    last_mcu_progress_counter = progress_raw
  end
  if event_28_raw then stats.mcu_event_41000028 = event_28_raw end
  if event_2c_raw then stats.mcu_event_4100002c = event_2c_raw end
  if event_00_raw then stats.mcu_event_41000000 = event_00_raw end
  if grin_reset_raw then stats.mcu_grin_reset_count = grin_reset_raw end
  if watchdog_raw then stats.mcu_recent_watchdog_resets = watchdog_raw end
  if unchanged_raw then stats.mcu_unchanged_progress_samples = unchanged_raw end
  if cooldown_raw then stats.mcu_governor_cooldown = cooldown_raw end

  if #errors == 0 then
    stats.mcu_governor_source = "custom-mcu-read"
    stats.mcu_governor_last_update = os.date("!%Y-%m-%dT%H:%M:%SZ")
    if #optional_errors == 0 then
      stats.mcu_governor_error = ""
    else
      stats.mcu_governor_error = "optional_read_failed " .. table.concat(optional_errors, "; ")
    end
    push_bounded(stats.mcu_governor_samples, {
      at = stats.mcu_governor_last_update,
      ddr_effective_mhz = stats.mcu_ddr_effective_mhz,
      ddr_raw_hex = stats.mcu_ddr_raw_hex,
      progress_counter = stats.mcu_progress_counter,
      progress_delta = stats.mcu_progress_delta_per_poll,
      event_41000028 = stats.mcu_event_41000028,
      event_4100002c = stats.mcu_event_4100002c,
      event_41000000 = stats.mcu_event_41000000,
      grin_reset_count = stats.mcu_grin_reset_count,
      recent_watchdog_resets = stats.mcu_recent_watchdog_resets,
      unchanged_progress_samples = stats.mcu_unchanged_progress_samples,
      governor_cooldown = stats.mcu_governor_cooldown,
    }, DIAG_DDR_SAMPLE_LIMIT)
  else
    stats.mcu_governor_error = "read_failed " .. table.concat(errors, "; ")
  end
end

local function monotonic_ms()
  local f = io.open("/proc/uptime", "r")
  if f then
    local s = f:read("*l") or ""
    f:close()
    local up = tonumber(s:match("^(%d+%.?%d*)"))
    if up then return math.floor(up * 1000) end
  end
  return os.time() * 1000
end

local function decoded_lane_from_byte(b)
  if not b then return 0 end
  return math.floor((b % 64) / 16)
end

local function lanes_for_mode()
  local function repeat_lane(lane)
    local lanes = {}
    for _ = 1, frames_per_lane do lanes[#lanes + 1] = lane end
    return lanes
  end
  if lane_mode == "1" then return repeat_lane(1) end
  if lane_mode == "2" then return repeat_lane(2) end
  if lane_mode == "3" then return repeat_lane(3) end
  return {1, 2, 3}
end

local function update_fault_state(status, now)
  local reasons = {}
  local uptime = now - start_time
  local function add(reason) reasons[#reasons + 1] = reason end

  if status == "error" then add("miner_error") end
  if uptime > 60 and not stats.stratum_connected then add("stratum_disconnected") end
  if uptime > 120 and stats.seconds_since_valid_job > 120 then add("no_recent_job") end
  if uptime > 180 and stats.seconds_since_last_result > 180 then add("no_recent_results") end
  if tonumber(stats.fan_control_temp_c) and tonumber(stats.fan_control_temp_c) >= fan_hard_c then add("high_temp") end
  if stats.mcu_progress_counter_resets and stats.mcu_progress_counter_resets > 0 then add("mcu_progress_reset") end
  if stats.mcu_grin_reset_count and stats.mcu_grin_reset_count > 0 then add("mcu_grin_reset") end
  if stats.cmd01_error and stats.cmd01_error > 0 then add("cmd01_error") end
  if stats.submit_error and stats.submit_error >= 10 and stats.accepted > 0 and stats.submit_error > stats.accepted * 0.10 then add("submit_error_rate") end
  if fan_auto_enabled and uptime > 60 and stats.fan_rpm then
    local missing = 0
    for _, rpm in ipairs(stats.fan_rpm) do
      if (tonumber(rpm) or 0) <= 0 then missing = missing + 1 end
    end
    if missing > 0 then add("fan_tach_missing") end
  end

  stats.fault_reasons = reasons
  stats.fault = #reasons > 0
  set_fault_led(stats.fault)
end

local function write_stats(status)
  if status then stats.status = status end
  local now = os.time()
  poll_fan_tach()
  if mcu_governor_poll_enabled then poll_mcu_governor(false) end
  ddr_update_residency()
  ddr_account_resets_if_changed()
  ddr_compute_metrics()
  ddr_persist_accounting(false)
  stats.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  stats.uptime_seconds = now - start_time
  if not last_rate_sample_epoch then
    last_rate_sample_epoch = now
    last_rate_sample_accepted = stats.accepted
  else
    local dt = now - last_rate_sample_epoch
    if dt > 0 then
      local delta_shares = stats.accepted - (last_rate_sample_accepted or stats.accepted)
      if delta_shares < 0 then delta_shares = 0 end
      local instant_spm = delta_shares / dt * 60
      rate_1m = ema(rate_1m, instant_spm, 60, dt)
      rate_5m = ema(rate_5m, instant_spm, 300, dt)
      rate_15m = ema(rate_15m, instant_spm, 900, dt)
      stats.instant_shares_per_min = instant_spm
      last_rate_sample_epoch = now
      last_rate_sample_accepted = stats.accepted
    end
  end
  if stats.uptime_seconds > 0 then
    stats.accepted_per_min_avg = stats.accepted / stats.uptime_seconds * 60
  end
  stats.accepted_per_min_1m = rate_1m or 0
  stats.accepted_per_min_5m = rate_5m or 0
  stats.accepted_per_min_15m = rate_15m or 0
  stats.accepted_per_min = stats.accepted_per_min_avg
  stats.shares_per_min = stats.accepted_per_min_avg
  stats.hashrate_gps_1m = stats.accepted_per_min_1m * shares_per_min_to_gps
  stats.hashrate_gps_5m = stats.accepted_per_min_5m * shares_per_min_to_gps
  stats.hashrate_gps_15m = stats.accepted_per_min_15m * shares_per_min_to_gps
  stats.hashrate_gps_avg = stats.accepted_per_min_avg * shares_per_min_to_gps
  stats.estimated_hashrate_gps = stats.hashrate_gps_avg
  stats.hashrate_gps = stats.hashrate_gps_avg
  if stats.cgminer_hashrate and stats.cgminer_hashrate > 0 then
    stats.hashrate = stats.cgminer_hashrate
    stats.hashrate_unit = stats.cgminer_hashrate_unit or "G/s"
    stats.hashrate_source = "cgminer_estats"
  else
    stats.hashrate = stats.hashrate_gps_avg
    stats.hashrate_unit = "G/s"
    stats.hashrate_source = "accepted_lifetime_fallback"
  end
  if stats.last_work_set_epoch then stats.seconds_since_last_work_set = now - stats.last_work_set_epoch end
  if stats.last_result_epoch then stats.seconds_since_last_result = now - stats.last_result_epoch end
  if stats.last_accept_epoch then stats.seconds_since_last_accept = now - stats.last_accept_epoch end
  if stats.last_stratum_byte_epoch then stats.seconds_since_stratum_byte = now - stats.last_stratum_byte_epoch end
  if stats.last_valid_job_epoch then stats.seconds_since_valid_job = now - stats.last_valid_job_epoch end
  update_fault_state(stats.status, now)
  local tmp = stats_path .. ".tmp"
  local f = io.open(tmp, "w")
  if f then
    stats.stats_payload_bytes = 0
    local payload = json.encode(stats)
    stats.stats_payload_bytes = #payload
    payload = json.encode(stats)
    f:write(payload)
    f:write("\n")
    f:close()
    os.execute("mv " .. shell_quote(tmp) .. " " .. shell_quote(stats_path))
  end
end

local function stratum_start(url)
  local host, port = parse_stratum_url(url)
  local base = "/tmp/custom-stratum-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  local in_fifo = base .. ".in"
  local out_file = base .. ".out"
  local pid_file = base .. ".pid"
  os.execute("rm -f /tmp/custom-stratum-*")
  os.execute("rm -f " .. shell_quote(in_fifo) .. " " .. shell_quote(out_file) .. " " .. shell_quote(pid_file))
  os.execute("mkfifo " .. shell_quote(in_fifo))
  os.execute(": > " .. shell_quote(out_file))
  os.execute("(nc " .. shell_quote(host) .. " " .. tostring(port) .. " < " .. shell_quote(in_fifo) .. " >> " .. shell_quote(out_file) .. " 2>/tmp/custom-stratum-nc.err & echo $! > " .. shell_quote(pid_file) .. ")")
  local writer = io.open(in_fifo, "w")
  if not writer then error("failed to open stratum fifo writer") end
  return {host = host, port = port, in_fifo = in_fifo, out_file = out_file, pid_file = pid_file, writer = writer, offset = 0, next_id = 0, partial = ""}
end

local function stratum_alive(st)
  if not st or not st.pid_file then return false end
  local pid = cmd_output("cat " .. shell_quote(st.pid_file) .. " 2>/dev/null")
  if pid == "" then return false end
  local ok = os.execute("kill -0 " .. shell_quote(pid) .. " >/dev/null 2>&1")
  return ok == true or ok == 0
end

local function stratum_send(st, method, params_raw)
  if not st or not st.writer then return nil, "" end
  local id = tostring(st.next_id)
  st.next_id = st.next_id + 1
  local raw = '{"jsonrpc":"2.0","method":"' .. method .. '","id":"' .. id .. '","params":' .. params_raw .. '}'
  local ok = pcall(function()
    st.writer:write(raw, "\n")
    st.writer:flush()
  end)
  if not ok then return nil, raw end
  return id, raw
end

local function stratum_send_raw(st, raw)
  if not st or not st.writer then return false end
  local ok = pcall(function()
    st.writer:write(raw, "\n")
    st.writer:flush()
  end)
  return ok
end

local function stratum_send_response(st, id, result_raw)
  if id == nil then return false end
  local raw = '{"jsonrpc":"2.0","id":' .. json.encode(id) .. ',"result":' .. (result_raw or "null") .. '}'
  return stratum_send_raw(st, raw)
end

local function stratum_poll(st)
  local f = io.open(st.out_file, "r")
  if not f then return {} end
  f:seek("set", st.offset)
  local chunk = f:read("*a") or ""
  st.offset = f:seek()
  f:close()

  local lines = {}
  if #chunk > 0 then
    stats.last_stratum_byte_epoch = os.time()
    stats.last_stratum_byte_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
    stats.stratum_connected = true
    local data = (st.partial or "") .. chunk
    st.partial = ""
    while true do
      local nl = data:find("\n", 1, true)
      if not nl then break end
      local line = data:sub(1, nl - 1):gsub("\r$", "")
      data = data:sub(nl + 1)
      if #line > 0 then lines[#lines + 1] = line end
    end
    st.partial = data
    stats.partial_stratum_bytes = #(st.partial or "")
  end
  return lines
end

local function stratum_stop(st)
  if st and st.writer then pcall(function() st.writer:close() end) end
  if st and st.pid_file then
    os.execute("kill $(cat " .. shell_quote(st.pid_file) .. " 2>/dev/null) >/dev/null 2>&1 || true")
    os.execute("rm -f " .. shell_quote(st.in_fifo or "") .. " " .. shell_quote(st.out_file or "") .. " " .. shell_quote(st.pid_file or ""))
  end
end

local function stop_stock()
  os.execute("/etc/init.d/cron stop >/dev/null 2>&1 || true")
  os.execute("/etc/init.d/appmonitor stop >/dev/null 2>&1 || true")
  os.execute("/etc/init.d/cgminer stop >/dev/null 2>&1 || true")
  os.execute("sleep 3")
  os.execute("killall -s 9 cgminer >/dev/null 2>&1 || true")
  os.execute("rm -f /tmp/.uci/cgminer /var/run/cgminer.pid")
end

local function restore_stock()
  os.execute("killall custom-fantach >/dev/null 2>&1 || true")
  os.execute("for p in /tmp/custom-stratum-*.pid; do [ -f \"$p\" ] && kill $(cat \"$p\" 2>/dev/null) >/dev/null 2>&1 || true; done")
  os.execute("rm -f /tmp/custom-stratum-* /tmp/custom-stratum-nc.err >/dev/null 2>&1 || true")
  os.execute("rm -f /tmp/.uci/cgminer /var/run/cgminer.pid")
  os.execute("if [ -f /usr/bin/cgminer.stock ]; then cp /usr/bin/cgminer.stock /usr/bin/cgminer; chmod +x /usr/bin/cgminer; fi")
  os.execute("/usr/bin/g1m-config ensure >/dev/null 2>&1 || true")
  os.execute("/etc/init.d/cgminer start >/dev/null 2>&1 || true")
  os.execute("/etc/init.d/appmonitor start >/dev/null 2>&1 || true")
  os.execute("/etc/init.d/cron start >/dev/null 2>&1 || true")
end

local function send_frame(serial, label, bytes)
  serial:write(bytes)
  serial:flush()
  emit({event = "send", label = label, bytes = #bytes, epoch = os.time()})
end

local function drain_serial(serial, drain_ms)
  local deadline = monotonic_ms() + drain_ms
  while monotonic_ms() < deadline do
    local chunk = serial:read(256)
    if chunk and #chunk > 0 then
      stats.uart_drain_bytes = stats.uart_drain_bytes + #chunk
    end
  end
end

local function valid_stratum_job(j)
  return j and tostring(j.job_id or "") ~= "" and tostring(j.pre_pow or "") ~= ""
end

local function main()
  if cfg.url == "" or cfg.user == "" then error("missing pool config") end
  emit({event = "miner_start", duration = duration, dwell = dwell, pool = cfg.url})
  ddr_load_accounting()
  start_fan_tach_monitor()
  write_stats("starting")

  local pending_submit = {}
  local st = nil
  local gjt_id = nil
  local awaiting_valid_job_epoch = nil
  local diag_state = { pool_generation = 0, send_seq = 0, pruned_jobs = {}, pruned_by_alias = {}, sent_work = {}, sent_by_alias = {}, alias_owners = {}, collision_by_alias = {}, result_signatures = {}, result_signature_order = {}, result_tail_keys = {}, result_tail_key_order = {}, result_tail_quarantine = {}, last_stock_tail_key = "", last_stock_tail_at = "", last_result_signature = "" }
  local function connect_stratum(reason)
    if st then stratum_stop(st) end
    pending_submit = {}
    diag_state.pool_generation = diag_state.pool_generation + 1
    st = stratum_start(cfg.url)
    if reason ~= "startup" then stats.stratum_reconnects = stats.stratum_reconnects + 1 end
    stats.stratum_connected = true
    stats.stratum_disconnect_reason = reason or ""
    stats.last_stratum_byte_epoch = os.time()
    stats.last_stratum_byte_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
    awaiting_valid_job_epoch = os.time()
    stratum_send(st, "login", '{"login":"' .. json_escape(cfg.user) .. '","pass":"' .. json_escape(cfg.password ~= "" and cfg.password or "x") .. '","agent":"custom-g1-lua/0.1"}')
    gjt_id = stratum_send(st, "getjobtemplate", "null")
    stats.template_requests = stats.template_requests + 1
    emit({event = "stratum_connect", reason = reason or "startup", template_id = gjt_id})
  end

  connect_stratum("startup")
  local initial_job = nil
  local deadline = os.time() + 30
  while os.time() < deadline and not initial_job do
    for _, line in ipairs(stratum_poll(st)) do
      local ok, obj = pcall(json.decode, line)
      if ok and obj then
        if tostring(obj.id or "") == tostring(gjt_id) and valid_stratum_job(obj.result) then initial_job = obj.result end
        if obj.method == "job" and valid_stratum_job(obj.params) then initial_job = obj.params end
      end
    end
    os.execute("sleep 1")
  end
  if not initial_job then error("no initial stratum job") end
  stats.last_valid_job_epoch = os.time()
  stats.last_valid_job_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
  awaiting_valid_job_epoch = nil

  capture_stock_sensors()
  maybe_update_fan_control()
  write_stats("starting")
  stop_stock()
  os.execute("stty -F " .. shell_quote(tty) .. " 4000000 raw -echo -ixon -ixoff -crtscts min 0 time 1")
  local serial = io.open(tty, "r+b")
  if not serial then error("failed to open " .. tty) end
  drain_serial(serial, 2000)
  send_frame(serial, "algo-grin", hex_to_bytes(algo_frame_hex))

  local active = nil
  local active_by_lane = {}
  local latest_job = initial_job
  local tracked = {}
  local tracked_unique = {}
  local seq = 0
  local submitted = {}
  local submitted_proofs = {}
  local duplicate_proof_relax_window_epoch = os.time()
  local duplicate_proof_relax_window_count = 0
  local buf = {}
  local result_no = 0
  local submit_id_to_job = {}
  local last_sent_stratum_job_key = nil
  local last_job_id = nil
  local last_difficulty = nil
  local last_pre_pow = nil
  local last_result_epoch = 0
  local last_accept_epoch = 0
  local last_work_set_epoch = 0
  local last_work_frames = {}
  local last_resend_ms = 0
  local duplicate_results_since_work = 0
  local unknown_results_since_work = 0
  local adjacent_duplicate_burst_count = 0
  local adjacent_duplicate_burst_epoch = 0
  local cmd04_event_sample
  
  local function compact_digest(s)
    if not s then return "" end
    return hash_string32(tostring(s)) .. ":" .. tostring(s):sub(1, 16)
  end

  local function prune_diag_indexes()
    local now = os.time()
    local function prune_list(list, limit)
      while #list > limit do table.remove(list, 1) end
      while #list > 0 and list[1].epoch and now - list[1].epoch > 1800 do table.remove(list, 1) end
    end
    prune_list(diag_state.pruned_jobs, 300)
    prune_list(diag_state.sent_work, 500)
    for alias, item in pairs(diag_state.pruned_by_alias) do
      if item.epoch and now - item.epoch > 1800 then diag_state.pruned_by_alias[alias] = nil end
    end
    for alias, item in pairs(diag_state.sent_by_alias) do
      if item.epoch and now - item.epoch > 1800 then diag_state.sent_by_alias[alias] = nil end
    end
    for alias, item in pairs(diag_state.alias_owners) do
      if item.epoch and now - item.epoch > 1800 then diag_state.alias_owners[alias] = nil end
    end
    for alias, item in pairs(diag_state.collision_by_alias) do
      if item.epoch and now - item.epoch > 1800 then diag_state.collision_by_alias[alias] = nil end
    end
    while #diag_state.result_signature_order > 1000 do
      local old = table.remove(diag_state.result_signature_order, 1)
      diag_state.result_signatures[old] = nil
    end
    while #diag_state.result_signature_order > 0 do
      local key = diag_state.result_signature_order[1]
      local item = diag_state.result_signatures[key]
      if item and item.first_epoch and now - item.first_epoch > 1800 then
        diag_state.result_signatures[key] = nil
        table.remove(diag_state.result_signature_order, 1)
      else
        break
      end
    end
    while #diag_state.result_tail_key_order > 1000 do
      local old = table.remove(diag_state.result_tail_key_order, 1)
      diag_state.result_tail_keys[old] = nil
    end
    while #diag_state.result_tail_key_order > 0 do
      local key = diag_state.result_tail_key_order[1]
      local item = diag_state.result_tail_keys[key]
      if item and item.first_epoch and now - item.first_epoch > 1800 then
        diag_state.result_tail_keys[key] = nil
        table.remove(diag_state.result_tail_key_order, 1)
      else
        break
      end
    end
    for key, until_epoch in pairs(diag_state.result_tail_quarantine) do
      if not until_epoch or now >= until_epoch then
        diag_state.result_tail_quarantine[key] = nil
      end
    end
  end

  local function make_result_diag(frame, decoded_result_lane, result_lane_byte)
    local nonce_hex = hex_range(frame, 5, 12)
    local proof_hash = hash_string32(hex_range(frame, 13, 180))
    local result_crc = hex_range(frame, 185, 186)
    local b6_b7 = hex_range(frame, 183, 184)
    local tail_b4_b7 = hex_range(frame, 181, 184)
    return {
      epoch = os.time(),
      at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      raw_frame_hash = hash_string32(hex_range(frame, 1, #frame)),
      chip = frame[4] or 0,
      lane_byte = result_lane_byte and string.format("%02x", result_lane_byte) or "",
      decoded_lane = decoded_result_lane or 0,
      nonce_hex = nonce_hex,
      proof_hash = proof_hash,
      tail_b4_b7 = tail_b4_b7,
      b6_b7 = b6_b7,
      result_crc = result_crc,
      signature = nonce_hex .. ":" .. proof_hash .. ":" .. result_crc .. ":" .. b6_b7,
      stock_tail_key = result_crc,
      stock_progress_key = b6_b7,
      ddr_raw_hex = stats.mcu_ddr_raw_hex,
      ddr_effective_mhz = stats.mcu_ddr_effective_mhz,
      active_job_key = active and tostring(active.key or "") or "",
      active_pool_job_key = active and tostring(active.stratum_job_key or "") or "",
      pool_generation = diag_state.pool_generation,
    }
  end

  local function merge_signature_status(current_status, next_status)
    local current = tostring(current_status or "")
    local next_value = tostring(next_status or "")
    if next_value == "" then return current end
    if (next_value == "suppressed" or next_value == "unknown")
      and (current == "pending" or current == "accepted" or current == "rejected" or current == "stale_suppressed") then
      return current
    end
    return next_value
  end

  local function note_result_signature(rdiag, status, job, submit_id)
    local now = os.time()
    local tail_item = diag_state.result_tail_keys[rdiag.stock_tail_key]
    if not tail_item then
      tail_item = {
        stock_tail_key = rdiag.stock_tail_key,
        first_epoch = now,
        first_seen = rdiag.at,
        last_seen = rdiag.at,
        repeat_count = 0,
        first_signature = rdiag.signature,
        last_signature = rdiag.signature,
        first_status = status or "unknown",
        current_status = status or "unknown",
        first_progress_key = rdiag.stock_progress_key,
        last_progress_key = rdiag.stock_progress_key,
      }
      diag_state.result_tail_keys[rdiag.stock_tail_key] = tail_item
      diag_state.result_tail_key_order[#diag_state.result_tail_key_order + 1] = rdiag.stock_tail_key
    else
      tail_item.repeat_count = (tail_item.repeat_count or 0) + 1
      tail_item.last_seen = rdiag.at
      tail_item.last_signature = rdiag.signature
      tail_item.current_status = merge_signature_status(tail_item.current_status, status)
      tail_item.last_progress_key = rdiag.stock_progress_key
      tail_item.last_delta_ms = math.floor((now - (tail_item.first_epoch or now)) * 1000)
      stats.stock_tail_key_repeat_total = stats.stock_tail_key_repeat_total + 1
    end

    local key = rdiag.signature
    local item = diag_state.result_signatures[key]
    if not item then
      item = {
        signature = key,
        first_epoch = now,
        first_seen = rdiag.at,
        last_seen = rdiag.at,
        repeat_count = 0,
        first_status = status or "unknown",
        current_status = status or "unknown",
        stock_tail_key = rdiag.stock_tail_key,
        nonce_hex = rdiag.nonce_hex,
        proof_hash = rdiag.proof_hash,
        result_crc = rdiag.result_crc,
        b6_b7 = rdiag.b6_b7,
        stock_progress_key = rdiag.stock_progress_key,
        lane = rdiag.decoded_lane,
        job_key = job and tostring(job.key or "") or "",
        pool_job_key = job and tostring(job.stratum_job_key or "") or "",
        submit_id = submit_id or "",
        stock_tail_repeat_count = tail_item and tail_item.repeat_count or 0,
        stock_tail_first_status = tail_item and tail_item.first_status or "",
        stock_tail_first_signature = tail_item and tail_item.first_signature or "",
      }
      diag_state.result_signatures[key] = item
      diag_state.result_signature_order[#diag_state.result_signature_order + 1] = key
    else
      item.repeat_count = (item.repeat_count or 0) + 1
      item.last_seen = rdiag.at
      item.current_status = merge_signature_status(item.current_status, status)
      item.last_delta_ms = math.floor((now - (item.first_epoch or now)) * 1000)
      if item.stock_tail_key == rdiag.stock_tail_key then
        stats.duplicate_stock_tail_key_repeat = stats.duplicate_stock_tail_key_repeat + 1
      end
      item.stock_tail_repeat_count = tail_item and tail_item.repeat_count or item.stock_tail_repeat_count
      item.stock_tail_first_status = tail_item and tail_item.first_status or item.stock_tail_first_status
      item.stock_tail_first_signature = tail_item and tail_item.first_signature or item.stock_tail_first_signature
    end
    prune_diag_indexes()
    return item
  end

  local function duplicate_phase_class(status)
    local normalized = tostring(status or "unknown")
    if normalized == "pending" then return "before_submit" end
    if normalized == "accepted" then return "after_submit" end
    if normalized == "rejected" then return "after_reject" end
    if normalized == "stale_suppressed" then return "job_rollover" end
    return "unknown"
  end

  local function note_adjacent_duplicate_phase(phase)
    local field = "adjacent_duplicate_class_" .. tostring(phase or "unknown")
    if stats[field] == nil then field = "adjacent_duplicate_class_unknown" end
    stats[field] = (stats[field] or 0) + 1
  end

  local function adjacent_duplicate_quarantine_remaining(stock_tail_key, now_epoch)
    local until_epoch = diag_state.result_tail_quarantine[stock_tail_key or ""]
    if not until_epoch then return 0 end
    local remaining = until_epoch - (now_epoch or os.time())
    if remaining <= 0 then
      diag_state.result_tail_quarantine[stock_tail_key or ""] = nil
      return 0
    end
    return remaining
  end

  local function arm_adjacent_duplicate_quarantine(stock_tail_key, now_epoch)
    if not stock_tail_key or stock_tail_key == "" then return 0 end
    if ADJACENT_DUPLICATE_QUARANTINE_SECONDS <= 0 then return 0 end
    local until_epoch = (now_epoch or os.time()) + ADJACENT_DUPLICATE_QUARANTINE_SECONDS
    diag_state.result_tail_quarantine[stock_tail_key] = until_epoch
    return ADJACENT_DUPLICATE_QUARANTINE_SECONDS
  end

  local function update_result_signature_status(signature, status)
    if signature and diag_state.result_signatures[signature] then
      diag_state.result_signatures[signature].current_status = status
      diag_state.result_signatures[signature].last_status_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
  end

  local function lookup_alias(candidates, index)
    for _, alias in ipairs(candidates or {}) do
      if index[alias] then return alias, index[alias] end
    end
    return nil, nil
  end

  local function classify_unknown_result(rdiag, candidates, signature_item)
    local now = os.time()
    local pruned_alias, pruned = lookup_alias(candidates, diag_state.pruned_by_alias)
    local sent_alias, sent = lookup_alias(candidates, diag_state.sent_by_alias)
    local collision_alias, collision = lookup_alias(candidates, diag_state.collision_by_alias)
    local owner_alias, owner = lookup_alias(candidates, diag_state.alias_owners)
    local lane_active = active_by_lane[rdiag.decoded_lane]
    local primary = "unknown_no_match"
    local lane_matches_sent = false
    local current_job_matches_sent_job = false
    local pool_generation_matches = false

    if sent then
      lane_matches_sent = (sent.lane == rdiag.decoded_lane)
      current_job_matches_sent_job = (lane_active and tostring(lane_active.key or "") == tostring(sent.local_job_key or ""))
      pool_generation_matches = (sent.pool_generation == diag_state.pool_generation)
    elseif pruned then
      lane_matches_sent = (pruned.lane == rdiag.decoded_lane)
      pool_generation_matches = (pruned.pool_generation == diag_state.pool_generation)
    elseif owner then
      lane_matches_sent = (owner.lane == rdiag.decoded_lane)
      pool_generation_matches = (owner.pool_generation == diag_state.pool_generation)
    end

    if collision then
      primary = "unknown_alias_collision"
    elseif pruned then
      primary = "unknown_recent_pruned_alias_hit"
    elseif sent then
      if sent.pool_generation ~= diag_state.pool_generation then
        primary = "unknown_post_reconnect_late"
      elseif sent.lane ~= rdiag.decoded_lane then
        primary = "unknown_lane_mismatch"
      elseif lane_active and tostring(lane_active.key or "") ~= tostring(sent.local_job_key or "") then
        primary = "unknown_stale_current_key_mismatch"
      else
        primary = "unknown_recent_sent_work_hit"
      end
    elseif owner then
      primary = "unknown_active_alias_miss"
    else
      primary = "unknown_no_match"
    end

    stats[primary] = (stats[primary] or 0) + 1
    if primary ~= "unknown_no_match" then stats.duplicate_salvage_candidate = stats.duplicate_salvage_candidate + 1 end
    local stock_tail_repeat_count = signature_item and tonumber(signature_item.stock_tail_repeat_count or 0) or 0
    if stock_tail_repeat_count > 0 then stats.unknown_stock_tail_key_repeat = stats.unknown_stock_tail_key_repeat + 1 end

    return {
      primary_bucket = primary,
      matched_full_8 = candidates and candidates[1] and ((sent_alias == candidates[1]) or (pruned_alias == candidates[1]) or (collision_alias == candidates[1]) or (owner_alias == candidates[1])) or false,
      matched_id6 = candidates and candidates[2] and ((sent_alias == candidates[2]) or (pruned_alias == candidates[2]) or (collision_alias == candidates[2]) or (owner_alias == candidates[2])) or false,
      matched_first4 = candidates and candidates[3] and ((sent_alias == candidates[3]) or (pruned_alias == candidates[3]) or (collision_alias == candidates[3]) or (owner_alias == candidates[3])) or false,
      matched_mid4 = candidates and candidates[4] and ((sent_alias == candidates[4]) or (pruned_alias == candidates[4]) or (collision_alias == candidates[4]) or (owner_alias == candidates[4])) or false,
      matched_recent_pruned = pruned ~= nil,
      matched_recent_sent_work = sent ~= nil,
      alias_collision_detected = collision ~= nil,
      lane_matches_sent = lane_matches_sent,
      current_job_matches_sent_job = current_job_matches_sent_job,
      active_lane_job_key = lane_active and tostring(lane_active.key or "") or "",
      pool_generation_matches = pool_generation_matches,
      matched_alias = sent_alias or pruned_alias or collision_alias or owner_alias or "",
      matched_sent_job_key = sent and tostring(sent.local_job_key or "") or "",
      matched_pruned_job_key = pruned and tostring(pruned.local_job_key or "") or "",
      matched_owner_job_key = owner and tostring(owner.local_job_key or "") or "",
      job_age_ms = sent and math.floor((now - (sent.sent_epoch or now)) * 1000) or nil,
      send_age_ms = sent and math.floor((now - (sent.sent_epoch or now)) * 1000) or nil,
      prune_age_ms = pruned and math.floor((now - (pruned.epoch or now)) * 1000) or nil,
      pool_generation = diag_state.pool_generation,
      sent_pool_generation = sent and sent.pool_generation or nil,
      pruned_pool_generation = pruned and pruned.pool_generation or nil,
      stock_tail_key = rdiag.stock_tail_key,
      stock_progress_key = rdiag.stock_progress_key,
      stock_tail_repeat_count = stock_tail_repeat_count,
      stock_tail_first_status = signature_item and signature_item.stock_tail_first_status or "",
      stock_tail_first_signature = signature_item and signature_item.stock_tail_first_signature or "",
    }
  end

  local function classify_duplicate_result(rdiag, job, signature_item, phase, status_override)
    local status = status_override or (signature_item and tostring(signature_item.current_status or signature_item.first_status or "unknown")) or "unknown"
    local phase_class = duplicate_phase_class(status)
    local bucket
    if phase == "stock_adjacent" then
      bucket = "duplicate_stock_adjacent_repeat"
    elseif phase == "before_submit" or status == "pending" then
      bucket = "duplicate_repeat_before_submit"
    elseif status == "rejected" then
      bucket = "duplicate_after_reject"
    else
      bucket = "duplicate_true_repeat_after_submit"
    end
    stats[bucket] = (stats[bucket] or 0) + 1
    return {
      duplicate_bucket = bucket,
      first_seen = signature_item and signature_item.first_seen or rdiag.at,
      last_seen = rdiag.at,
      repeat_count = signature_item and signature_item.repeat_count or 0,
      first_status = signature_item and signature_item.first_status or "unknown",
      original_status = status,
      phase_class = phase_class,
      stock_tail_key_repeats = signature_item and signature_item.stock_tail_key == rdiag.stock_tail_key or false,
      stock_tail_key = rdiag.stock_tail_key,
      stock_progress_key = rdiag.stock_progress_key,
      stock_tail_repeat_count = signature_item and tonumber(signature_item.stock_tail_repeat_count or 0) or 0,
      stock_tail_first_status = signature_item and signature_item.stock_tail_first_status or "",
      stock_tail_first_signature = signature_item and signature_item.stock_tail_first_signature or "",
      delta_ms = signature_item and signature_item.last_delta_ms or 0,
      job_age_ms = job and job.sent_epoch and math.floor((os.time() - job.sent_epoch) * 1000) or nil,
      lane = job and job.lane or rdiag.decoded_lane,
    }
  end

  local function should_store_duplicate_sample(dup_diag)
    local repeat_count = tonumber(dup_diag and dup_diag.repeat_count or 0) or 0
    local stock_tail_repeat_count = tonumber(dup_diag and dup_diag.stock_tail_repeat_count or 0) or 0
    local repeat_score = math.max(repeat_count, stock_tail_repeat_count)
    if repeat_score <= 1 then return true end
    if repeat_score == 2 or repeat_score == 4 or repeat_score == 8 then return true end
    if repeat_score > 0 and repeat_score % 16 == 0 then return true end
    stats.duplicate_samples_compacted = stats.duplicate_samples_compacted + 1
    return false
  end

  local function stale_submit_reason(job)
    if not job then return "no_matched_job" end
    local now = os.time()
    local age = job.sent_epoch and (now - job.sent_epoch) or 0
    if job.pool_generation and job.pool_generation ~= diag_state.pool_generation then
      return "pool_generation_mismatch"
    end
    if RESULT_SUBMIT_MAX_AGE_SECONDS > 0 and age > RESULT_SUBMIT_MAX_AGE_SECONDS then
      return "job_age_limit"
    end
    local current_key = valid_stratum_job(latest_job)
      and (tostring(latest_job.job_id or "") .. ":" .. tostring(latest_job.difficulty or "") .. ":" .. tostring(latest_job.pre_pow or ""))
      or ""
    if current_key ~= "" and tostring(job.stratum_job_key or "") ~= current_key then
      local stale_grace = STALE_RESULT_GRACE_SECONDS
      local same_height = tonumber(job.height) and tonumber(latest_job and latest_job.height) and tonumber(job.height) == tonumber(latest_job.height)
      if same_height and TWO_MINERS_STALE_GRACE_SECONDS > stale_grace then
        stale_grace = TWO_MINERS_STALE_GRACE_SECONDS
      end
      if age > stale_grace then return "current_job_mismatch" end
    end
    return nil
  end

  local function suppress_stale_submit(reason, frame, job, matched_key, decoded_result_lane, result_lane_byte, result_diag)
    local sig_item = note_result_signature(result_diag, "stale_suppressed", job, "")
    local dup_diag = classify_duplicate_result(result_diag, job, sig_item, "before_submit")
    stats.stale_submit_suppressed = stats.stale_submit_suppressed + 1
    stats.stale_result_frames = stats.stale_result_frames + 1
    stats.skipped_results = stats.skipped_results + 1
    if reason == "pool_generation_mismatch" then
      stats.stale_pool_generation_suppressed = stats.stale_pool_generation_suppressed + 1
    elseif reason == "current_job_mismatch" then
      stats.stale_current_job_suppressed = stats.stale_current_job_suppressed + 1
    elseif reason == "job_age_limit" then
      stats.stale_job_age_suppressed = stats.stale_job_age_suppressed + 1
    end
    cmd04_event_sample("stale_submit_suppressed", frame, job, matched_key, decoded_result_lane, result_lane_byte, reason, {
      stale_reason = reason,
      result_signature = result_diag.signature,
      duplicate_bucket = dup_diag.duplicate_bucket,
      job_pool_generation = job and job.pool_generation or nil,
      current_pool_generation = diag_state.pool_generation,
      job_pool_key = job and tostring(job.stratum_job_key or "") or "",
      current_pool_key = valid_stratum_job(latest_job)
        and (tostring(latest_job.job_id or "") .. ":" .. tostring(latest_job.difficulty or "") .. ":" .. tostring(latest_job.pre_pow or ""))
        or "",
    })
    emit({event = "stale_submit_suppressed", reason = reason, seq = job and job.key or "", nonce_hex = result_diag.nonce_hex, matched_key = matched_key or ""})
  end

  local function prune_pending_submit()
    local now = os.time()
    for id, item in pairs(pending_submit) do
      if item.sent_epoch and now - item.sent_epoch > PENDING_SUBMIT_TIMEOUT_SECONDS then
        pending_submit[id] = nil
        stats.pending_submit_timeouts = stats.pending_submit_timeouts + 1
      end
    end
  end

  local function prune_submitted_proofs()
    local now = os.time()
    for key, epoch in pairs(submitted_proofs) do
      if now - epoch > DUPLICATE_PROOF_RETENTION_SECONDS then
        submitted_proofs[key] = nil
      end
    end
  end

  local function stratum_job_key(j)
    if not j then return "" end
    return tostring(j.job_id or "") .. ":" .. tostring(j.difficulty or "") .. ":" .. tostring(j.pre_pow or "")
  end

  local function should_send_for_job(j)
    local now = os.time()
    local job_id = tostring(j and j.job_id or "")
    local difficulty = tostring(j and j.difficulty or "")
    local pre_pow = tostring(j and j.pre_pow or "")
    if job_id == "" or pre_pow == "" then return false, "missing_job_fields" end
    if last_job_id == nil then return true, "first_job" end
    if difficulty ~= last_difficulty then return true, "difficulty_changed" end
    if pre_pow ~= last_pre_pow then
      local clean_jobs = j and (j.clean_jobs == true or tostring(j.clean_jobs or "") == "true")
      local last_height = active and tonumber(active.height) or tonumber(latest_job and latest_job.height)
      local new_height = tonumber(j and j.height)
      if PREPOW_DEBOUNCE_SECONDS > 0
        and not clean_jobs
        and last_height and new_height and new_height == last_height
        and last_work_set_epoch > 0
        and now - last_work_set_epoch < PREPOW_DEBOUNCE_SECONDS then
        return false, "pre_pow_debounced"
      end
      return true, "pre_pow_changed"
    end
    if job_id ~= last_job_id then
      local clean_jobs = j and (j.clean_jobs == true or tostring(j.clean_jobs or "") == "true")
      if JOB_ID_DEBOUNCE_SECONDS > 0
        and not clean_jobs
        and last_work_set_epoch > 0
        and now - last_work_set_epoch < JOB_ID_DEBOUNCE_SECONDS then
        return false, "job_id_debounced"
      end
      return true, "job_id_changed"
    end
    return false, "duplicate_notify"
  end

  local function force_lane_in_nonce(nonce_hex, lane)
    local b = tonumber(nonce_hex:sub(5, 6), 16) or 0
    b = b % 256
    local base = (b % 16) + (math.floor(b / 64) * 64)
    if lane == 1 then b = base + 0x10
    elseif lane == 2 then b = base + 0x20
    else b = base + 0x30 end
    return nonce_hex:sub(1, 4) .. string.format("%02x", b) .. "00" .. nonce_hex:sub(9)
  end

  local function nonce_aliases(nonce_hex)
    nonce_hex = tostring(nonce_hex or "")
    local aliases = {
      nonce_hex,
      nonce_hex:sub(1, 12),
      nonce_hex:sub(1, 8),
    }
    if #nonce_hex >= 12 then
      aliases[#aliases + 1] = "mid4:" .. nonce_hex:sub(5, 12)
    end
    return aliases
  end

  local function alias_kind(alias)
    alias = tostring(alias or "")
    if alias:sub(1, 5) == "mid4:" then return "mid4" end
    return "direct"
  end

  local function prune_old_tracked()
    local now = os.time()
    local unique_count = 0
    for key, job in pairs(tracked_unique) do
      if job.sent_epoch and now - job.sent_epoch > job_retention_seconds then
        local removed_aliases = 0
        local pruned = {
          epoch = now,
          at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          local_job_key = tostring(job.key or key),
          pool_job_id = tostring(job.job_id or ""),
          pool_job_key = tostring(job.stratum_job_key or ""),
          pool_generation = job.pool_generation or diag_state.pool_generation,
          clean_jobs = job.clean_jobs or false,
          previous_job_key = tostring(job.previous_job_key or ""),
          prune_reason = "age_retention",
          age_at_prune = now - job.sent_epoch,
          aliases_removed = #(job.aliases or {}),
          prepow_digest = tostring(job.prepow_digest or ""),
          lane = job.lane or 0,
          sent_epoch = job.sent_epoch,
        }
        for _, alias in ipairs(job.aliases or {}) do
          diag_state.pruned_by_alias[alias] = pruned
          if tracked[alias] == job then
            tracked[alias] = nil
            removed_aliases = removed_aliases + 1
          end
        end
        pruned.aliases_removed = removed_aliases
        diag_state.pruned_jobs[#diag_state.pruned_jobs + 1] = pruned
        push_bounded(stats.recent_pruned_job_samples, {
          at = pruned.at,
          local_job_key = pruned.local_job_key,
          pool_job_id = pruned.pool_job_id,
          pool_generation = pruned.pool_generation,
          prune_reason = pruned.prune_reason,
          age_at_prune = pruned.age_at_prune,
          aliases_removed = pruned.aliases_removed,
          prepow_digest = pruned.prepow_digest,
          lane = pruned.lane,
        }, DIAG_SAMPLE_LIMIT)
        tracked_unique[key] = nil
        stats.pruned_jobs = stats.pruned_jobs + 1
      else
        unique_count = unique_count + 1
      end
    end
    local alias_count = 0
    for _ in pairs(tracked) do alias_count = alias_count + 1 end
    stats.tracked_jobs = alias_count
    stats.tracked_aliases = alias_count
    stats.unique_tracked_jobs = unique_count
    prune_diag_indexes()
  end

  function cmd04_event_sample(event_type, frame, job, matched_key, decoded_result_lane, result_lane_byte, current_duplicate_key, extra)
    local now = os.time()
    local nonce_hex = frame and hex_range(frame, 5, 12) or ""
    local proof_hash = frame and hash_string32(hex_range(frame, 13, 180)) or ""
    local result_crc = frame and hex_range(frame, 185, 186) or ""
    local sample = {
      at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      event_type = tostring(event_type or ""),
      job_id = job and tostring(job.job_id or "") or "",
      matched_job_key = job and tostring(job.key or "") or "",
      decoded_result_lane = decoded_result_lane or 0,
      matched_sent_lane = job and (job.lane or 0) or 0,
      nonce_hex = nonce_hex,
      proof_hash = proof_hash,
      result_tail_b4_b7 = frame and hex_range(frame, 181, 184) or "",
      result_b6_b7 = frame and hex_range(frame, 183, 184) or "",
      result_crc = result_crc,
      current_duplicate_key = tostring(current_duplicate_key or ""),
      stock_like_crc_key = result_crc,
      stock_tail_key = result_crc,
      stock_progress_key = frame and hex_range(frame, 183, 184) or "",
      matched_key = matched_key or "",
      result_lane_byte = result_lane_byte and string.format("%02x", result_lane_byte) or "",
      frame_age = job and job.sent_epoch and (now - job.sent_epoch) or nil,
      job_age = job and job.sent_epoch and (now - job.sent_epoch) or nil,
    }
    local lane_for_cmd01 = (job and job.lane) or decoded_result_lane or stats.uart_lane_index
    local last_cmd01 = stats.cmd01_last_by_lane and stats.cmd01_last_by_lane[lane_for_cmd01]
    if last_cmd01 then
      sample.last_cmd01_for_lane = last_cmd01.value_hex
      sample.seconds_since_last_cmd01_for_lane = last_cmd01.epoch and (now - last_cmd01.epoch) or nil
    else
      sample.last_cmd01_for_lane = ""
      sample.seconds_since_last_cmd01_for_lane = nil
    end
    if extra then
      for k, v in pairs(extra) do sample[k] = v end
    end
    local no_store = sample.no_store
    sample.no_store = nil
    if not no_store then push_bounded(stats.cmd04_event_samples, sample, DIAG_HEAVY_SAMPLE_LIMIT) end
    return sample
  end

  local function send_work_set(reason)
    local now = os.time()
    if not stats.stratum_connected or not valid_stratum_job(latest_job) or not stats.last_valid_job_epoch or now - stats.last_valid_job_epoch > STRATUM_WATCHDOG_SECONDS then
      stats.stale_job_work_suppressed = stats.stale_job_work_suppressed + 1
      emit({
        event = "stale_job_work_suppressed",
        reason = reason,
        stratum_connected = stats.stratum_connected,
        seconds_since_valid_job = stats.last_valid_job_epoch and (now - stats.last_valid_job_epoch) or -1,
      })
      write_stats("running")
      return
    end
    local set_key = stratum_job_key(latest_job)
    local built_frames = {}
    local lanes = lanes_for_mode()
    for _, lane in ipairs(lanes) do
      seq = seq + 1
      diag_state.send_seq = diag_state.send_seq + 1
      local nonce_hex = force_lane_in_nonce(random_hex(8), lane)
      local frame_hex = build_work_frame(latest_job.pre_pow, nonce_hex)
      local frame_audit = audit_work_frame(frame_hex, lane)
      local work_lane_byte = frame_hex:sub(489, 490)
      local work_lane_f5 = frame_hex:sub(491, 492)
      local id6 = nonce_hex:sub(1, 12)
      local aliases = nonce_aliases(nonce_hex)
      local previous_active_key = active and tostring(active.key or "") or ""
      local job = {
        key = tostring(seq),
        send_seq = diag_state.send_seq,
        id6 = id6,
        nonce_hex = nonce_hex,
        aliases = aliases,
        lane = lane,
        height = tonumber(latest_job.height) or 0,
        job_id = tonumber(latest_job.job_id) or 0,
        stratum_job_key = set_key,
        pool_generation = diag_state.pool_generation,
        previous_job_key = previous_active_key,
        clean_jobs = latest_job.clean_jobs or false,
        prepow_digest = compact_digest(latest_job.pre_pow),
        sent_epoch = os.time(),
        reason = reason,
        results = 0,
        replacement_sent = false,
      }
      active = job
      active_by_lane[lane] = job
      tracked_unique[job.key] = job
      local alias_records = {}
      local alias_overwrote = false
      local old_alias_owner = nil
      for _, alias in ipairs(aliases) do
        local old_owner = tracked[alias] or diag_state.alias_owners[alias]
        local old_owner_key = old_owner and tostring(old_owner.local_job_key or old_owner.key or "") or ""
        if old_owner and old_owner_key ~= job.key then
          alias_overwrote = true
          old_alias_owner = old_alias_owner or old_owner
          stats.alias_overwrite_count = stats.alias_overwrite_count + 1
          stats.alias_collision_count = stats.alias_collision_count + 1
          local collision = {
            epoch = os.time(),
            at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            alias = alias,
            new_job_key = job.key,
            old_job_key = old_owner_key,
            new_pool_job_key = set_key,
            old_pool_job_key = tostring(old_owner.pool_job_key or old_owner.stratum_job_key or ""),
            new_lane = lane,
            old_lane = old_owner.lane or 0,
            pool_generation = diag_state.pool_generation,
          }
          diag_state.collision_by_alias[alias] = collision
          push_bounded(stats.alias_collision_samples, collision, DIAG_SAMPLE_LIMIT)
        end
        local owner = {
          epoch = os.time(),
          at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          alias = alias,
          local_job_key = job.key,
          pool_job_id = tostring(job.job_id or ""),
          pool_job_key = set_key,
          pool_generation = diag_state.pool_generation,
          lane = lane,
          send_seq = diag_state.send_seq,
          sent_epoch = job.sent_epoch,
          nonce_hex = nonce_hex,
          prepow_digest = job.prepow_digest,
          frame_hash = hash_string32(frame_hex),
        }
        diag_state.alias_owners[alias] = owner
        diag_state.sent_by_alias[alias] = owner
        alias_records[#alias_records + 1] = alias
        tracked[alias] = job
      end
      local sent_entry = {
        epoch = job.sent_epoch,
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        send_seq = diag_state.send_seq,
        lane = lane,
        local_job_key = job.key,
        pool_job_id = tostring(job.job_id or ""),
        pool_job_key = set_key,
        pool_generation = diag_state.pool_generation,
        sent_snapshot_key = set_key,
        aliases = alias_records,
        alias_overwrote = alias_overwrote,
        old_alias_owner = old_alias_owner and tostring(old_alias_owner.local_job_key or "") or "",
        frame_len = frame_audit.length,
        frame_hash = hash_string32(frame_hex),
        f2_f9 = frame_audit.f2_f9,
        f4 = work_lane_byte,
        f5 = work_lane_f5,
        fa_101 = frame_audit.fa_101,
        crc = frame_audit.crc_stored,
      }
      diag_state.sent_work[#diag_state.sent_work + 1] = sent_entry
      push_bounded(stats.recent_sent_work_samples, {
        at = sent_entry.at,
        send_seq = diag_state.send_seq,
        lane = lane,
        local_job_key = job.key,
        pool_job_id = sent_entry.pool_job_id,
        pool_generation = diag_state.pool_generation,
        alias_overwrote = alias_overwrote,
        old_alias_owner = sent_entry.old_alias_owner,
        f2_f9 = sent_entry.f2_f9,
        f4 = sent_entry.f4,
        f5 = sent_entry.f5,
        fa_101 = sent_entry.fa_101,
        crc = sent_entry.crc,
      }, DIAG_SAMPLE_LIMIT)
      stats.jobs_sent = stats.jobs_sent + 1
      stats.lanes_sent = stats.lanes_sent + 1
      push_bounded(stats.work_field_samples, {
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        reason = reason,
        lane = lane,
        key = job.key,
        job_id = tostring(latest_job.job_id or ""),
        difficulty = tostring(latest_job.difficulty or ""),
        height = tonumber(latest_job.height) or 0,
        edge_bits = 32,
        pre_pow_prefix = tostring(latest_job.pre_pow or ""):sub(1, 32),
        nonce_hex = nonce_hex,
        id6 = id6,
        length = frame_audit.length,
        frame_starts = frame_audit.starts,
        f2_f9 = frame_audit.f2_f9,
        work_lane_byte_0xf4 = work_lane_byte,
        work_lane_byte_0xf5 = work_lane_f5,
        final8_0xfa = frame_hex:sub(501, 516),
        crc = frame_hex:sub(-4),
        crc_computed = frame_audit.crc_computed,
        crc_ok = frame_audit.crc_ok,
      }, DIAG_SAMPLE_LIMIT)
      frame_audit.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      frame_audit.reason = reason
      frame_audit.key = job.key
      frame_audit.job_id = tostring(latest_job.job_id or "")
      frame_audit.height = tonumber(latest_job.height) or 0
      frame_audit.nonce_hex = nonce_hex
      push_bounded(stats.work_frame_audit_samples, frame_audit, DIAG_SAMPLE_LIMIT)
      built_frames[#built_frames + 1] = {frame_hex = frame_hex, lane = lane, key = job.key, id6 = id6}
      send_frame(serial, "work-" .. job.key .. "-lane-" .. lane, hex_to_bytes(frame_hex))
      emit({event = "send_work", seq = job.key, lane = lane, length = frame_audit.length, f2_f9 = frame_audit.f2_f9, work_lane_byte_0xf4 = work_lane_byte, work_lane_byte_0xf5 = work_lane_f5, final8_0xfa = frame_audit.fa_101, crc_stored = frame_audit.crc_stored, crc_computed = frame_audit.crc_computed, crc_ok = frame_audit.crc_ok, id6 = id6, nonce_hex = nonce_hex, aliases = aliases, height = job.height, job_id = job.job_id, reason = reason})
      if inter_work_frame_delay_ms > 0 then
        os.execute("usleep " .. tostring(math.floor(inter_work_frame_delay_ms * 1000)) .. " >/dev/null 2>&1 || true")
      end
    end
    last_work_frames = built_frames
    last_work_set_epoch = os.time()
    duplicate_results_since_work = 0
    unknown_results_since_work = 0
    stats.last_work_set_epoch = last_work_set_epoch
    stats.work_sets_sent = stats.work_sets_sent + 1
    last_job_id = tostring(latest_job.job_id or "")
    last_difficulty = tostring(latest_job.difficulty or "")
    last_pre_pow = tostring(latest_job.pre_pow or "")
    stats.last_job_id = last_job_id
    stats.last_difficulty = last_difficulty
    stats.last_pre_pow_prefix = last_pre_pow:sub(1, 32)
    local active_jobs = {}
    for lane = 1, 3 do
      local lane_job = active_by_lane[lane]
      active_jobs[tostring(lane)] = lane_job and {
        job_key = lane_job.key,
        send_seq = lane_job.send_seq,
        age_seconds = os.time() - lane_job.sent_epoch,
        job_id = lane_job.job_id,
        stratum_job_key = lane_job.stratum_job_key,
      } or nil
    end
    stats.active_jobs_by_lane = active_jobs
    stats.current_job = {
      job_key = active and active.key or "",
      height = tonumber(latest_job.height) or 0,
      job_id = tonumber(latest_job.job_id) or 0,
      stratum_job_key = set_key,
      reason = reason,
      lanes_sent = #lanes,
      age_seconds = 0,
    }
    prune_old_tracked()
    write_stats("running")
  end

  local function maybe_soft_refresh()
    local now = os.time()
    if not stats.stratum_connected or not stats.last_valid_job_epoch or now - stats.last_valid_job_epoch > STRATUM_WATCHDOG_SECONDS then
      stats.stale_job_work_suppressed = stats.stale_job_work_suppressed + 1
      return
    end
    if last_work_set_epoch > 0 and now - last_work_set_epoch < MIN_WORK_SET_INTERVAL_SECONDS then return end
    if last_result_epoch == 0 or now - last_result_epoch >= NO_RESULT_REFRESH_SECONDS then
      stats.soft_refreshes = stats.soft_refreshes + 1
      stats.last_soft_refresh_reason = "no_result_refresh"
      send_work_set("no_result_refresh")
    end
  end

  local function maybe_result_refresh(reason)
    if not enable_result_refresh then return false end
    local now = os.time()
    if not stats.stratum_connected or not stats.last_valid_job_epoch or now - stats.last_valid_job_epoch > STRATUM_WATCHDOG_SECONDS then
      stats.stale_job_work_suppressed = stats.stale_job_work_suppressed + 1
      return false
    end
    if last_work_set_epoch > 0 and now - last_work_set_epoch < RESULT_REFRESH_MIN_INTERVAL_SECONDS then return false end
    stats.result_refreshes = stats.result_refreshes + 1
    stats.last_result_refresh_reason = reason
    if reason == "duplicate_result_refresh" then
      stats.duplicate_result_refreshes = stats.duplicate_result_refreshes + 1
    elseif reason == "adjacent_duplicate_result_refresh" then
      stats.adjacent_duplicate_result_refreshes = stats.adjacent_duplicate_result_refreshes + 1
    elseif reason == "unknown_result_refresh" then
      stats.unknown_result_refreshes = stats.unknown_result_refreshes + 1
    elseif reason == "no_accept_result_refresh" then
      stats.no_accept_result_refreshes = stats.no_accept_result_refreshes + 1
    end
    send_work_set(reason)
    return true
  end

  local initial_should_send, initial_reason = should_send_for_job(latest_job)
  if initial_should_send then
    stats.work_update_count = stats.work_update_count + 1
    stats.last_work_update_reason = initial_reason
    send_work_set("initial")
  else
    stats[initial_reason] = (stats[initial_reason] or 0) + 1
  end
  local end_epoch = os.time() + duration
  local last_stats = 0

  local function allowed_resync_type(typ)
    return typ == 0x01 or typ == 0x03 or typ == 0x04 or typ == 0x05
  end

  local function recoverable_resync_type(typ)
    return false
  end

  local function crc_resync_bucket(embedded_at)
    if not embedded_at or embedded_at <= 0 then return "" end
    if embedded_at < 100 then return "early" end
    if embedded_at <= 180 then return "mid" end
    return "tail"
  end

  local function find_resync_candidate(need)
    local first_embedded_at = nil
    local first_candidate_type = nil
    local first_candidate_need = nil
    local first_candidate_got = nil
    local first_candidate_calc = nil
    local first_candidate_reason = "none"
    local saw_unknown_cmd = false
    local saw_short_buffer = false
    local saw_invalid_crc = false
    local search_limit = math.min(#buf - 1, need - 1)
    for i = 2, search_limit do
      if buf[i] == 0xff and buf[i + 1] == 0x55 then
        if not first_embedded_at then first_embedded_at = i end
        local typ = buf[i + 2]
        if not first_candidate_type then first_candidate_type = typ end
        if not allowed_resync_type(typ) then
          saw_unknown_cmd = true
          if first_candidate_reason == "none" then first_candidate_reason = "unknown_cmd" end
        else
          local candidate_need = expected_len(typ)
          if not first_candidate_need then first_candidate_need = candidate_need end
          if #buf - i + 1 < candidate_need then
            saw_short_buffer = true
            if first_candidate_reason == "none" then first_candidate_reason = "short_buffer" end
          else
            local candidate_got = buf[i + candidate_need - 2] * 256 + buf[i + candidate_need - 1]
            local candidate_calc = crc_ccitt(buf, i + 2, i + candidate_need - 3)
            if not first_candidate_got then
              first_candidate_got = candidate_got
              first_candidate_calc = candidate_calc
            end
            if candidate_got == candidate_calc then
              return {
                embedded_at = i,
                candidate_type = typ,
                candidate_need = candidate_need,
                candidate_got = candidate_got,
                candidate_calc = candidate_calc,
                candidate_valid = true,
                candidate_reason = "valid",
                saw_unknown_cmd = saw_unknown_cmd,
                saw_short_buffer = saw_short_buffer,
                saw_invalid_crc = saw_invalid_crc,
              }
            end
            saw_invalid_crc = true
            if first_candidate_reason == "none" then first_candidate_reason = "invalid_crc" end
          end
        end
      end
    end
    return {
      embedded_at = first_embedded_at,
      candidate_type = first_candidate_type,
      candidate_need = first_candidate_need,
      candidate_got = first_candidate_got,
      candidate_calc = first_candidate_calc,
      candidate_valid = false,
      candidate_reason = first_candidate_reason,
      saw_unknown_cmd = saw_unknown_cmd,
      saw_short_buffer = saw_short_buffer,
      saw_invalid_crc = saw_invalid_crc,
    }
  end

  local function note_cmd04_alt_boundary(candidate)
    if not candidate or not candidate.embedded_at then return nil end
    local possible_len = candidate.embedded_at - 1
    if possible_len < 16 or possible_len > expected_len(0x04) then return nil end
    local alt_got = buf[possible_len - 1] * 256 + buf[possible_len]
    local alt_calc = crc_ccitt(buf, 3, possible_len - 2)
    local valid = alt_got == alt_calc
    if valid then
      stats.crc_resync_cmd04_alt_boundary_valid = stats.crc_resync_cmd04_alt_boundary_valid + 1
    else
      stats.crc_resync_cmd04_alt_boundary_invalid = stats.crc_resync_cmd04_alt_boundary_invalid + 1
    end
    local sample = {
      at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      embedded_at = candidate.embedded_at,
      embedded_bucket = crc_resync_bucket(candidate.embedded_at),
      possible_len = possible_len,
      alt_valid = valid,
      alt_got_crc = string.format("%04x", alt_got),
      alt_calc_crc = string.format("%04x", alt_calc),
      candidate_type = candidate.candidate_type and string.format("0x%02x", candidate.candidate_type) or "",
      candidate_valid = candidate.candidate_valid,
      prefix = hex_range(buf, 1, math.min(#buf, 48)),
    }
    push_bounded(stats.crc_resync_cmd04_alt_boundary_samples, sample, DIAG_SAMPLE_LIMIT)
    return sample
  end

  local function note_crc_resync(frame_type, need, got, calc, discard_amount, candidate, action)
    candidate = candidate or find_resync_candidate(need)
    local embedded_at = candidate.embedded_at
    local alt_boundary_sample = nil

    local typ_hex = string.format("0x%02x", frame_type or 0)
    if frame_type == 0x04 then
      alt_boundary_sample = note_cmd04_alt_boundary(candidate)
      if action == "silent_drop_tail_embedded" then
        stats.crc_resync_cmd04_tail_silent_drops = stats.crc_resync_cmd04_tail_silent_drops + 1
      else
        stats.crc_resync_cmd04_nacked = stats.crc_resync_cmd04_nacked + 1
      end
      if embedded_at then stats.crc_resync_cmd04_embedded_header = stats.crc_resync_cmd04_embedded_header + 1 end
    elseif frame_type == 0x01 then
      stats.crc_resync_cmd01 = stats.crc_resync_cmd01 + 1
    elseif frame_type == 0x03 then
      stats.crc_resync_cmd03 = stats.crc_resync_cmd03 + 1
    else
      stats.crc_resync_other = stats.crc_resync_other + 1
    end

    if embedded_at then
      stats.crc_resync_embedded_header = stats.crc_resync_embedded_header + 1
      local bucket = crc_resync_bucket(embedded_at)
      if bucket == "early" then
        stats.crc_resync_embedded_early = stats.crc_resync_embedded_early + 1
      elseif bucket == "mid" then
        stats.crc_resync_embedded_mid = stats.crc_resync_embedded_mid + 1
      elseif bucket == "tail" then
        stats.crc_resync_embedded_tail = stats.crc_resync_embedded_tail + 1
      end
    else
      stats.crc_resync_no_header = stats.crc_resync_no_header + 1
    end
    if candidate.candidate_valid then
      stats.crc_resync_candidate_valid = stats.crc_resync_candidate_valid + 1
    elseif embedded_at then
      if candidate.saw_unknown_cmd then stats.crc_resync_candidate_unknown_cmd = stats.crc_resync_candidate_unknown_cmd + 1 end
      if candidate.saw_short_buffer then stats.crc_resync_candidate_short_buffer = stats.crc_resync_candidate_short_buffer + 1 end
      if candidate.saw_invalid_crc then stats.crc_resync_candidate_invalid_crc = stats.crc_resync_candidate_invalid_crc + 1 end
    end
    local discarded = discard_amount or need
    stats.crc_resync_bytes_discarded = stats.crc_resync_bytes_discarded + discarded

    push_bounded(stats.crc_resync_samples, {
      at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      frame_type = typ_hex,
      action = action or (frame_type == 0x04 and "nack_drop_frame" or "drop_frame"),
      embedded_at = embedded_at or 0,
      embedded_bucket = crc_resync_bucket(embedded_at),
      candidate_valid = candidate.candidate_valid,
      candidate_reason = candidate.candidate_reason or "",
      candidate_type = candidate.candidate_type and string.format("0x%02x", candidate.candidate_type) or "",
      candidate_need = candidate.candidate_need or 0,
      candidate_got_crc = candidate.candidate_got and string.format("%04x", candidate.candidate_got) or "",
      candidate_calc_crc = candidate.candidate_calc and string.format("%04x", candidate.candidate_calc) or "",
      discarded = discarded,
      need = need,
      got_crc = string.format("%04x", got or 0),
      calc_crc = string.format("%04x", calc or 0),
      alt_possible_len = alt_boundary_sample and alt_boundary_sample.possible_len or 0,
      alt_valid = alt_boundary_sample and alt_boundary_sample.alt_valid or false,
      alt_got_crc = alt_boundary_sample and alt_boundary_sample.alt_got_crc or "",
      alt_calc_crc = alt_boundary_sample and alt_boundary_sample.alt_calc_crc or "",
      prefix = hex_range(buf, 1, math.min(#buf, 32)),
    }, DIAG_SAMPLE_LIMIT)
  end

  while os.time() < end_epoch do
    maybe_update_fan_control()
    prune_pending_submit()
    prune_submitted_proofs()
    local now_for_watchdog = os.time()
    local stratum_dead = not stratum_alive(st)
    local no_stratum_bytes = stats.last_stratum_byte_epoch and now_for_watchdog - stats.last_stratum_byte_epoch > STRATUM_WATCHDOG_SECONDS
    local no_valid_job = (awaiting_valid_job_epoch and now_for_watchdog - awaiting_valid_job_epoch > STRATUM_WATCHDOG_SECONDS)
      or ((not awaiting_valid_job_epoch) and stats.last_valid_job_epoch and now_for_watchdog - stats.last_valid_job_epoch > STRATUM_WATCHDOG_SECONDS)
    if stratum_dead or no_stratum_bytes or no_valid_job then
      local reason = stratum_dead and "nc_dead" or (no_stratum_bytes and "stratum_byte_timeout" or "valid_job_timeout")
      stats.stratum_connected = false
      stats.stratum_disconnect_reason = reason
      latest_job = nil
      last_job_id = nil
      last_difficulty = nil
      last_pre_pow = nil
      last_work_frames = {}
      pending_submit = {}
      submitted = {}
      write_stats("running")
      emit({event = "stratum_watchdog_reconnect", reason = reason})
      connect_stratum(reason)
    end

    for _, line in ipairs(stratum_poll(st)) do
      local ok, obj = pcall(json.decode, line)
      if ok and obj then
        if obj.method == "client.reconnect" then
          stats.stratum_client_reconnects = stats.stratum_client_reconnects + 1
          stats.stratum_connected = false
          stats.stratum_disconnect_reason = "client.reconnect"
          latest_job = nil
          pending_submit = {}
          submitted = {}
          if obj.id ~= nil then stratum_send_response(st, obj.id, "true") end
          connect_stratum("client.reconnect")
        elseif obj.method == "mining.ping" or obj.method == "ping" then
          stats.stratum_pings = stats.stratum_pings + 1
          if obj.id ~= nil then stratum_send_response(st, obj.id, '"pong"') end
        elseif tostring(obj.id or "") == tostring(gjt_id) and valid_stratum_job(obj.result) then
          local new_job = obj.result
          stats.last_valid_job_epoch = os.time()
          stats.last_valid_job_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
          awaiting_valid_job_epoch = nil
          local should_send, decision = should_send_for_job(new_job)
          stats.new_job_reason = decision
          stats[decision] = (stats[decision] or 0) + 1
          latest_job = new_job
          if should_send then
            stats.work_update_count = stats.work_update_count + 1
            stats.last_work_update_reason = decision
            send_work_set(decision)
          end
        elseif obj.method == "job" and valid_stratum_job(obj.params) then
          local new_job = obj.params
          stats.last_valid_job_epoch = os.time()
          stats.last_valid_job_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
          awaiting_valid_job_epoch = nil
          local should_send, decision = should_send_for_job(new_job)
          local key = stratum_job_key(new_job)
          stats.notify_count = stats.notify_count + 1
          stats.new_job_reason = decision
          stats.pool_jobs = stats.pool_jobs + 1
          stats[decision] = (stats[decision] or 0) + 1
          push_bounded(stats.notify_samples, {
            at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            job_id = tostring(new_job.job_id or ""),
            difficulty = tostring(new_job.difficulty or ""),
            height = tonumber(new_job.height) or 0,
            pre_pow_prefix = tostring(new_job.pre_pow or ""):sub(1, 32),
            decision = decision,
            sent = should_send,
          }, DIAG_SAMPLE_LIMIT)
          emit({
            event = "notify_decision",
            job_id = tostring(new_job.job_id or ""),
            difficulty = tostring(new_job.difficulty or ""),
            height = tonumber(new_job.height) or 0,
            pre_pow_prefix = tostring(new_job.pre_pow or ""):sub(1, 32),
            decision = decision,
            reason = decision,
            sent = should_send,
          })
          latest_job = new_job
          if should_send then
            stats.work_update_count = stats.work_update_count + 1
            stats.last_work_update_reason = decision
            send_work_set(decision)
          else
            stats.same_job_ignored = stats.same_job_ignored + 1
            emit({event = "same_job_ignored", key = key})
          end
        elseif obj.id and pending_submit[tostring(obj.id)] then
          local sjob = pending_submit[tostring(obj.id)]
          if obj.result == "ok" then
            stats.accepted = stats.accepted + 1
            stats.submit_ok = stats.submit_ok + 1
            ddr_account_event("accepted_by_ddr", 1)
            update_result_signature_status(sjob.result_signature, "accepted")
            if sjob.lane and stats.accepted_by_lane[sjob.lane] then
              stats.accepted_by_lane[sjob.lane] = stats.accepted_by_lane[sjob.lane] + 1
            end
            last_accept_epoch = os.time()
            stats.last_accept_epoch = last_accept_epoch
            stats.last_share_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
            stats.last_share_nonce = sjob.nonce_hex
          else
            stats.rejected = stats.rejected + 1
            stats.submit_error = stats.submit_error + 1
            ddr_account_event("rejected_by_ddr", 1)
            ddr_account_event("submit_errors_by_ddr", 1)
            update_result_signature_status(sjob.result_signature, "rejected")
            local msg = "unknown"
            if obj.error then
              if type(obj.error) == "table" then
                msg = tostring(obj.error.message or obj.error.code or "error")
              else
                msg = tostring(obj.error)
              end
            end
            local msg_lc = string.lower(msg)
            if string.find(msg_lc, "job not found", 1, true) then
              stats.submit_error_job_not_found = stats.submit_error_job_not_found + 1
              stats.submit_error_stale_pool = stats.submit_error_stale_pool + 1
            elseif string.find(msg_lc, "too late", 1, true) or string.find(msg_lc, "stale", 1, true) then
              stats.submit_error_solution_too_late = stats.submit_error_solution_too_late + 1
              stats.submit_error_stale_pool = stats.submit_error_stale_pool + 1
            else
              stats.submit_error_other = stats.submit_error_other + 1
            end
            stats.submit_error_messages[#stats.submit_error_messages + 1] = {at = os.date("!%Y-%m-%dT%H:%M:%SZ"), message = msg}
            while #stats.submit_error_messages > 5 do table.remove(stats.submit_error_messages, 1) end
            if sjob.cmd04_sample then
              local sample = {}
              for k, v in pairs(sjob.cmd04_sample) do sample[k] = v end
              sample.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
              sample.event_type = "submit_error"
              sample.submit_id = tostring(obj.id)
              sample.submit_error_message = msg
              sample.submit_response_age = sjob.sent_epoch and (os.time() - sjob.sent_epoch) or nil
              push_bounded(stats.cmd04_event_samples, sample, DIAG_HEAVY_SAMPLE_LIMIT)
            else
              push_bounded(stats.cmd04_event_samples, {
                at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                event_type = "submit_error",
                submit_id = tostring(obj.id),
                submit_error_message = msg,
                job_id = "",
                matched_job_key = "",
                decoded_result_lane = 0,
                matched_sent_lane = 0,
                nonce_hex = sjob.nonce_hex or "",
                proof_hash = "",
                result_tail_b4_b7 = "",
                result_b6_b7 = "",
                result_crc = "",
                current_duplicate_key = "",
                stock_like_crc_key = "",
              }, DIAG_HEAVY_SAMPLE_LIMIT)
            end
          end
          pending_submit[tostring(obj.id)] = nil
          write_stats("running")
          emit({event = "submit_response", id = obj.id, result = obj.result or "", error = obj.error})
        end
      end
    end

    local chunk = serial:read(256)
    if chunk and #chunk > 0 then
      for i = 1, #chunk do buf[#buf + 1] = string.byte(chunk, i) end
      while #buf >= 2 and not (buf[1] == 0xff and buf[2] == 0x55) do table.remove(buf, 1) end
      if #buf >= 4 then
        local need = expected_len(buf[3])
        if not need then
          table.remove(buf, 1)
        elseif #buf >= need then
          local got = buf[need - 1] * 256 + buf[need]
          local calc = crc_ccitt(buf, 3, need - 2)
          if got == calc then
            local frame = {}
            for i = 1, need do frame[i] = buf[i] end
            for _ = 1, need do table.remove(buf, 1) end
            if frame[3] == 0x01 then
              local now_cmd01 = os.time()
              local lane = stats.uart_lane_index
              local chip = frame[4] or 0
              local value = ((frame[5] or 0) * 256) + (frame[6] or 0)
              local value_hex = string.format("0x%04x", value)
              stats.uart_frame_type_counts.cmd01 = (stats.uart_frame_type_counts.cmd01 or 0) + 1
              stats.cmd01_frames = stats.cmd01_frames + 1
              stats.cmd01_by_lane[lane] = (stats.cmd01_by_lane[lane] or 0) + 1
              if value == 0xa1a1 then
                stats.cmd01_ok = stats.cmd01_ok + 1
                stats.cmd01_ok_by_lane[lane] = (stats.cmd01_ok_by_lane[lane] or 0) + 1
              elseif value == 0xf1f1 then
                stats.cmd01_error = stats.cmd01_error + 1
                stats.cmd01_error_by_lane[lane] = (stats.cmd01_error_by_lane[lane] or 0) + 1
              else
                stats.cmd01_other = stats.cmd01_other + 1
                stats.cmd01_other_by_lane[lane] = (stats.cmd01_other_by_lane[lane] or 0) + 1
              end
              stats.cmd01_last_by_lane[lane] = {
                epoch = now_cmd01,
                at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                lane = lane,
                chip = chip,
                value = value,
                value_hex = value_hex,
              }
              push_bounded(stats.cmd01_samples, {
                at = stats.cmd01_last_by_lane[lane].at,
                lane = lane,
                chip = chip,
                value_hex = value_hex,
                frame_hex = hex_range(frame, 1, #frame),
                bytes_4_6 = hex_range(frame, 4, 6),
                age = 0,
              }, DIAG_HEAVY_SAMPLE_LIMIT)
              push_bounded(stats.uart_frame_samples, {
                at = stats.cmd01_last_by_lane[lane].at,
                type = "0x01",
                chip = chip,
                inferred_lane = lane,
                lane_source = "uart_lane_index",
                value_hex = value_hex,
                bytes_4_6 = hex_range(frame, 4, 6),
                frame_hex = hex_range(frame, 1, #frame),
                seconds_since_last_work_set = last_work_set_epoch > 0 and (now_cmd01 - last_work_set_epoch) or nil,
                active_job_key = active and tostring(active.key or "") or "",
              }, DIAG_HEAVY_SAMPLE_LIMIT)
              emit({event = "cmd01", lane = lane, chip = chip, value_hex = value_hex})
              write_stats("running")
            elseif frame[3] == 0x03 then
              local now_status = os.time()
              local chip = frame[4] or 0
              local decoded = decode_uart_status_temp(frame)
              stats.uart_frame_type_counts.cmd03 = (stats.uart_frame_type_counts.cmd03 or 0) + 1
              stats.uart_status_frames = stats.uart_status_frames + 1
              stats.last_status_frame_epoch = now_status
              stats.last_status_frame_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
              last_status_frame_epoch = now_status
              stats.chip_status[chip + 1] = true
              if decoded.temp_c then
                stats.chip_temps_c[chip + 1] = decoded.temp_c
                local temps = {}
                for _, v in pairs(stats.chip_temps_c) do
                  if tonumber(v) then temps[#temps + 1] = tonumber(v) end
                end
                stats.board_temps_c = temps
                stats.sensor_temps_c = temps
                stats.chip_temp_c = max_valid_temp(temps) or decoded.temp_c
                stats.fan_control_temp_c = stats.chip_temp_c
                stats.temp = string.format("%.1f", stats.chip_temp_c)
                stats.sensor_source = "uart_status"
                stats.sensor_updated_at = stats.last_status_frame_time
                last_valid_fan_temp_epoch = now_status
              end
              push_bounded(stats.status_frame_samples, {
                at = stats.last_status_frame_time,
                frame_hex = hex_range(frame, 1, #frame),
                chip = chip,
                temp_hi = string.format("%02x", frame[5] or 0),
                temp_lo = string.format("%02x", frame[6] or 0),
                raw_be = decoded.raw_be,
                raw_le = decoded.raw_le,
                temp_be_c = decoded.temp_be_c,
                temp_le_c = decoded.temp_le_c,
                chosen_temp_c = decoded.temp_c,
              }, DIAG_SAMPLE_LIMIT)
              push_bounded(stats.uart_frame_samples, {
                at = stats.last_status_frame_time,
                type = "0x03",
                chip = chip,
                bytes_4_6 = hex_range(frame, 4, 6),
                temp_hi = string.format("%02x", frame[5] or 0),
                temp_lo = string.format("%02x", frame[6] or 0),
                raw_be = decoded.raw_be,
                raw_le = decoded.raw_le,
                chosen_temp_c = decoded.temp_c,
                frame_hex = hex_range(frame, 1, #frame),
                seconds_since_last_work_set = last_work_set_epoch > 0 and (now_status - last_work_set_epoch) or nil,
                active_job_key = active and tostring(active.key or "") or "",
              }, DIAG_HEAVY_SAMPLE_LIMIT)
              emit({event = "uart_status_frame", chip = chip, frame_hex = hex_range(frame, 1, #frame), raw_be = decoded.raw_be, raw_le = decoded.raw_le, temp_c = decoded.temp_c})
              write_stats("running")
            elseif frame[3] == 0x04 then
              result_no = result_no + 1
              last_result_epoch = os.time()
              stats.uart_frame_type_counts.cmd04 = (stats.uart_frame_type_counts.cmd04 or 0) + 1
              stats.last_result_epoch = last_result_epoch
              stats.uart_result_frames = stats.uart_result_frames + 1
              stats.last_result_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
              serial:write(hex_to_bytes(ack_hex))
              serial:flush()
              stats.uart_result_acks = stats.uart_result_acks + 1
              local candidate_full = hex_range(frame, 5, 12)
              local candidates = nonce_aliases(candidate_full)
              local result_lane_byte = frame[7] or 0
              local decoded_result_lane = decoded_lane_from_byte(result_lane_byte)
              local result_diag = make_result_diag(frame, decoded_result_lane, result_lane_byte)
              local stock_adjacent_duplicate = false
              local previous_stock_tail_key = diag_state.last_stock_tail_key or ""
              local previous_result_signature = diag_state.last_result_signature or ""
              local tail_matches_previous = result_diag.stock_tail_key ~= "" and previous_stock_tail_key == result_diag.stock_tail_key
              local signature_matches_previous = result_diag.signature ~= "" and previous_result_signature == result_diag.signature
              if tail_matches_previous and (ADJACENT_DUPLICATE_REQUIRE_EXACT_SIGNATURE <= 0 or signature_matches_previous) then
                stock_adjacent_duplicate = true
              elseif tail_matches_previous then
                stats.adjacent_duplicate_tail_only_ignored = stats.adjacent_duplicate_tail_only_ignored + 1
              end
              diag_state.last_stock_tail_key = result_diag.stock_tail_key or ""
              diag_state.last_stock_tail_at = result_diag.at
              diag_state.last_result_signature = result_diag.signature or ""
              if decoded_result_lane >= 1 and decoded_result_lane <= 3 then
                stats.decoded_results_by_lane[decoded_result_lane] = stats.decoded_results_by_lane[decoded_result_lane] + 1
              else
                stats.decoded_result_lane_unknown = stats.decoded_result_lane_unknown + 1
              end
              update_cgminer_estats(result_diag, decoded_result_lane)
              local matched_key = nil
              local job = nil
              for _, candidate in ipairs(candidates) do
                if tracked[candidate] then
                  matched_key = candidate
                  job = tracked[candidate]
                  break
                end
              end
              local matched_alias_kind = alias_kind(matched_key)
              if matched_alias_kind == "mid4" then
                stats.result_mid4_alias_matches = stats.result_mid4_alias_matches + 1
              end
              local lane_active = active_by_lane[decoded_result_lane]
              local matches_active = lane_active and job == lane_active
              if not matches_active then stats.inactive_result_frames = stats.inactive_result_frames + 1 end
              push_bounded(stats.result_lane_samples, {
                at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                result_lane_byte = string.format("%02x", result_lane_byte),
                decoded_result_lane = decoded_result_lane,
                matched_job_lane = job and job.lane or 0,
                matched_key = matched_key or "",
                matched_alias_kind = matched_alias_kind,
                nonce_hex = candidate_full,
                result_bytes_5_12 = hex_range(frame, 5, 12),
                result_tail_181_186 = hex_range(frame, 181, 186),
                matched_work_nonce = job and tostring(job.nonce_hex or "") or "",
                matched_work_f4 = job and tostring((job.nonce_hex or ""):sub(5, 6)) or "",
                active_lane_job_key = lane_active and tostring(lane_active.key or "") or "",
                frame_prefix = hex_range(frame, 1, math.min(32, #frame)),
              }, DIAG_SAMPLE_LIMIT)
              push_bounded(stats.uart_frame_samples, {
                at = stats.last_result_time,
                type = "0x04",
                chip = frame[4] or 0,
                decoded_result_lane = decoded_result_lane,
                lane_source = "frame[7]",
                result_lane_byte = string.format("%02x", result_lane_byte),
                matched_job_lane = job and job.lane or 0,
                matched_job_key = job and tostring(job.key or "") or "",
                matched_alias_kind = matched_alias_kind,
                matched_key = matched_key or "",
                nonce_hex = candidate_full,
                result_bytes_5_12 = hex_range(frame, 5, 12),
                result_tail_181_186 = hex_range(frame, 181, 186),
                matched_work_nonce = job and tostring(job.nonce_hex or "") or "",
                matched_work_f4 = job and tostring((job.nonce_hex or ""):sub(5, 6)) or "",
                matched_work_f5 = job and tostring((job.nonce_hex or ""):sub(7, 8)) or "",
                active_lane_job_key = lane_active and tostring(lane_active.key or "") or "",
                active_job_key = active and tostring(active.key or "") or "",
                seconds_since_last_work_set = last_work_set_epoch > 0 and (last_result_epoch - last_work_set_epoch) or nil,
                frame_prefix = hex_range(frame, 1, math.min(32, #frame)),
              }, DIAG_HEAVY_SAMPLE_LIMIT)
              if stock_adjacent_duplicate then
                local now = os.time()
                local previous_tail_item = diag_state.result_tail_keys[result_diag.stock_tail_key]
                local previous_tail_status = previous_tail_item and tostring(previous_tail_item.current_status or previous_tail_item.first_status or "unknown") or "unknown"
                local previous_phase_class = duplicate_phase_class(previous_tail_status)
                note_adjacent_duplicate_phase(previous_phase_class)
                local quarantine_remaining = adjacent_duplicate_quarantine_remaining(result_diag.stock_tail_key, now)
                local quarantine_active = quarantine_remaining > 0
                if not quarantine_active and (previous_phase_class == "before_submit" or previous_phase_class == "after_submit" or previous_phase_class == "job_rollover") then
                  quarantine_remaining = arm_adjacent_duplicate_quarantine(result_diag.stock_tail_key, now)
                  quarantine_active = quarantine_remaining > 0
                  if quarantine_active then
                    stats.adjacent_duplicate_quarantine_armed = stats.adjacent_duplicate_quarantine_armed + 1
                  end
                end
                if quarantine_active then
                  stats.adjacent_duplicate_quarantine_hits = stats.adjacent_duplicate_quarantine_hits + 1
                end
                local sig_item = note_result_signature(result_diag, "suppressed", job, "")
                local dup_diag = classify_duplicate_result(result_diag, job, sig_item, "stock_adjacent", previous_tail_status)
                stats.duplicate_result_frames = stats.duplicate_result_frames + 1
                if DUPLICATE_CMD04_EXTRA_NACK > 0 then
                  serial:write(hex_to_bytes(nack_hex))
                  serial:flush()
                  stats.uart_result_nacks = stats.uart_result_nacks + 1
                  stats.duplicate_cmd04_extra_nacks = stats.duplicate_cmd04_extra_nacks + 1
                end
                if matched_alias_kind == "mid4" then stats.result_mid4_alias_duplicates = stats.result_mid4_alias_duplicates + 1 end
                ddr_account_event("duplicates_by_ddr", 1)
                local accept_age_seconds = last_accept_epoch > 0 and (now - last_accept_epoch) or -1
                local refresh_blocked_by_accept_age = false
                if not quarantine_active then
                  duplicate_results_since_work = duplicate_results_since_work + 1
                  if adjacent_duplicate_burst_epoch == 0 or now - adjacent_duplicate_burst_epoch > ADJACENT_DUPLICATE_REFRESH_WINDOW_SECONDS then
                    adjacent_duplicate_burst_epoch = now
                    adjacent_duplicate_burst_count = 0
                  end
                  adjacent_duplicate_burst_count = adjacent_duplicate_burst_count + 1
                  stats.adjacent_duplicate_burst_count = adjacent_duplicate_burst_count
                end
                cmd04_event_sample("duplicate_result_frame", frame, job, matched_key, decoded_result_lane, result_lane_byte, result_diag.stock_tail_key, {
                  duplicate_reason = "stock_adjacent_crc",
                  previous_stock_tail_key = previous_stock_tail_key,
                  previous_result_signature = previous_result_signature,
                  signature_matches_previous = signature_matches_previous,
                  result_signature = result_diag.signature,
                  duplicate_bucket = dup_diag.duplicate_bucket,
                  phase_class = dup_diag.phase_class,
                  first_seen = dup_diag.first_seen,
                  repeat_count = dup_diag.repeat_count,
                  original_status = dup_diag.original_status,
                  stock_tail_key_repeats = dup_diag.stock_tail_key_repeats,
                  stock_tail_key = dup_diag.stock_tail_key,
                  stock_progress_key = dup_diag.stock_progress_key,
                  stock_tail_repeat_count = dup_diag.stock_tail_repeat_count,
                  stock_tail_first_status = dup_diag.stock_tail_first_status,
                  stock_tail_first_signature = dup_diag.stock_tail_first_signature,
                  quarantine_active = quarantine_active,
                  quarantine_remaining_seconds = quarantine_remaining,
                  accept_age_seconds = accept_age_seconds,
                  work_age_seconds = last_work_set_epoch > 0 and (now - last_work_set_epoch) or nil,
                })
                if should_store_duplicate_sample(dup_diag) then
                  push_bounded(stats.duplicate_result_samples, {
                    at = result_diag.at,
                    signature = result_diag.signature,
                    duplicate_bucket = dup_diag.duplicate_bucket,
                    phase_class = dup_diag.phase_class,
                    nonce_hex = result_diag.nonce_hex,
                    proof_hash = result_diag.proof_hash,
                    result_crc = result_diag.result_crc,
                    b6_b7 = result_diag.b6_b7,
                    stock_tail_key = dup_diag.stock_tail_key,
                    stock_progress_key = dup_diag.stock_progress_key,
                    stock_tail_repeat_count = dup_diag.stock_tail_repeat_count,
                    stock_tail_first_status = dup_diag.stock_tail_first_status,
                    stock_tail_first_signature = dup_diag.stock_tail_first_signature,
                    repeat_count = dup_diag.repeat_count,
                    original_status = dup_diag.original_status,
                    lane = dup_diag.lane,
                    job_key = job and tostring(job.key or "") or "",
                    matched_key = matched_key or "",
                    previous_stock_tail_key = previous_stock_tail_key,
                    previous_result_signature = previous_result_signature,
                    signature_matches_previous = signature_matches_previous,
                    delta_ms = dup_diag.delta_ms,
                    quarantine_active = quarantine_active,
                    quarantine_remaining_seconds = quarantine_remaining,
                    accept_age_seconds = accept_age_seconds,
                  }, DIAG_HEAVY_SAMPLE_LIMIT)
                end
                emit({event = quarantine_active and "duplicate_stock_adjacent_quarantined" or "duplicate_stock_adjacent_suppressed", stock_tail_key = result_diag.stock_tail_key, nonce_hex = result_diag.nonce_hex, matched_key = matched_key or "", phase_class = dup_diag.phase_class, quarantine_remaining_seconds = quarantine_remaining})
                if not quarantine_active and adjacent_duplicate_burst_count >= ADJACENT_DUPLICATE_REFRESH_THRESHOLD then
                  if accept_age_seconds >= 0 and accept_age_seconds < ADJACENT_DUPLICATE_REFRESH_MIN_ACCEPT_AGE_SECONDS then
                    stats.adjacent_duplicate_refresh_blocked_by_accept_age = stats.adjacent_duplicate_refresh_blocked_by_accept_age + 1
                    refresh_blocked_by_accept_age = true
                  elseif maybe_result_refresh("adjacent_duplicate_result_refresh") then
                    adjacent_duplicate_burst_count = 0
                    adjacent_duplicate_burst_epoch = 0
                    stats.adjacent_duplicate_burst_count = 0
                  end
                end
              elseif job then
                if job.lane and stats.results_by_lane[job.lane] then
                  stats.results_by_lane[job.lane] = stats.results_by_lane[job.lane] + 1
                end
                local stale_reason = stale_submit_reason(job)
                if stale_reason then
                  suppress_stale_submit(stale_reason, frame, job, matched_key, decoded_result_lane, result_lane_byte, result_diag)
                else
                local nonce_hex
                local raw
                local submit_id = tostring(st.next_id)
                st.next_id = st.next_id + 1
                raw, nonce_hex = build_submit_json(submit_id, job, frame)
                local key = job.key .. ":" .. nonce_hex
                local proof_hash = hash_string32(hex_range(frame, 13, 180))
                local proof_key = tostring(job.job_id or "") .. ":" .. tostring(nonce_hex or "") .. ":" .. proof_hash
                local proof_suppressed = false
                if not submitted[key] then
                  local relax_duplicate_proof = false
                  if submitted_proofs[proof_key] then
                    local now = os.time()
                    if now - duplicate_proof_relax_window_epoch >= 3600 then
                      duplicate_proof_relax_window_epoch = now
                      duplicate_proof_relax_window_count = 0
                    end
                    if DUPLICATE_PROOF_RELAX_MAX_PER_HOUR > 0 and duplicate_proof_relax_window_count < DUPLICATE_PROOF_RELAX_MAX_PER_HOUR then
                      relax_duplicate_proof = true
                      duplicate_proof_relax_window_count = duplicate_proof_relax_window_count + 1
                      stats.duplicate_proof_relaxed_submits = stats.duplicate_proof_relaxed_submits + 1
                    else
                      stats.duplicate_proof_relaxed_limited = stats.duplicate_proof_relaxed_limited + 1
                    end
                  end
                  if submitted_proofs[proof_key] and not relax_duplicate_proof then
                    local sig_item = note_result_signature(result_diag, "suppressed", job, "")
                    local dup_diag = classify_duplicate_result(result_diag, job, sig_item, "before_submit")
                    stats.duplicate_proof_key_repeat = stats.duplicate_proof_key_repeat + 1
                    stats.duplicate_proof_suppressed = stats.duplicate_proof_suppressed + 1
                    stats.duplicate_result_frames = stats.duplicate_result_frames + 1
                    if matched_alias_kind == "mid4" then stats.result_mid4_alias_duplicates = stats.result_mid4_alias_duplicates + 1 end
                    ddr_account_event("duplicates_by_ddr", 1)
                    duplicate_results_since_work = duplicate_results_since_work + 1
                    cmd04_event_sample("duplicate_result_frame", frame, job, matched_key, decoded_result_lane, result_lane_byte, proof_key, {
                      duplicate_reason = "proof_key",
                      duplicate_submit_key = key,
                      result_signature = result_diag.signature,
                      duplicate_bucket = dup_diag.duplicate_bucket,
                      first_seen = dup_diag.first_seen,
                      repeat_count = dup_diag.repeat_count,
                      original_status = dup_diag.original_status,
                      stock_tail_key_repeats = dup_diag.stock_tail_key_repeats,
                      stock_tail_key = dup_diag.stock_tail_key,
                      stock_progress_key = dup_diag.stock_progress_key,
                      stock_tail_repeat_count = dup_diag.stock_tail_repeat_count,
                      stock_tail_first_status = dup_diag.stock_tail_first_status,
                      stock_tail_first_signature = dup_diag.stock_tail_first_signature,
                    })
                    if should_store_duplicate_sample(dup_diag) then
                      push_bounded(stats.duplicate_result_samples, {
                        at = result_diag.at,
                        signature = result_diag.signature,
                        duplicate_bucket = dup_diag.duplicate_bucket,
                        nonce_hex = result_diag.nonce_hex,
                        proof_hash = result_diag.proof_hash,
                        result_crc = result_diag.result_crc,
                        b6_b7 = result_diag.b6_b7,
                        stock_tail_key = dup_diag.stock_tail_key,
                        stock_progress_key = dup_diag.stock_progress_key,
                        stock_tail_repeat_count = dup_diag.stock_tail_repeat_count,
                        stock_tail_first_status = dup_diag.stock_tail_first_status,
                        stock_tail_first_signature = dup_diag.stock_tail_first_signature,
                        repeat_count = dup_diag.repeat_count,
                        original_status = dup_diag.original_status,
                        lane = dup_diag.lane,
                        job_key = tostring(job.key or ""),
                        delta_ms = dup_diag.delta_ms,
                      }, DIAG_HEAVY_SAMPLE_LIMIT)
                    end
                    emit({event = "duplicate_proof_suppressed", seq = job.key, nonce_hex = nonce_hex, proof_hash = proof_hash})
                    proof_suppressed = true
                    raw = nil
                  end
                end
                if raw and not submitted[key] then
                  local now = os.time()
                  if stats.stratum_connected and stats.last_valid_job_epoch and now - stats.last_valid_job_epoch <= STRATUM_WATCHDOG_SECONDS then
                    local sent = stratum_send_raw(st, raw)
                    if sent then
                      if matched_alias_kind == "mid4" then stats.result_mid4_alias_submits = stats.result_mid4_alias_submits + 1 end
                      submitted[key] = true
                      submitted_proofs[proof_key] = now
                      adjacent_duplicate_burst_count = 0
                      adjacent_duplicate_burst_epoch = 0
                      stats.adjacent_duplicate_burst_count = 0
                      local sig_item = note_result_signature(result_diag, "pending", job, submit_id)
                      pending_submit[submit_id] = {
                        id6 = job.id6,
                        nonce_hex = nonce_hex,
                        lane = job.lane,
                        sent_epoch = now,
                        result_signature = result_diag.signature,
                        cmd04_sample = cmd04_event_sample("submitted", frame, job, matched_key, decoded_result_lane, result_lane_byte, key, {
                          submit_id = submit_id,
                          proof_key = proof_key,
                          result_signature = result_diag.signature,
                          duplicate_repeat_count = sig_item and sig_item.repeat_count or 0,
                          no_store = true,
                        }),
                      }
                      if job.stale_reason then
                        stats.stale_candidate_submits = stats.stale_candidate_submits + 1
                      end
                      emit({event = "submit", id = submit_id, seq = job.key, nonce_hex = nonce_hex, matched_key = matched_key, candidates = candidates, result_lane_byte = string.format("%02x", result_lane_byte), decoded_result_lane = decoded_result_lane, matched_job_lane = job.lane})
                    else
                      stats.stratum_connected = false
                      stats.stratum_disconnect_reason = "submit_write_failed"
                      stats.skipped_results = stats.skipped_results + 1
                    end
                  else
                    stats.stale_job_work_suppressed = stats.stale_job_work_suppressed + 1
                    stats.skipped_results = stats.skipped_results + 1
                  end
                elseif not proof_suppressed then
                  local sig_item = note_result_signature(result_diag, "suppressed", job, "")
                  local dup_diag = classify_duplicate_result(result_diag, job, sig_item, "after_submit")
                  stats.duplicate_submit_key_repeat = stats.duplicate_submit_key_repeat + 1
                  stats.duplicate_result_frames = stats.duplicate_result_frames + 1
                  if matched_alias_kind == "mid4" then stats.result_mid4_alias_duplicates = stats.result_mid4_alias_duplicates + 1 end
                  ddr_account_event("duplicates_by_ddr", 1)
                  duplicate_results_since_work = duplicate_results_since_work + 1
                  cmd04_event_sample("duplicate_result_frame", frame, job, matched_key, decoded_result_lane, result_lane_byte, key, {
                    duplicate_reason = "submit_key",
                    proof_key = proof_key,
                    result_signature = result_diag.signature,
                    duplicate_bucket = dup_diag.duplicate_bucket,
                    first_seen = dup_diag.first_seen,
                    repeat_count = dup_diag.repeat_count,
                    original_status = dup_diag.original_status,
                    stock_tail_key_repeats = dup_diag.stock_tail_key_repeats,
                    stock_tail_key = dup_diag.stock_tail_key,
                    stock_progress_key = dup_diag.stock_progress_key,
                    stock_tail_repeat_count = dup_diag.stock_tail_repeat_count,
                    stock_tail_first_status = dup_diag.stock_tail_first_status,
                    stock_tail_first_signature = dup_diag.stock_tail_first_signature,
                  })
                  if should_store_duplicate_sample(dup_diag) then
                    push_bounded(stats.duplicate_result_samples, {
                      at = result_diag.at,
                      signature = result_diag.signature,
                      duplicate_bucket = dup_diag.duplicate_bucket,
                      nonce_hex = result_diag.nonce_hex,
                      proof_hash = result_diag.proof_hash,
                      result_crc = result_diag.result_crc,
                      b6_b7 = result_diag.b6_b7,
                      stock_tail_key = dup_diag.stock_tail_key,
                      stock_progress_key = dup_diag.stock_progress_key,
                      stock_tail_repeat_count = dup_diag.stock_tail_repeat_count,
                      stock_tail_first_status = dup_diag.stock_tail_first_status,
                      stock_tail_first_signature = dup_diag.stock_tail_first_signature,
                      repeat_count = dup_diag.repeat_count,
                      original_status = dup_diag.original_status,
                      lane = dup_diag.lane,
                      job_key = tostring(job.key or ""),
                      delta_ms = dup_diag.delta_ms,
                    }, DIAG_HEAVY_SAMPLE_LIMIT)
                  end
                end
                end
              else
                local sig_item = note_result_signature(result_diag, "unknown", nil, "")
                local unknown_diag = classify_unknown_result(result_diag, candidates, sig_item)
                stats.stale_result_frames = stats.stale_result_frames + 1
                stats.unknown_result_frames = stats.unknown_result_frames + 1
                if matched_alias_kind == "mid4" then stats.result_mid4_alias_unknowns = stats.result_mid4_alias_unknowns + 1 end
                ddr_account_event("unknowns_by_ddr", 1)
                stats.skipped_results = stats.skipped_results + 1
                unknown_results_since_work = unknown_results_since_work + 1
                local sample = {
                  at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                  candidates = candidates,
                  result_lane_byte = string.format("%02x", result_lane_byte),
                  decoded_result_lane = decoded_result_lane,
                  frame_prefix = hex_range(frame, 1, math.min(32, #frame)),
                  raw_frame_hash = result_diag.raw_frame_hash,
                  nonce_hex = result_diag.nonce_hex,
                  proof_hash = result_diag.proof_hash,
                  tail_b4_b7 = result_diag.tail_b4_b7,
                  b6_b7 = result_diag.b6_b7,
                  result_crc = result_diag.result_crc,
                  stock_tail_key = unknown_diag.stock_tail_key,
                  stock_progress_key = unknown_diag.stock_progress_key,
                  stock_tail_repeat_count = unknown_diag.stock_tail_repeat_count,
                  stock_tail_first_status = unknown_diag.stock_tail_first_status,
                  stock_tail_first_signature = unknown_diag.stock_tail_first_signature,
                  ddr_raw_hex = result_diag.ddr_raw_hex,
                  ddr_effective_mhz = result_diag.ddr_effective_mhz,
                  active_job_key = result_diag.active_job_key,
                  pool_generation = result_diag.pool_generation,
                  primary_bucket = unknown_diag.primary_bucket,
                  matched_full_8 = unknown_diag.matched_full_8,
                  matched_id6 = unknown_diag.matched_id6,
                  matched_first4 = unknown_diag.matched_first4,
                  matched_mid4 = unknown_diag.matched_mid4,
                  matched_recent_pruned = unknown_diag.matched_recent_pruned,
                  matched_recent_sent_work = unknown_diag.matched_recent_sent_work,
                  alias_collision_detected = unknown_diag.alias_collision_detected,
                  lane_matches_sent = unknown_diag.lane_matches_sent,
                  current_job_matches_sent_job = unknown_diag.current_job_matches_sent_job,
                  pool_generation_matches = unknown_diag.pool_generation_matches,
                  matched_alias = unknown_diag.matched_alias,
                  matched_sent_job_key = unknown_diag.matched_sent_job_key,
                  matched_pruned_job_key = unknown_diag.matched_pruned_job_key,
                  send_age_ms = unknown_diag.send_age_ms,
                  prune_age_ms = unknown_diag.prune_age_ms,
                }
                push_bounded(stats.unknown_result_samples, sample, DIAG_HEAVY_SAMPLE_LIMIT)
                cmd04_event_sample("unknown_result_frame", frame, nil, nil, decoded_result_lane, result_lane_byte, table.concat(candidates, ","), {
                  candidates = candidates,
                  frame_prefix = sample.frame_prefix,
                  result_signature = result_diag.signature,
                  raw_frame_hash = result_diag.raw_frame_hash,
                  primary_bucket = unknown_diag.primary_bucket,
                  matched_alias = unknown_diag.matched_alias,
                  matched_full_8 = unknown_diag.matched_full_8,
                  matched_id6 = unknown_diag.matched_id6,
                  matched_first4 = unknown_diag.matched_first4,
                  matched_mid4 = unknown_diag.matched_mid4,
                  matched_recent_pruned = unknown_diag.matched_recent_pruned,
                  matched_recent_sent_work = unknown_diag.matched_recent_sent_work,
                  alias_collision_detected = unknown_diag.alias_collision_detected,
                  lane_matches_sent = unknown_diag.lane_matches_sent,
                  current_job_matches_sent_job = unknown_diag.current_job_matches_sent_job,
                  pool_generation_matches = unknown_diag.pool_generation_matches,
                  send_age_ms = unknown_diag.send_age_ms,
                  prune_age_ms = unknown_diag.prune_age_ms,
                  stock_tail_key = unknown_diag.stock_tail_key,
                  stock_progress_key = unknown_diag.stock_progress_key,
                  stock_tail_repeat_count = unknown_diag.stock_tail_repeat_count,
                  stock_tail_first_status = unknown_diag.stock_tail_first_status,
                  stock_tail_first_signature = unknown_diag.stock_tail_first_signature,
                })
                emit({event = "unknown_result", bucket = unknown_diag.primary_bucket, candidates = candidates, frame_prefix = sample.frame_prefix, result_lane_byte = string.format("%02x", result_lane_byte), decoded_result_lane = decoded_result_lane})
              end
              write_stats("running")
            end
          else
            stats.crc_resync = stats.crc_resync + 1
            local resync_candidate = find_resync_candidate(need)
            if buf[3] == 0x04 then
              local recover_candidate = resync_candidate.candidate_valid and recoverable_resync_type(resync_candidate.candidate_type)
              local discard_amount = recover_candidate and (resync_candidate.embedded_at - 1) or need
              local embedded_bucket = crc_resync_bucket(resync_candidate.embedded_at)
              local silent_tail_embedded = resync_candidate.candidate_valid
                and embedded_bucket == "tail"
                and (resync_candidate.candidate_type == 0x01 or resync_candidate.candidate_type == 0x03)
              local action = silent_tail_embedded and "silent_drop_tail_embedded" or "nack_drop_frame"
              note_crc_resync(buf[3], need, got, calc, discard_amount, resync_candidate, action)
              if not silent_tail_embedded then
                serial:write(hex_to_bytes(nack_hex))
                serial:flush()
                stats.uart_result_nacks = stats.uart_result_nacks + 1
              end
              if recover_candidate then
                stats.crc_resync_recovered_frames = stats.crc_resync_recovered_frames + 1
              end
              for _ = 1, discard_amount do table.remove(buf, 1) end
              write_stats("running")
            elseif buf[3] == 0x01 then
              stats.cmd01_crc_errors = stats.cmd01_crc_errors + 1
              local recover_candidate = resync_candidate.candidate_valid and recoverable_resync_type(resync_candidate.candidate_type)
              local discard_amount = recover_candidate and (resync_candidate.embedded_at - 1) or need
              note_crc_resync(buf[3], need, got, calc, discard_amount, resync_candidate)
              if recover_candidate then
                stats.crc_resync_recovered_frames = stats.crc_resync_recovered_frames + 1
              end
              for _ = 1, discard_amount do table.remove(buf, 1) end
              write_stats("running")
            elseif buf[3] == 0x03 then
              stats.uart_status_crc_errors = stats.uart_status_crc_errors + 1
              push_bounded(stats.status_frame_samples, {
                at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                frame_hex = hex_range(buf, 1, math.min(need, #buf)),
                crc_valid = false,
              }, DIAG_SAMPLE_LIMIT)
              local recover_candidate = resync_candidate.candidate_valid and recoverable_resync_type(resync_candidate.candidate_type)
              local discard_amount = recover_candidate and (resync_candidate.embedded_at - 1) or need
              note_crc_resync(buf[3], need, got, calc, discard_amount, resync_candidate)
              if recover_candidate then
                stats.crc_resync_recovered_frames = stats.crc_resync_recovered_frames + 1
              end
              for _ = 1, discard_amount do table.remove(buf, 1) end
              write_stats("running")
            else
              note_crc_resync(buf[3], need, got, calc, 1, resync_candidate)
              table.remove(buf, 1)
            end
          end
        end
      end
    end

    if enable_dwell_refresh and active and os.time() - active.sent_epoch >= dwell then
      active.stale_reason = active.stale_reason or "dwell_complete"
      last_sent_stratum_job_key = stratum_job_key(latest_job)
      send_work_set("dwell_complete")
    end
    if enable_result_refresh then
      local now = os.time()
      if unknown_results_since_work >= UNKNOWN_RESULT_REFRESH_THRESHOLD then
        maybe_result_refresh("unknown_result_refresh")
      elseif duplicate_results_since_work >= DUPLICATE_RESULT_REFRESH_THRESHOLD then
        maybe_result_refresh("duplicate_result_refresh")
      elseif stats.accepted > 0 and last_accept_epoch > 0 and now - last_accept_epoch >= NO_ACCEPT_WORK_REFRESH_SECONDS then
        maybe_result_refresh("no_accept_result_refresh")
      end
    end
    if enable_soft_refresh then maybe_soft_refresh() end
    local now_ms = monotonic_ms()
    if resend_interval_ms > 0 and serial and #last_work_frames > 0 and now_ms - last_resend_ms >= resend_interval_ms then
      last_resend_ms = now_ms
      stats.resends = stats.resends + 1
      stats.last_resend_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
      for _, frame in ipairs(last_work_frames) do
        send_frame(serial, "resend-work-" .. tostring(frame.key) .. "-lane-" .. tostring(frame.lane), hex_to_bytes(frame.frame_hex))
        stats.resend_frames = stats.resend_frames + 1
      end
    end
    if os.time() - last_stats >= STATS_WRITE_INTERVAL_SECONDS then
      if active and stats.current_job then stats.current_job.age_seconds = os.time() - active.sent_epoch end
      if stats.active_jobs_by_lane then
        for lane = 1, 3 do
          local lane_job = active_by_lane[lane]
          local lane_stats = stats.active_jobs_by_lane[tostring(lane)]
          if lane_job and lane_stats then lane_stats.age_seconds = os.time() - lane_job.sent_epoch end
        end
      end
      prune_old_tracked()
      write_stats("running")
      last_stats = os.time()
    end
  end

  serial:close()
  stratum_stop(st)
  restore_stock()
  write_stats("stopped")
  emit({event = "miner_end", accepted = stats.accepted, rejected = stats.rejected, jobs_sent = stats.jobs_sent, results = stats.uart_result_frames})
end

local ok, err = pcall(main)
if not ok then
  stats.errors[#stats.errors + 1] = {at = os.date("!%Y-%m-%dT%H:%M:%SZ"), error = tostring(err)}
  write_stats("error")
  emit({event = "miner_error", error = tostring(err)})
  pcall(restore_stock)
  os.exit(1)
end






