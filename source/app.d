module app;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm : canFind;
import std.process : execute;

import config;
import distro;
import editor;
import iso;
import usb;

// ── Dependency check ──────────────────────────────────────────────────────────

void checkDeps()
{
    if (execute(["bsdtar", "--version"]).status != 0)
    {
        stderr.writeln("error: bsdtar not found. Install libarchive (libarchive or bsdtar package).");
        import core.stdc.stdlib : exit; exit(1);
    }
}

// ── CLI commands ──────────────────────────────────────────────────────────────

void cmdAdd(string mountPoint, string[] isoPaths)
{
    foreach (isoPath; isoPaths)
    {
        if (!exists(isoPath)) { stderr.writeln("ISO not found: ", isoPath); continue; }

        writeln("Inspecting ", isoPath.baseName(), " ...");
        ISOFiles isoFiles;
        try   isoFiles = inspectISO(isoPath);
        catch (Exception e) { stderr.writeln("  Error: ", e.msg); continue; }

        if (!isoFiles.kernel) { stderr.writeln("  Could not find kernel — skipping."); continue; }
        if (!isoFiles.initrd) { stderr.writeln("  Could not find initrd — skipping.");  continue; }

        BootEntry[] entries;
        if (isoFiles.configContent.length)
        {
            bool isGrub = isoFiles.configFile.toLower().canFind("grub");
            entries = isGrub ? parseGrub(isoFiles.configContent)
                             : parseIsolinux(isoFiles.configContent);
        }

        BootEntry best;
        foreach (e; entries) if (e.kernel.length) { best = e; break; }

        auto dtype     = detectType(isoFiles, entries);
        auto name      = deriveName(isoPath, entries);
        auto label     = best.label.length ? best.label : name;
        auto distroDir = "/" ~ PB_DIR ~ "/" ~ name;
        auto usbLabel  = getVolumeLabel(mountPoint);
        auto args      = translateArgs(dtype, best.args, distroDir, usbLabel);

        writefln("  Label:   %s", label);
        writefln("  Type:    %s", dtype);
        writefln("  Kernel:  %s", isoFiles.kernel);
        writefln("  Initrd:  %s", isoFiles.initrd);
        if (isoFiles.squashfs) writefln("  Squashfs:%s", isoFiles.squashfs);

        auto destBase   = buildPath(mountPoint, PB_DIR, name);
        auto kernelDest = buildPath(destBase, "vmlinuz");
        auto initrdDest = buildPath(destBase, "initrd.img");

        writeln("  Extracting kernel...");
        extractFile(isoPath, isoFiles.kernel, kernelDest);

        writeln("  Extracting initrd...");
        extractFile(isoPath, isoFiles.initrd, initrdDest);

        if (dtype == DistroType.T2SDE)
        {
            writeln("  Patching T2 initrd (ext4 fs probe)...");
            if (!patchT2Initrd(initrdDest))
                stderr.writeln("  WARNING: T2 initrd patch failed — boot may not work. Need zstd and cpio.");
        }

        if (isoFiles.squashfs)
        {
            string squashDest;
            final switch (dtype)
            {
                case DistroType.FedoraDracut:
                    squashDest = buildPath(destBase, "LiveOS", "squashfs.img"); break;
                case DistroType.UbuntuCasper:
                    squashDest = buildPath(destBase, "casper", "filesystem.squashfs"); break;
                case DistroType.DebianLive:
                    squashDest = buildPath(destBase, "live", isoFiles.squashfs.baseName()); break;
                case DistroType.ArchISO:
                {
                    string sqFile  = isoFiles.squashfs.baseName();
                    string archDir = isoFiles.squashfs.dirName().baseName();
                    squashDest = (archDir.length && archDir != "/")
                        ? buildPath(destBase, archDir, sqFile)
                        : buildPath(destBase, sqFile);
                    break;
                }
                case DistroType.T2SDE:
                case DistroType.MinimalInstaller:
                case DistroType.Generic:
                    squashDest = buildPath(destBase, isoFiles.squashfs.baseName()); break;
            }
            writeln("  Extracting squashfs (may take a while)...");
            extractFile(isoPath, isoFiles.squashfs, squashDest);
        }

        string endian = detectKernelEndian(kernelDest);
        writefln("  Endian:  %s", endian == "le" ? "Little (ppc64le)"
                                : endian == "be" ? "Big (ppc64)"
                                                 : "Unknown");

        auto meta = DistroMeta(name, label,
                               distroDir ~ "/vmlinuz",
                               distroDir ~ "/initrd.img",
                               args, endian);
        writeMeta(mountPoint, meta);
        writeln("  Registered.");
    }
    regenerate(mountPoint);
}

void cmdList(string mountPoint)
{
    auto distros = listDistros(mountPoint);
    if (!distros.length) { writeln("No distros on ", mountPoint); return; }
    auto globalArgs = readGlobalArgs(mountPoint);
    writeln("Distros on ", mountPoint, ":");
    foreach (d; distros)
    {
        string endianStr = d.endian == "le" ? "LE" : d.endian == "be" ? "BE" : "??";
        writefln("  [%s] [%s]  %s", d.name, endianStr, d.label);
        writefln("    kernel: %s", d.kernel);
        writefln("    initrd: %s", d.initrd);
        writefln("    args:   %s", d.args.length ? d.args : "(none)");
    }
    if (globalArgs.length) writeln("\nGlobal args: ", globalArgs);
}

void cmdEdit(string mountPoint, string name)
{
    auto path = metaPath(mountPoint, name);
    if (!exists(path)) { stderr.writeln("Distro not found: ", name); return; }
    auto meta = readMeta(path);
    writeln("Editing args for: ", meta.label);
    meta.args = editLine("Current args:", meta.args);
    writeMeta(mountPoint, meta);
    writeln("Saved. Run 'petitbootusb regenerate ", mountPoint, "' to update grub.cfg.");
}

void cmdGlobal(string mountPoint)
{
    auto current = readGlobalArgs(mountPoint);
    writeln("Global args (appended to every boot entry):");
    auto newArgs = editLine("Current global args:", current);
    writeGlobalArgs(mountPoint, newArgs);
    writeln("Saved.");
    regenerate(mountPoint);
}

// ── Usage ─────────────────────────────────────────────────────────────────────

void usage()
{
    writeln("Usage: petitbootusb [<usb-mountpoint>]           — launch TUI");
    writeln("       petitbootusb <command> <usb-mountpoint> [args...]");
    writeln();
    writeln("Commands:");
    writeln("  add <usb> <iso> [iso2 ...]   Extract and register ISO(s)");
    writeln("  remove <usb> <name>          Remove a distro and update grub.cfg");
    writeln("  list <usb>                   List registered distros");
    writeln("  edit <usb> <name>            Edit kernel args for a distro");
    writeln("  global <usb>                 Edit global args appended to all entries");
    writeln("  regenerate <usb>             Rebuild grub.cfg from stored metadata");
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main(string[] args)
{
    checkDeps();

    // TUI mode: no subcommand, or just a mount point
    if (args.length <= 2 && !args[$ - 1].startsWith("-"))
    {
        import tui.term : isTTY;
        import tui.ui   : runTUI;

        // Empty string → device picker; explicit path → validate first
        string mountPoint = args.length == 2 ? args[1].stripRight("/") : "";

        if (mountPoint.length && (!exists(mountPoint) || !isDir(mountPoint)))
        {
            stderr.writeln("Not a directory: ", mountPoint);
            return 1;
        }

        if (isTTY())
        {
            runTUI(mountPoint);
            return 0;
        }
        // Not a TTY and no subcommand
        usage();
        return 0;
    }

    if (args.length < 3) { usage(); return args.length == 1 ? 0 : 1; }

    string cmd        = args[1];
    string mountPoint = args[2].stripRight("/");

    if (!exists(mountPoint) || !mountPoint.isDir())
    {
        stderr.writeln("Not a directory: ", mountPoint);
        return 1;
    }

    try
    {
        switch (cmd)
        {
            case "add":
                if (args.length < 4) { stderr.writeln("add: requires at least one ISO path"); return 1; }
                cmdAdd(mountPoint, args[3 .. $]);
                break;
            case "remove":
                if (args.length < 4) { stderr.writeln("remove: requires a distro name"); return 1; }
                removeDistro(mountPoint, args[3]);
                break;
            case "list":       cmdList(mountPoint);            break;
            case "edit":
                if (args.length < 4) { stderr.writeln("edit: requires a distro name"); return 1; }
                cmdEdit(mountPoint, args[3]);
                break;
            case "global":     cmdGlobal(mountPoint);          break;
            case "regenerate": regenerate(mountPoint);         break;
            default:
                stderr.writeln("Unknown command: ", cmd);
                usage();
                return 1;
        }
    }
    catch (Exception e) { stderr.writeln("Error: ", e.msg); return 1; }

    return 0;
}
