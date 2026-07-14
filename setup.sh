#!/usr/bin/env bash
#
# setup.sh — build the from-source half of the test matrix:
#   upstream TinyCC (mob, pinned) as native x86_64 + cross riscv64 compiler,
#   musl 1.2.5 sysroots for both arches (gcc-built, so libc quality is held
#   constant), and flex 2.5.39 compiled BY tcc for both arches.
#
# The third matrix column — the bootstrap-chain-built riscv64 flex that
# actually exhibits the bug — is vendored in chain-binaries/ (it cannot be
# rebuilt outside a GNU Guix commencement.scm bootstrap; see PROVENANCE.md).
#
# Requirements: gcc, riscv64-linux-gnu-gcc (+ binutils), make, git, curl.
# Everything lands in ./build.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
B="$PWD/build"
mkdir -p "$B"

TCC_REPO=https://github.com/TinyCC/tinycc
TCC_COMMIT=d9d02c56401e43be43760b63f7d82f771a7ed1f6   # mob, 2026-07-14
MUSL_URL=https://musl.libc.org/releases/musl-1.2.5.tar.gz
MUSL_SHA256=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
# (2.5.39 predates flex's GitHub-release era; SourceForge is canonical)
FLEX_URL=https://downloads.sourceforge.net/project/flex/flex-2.5.39.tar.gz
FLEX_SHA256=71dd1b58158c935027104c830c019e48c73250708af5def45ea256c789318948

msg() { printf '\033[1m:: %s\033[0m\n' "$*" >&2; }

fetch() { # fetch <url> <sha256> <dest>
  [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet 2>/dev/null && return 0
  curl -fL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet
}

# ---- upstream tcc (native + all cross backends) ------------------------------
if [ ! -x "$B/tcc-prefix/bin/riscv64-tcc" ]; then
  msg "building upstream tcc @ ${TCC_COMMIT:0:12} (native + cross)"
  rm -rf "$B/tinycc"
  git clone -q "$TCC_REPO" "$B/tinycc"
  git -C "$B/tinycc" checkout -q "$TCC_COMMIT"
  ( cd "$B/tinycc" && ./configure --prefix="$B/tcc-prefix" --enable-cross \
      > configure.log 2>&1 && make -j"$(nproc)" > make.log 2>&1 \
      && make install > install.log 2>&1 )
fi

# ---- musl sysroots (gcc-built on both arches: libc held constant) ------------
fetch "$MUSL_URL" "$MUSL_SHA256" "$B/musl-1.2.5.tar.gz"
[ -d "$B/musl-1.2.5" ] || tar -C "$B" -xf "$B/musl-1.2.5.tar.gz"
if [ ! -f "$B/sysroot-x86_64/lib/crt1.o" ]; then
  msg "building musl sysroot (x86_64, gcc)"
  ( cd "$B/musl-1.2.5" && make distclean >/dev/null 2>&1 || true
    ./configure CC=gcc --prefix="$B/sysroot-x86_64" --disable-shared \
      > conf-x86.log 2>&1 && make -j"$(nproc)" > make-x86.log 2>&1 \
      && make install > inst-x86.log 2>&1 )
fi
if [ ! -f "$B/sysroot-riscv64/lib/crt1.o" ]; then
  msg "building musl sysroot (riscv64, riscv64-linux-gnu-gcc)"
  ( cd "$B/musl-1.2.5" && make distclean >/dev/null 2>&1 || true
    ./configure --target=riscv64-linux-gnu CC=riscv64-linux-gnu-gcc \
      AR=riscv64-linux-gnu-ar RANLIB=riscv64-linux-gnu-ranlib \
      --prefix="$B/sysroot-riscv64" --disable-shared \
      > conf-rv.log 2>&1 && make -j"$(nproc)" > make-rv.log 2>&1 \
      && make install > inst-rv.log 2>&1 )
fi

# ---- flex 2.5.39, compiled by upstream tcc ------------------------------------
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

# build_flex <dirname> <tcc> <sysroot> <libtcc1>
# tcc as CC compiles every object; the final link is done by hand because
# libtool drops -static and reorders archives (tcc is a single-pass linker,
# hence the libc.a / libtcc1.a / libc.a sandwich).
build_flex() {
  local d="$B/$1" cc="$2" sys="$3" libtcc1="$4"
  [ -x "$d/flex" ] && return 0
  msg "building flex with $(basename "$cc") against $(basename "$sys")"
  mkdir -p "$d"
  ( cd "$d"
    ../flex-2.5.39/configure --host="$(basename "$sys" | sed s/sysroot-//)-linux-musl" \
      CC="$cc -static -nostdinc -I$sys/include -I$B/tcc-prefix/lib/tcc/include" \
      LDFLAGS="-nostdlib $sys/lib/crt1.o $sys/lib/crti.o" \
      LIBS="$sys/lib/libc.a $libtcc1 $sys/lib/libc.a $sys/lib/crtn.o" \
      > conf.log 2>&1
    make -C lib > lib.log 2>&1
    make flex -j"$(nproc)" > make.log 2>&1 || true   # link step fails under libtool
    "$cc" -nostdlib "$sys/lib/crt1.o" "$sys/lib/crti.o" *.o lib/.libs/libcompat.a \
      "$sys/lib/libc.a" "$libtcc1" "$sys/lib/libc.a" "$sys/lib/crtn.o" -o flex )
}

build_flex bx86  "$B/tcc-prefix/bin/tcc"         "$B/sysroot-x86_64"  "$B/tcc-prefix/lib/tcc/x86_64-libtcc1.a"
build_flex brv64 "$B/tcc-prefix/bin/riscv64-tcc" "$B/sysroot-riscv64" "$B/tcc-prefix/lib/tcc/riscv64-libtcc1.a"

msg "setup complete: build/bx86/flex (x86_64), build/brv64/flex (riscv64)"
