module mempooled.fixed;

debug import core.stdc.stdio;
import core.memory : pureMalloc, pureCalloc, pureFree;
import core.lifetime : emplace, forward;
import mempooled.intrinsics;

nothrow @nogc:

/**
 * Create instance of `FixedPool`
 *
 * Params:
 *      T = type of the pooled item
 *      blockSize = size of one block in a pool
 *      size = number of items
 *      buffer = optional buffer to initiate `FixedPool` over
 */
auto fixedPool(T, size_t size)(ubyte[] buffer = null)
{
    auto res = FixedPool!(T.sizeof, size, T)();
    res.initPool(buffer);
    return res;
}

/// ditto
auto fixedPool(size_t blockSize, size_t numBlocks)(ubyte[] buffer = null)
{
    auto res = FixedPool!(blockSize, numBlocks, void)();
    res.initPool(buffer);
    return res;
}

/**
 * Implementation of "Fast Efficient Fixed-Size Memory Pool" as described in
 * [this](www.thinkmind.org/download.php?articleid=computation_tools_2012_1_10_80006) article.
 *
 * It can work as a pool for single templated type or generic pool with a fixed block size (so one
 * can `alloc` various types with size less or equal to the block size).
 *
 * Minimal block size is 4B as data in blocks are used internally to form a linked list of the blocks.
 *
 * Internally it uses refcounted payload so can be copied around as needed.
 *
 * Params:
 *      blockSize = size of one item block in a pool
 *      numBlock = number of blocks in a pool
 *      T = optional forced type of pooled items - if used, pool is forced to provide items of this type only
 *
 * See_Also: implementation here: https://github.com/green-anger/MemoryPool
 */
struct FixedPool(size_t blockSize, size_t numBlocks, T = void)
{
    nothrow @nogc:

    static assert(blockSize >= 4, "blockSize must be equal or greater than uint.sizeof");
    static if (!is(T == void))
    {
        static assert(T.sizeof <= blockSize, "Blocksize must be greater or equal to T.sizeof");
    }

    private
    {
        struct Payload
        {
            nothrow @nogc @safe pure:

            ubyte* memStart;        // Beginning of memory pool
            ubyte* next;            // Num of next free block
            uint numFreeBlocks;     // Num of remaining blocks
            uint numInitialized;    // Num of initialized blocks
            size_t refs;            // Number of references
            bool ownPool;           // Is memory block allocated by us?

            void initialize(ubyte[] buffer)
            {
                import core.exception : onOutOfMemoryError;
                if (buffer)
                {
                    assert(
                        buffer.length >= numBlocks * blockSize,
                        "Provided buffer has wrong size, must be at least numBlocks*blockSize");
                    memStart = &buffer[0];
                }
                else
                {
                    memStart = () @trusted { return cast(ubyte*)pureCalloc(numBlocks, blockSize); }();
                    if (!memStart) onOutOfMemoryError();
                    ownPool = true;
                }

                next = memStart;
                numFreeBlocks = numBlocks;
                refs = 1;
            }

            ~this()
            {
                assert(memStart, "memStart is null");
                if (ownPool) () @trusted { pureFree(memStart); }();
            }
        }

        Payload* pay;
    }

    /// Copy constructor
    this(ref return scope typeof(this) rhs) pure @safe
    {
        // debug printf("copy\n");
        if (rhs.pay is null) initPool();
        else
        {
            this.pay = rhs.pay;
            this.pay.refs++;
        }
    }

    /// Destructor
    ~this() pure @safe
    {
        import std.traits : hasElaborateDestructor;
        if (pay)
        {
            pay.refs--;
            // debug printf("destroy: refs=%d\n", pay.refs);
            if (pay.refs == 0)
            {
                // debug printf("free\n");
                static if (is(T == void) || hasElaborateDestructor!T) {
                    assert(pay.numFreeBlocks == numBlocks, "Possibly not disposed allocations left in pool");
                }
                destroy(*pay); // call payload destructor
                () @trusted { pureFree(pay); } ();
            }
        }
    }

    /// Available number of items / blocks that can be allocated
    size_t capacity() const pure @safe
    {
        if (_expect(pay is null, false)) return numBlocks;
        return pay.numFreeBlocks;
    }

    static if (is(T == void)) // allow to allocate anything that fits
    {
        /**
         * Allocates item of requested type from the pool.
         *
         * Size of the requested item type must be less or equal to the pool block size.
         *
         * Params: args = optional args to be used to initialize item
         * Returns: pointer to the allocated item or `null` if the pool is already depleted.
         */
        U* alloc(U, ARGS...)(auto ref ARGS args)
        {
            static assert(U.sizeof <= blockSize, format!"Can't allocate %s of size %s with blockSize=%s"(U, U.sizeof, blockSize));
            return allocImpl!(U, true)(forward!args);
        }

        /**
         * Similar to `alloc` but doesn't initialize the allocated value.
         */
        U* allocVoid(U)()
        {
            static assert(U.sizeof <= blockSize, format!"Can't allocate %s of size %s with blockSize=%s"(U, U.sizeof, blockSize));
            return allocImpl!(U, false)();
        }

        /**
         * Returns previously allocated item back to the pool.
         *
         * If the item type has a destructor it is called.
         *
         * Params: p = allocated item pointer
         */
        void dealloc(U)(ref U* p)
        {
            pragma(inline, true)
            deallocImpl(p);
        }
    }
    else
    {
        /**
         * Allocates item from the pool.
         *
         * Params: args = optional args to be used to initialize item
         * Returns: pointer to the allocated item or `null` if the pool is already depleted.
         */
        T* alloc(ARGS...)(auto ref ARGS args)
        {
            pragma(inline)
            return allocImpl!(T, true)(forward!args);
        }

        /**
         * Similar to `alloc` but doesn't initialize the allocated value.
         */
        T* allocVoid()
        {
            pragma(inline)
            return allocImpl!(T, false)();
        }

        /**
         * Returns previously allocated item back to the pool.
         *
         * If the item type has a destructor it is called.
         *
         * Params: p = allocated item pointer
         */
        void dealloc(ref T* p)
        {
            pragma(inline, true)
            deallocImpl(p);
        }
    }

    private:

    void initPool(ubyte[] buffer = null) pure @safe
    {
        import core.exception : onOutOfMemoryError;

        assert(pay is null);
        // debug printf("init\n");
        pay = () @trusted { return cast(Payload*)pureMalloc(Payload.sizeof); }();
        if (!pay) onOutOfMemoryError();
        emplace(pay);
        pay.initialize(buffer);
    }

    U* allocImpl(U, bool initialize = true, ARGS...)(auto ref ARGS args)
    {
        pragma(inline, true);
        static assert(initialize || ARGS.length == 0);
        if (_expect(pay is null, false)) initPool();

        // make sure that list of unused blocks is correct when allocating
        if (pay.numInitialized < numBlocks)
        {
            uint* p = () @trusted { return cast(uint*)addrFromIdx(pay.memStart, pay.numInitialized); }();
            *p = ++pay.numInitialized;
        }

        if (_expect(pay.numFreeBlocks > 0, true))
        {
            U* ret = () @trusted { return cast(U*)pay.next; }();
            if (_expect(--pay.numFreeBlocks != 0, true))
                pay.next = addrFromIdx(pay.memStart, () @trusted { return *(cast(uint*)pay.next); }());
            else pay.next = null;
            static if (initialize) return emplace(ret, args);
            else return ret;
        }
        return null;
    }

    void deallocImpl(U)(ref U* p)
    {
        pragma(inline, true);
        assert(pay, "dealloc called on uninitialized pool");
        assert(p, "Null pointer");

        () @trusted {
            assert(
                cast(ubyte*)p >= pay.memStart && cast(ubyte*)p < (pay.memStart + numBlocks*blockSize),
                "Pointer out of bounds"
            );
            assert((cast(ubyte*)p - pay.memStart) % blockSize == 0, "Invalid item memory offset");
        }();

        import std.traits : hasElaborateDestructor;
        static if (hasElaborateDestructor!U)
            destroy(*p); // call possible destructors

        // store index of prev next to newly returned item
        uint* nip = () @trusted { return cast(uint*)p; }();
        if (_expect(pay.next !is null, true))
            *nip = idxFromAddr(pay.memStart, pay.next);
        else
            *nip = numBlocks;

        // and use returned item as next free one
        pay.next = () @trusted { return cast(ubyte*)p; }();
        ++pay.numFreeBlocks;
        p = null;
    }

    static ubyte* addrFromIdx(const ubyte* mstart, uint i) pure @trusted
    {
        pragma(inline, true)
        return cast(ubyte*)(mstart + ( i * blockSize));
    }

    static uint idxFromAddr(const ubyte* mstart, const ubyte* p) pure @trusted
    {
        pragma(inline, true)
        return ((cast(uint)(p - mstart)) / blockSize);
    }
}

@("internal implementation test")
@safe unittest
{
    auto pool = fixedPool!(int, 10);
    foreach (i; 0..10)
    {
        auto item = pool.alloc;
        assert(*item == 0);
        *item = i;
    }
    assert(pool.capacity == 0);
    assert(pool.pay.next is null);

    int* pstart = () @trusted { return cast(int*)pool.pay.memStart; }();
    pool.dealloc(pstart); // dealocate first
    assert(pool.capacity == 1);
    assert(pool.pay.next == pool.pay.memStart);
    assert(pstart is null);

    auto i = pool.alloc();
    assert(pool.capacity == 0);
    assert(pool.pay.next is null);

    pstart = () @trusted { return cast(int*)pool.pay.memStart; }();
    int* pend = () @trusted { return cast(int*)(pool.pay.memStart + int.sizeof*9); }();
    pool.dealloc(pstart); // dealocate it back
    pool.dealloc(pend); // deallocate last one
    auto p = pool.alloc;
    assert(pool.pay.next == pool.pay.memStart);
    assert(cast(ubyte*)p == () @trusted { return pool.pay.memStart + int.sizeof*9; }());
}

@("payload destructor")
@safe unittest
{
    static int refs;
    struct Foo
    {
        ~this() nothrow @nogc @safe { refs--; }
    }

    auto pool = fixedPool!(Foo, 10);
    alias PFoo = Foo*;

    PFoo[10] foos;
    foreach (i; 0..10) foos[i] = pool.alloc();
    refs = 10;
    foreach (i; 0..10) pool.dealloc(foos[i]);
    assert(refs == 0);
}

@("capacity")
@safe unittest
{
    auto pool = fixedPool!(int, 10);
    assert(pool.capacity == 10);
    foreach (_; 0..10)
    {
        auto p = pool.alloc();
        assert(p !is null);
    }
    assert(pool.capacity == 0);
    assert(pool.alloc() is null); // no more space
}

@("untyped")
@safe unittest
{
    static int refs;
    struct Foo
    {
        ~this() nothrow @nogc @safe { refs--; }
    }

    struct Bar
    {
        int baz;
        this(int i) nothrow @nogc @safe { baz = i; }
        ~this() nothrow @nogc @safe { refs--; }
    }

    auto pool = fixedPool!(100, 1);
    assert(pool.capacity == 1);
    auto f = pool.alloc!(Foo);
    refs++;
    pool.dealloc(f);
    f = null;
    assert(refs == 0);

    auto b = pool.alloc!Bar(42);
    refs++;
    assert(b.baz == 42);
    pool.dealloc(b);
    b = null;
    assert(refs == 0);

    auto x = pool.alloc!int();
    assert(x !is null);
    auto y = pool.alloc!int();
    assert(y is null);
    pool.dealloc(x);
}

@("copy")
@safe unittest
{
    auto pool = fixedPool!(int, 10);
    assert(pool.pay.refs == 1);
    auto pool2 = pool;
    assert(pool.pay.refs == 2);
    assert(pool.pay is pool2.pay);
}

@("custom buffer")
@safe unittest
{
    auto buf = () @trusted { return (cast(ubyte*)pureMalloc(int.sizeof * 1024))[0..1024*int.sizeof]; }();
    auto pool = fixedPool!(int, 1024)(buf);
    auto i = pool.alloc();
    assert(cast(ubyte*)i == &buf[0]);
}

@("void initializers")
@safe unittest
{
    {
        auto pool = fixedPool!(int, 10);
        auto a = pool.allocVoid();
        auto b = pool.allocVoid();

        // next index is left in place
        assert(*a == 1);
        assert(*b == 2);
    }

    {
        auto pool = fixedPool!(4, 10);
        auto a = pool.allocVoid!int();
        auto b = pool.allocVoid!int();

        // next index is left in place
        assert(*a == 1);
        assert(*b == 2);
        pool.dealloc(a);
        pool.dealloc(b);
    }
}

@("noncopyable")
@safe unittest
{
    struct Foo
    {
        int n;
        @disable this(this);
    }

    struct Bar
    {
        Foo* f;
        this(ref Foo f) @trusted { this.f = &f; }
    }

    Foo f = Foo(42);
    auto pool = fixedPool!(Bar, 10);
    auto b = pool.alloc(f);
    assert(b !is null);
    assert(b.f !is null);
    assert(b.f.n == 42);
}
