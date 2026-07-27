# test-debugging-riscv64-tcc-flex

Reproducer and root-cause analysis for a TinyCC riscv64 **long-double
codegen bug** that broke the riscv64 Guix full-source bootstrap
([ekaitz-zarraga/commencement.scm](https://codeberg.org/ekaitz-zarraga/commencement.scm)).

## TL;DR

> **Correction (2026-07-27):** the analysis below holds for the
> configuration this repository's CI builds (an x86_64-hosted *cross*
> riscv64-tcc). The bootstrap chain's own flex breakage has a different
> root cause and is **not** fixed by re-pinning tcc — see
> [Root cause, corrected](#root-cause-corrected-2026-07-27).

The bug is a **TinyCC riscv64 long-double codegen defect**. The minimal
reproducer is a single long-double constant — no libm, no libc math, no flex
(`longdouble-const.c`):

```c
long double x = 0.30102999566398119521L;   /* log10(2) */
double d = (double) x;                       /* chain-vintage tcc: wrong value */
```

The chain-vintage tcc emits that constant corrupted; upstream mob ≥
[`923fba83`](https://github.com/TinyCC/tinycc/commit/923fba83) emits it
correctly. Everything below is how it surfaced in the wild and how it was
bisected.

## NOT a self-miscompilation

An earlier revision framed this as tcc miscompiling *itself*. **That is
wrong and retracted.** The chain-vintage tcc compiles the TinyCC source into
a working riscv64 tcc that correctly compiles and runs programs — tcc's own
source doesn't exercise the broken long-double-constant path. The defect
only bites code that *uses* long-double constants, which is why it hid until
musl's libm (`log10`, built by that tcc) tripped it.

## Root cause, corrected (2026-07-27)

An earlier revision of this README blamed the chain's broken libm on tcc's
long-double constant emission and recommended re-pinning tcc to mob
[`923fba83`](https://github.com/TinyCC/tinycc/commit/923fba83) or later.
That emission bug is real and `923fba83` fixes it, but it only fires in the
configuration this repository's CI builds — a cross riscv64-tcc on an
x86_64 host, where `init_putv` copies the host's x87 80-bit image into the
16-byte binary128 slot. It is not what breaks the bootstrap chain, and a
re-pin alone would not fix the chain.

The chain's tcc runs natively and its emission path is value-preserving.
The defect is earlier: tcc's `parse_number()` converts decimal FP literals
with the runtime `strtof`/`strtod`/`strtold` of the libc the tcc binary
itself links (as of mob `85ba3ae8`: tccpp.c:2438-2445), and hex-float
literals via runtime `ldexp`. The chain's tcc links GNU Mes' libc, where

1. `strtod`'s backend `abtod` divides the whole fractional digit string by
   10 once, however many digits it has (`"0.25"` parses as 2.5);
2. the digit accumulator `abtol` wraps in a 32-bit `int`;
3. negative decimal exponents are applied one decade short (`"5e-1"` → 5.0);
4. `strtof` and `strtold` alias `strtod`, so all three tcc conversion calls
   funnel into the same broken backend;
5. `ldexp` is a `return 0;` stub, so every hex-float literal parses to 0.0.

Every nontrivial FP constant such a tcc emits is garbage. musl's own
`log10.c` constant `log10_2hi` (`3.01029995663611771306e-01`) parses to
137191264.8, and flex 2.5.39 — which sizes a per-start-condition
allocation with `(int)(1 + log10(i))`, here 137191265 — dies with
`fatal internal error, allocation of macro definition failed`.

Each step is demonstrated by green public CI in
[bootstrap-chain-bug-reproducers](https://github.com/JasonGross/bootstrap-chain-bug-reproducers)
(rows 1, 2, 5, 23; row 23 asserts the exact bits and the 137191265
arithmetic, with a per-run ablation proving the assertions would notice
the bug's absence). The chain fix is an integer-only FP-literal parser in
tccpp.c, with a binary128 path for riscv64:
[`tccpp-integer-fp-literals`](https://github.com/JasonGross/tinycc/tree/tccpp-integer-fp-literals)
(against the chain-pinned mob base `8cd21e91`). In our chain replay (not
CI-checked in this repository) the rebuilt tcc → musl → flex survives
gengtype-lex.l. The sections below on the cross defect and the `923fba83`
bisection remain valid for what this repository's CI demonstrates.

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
garbage** (or segfaults outright: `log10-probe.c`), because that musl was
built by the miscompiling tcc.

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
| `longdouble-const` compiled by **chain-vintage tcc** | **wrong value** (minimal repro) |
| `longdouble-const` compiled by **upstream mob tcc** | correct |
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

1. ~~Re-pin `tcc-boot` in commencement.scm to mob ≥
   [`923fba83`](https://github.com/TinyCC/tinycc/commit/923fba83) (or
   backport that commit), then rebuild `musl-boot0` and everything above
   it.~~ **Superseded — insufficient for the chain; see
   [Root cause, corrected](#root-cause-corrected-2026-07-27).**
2. Until then: nothing in the chain below flex actually consumes the broken
   `log10` — the chain reached GCC 9.5 despite it — but any tcc-era package
   calling libm long-double paths is at risk.

## Reporting

* The underlying tcc bug is **already fixed upstream** (`923fba83`); the
  actionable report is to the bootstrap chain (re-pin), plus optionally a
  regression test offered to tinycc-devel@nongnu.org.

---

*Authorship note: this repository (analysis, reproducers, and
documentation) was researched and written by Claude (Anthropic's Fable 5
model), working on Jason Gross's behalf.*
