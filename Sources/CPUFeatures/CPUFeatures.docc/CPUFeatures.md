# ``CPUFeatures``

What the CPU can do, from CPUID through glibc, without reading `/proc`.

## Overview

``CPU`` asks glibc's x86 feature table (`__x86_get_cpuid_feature_leaf`), which already accounts for what the kernel
enabled, such as AVX-512's register state. Off x86-64 Linux every answer is `false`, so callers fall back to portable
code.

## Topics

### Features

- ``CPU/hasSHA``
- ``CPU/hasPCLMULQDQ``
- ``CPU/hasVPCLMULQDQ512``
- ``CPU/usable(leaf:register:bit:)``
