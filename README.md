# test-debugging-riscv64-tcc-flex

Reproducer for a **runtime failure of tcc-compiled flex 2.5.39 on riscv64**,
found while working on the riscv64 Guix full-source bootstrap
([ekaitz-zarraga/commencement.scm](https://codeberg.org/ekaitz-zarraga/commencement.scm)):
a flex built by the bootstrap chain's tcc lineage builds fine but dies at
runtime on GCC 4.6.4's `gengtype-lex.l`:

```
flex: fatal internal error, allocation of macro definition failed
```

That error is raised in flex's m4-define buffer machinery (`buf.c` /
`filter.c`, present since flex 2.5.31), pointing at varargs-flavored
codegen; notably, the chain tcc's riscv64 target implements `va_list` as a
bare `char *` walked by header macros (`include/stdarg.h` in
[ekaitz-zarraga/tcc](https://github.com/ekaitz-zarraga/tcc)), rather than
the ABI-native scheme upstream tcc has since grown.

## The matrix (what CI shows)

| leg | compiler | arch | result on `gengtype-lex.l` |
|---|---|---|---|
| 1 | upstream tcc ([mob @ `d9d02c5`](https://github.com/TinyCC/tinycc)) | x86_64 | **passes** |
| 2 | upstream tcc (same) | riscv64 (qemu-user) | **passes** |
| 3 | bootstrap-chain tcc lineage (vendored binary) | riscv64 (qemu-user) | **fails** with the error above |

Legs 1–2 are built from source by `setup.sh` (pinned upstream tcc as
native + cross compiler, gcc-built musl 1.2.5 sysroots on both arches so
libc quality is held constant, flex 2.5.39 compiled by tcc). Leg 3 is a
vendored static binary — it comes out of a GNU Guix bootstrap chain and
cannot be casually rebuilt; see
[`chain-binaries/PROVENANCE.md`](chain-binaries/PROVENANCE.md).

**Green CI = the bug reproduced and is bounded**: the input is valid, flex
2.5.39-compiled-by-tcc works on both arches with *current upstream* tcc —
the failure is specific to the bootstrap chain's tcc vintage on riscv64
(and is evidently absent/fixed upstream, which makes a bisect of the fork
against mob attractive).

Interesting extra data point: the failure is *input-dependent*. Trivial
`.l` files, `%x` start conditions, and `gengtype-lex.l`'s exact `%option`
combination all pass through the failing binary; the full file crashes it.
Hence the minimizer — whose result ([`minimized.l`](minimized.l), 12 lines
from 213 in 191 oracle calls) points at a **trailing-context rule**
(`^{HWS}typedef/{EOID}` — the `/` lookahead operator) combined with a name
definition and a start condition as the load-bearing ingredients.

## Usage

```sh
./setup.sh      # build legs 1-2 (needs gcc, riscv64-linux-gnu-gcc, qemu-user)
./repro.sh      # run the matrix, exit 0 iff it looks exactly as above
./minimize.py   # ddmin gengtype-lex.l -> minimized.l, preserving
                #   x86-tcc-flex PASSES && chain-riscv64-flex FAILS
```

## Caveats

* All riscv64 execution here is **qemu-user** (10.x locally, distro
  qemu-user-static in CI), not silicon. The gcc-built and
  upstream-tcc-built riscv64 flex binaries passing under the same qemu is
  strong evidence the emulator is not the culprit, but a confirmation on
  real RISC-V hardware would be welcome.
* `gengtype-lex.l` is from GCC 4.6.4 (GPLv3+; header kept intact), via
  [ekaitz-zarraga/gcc](https://github.com/ekaitz-zarraga/gcc) (the RISC-V
  backport of GCC 4.6.4 used by the bootstrap chain).

## Where this is being reported

* tcc: `tinycc-devel@nongnu.org` (upstream), and the bootstrap-chain
  angle to Ekaitz Zarraga alongside commencement.scm work.
* flex is *not* suspected (gcc-built flex 2.5.39 handles the same input
  everywhere); if root-causing ever shows flex-side UB, cross-file to
  westes/flex.
