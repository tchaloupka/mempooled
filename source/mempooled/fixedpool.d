module mempool.fixed;

debug import core.stdc.stdio;
import core.stdc.stdlib;
import std.conv : emplace;

nothrow @nogc:

/// create instance of `FixedPool`
auto fixedPool(T, size_t size)()
{
    return FixedPool!(T.sizeof, size, T)();
}

/// ditto
auto fixedPool(size_t blockSize, size_t numBlocks)()
{
    return FixedPool!(blockSize, numBlocks, void)();
}

/**
 * Implementation of "Fast Efficient Fixed-Size Memory Pool" as described in this article:
 * www.thinkmind.org/download.php?articleid=computation_tools_2012_1_10_80006
 *
 * See_Also: implementation here: https://github.com/green-anger/MemoryPool
 */
struct FixedPool(size_t blockSize, size_t numBlocks, T = void)
{
    nothrow @nogc:

    static assert(blockSize >= 4, "blockSize must be equal or greater than uint.sizeof");
    static if (!is(T == void))
    {
        static assert(T.sizeof == blockSize, "Blocksize must be the same as used T.sizeof");
    }

    private
    {
        struct Payload
        {
            ubyte* memStart;       // Beginning of memory pool
            ubyte* next;           // Num of next free block
            uint numFreeBlocks;    // Num of remaining blocks
            uint numInitialized;   // Num of initialized blocks
            size_t refs;            // number of references

            void initialize()
            {
                memStart = cast(ubyte*)calloc(numBlocks, blockSize);
                assert(memStart, "failed to allocate pool");
                next = memStart;
                numFreeBlocks = numBlocks;
                refs = 1;
            }

            ~this()
            {
                free(memStart);
            }
        }

        Payload* pay;
    }

    /// Copy constructor
    this(ref return scope typeof(this) rhs)
    {
        // debug printf("copy\n");
        if (rhs.pay is null) initPool();
        else
        {
            this.pay = rhs.pay;
            this.pay.refs++;
        }
    }

    ~this()
    {
        if (pay)
        {
            pay.refs--;
            // debug printf("destroy: refs=%d\n", pay.refs);
            if (pay.refs == 0)
            {
                // debug printf("free\n");
                destroy(*pay); // call payload destructor
                free(pay);
            }
        }
    }

    size_t capacity() const
    {
        if (pay is null) return numBlocks;
        return pay.numFreeBlocks;
    }

    static if (is(T == void)) // allow to allocate anything that fits
    {
        U* alloc(U, ARGS...)(ARGS args)
        {
            static assert(U.sizeof <= blockSize, format!"Can't allocate %s of size %s with blockSize=%s"(U, U.sizeof, blockSize));
            void* p = allocImpl();
            if (p) return emplace(cast(U*)p, args);
            return null;
        }

        void dealloc(U)(U* p)
        {
            deallocImpl(p);
        }
    }
    else
    {
        T* alloc(ARGS...)(ARGS args)
        {
            void* p = allocImpl();
            if (p) return emplace(cast(T*)p, args);
            return null;
        }

        void dealloc(T* p)
        {
            deallocImpl(p);
        }
    }

    private:

    void initPool()
    {
        assert(pay is null);
        // debug printf("init\n");
        pay = cast(Payload*)malloc(Payload.sizeof);
        emplace(pay);
        pay.initialize();
    }

    void* allocImpl()
    {
        if (pay is null) initPool();

        // make sure that list of unused blocks is correct when allocating
        if (pay.numInitialized < numBlocks)
        {
            uint* p = cast(uint*)addrFromIdx(pay.numInitialized);
            *p = ++pay.numInitialized;
        }

        void* ret;
        if (pay.numFreeBlocks > 0)
        {
            ret = cast(void*)pay.next;
            if (--pay.numFreeBlocks != 0)
                pay.next = addrFromIdx(*(cast(uint*)pay.next));
            else pay.next = null;
        }
        return ret;
    }

    void deallocImpl(U)(U* p)
    {
        assert(
            cast(ubyte*)p >= pay.memStart  && cast(ubyte*)p < (pay.memStart + numBlocks*blockSize),
            "Out of bounds"
        );
        assert((cast(ubyte*)p - pay.memStart) % blockSize == 0, "Invalid item memory offset");

        import std.traits : hasElaborateDestructor;
        static if (hasElaborateDestructor!U)
            destroy(*p); // call possible destructors

        // store index of prev next to newly returned item
        if (pay.next !is null)
            *(cast(uint*)p) = idxFromAddr(pay.next);
        else
            *(cast(uint*)p) = numBlocks;

        // and use returned item as next free one
        pay.next = cast(ubyte*)p;
        ++pay.numFreeBlocks;
    }

    ubyte* addrFromIdx(uint i) const
    {
        pragma(inline)
        return cast(ubyte*)(pay.memStart + ( i * blockSize));
    }

    uint idxFromAddr(const ubyte* p) const
    {
        pragma(inline)
        return ((cast(uint)(p - pay.memStart)) / blockSize);
    }
}

@("internal implementation test")
unittest
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

    pool.dealloc(cast(int*)pool.pay.memStart); // dealocate first
    assert(pool.capacity == 1);
    assert(pool.pay.next == pool.pay.memStart);

    auto i = pool.alloc();
    assert(pool.capacity == 0);
    assert(pool.pay.next is null);

    pool.dealloc(cast(int*)pool.pay.memStart); // dealocate it back
    pool.dealloc(cast(int*)(pool.pay.memStart + int.sizeof*9)); // deallocate last one
    auto p = pool.alloc;
    assert(pool.pay.next == pool.pay.memStart);
    assert(cast(ubyte*)p == pool.pay.memStart + int.sizeof*9);
}

@("payload destructor")
unittest
{
    static int refs;
    struct Foo
    {
        ~this() nothrow @nogc { refs--; }
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
unittest
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
unittest
{
    static int refs;
    struct Foo
    {
        ~this() nothrow @nogc { refs--; }
    }

    struct Bar
    {
        int baz;
        this(int i) nothrow @nogc { baz = i; }
        ~this() nothrow @nogc { refs--; }
    }

    auto pool = fixedPool!(100, 10);
    assert(pool.capacity == 10);
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
}
