# Measuring

## Build microbenchmarks the way you ship

SwiftPM's release build compiles each module whole (`-wmo`). A microbenchmark built file by file, or with plain
`swiftc -O` on separate files, can inline differently and land on different code. In one case a JSON reader looked
70–185 ns slower per call in a non-WMO build, and turned out faster once built whole-module: 490 ns against 800–1,000
for an article body.

```sh
swiftc -O -wmo -enforce-exclusivity=unchecked -module-name bench Bench.swift Code.swift -o bench
```

## Read what the compiler made

Count the calls a hot function makes. Anything into the runtime is suspect.

```sh
objdump -d --no-show-raw-insn .build/release/App > d.txt
awk '/^[0-9a-f]+ <.*>:$/ { p = index($0, "writeString") > 0 } p' d.txt \
  | grep -oE 'call\s+[0-9a-f]+ <[^>]+>' | sort | uniq -c | sort -rn
```

What turned up this way:

- `Array.append(contentsOf:)`: generic and not inlined, called once per JSON field.
- `swift_isUniquelyReferenced_nonNull_native`: each `[UInt8]` mutation checks the buffer is unique.
- `swift_once`: a file-scope `let` read inside a loop.
- A sort's comparison closure: called once per comparison, not inlined.

## Profile per thread, on the CPU that matters

Local numbers on an Apple-silicon laptop swung ±30% between runs, too much to see a 3% change. On x86 GitHub runners,
two things gave stable answers:

- CPU per request split by thread kind (reactors, read lanes, write lanes, bcrypt workers), from each thread's
  `/proc/<pid>/task/<tid>/stat` before and after a window.
- `perf report --sort comm,dso,symbol`, summed per kind of thread. That turned "the reactors cost 1.8 µs more than the
  reference" into "1.05 µs of it is SHA-256, 0.34 µs base64".

Run each build twice in the same job, and compare only within a job: runners differ (AMD Zen 3, Zen 4, Zen 5 and
Intel all turned up), and the difference between them is often bigger than the change being measured.

## Count allocations

An `LD_PRELOAD` shim that counts `malloc`, `calloc` and `realloc` per caller, over a window of the load, shows what
allocates per request. One server went from 7.8 allocations per request to 3.4; another ended at 0.72, all of them
inside SQLite's writes.

## Compare with the code that actually runs

A library's portable reference is often not what runs. ISA-L's `isal_deflate_body_base` (C) is not what runs on
x86: that is `isal_deflate_body_04`, AVX2 assembly that handles two positions per step. Its AVX-512 code is only in
the CRC. Porting the C reference got within 1.45×; porting what the assembly does got level. See the
[gzip case](case-gzip.md).

## The test that matters

Optimizations here touched sorting, hashing and JSON escaping, so the last check was byte-for-byte: hundreds of
responses from the old and new builds on copies of the same database, compared exactly.

## Loopback hides part of the cost

On a runner, client and server share the kernel: the receiving side of each packet is processed on the sender's CPU,
and kernel work was about 75% of the server's samples. Percentages then shrink real differences (a 1 µs gap in user
space read as "3–8%"). Compare absolute time per request, per function, for each build, and count packets per
request by direction (iptables counters on the port) before blaming the network.

## Tails show only at saturation

A checkpoint that holds writes for up to a second didn't show at 60–80% CPU on a runner's fast disk. At 100% it set
p99: 456 ms with a 1 s cap on the hold, 251 ms with 250 ms. Run the comparison at the load where the real test fails.

## One run on the target machine can't resolve small changes

The $12 box scored each build once. A follow-up that was 0.2–0.5 µs per request cheaper on runners held 240,000 users
against the original's 300,000, and a second follow-up, with Swift's checks turned back on, held the same 240,000 that
day. Two opposite changes landing on one number is the box's day, not the code: the original's p99 had already been
942 ms against a 1 s limit, so a slightly worse day turns a pass into a fail. Decide changes of a few percent before
the box, in repeated rounds within one job, and take the box's number as one sample.

## CPU per request depends on how busy the server is

Ubuntu 24.04's kernel (6.8) is built without `CONFIG_IRQ_TIME_ACCOUNTING`, so the kernel's receive work (softirq) is
charged to whatever task is running when it runs. A server that leaves the CPU idle more often has more of that work
charged to the idle task; a busier one has it charged to itself. In a KVM guest shaped like the $12 box, the same
server measured 20.8 µs per request in its own cgroup at 270,000 users (30% idle) and 22.0–22.3 µs at 300,000 (18%
idle). User time stayed at 4.5–4.6 µs; the rest was kernel time. A busy guest also takes each interrupt as an exit to
the hypervisor, where an idle one is only woken by it.

So a server's CPU per request, measured at its own limit, mixes its code with how close to the limit it ran. Compare
servers at the same idle share, or by the whole machine's busy time per request.

## Hyper-V hides what KVM shows

GitHub's runners (Azure) and WSL2 both run on Hyper-V, and costs that showed only on the $12 box, a KVM guest, didn't
show on either. A KVM guest on a desktop did show them: QEMU inside WSL2 (nested virtualization; `/dev/kvm` is there),
Ubuntu's cloud image with its 6.8 kernel, 1 vCPU and 2 GB, `virtio-net` on a tap device moved into the load
generator's network namespace. It needed two settings. The guest's receive ring at 1,024 entries (`rx_queue_size`)
and the tap's queue at 10,000 packets: the defaults, 256 and 1,000, dropped the load generator's bursts, and p99 went
to seconds with the guest 70% idle. And the vCPU thread pinned to a core of its own, with QEMU's other threads on
another (vhost's worker included, which on recent kernels is a thread of QEMU's). On the host, `perf kvm stat` counts
the exits by reason; it prints its report to stderr. Nested, an exit costs more than on the real box (a device
notification about 16 µs), which exaggerates exactly the costs the guest is there to find.

## Read the other implementation first

When another implementation is faster, read all of it, build scripts included, before profiling. Here the profiles
pointed at "user space, spread thin"; the source showed the differences directly: how the C library was compiled, a
commit from the wrong connection, a per-entry loop the other side did a page at a time.
