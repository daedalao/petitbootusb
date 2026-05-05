module usb;

import std.file;
import std.path;
import std.stdio;
import std.json;
import std.string;
import std.algorithm : map;
import std.array;

enum PB_DIR         = "petitbootusb";
enum GRUB_DIR       = "boot/grub";
enum GLOBAL_ARGS    = "petitbootusb/.global-args";

struct DistroMeta
{
    string name;
    string label;
    string kernel;   // USB-absolute path e.g. /petitbootusb/fedora/vmlinuz
    string initrd;
    string args;
    string endian;   // "le", "be", or "?"
}

string metaPath(string usbMount, string name)
{
    return buildPath(usbMount, PB_DIR, name, "metadata.json");
}

void writeMeta(string usbMount, DistroMeta meta)
{
    auto path = metaPath(usbMount, meta.name);
    mkdirRecurse(path.dirName());
    auto obj = JSONValue([
        "name":   JSONValue(meta.name),
        "label":  JSONValue(meta.label),
        "kernel": JSONValue(meta.kernel),
        "initrd": JSONValue(meta.initrd),
        "args":   JSONValue(meta.args),
        "endian": JSONValue(meta.endian),
    ]);
    std.file.write(path, obj.toPrettyString() ~ "\n");
}

DistroMeta readMeta(string path)
{
    auto obj = parseJSON(cast(string) std.file.read(path));
    return DistroMeta(
        obj["name"].str,
        obj["label"].str,
        obj["kernel"].str,
        obj["initrd"].str,
        obj["args"].str,
        "endian" in obj ? obj["endian"].str : "?",
    );
}

DistroMeta[] listDistros(string usbMount)
{
    auto pbDir = buildPath(usbMount, PB_DIR);
    if (!exists(pbDir) || !pbDir.isDir()) return [];
    DistroMeta[] result;
    foreach (entry; dirEntries(pbDir, SpanMode.shallow))
    {
        auto mp = buildPath(entry.name, "metadata.json");
        if (exists(mp))
            result ~= readMeta(mp);
    }
    return result;
}

string readGlobalArgs(string usbMount)
{
    auto path = buildPath(usbMount, GLOBAL_ARGS);
    if (!exists(path)) return "";
    return (cast(string) std.file.read(path)).strip();
}

void writeGlobalArgs(string usbMount, string args)
{
    auto path = buildPath(usbMount, GLOBAL_ARGS);
    mkdirRecurse(path.dirName());
    std.file.write(path, args ~ "\n");
}

void regenerate(string usbMount)
{
    auto distros    = listDistros(usbMount);
    auto globalArgs = readGlobalArgs(usbMount);
    auto grubDir    = buildPath(usbMount, GRUB_DIR);

    mkdirRecurse(grubDir);

    auto grubPath = buildPath(grubDir, "grub.cfg");
    auto f = File(grubPath, "w");
    f.writeln("set default=0");
    f.writeln("set timeout=10");
    f.writeln();

    foreach (d; distros)
    {
        string allArgs = d.args;
        if (globalArgs.length)
            allArgs = (allArgs ~ " " ~ globalArgs).strip();

        f.writeln(`menuentry "`, d.label, `" {`);
        f.writeln(`    linux `, d.kernel, ` `, allArgs);
        f.writeln(`    initrd `, d.initrd);
        f.writeln(`}`);
        f.writeln();
    }

    f.close();
    writeln("grub.cfg updated: ", grubPath);
    writeln("  ", distros.length, " entr", distros.length == 1 ? "y" : "ies");
}

void removeDistro(string usbMount, string name)
{
    auto dir = buildPath(usbMount, PB_DIR, name);
    if (!exists(dir))
        throw new Exception("distro not found: " ~ name);
    rmdirRecurse(dir);
    writeln("Removed ", name);
    regenerate(usbMount);
}

// ── USB device discovery ──────────────────────────────────────────────────────

struct USBDevice
{
    string device;      // /dev/sdb
    string size;        // 28.8G
    string label;       // 320D-CE15
    string mountpoint;  // /run/media/user/320D-CE15
}

// Parse lsblk key=value pairs format (-P flag).  Direct string scan beats
// regex here since scanUSBDevices() looks up several fields per line.
private string lsblkField(string line, string key)
{
    string needle = key ~ `="`;
    auto i = line.indexOf(needle);
    if (i < 0) return "";
    auto start = i + needle.length;
    auto end = line.indexOf('"', start);
    if (end < 0) return "";
    return line[start .. end];
}

USBDevice[] scanUSBDevices()
{
    import std.process : execute;
    auto r = execute(["lsblk", "-Pno", "NAME,SIZE,LABEL,MOUNTPOINT,RM,TYPE"]);
    if (r.status != 0) return [];

    USBDevice[] result;
    foreach (line; r.output.splitLines())
    {
        if (lsblkField(line, "RM") != "1") continue;        // removable only
        auto mp = lsblkField(line, "MOUNTPOINT");
        if (!mp.startsWith("/")) continue;                   // must be mounted
        auto tp = lsblkField(line, "TYPE");
        if (tp != "disk" && tp != "part") continue;

        result ~= USBDevice(
            "/dev/" ~ lsblkField(line, "NAME"),
            lsblkField(line, "SIZE"),
            lsblkField(line, "LABEL"),
            mp,
        );
    }
    return result;
}

// Get the volume label of a mounted USB given its mountpoint.
string getVolumeLabel(string mountPoint)
{
    import std.process : execute;
    auto r = execute(["lsblk", "-Pno", "NAME,LABEL,MOUNTPOINT"]);
    if (r.status != 0) return "";
    foreach (line; r.output.splitLines())
    {
        if (lsblkField(line, "MOUNTPOINT") != mountPoint) continue;
        return lsblkField(line, "LABEL");
    }
    return "";
}
