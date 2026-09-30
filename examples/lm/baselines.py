#!/usr/bin/env python3
"""n-gram baselines for the transformer's validation loss.

Scores exactly the predictions the Plankalkül plan `evaluate` scores: 64
windows of 33 characters starting at 1023·k in the validation text, each
character predicted from the preceding characters of its window only.
The model of order n is an add-0.1 smoothed n-gram estimated on the
training text; near the window start it falls back to the longest context
available. Loss in nats per character.

usage: baselines.py DIR     (DIR as written by data.py)
"""
import math
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import text  # noqa: E402

V, DELTA = 64, 0.1


def main():
    d = sys.argv[1]
    train = [text.CODE[c] for c in open(os.path.join(d, "train.txt")).read()]
    val = [text.CODE[c] for c in open(os.path.join(d, "val.txt")).read()]
    for order in range(1, 7):
        counts = [Counter() for _ in range(order)]    # counts[k]: (k-context, next)
        ctx = [Counter() for _ in range(order)]
        for k in range(order):
            for i in range(k, len(train)):
                h = tuple(train[i - k:i])
                counts[k][h + (train[i],)] += 1
                ctx[k][h] += 1
        total, n = 0.0, 0
        for w in range(64):
            win = val[1023 * w:1023 * w + 33]
            for t in range(32):
                k = min(order - 1, t + 1)
                h = tuple(win[t + 1 - k:t + 1])
                p = (counts[k][h + (win[t + 1],)] + DELTA) / (ctx[k][h] + DELTA * V)
                total -= math.log(p)
                n += 1
        print("%d-gram: %.4f nats/char" % (order, total / n))


if __name__ == "__main__":
    main()
