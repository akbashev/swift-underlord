# Case: gzip at ISA-L level 0's speed, in Swift

A server sending ~3.7 KB JSON feeds gzipped them with its own Swift deflate: greedy matching, then Huffman codes built
for each body. Compared on an x86 runner, one pinned core, 300 real feeds:

| | time per feed | output |
|---|---|---|
| Swift, codes built per body | 14.0 µs | 840 B |
| ISA-L 2.31.1, level 0 | 3.4 µs | 1,146 B |
| libdeflate, level 1 | 11.5 µs | 819 B |
| zlib, level 1 | 20.8 µs | 851 B |

The Swift version compressed 27% better than ISA-L's level 0 and cost four times as much. The extra compression
bought nothing: either size, plus the response head, fits one TCP segment.

## Steps

1. **ISA-L's default Huffman table, in one pass.** ISA-L's level 0 doesn't build codes per body: it ships a dynamic
   block header (886 bits) with a generic table. Decoding that header once gives the code lengths, and each literal or
   match can be written as it is found. Building the codes had been a third of the time. 14 → 4.6 µs.
2. **CRC-32 on PCLMULQDQ.** Folding 16-byte lanes with the carry-less multiply instead of eight-bytes-per-step tables.
3. **ISA-L's level-0 loop, from its portable C:** a branch-free 64-bit bit writer (store eight bytes every write,
   advance by whole bytes), a match's length and distance in one write, a 16-bit hash table, the next positions
   hashed after a match. On AMD Zen 3: 4.57 µs against ISA-L's 4.5.
4. **What x86 actually runs.** ISA-L's x86 loop is AVX2 assembly that handles two positions per step: both hashed and
   looked up, 8 bytes at each compared with one XOR (4–7 equal bytes give the length directly), a literal and a
   match or two literals in one write. Its CRC folds 128 bytes per step, or 256 with AVX-512's VPCLMULQDQ. Ported:
   3.3 µs against ISA-L's 3.4 on AMD Zen 4, output 1,140 bytes against 1,146.

## What it shows

- Compare with the code that runs on the target, not the reference version.
- A better compression ratio is only worth something if it changes what goes on the wire.
- Every output was checked by decompressing it: CRC, length and bytes.
