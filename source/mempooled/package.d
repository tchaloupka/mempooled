module mempooled;

public import mempooled.dynamic;
public import mempooled.fixed;

version (unittest)
{
    version (D_BetterC)
    {
        import core.stdc.stdio;
        import std.meta : AliasSeq;

        extern (C) int main()
        {
            foreach (mod; AliasSeq!(mempooled.dynamic, mempooled.fixed))
            {
                static foreach(u; __traits(getUnitTests, mod))
                {
                    static if (__traits(getAttributes, u).length)
                        printf("unittest %s:%d | '" ~ __traits(getAttributes, u)[0] ~ "'\n", __traits(getLocation, u)[0].ptr, __traits(getLocation, u)[1]);
                    else
                        printf("unittest %s:%d\n", __traits(getLocation, u)[0].ptr, __traits(getLocation, u)[1]);
                    u();
                }
            }
            printf("All unit tests have been run successfully.\n");
            return 0;
        }
    }
}
