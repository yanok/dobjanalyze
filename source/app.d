import std.logger;
import std.stdio;
import std.file;

import nm;

void main(string[] args)
{
    auto logger = new FileLogger(stderr, LogLevel.all);
    sharedLog = cast(shared(Logger)) logger;
    trace("Arguments: ", args);

    if (args.length != 2)
    {
        fatalf("Exactly one argument is required, got %d", args.length - 1);
        return;
    }

    processObjectFile(args[1]);
}
