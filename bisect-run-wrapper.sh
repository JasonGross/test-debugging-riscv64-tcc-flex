#!/usr/bin/env bash
# git-bisect-run wrapper hunting the commit that FIXED the miscompile.
# Terms: --term-old=broken --term-new=fixed
#   oracle exit 0 (probe works)  -> this commit is FIXED  -> wrapper exit 1
#   oracle exit 1 (probe crashes)-> this commit is BROKEN -> wrapper exit 0
#   oracle exit 125              -> skip                  -> wrapper exit 125
"$(dirname "$0")/bisect-oracle.sh"
rc=$?
case $rc in
  0) exit 1 ;;
  125) exit 125 ;;
  *) exit 0 ;;
esac
