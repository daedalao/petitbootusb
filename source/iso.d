module iso;

import std.process;
import std.string;
import std.stdio;
import std.algorithm : map, filter, canFind;
import std.array;
import std.path;
import std.file;

string normalizeISOPath(string raw)
{
    // Strip leading "./" or "/" so we have a clean relative path for bsdtar,
    // but also return a canonical "/"-prefixed form for matching.
    return "/" ~ raw.strip().stripLeft("./").stripLeft("/");
}

string[] listISO(string isoPath)
{
    auto r = execute(["bsdtar", "-tf", isoPath]);
    if (r.status != 0)
        throw new Exception("bsdtar list failed for " ~ isoPath ~ ": " ~ r.output);
    return r.output
            .splitLines()
            .filter!(l => l.strip().length && !l.strip().endsWith("/"))
            .map!normalizeISOPath
            .array;
}

// Read a small file from ISO into a string (for configs).
string readFileFromISO(string isoPath, string isoNormPath)
{
    string bare = isoNormPath.stripLeft("/");
    auto r = execute(["bsdtar", "-xf", isoPath, "-O", bare]);
    if (r.status != 0)
        return null;
    return r.output;
}

// Extract a (potentially large) file from ISO to destPath by streaming bsdtar stdout.
void extractFile(string isoPath, string isoNormPath, string destPath)
{
    mkdirRecurse(destPath.dirName());
    string bare = isoNormPath.stripLeft("/");
    auto dest = File(destPath, "wb");
    auto pid  = spawnProcess(["bsdtar", "-xf", isoPath, "-O", bare],
                             std.stdio.stdin, dest, std.stdio.stderr);
    int status = wait(pid);
    dest.close();
    if (status != 0)
    {
        if (exists(destPath)) remove(destPath);
        throw new Exception("bsdtar extract failed: " ~ isoNormPath ~ " from " ~ isoPath);
    }
}

// Return the first candidate path found in the ISO file list.
string findInISO(string[] files, string[] candidates)
{
    foreach (candidate; candidates)
    {
        auto cLower = candidate.toLower();
        foreach (f; files)
            if (f.toLower() == cLower)
                return f;
    }
    // Second pass: suffix match (handles varying prefix dirs)
    foreach (candidate; candidates)
    {
        auto cLower = candidate.toLower();
        foreach (f; files)
            if (f.toLower().endsWith(cLower))
                return f;
    }
    return null;
}

struct ISOFiles
{
    string kernel;
    string initrd;
    string squashfs;
    string configFile;
    string configContent;
}

ISOFiles inspectISO(string isoPath)
{
    auto files = listISO(isoPath);
    ISOFiles result;

    // Boot configs — grub preferred, isolinux fallback
    result.configFile = findInISO(files, [
        "/boot/grub/grub.cfg",
        "/boot/grub2/grub.cfg",
        "/EFI/BOOT/grub.cfg",
        "/EFI/boot/grub.cfg",
        "/grub/grub.cfg",
        "/grub.cfg",
    ]);
    if (!result.configFile)
        result.configFile = findInISO(files, [
            "/isolinux/isolinux.cfg",
            "/boot/isolinux/isolinux.cfg",
            "/syslinux/syslinux.cfg",
            "/isolinux.cfg",
        ]);

    if (result.configFile)
        result.configContent = readFileFromISO(isoPath, result.configFile);

    // ppc64le kernels are often vmlinux (uncompressed ELF), not vmlinuz.
    // Arch Power uses arch/boot/<arch>/vmlinuz-linux (suffix match covers all arches).
    result.kernel = findInISO(files, [
        "/ppc/ppc64/vmlinuz",           // Fedora ppc64le netinst
        "/ppc/ppc64/vmlinux",
        "/ppc64/vmlinuz",
        "/ppc64/vmlinux",
        "/boot/vmlinux",
        "/boot/vmlinuz",
        "/images/pxeboot/vmlinuz",
        "/casper/vmlinuz",
        "/live/vmlinuz",
        "/live/vmlinux",            // Chimera Linux
        "/vmlinuz-linux",           // Arch Power ppc64le / ppc
        "/vmlinuz-linux-ppc64",     // Arch Power ppc64 BE
        "/vmlinuz-linux-ppc64le",
        "/boot/ibmpower",           // Gentoo powerpc (IBM POWER-specific kernel)
        "/boot/ppc64",              // Gentoo powerpc ppc64
        "/boot/gentoo",             // Gentoo ppc64le
        "/vmlinux",
        "/vmlinuz",
    ]);
    // Fallback: versioned kernel (e.g. T2's boot/vmlinux-6.19.5-t2)
    if (!result.kernel)
        result.kernel = findByPathPrefix(files, ["/boot/vmlinux-", "/boot/vmlinuz-"]);

    result.initrd = findInISO(files, [
        "/ppc/ppc64/initrd.img",
        "/ppc64/initrd.img",
        "/boot/initrd.img",
        "/boot/initramfs.img",
        "/images/pxeboot/initrd.img",
        "/casper/initrd",
        "/casper/initrd.img",
        "/live/initrd",             // Chimera Linux
        "/live/initrd.img",
        "/initramfs-linux.img",         // Arch Power ppc64le / ppc
        "/initramfs-linux-ppc64.img",   // Arch Power ppc64 BE
        "/initramfs-linux-ppc64le.img",
        "/boot/ibmpower.igz",           // Gentoo powerpc
        "/boot/ppc64.igz",              // Gentoo powerpc ppc64
        "/boot/gentoo.igz",             // Gentoo ppc64le
        "/initrd.img",
        "/initrd",
    ]);
    // Fallback: versioned initrd (e.g. T2's boot/initrd-6.19.5-t2)
    if (!result.initrd)
        result.initrd = findByPathPrefix(files, ["/boot/initrd-", "/boot/initramfs-"]);

    result.squashfs = findInISO(files, [
        "/LiveOS/squashfs.img",
        "/casper/filesystem.squashfs",
        "/live/filesystem.squashfs",
        "/live/filesystem.erofs",   // Chimera Linux
        "/airootfs.sfs",            // Arch Power (any arch subdir, suffix match)
        "/image.squashfs",          // Gentoo
        "/live.squash",             // T2/SDE
        "/squashfs.img",
    ]);

    return result;
}

// Find first file whose full ISO path starts with any of the given prefixes.
string findByPathPrefix(string[] files, string[] prefixes)
{
    foreach (prefix; prefixes)
    {
        auto p = prefix.toLower();
        foreach (f; files)
            if (f.toLower().startsWith(p))
                return f;
    }
    return null;
}

// Get sizes of multiple files from one bsdtar -tvf pass.  Returns -1 for any
// path not found.  Order of results matches order of isoNormPaths.
long[] getISOFileSizes(string isoPath, string[] isoNormPaths)
{
    import std.conv : to;
    long[] result = new long[isoNormPaths.length];
    result[] = -1L;

    auto r = execute(["bsdtar", "-tvf", isoPath]);
    if (r.status != 0) return result;

    foreach (line; r.output.splitLines())
    {
        auto parts = line.split();
        if (parts.length < 6) continue;
        // Only regular files — mode field starts with '-'.  Skips symlinks,
        // hardlinks and dirs whose last token is the link target, not the path.
        if (parts[0].length == 0 || parts[0][0] != '-') continue;
        long sz;
        try sz = parts[4].to!long;
        catch (Exception) continue;

        // The last token in bsdtar -tvf is the file path (no spaces in ISO paths).
        string linePath = parts[$ - 1];

        foreach (i, path; isoNormPaths)
        {
            if (!path.length || result[i] >= 0) continue;
            if (linePath == path.stripLeft("/")) { result[i] = sz; break; }
        }
    }
    return result;
}

// Get the size of a single file — kept for callers that only need one.
long getISOFileSize(string isoPath, string isoNormPath)
{
    auto r = getISOFileSizes(isoPath, [isoNormPath]);
    return r[0];
}
