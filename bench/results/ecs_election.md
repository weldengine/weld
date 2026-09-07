# M1.B / P2-1 — driver election: cost and flip rate

Mode `ReleaseFast`, ⚠ **dev-mode — not opposable** (no `--cold-isolated`).

## Track A — the cost of ONE election, by with-set shape

`ns/election`, median of 5 samples of 20000 elections. Every archetype in
the world carries every table member of the with-set, so this is the
CEILING at that archetype count and not a typical case.

| with-set | A=1 | A=4 | A=16 | A=64 | A=256 | 
|---|---|---|---|---|---|
| 2 sparse | 6 | 5 | 5 | 5 | 5 | 
| 8 sparse | 14 | 14 | 13 | 13 | 11 | 
| 1 table + 1 sparse | 3 | 8 | 43 | 158 | 808 | 
| 1 table + 7 sparse | 10 | 11 | 35 | 137 | 847 | 
| 2 table | 0 | 0 | 0 | 0 | 0 | 
| 8 table | 0 | 0 | 0 | 0 | 0 | 

## Track B — flips per 60 ticks

One term `{table, sparse}`, 1000 table carriers of 4000 entities. The
`preserving` rows are the crossover bench's own churn, which leaves both
populations unchanged; the `moving` and `oscillating` rows are what make
a zero there a statement about the churn.

| churn mode | churn/tick | flips |
|---|---|---|
| preserving | 0 | 0 |
| preserving | 1 | 0 |
| preserving | 10 | 0 |
| preserving | 60 | 0 |
| moving | 1 | 1 |
| moving | 10 | 1 |
| moving | 60 | 1 |
| oscillating | 1 | 59 |

Anti-DCE checksum: 4000304
