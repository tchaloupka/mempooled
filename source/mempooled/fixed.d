module mempooled.fixed;

debug import core.stdc.stdio;
import core.stdc.stdlib;
import std.conv : emplace;

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
 * Implementation of "Fast Efficient Fixed-Size Memory Pool" as described in this article:
 * www.thinkmind.org/download.php?articleid=computation_tools_2012_1_10_80006
 *
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
        static assert(T.sizeof == blockSize, "Blocksize must be the same as used T.sizeof");
    }

    private
    {
        struct Payload
        {
            nothrow @nogc:

            ubyte* memStart;        // Beginning of memory pool
            ubyte* next;            // Num of next free block
            uint numFreeBlocks;     // Num of remaining blocks
            uint numInitialized;    // Num of initialized blocks
            size_t refs;            // Number of references
            bool ownPool;           // Is memory block allocated by us?

            void initialize(ubyte[] buffer)
            {
                assert(buffer is null || buffer.length == numBlocks * blockSize, "Provided buffer has wrong size, must be numBlocks*blockSize");
                if (buffer) memStart = &buffer[0];
                else
                {
                    memStart = cast(ubyte*)calloc(numBlocks, blockSize);
                    assert(memStart, "failed to allocate pool");
                    ownPool = true;
                }

                next = memStart;
                numFreeBlocks = numBlocks;
                refs = 1;
            }

            ~this()
            {
                assert(memStart, "memStart is null");
                if (ownPool) free(memStart);
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

    /// Destructor
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

    /// Available number of items / blocks that can be allocated
    size_t capacity() const
    {
        if (pay is null) return numBlocks;
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
        U* alloc(U, ARGS...)(ARGS args)
        {
            pragma(inline)
            static assert(U.sizeof <= blockSize, format!"Can't allocate %s of size %s with blockSize=%s"(U, U.sizeof, blockSize));
            void* p = allocImpl();
            if (p) return emplace(cast(U*)p, args);
            return null;
        }

        /**
         * Returns previously allocated item back to the pool.
         *
         * If the item type has a destructor it is called.
         *
         * Params: p = allocated item pointer
         */
        void dealloc(U)(U* p)
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
        T* alloc(ARGS...)(ARGS args)
        {
            pragma(inline)
            void* p = allocImpl();
            if (p) return emplace(cast(T*)p, args);
            return null;
        }

        /**
         * Returns previously allocated item back to the pool.
         *
         * If the item type has a destructor it is called.
         *
         * Params: p = allocated item pointer
         */
        void dealloc(T* p)
        {
            pragma(inline, true)
            deallocImpl(p);
        }
    }

    private:

    void initPool(ubyte[] buffer = null)
    {
        assert(pay is null);
        // debug printf("init\n");
        pay = cast(Payload*)malloc(Payload.sizeof);
        emplace(pay);
        pay.initialize(buffer);
    }

    void* allocImpl()
    {
        if (pay is null) initPool();

        // make sure that list of unused blocks is correct when allocating
        if (pay.numInitialized < numBlocks)
        {
            uint* p = cast(uint*)addrFromIdx(pay.memStart, pay.numInitialized);
            *p = ++pay.numInitialized;
        }

        void* ret;
        if (pay.numFreeBlocks > 0)
        {
            ret = cast(void*)pay.next;
            if (--pay.numFreeBlocks != 0)
                pay.next = addrFromIdx(pay.memStart, *(cast(uint*)pay.next));
            else pay.next = null;
        }
        return ret;
    }

    void deallocImpl(U)(U* p)
    {
        assert(
            cast(ubyte*)p >= pay.memStart && cast(ubyte*)p < (pay.memStart + numBlocks*blockSize),
            "Out of bounds"
        );
        assert((cast(ubyte*)p - pay.memStart) % blockSize == 0, "Invalid item memory offset");

        import std.traits : hasElaborateDestructor;
        static if (hasElaborateDestructor!U)
            destroy(*p); // call possible destructors

        // store index of prev next to newly returned item
        if (pay.next !is null)
            *(cast(uint*)p) = idxFromAddr(pay.memStart, pay.next);
        else
            *(cast(uint*)p) = numBlocks;

        // and use returned item as next free one
        pay.next = cast(ubyte*)p;
        ++pay.numFreeBlocks;
    }

    static ubyte* addrFromIdx(const ubyte* mstart, uint i) pure
    {
        pragma(inline, true)
        return cast(ubyte*)(mstart + ( i * blockSize));
    }

    static uint idxFromAddr(const ubyte* mstart, const ubyte* p) pure
    {
        pragma(inline, true)
        return ((cast(uint)(p - mstart)) / blockSize);
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
}

@("copy")
unittest
{
    auto pool = fixedPool!(int, 10);
    assert(pool.pay.refs == 1);
    auto pool2 = pool;
    assert(pool.pay.refs == 2);
    assert(pool.pay is pool2.pay);
}

@("custom buffer")
unittest
{
    auto buf = (cast(ubyte*)malloc(int.sizeof * 1024))[0..1024*int.sizeof];
    auto pool = fixedPool!(int, 1024)(buf);
    auto i = pool.alloc();
    assert(cast(ubyte*)i == &buf[0]);
}
