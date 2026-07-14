# test-debugging-riscv64-tcc-flex

Reproducer and root-cause analysis for a TinyCC riscv64 **long-double
codegen bug** that broke the riscv64 Guix full-source bootstrap
([ekaitz-zarraga/commencement.scm](https://codeberg.org/ekaitz-zarraga/commencement.scm)).

## Symptom → root cause

The original symptom: flex 2.5.39, built inside the bootstrap chain, dies on
GCC 4.6.4's `gengtype-lex.l`:

```
flex: fatal internal error, allocation of macro definition failed
```

Delta-debugging the input (213 → 12 lines, `minimize.py` / `minimized.l`)
pointed at flex's start-condition handling; reading that call site
(`main.c:456`) shows the allocation size is computed with **`log10(i)`** —
and the crash is the allocation "failing" because **musl's `log10` returns
garbage** (or segfaults outright: `log10-probe.c`).

The libc is the broken artifact, not flex: byte-identical flex objects work
when linked against a gcc-built musl and fail against the chain's tcc-built
musl. The chain's tcc — a snapshot of upstream mob taken 2024-06-01
(byte-identical to
[`8cd21e91`](https://github.com/TinyCC/tinycc/commit/8cd21e91); see
`tcc-chain-vintage/PROVENANCE.md`) — **miscompiles musl's libm on riscv64**:
long-double constants are emitted corrupted.

`git bisect` over upstream mob with `bisect-oracle.sh` (build tcc → build
musl 1.1.24 chain-style → run the log10 probe) identifies the fix:

> [`923fba83`](https://github.com/TinyCC/tinycc/commit/923fba83)
> **"general: long double issues"** (grischka, 2026-05-02) —
> "init_putv(): improve long double cross constants"

So: the bootstrap chain pinned mob inside a ~2-year window where riscv64
long-double constant emission was broken; current mob is fixed.

## The matrix (what CI shows — everything built from source)

| leg | expected |
|---|---|
| `log10-probe` vs musl 1.1.24 built by **chain-vintage tcc** | **crashes** |
| `log10-probe` vs musl 1.1.24 built by **upstream mob tcc** | correct values |
| flex by upstream tcc, x86_64, gcc-musl | passes |
| flex by upstream tcc, riscv64, gcc-musl | passes |
| flex by chain-vintage tcc, riscv64, **gcc-musl** | passes (vintage-compiled flex code is fine) |
| flex by chain-vintage tcc, riscv64, vintage-built musl | informational* |

\* the corrupted-constant defect manifests layout-dependently; the flexfatal
symptom is reliable against the Guix chain's own store-built `musl-boot0`
(rebuildable only via the Guix bootstrap:
`guix build -L . -e '(@@ (commencement) flex-boot)' --system=riscv64-linux`
in a commencement.scm checkout), while locally rebuilt defective libcs may
crash elsewhere or dodge the corruption. The probe legs assert the defect
deterministically.

## Usage

```sh
./setup.sh            # build all legs (needs gcc, riscv64-linux-gnu-gcc, qemu-user)
./repro.sh            # run the matrix; exit 0 iff it looks exactly as above
./minimize.py         # ddmin an input, preserving pass-on-x86 / fail-on-riscv64
# bisect (already done, result above) — reproduce with:
#   cd build/tinycc && export MUSL_TARBALL=$PWD/../musl-1.1.24.tar.gz \
#     PROBE=$PWD/../../log10-probe.c
#   git bisect start --term-old=broken --term-new=fixed
#   git bisect broken 8cd21e91 && git bisect fixed d9d02c5
#   git bisect run ../../bisect-run-wrapper.sh
```

## Notes and caveats

* All riscv64 execution is qemu-user. The defect is **not** an emulator
  artifact: Debian's qemu 7.2 and a locally built qemu 10.0.11 agree on
  every verdict here.
* `tcc-chain-vintage/` is vendored *source* (no binaries in this repo): the
  fork branch the chain pinned no longer exists upstream (rebased away), so
  the content-addressed snapshot is preserved here with provenance.
* `gengtype-lex.l` is from GCC 4.6.4 (GPLv3+; header intact) via the
  chain's [GCC 4.6.4 riscv64 backport](https://github.com/ekaitz-zarraga/gcc).
* An earlier revision of this repo claimed the bug was fork-specific and
  vendored the chain's failing flex binary; both were superseded by the
  analysis above (the pinned tree turned out to be *unmodified upstream mob*
  of 2024-06-01, and everything now builds from source).

## Fix recommendations for the bootstrap chain

1. Re-pin `tcc-boot` in commencement.scm to mob ≥
   [`923fba83`](https://github.com/TinyCC/tinycc/commit/923fba83) (or
   backport that commit), then rebuild `musl-boot0` and everything above it.
2. Until then: nothing in the chain below flex actually consumes the broken
   `log10` — the chain reached GCC 9.5 despite it — but any tcc-era package
   calling libm long-double paths is at risk.

## Reporting

* The underlying tcc bug is **already fixed upstream** (`923fba83`); the
  actionable report is to the bootstrap chain (re-pin), plus optionally a
  regression test offered to tinycc-devel@nongnu.org.
