import std.logger;
import std.stdio;
import std.file;

import nm;
import options;

void main(string[] args)
{
    debug (traceLogging)
    {
        auto logger = new FileLogger(stderr, LogLevel.all);
        sharedLog = cast(shared(Logger)) logger;
    }
    trace("Arguments: ", args);

    const res = parseArgs(args);
    if (res.isHelp) return;

    if (args.length != 2)
    {
        fatalf("Exactly one argument is required, got %d", args.length - 1);
        return;
    }

    processObjectFile(args[1], res.options);
}
