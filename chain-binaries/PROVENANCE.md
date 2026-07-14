# flex-riscv64-chain

Static riscv64 flex 2.5.39 built inside the riscv64 GNU Guix full-source
bootstrap (`commencement.scm`), i.e. by the chain's tcc-musl lineage
(tcc fork: https://github.com/ekaitz-zarraga/tcc, branch `mob`,
0.9.27-era with the riscv64 backport) against the chain's tcc-built
musl-boot 1.1.24.

* sha256: `e6985dac3507b00fced6d0507b1bdb22689c21bda6fb31d191690f133d9c74f0`
* size: 569632 bytes, statically linked, ELF riscv64 (lp64d)
* Guix store item: `/gnu/store/b46xm98dfqln7jsv1g173yq6hfpny5cn-flex-2.5.39`
* package definition: `flex-boot` in commencement.scm
  (https://codeberg.org/ekaitz-zarraga/commencement.scm) — flex 2.5.39
  release tarball, `CC=tcc CFLAGS=-DHAVE_ALLOCA_H --enable-static
  --disable-shared`, `--system=riscv64-linux` (built under qemu-user
  binfmt on an x86_64 host, qemu 10.0.11)

To rebuild it from the 392-byte hex0 seed (hours under emulation, or on
real RISC-V hardware):

```sh
git clone https://codeberg.org/ekaitz-zarraga/commencement.scm
cd commencement.scm
guix build -L . -e '(@@ (commencement) flex-boot)' \
  --no-grafts --system=riscv64-linux
```
