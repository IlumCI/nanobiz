#!/usr/bin/env python3
"""The 64-symbol character vocabulary of examples/lm/transformer.pk.

    0-25   a-z            (upper case is folded to lower case)
    26     space          (tab and other blanks become spaces)
    27     newline
    28-37  0-9
    38-63  . , ! ? ' " - : ; ( ) [ ] { } + = * / < > ^ _ $ % \\

Any other character becomes a space; runs of spaces are squeezed.

usage:
    text.py encode N [TEXT]    N codes, blank-separated; TEXT (or standard
                               input) is normalised and repeated or cut to N
    text.py normalize          standard input to standard output
    text.py decode [CODES]     codes (argument or standard input) to text
"""
import re
import sys

SYMBOLS = "abcdefghijklmnopqrstuvwxyz \n0123456789" + ".,!?'\"-:;()[]{}+=*/<>^_$%\\"
assert len(SYMBOLS) == 64
CODE = {c: i for i, c in enumerate(SYMBOLS)}


def normalize(text):
    text = text.lower().replace("\r\n", "\n")
    text = "".join(c if c in CODE else " " for c in text)
    text = re.sub(r" +", " ", text)
    text = re.sub(r" *\n *", "\n", text)
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
        sys.stdout.write("".join(SYMBOLS[int(c)] for c in re.split(r"[,\s]+", codes.strip()) if c))
        sys.stdout.write("\n")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
