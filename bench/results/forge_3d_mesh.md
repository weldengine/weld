# forge_3d mesh bench (M1.1.11.1)

Scalar `Real` = `f32`, optimize = `ReleaseFast`.

| triangles | build (median) | raycast | hits | `worldAabb` | cached box | `overlapAabb` |
|---|---|---|---|---|---|---|
| 1000 | 0.752 ms | 1685.0 ns | 127/2000 | 9580.0 ns | 34.5 ns | 49.5 ns |
| 4000 | 2.067 ms | 2274.0 ns | 438/2000 | 21981.0 ns | 20.0 ns | 24.5 ns |
| 16000 | 6.537 ms | 2708.0 ns | 807/2000 | 71355.5 ns | 13.0 ns | 18.5 ns |

`worldAabb` is the O(V) pass over the mesh's transported vertices; `cached box` is
the same value read from a variable, i.e. the floor a per-body cache could reach.
The difference between the two columns IS the cost of the decision taken at gate A,
and `overlapAabb` is the query it sits inside.
