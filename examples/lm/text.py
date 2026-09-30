#!/usr/bin/env python3
"""The character vocabulary of examples/lm/transformer.pk (96 symbols) and
examples/lm/recurrent.pk (98 symbols).

    0      newline
    1-95   the printable ASCII characters, space (32) to '~' (126)
    96     <bot>  begin of continuous thought   (recurrent.pk only)
    97     <eot>  end of continuous thought     (recurrent.pk only)

Decoding shows code 98, which recurrent.pk outputs for a latent position,
as <thought>.

Normalisation: Unicode is decomposed (NFKD) and accents dropped; typographic
quotes, dashes and ellipses become their ASCII forms; tabs become 4 spaces;
any other character becomes a space; runs of more than two newlines are
shortened to two. Case and spacing are kept, so code survives unchanged.

usage:
    text.py encode N [TEXT]    N codes, blank-separated; TEXT (or standard
                               input) is normalised and repeated or cut to N
    text.py normalize          standard input to standard output
    text.py decode [CODES]     codes (argument or standard input) to text
"""
import re
import sys
import unicodedata

SYMBOLS = "\n" + "".join(chr(c) for c in range(32, 127))
assert len(SYMBOLS) == 96
CODE = {c: i for i, c in enumerate(SYMBOLS)}
BOT, EOT, LATENT = 96, 97, 98
NAMES = {BOT: "<bot>", EOT: "<eot>", LATENT: "<thought>"}
REPLACE = {"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-",
           "—": "-", "…": "...", "×": "*", "÷": "/", "−": "-",
           "≤": "<=", "≥": ">=", "≠": "!=", "\t": "    ", " ": " "}


def normalize(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = "".join(REPLACE.get(c, c) for c in text)
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = "".join(c if c in CODE else " " for c in text)
    return re.sub(r"\n{3,}", "\n\n", text)


def encode(text, n):
    codes = [CODE[c] for c in normalize(text)]
    if not codes:
        sys.exit("text.py: no encodable characters")
    return [codes[i % len(codes)] for i in range(n)]


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "encode":
        text = sys.argv[3] if len(sys.argv) > 3 else sys.stdin.read()
        print(" ".join(map(str, encode(text, int(sys.argv[2])))))
    elif cmd == "normalize":
        sys.stdout.write(normalize(sys.stdin.read()))
    elif cmd == "decode":
        codes = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()
        sys.stdout.write("".join(NAMES.get(int(c)) or SYMBOLS[int(c)]
                                 for c in re.split(r"[,\s]+", codes.strip()) if c))
        sys.stdout.write("\n")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
