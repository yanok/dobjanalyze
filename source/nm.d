import std.file;
import std.logger;
import std.array;
import std.conv;
import core.demangle;

struct Symbol
{
    string name;
    string demangledName;
    char kind;
    size_t size;
}

Symbol parseLine(string line)
{
    auto parts = line.split;
    tracef("Parsing line: %s, parts: %s", line, parts);
    size_t size = 0;
    char kind;
    string name;
    if (parts.length == 2)
    {
        kind = parts[0][0];
        name = parts[1];
    }
    else
    {
        assert(parts.length == 4);
        kind = parts[2][0];
        name = parts[3];
        size = to!size_t(parts[1]);
    }
    auto demName = cast(string) demangle(name);
    tracef("Symbol: name=%s, demangledName=%s, kind=%c, size=%d", name, demName, kind, size);
    auto sym = Symbol(name, demName, kind, size);

    return sym;
}

void parseNmOutput(string text)
{
    foreach (line; text.split('\n'))
    {
        if (line.length == 0)
        {
            trace("Skipping an empty line");
            continue;
        }
        parseLine(line);
    }
}

void processObjectFile(string filename)
{
    import std.process;

    tracef("Processing object file %s", filename);
    fatalf(!exists(filename), "%s doesn't exists", filename);
    fatalf(!isFile(filename), "%s is not a file", filename);
    trace("Running nm to get list of symbols");
    auto res = execute(["nm", "-S", "-t", "d", filename]);
    tracef("nm returned %d", res.status);
    fatalf(res.status != 0, "nm execution failed with return code %d", res.status);
    parseNmOutput(res.output);
}
