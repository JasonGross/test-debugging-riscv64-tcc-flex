#!/usr/bin/env bash
# bisect-oracle.sh — git-bisect oracle for the tcc-riscv64 musl-log10 miscompile.
#
# Run from within a tinycc checkout (any commit). Builds riscv64-tcc + its
# libtcc1 at that commit, builds musl 1.1.24 the bootstrap-chain way
# (soft-float defines, no complex/, tcc -ar), compiles the log10 probe and
# runs it under qemu-user.
#
# Exit 0  = GOOD (probe prints 4 correct lines)
# Exit 1  = BAD  (probe crashes or prints wrong values)
# Exit 125 = SKIP (this tcc commit cannot complete the build)
#
# Env: MUSL_TARBALL (path to musl-1.1.24.tar.gz), PROBE (path to log10 probe .c)
set -uo pipefail
HERE="$(pwd)"
: "${MUSL_TARBALL:?}" "${PROBE:?}"
QEMU=$(command -v qemu-riscv64-static || command -v qemu-riscv64 || true)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

say() { printf 'oracle[%s]: %s\n' "$(git rev-parse --short HEAD)" "$*" >&2; }

# ---- tcc at this commit -------------------------------------------------------
# git clean, not just distclean: stale cross libtcc1 archives from a previous
# checkout otherwise survive and get linked, making verdicts order-dependent.
git clean -fdxq > /dev/null 2>&1
./configure > "$W/conf.log" 2>&1 || { say "configure failed"; exit 125; }
make riscv64-tcc -j"$(nproc)" > "$W/tcc.log" 2>&1 || { say "tcc build failed"; exit 125; }
# libtcc1 target spelling changed over mob history — try both
make riscv64-libtcc1.a > "$W/lib.log" 2>&1 || \
  make libtcc1-riscv64.a >> "$W/lib.log" 2>&1 || { say "libtcc1 failed"; exit 125; }
LIBTCC1=$(ls "$HERE"/riscv64-libtcc1.a "$HERE"/libtcc1-riscv64.a 2>/dev/null | head -1)
[ -n "$LIBTCC1" ] || { say "no libtcc1"; exit 125; }
TCC="$HERE/riscv64-tcc -B$HERE"

# ---- musl 1.1.24, chain-style -------------------------------------------------
mkdir -p "$W/musl" && tar -C "$W/musl" --strip-components=1 -xf "$MUSL_TARBALL"
cd "$W/musl" || exit 125
rm -rf src/complex
sed -i 's/^EMPTY_LIB_NAMES = /EMPTY_LIB_NAMES = g /' Makefile
./configure --target=riscv64 CC="$TCC" --prefix="$W/sys" --disable-shared \
  --disable-gcc-wrapper > conf.log 2>&1 || { say "musl configure failed"; exit 125; }
CHAINFLAGS="-DSYSCALL_NO_TLS -D__riscv_float_abi_soft -U__riscv_flen"
make -j"$(nproc)" CC="$TCC" AR="$TCC -ar" RANLIB=true CFLAGS="$CHAINFLAGS" \
  > make.log 2>&1 || { say "musl build failed"; exit 125; }
make install CC="$TCC" AR="$TCC -ar" RANLIB=true CFLAGS="$CHAINFLAGS" \
  > inst.log 2>&1 || { say "musl install failed"; exit 125; }
S="$W/sys"

# ---- probe --------------------------------------------------------------------
cd "$HERE" || exit 125
$TCC -static -nostdinc -I"$S/include" -I"$HERE/include" -nostdlib \
  "$S/lib/crt1.o" "$S/lib/crti.o" "$PROBE" "$S/lib/libc.a" "$LIBTCC1" \
  "$S/lib/libc.a" "$S/lib/crtn.o" -o "$W/probe" > "$W/link.log" 2>&1 \
  || { say "probe link failed"; exit 125; }
OUT=$(timeout 20 $QEMU "$W/probe" 2>&1); RC=$?
say "probe rc=$RC out: $(echo "$OUT" | head -1)"
[ $RC -eq 0 ] && echo "$OUT" | grep -q "log10(2) = 0.301030" && exit 0
exit 1
