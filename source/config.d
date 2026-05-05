module config;

import std.string;
import std.regex;
import std.algorithm : canFind, count;
import std.array;

struct BootEntry
{
    string label;
    string kernel;
    string initrd;
    string args;
}

BootEntry[] parseIsolinux(string content)
{
    BootEntry[] entries;
    BootEntry cur;
    bool inLabel;

    foreach (rawLine; content.splitLines())
    {
        auto line = rawLine.strip();
        auto upper = line.toUpper();

        if (upper.startsWith("LABEL "))
        {
            if (inLabel && cur.kernel.length)
                entries ~= cur;
            cur = BootEntry.init;
            cur.label = line[6 .. $].strip();
            inLabel = true;
        }
        else if (upper.startsWith("MENU LABEL "))
        {
            cur.label = line[11 .. $].strip();
        }
        else if (inLabel)
        {
            if (upper.startsWith("KERNEL ") || upper.startsWith("LINUX "))
                cur.kernel = line[line.indexOf(' ') + 1 .. $].strip();
            else if (upper.startsWith("INITRD "))
                cur.initrd = line[7 .. $].strip();
            else if (upper.startsWith("APPEND "))
                cur.args = line[7 .. $].strip();
        }
    }
    if (inLabel && cur.kernel.length)
        entries ~= cur;
    return entries;
}

BootEntry[] parseGrub(string content)
{
    BootEntry[] entries;
    BootEntry cur;
    bool inEntry;
    int depth;

    auto labelRe  = regex(`menuentry\s+"([^"]+)"`);
    auto linuxRe  = regex(`^\s*linux(?:efi)?\s+(\S+)\s*(.*)`);
    auto initrdRe = regex(`^\s*initrd(?:efi)?\s+(\S+)`);

    foreach (line; content.splitLines())
    {
        auto s = line.strip();

        if (!inEntry)
        {
            auto m = matchFirst(s, labelRe);
            if (!m.empty)
            {
                cur = BootEntry.init;
                cur.label = m[1];
                inEntry = true;
                depth = 0;
            }
        }

        if (inEntry)
        {
            depth += cast(int)(s.count('{') - s.count('}'));

            auto ml = matchFirst(line, linuxRe);
            if (!ml.empty)
            {
                cur.kernel = ml[1];
                cur.args   = ml[2].strip();
            }

            auto mi = matchFirst(line, initrdRe);
            if (!mi.empty)
                cur.initrd = mi[1];

            if (depth <= 0 && s.canFind('}'))
            {
                if (cur.kernel.length)
                    entries ~= cur;
                inEntry = false;
            }
        }
    }
    return entries;
}
