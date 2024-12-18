module options;

import std.typecons;

import args : Arg, Optional, parseArgsWithConfigFile, printArgsHelp;

static struct CmdlineOptions
{
    @Arg("Try to group mixins", Optional.yes) bool groupMixins;
    @Arg("Output JSON to filename", Optional.yes) string jsonOutFile;
    @Arg("Look for specific template", Optional.yes) string filterTemplate;
}

Tuple!(CmdlineOptions, "options", bool, "isHelp") parseArgs(ref string[] args)
{
    CmdlineOptions options;
    bool helpWanted = parseArgsWithConfigFile(options, args);

    if (helpWanted)
    {
        printArgsHelp(options, "Collect symbols from D object file");
    }
    return Tuple!(CmdlineOptions, "options", bool, "isHelp")(options, helpWanted);
}
