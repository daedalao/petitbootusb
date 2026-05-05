module distro;

import std.string;
import std.algorithm : canFind;
import std.array;
import std.ascii : isAlphaNum;
import std.path : baseName, stripExtension;
import std.uni : toLower;

import config : BootEntry;

// Kernel byte-order as detected from ELF header (EI_DATA byte).
// Stored as string "le" / "be" / "?" in metadata.json.
string detectKernelEndian(string kernelPath)
{
    import std.stdio : File;
    try {
        ubyte[6] hdr;
        auto f = File(kernelPath, "rb");
        auto got = f.rawRead(hdr[]);
        f.close();
        if (got.length >= 6 && hdr[0] == 0x7f && hdr[1] == 'E'
                             && hdr[2] == 'L'  && hdr[3] == 'F')
            return hdr[5] == 1 ? "le" : "be";
    } catch (Exception) {}
    return "?";
}
import iso : ISOFiles;

enum DistroType
{
    FedoraDracut,
    UbuntuCasper,
    DebianLive,
    ArchISO,        // Arch Power — uses airootfs.sfs + archisolabel
    T2SDE,          // T2/SDE — live.squash + initrd that needs patching
    MinimalInstaller,
    Generic,
}

DistroType detectType(ref ISOFiles isoFiles, BootEntry[] entries)
{
    // T2/SDE — kernel and initrd ship as `*-t2` and the rootfs is `live.squash`.
    // Check this first so the live.squash filename doesn't slip into Generic.
    if (isoFiles.kernel.toLower().canFind("-t2") ||
        isoFiles.initrd.toLower().canFind("-t2") ||
        (isoFiles.squashfs.length && isoFiles.squashfs.baseName().toLower() == "live.squash"))
        return DistroType.T2SDE;

    if (!isoFiles.squashfs)
        return DistroType.MinimalInstaller;

    auto sq = isoFiles.squashfs.toLower();
    if (sq.canFind("airootfs.sfs")) return DistroType.ArchISO;
    if (sq.canFind("liveos"))       return DistroType.FedoraDracut;
    if (sq.canFind("casper"))       return DistroType.UbuntuCasper;
    if (sq.canFind("/live/"))       return DistroType.DebianLive;

    foreach (e; entries)
    {
        if (e.args.canFind("archisobasedir"))   return DistroType.ArchISO;
        if (e.args.canFind("rd.live.image") ||
            e.args.canFind("rd.live.squashimg") ||
            e.args.canFind("rd.live.dir"))      return DistroType.FedoraDracut;
        if (e.args.canFind("boot=casper"))      return DistroType.UbuntuCasper;
        if (e.args.canFind("boot=live"))        return DistroType.DebianLive;
    }

    return DistroType.Generic;
}

// Remove args that reference the CD/ISO device — we substitute our own paths.
string stripDeviceArgs(string args)
{
    string[] keep;
    foreach (tok; args.split())
    {
        if (tok.startsWith("CDLABEL="))          continue;
        if (tok.startsWith("inst.stage2="))       continue;
        if (tok.startsWith("iso-scan/filename=")) continue;
        if (tok.startsWith("findiso="))           continue;
        if (tok.startsWith("root=live:"))         continue;  // any CDLABEL/LABEL form
        if (tok == "root=/dev/cdrom")             continue;
        if (tok.startsWith("loop="))              continue;  // Gentoo loop-mount
        if (tok.startsWith("looptype="))          continue;
        if (tok.startsWith("scandelay="))         continue;  // CD spin-up delay
        if (tok == "cdroot")                      continue;  // Gentoo cdroot flag
        if (tok.startsWith("live-media="))        continue;  // Chimera live device label
        keep ~= tok;
    }
    return keep.join(" ");
}

string translateArgs(DistroType type, string originalArgs, string distroDir, string usbLabel = "")
{
    string base = stripDeviceArgs(originalArgs);

    final switch (type)
    {
        case DistroType.FedoraDracut:
        {
            string[] toks;
            foreach (tok; base.split())
                if (!tok.startsWith("rd.live.dir="))
                    toks ~= tok;
            if (!toks.canFind("rd.live.image"))
                toks = ["rd.live.image"] ~ toks;
            toks ~= "rd.live.dir=" ~ distroDir;
            return toks.join(" ");
        }

        case DistroType.UbuntuCasper:
        {
            string[] toks;
            foreach (tok; base.split())
                if (!tok.startsWith("live-media-path=") && tok != "boot=casper")
                    toks ~= tok;
            return ("boot=casper live-media-path=" ~ distroDir ~ "/casper " ~ toks.join(" ")).strip();
        }

        case DistroType.DebianLive:
        {
            string[] toks;
            foreach (tok; base.split())
                if (!tok.startsWith("live-media-path=") && tok != "boot=live")
                    toks ~= tok;
            return ("boot=live live-media-path=" ~ distroDir ~ "/live " ~ toks.join(" ")).strip();
        }

        case DistroType.ArchISO:
        {
            // Arch's initramfs scans for archisolabel on the device, mounts it,
            // then looks for archisobasedir/<cpu_arch>/airootfs.sfs relative to it.
            // We set archisobasedir to our subdir (no leading slash = relative to device root)
            // and archisolabel to the actual USB volume label.
            string[] toks;
            foreach (tok; base.split())
                if (!tok.startsWith("archisolabel=") && !tok.startsWith("archisobasedir=")
                 && tok != "---")   // Arch uses --- as GRUB/kernel arg separator
                    toks ~= tok;
            toks ~= "archisobasedir=" ~ distroDir.stripLeft("/");
            toks ~= "archisolabel=" ~ (usbLabel.length ? usbLabel : "PETITBOOTUSB");
            return toks.join(" ");
        }

        case DistroType.T2SDE:
        {
            // T2's initrd reads `live=<path>` from the cmdline (default
            // `live.squash`) and looks for that file at the root of the
            // first block device it can mount.  We give it the relative
            // path under our distro dir.
            string relSquash = distroDir.stripLeft("/") ~ "/live.squash";
            return ("live=" ~ relSquash ~ " " ~ base).strip();
        }

        case DistroType.MinimalInstaller:
        case DistroType.Generic:
            return base;
    }
}

// T2/SDE's initrd hardcodes `fs=iso9660` when probing devices for the live
// image, which silently fails on ext4 USBs.  Rewrite that one line to keep
// the disktype-detected filesystem.  Requires zstd and cpio on the host.
//
// Returns true on success, false if the host is missing tooling (caller
// should emit a warning — the entry will copy unmodified and just won't boot).
bool patchT2Initrd(string initrdPath)
{
    import std.process    : execute, spawnProcess, wait, Config;
    import std.file       : tempDir, mkdir, mkdirRecurse, exists, rmdirRecurse,
                            read, write, dirEntries, SpanMode, isDir;
    import std.path       : buildPath, dirName;
    import std.stdio      : File, stdout, stderr;
    import std.conv       : to;
    import std.random     : uniform;
    import std.regex      : regex, replaceAll;

    if (execute(["zstd", "--version"]).status != 0) return false;
    if (execute(["cpio", "--version"]).status != 0) return false;

    auto scratch = buildPath(tempDir(),
                             "petitbootusb-t2-" ~ uniform(0, 1_000_000_000).to!string);
    mkdirRecurse(scratch);

    bool patchOk = patchT2InitrdInner(initrdPath, scratch);

    try rmdirRecurse(scratch);
    catch (Exception) {}

    return patchOk;
}

private bool patchT2InitrdInner(string initrdPath, string scratch)
{
    import std.process    : execute, spawnProcess, wait, Config;
    import std.file       : mkdir, exists, read, write, dirEntries, SpanMode;
    import std.path       : buildPath;
    import std.stdio      : File, stdout, stderr;
    import std.regex      : regex, replaceAll;

    auto cpioPath = buildPath(scratch, "initrd.cpio");
    auto rootDir  = buildPath(scratch, "root");
    mkdir(rootDir);

    // 1. zstd -d  <  initrd  >  cpio
    {
        auto inF  = File(initrdPath, "rb");
        auto outF = File(cpioPath, "wb");
        auto pid  = spawnProcess(["zstd", "-d", "-q"], inF, outF);
        if (wait(pid) != 0) return false;
    }

    // 2. cd root && cpio -i -d --quiet < cpio
    // cpio returns non-zero when it can't mknod device nodes as non-root;
    // we don't care — devtmpfs in T2's init recreates them.  Just verify
    // the files we actually need landed on disk.
    {
        auto inF       = File(cpioPath, "rb");
        auto devnull   = File("/dev/null", "wb");
        auto pid       = spawnProcess(["cpio", "-i", "-d", "--quiet",
                                       "--no-absolute-filenames"],
                                      inF, devnull, devnull,
                                      null, Config.none, rootDir);
        wait(pid);
    }

    // 3. patch /init — drop the `fs=iso9660` line that overrides detection
    auto initFile = buildPath(rootDir, "init");
    if (!exists(initFile)) return false;
    string content = cast(string) read(initFile);
    auto patched   = replaceAll(content,
                                regex(`(?m)^[ \t]*fs=iso9660[ \t]*$`),
                                "    # fs=iso9660  # patched out by petitbootusb");
    if (patched == content) return false;     // nothing changed — pattern moved upstream?
    write(initFile, patched);

    // 4. Walk extracted tree, write the path list to a file, redirect cpio's
    // stdin from it.  Avoids the classic write-stdin / read-stdout deadlock
    // a pipeProcess would hit once cpio's 64 KB stdout buffer fills.
    auto cpioNew  = buildPath(scratch, "initrd.cpio.new");
    auto listPath = buildPath(scratch, "filelist");
    {
        auto lf = File(listPath, "w");
        lf.writeln(".");
        foreach (e; dirEntries(rootDir, SpanMode.breadth, false))
            lf.writeln("." ~ e.name[rootDir.length .. $]);
        lf.close();
    }
    {
        auto inF   = File(listPath, "rb");
        auto outF  = File(cpioNew, "wb");
        auto devnl = File("/dev/null", "wb");
        auto pid   = spawnProcess(["cpio", "-o", "-H", "newc", "--quiet"],
                                  inF, outF, devnl,
                                  null, Config.none, rootDir);
        // cpio -o may report missing /dev nodes — that's OK, see step 2
        wait(pid);
    }

    // 5. zstd  <  cpio.new  >  initrd
    {
        auto inF  = File(cpioNew, "rb");
        auto outF = File(initrdPath, "wb");
        auto pid  = spawnProcess(["zstd", "-q"], inF, outF);
        if (wait(pid) != 0) return false;
    }

    return true;
}

string slugify(string s)
{
    char[] result;
    bool lastDash;
    foreach (dchar c; s.toLower())
    {
        if (isAlphaNum(cast(char) c))
        {
            result ~= cast(char) c;
            lastDash = false;
        }
        else if (!lastDash && result.length)
        {
            result ~= '-';
            lastDash = true;
        }
    }
    while (result.length && result[$ - 1] == '-')
        result = result[0 .. $ - 1];
    return cast(string) result;
}

string deriveName(string isoPath, BootEntry[] entries)
{
    if (entries.length && entries[0].label.length)
        return slugify(entries[0].label);
    return slugify(isoPath.baseName().stripExtension());
}
