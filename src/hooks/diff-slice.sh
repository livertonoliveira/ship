#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: diff-slice.sh <diff-file> --out-dir <dir>" >&2
  echo "  Partitions a unified diff into 3 OWASP-category slices by file path:" >&2
  echo "    slice-injection.md  slice-auth.md  slice-data.md" >&2
  echo "  A file matching no category is copied into all three (conservative fallback)." >&2
}

main() {
  local diff_file="" out_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out-dir) out_dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage; exit 1 ;;
      *)
        if [ -z "$diff_file" ]; then diff_file="$1"; else usage; exit 1; fi
        shift ;;
    esac
  done

  if [ -z "$diff_file" ] || [ -z "$out_dir" ]; then usage; exit 1; fi
  if [ ! -f "$diff_file" ]; then
    echo "diff-slice.sh: diff file not found: $diff_file" >&2
    exit 1
  fi

  mkdir -p "$out_dir"
  local inj="$out_dir/slice-injection.md"
  local auth="$out_dir/slice-auth.md"
  local data="$out_dir/slice-data.md"
  : > "$inj"; : > "$auth"; : > "$data"

  awk -v injfile="$inj" -v authfile="$auth" -v datafile="$data" '
    function matchany(lc, list,   n, arr, i) {
      n = split(list, arr, " ")
      for (i = 1; i <= n; i++) if (index(lc, arr[i])) return 1
      return 0
    }
    function emit(   lc, i, a, u, d) {
      if (block == "") return
      lc = tolower(bpath)
      i = matchany(lc, INJ)
      u = matchany(lc, AUTH)
      d = matchany(lc, DATA)
      if (!i && !u && !d) { i = 1; u = 1; d = 1 }
      if (i) printf "%s", block >> injfile
      if (u) printf "%s", block >> authfile
      if (d) printf "%s", block >> datafile
      block = ""; bpath = ""
    }
    BEGIN {
      INJ = "controller route resolver handler parser validator dto schema query repository repo"
      AUTH = "guard middleware auth session jwt permission role policy cors interceptor"
      DATA = "encrypt crypto log config setting .env cookie header secret hash password"
    }
    /^diff --git / {
      emit()
      bpath = $0
      sub(/^diff --git a\/[^ ]* b\//, "", bpath)
    }
    { block = block $0 "\n" }
    END { emit() }
  ' "$diff_file"

  echo "injection=$inj"
  echo "auth=$auth"
  echo "data=$data"
}

main "$@"
