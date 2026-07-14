#!/usr/bin/env bash
#
# repro.sh — run the three-way matrix on gengtype-lex.l (from GCC 4.6.4):
#
#   1. flex built by upstream tcc, x86_64  -> expected: PASS
#   2. flex built by upstream tcc, riscv64 -> expected: PASS   (under qemu)
#   3. flex built by the Guix bootstrap chain's tcc lineage, riscv64
#      (vendored binary)                   -> expected: FAIL with
#      "flex: fatal internal error, allocation of macro definition failed"
#
# Exit 0 iff every leg behaves as expected — i.e. GREEN CI == BUG REPRODUCED
# and bounded (input is fine, upstream tcc is fine on both arches; the
# regression is in the bootstrap-chain tcc vintage on riscv64).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
B="$PWD/build"
INPUT="${1:-$PWD/gengtype-lex.l}"
MAGIC="allocation of macro definition failed"

# qemu-user for the riscv64 legs: explicit binary, or binfmt_misc direct exec
if command -v qemu-riscv64-static >/dev/null; then QEMU=qemu-riscv64-static
elif command -v qemu-riscv64 >/dev/null; then QEMU=qemu-riscv64
else QEMU=""; fi   # rely on binfmt

run() { # run <label> <expect: pass|fail-magic> <cmd...>
  local label="$1" expect="$2"; shift 2
  local out; out=$(mktemp); local err; err=$(mktemp)
  "$@" "$INPUT" > "$out" 2> "$err"; local rc=$?
  local verdict
  case "$expect" in
    pass) [ $rc -eq 0 ] && verdict=OK || verdict=UNEXPECTED ;;
    fail-magic)
      if [ $rc -ne 0 ] && grep -q "$MAGIC" "$err"; then verdict=OK
      else verdict=UNEXPECTED; fi ;;
  esac
  printf '%-34s expect=%-10s rc=%-3s %s\n' "$label" "$expect" "$rc" "$verdict"
  [ "$verdict" = UNEXPECTED ] && { echo "--- stderr ---"; cat "$err"; FAILED=1; }
  rm -f "$out" "$err"
}

FAILED=0
echo "input: $INPUT"
run "upstream-tcc x86_64"        pass       "$B/bx86/flex" -t
run "upstream-tcc riscv64 (qemu)" pass      $QEMU "$B/brv64/flex" -t
run "chain-tcc riscv64 (qemu)"   fail-magic $QEMU "$PWD/chain-binaries/flex-riscv64-chain" -t

if [ "$FAILED" = 0 ]; then
  echo "MATRIX AS EXPECTED — bug reproduced and bounded."
else
  echo "MATRIX DEVIATED — see above."
fi
exit "$FAILED"
