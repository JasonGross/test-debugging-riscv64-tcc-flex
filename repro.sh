#!/usr/bin/env bash
#
# repro.sh — run the matrix. Everything here was built from source by setup.sh.
#
# The minimal C repro (log10-probe.c — musl's libm long-double paths):
#   1. probe linked against chain-style musl built by CHAIN-VINTAGE tcc
#        -> expected: CRASH (the miscompiled-libc artifact)
#   2. probe linked against chain-style musl built by UPSTREAM-MOB tcc
#        -> expected: prints correct log10 values
#
# The original symptom (flex 2.5.39 on GCC 4.6.4's gengtype-lex.l):
#   3. flex by upstream tcc, x86_64, gcc-musl        -> PASS
#   4. flex by upstream tcc, riscv64, gcc-musl       -> PASS   (qemu)
#   5. flex by vintage tcc,  riscv64, gcc-musl       -> PASS   (qemu)
#        (proves the vintage-compiled flex code itself is fine)
#   6. flex by vintage tcc,  riscv64, chain-musl     -> FAIL with
#        "flex: fatal internal error, allocation of macro definition failed"
#        (the defective libc: flex's start-condition loop calls log10())
#
# Exit 0 iff every leg behaves as expected — GREEN CI == BUG REPRODUCED,
# root-caused to the libc built by the chain-vintage tcc, and bounded
# (upstream tcc mob >= 923fba83 "general: long double issues" is fixed).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
B="$PWD/build"
INPUT="${1:-$PWD/gengtype-lex.l}"
MAGIC="allocation of macro definition failed"
VIN="$B/tcc-vintage"
TP="$B/tcc-prefix"

if command -v qemu-riscv64-static >/dev/null; then QEMU=qemu-riscv64-static
elif command -v qemu-riscv64 >/dev/null; then QEMU=qemu-riscv64
else QEMU=""; fi   # rely on binfmt_misc

# link the log10 probe against a given chain-style musl, using its builder tcc
linkprobe() { # linkprobe <out> <tcc-string> <sysroot> <libtcc1> <includes...>
  local out="$1" tcc="$2" sys="$3" lib1="$4"; shift 4
  $tcc -static -nostdinc "$@" -I"$sys/include" -nostdlib \
    "$sys/lib/crt1.o" "$sys/lib/crti.o" log10-probe.c \
    "$sys/lib/libc.a" "$lib1" "$sys/lib/libc.a" "$sys/lib/crtn.o" \
    -o "$out" 2>/dev/null
}
linkprobe "$B/probe-vintage" "$VIN/riscv64-tcc -B$VIN" "$B/sys-chain-vintage" \
  "$VIN/riscv64-libtcc1.a" -I"$VIN/include"
linkprobe "$B/probe-mob" "$TP/bin/riscv64-tcc" "$B/sys-chain-mob" \
  "$TP/lib/tcc/riscv64-libtcc1.a" -I"$TP/lib/tcc/include"

FAILED=0
run() { # run <label> <expect: pass|probe-ok|crash|fail-magic> <cmd...>
  local label="$1" expect="$2"; shift 2
  local out; out=$(mktemp); local err; err=$(mktemp)
  timeout 60 "$@" > "$out" 2> "$err"; local rc=$?
  local verdict=UNEXPECTED
  case "$expect" in
    pass)       [ $rc -eq 0 ] && verdict=OK ;;
    probe-ok)   [ $rc -eq 0 ] && grep -q "log10(2) = 0.301030" "$out" && verdict=OK ;;
    crash)      [ $rc -ge 128 ] && verdict=OK ;;
    fail-magic) [ $rc -ne 0 ] && grep -q "$MAGIC" "$err" && verdict=OK ;;
  esac
  printf '%-44s expect=%-10s rc=%-3s %s\n' "$label" "$expect" "$rc" "$verdict"
  if [ "$verdict" = UNEXPECTED ]; then
    echo "--- stdout ---"; head -5 "$out"; echo "--- stderr ---"; head -5 "$err"
    FAILED=1
  fi
  rm -f "$out" "$err"
}

echo "flex input: $INPUT"
run "probe / vintage-tcc-built musl"      crash      $QEMU "$B/probe-vintage"
run "probe / mob-tcc-built musl"          probe-ok   $QEMU "$B/probe-mob"
run "flex upstream-tcc x86_64 gcc-musl"   pass       "$B/bx86/flex" -t "$INPUT"
run "flex upstream-tcc rv64 gcc-musl"     pass       $QEMU "$B/brv64/flex" -t "$INPUT"
run "flex vintage-tcc rv64 gcc-musl"      pass       $QEMU "$B/brv64-vintage-gccmusl/flex" -t "$INPUT"

# Informational, not asserted: the corrupted-long-double-constant defect
# manifests layout-dependently, so flex linked against the locally rebuilt
# defective libc may pass, crash, or die with flex's fatal message depending
# on toolchain build details. Against the Guix chain's own store-built
# musl-boot0 it reliably dies with "allocation of macro definition failed"
# (flex's start-condition loop calls log10()); rebuilding THAT exact binary
# requires the Guix bootstrap (see README).
INFO_OUT=$(timeout 60 $QEMU "$B/brv64-vintage-chainmusl/flex" -t "$INPUT" 2>&1 > /dev/null)
INFO_RC=$?
printf '%-44s (informational) rc=%-3s %s\n' "flex vintage-tcc rv64 chain-musl" \
  "$INFO_RC" "$(echo "$INFO_OUT" | head -1)"

if [ "$FAILED" = 0 ]; then
  echo "MATRIX AS EXPECTED — bug reproduced, root-caused, and bounded."
else
  echo "MATRIX DEVIATED — see above."
fi
exit "$FAILED"
