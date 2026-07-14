#!/usr/bin/env python3
"""minimize.py — delta-debug gengtype-lex.l down to a minimal trigger.

Invariant preserved at every step (the classic ddmin oracle, two-sided):
  * flex built by upstream tcc for x86_64 SUCCEEDS on the candidate, AND
  * the bootstrap-chain riscv64 flex FAILS on it with
    "allocation of macro definition failed" (run under qemu-user).

Run ./setup.sh first. Output: minimized.l (plus progress on stderr).

Line-granularity ddmin (Zeller) iterated to a fixpoint, then a cheap
char-level trim pass on each surviving line.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
X86_FLEX = os.path.join(HERE, "build", "bx86", "flex")
CHAIN_FLEX = os.path.join(HERE, "chain-binaries", "flex-riscv64-chain")
MAGIC = b"allocation of macro definition failed"
QEMU = shutil.which("qemu-riscv64-static") or shutil.which("qemu-riscv64")

oracle_calls = 0


def run(cmd, lfile):
    try:
        return subprocess.run(
            cmd + ["-t", lfile],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        return None


def interesting(text):
    """True iff x86 passes AND chain riscv64 fails with the magic error."""
    global oracle_calls
    oracle_calls += 1
    with tempfile.NamedTemporaryFile(
        "w", suffix=".l", dir=HERE, delete=False
    ) as f:
        f.write(text)
        lfile = f.name
    try:
        ok = run([X86_FLEX], lfile)
        if ok is None or ok.returncode != 0:
            return False
        chain_cmd = ([QEMU] if QEMU else []) + [CHAIN_FLEX]
        bad = run(chain_cmd, lfile)
        return bad is not None and bad.returncode != 0 and MAGIC in bad.stderr
    finally:
        os.unlink(lfile)


def ddmin_lines(lines):
    n = 2
    while len(lines) >= 2:
        chunk = max(1, len(lines) // n)
        reduced = False
        i = 0
        while i < len(lines):
            candidate = lines[:i] + lines[i + chunk:]
            if candidate and interesting("\n".join(candidate) + "\n"):
                lines = candidate
                reduced = True
                # keep i (next chunk shifted into place)
            else:
                i += chunk
        if reduced:
            n = max(n - 1, 2)
        elif n >= len(lines):
            break
        else:
            n = min(n * 2, len(lines))
        print(f"  ddmin: {len(lines)} lines, granularity {n}, "
              f"{oracle_calls} oracle calls", file=sys.stderr)
    return lines


def trim_line_chars(lines):
    """Char-level pass: try truncating each line from the right."""
    for i, line in enumerate(lines):
        lo, hi = 0, len(line)
        # binary-search the shortest right-truncation that stays interesting
        while lo < hi:
            mid = (lo + hi) // 2
            cand = lines[:i] + [line[:mid]] + lines[i + 1:]
            if interesting("\n".join(cand) + "\n"):
                hi = mid
            else:
                lo = mid + 1
        if hi < len(line):
            lines[i] = line[:hi]
    return [l for l in lines if l.strip() or True]


def main():
    src = os.path.join(HERE, sys.argv[1] if len(sys.argv) > 1
                       else "gengtype-lex.l")
    text = open(src).read()
    if not interesting(text):
        sys.exit("original input does not satisfy the oracle — "
                 "run ./setup.sh and check ./repro.sh first")
    lines = text.splitlines()
    print(f"start: {len(lines)} lines", file=sys.stderr)
    prev = None
    while prev != lines:
        prev = list(lines)
        lines = ddmin_lines(lines)
    lines = trim_line_chars(lines)
    # final sanity
    out = "\n".join(lines) + "\n"
    assert interesting(out)
    dest = os.path.join(HERE, "minimized.l")
    open(dest, "w").write(out)
    print(f"done: {len(lines)} lines, {oracle_calls} oracle calls "
          f"-> {dest}", file=sys.stderr)


if __name__ == "__main__":
    main()
