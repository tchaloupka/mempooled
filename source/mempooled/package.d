module mempooled;

public import mempooled.fixed;

version (unittest)
{
    version (D_BetterC)
    {
        import core.stdc.stdio;
        extern (C) int main()
        {
            static foreach(u; __traits(getUnitTests, mempooled.fixed))
                u();
            printf("All unit tests have been run successfully.\n");
            return 0;
        }
    }
}
