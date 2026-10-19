#!/usr/bin/env python3
"""M5a checks. Usage: check.py <serial.log> <run dir with exp-*.txt> <refused-by-design.txt>"""
import re, sys, os
log = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
d = sys.argv[2]
rbd = {l.split("\t")[0] for l in open(sys.argv[3]) if l.strip() and not l.startswith("#")}
refusal = re.compile(r"koru-os: (ENOSYS|STUBBED) |Unsupported resource \d+|Ignore updating resource \d+")
clean = [l for l in log if not refusal.search(l)]
def section(n):
    """Output lines after the bare marker line M5-Tn, up to the next prompt."""
    try: i = clean.index("M5-T%d" % n)
    except ValueError: return None
    out = []
    for l in clean[i + 1:]:
        if l.startswith("~ # ") or l.startswith("koru-os: init exited"): break
        if l.strip(): out.append(l)
    return out
exp = lambda f: open(os.path.join(d, f)).read().split("\n")[:-1]
res, ok = [], True
def chk(name, cond, detail=""):
    global ok
    res.append(("PASS" if cond else "FAIL") + " " + name + (": " + str(detail) if detail != "" else ""))
    ok = ok and bool(cond)
s1 = section(1); chk("(m1) musl hello argc=3, rc=42", s1 is not None and any(l.startswith("M5 hello from /bin/hello-musl, argc=3") for l in s1) and "rc=42" in s1, s1)
s2 = section(2); chk("(m2) glibc hello argc=2, rc=42", s2 is not None and any(l.startswith("M5 hello from /bin/hello-glibc, argc=2") for l in s2) and "rc=42" in s2, s2)
s3 = section(3); got = sorted(w for l in (s3 or []) for w in l.split()); chk("(m3) GNU ls / equals host listing", s3 is not None and got == sorted(exp("exp-ls.txt")), got)
cnt = exp("exp-count.txt")[0]
s4 = section(4); chk("(m4) GNU ls / | GNU wc -l = %s" % cnt, s4 == [cnt], s4)
s5 = section(5); chk("(m5) dynamic busybox ls / | wc -l = %s" % cnt, s5 is not None and [l.strip() for l in s5] == [cnt], s5)
s6 = section(6); chk("(m6) GNU sha256sum equals host", s6 == ["%s  /etc/m5-data" % exp("exp-sha.txt")[0]], s6)
s7 = section(7); chk("(m7) GNU sort | head -3 equals host", s7 == exp("exp-sort3.txt"), s7)
chk("(m8) exit 5 seen as init exit status 5", "koru-os: init exited with status 5" in log)
text = "\n".join(log)
rows = re.findall(r"koru-os: (ENOSYS|STUBBED) (\S+)", text)
names = [(n if k == "ENOSYS" else "STUBBED " + n.rstrip("()")) for k, n in rows]
# posix-process prlimit64 refusals: -EINVAL for unknown resources, silent success for ignored updates
names += ["prlimit64 resource " + r for r in re.findall(r"Unsupported resource (\d+)", text)]
names += ["prlimit64 ignored update " + r for r in re.findall(r"Ignore updating resource (\d+)", text)]
rows = names
names = sorted(set(names))
bad = [n for n in names if n not in rbd]
chk("(d) refusal log classified", not bad, "%d rows, names %s%s" % (len(rows), names, "; unclassified " + str(bad) if bad else ""))
chk("(x) no Unikraft Crash", not any("Unikraft Crash" in l for l in log))
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL")); sys.exit(0 if ok else 1)
