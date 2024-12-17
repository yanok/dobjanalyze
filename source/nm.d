module nm;

import std.file;
import std.logger;
import std.array;
import std.conv;
import std.json;
import std.algorithm.searching;

import structured_demangle;

import options;

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
    Node demangle;
}

// debug = dump_json;

private struct MaybeTemplateName {
    bool isTemplate;
    string templateNameAndField;
    string templateArguments;
}

MaybeTemplateName maybeTemplateName(Node[] children, ref const(CmdlineOptions) options) {
    string[] parts;
    bool isTemplate = false;
    bool isMixin = false;
    string templateArgs = "";
    foreach (c; children) {
        if (c.kind == Node.Kind.SymbolName) {
            if (!c.children.empty &&
                c.children[0].kind == Node.Kind.TemplateInstance) {
                if (isTemplate) break;
                isTemplate = true;
                auto ti = c.children[0];
                fatalf(ti.children.empty, "template instance %s has no children", ti);
                auto tich = ti.children;
                fatalf(tich[0].kind != Node.Kind.TemplateName, "template instance first child is not a name: %s", tich[0]);
                parts ~= tich[0].value ~ "!(...)";
                if (tich.array.length > 1 && tich[1].kind == Node.Kind.TemplateArguments)
                    templateArgs = tich[1].value;
            } else {
                // To group mixin contents together, drop everything that goes before __mixinN
                if (options.groupMixins && c.value.startsWith("__mixin")) {
                    parts = ["<mixin>"];
                    isMixin = true;
                } else {
                    parts ~= c.value;
                    if (isTemplate || isMixin) break;
                }
            }
        } else {
            break;
        }
    }
    return MaybeTemplateName(
        isTemplate: isTemplate || isMixin,
        templateNameAndField: parts.join("."),
        templateArguments: templateArgs,
    );
}

Symbol toSymbol(Node dem, string name, ref const(CmdlineOptions) options) {
    trace(dem);
    if (dem.kind != Node.Kind.MangledName) {
        return Symbol(
            name: name,
            demangledName: name,
            isTemplateInstantiation: false,
            demangle: dem,
        );
    }
    auto s = Symbol(
        name: name,
        demangledName: dem.value,
        isTemplateInstantiation: false,
        demangle: dem,
    );
    if (dem.children.empty) return s;
    auto tm = maybeTemplateName(dem.children, options);
    tracef("MaybeTemplate: %s", tm);

    s.isTemplateInstantiation = tm.isTemplate;
    if (tm.isTemplate) {
        s.templateName = tm.templateNameAndField;
        s.rest = tm.templateArguments;
    }
    return s;
}

Symbol parseLine(string line, ref const(CmdlineOptions) options)
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
        fatalf(parts.length != 4, "expected to have 4 parts, got: %s", parts);
        kind = parts[2][0];
        name = parts[3];
        size = to!size_t(parts[1]);
    }
    auto sdem = structuredDemangle(name);
    tracef("Demangled: %s", sdem);
    debug(dump_json) {
        import std.stdio;
        import std.json;
        writeln(sdem.toJSON(true));
    }
    auto sym = sdem.toSymbol(name, options);
    sym.kind = kind;
    sym.size = size;

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

Symbols parseNmOutput(string text, ref const(CmdlineOptions) options)
{
    Symbols syms;

    size_t cnt = 0;
    foreach (line; text.split('\n'))
    {
        if (line.length == 0)
        {
            trace("Skipping an empty line");
            continue;
        }
        cnt++;
        Symbol s = parseLine(line, options);
        syms.allSyms ~= s;
        syms.perKind.require(s.kind, []) ~= s;
        if (s.isTemplateInstantiation)
        {
            syms.tInsts ~= s;
            syms.perTemplate.require(s.templateName, []) ~= s;
        }
        infof(cnt % 1000 == 0, "%d lines processes", cnt);
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

void processObjectFile(string filename, CmdlineOptions options)
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
    auto syms = parseNmOutput(res.output, options);

    trace("Done parsing nm output");

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
