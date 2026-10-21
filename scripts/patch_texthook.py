"""Stage architecture-isolated Textractor pipe names without changing vendor DLLs."""
import argparse
import hashlib
from pathlib import Path
import struct

parser = argparse.ArgumentParser()
parser.add_argument("arch", choices=("x86", "x64"))
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
data = args.source.read_bytes()
known = {
    "x86": "8fde589a24ef861c581b61829626d35d6b0fcc958aaaeca620dff630f1ed465b",
    "x64": "43b966f566e1d6362416041bfb55dc4e04aef7bcb8b5aae2da8179c24b2dd58e",
}
if hashlib.sha256(data).hexdigest() != known[args.arch]:
    raise SystemExit("Unknown Textractor DLL: update and verify the pinned release before packaging")
pe = struct.unpack_from("<I", data, 0x3c)[0]
machine = struct.unpack_from("<H", data, pe + 4)[0]
if data[pe:pe+4] != b"PE\0\0" or machine != {"x86": 0x14c, "x64": 0x8664}[args.arch]:
    raise SystemExit("Textractor DLL architecture mismatch")
prefix = "TOUITSU32_" if args.arch == "x86" else "TOUITSU64_"
for suffix in ("_HOOK", "_HOST", "_PIPE_AVAILABLE", "_CONNECTING_PIPES"):
    original = ("TEXTRACTOR" + suffix).encode("utf-16-le")
    replacement = (prefix + suffix).encode("utf-16-le")
    if len(original) != len(replacement) or original not in data:
        raise SystemExit("Unexpected Textractor pipe-name layout: " + suffix)
    data = data.replace(original, replacement)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_bytes(data)
