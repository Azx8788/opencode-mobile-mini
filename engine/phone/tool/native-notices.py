#!/usr/bin/env python3
"""Collect exact locked Android dependency notices from Cargo's local sources."""
import os
import pathlib
import re
import subprocess
import sys
import tomllib

repo = pathlib.Path(__file__).resolve().parents[3]
output = pathlib.Path(sys.argv[1])
targets = sys.argv[2:] or ['aarch64-linux-android', 'x86_64-linux-android']
if any(target not in {'aarch64-linux-android', 'x86_64-linux-android'} for target in targets):
    raise SystemExit('Unsupported Android notice target')
# Union the exact target trees: architecture-specific dependencies must not be omitted.
tree = '\n'.join(subprocess.check_output([
    'cargo', 'tree', '--manifest-path', str(repo / 'engine/phone/Cargo.toml'),
    '--locked', '--offline', '--target', target,
    '--edges', 'normal', '--prefix', 'none', '--format', '{p}',
], text=True) for target in targets)
registry = pathlib.Path(os.environ.get('CARGO_HOME', pathlib.Path.home() / '.cargo')) / 'registry/src'
sections = ['Phone engine Android dependency notices\n'
            'Generated from the union of locked Android target normal dependency trees; build-time macro dependencies may also appear.\n']
for name, version in sorted(set(re.findall(r'^([\w-]+) v([^\s]+)', tree, re.M))):
    if name == 'oc-phone-engine':
        continue
    candidates = list(registry.glob(f'*/{name}-{version}'))
    if len(candidates) != 1:
        raise SystemExit(f'Exact package source unavailable: {name} {version}')
    crate = candidates[0]
    package = tomllib.loads((crate / 'Cargo.toml').read_text())['package']
    texts = sorted(p for p in crate.iterdir() if p.is_file() and
                   re.match(r'(?i)^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE)([.-]|$)', p.name))
    if not texts:
        raise SystemExit(f'License text unavailable: {name} {version}')
    sections.append(f'\n==== {name} {version} ({package.get("license", "license-file")}) ====\n')
    for text in texts:
        sections.append(f'\n-- {text.name} --\n' + text.read_text())
    if name == 'libgit2-sys':
        sections.append('\n-- Bundled libgit2 COPYING, including linking exception and vendored notices --\n' +
                        (crate / 'libgit2/COPYING').read_text())
    if name == 'libsqlite3-sys':
        sections.append('\n-- Bundled SQLite public-domain dedication (sqlite3.h header) --\n' +
                        (crate / 'sqlite3/sqlite3.h').read_text().split('*/', 1)[0] + '*/\n')
sysroot = pathlib.Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip())
standard = sysroot / 'share/doc/rust/COPYRIGHT-library.html'
if not standard.is_file():
    raise SystemExit('Rust standard-library copyright notice unavailable')
sections.append('\n==== Rust standard library ====\n' + standard.read_text())
output.parent.mkdir(parents=True, exist_ok=True)
# Normalize trailing whitespace in the aggregate; license words stay intact.
output.write_text('\n'.join(line.rstrip() for line in '\n'.join(sections).splitlines()) + '\n')
print(f'Native dependency notices: {output.name}')
