#!/usr/bin/env bash
#
# setup.sh — build every leg of the test matrix FROM SOURCE (no binaries
# are committed to this repo):
#
#   * upstream TinyCC (mob, pinned) as native x86_64 + cross riscv64 compiler
#   * the CHAIN-VINTAGE TinyCC (vendored source snapshot in tcc-chain-vintage/:
#     the exact tree the Guix riscv64 full-source bootstrap pinned; it is
#     byte-identical to upstream mob commit 8cd21e91, and the fork branch it
#     was fetched from has since been rewritten — see
#     tcc-chain-vintage/PROVENANCE.md)
#   * musl sysroots:
#       - musl 1.2.5 built by gcc for both arches (control libc)
#       - musl 1.1.24 built "chain-style" by the vintage riscv64-tcc
#         -> THE DEFECTIVE LIBC (long-double constants miscompiled)
#       - musl 1.1.24 chain-style by upstream-mob riscv64-tcc -> control
#   * flex 2.5.39 compiled by tcc in four combinations (see repro.sh)
#
# "Chain-style" = how the Guix riscv64 bootstrap builds its first musl:
# soft-float defines (dodges fenv.S, which tcc's assembler can't parse),
# src/complex removed, tcc -ar as archiver.
#
# Requirements: gcc, riscv64-linux-gnu-gcc (+ binutils), make, git, curl.
# Everything lands in ./build.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
B="$PWD/build"
mkdir -p "$B"

TCC_REPO=https://github.com/TinyCC/tinycc
TCC_COMMIT=d9d02c56401e43be43760b63f7d82f771a7ed1f6   # mob, 2026-07-14
MUSL125_URL=https://musl.libc.org/releases/musl-1.2.5.tar.gz
MUSL125_SHA256=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
MUSL1124_URL=https://musl.libc.org/releases/musl-1.1.24.tar.gz
MUSL1124_SHA256=1370c9a812b2cf2a7d92802510cca0058cc37e66a7bedd70051f0a34015022a3
# (2.5.39 predates flex's GitHub-release era; SourceForge is canonical)
FLEX_URL=https://downloads.sourceforge.net/project/flex/flex-2.5.39.tar.gz
FLEX_SHA256=71dd1b58158c935027104c830c019e48c73250708af5def45ea256c789318948

msg() { printf '\033[1m:: %s\033[0m\n' "$*" >&2; }

fetch() { # fetch <url> <sha256> <dest>
  [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet 2>/dev/null && return 0
  curl -fL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet
}

# ---- upstream tcc (native + cross riscv64) ------------------------------------
if [ ! -x "$B/tcc-prefix/bin/riscv64-tcc" ]; then
  msg "building upstream tcc @ ${TCC_COMMIT:0:12} (native + cross)"
  rm -rf "$B/tinycc"
  git clone -q "$TCC_REPO" "$B/tinycc"
  git -C "$B/tinycc" checkout -q "$TCC_COMMIT"
  ( cd "$B/tinycc" && ./configure --prefix="$B/tcc-prefix" --enable-cross \
      > configure.log 2>&1 && make -j"$(nproc)" > make.log 2>&1 \
      && make install > install.log 2>&1 )
fi
TP="$B/tcc-prefix"

# ---- chain-vintage tcc (vendored source; plain configure) ---------------------
if [ ! -x "$B/tcc-vintage/riscv64-tcc" ]; then
  msg "building chain-vintage tcc (vendored source)"
  rm -rf "$B/tcc-vintage"
  cp -r tcc-chain-vintage "$B/tcc-vintage"
  chmod -R u+w "$B/tcc-vintage"
  ( cd "$B/tcc-vintage" && ./configure > conf.log 2>&1 \
      && make riscv64-tcc -j"$(nproc)" > mk.log 2>&1 \
      && make riscv64-libtcc1.a >> mk.log 2>&1 )
fi
VIN="$B/tcc-vintage"

# ---- gcc-built musl 1.2.5 sysroots (control libc, both arches) ----------------
fetch "$MUSL125_URL" "$MUSL125_SHA256" "$B/musl-1.2.5.tar.gz"
[ -d "$B/musl-1.2.5" ] || tar -C "$B" -xf "$B/musl-1.2.5.tar.gz"
if [ ! -f "$B/sysroot-x86_64/lib/crt1.o" ]; then
  msg "building musl 1.2.5 sysroot (x86_64, gcc)"
  ( cd "$B/musl-1.2.5" && make distclean >/dev/null 2>&1 || true
    ./configure CC=gcc --prefix="$B/sysroot-x86_64" --disable-shared \
      > conf-x86.log 2>&1 && make -j"$(nproc)" > make-x86.log 2>&1 \
      && make install > inst-x86.log 2>&1 )
fi
if [ ! -f "$B/sysroot-riscv64/lib/crt1.o" ]; then
  msg "building musl 1.2.5 sysroot (riscv64, riscv64-linux-gnu-gcc)"
  ( cd "$B/musl-1.2.5" && make distclean >/dev/null 2>&1 || true
    ./configure --target=riscv64-linux-gnu CC=riscv64-linux-gnu-gcc \
      AR=riscv64-linux-gnu-ar RANLIB=riscv64-linux-gnu-ranlib \
      --prefix="$B/sysroot-riscv64" --disable-shared \
      > conf-rv.log 2>&1 && make -j"$(nproc)" > make-rv.log 2>&1 \
      && make install > inst-rv.log 2>&1 )
fi

# ---- chain-style musl 1.1.24: defective (vintage tcc) + control (mob tcc) -----
fetch "$MUSL1124_URL" "$MUSL1124_SHA256" "$B/musl-1.1.24.tar.gz"
build_chain_musl() { # build_chain_musl <dirname> <cc-string> <prefix>
  local d="$B/$1" TCC="$2" prefix="$3"
  [ -f "$prefix/lib/crt1.o" ] && return 0
  msg "building musl 1.1.24 chain-style: $1"
  rm -rf "$d" && mkdir -p "$d"
  tar -C "$d" --strip-components=1 -xf "$B/musl-1.1.24.tar.gz"
  local FLAGS="-DSYSCALL_NO_TLS -D__riscv_float_abi_soft -U__riscv_flen"
  ( cd "$d" && rm -rf src/complex
    sed -i 's/^EMPTY_LIB_NAMES = /EMPTY_LIB_NAMES = g /' Makefile
    ./configure --target=riscv64 CC="$TCC" --prefix="$prefix" \
      --disable-shared --disable-gcc-wrapper > conf.log 2>&1
    make -j"$(nproc)" CC="$TCC" AR="$TCC -ar" RANLIB=true CFLAGS="$FLAGS" \
      > make.log 2>&1
    make install CC="$TCC" AR="$TCC -ar" RANLIB=true CFLAGS="$FLAGS" \
      > inst.log 2>&1 )
}
build_chain_musl m-vintage "$VIN/riscv64-tcc -B$VIN"     "$B/sys-chain-vintage"
build_chain_musl m-mob     "$TP/bin/riscv64-tcc"         "$B/sys-chain-mob"

# ---- flex 2.5.39 ---------------------------------------------------------------
fetch "$FLEX_URL" "$FLEX_SHA256" "$B/flex-2.5.39.tar.gz"
if [ ! -d "$B/flex-2.5.39" ]; then
  tar -C "$B" -xf "$B/flex-2.5.39.tar.gz"
  # 2013-era config.sub predates musl triplets and riscv64
  for f in config.sub config.guess; do
    if [ -f "/usr/share/misc/$f" ]; then cp "/usr/share/misc/$f" "$B/flex-2.5.39/$f"
    else curl -fL --retry 3 -o "$B/flex-2.5.39/$f" \
      "https://git.savannah.gnu.org/cgit/config.git/plain/$f"; fi
  done
fi

# build_flex <dirname> <host-triplet> <cc-with-flags> <sysroot> <libtcc1> [cflags]
# tcc as CC compiles every object; the final link is done by hand because
# libtool drops -static and reorders archives (tcc is a single-pass linker,
# hence the libc.a / libtcc1.a / libc.a sandwich).
build_flex() {
  local d="$B/$1" host="$2" cc="$3" sys="$4" libtcc1="$5" xcflags="${6:-}"
  [ -x "$d/flex" ] && return 0
  msg "building flex: $1"
  mkdir -p "$d"
  ( cd "$d"
    ../flex-2.5.39/configure --host="$host" \
      CC="$cc -static -nostdinc -I$sys/include" \
      ${xcflags:+CFLAGS="$xcflags"} \
      LDFLAGS="-nostdlib $sys/lib/crt1.o $sys/lib/crti.o" \
      LIBS="$sys/lib/libc.a $libtcc1 $sys/lib/libc.a $sys/lib/crtn.o" \
      > conf.log 2>&1
    make -C lib > lib.log 2>&1
    make flex -j"$(nproc)" > make.log 2>&1 || true  # link fails under libtool
    $cc -static -nostdlib "$sys/lib/crt1.o" "$sys/lib/crti.o" *.o \
      lib/.libs/libcompat.a "$sys/lib/libc.a" "$libtcc1" "$sys/lib/libc.a" \
      "$sys/lib/crtn.o" -o flex )
}

build_flex bx86 x86_64-linux-musl \
  "$TP/bin/tcc -I$TP/lib/tcc/include" \
  "$B/sysroot-x86_64" "$TP/lib/tcc/x86_64-libtcc1.a"
build_flex brv64 riscv64-linux-musl \
  "$TP/bin/riscv64-tcc -I$TP/lib/tcc/include" \
  "$B/sysroot-riscv64" "$TP/lib/tcc/riscv64-libtcc1.a"
build_flex brv64-vintage-gccmusl riscv64-linux-musl \
  "$VIN/riscv64-tcc -B$VIN -I$VIN/include" \
  "$B/sysroot-riscv64" "$VIN/riscv64-libtcc1.a" "-DHAVE_ALLOCA_H"
build_flex brv64-vintage-chainmusl riscv64-linux-musl \
  "$VIN/riscv64-tcc -B$VIN -I$VIN/include" \
  "$B/sys-chain-vintage" "$VIN/riscv64-libtcc1.a" "-DHAVE_ALLOCA_H"

msg "setup complete"
