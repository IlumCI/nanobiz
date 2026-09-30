#!/usr/bin/env python3
"""Independent numpy implementation of examples/lm/recurrent.pk and
examples/lm/recurrent-small.pk.

Reproduces the parameters and data of the entry plans `gradcheck` and
`cocogradcheck` for a seed and recurrence r and prints the loss, which must
agree with R1 of those plans to rounding error. Checks the recurrent-depth
forward pass (prelude, shared core with input injection, coda) and the
Coconut passes (continuous thoughts fed back as input embeddings).

usage: reference_recurrent.py text|coconut SEED R [small]
"""
import sys
import numpy as np

M64 = (1 << 64) - 1
SMALL = len(sys.argv) > 4 and sys.argv[4] == "small"
NV, T, DH = 98, 32, 16
D, H, F, BLOCKS = (32, 2, 53, 2) if SMALL else (64, 4, 120, 3)   # prelude, core[, coda]
LS = 2 * D + 4 * D * D + 3 * D * F                     # parameters per block
BASE = [NV * D + k * LS for k in range(BLOCKS)]
A_OFF = NV * D + BLOCKS * LS                           # adapter, 2D x D
GF = A_OFF + 2 * D * D                                 # final gain
NP = GF + D                                            # 23712 or 133184
OFF = dict(Wq=D, Wk=D + D * D, Wv=D + 2 * D * D, Wo=D + 3 * D * D, g2=D + 4 * D * D,
           W1=2 * D + 4 * D * D, W3=2 * D + 4 * D * D + D * F, W2=2 * D + 4 * D * D + 2 * D * F)
STD = dict(base=1 / 8, Wo=0.03952847075210474, W2=0.02886751345948129, A=0.08838834764831845)
if SMALL:
    STD = dict(base=0.17677669529663687, Wo=0.0625, W2=0.04856429311786321, A=0.125)


def rng(x):
    x ^= x >> 12
    x ^= (x << 25) & M64
    x ^= x >> 27
    return x, (((x * 2685821657736338717) & M64) >> 11) * 2.0 ** -53


def init(seed):
    s = seed ^ 0x9E3779B97F4A7C15 or 1
    p = np.empty(NP)
    for i in range(NP):
        s, u = rng(s)
        std = STD["base"]
        j = (i - NV * D) % LS if NV * D <= i < A_OFF else None
        if j is not None and OFF["Wo"] <= j < OFF["g2"]:
            std = STD["Wo"]
        if j is not None and j >= OFF["W2"]:
            std = STD["W2"]
        if A_OFF <= i < GF:
            std = STD["A"]
        p[i] = (u * 2 - 1) * 1.7320508075688772 * std
        if i >= GF or (j is not None and (j < D or OFF["g2"] <= j < OFF["W1"])):
            p[i] = 1.0
    return p, s


def mat(p, off, r, c):
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


def block(p, b, x):
    mask = np.tril(np.ones((T, T), dtype=bool))
    n1 = rmsnorm(x, p[b:b + D])
    q, k = rope(n1 @ mat(p, b + OFF["Wq"], D, D)), rope(n1 @ mat(p, b + OFF["Wk"], D, D))
    v = n1 @ mat(p, b + OFF["Wv"], D, D)
    o = np.zeros((T, D))
    for h in range(H):
        sl = slice(h * DH, (h + 1) * DH)
        s = np.where(mask, q[:, sl] @ k[:, sl].T / np.sqrt(DH), -np.inf)
        a = np.exp(s - s.max(axis=1, keepdims=True))
        o[:, sl] = (a / a.sum(axis=1, keepdims=True)) @ v[:, sl]
    x = x + o @ mat(p, b + OFF["Wo"], D, D)
    n2 = rmsnorm(x, p[b + OFF["g2"]:b + OFF["W1"]])
    a1, a3 = n2 @ mat(p, b + OFF["W1"], D, F), n2 @ mat(p, b + OFF["W3"], D, F)
    return x + (a1 / (1 + np.exp(-a1)) * a3) @ mat(p, b + OFF["W2"], F, D)


def forward(p, tokens, r, latent=None):
    """Final-norm states and logits; latent: {position: input vector}."""
    x = mat(p, 0, NV, D)[tokens].copy()
    for pos, vec in (latent or {}).items():
        x[pos] = vec
    e = block(p, BASE[0], x)
    s = np.zeros((T, D))
    for _ in range(r):
        s = block(p, BASE[1], np.concatenate([s, e], axis=1) @ mat(p, A_OFF, 2 * D, D))
    y = block(p, BASE[2], s) if BLOCKS == 3 else s     # the small model has no coda
    nf = rmsnorm(y, p[GF:GF + D])
    return nf, nf @ mat(p, 0, NV, D).T


def xent(lg, seq, mask):
    rows = [t for t in range(T) if mask >> t & 1]
    m = lg.max(axis=1, keepdims=True)
    lse = (m + np.log(np.exp(lg - m).sum(axis=1, keepdims=True)))[:, 0]
    return float(np.mean([lse[t] - lg[t, seq[t + 1]] for t in rows]))


def main():
    mode, seed, r = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    p, s = init(seed)
    for i in range(NP):                                # as in plan randomize
        s, u = rng(s)
        p[i] += 0.2 * (u - 0.5)
    seq = []
    for _ in range(T + 1):
        s, u = rng(s)
        seq.append(int(u * 96.0))
    seq = np.array(seq)
    if mode == "text":
        print(repr(xent(forward(p, seq[:T], r)[1], seq, 0xFFFFFFFF)))
    else:                                              # latents at 10, 11
        latent = {10: np.zeros(D), 11: np.zeros(D)}
        for pos in (10, 11):
            nf, _ = forward(p, seq[:T], r, latent)
            latent[pos] = nf[pos - 1].copy()
        print(repr(xent(forward(p, seq[:T], r, latent)[1], seq, 0xFFFFE000)))


if __name__ == "__main__":
    main()
