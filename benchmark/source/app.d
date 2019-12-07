module app;

import mempooled.fixed;

import std.datetime.stopwatch;
import std.stdio;

struct Foo
{
    long[4] f;
    ~this() nothrow @nogc {}
}

static assert(Foo.sizeof == 32);
enum NUM_ALLOC = 10_000_000;

void main()
{
    alias PFoo = Foo*;
    PFoo[][] pf;
    pf = new PFoo[][3];
    foreach (i; 0..3) pf[i] = new PFoo[NUM_ALLOC];

    auto pool = fixedPool!(Foo, NUM_ALLOC)();

    auto res = benchmark!(
        {
            auto p = pool;
            foreach (i; 0..NUM_ALLOC)
            {
                pf[0][i] = p.alloc();
            }
        },
        {
            foreach (i; 0..NUM_ALLOC)
            {
                pf[1][i] = cast(Foo*)(new Foo());
            }
        },
        {
            import core.stdc.stdlib : malloc;
            import std.conv : emplace;
            foreach (i; 0..NUM_ALLOC)
            {
                pf[2][i] = (cast(Foo*)malloc(Foo.sizeof)).emplace;
            }
        },
    )(1);

    writeln("Alloc");
    writeln("-----");
    writeln("fixedPool: ", res[0]);
    writeln("GC:        ", res[1]);
    writeln("malloc:    ", res[2]);

    res = benchmark!(
        {
            auto p = pool;
            foreach (i; 0..NUM_ALLOC)
            {
                p.dealloc(pf[0][i]);
            }
        },
        {
            foreach (i; 0..NUM_ALLOC)
            {
                destroy(*pf[1][i]);
            }
        },
        {
            import core.stdc.stdlib : free;
            foreach (i; 0..NUM_ALLOC)
            {
                free(pf[2][i]);
            }
        },
    )(1);

    writeln();
    writeln("Dealloc");
    writeln("-------");
    writeln("fixedPool: ", res[0]);
    writeln("GC:        ", res[1]);
    writeln("malloc:    ", res[2]);
}
