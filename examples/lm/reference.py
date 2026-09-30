#!/usr/bin/env python3
"""Independent numpy implementation of examples/lm/transformer.pk.

Reproduces the random parameters and sequence of the Plankalkül entry plan
`gradcheck` for a given seed and prints the loss, which must agree with R1
of `gradcheck` to rounding error. It checks the forward pass (embedding,
2 × [RMSNorm, rotary causal attention, RMSNorm, SwiGLU], tied output
layer, cross-entropy), the initialisation and the random number generator
against numpy's own exp/log/sqrt/sin/cos.

usage: reference.py SEED
"""
import sys
import numpy as np

M64 = (1 << 64) - 1
NV, T, D, H, DH, F, L = 64, 32, 32, 2, 16, 64, 2
NP = NV * D + L * 10304 + D                            # 22688 parameters
GF = NV * D + L * 10304                                # offset of gf


def rng(x):
    x ^= x >> 12
    x ^= (x << 25) & M64
    x ^= x >> 27
    return x, (((x * 2685821657736338717) & M64) >> 11) * 2.0 ** -53


def layer_offset(i):
    return None if not NV * D <= i < GF else (i - NV * D) % 10304


def init(seed):
    s = seed ^ 0x9E3779B97F4A7C15 or 1
    p = np.empty(NP)
    for i in range(NP):
        s, u = rng(s)
        std, j = 0.1767766952966369, layer_offset(i)
        if j is not None and 3104 <= j < 4128:
            std = 0.08838834764831845                  # Wo
        if j is not None and j >= 8256:
            std = 0.0625                               # W2
        p[i] = (u * 2 - 1) * 1.7320508075688772 * std
        if i >= GF or (j is not None and (j < 32 or 4128 <= j < 4160)):
            p[i] = 1.0
    return p, s


def block(p, off, r, c):
    return p[off:off + r * c].reshape(r, c)


def rmsnorm(x, g):
    return x / np.sqrt((x * x).mean(axis=1, keepdims=True) + 1e-5) * g


def rope(x):
    ang = np.arange(T)[:, None] * 10000.0 ** (-np.arange(DH // 2) / (DH // 2))
    c, s = np.cos(ang), np.sin(ang)
    y = x.copy()
    for h in range(H):
        e = h * DH + 2 * np.arange(DH // 2)
        y[:, e] = x[:, e] * c - x[:, e + 1] * s
        y[:, e + 1] = x[:, e] * s + x[:, e + 1] * c
    return y


def loss(p, seq):
    E = block(p, 0, NV, D)
    x = E[seq[:T]]
    mask = np.tril(np.ones((T, T), dtype=bool))
    for l in range(L):
        b = NV * D + l * 10304
        n1 = rmsnorm(x, p[b:b + 32])
        q = rope(n1 @ block(p, b + 32, D, D))
        k = rope(n1 @ block(p, b + 1056, D, D))
        v = n1 @ block(p, b + 2080, D, D)
        o = np.zeros((T, D))
        for h in range(H):
            sl = slice(h * DH, (h + 1) * DH)
            s = np.where(mask, q[:, sl] @ k[:, sl].T / np.sqrt(DH), -np.inf)
            a = np.exp(s - s.max(axis=1, keepdims=True))
            o[:, sl] = (a / a.sum(axis=1, keepdims=True)) @ v[:, sl]
        x = x + o @ block(p, b + 3104, D, D)
        n2 = rmsnorm(x, p[b + 4128:b + 4160])
        a1, a3 = n2 @ block(p, b + 4160, D, F), n2 @ block(p, b + 6208, D, F)
        x = x + (a1 / (1 + np.exp(-a1)) * a3) @ block(p, b + 8256, F, D)
    lg = rmsnorm(x, p[GF:GF + D]) @ E.T
    m = lg.max(axis=1, keepdims=True)
    lse = (m + np.log(np.exp(lg - m).sum(axis=1, keepdims=True)))[:, 0]
    return float(np.mean(lse - lg[np.arange(T), seq[1:]]))


def main():
    p, s = init(int(sys.argv[1]))
    for i in range(NP):                                # as in plan gradcheck
        s, u = rng(s)
        p[i] += 0.2 * (u - 0.5)
    seq = []
    for _ in range(T + 1):
        s, u = rng(s)
        seq.append(int(u * NV))
    print(repr(loss(p, np.array(seq))))


if __name__ == "__main__":
    main()
