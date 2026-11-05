#!/usr/bin/env bash
# board.sh — the challenge slot board. Regenerates challenges/CATALOG.md
# from challenges/*/entry.md frontmatter; --check verifies the committed
# table is fresh AND every entry is well-formed (fields, enums, needs
# resolving to real slots, landed rows carrying an evidence class).
# Entries are the source of truth — never edit CATALOG.md by hand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python - "$@" <<'PY'
import os, re, sys, glob

ROOT = os.getcwd()
CH = os.path.join(ROOT, 'challenges')
CAT = os.path.join(CH, 'CATALOG.md')

LANES = {'native-zig', 'koru-lift', 'donor-c', 'hosted', 'oracle'}
TIERS = {'qemu', 'hw'}
STATUS = {'open', 'claimed', 'landed', 'waived'}
EVID = {'V', 'M', 'C', 'D', '—', '-'}
REQUIRED = ['name', 'iface', 'arms', 'lane', 'needs', 'accept', 'tier',
            'status', 'evidence']

def parse_entry(path):
    txt = open(path, encoding='utf-8').read()
    m = re.match(r'^---\n(.*?)\n---\n', txt, re.S)
    if not m:
        return None, 'no frontmatter block'
    fm = {}
    for line in m.group(1).split('\n'):
        mm = re.match(r'([a-zA-Z_]+):\s*(.*)$', line)
        if mm:
            fm[mm.group(1)] = mm.group(2).strip()
    return fm, None

entries = {}
errors = []
for d in sorted(glob.glob(os.path.join(CH, '*/'))):
    slot = os.path.basename(os.path.normpath(d))
    ep = os.path.join(d, 'entry.md')
    ap = os.path.join(d, 'accept.sh')
    if not os.path.exists(ep):
        errors.append(f'{slot}: missing entry.md'); continue
    fm, err = parse_entry(ep)
    if err:
        errors.append(f'{slot}: {err}'); continue
    for k in REQUIRED:
        if k not in fm:
            errors.append(f'{slot}: missing frontmatter key "{k}"')
    if fm.get('name') != slot:
        errors.append(f'{slot}: name "{fm.get("name")}" != dir')
    if fm.get('lane') not in LANES:
        errors.append(f'{slot}: bad lane "{fm.get("lane")}"')
    if fm.get('tier') not in TIERS:
        errors.append(f'{slot}: bad tier "{fm.get("tier")}"')
    if fm.get('status') not in STATUS:
        errors.append(f'{slot}: bad status "{fm.get("status")}"')
    if fm.get('status') == 'landed' and fm.get('evidence') not in 'VMCD':
        errors.append(f'{slot}: landed but evidence="{fm.get("evidence")}" (want V/M/C/D)')
    if fm.get('status') != 'landed' and fm.get('evidence') not in ('—', '-'):
        errors.append(f'{slot}: non-landed with evidence="{fm.get("evidence")}"')
    if not os.path.exists(ap):
        errors.append(f'{slot}: missing accept.sh')
    needs = fm.get('needs', '—')
    fm['_needs'] = [] if needs in ('—', '-', '') else \
        [n.strip() for n in needs.strip('[]').split(',') if n.strip()]
    fm['_arms'] = fm.get('arms', '—').strip('[]')
    entries[slot] = fm

for slot, fm in entries.items():
    for n in fm['_needs']:
        if n not in entries:
            errors.append(f'{slot}: needs "{n}" — no such slot')

def render(entries):
    cols = ['slot', 'iface', 'arms', 'lane', 'needs', 'tier', 'status', 'evidence']
    rows = []
    for slot, fm in entries.items():
        st = fm['status']
        rows.append([slot, fm['iface'], fm['_arms'], fm['lane'],
                     fm.get('needs', '—'), fm['tier'],
                     f"**{st}**" if st == 'landed' else st,
                     fm['evidence']])
    w = [max([len(cols[i])] + [len(r[i]) for r in rows])
         for i in range(len(cols))]
    def line(r, ch='│'):
        return ' ' + ch.join(r[i].ljust(w[i]) for i in range(len(cols))) + ' '
    out = []
    out.append(line(cols))
    out.append('─' + '┼'.join('─' * w[i] for i in range(len(cols))) + '─')
    for r in rows:
        out.append(line(r))
    return '\n'.join(out)

table = render(entries)
header = """# Challenge catalog

The slot board — gaps recorded as challenges. Read first; entries are the
source of truth. `scripts/board.sh` regenerates this table from
`challenges/*/entry.md` frontmatter and `--check` verifies freshness.

States: `landed | open | claimed | waived` ·
Lanes: `native-zig | koru-lift | donor-c | hosted | oracle` ·
Tiers: `qemu | hw` · Evidence: `V | M | C | D`

```
""" + table + """
```

`accept.sh` per slot is the minimal runnable probe: landed slots re-run
their evidence; open slots print the falsifiable criteria and exit 77
(skip) until the rung lands.
"""

if '--check' in sys.argv:
    ok = True
    old = open(CAT, encoding='utf-8').read() if os.path.exists(CAT) else ''
    if old != header:
        print('board: CATALOG.md is stale — run scripts/board.sh', file=sys.stderr)
        ok = False
    for e in errors:
        print('board: ' + e, file=sys.stderr); ok = False
    if ok:
        print(f'board: {len(entries)} slots — catalog fresh, all entries valid')
    sys.exit(0 if ok else 1)

for e in errors:
    print('board: ' + e, file=sys.stderr)
open(CAT, 'w', encoding='utf-8').write(header)
print(f'board: CATALOG.md regenerated — {len(entries)} slots' +
      (f' ({len(errors)} problems)' if errors else ''))
sys.exit(1 if errors else 0)
PY
