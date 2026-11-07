"""Reject tracked or working source paths that collide on macOS/Windows."""
from pathlib import Path
import subprocess

tracked = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
sources = [p for p in tracked if p and Path(p).exists()]
sources.extend(str(p) for p in Path("lib").rglob("*.dart"))
by_case = {}
for path in sources:
    existing = by_case.setdefault(path.casefold(), path)
    if existing != path:
        raise SystemExit(f"Conflicting source paths: {existing} / {path}")
if not Path("lib/main.dart").is_file():
    raise SystemExit("Missing canonical lib/main.dart")
print("Source paths are unambiguous")
