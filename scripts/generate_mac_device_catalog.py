#!/usr/bin/env python3
"""Generate slim Resources/MacSpecs.json from AppleDB (+ optional Asahi device list).

Fields are English / language-neutral only (identifier cross-check for MacInspect).

Examples:
  # Sparse-clone AppleDB Mac folders, then:
  python3 scripts/generate_mac_device_catalog.py \\
    --appledb /path/to/appledb \\
    --asahi-md /path/to/device-list.md \\
    --out Resources/MacSpecs.json
"""

from __future__ import annotations

import argparse
import glob
import json
import re
from datetime import date
from pathlib import Path

INCH_RE = re.compile(r"(\d+(?:\.\d+)?)-inch", re.I)
A_RE = re.compile(r"^A\d{4,5}$")
DEVICE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*,\d+$")


def norm_model_no(value) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        for item in value:
            text = str(item).strip()
            if A_RE.match(text):
                return text
        return str(value[0]).strip() if value else ""
    return str(value).strip()


def screen_from_name(name: str) -> str:
    match = INCH_RE.search(name or "")
    return f"{match.group(1)}-inch" if match else ""


def chip_from(device: dict) -> str:
    soc = device.get("soc")
    if isinstance(soc, list):
        return " / ".join(str(x) for x in soc if x)
    if soc:
        return str(soc).strip()
    if device.get("arch") in ("x86-64", "x86_64", "i386"):
        return "Intel"
    return ""


def board_from(device: dict) -> str:
    board = device.get("board")
    if isinstance(board, list):
        for item in board:
            text = str(item).strip()
            if text.upper().endswith("AP"):
                return text
        return str(board[0]).strip() if board else ""
    return str(board).strip() if board else ""


def parse_asahi(path: Path) -> dict[str, dict[str, str]]:
    if not path or not path.exists():
        return {}
    out: dict[str, dict[str, str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.strip("|").split("|")]
        if len(parts) < 4:
            continue
        name, device, product, _soc = parts[0], parts[1], parts[2], parts[3]
        if name.lower().startswith("marketing") or name.startswith("-"):
            continue
        if not DEVICE_RE.match(device):
            continue
        out[device] = {"name": name, "board": product}
    return out


def merge_entry(prev: dict, new: dict) -> dict:
    merged = dict(prev)
    for key, value in new.items():
        if not value:
            continue
        current = merged.get(key) or ""
        if not current:
            merged[key] = value
        elif key == "chip" and current == "Intel" and value != "Intel":
            merged[key] = value
        elif key == "name" and len(value) > len(current):
            merged[key] = value
    return merged


def load_appledb(appledb: Path) -> dict[str, dict]:
    models: dict[str, dict] = {}
    pattern = str(appledb / "deviceFiles" / "**" / "*.json")
    for path in sorted(glob.glob(pattern, recursive=True)):
        with open(path, encoding="utf-8") as handle:
            device = json.load(handle)
        ident = device.get("identifier")
        if not isinstance(ident, str) or not ident:
            continue
        entry = {
            "name": (device.get("name") or "").strip(),
            "model_no": norm_model_no(device.get("model")),
            "chip": chip_from(device),
            "board": board_from(device),
            "screen": screen_from_name(device.get("name") or ""),
            "released": str(device.get("released") or "").strip(),
        }
        models[ident] = entry if ident not in models else merge_entry(models[ident], entry)
    return models


def apply_asahi(models: dict[str, dict], asahi: dict[str, dict[str, str]]) -> tuple[int, int]:
    filled = 0
    added = 0
    for ident, row in asahi.items():
        if ident in models:
            if not models[ident].get("board") and row.get("board"):
                models[ident]["board"] = row["board"]
                filled += 1
            if not models[ident].get("name") and row.get("name"):
                models[ident]["name"] = row["name"]
            continue
        models[ident] = {
            "name": row.get("name") or "",
            "model_no": "",
            "chip": "",
            "board": row.get("board") or "",
            "screen": screen_from_name(row.get("name") or ""),
            "released": "",
        }
        added += 1
    return filled, added


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appledb", type=Path, required=True, help="Path to littlebyteorg/appledb checkout")
    parser.add_argument("--asahi-md", type=Path, default=None, help="Optional Asahi device-list.md")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("Resources/MacSpecs.json"),
        help="Output catalog path",
    )
    args = parser.parse_args()

    models = load_appledb(args.appledb)
    asahi = parse_asahi(args.asahi_md) if args.asahi_md else {}
    board_filled, asahi_only = apply_asahi(models, asahi)

    root = {
        "version": 2,
        "updated": date.today().isoformat(),
        "total": len(models),
        "sources": [
            {
                "name": "AppleDB",
                "url": "https://github.com/littlebyteorg/appledb",
                "license": "MIT",
                "note": "Primary: model identifier, A-number, SoC, board code, English marketing name",
            },
            {
                "name": "Asahi Linux device list",
                "url": "https://asahilinux.org/docs/hw/devices/device-list/",
                "license": "Documentation (project)",
                "note": "Supplementary Apple Silicon board codes (JxxxAP) cross-check / fill",
            },
        ],
        "models": dict(sorted(models.items(), key=lambda item: item[0])),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(root, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(
        f"wrote {args.out} models={len(models)} "
        f"asahi_board_filled={board_filled} asahi_only={asahi_only}"
    )


if __name__ == "__main__":
    main()
