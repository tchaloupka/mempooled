module mempooled.dynamic;

debug import core.stdc.stdio;
import core.memory : pureMalloc, pureCalloc, pureFree;
import core.lifetime : emplace, forward;
import mempooled.intrinsics;

nothrow @nogc:

/**
 * Memory pool implemented over linked list of allocated blocks that are being reused.
 * If there is no preallocated block in the pool, it allocates the new one from the heap.
 * When block is returned to the pool, it's just prepended at the start of the unused blocks to be available again.
 *
 * Unused blocks are freed only when `clear()` is called on the pool or when pool itself is cleared out by ROI.
 */
struct DynamicPool(size_t blockSize)
{
    nothrow @nogc:

    static assert(blockSize >= 8, "blockSize must be equal or greater than (void*).sizeof");

    private
    {
        static assert(Block.sizeof == 8);

        struct Block { Block* next; }
        struct Payload
        {
            nothrow @nogc @safe pure:

            Block* pool;        // Beginning of unused blocks
            uint numFreeBlocks; // Number of available memory blocks
            uint numUsedBlocks; // Number of provided memory blocks
            size_t refs;        // Number of references

            ~this() @trusted
            {
                assert(!numUsedBlocks, "There are still some not yet returned memory blocks");
                while (pool)
                {
                    auto next = pool.next;
                    pureFree(pool);
                    numFreeBlocks--;
                    pool = next;
                }
                assert(!numFreeBlocks, "Should be zero");
            }
        }

        Payload* pay;
    }

    /// Copy constructor
    this(ref return scope typeof(this) rhs) pure @safe
    {
        if (rhs.pay is null) return;
        else
        {
            this.pay = rhs.pay;
            this.pay.refs++;
        }
    }

    /// Available number of preallocated blocks
    size_t capacity() const pure @safe
    {
        if (_expect(pay is null, false)) return 0;
        return pay.numFreeBlocks;
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
                assert(pay.numUsedBlocks == 0, "Some blocks are still being used!");
                destroy(*pay); // call payload destructor
                () @trusted { pureFree(pay); } ();
            }
        }
    }

    /**
     * Returns memory block of the request size.
     *
     * If there is no preallocated block in the pool, new'd be allocated (with `blockSize` length
     * regardless of `len` parameter).
     *
     * Params:
     *   len - size of wanted block (must by lower or equal to a pool's `blockSize`)
     *
     * Returns:
     *   Address of the memory block or null if it fails to allocate.
     */
    void* alloc(size_t len) @safe pure
    in (len <= blockSize)
    {
        if (_expect(pay is null, false))
        {
            import core.exception : onOutOfMemoryError;
            pay = () @trusted { return cast(Payload*)pureMalloc(Payload.sizeof); }();
            if (!pay) onOutOfMemoryError();
            emplace(pay);
            pay.refs = 1;
            goto newBlock;
        }

        if (pay.pool !is null)
        {
            void* ret = cast(void*)pay.pool;
            pay.pool = pay.pool.next;
            pay.numFreeBlocks--;
            pay.numUsedBlocks++;
            return ret;
        }

        newBlock:
        auto res = () @trusted { return pureMalloc(blockSize); }();
        if (res) pay.numUsedBlocks++;
        return res;
    }

    /**
     * Allocates requested type over pooled memory block and returns it.
     * `onOutOfMemoryError` is called when new memory block fails to be allocated.
     */
    T* alloc(T, ARGS...)(auto ref ARGS args)
    {
        import core.exception : onOutOfMemoryError;

        static assert(T.sizeof <= blockSize, "Requested type don't fit in pool's blocks size");
        auto mem = () @trusted { return cast(T*)alloc(T.sizeof); }();
        if (!mem) onOutOfMemoryError();
        return mem.emplace(forward!args);
    }

    /**
     * Returns block of memory back to the pool.
     * Deallocating pointer to a memory not returned by the pool has undefined behavior.
     */
    void dealloc(ref void* ptr) @system
    in (ptr, "Null ptr provided")
    in (pay, "Pool not initialized")
    {
        auto block = cast(Block*)ptr;
        block.next = pay.pool;
        pay.pool = block;
        pay.numUsedBlocks--;
        pay.numFreeBlocks++;
        ptr = null;
    }

    /// ditto
    void dealloc(T)(ref T* p) if (!is(T == void))
    {
        import std.traits : hasElaborateDestructor;
        static if (hasElaborateDestructor!T)
            destroy(*p); // call possible destructors

        dealloc(*(cast(void**)&p));
    }

    /**
     * Clears all currently preallocated memory blocks.
     */
    void clear() @safe pure
    in (pay, "Pool not initialized")
    {
        while (pay.pool)
        {
            auto n = pay.pool.next;
            () @trusted { pureFree(pay.pool); }();
            pay.pool = n;
            pay.numFreeBlocks--;
        }
        assert(pay.numFreeBlocks == 0);
    }
}

///
@("Usage tests")
unittest
{
    DynamicPool!1024 pool; // each block is 1024B large
    auto n = pool.alloc!int(42); // allocates whole 1024B block for just an 4B large number
    assert(*n == 42);

    auto buf = pool.alloc!(ubyte[1024])(); // uses whole block and zeroes the array
    foreach (i; 0..1024) assert((*buf)[i] == 0);

    void* vbuf = pool.alloc(1024); // uses whole block that we can use as we please - block memory is uninitialized
    assert(vbuf !is null);

    // FixedPool over DynamicPool memory block
    import mempooled.fixed : fixedPool;
    auto fpblock = cast(ubyte*)pool.alloc(1024);
    auto fpool = fixedPool!(8, 128)(fpblock[0..1024]);
    auto x = fpool.alloc!int(666);
    assert(*x == 666);
    fpool.dealloc(x);

    assert(pool.pay.numUsedBlocks == 4);
    pool.dealloc(n);
    pool.dealloc(buf);
    pool.dealloc(vbuf);
    pool.dealloc(fpblock);
}

@("Pool integrity tests")
@safe unittest
{
    DynamicPool!1024 pool;

    assert(pool.pay is null);
    void* block = pool.alloc(10);
    assert(pool.pay !is null);
    assert(pool.pay.refs == 1);
    assert(pool.pay.numFreeBlocks == 0);
    assert(pool.pay.numUsedBlocks == 1);
    assert(block !is null);
    () @trusted { (cast(ubyte*)block)[8] = 42; }(); // write 42 after Block next pointer
    assert(pool.capacity == 0);
    () @trusted { pool.dealloc(block); }();
    assert(block is null);
    assert(pool.pay.numFreeBlocks == 1);
    assert(pool.pay.numUsedBlocks == 0);
    assert(pool.capacity == 1);
    block = pool.alloc(1024);
    assert(pool.pay.numFreeBlocks == 0);
    assert(pool.pay.numUsedBlocks == 1);
    assert(block !is null);
    assert(() @trusted { return (cast(ubyte*)block)[8]; }() == 42);
    assert(pool.capacity == 0);
    () @trusted { pool.dealloc(block); }();

    struct Foo { int n; }
    Foo* f = pool.alloc!Foo(42);
    assert(f.n == 42);
    () @trusted { pool.dealloc(f); }();
    assert(f is null);

    assert(pool.pay.numFreeBlocks == 1);
    pool.clear();
    assert(pool.pay.numFreeBlocks == 0);
}
