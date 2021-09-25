# mempooled

[![Latest version](https://img.shields.io/dub/v/mempooled.svg)](https://code.dlang.org/packages/mempooled)
[![Dub downloads](https://img.shields.io/dub/dt/mempooled.svg)](http://code.dlang.org/packages/mempooled)
[![Actions Status](https://github.com/tchaloupka/mempooled/workflows/ci/badge.svg)](https://github.com/tchaloupka/mempooled/actions)
[![codecov](https://codecov.io/gh/tchaloupka/mempooled/branch/master/graph/badge.svg)](https://codecov.io/gh/tchaloupka/mempooled)
[![license](https://img.shields.io/github/license/tchaloupka/mempooled.svg)](https://github.com/tchaloupka/mempooled/blob/master/LICENSE)

Fast efficient memory pools implementation supporting `@nogc` and `betterC`.

**Note:** Currently only `fixedpool` is implemented.

[Docs](https://tchaloupka.github.io/mempooled/mempooled.html)

## fixedpool

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
