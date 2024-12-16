module nm;

import std.file;
import std.logger;
import std.array;
import std.conv;
import std.json;
import std.algorithm.searching;
import imported.core.demangle;

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

// debug = dump_json;

private struct MaybeTemplateName {
    bool isTemplate;
    string templateNameAndField;
    string templateArguments;
}

MaybeTemplateName maybeTemplateName(JSONValue children) {
    string[] parts;
    bool isTemplate = false;
    string templateArgs = "";
    foreach (c; children.array) {
        fatalf(!("Node" in c.object), "%s has no Node", c);
        fatalf(!("Value" in c.object), "%s has no Value", c);
        if (c.object["Node"].str == "symbolName") {
            if ("children" in c.object &&
                "Node" in c.object["children"][0] &&
                c.object["children"][0]["Node"].str == "templateInstance") {
                if (isTemplate) break;
                isTemplate = true;
                auto ti = c.object["children"][0];
                fatalf(!("children" in ti), "template instance %s has no children", ti);
                auto tich = ti["children"];
                fatalf(tich.array.length == 0, "template instance %s has zero children", ti);
                fatalf(!("Value" in tich[0]), "template name %s has no Value", tich[0]);
                parts ~= tich[0]["Value"].str ~ "!(...)";
                if (tich.array.length > 1)
                    templateArgs = tich[1]["Value"].str;
            } else {
                parts ~= c["Value"].str;
                if (isTemplate) break;
            }
        } else {
            break;
        }
    }
    return MaybeTemplateName(
        isTemplate: isTemplate,
        templateNameAndField: parts.join("."),
        templateArguments: templateArgs,
    );
}

Symbol toSymbol(JSONValue dem, string name) {
    trace(dem);
    if (dem.object["Node"].str != "mangledName") {
        return Symbol(
            name: name,
            demangledName: name,
            isTemplateInstantiation: false,
        );
    }
    auto s = Symbol(
        name: name,
        demangledName: dem.object["Value"].str,
        isTemplateInstantiation: false,
    );
    if (!("children" in dem.object)) return s;
    auto tm = maybeTemplateName(dem.object["children"]);
    tracef("MaybeTemplate: %s", tm);

    s.isTemplateInstantiation = tm.isTemplate;
    if (tm.isTemplate) {
        s.templateName = tm.templateNameAndField;
        s.rest = tm.templateArguments;
    }
    return s;
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
        fatalf(parts.length != 4, "expected to have 4 parts, got: %s", parts);
        kind = parts[2][0];
        name = parts[3];
        size = to!size_t(parts[1]);
    }
    auto demName = cast(string) demangle(name);
    auto sdem = structuredDemangle(name);
    tracef("Demangled: %s", sdem);
    debug(dump_json) {
        import std.stdio;
        import std.json;
        writeln(sdem.toJSON(true));
    }
    auto sym = sdem.toSymbol(name);
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

Symbols parseNmOutput(string text)
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
        Symbol s = parseLine(line);
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
