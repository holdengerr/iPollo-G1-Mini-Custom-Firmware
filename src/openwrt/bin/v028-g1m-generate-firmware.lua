#!/usr/bin/lua

local BASE_FIRMWARE = "/root/firmware-base/Mini-G22-base.bin"
local OUTPUT_DIR = "/root/uploaded-firmware"

local DDR_STARTUP_OFFSET = 0x000130AA
local DDR_UPPER_OFFSET = 0x0001344C
local DDR_LOWER_OFFSET = 0x00013488

local VDDR_ISL_VMAX_PRINT_OFFSET = 0x0000E6C0
local VDDR_ISL_VMAX_HIGH_BYTE_OFFSET = 0x0000E67A
local VDDR_ISL_VMAX_LOW_BYTE_OFFSET = 0x0000E682
local VDDR_ISL_HIGH_BYTE_OFFSET = 0x0000E6CC
local VDDR_ISL_LOW_BYTE_OFFSET = 0x0000E6D4
local VDDR_ISL_PRINT_OFFSET = 0x0000E712
local VDDR_MINI_PAYLOAD_OFFSET = 0x0000EC12
local VDDR_MINI_PRINT_OFFSET = 0x0000EC68

local VCORE_PROFILE_OFFSET_1 = 0x0000E4B2
local VCORE_PROFILE_OFFSET_2 = 0x0000E4DA
local VCORE_PAYLOAD_OFFSET = 0x0000ED14
local VCORE_PRINT_OFFSET = 0x0000ED6A

local BRIDGE_PATCHES = {
	{ offset = 0x00F204, bytes = {0x13, 0xd5, 0x87, 0x01} },
	{ offset = 0x00F208, bytes = {0x93, 0xf6, 0xf7, 0x0f} },
}
local tunpack = table.unpack or unpack

local function fail(msg)
	io.stderr:write(msg .. "\n")
	os.exit(1)
end

local function is_int_string(s)
	return s and s:match("^%d+$") ~= nil
end

local function to_int(name, value)
	if not is_int_string(value) then
		fail(name .. " must be a whole number")
	end
	return tonumber(value)
end

local function le32(v)
	local b1 = v % 256
	v = math.floor(v / 256)
	local b2 = v % 256
	v = math.floor(v / 256)
	local b3 = v % 256
	v = math.floor(v / 256)
	local b4 = v % 256
	return string.char(b1, b2, b3, b4)
end

local function encode_addi(rd, rs1, imm12)
	if imm12 < 0 or imm12 > 0xFFF then
		fail(string.format("addi immediate out of range: 0x%x", imm12))
	end
	local insn = ((imm12 % 0x1000) * 0x100000) + ((rs1 % 0x20) * 0x8000) + ((rd % 0x20) * 0x80) + 0x13
	return le32(insn)
end

local function encode_sltiu(rd, rs1, imm12)
	if imm12 < 0 or imm12 > 0xFFF then
		fail(string.format("sltiu immediate out of range: 0x%x", imm12))
	end
	local insn = ((imm12 % 0x1000) * 0x100000) + ((rs1 % 0x20) * 0x8000) + (3 * 0x1000) + ((rd % 0x20) * 0x80) + 0x13
	return le32(insn)
end

local function patch_blob(blob, offset, bytes)
	local start_index = offset + 1
	local end_index = offset + #bytes
	if end_index > #blob then
		fail(string.format("patch past end of firmware at 0x%08x", offset))
	end
	return blob:sub(1, start_index - 1) .. bytes .. blob:sub(end_index + 1)
end

local function patch_table(blob, offset, byte_table)
	return patch_blob(blob, offset, string.char(tunpack(byte_table)))
end

local function json_escape(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\r", "\\r")
	s = s:gsub("\n", "\\n")
	s = s:gsub("\t", "\\t")
	return s
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		fail("unable to open base firmware: " .. path)
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function write_file(path, data)
	local f = io.open(path, "wb")
	if not f then
		fail("unable to write file: " .. path)
	end
	f:write(data)
	f:close()
end

local function file_exists(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

local function validate_args(ddr_mhz, vddr_mv, vcore_mv)
	if ddr_mhz < 1872 or ddr_mhz > 2220 or (ddr_mhz % 12) ~= 0 then
		fail("DDR must be 1872-2220 MHz in 12 MHz steps")
	end
	if vddr_mv < 1200 or vddr_mv > 1600 or (vddr_mv % 2) ~= 0 then
		fail("Vddr must be 1200-1600 mV and even")
	end
	if vcore_mv < 1000 or vcore_mv > 1100 or (vcore_mv % 2) ~= 0 then
		fail("Vcore must be 1000-1100 mV and even")
	end
end

local ddr_mhz = to_int("DDR", arg[1])
local vddr_mv = to_int("Vddr", arg[2])
local vcore_mv = to_int("Vcore", arg[3])
validate_args(ddr_mhz, vddr_mv, vcore_mv)

local ddr_raw = math.floor(ddr_mhz / 12)
local ddr_raw_hex = string.format("0x%02x", ddr_raw)
local profile = string.format("generated-ddr%02x-vddr%d-vcore%d", ddr_raw, vddr_mv, vcore_mv)
local label = string.format("Custom %d MHz / Vddr %d / Vcore %d", ddr_mhz, vddr_mv, vcore_mv)
local base_name = string.format("generated-ddr%02x-vddr%d-vcore%d", ddr_raw, vddr_mv, vcore_mv)
local bin_path = OUTPUT_DIR .. "/" .. base_name .. ".bin"
local manifest_path = OUTPUT_DIR .. "/" .. base_name .. ".json"

os.execute("mkdir -p '" .. OUTPUT_DIR .. "'")

if file_exists(bin_path) and file_exists(manifest_path) then
	print(bin_path .. "|" .. manifest_path .. "|reused|" .. profile)
	os.exit(0)
end

local firmware = read_file(BASE_FIRMWARE)
firmware = patch_blob(firmware, DDR_STARTUP_OFFSET, encode_addi(14, 0, ddr_raw))
firmware = patch_blob(firmware, DDR_UPPER_OFFSET, encode_addi(14, 0, ddr_raw - 1))
firmware = patch_blob(firmware, DDR_LOWER_OFFSET, encode_sltiu(15, 15, ddr_raw + 1))

local vddr_hi = math.floor(vddr_mv / 256)
local vddr_lo = vddr_mv % 256
local vddr_raw_half = math.floor(vddr_mv / 2)
firmware = patch_blob(firmware, VDDR_ISL_VMAX_HIGH_BYTE_OFFSET, encode_addi(15, 0, vddr_hi))
firmware = patch_blob(firmware, VDDR_ISL_VMAX_LOW_BYTE_OFFSET, encode_addi(15, 0, vddr_lo))
firmware = patch_blob(firmware, VDDR_ISL_HIGH_BYTE_OFFSET, encode_addi(15, 0, vddr_hi))
firmware = patch_blob(firmware, VDDR_ISL_LOW_BYTE_OFFSET, encode_addi(15, 0, vddr_lo))
firmware = patch_blob(firmware, VDDR_MINI_PAYLOAD_OFFSET, encode_addi(15, 0, vddr_raw_half))
firmware = patch_blob(firmware, VDDR_ISL_VMAX_PRINT_OFFSET, encode_addi(11, 0, vddr_mv))
firmware = patch_blob(firmware, VDDR_ISL_PRINT_OFFSET, encode_addi(11, 0, vddr_mv))
firmware = patch_blob(firmware, VDDR_MINI_PRINT_OFFSET, encode_addi(11, 0, vddr_mv))

firmware = patch_blob(firmware, VCORE_PROFILE_OFFSET_1, encode_addi(14, 0, vcore_mv))
firmware = patch_blob(firmware, VCORE_PROFILE_OFFSET_2, encode_addi(14, 0, vcore_mv))
firmware = patch_blob(firmware, VCORE_PAYLOAD_OFFSET, encode_addi(15, 0, math.floor(vcore_mv / 2)))
firmware = patch_blob(firmware, VCORE_PRINT_OFFSET, encode_addi(11, 0, vcore_mv))

for _, patch in ipairs(BRIDGE_PATCHES) do
	firmware = patch_table(firmware, patch.offset, patch.bytes)
end

write_file(bin_path, firmware)

local manifest = table.concat({
	"{\n",
	'  "generated_at": "' .. json_escape(os.date("!%Y-%m-%dT%H:%M:%SZ")) .. '",\n',
	'  "tool": "/usr/bin/g1m-generate-firmware",\n',
	'  "base": "' .. json_escape(BASE_FIRMWARE) .. '",\n',
	'  "firmware": "' .. json_escape(bin_path) .. '",\n',
	'  "manifest": "' .. json_escape(manifest_path) .. '",\n',
	'  "profile": "' .. json_escape(profile) .. '",\n',
	'  "label": "' .. json_escape(label) .. '",\n',
	'  "settings": {\n',
	'    "ddr_raw_hex": "' .. ddr_raw_hex .. '",\n',
	'    "ddr_effective_mhz": ' .. ddr_mhz .. ',\n',
	'    "vddr_mv": ' .. vddr_mv .. ',\n',
	'    "vcore_mv": ' .. vcore_mv .. '\n',
	"  }\n",
	"}\n"
})
write_file(manifest_path, manifest)

print(bin_path .. "|" .. manifest_path .. "|generated|" .. profile)
