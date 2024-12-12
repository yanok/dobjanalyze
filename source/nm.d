module nm;

import std.file;
import std.logger;
import std.array;
import std.conv;
import std.algorithm.searching;
import core.demangle;

struct Symbol
{
    string name;
    string demangledName;
    string baseName;
    bool isTemplateInstantiation;
    string templateName;
    string rest;
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
    import d = custom_demangle;

    auto base = cast(string) d.demangle(name);
    auto baseSplit = base.findSplit("!");
    auto isTempl = baseSplit[2] != "";
    auto templ = baseSplit[0];
    auto rest = baseSplit[2];
    tracef("Symbol: name=%s, demangledName=%s, kind=%c, size=%d, base=%s, is_instance=%s, template=%s, rest=%s",
        name, demName, kind, size, base, isTempl, templ, rest);
    auto sym = Symbol(name, demName, base, isTempl, templ, rest, kind, size);

    return sym;
}

struct Stats
{
    string group;
    size_t count;
    size_t totalSize;
    size_t avgSize;
    size_t minSize;
    size_t maxSize;
    size_t medianSize;
}

void displayStats(Stats s)
{
    import std.stdio;

    writeln("----------------------------------------");
    writefln("Stats for %s:", s.group);
    writeln("----------------------------------------");
    writefln("Count:  %d", s.count);
    writefln("Size:   %d", s.totalSize);
    writefln("Avg:    %d", s.avgSize);
    writefln("Min:    %d", s.minSize);
    writefln("Max:    %d", s.maxSize);
    writefln("Median: %d", s.medianSize);
    writeln("----------------------------------------");

}

Stats computeStats(string group, Symbol[] syms)
{
    import std.algorithm;

    Stats stats;
    stats.group = group;
    stats.count = syms.length;
    auto sizes = syms.map!(s => s.size).array.sort;
    stats.totalSize = sizes.sum;
    if (stats.count)
    {
        stats.avgSize = stats.totalSize / stats.count;
        stats.minSize = sizes[0];
        stats.maxSize = sizes[$ - 1];
        stats.medianSize = (syms.length & 1) ? sizes[syms.length / 2] : (
            sizes[syms.length / 2 - 1] + sizes[syms.length / 2]) / 2;
    }
    return stats;
}

struct Symbols
{
    Symbol[] allSyms;
    Symbol[] tInsts;
    Symbol[][char] perKind;
    Symbol[][string] perTemplate;
    Stats stats;
    Stats tInstsStats;
    Stats[char] statsPerKind;
    Stats[string] statsPerTemplate;
}

Symbols parseNmOutput(string text)
{
    Symbols syms;

    foreach (line; text.split('\n'))
    {
        if (line.length == 0)
        {
            trace("Skipping an empty line");
            continue;
        }
        Symbol s = parseLine(line);
        syms.allSyms ~= s;
        syms.perKind.require(s.kind, []) ~= s;
        if (s.isTemplateInstantiation)
        {
            syms.tInsts ~= s;
            syms.perTemplate.require(s.templateName, []) ~= s;
        }
    }
    syms.stats = computeStats("all file", syms.allSyms);
    syms.tInstsStats = computeStats("template instances", syms.tInsts);
    foreach (kind, ss; syms.perKind)
    {
        syms.statsPerKind[kind] = computeStats("kind " ~ kind, ss);
    }
    foreach (t, ss; syms.perTemplate)
    {
        syms.statsPerTemplate[t] = computeStats("template " ~ t, ss);
    }
    return syms;
}

void processObjectFile(string filename)
{
    import std.process;

    auto nm = environment.get("NM", "nm");
    tracef("Processing object file %s", filename);
    fatalf(!exists(filename), "%s doesn't exists", filename);
    fatalf(!isFile(filename), "%s is not a file", filename);
    trace("Running nm to get list of symbols");
    auto res = execute([nm, "-S", "-t", "d", filename]);
    tracef("nm returned %d", res.status);
    fatalf(res.status != 0, "nm execution failed with return code %d", res.status);
    auto syms = parseNmOutput(res.output);

    displayStats(syms.stats);
    displayStats(syms.tInstsStats);
    foreach (kind, stats; syms.statsPerKind)
    {
        displayStats(stats);
    }

    Stats[] tStats;
    foreach (t, stats; syms.statsPerTemplate)
    {
        tStats ~= stats;
    }
    import std.algorithm;

    foreach (stats; tStats.sort!"a.count < b.count")
    {
        displayStats(stats);
    }
}
