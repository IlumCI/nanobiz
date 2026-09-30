#!/usr/bin/env bash
# Character codes of the demo model: a–z = 0–25, space = 26, '.' = 27.
#   text.sh encode N "text"   N tokens, comma-separated; the text is
#                              lower-cased and repeated or cut to length N
#   text.sh decode "3,1,..."  the text for comma-separated tokens
set -euo pipefail
case "${1:-}" in
  encode)
    printf '%s' "$3" | tr 'A-Z' 'a-z' | awk -v n="$2" '
      { s = s $0 }
      END {
        alpha = "abcdefghijklmnopqrstuvwxyz ."
        m = 0
        for (i = 1; i <= length(s); i++) {
          k = index(alpha, substr(s, i, 1))
          if (k > 0) code[m++] = k - 1
        }
        if (m == 0) { print "text.sh: no encodable characters" > "/dev/stderr"; exit 1 }
        out = ""
        for (i = 0; i < n; i++) out = out (i ? "," : "") code[i % m]
        print out
      }' ;;
  decode)
    printf '%s\n' "$2" | awk -F, '
      { alpha = "abcdefghijklmnopqrstuvwxyz ."
        for (i = 1; i <= NF; i++) printf "%s", substr(alpha, $i + 1, 1)
        printf "\n" }' ;;
  *) echo "usage: text.sh encode N TEXT | decode TOKENS" >&2; exit 2 ;;
esac
