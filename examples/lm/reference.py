#!/usr/bin/env python3
"""Independent numpy implementation of examples/lm/transformer.pk.

Reproduces the random parameters and sequence of the Plankalkül entry plan
`gradcheck` for a given seed and prints the loss, which must agree with R1
of `gradcheck` to rounding error. It checks the forward pass (embedding,
3 × [RMSNorm, rotary causal attention, RMSNorm, SwiGLU], tied output
layer, cross-entropy), the initialisation and the random number generator
against numpy's own exp/log/sqrt/sin/cos.

usage: reference.py SEED
"""
import sys
import numpy as np

M64 = (1 << 64) - 1
NV, T, D, H, DH, F, L = 96, 32, 64, 4, 16, 134, 3
LS = 2 * D + 4 * D * D + 3 * D * F                     # parameters per layer
NP = NV * D + L * LS + D                               # 132928 parameters
GF = NV * D + L * LS                                   # offset of gf
OFF = dict(g1=0, Wq=D, Wk=D + D * D, Wv=D + 2 * D * D, Wo=D + 3 * D * D,
           g2=D + 4 * D * D, W1=2 * D + 4 * D * D, W3=2 * D + 4 * D * D + D * F,
           W2=2 * D + 4 * D * D + 2 * D * F)


def rng(x):
    x ^= x >> 12
    x ^= (x << 25) & M64
    x ^= x >> 27
    return x, (((x * 2685821657736338717) & M64) >> 11) * 2.0 ** -53


def layer_offset(i):
    return None if not NV * D <= i < GF else (i - NV * D) % LS


def init(seed):
    s = seed ^ 0x9E3779B97F4A7C15 or 1
    p = np.empty(NP)
    for i in range(NP):
        s, u = rng(s)
        std, j = 0.125, layer_offset(i)
        if j is not None and OFF["Wo"] <= j < OFF["g2"]:
            std = 0.051031036307982884                 # Wo
        if j is not None and j >= OFF["W2"]:
            std = 0.03526728079292992                  # W2
        p[i] = (u * 2 - 1) * 1.7320508075688772 * std
        if i >= GF or (j is not None and (j < D or OFF["g2"] <= j < OFF["W1"])):
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
        b = NV * D + l * LS
        n1 = rmsnorm(x, p[b:b + D])
        q = rope(n1 @ block(p, b + OFF["Wq"], D, D))
        k = rope(n1 @ block(p, b + OFF["Wk"], D, D))
        v = n1 @ block(p, b + OFF["Wv"], D, D)
        o = np.zeros((T, D))
        for h in range(H):
            sl = slice(h * DH, (h + 1) * DH)
            s = np.where(mask, q[:, sl] @ k[:, sl].T / np.sqrt(DH), -np.inf)
            a = np.exp(s - s.max(axis=1, keepdims=True))
            o[:, sl] = (a / a.sum(axis=1, keepdims=True)) @ v[:, sl]
        x = x + o @ block(p, b + OFF["Wo"], D, D)
        n2 = rmsnorm(x, p[b + OFF["g2"]:b + OFF["W1"]])
        a1, a3 = n2 @ block(p, b + OFF["W1"], D, F), n2 @ block(p, b + OFF["W3"], D, F)
        x = x + (a1 / (1 + np.exp(-a1)) * a3) @ block(p, b + OFF["W2"], F, D)
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
