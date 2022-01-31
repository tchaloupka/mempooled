# mempooled

[![Latest version](https://img.shields.io/dub/v/mempooled.svg)](https://code.dlang.org/packages/mempooled)
[![Dub downloads](https://img.shields.io/dub/dt/mempooled.svg)](http://code.dlang.org/packages/mempooled)
[![Actions Status](https://github.com/tchaloupka/mempooled/workflows/ci/badge.svg)](https://github.com/tchaloupka/mempooled/actions)
[![codecov](https://codecov.io/gh/tchaloupka/mempooled/branch/master/graph/badge.svg)](https://codecov.io/gh/tchaloupka/mempooled)
[![license](https://img.shields.io/github/license/tchaloupka/mempooled.svg)](https://github.com/tchaloupka/mempooled/blob/master/LICENSE)

Fast efficient memory pools implementation supporting `@nogc` and `betterC`.

[Docs](https://tchaloupka.github.io/mempooled/mempooled.html)

## FixedPool

Implementation of "Fast Efficient Fixed-Size Memory Pool" as described in [this](http://www.thinkmind.org/download.php?articleid=computation_tools_2012_1_10_80006) article.

It can work as a pool for single templated type or generic pool with a fixed block size (so one can `alloc` various types with size less or equal to the block size - note however that space can be used inefficiently as one pool block can hold only one such item).

Minimal block size is 4B as data in blocks are used internally to form a linked list of the blocks.

### Sample usage

```D
import mempooled.fixed;

struct Foo {}

auto pool = fixedPool!(Foo, 10);
Foo* f = pool.alloc();

// some work

pool.dealloc(f);
f = null;
```

or with a generic pool:

```D
import mempooled.fixed;

struct Foo
{
    int f;
    this(int f) { this.f = f; }
}
struct Bar {}

auto pool = fixedPool!(32, 100);
Foo* f = pool.alloc!Foo(42);
Bar* b = pool.alloc!Bar();
pool.dealloc(f);
pool.dealloc(b);
```

## DynamicPool

Simple implementation of memory blocks pool that are managed using linked list.
Pool allocates blocks of the same size (defined in pool's template parameter).
Whole block is consumed on `alloc`.

### Sample usage

```D
DynamicPool!1024 pool; // each block is 1024B large
auto n = pool.alloc!int(42); // allocates whole 1024B block for just an 4B large number
assert(*n == 42);

auto buf = pool.alloc!(ubyte[1024])(); // uses whole block and zeroes the array
foreach (i; 0..1024) assert((*buf)[i] == 0);

void* vbuf = pool.alloc(1024); // uses whole block that we can use as we please - block memory is uninitialized
assert(vbuf !is null);

// FixedPool over DynamicPool memory block
auto fpblock = cast(ubyte*)pool.alloc(1024);
auto fpool = fixedPool!(8, 128)(fpblock[0..1024]);
auto x = fpool.alloc!int(666);
assert(*x == 666);
fpool.dealloc(x);

// we must deallocate memory blocks in this case
pool.dealloc(n);
pool.dealloc(buf);
pool.dealloc(vbuf);
pool.dealloc(fpblock); // using fpool from this moment would cause problems
```

## How to use the lib

Add it as a dependency to your `dub` project type or just copy the source code to your project.

## Speed comparison

Tested with `dub -b release --compiler=ldc2`

For benchmark source code check `benchmark` subfolder.

```
Alloc
-----
fixedPool: 234 ms, 710 μs, and 5 hnsecs
GC:        831 ms, 890 μs, and 3 hnsecs
malloc:    448 ms, 686 μs, and 7 hnsecs

Dealloc
-------
fixedPool: 46 ms, 6 μs, and 1 hnsec
GC:        40 ms, 240 μs, and 1 hnsec
malloc:    75 ms, 354 μs, and 4 hnsecs
```
