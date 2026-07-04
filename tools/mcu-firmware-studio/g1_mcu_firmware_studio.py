#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASE = REPO_ROOT / "firmware" / "Mini-G22.bin"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "outputs" / "pc-generated-firmware"

DDR_STARTUP_OFFSET = 0x000130AA
DDR_UPPER_OFFSET = 0x0001344C
DDR_LOWER_OFFSET = 0x00013488

VDDR_ISL_VMAX_PRINT_OFFSET = 0x0000E6C0
VDDR_ISL_VMAX_HIGH_BYTE_OFFSET = 0x0000E67A
VDDR_ISL_VMAX_LOW_BYTE_OFFSET = 0x0000E682
VDDR_ISL_HIGH_BYTE_OFFSET = 0x0000E6CC
VDDR_ISL_LOW_BYTE_OFFSET = 0x0000E6D4
VDDR_ISL_PRINT_OFFSET = 0x0000E712
VDDR_MINI_PAYLOAD_OFFSET = 0x0000EC12
VDDR_MINI_PRINT_OFFSET = 0x0000EC68

VCORE_PROFILE_OFFSET_1 = 0x0000E4B2
VCORE_PROFILE_OFFSET_2 = 0x0000E4DA
VCORE_PAYLOAD_OFFSET = 0x0000ED14
VCORE_PRINT_OFFSET = 0x0000ED6A

BRIDGE_PATCHES = {
    0x00F204: bytes.fromhex("13 d5 87 01"),
    0x00F208: bytes.fromhex("93 f6 f7 0f"),
}

STATE = {
    "recent": [],
    "last_generated": None,
}


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def le32(value: int) -> bytes:
    return value.to_bytes(4, "little")


def encode_addi(rd: int, rs1: int, imm12: int) -> bytes:
    if not (0 <= imm12 <= 0xFFF):
        raise ValueError(f"imm12 out of range: 0x{imm12:x}")
    insn = ((imm12 & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((0 & 0x7) << 12) | ((rd & 0x1F) << 7) | 0x13
    return le32(insn)


def encode_sltiu(rd: int, rs1: int, imm12: int) -> bytes:
    if not (0 <= imm12 <= 0xFFF):
        raise ValueError(f"imm12 out of range: 0x{imm12:x}")
    insn = ((imm12 & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((3 & 0x7) << 12) | ((rd & 0x1F) << 7) | 0x13
    return le32(insn)


def parse_int(value: str | int, field: str) -> int:
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text:
        raise ValueError(f"{field} is required")
    try:
        return int(text, 0)
    except ValueError as exc:
        raise ValueError(f"{field} must be an integer or hex value") from exc


def encode_name(value: str) -> str:
    safe = []
    for ch in value.lower():
        if ch.isalnum():
            safe.append(ch)
        elif ch in ("-", "_"):
            safe.append(ch)
        else:
            safe.append("-")
    cooked = "".join(safe).strip("-")
    while "--" in cooked:
        cooked = cooked.replace("--", "-")
    return cooked or "custom"


def patch_slice(data: bytearray, offset: int, new_bytes: bytes, desc: str, patches: list[dict], extra: dict | None = None) -> None:
    old_bytes = bytes(data[offset : offset + len(new_bytes)])
    data[offset : offset + len(new_bytes)] = new_bytes
    record = {
        "offset": f"0x{offset:08x}",
        "old_bytes": old_bytes.hex(" "),
        "new_bytes": new_bytes.hex(" "),
        "desc": desc,
    }
    if extra:
        record.update(extra)
    patches.append(record)


def build_firmware(payload: dict) -> dict:
    base_path = Path(payload.get("base_path") or DEFAULT_BASE).expanduser().resolve()
    output_dir = Path(payload.get("output_dir") or DEFAULT_OUTPUT_DIR).expanduser().resolve()
    profile_name = str(payload.get("profile_name") or "").strip()
    include_bridge = bool(payload.get("include_bridge_telemetry", True))
    include_vcore_payload = bool(payload.get("include_vcore_payload", True))
    include_vcore_print = bool(payload.get("include_vcore_print", True))
    include_vddr_print = bool(payload.get("include_vddr_print", True))

    if not base_path.is_file():
        raise FileNotFoundError(f"Base firmware not found: {base_path}")

    ddr_raw = parse_int(payload.get("ddr_raw"), "DDR raw")
    vddr_mv = parse_int(payload.get("vddr_mv"), "Vddr mV")
    vcore_mv = parse_int(payload.get("vcore_mv"), "Vcore mV")
    if not (0 <= ddr_raw <= 0xFFF):
        raise ValueError("DDR raw must be between 0x000 and 0xFFF")
    if not (1000 <= vddr_mv <= 2000):
        raise ValueError("Vddr mV must be between 1000 and 2000")
    if not (900 <= vcore_mv <= 2000):
        raise ValueError("Vcore mV must be between 900 and 2000")
    if vcore_mv % 2:
        raise ValueError("Vcore mV must be even because the runtime payload path uses mV/2 raw units")

    target_slug = profile_name or f"ddr{ddr_raw:02x}-vddr{vddr_mv}-vcore{vcore_mv}"
    target_slug = encode_name(target_slug)

    output_dir.mkdir(parents=True, exist_ok=True)
    output_bin = output_dir / f"Mini-G22-{target_slug}.bin"
    output_manifest = output_dir / f"Mini-G22-{target_slug}.json"

    data = bytearray(base_path.read_bytes())
    original_sha = sha256_hex(data)
    patches: list[dict] = []

    startup_new = encode_addi(rd=14, rs1=0, imm12=ddr_raw)
    upper_new = encode_addi(rd=14, rs1=0, imm12=ddr_raw - 1)
    lower_new = encode_sltiu(rd=15, rs1=15, imm12=ddr_raw + 1)
    patch_slice(data, DDR_STARTUP_OFFSET, startup_new, f"DDR startup target -> 0x{ddr_raw:02x} / {ddr_raw * 12} MHz", patches)
    patch_slice(data, DDR_UPPER_OFFSET, upper_new, f"DDR governor upper guard -> 0x{ddr_raw - 1:02x}", patches)
    patch_slice(data, DDR_LOWER_OFFSET, lower_new, f"DDR governor lower guard compare -> 0x{ddr_raw + 1:02x}", patches)

    vddr_hi = (vddr_mv >> 8) & 0xFF
    vddr_lo = vddr_mv & 0xFF
    vddr_raw = vddr_mv // 2
    if vddr_mv % 2:
        raise ValueError("Vddr mV must be even because the active Mini path uses mV/2 raw units")
    if not (0 <= vddr_raw <= 0xFFF):
        raise ValueError(f"Vddr raw out of range after mV/2 conversion: 0x{vddr_raw:x}")

    patch_slice(data, VDDR_ISL_VMAX_HIGH_BYTE_OFFSET, encode_addi(rd=15, rs1=0, imm12=vddr_hi), f"ISL DDR VMAX high byte -> 0x{vddr_hi:02x}", patches)
    patch_slice(data, VDDR_ISL_VMAX_LOW_BYTE_OFFSET, encode_addi(rd=15, rs1=0, imm12=vddr_lo), f"ISL DDR VMAX low byte -> 0x{vddr_lo:02x}", patches)
    patch_slice(data, VDDR_ISL_HIGH_BYTE_OFFSET, encode_addi(rd=15, rs1=0, imm12=vddr_hi), f"ISL Vddr payload high byte -> 0x{vddr_hi:02x}", patches)
    patch_slice(data, VDDR_ISL_LOW_BYTE_OFFSET, encode_addi(rd=15, rs1=0, imm12=vddr_lo), f"ISL Vddr payload low byte -> 0x{vddr_lo:02x}", patches)
    patch_slice(
        data,
        VDDR_MINI_PAYLOAD_OFFSET,
        encode_addi(rd=15, rs1=0, imm12=vddr_raw),
        f"Mini Vddr runtime payload raw -> 0x{vddr_raw:03x} ({vddr_mv} mV target)",
        patches,
    )
    if include_vddr_print:
        patch_slice(data, VDDR_ISL_VMAX_PRINT_OFFSET, encode_addi(rd=11, rs1=0, imm12=vddr_mv), f"ISL Set ddr VMAX print argument -> {vddr_mv}", patches)
        patch_slice(data, VDDR_ISL_PRINT_OFFSET, encode_addi(rd=11, rs1=0, imm12=vddr_mv), f"ISL Set Vddr print argument -> {vddr_mv}", patches)
        patch_slice(data, VDDR_MINI_PRINT_OFFSET, encode_addi(rd=11, rs1=0, imm12=vddr_mv), f"Mini Set Vddr print argument -> {vddr_mv}", patches)

    patch_slice(data, VCORE_PROFILE_OFFSET_1, encode_addi(rd=14, rs1=0, imm12=vcore_mv), f"Vcore profile initializer 1 -> {vcore_mv} mV", patches)
    patch_slice(data, VCORE_PROFILE_OFFSET_2, encode_addi(rd=14, rs1=0, imm12=vcore_mv), f"Vcore profile initializer 2 -> {vcore_mv} mV", patches)
    if include_vcore_payload:
        patch_slice(
            data,
            VCORE_PAYLOAD_OFFSET,
            encode_addi(rd=15, rs1=0, imm12=vcore_mv // 2),
            f"Vcore runtime payload raw -> 0x{vcore_mv // 2:03x} ({vcore_mv} mV target)",
            patches,
        )
    if include_vcore_print:
        patch_slice(data, VCORE_PRINT_OFFSET, encode_addi(rd=11, rs1=0, imm12=vcore_mv), f"Vcore print argument -> {vcore_mv} mV", patches)

    if include_bridge:
        for offset, new_bytes in BRIDGE_PATCHES.items():
            desc = "bridge telemetry patch retained" if bytes(data[offset : offset + len(new_bytes)]) == new_bytes else "enable read-only PMBus bridge telemetry"
            patch_slice(data, offset, new_bytes, desc, patches)

    output_bin.write_bytes(data)
    output_sha = sha256_hex(data)

    manifest = {
        "generated_at": now_iso(),
        "tool": str(Path(__file__).resolve()),
        "base": str(base_path),
        "base_sha256": original_sha,
        "firmware": str(output_bin),
        "manifest": str(output_manifest),
        "profile": target_slug,
        "settings": {
            "ddr_raw_hex": f"0x{ddr_raw:02x}",
            "ddr_effective_mhz": ddr_raw * 12,
            "vddr_mv": vddr_mv,
            "vcore_mv": vcore_mv,
            "include_bridge_telemetry": include_bridge,
            "include_vcore_payload": include_vcore_payload,
            "include_vcore_print": include_vcore_print,
            "include_vddr_print": include_vddr_print,
        },
        "output_sha256": output_sha,
        "patches": patches,
    }
    output_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    recent_entry = {
        "generated_at": manifest["generated_at"],
        "firmware": str(output_bin),
        "manifest": str(output_manifest),
        "profile": target_slug,
        "ddr_raw_hex": f"0x{ddr_raw:02x}",
        "ddr_effective_mhz": ddr_raw * 12,
        "vddr_mv": vddr_mv,
        "vcore_mv": vcore_mv,
        "sha256": output_sha,
    }
    STATE["last_generated"] = recent_entry
    STATE["recent"] = [recent_entry] + [item for item in STATE["recent"] if item.get("firmware") != recent_entry["firmware"]][:19]
    return manifest


class App:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("G1 MCU Firmware Studio")
        self.root.geometry("980x760")
        self.root.minsize(860, 660)

        self.base_path = tk.StringVar(value=str(DEFAULT_BASE))
        self.output_dir = tk.StringVar(value=str(DEFAULT_OUTPUT_DIR))
        self.profile_name = tk.StringVar(value="custom-ddr9c-vddr1300-vcore1080")
        self.ddr_raw = tk.StringVar(value="0x9c")
        self.vddr_mv = tk.StringVar(value="1300")
        self.vcore_mv = tk.StringVar(value="1080")
        self.include_bridge = tk.BooleanVar(value=True)
        self.include_vcore_payload = tk.BooleanVar(value=True)
        self.include_vcore_print = tk.BooleanVar(value=True)
        self.include_vddr_print = tk.BooleanVar(value=True)
        self.status = tk.StringVar(value="Ready.")
        self.last_firmware = tk.StringVar(value="--")
        self.last_manifest = tk.StringVar(value="--")

        self._build_ui()

    def _build_ui(self) -> None:
        pad = {"padx": 10, "pady": 6}
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(1, weight=1)

        header = ttk.Frame(self.root, padding=14)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        ttk.Label(header, text="G1 MCU Firmware Studio", font=("Segoe UI", 17, "bold")).grid(row=0, column=0, sticky="w")
        ttk.Label(header, text="Generate patched Mini-G22.bin images on the PC. Upload stays on the miner admin page.", foreground="#666").grid(row=1, column=0, sticky="w", pady=(2, 0))

        body = ttk.Frame(self.root, padding=(14, 0, 14, 14))
        body.grid(row=1, column=0, sticky="nsew")
        body.columnconfigure(0, weight=1)
        body.rowconfigure(2, weight=1)

        form = ttk.LabelFrame(body, text="Firmware Settings", padding=12)
        form.grid(row=0, column=0, sticky="ew")
        form.columnconfigure(1, weight=1)

        def add_row(row: int, label: str, variable: tk.StringVar, browse: str | None = None) -> None:
            ttk.Label(form, text=label).grid(row=row, column=0, sticky="w", **pad)
            entry = ttk.Entry(form, textvariable=variable)
            entry.grid(row=row, column=1, sticky="ew", **pad)
            if browse == "file":
                ttk.Button(form, text="Browse", command=lambda: self._pick_file(variable)).grid(row=row, column=2, sticky="ew", **pad)
            elif browse == "dir":
                ttk.Button(form, text="Browse", command=lambda: self._pick_dir(variable)).grid(row=row, column=2, sticky="ew", **pad)

        add_row(0, "Base Firmware Path", self.base_path, "file")
        add_row(1, "Output Directory", self.output_dir, "dir")
        add_row(2, "Profile Name", self.profile_name)
        add_row(3, "DDR Raw", self.ddr_raw)
        add_row(4, "Vddr (mV)", self.vddr_mv)
        add_row(5, "Vcore (mV)", self.vcore_mv)
        checks = ttk.LabelFrame(body, text="Patch Options", padding=12)
        checks.grid(row=1, column=0, sticky="ew", pady=(12, 0))
        ttk.Checkbutton(checks, text="Include read-only bridge telemetry patch", variable=self.include_bridge).grid(row=0, column=0, sticky="w", **pad)
        ttk.Checkbutton(checks, text="Patch runtime Vcore payload at 0xed14", variable=self.include_vcore_payload).grid(row=1, column=0, sticky="w", **pad)
        ttk.Checkbutton(checks, text="Patch printed Vcore argument", variable=self.include_vcore_print).grid(row=2, column=0, sticky="w", **pad)
        ttk.Checkbutton(checks, text="Patch printed Vddr argument", variable=self.include_vddr_print).grid(row=3, column=0, sticky="w", **pad)

        bottom = ttk.Panedwindow(body, orient=tk.VERTICAL)
        bottom.grid(row=2, column=0, sticky="nsew", pady=(12, 0))

        actions = ttk.Frame(bottom, padding=0)
        actions.columnconfigure(1, weight=1)
        ttk.Button(actions, text="Generate Firmware", command=self.generate).grid(row=0, column=0, sticky="w")
        ttk.Button(actions, text="Open Output Folder", command=self.open_output_dir).grid(row=0, column=1, sticky="w", padx=(10, 0))
        ttk.Label(actions, textvariable=self.status).grid(row=1, column=0, columnspan=2, sticky="w", pady=(10, 0))
        ttk.Label(actions, textvariable=self.last_firmware, wraplength=900).grid(row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))
        ttk.Label(actions, textvariable=self.last_manifest, wraplength=900).grid(row=3, column=0, columnspan=2, sticky="w", pady=(2, 0))
        bottom.add(actions, weight=0)

        result_frame = ttk.LabelFrame(bottom, text="Manifest / Patch Log", padding=8)
        result_frame.columnconfigure(0, weight=1)
        result_frame.rowconfigure(0, weight=1)
        self.result = tk.Text(result_frame, wrap="word", height=24)
        self.result.grid(row=0, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(result_frame, orient="vertical", command=self.result.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.result.configure(yscrollcommand=scroll.set)
        bottom.add(result_frame, weight=1)

    def _pick_file(self, variable: tk.StringVar) -> None:
        initial = Path(variable.get()).expanduser()
        chosen = filedialog.askopenfilename(initialdir=str(initial.parent if initial.parent.exists() else REPO_ROOT))
        if chosen:
            variable.set(chosen)

    def _pick_dir(self, variable: tk.StringVar) -> None:
        initial = Path(variable.get()).expanduser()
        chosen = filedialog.askdirectory(initialdir=str(initial if initial.exists() else REPO_ROOT))
        if chosen:
            variable.set(chosen)

    def _payload(self) -> dict:
        return {
            "base_path": self.base_path.get().strip(),
            "output_dir": self.output_dir.get().strip(),
            "profile_name": self.profile_name.get().strip(),
            "ddr_raw": self.ddr_raw.get().strip(),
            "vddr_mv": self.vddr_mv.get().strip(),
            "vcore_mv": self.vcore_mv.get().strip(),
            "include_bridge_telemetry": self.include_bridge.get(),
            "include_vcore_payload": self.include_vcore_payload.get(),
            "include_vcore_print": self.include_vcore_print.get(),
            "include_vddr_print": self.include_vddr_print.get(),
        }

    def generate(self) -> None:
        try:
            manifest = build_firmware(self._payload())
        except Exception as exc:  # noqa: BLE001
            self.status.set(f"Generation failed: {exc}")
            messagebox.showerror("Generation failed", str(exc))
            return

        self.status.set("Firmware generated.")
        self.last_firmware.set(f"Firmware: {manifest['firmware']}")
        self.last_manifest.set(f"Manifest: {manifest['manifest']}")
        self.result.delete("1.0", tk.END)
        self.result.insert("1.0", json.dumps(manifest, indent=2))

    def open_output_dir(self) -> None:
        target = Path(self.output_dir.get().strip() or DEFAULT_OUTPUT_DIR).expanduser()
        try:
            target.mkdir(parents=True, exist_ok=True)
            subprocess.Popen(["explorer.exe", str(target)])
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror("Open folder failed", str(exc))


def main() -> None:
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista")
    except tk.TclError:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
