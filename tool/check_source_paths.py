"""Check portable Dart source names in Git checkouts and extracted ZIPs."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
paths = {p.relative_to(root).as_posix() for p in root.rglob('*.dart') if not any(x in {'archive', 'build', '.dart_tool', '.git'} for x in p.relative_to(root).parts)}
try:
    result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, check=True)
    paths.update(p for p in result.stdout.decode().split('\0') if p.endswith('.dart'))
except (OSError, subprocess.CalledProcessError):
    pass  # A downloaded ZIP has no Git metadata.
seen = {}
for path in sorted(paths):
    normalized = path.replace('\\', '/').casefold()
    if normalized in seen and seen[normalized] != path:
        raise SystemExit(f'Conflicting Dart source paths: {seen[normalized]} / {path}')
    seen[normalized] = path
if not (root / 'lib/main.dart').is_file():
    raise SystemExit('Missing canonical lib/main.dart')
print(f'Source paths are unambiguous ({len(paths)} Dart files checked)')
