module editor;

import std.stdio;
import std.string : strip;

string editLine(string heading, string current)
{
    writeln(heading);
    writeln("  ", current.length ? current : "(none)");
    write("\nNew args (enter to keep): ");
    stdout.flush();
    string input = readln().strip();
    return input.length ? input : current;
}
