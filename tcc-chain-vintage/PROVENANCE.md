# tcc-chain-vintage — provenance

This directory is a verbatim, unmodified snapshot of the TinyCC source tree
that the riscv64 GNU Guix full-source bootstrap
([ekaitz-zarraga/commencement.scm](https://codeberg.org/ekaitz-zarraga/commencement.scm))
pins as `tcc-boot`:

* Guix origin: `git-fetch` of https://github.com/ekaitz-zarraga/tcc,
  `(commit "mob")`, recursive, sha256
  `05slgpsavjd76pnkhghik3skmmic8d1py1b3jvcklcvkh1jv3s8i` (nix-base32)
* Obtained from the content-addressed Guix store checkout
  (`/gnu/store/7wvp06m3cgnd29x04b3nixky0p8va4zw-git-checkout`).

It is vendored here because **the branch it was fetched from no longer
exists**: `ekaitz-zarraga/tcc` has since been rebased (its default branch is
now `riscv-mes`), so the pinned commit is unreachable upstream. The tree is
pure source (GPL/LGPL, see COPYING/RELICENSING) — no binaries.

Identification: the tree is **byte-identical to upstream TinyCC mob commit
[`8cd21e91`](https://github.com/TinyCC/tinycc/commit/8cd21e91) ("Address of
solved for riscv64", 2024-06-01)** — i.e. the bootstrap chain pinned plain
upstream mob of that date, carrying no fork-specific patches. That places
the pin *inside* the window of the long-double codegen defect that upstream
later fixed in
[`923fba83`](https://github.com/TinyCC/tinycc/commit/923fba83)
("general: long double issues", 2026-05-02).
