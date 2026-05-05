module tui.ui;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm : min, max, canFind, sort;
import std.format : format;
import std.conv : to;
import core.thread;
import core.atomic;

import tui.term;
import tui.input;
import tui.draw;
import usb;
import iso;
import config;
import distro;

// ── UI state ─────────────────────────────────────────────────────────────────

enum Mode { Normal, EditArgs, EditGlobal, Extracting, Confirm,
            DevicePicker, FileBrowser }

struct UIState
{
    string      usbMount;
    DistroMeta[]distros;
    string      globalArgs;
    int         sel;        // selected index in distro list
    int         scroll;     // list scroll offset

    Mode        mode;
    char[]      inputBuf;   // text input buffer (edit/add modes)
    int         cursor;     // cursor position in inputBuf
    string      statusMsg;
    bool        statusErr;

    // Extraction progress (read from g_ atomics)
    int         spinTick;
    int         syncTicks;     // bumped while g_ext.syncing is true; 0 otherwise

    // Status auto-clear: ticks since statusMsg was set
    int         statusAge;

    // Currently running extraction worker (null when idle)
    Thread      extractThread;

    // Confirm dialog
    string      confirmMsg;
    int         confirmTarget;  // distro index to delete

    // Device picker
    USBDevice[] devices;
    int         deviceSel;

    // File browser
    string      fbPath;         // current directory
    string[]    fbEntries;      // filenames in fbPath (dirs + .iso files)
    long[]      fbSizes;        // parallel size array (-1 for dirs)
    int         fbSel;
    int         fbScroll;
}

// Shared extraction state (written by worker Thread, read by UI)
shared struct ExtractState
{
    int  step;          // 0=inspect 1=kernel 2=initrd 3=squashfs 4=meta
    long bytesWritten;
    long bytesTotal;
    bool syncing;       // bsdtar finished; waiting for fsync to flush to USB
    bool done;
    bool failed;
}
shared ExtractState g_ext;

// Last failure message (separate from atomics — only read once `failed` is set)
__gshared string g_extError;

// Set a status message and reset its age counter.
void setStatus(ref UIState s, string msg, bool err = false)
{
    s.statusMsg = msg;
    s.statusErr = err;
    s.statusAge = 0;
}

// ── Layout helpers ────────────────────────────────────────────────────────────

enum HEADER_ROW  = 1;
enum FOOTER_ROW_KEY = -1;  // rows from bottom
enum MIN_COLS    = 70;
enum MIN_ROWS    = 16;

struct Layout
{
    int rows, cols;
    int divCol;      // column of the │ divider (1-based)
    int contentTop;  // first content row (inside top border)
    int contentBot;  // last content row (inside bottom border)
    int listW;       // usable list panel chars
    int detailX;     // first column of detail content
    int detailW;     // usable detail panel chars
}

Layout calcLayout(TermSize ts)
{
    Layout l;
    l.rows = ts.rows;
    l.cols = ts.cols;
    l.divCol    = max(34, min(44, ts.cols * 2 / 5));
    l.contentTop = 2;
    l.contentBot = ts.rows - 3;
    l.listW      = l.divCol - 2;
    l.detailX    = l.divCol + 2;
    l.detailW    = ts.cols - l.divCol - 3;
    return l;
}

// ── Rendering ─────────────────────────────────────────────────────────────────

void renderHeader(ref Frame f, ref UIState s, ref Layout l)
{
    // Full-width background strip
    f.fill(1, 1, l.cols, BG_TITLE ~ FG_NORM);

    // App name + version
    f.at(1, 2);
    f.put(BG_TITLE ~ FG_ACCENT ~ BOLD ~ "petitbootusb" ~ RESET ~ BG_TITLE ~ FG_DIM ~ " v0.1");

    // Stats on the right (compute first so we know how much room USB path has)
    int le = 0, be = 0, uk = 0;
    foreach (d; s.distros) {
        if (d.endian == "le") le++;
        else if (d.endian == "be") be++;
        else uk++;
    }
    string stats = format(" %d distro%s", s.distros.length, s.distros.length == 1 ? "" : "s");
    if (le) stats ~= format("  " ~ FG_LE ~ "LE:%d" ~ FG_DIM, le);
    if (be) stats ~= format("  " ~ FG_BE ~ "BE:%d" ~ FG_DIM, be);
    if (uk) stats ~= format("  ?: %d", uk);
    int statsW = cast(int) stripAnsi(stats).length;
    int statX  = l.cols - statsW - 1;

    // USB path — truncate so it doesn't overlap stats
    int usbMax = max(0, statX - 22);
    string usbDisp = trunc(s.usbMount, usbMax);
    f.at(1, 20);
    f.put(BG_TITLE ~ FG_DIM ~ " │ " ~ usbDisp);

    f.at(1, max(40, statX));
    f.put(BG_TITLE ~ FG_DIM ~ stats);
    f.reset();
}

void renderFooter(ref Frame f, ref UIState s, ref Layout l)
{
    int sep = l.rows - 2;
    int bot = l.rows - 1;

    // Separator
    f.at(sep, 1);
    f.put(FG_BORDER ~ BG_PANEL ~ ML);
    foreach (_; 2 .. l.cols) f.put(HL);
    f.put(MR);

    // Key bar
    f.fill(bot, 1, l.cols, BG_TITLE ~ FG_NORM);
    f.at(bot, 2);
    f.put(BG_TITLE);

    void key(string k, string desc)
    {
        f.put(BOLD ~ FG_KEY ~ k ~ RESET ~ BG_TITLE ~ FG_KDESC ~ " " ~ desc ~ "  ");
    }

    final switch (s.mode)
    {
        case Mode.Normal:
            key("A", "Add ISO");
            key("U", "USB device");
            key("D", "Delete");
            key("E", "Edit args");
            key("G", "Global args");
            key("R", "Regenerate");
            key("↑↓", "Navigate");
            key("Q", "Quit");
            break;
        case Mode.EditArgs, Mode.EditGlobal:
            key("Enter", "Save");
            key("Esc", "Cancel");
            key("Ctrl+U", "Clear");
            break;
        case Mode.Extracting:
            key("Ctrl+C", "Abort");
            break;
        case Mode.Confirm:
            key("Y", "Confirm delete");
            key("N / Esc", "Cancel");
            break;
        case Mode.DevicePicker:
            key("↑↓", "Navigate");
            key("Enter", "Select");
            key("R", "Rescan");
            key("Q", "Quit");
            break;
        case Mode.FileBrowser:
            key("↑↓", "Navigate");
            key("Enter", "Open/Select");
            key("Bksp", "Up dir");
            key("Esc", "Cancel");
            break;
    }

    // Status message on right
    if (s.statusMsg.length)
    {
        string col = s.statusErr ? FG_ERR : FG_OK;
        // Truncate the message to whatever space we have left after the keys.
        int avail = max(20, l.cols - 50);
        string msg = trunc(s.statusMsg, avail);
        int msgX  = l.cols - cast(int) msg.length - 2;
        if (msgX > 1)
        {
            f.fill(bot, msgX, cast(int) msg.length + 1, BG_TITLE);
            f.at(bot, msgX);
            f.put(BG_TITLE ~ col ~ BOLD ~ msg);
        }
    }

    f.reset();
}

void renderList(ref Frame f, ref UIState s, ref Layout l)
{
    int visRows = l.contentBot - l.contentTop + 1;

    // Clamp scroll
    if (s.sel < s.scroll) s.scroll = s.sel;
    if (s.sel >= s.scroll + visRows) s.scroll = s.sel - visRows + 1;
    if (s.scroll < 0) s.scroll = 0;

    foreach (vi; 0 .. visRows)
    {
        int di = vi + s.scroll;
        int row = l.contentTop + vi;

        if (di >= cast(int) s.distros.length)
        {
            f.fill(row, 2, l.listW, BG_PANEL);
            continue;
        }

        auto d = s.distros[di];
        bool sel = (di == s.sel);

        string rowBg = sel ? BG_SEL : BG_PANEL;
        string rowFg = sel ? FG_SEL  : FG_NORM;

        // Selector
        f.at(row, 2);
        f.put(rowBg);
        f.put(sel ? (FG_OK ~ BOLD ~ "▸ " ~ RESET ~ rowBg ~ rowFg)
                  : (FG_DIM ~ "  " ~ rowFg));

        // Name — truncated to leave room for badge
        int badgeW = 5;  // " [LE]"
        string name = trunc(d.label, l.listW - badgeW - 2);
        f.put(rowFg ~ pad(name, l.listW - badgeW - 2));

        // Endian badge
        string badge, badgeColor;
        if (d.endian == "be") { badge = "[BE]"; badgeColor = FG_BE; }
        else if (d.endian == "le") { badge = "[LE]"; badgeColor = FG_LE; }
        else { badge = "[??]"; badgeColor = FG_DIM; }
        f.put(" " ~ badgeColor ~ (sel ? BOLD : "") ~ badge);

        f.reset();
    }

    // Scroll indicators
    if (s.scroll > 0)
        f.text(l.contentTop, l.divCol - 2, 2, FG_DIM ~ BG_PANEL, " ▲");
    if (s.scroll + visRows < cast(int) s.distros.length)
        f.text(l.contentBot, l.divCol - 2, 2, FG_DIM ~ BG_PANEL, " ▼");
}

void renderDetail(ref Frame f, ref UIState s, ref Layout l)
{
    if (s.distros.length == 0)
    {
        f.text(l.contentTop + 1, l.detailX, l.detailW,
               FG_DIM ~ BG_PANEL ~ ITALIC, "No distros registered. Press A to add an ISO.");
        return;
    }

    auto d = s.distros[s.sel];
    int row = l.contentTop;
    int x   = l.detailX;
    int w   = l.detailW;

    void label(string k) {
        f.text(row, x, w, BG_PANEL ~ FG_LABEL ~ BOLD, k);
    }
    void value(string v, string col = "") {
        f.text(row, x + 2, max(0, w - 2), BG_PANEL ~ (col.length ? col : FG_NORM), v);
        row++;
    }
    void blank() { f.fill(row++, x, w, BG_PANEL); }

    // ── Label
    label("Label");  row++;
    value(trunc(d.label, w - 2));
    blank();

    // ── Endian
    label("Endian"); row++;
    if      (d.endian == "le") value("▼ Little-endian (ppc64le)", FG_LE);
    else if (d.endian == "be") value("▲ Big-endian (ppc64)", FG_BE);
    else                       value("Unknown", FG_DIM);
    blank();

    // ── Kernel
    label("Kernel"); row++;
    value(trunc(d.kernel, w - 2), FG_PATH);
    blank();

    // ── Initrd
    label("Initrd"); row++;
    value(trunc(d.initrd, w - 2), FG_PATH);
    blank();

    // ── Args
    label("Args"); row++;
    bool editingArgs = (s.mode == Mode.EditArgs);
    if (editingArgs)
    {
        // Show input box
        f.fill(row, x, w, BG_INPUT);
        string buf = (cast(string) s.inputBuf);
        // Show with cursor
        string vis = trunc(buf, w - 2);
        f.at(row, x + 1);
        f.put(BG_INPUT ~ FG_WARN ~ vis);
        // Cursor position
        int curX = min(cast(int) vis.length, s.cursor);
        f.at(row, x + 1 + curX);
        f.put(SHOW_CURSOR);
        row++;
    }
    else
    {
        if (d.args.length)
        {
            foreach (line; wrapArgs(d.args, w - 2))
            {
                if (row > l.contentBot - 4) { f.text(row++, x+2, w-2, BG_PANEL~FG_DIM, "..."); break; }
                value(line, FG_WARN);
            }
        }
        else value("(none)", FG_DIM);
    }
    blank();

    // ── Global args
    if (row <= l.contentBot - 2)
    {
        label("Global args"); row++;
        bool editingGlobal = (s.mode == Mode.EditGlobal);
        if (editingGlobal)
        {
            f.fill(row, x, w, BG_INPUT);
            string vis = trunc(cast(string) s.inputBuf, w - 2);
            f.at(row, x + 1);
            f.put(BG_INPUT ~ FG_WARN ~ vis);
            int curX = min(cast(int) vis.length, s.cursor);
            f.at(row, x + 1 + curX);
            f.put(SHOW_CURSOR);
            row++;
        }
        else
        {
            if (s.globalArgs.length)
                foreach (line; wrapArgs(s.globalArgs, w - 2))
                {
                    if (row > l.contentBot) break;
                    value(line, FG_WARN);
                }
            else value("(none)", FG_DIM);
        }
    }

    // Fill remaining rows
    while (row <= l.contentBot)
        f.fill(row++, x, w, BG_PANEL);
}

void renderOuterBox(ref Frame f, ref Layout l)
{
    int r = l.rows;
    int c = l.cols;

    // Top border (row 2)
    f.at(2, 1);
    f.put(FG_BORDER ~ BG_PANEL ~ TL);
    foreach (ci; 2 .. c - 1)
        f.put(ci == l.divCol ? MT : HL);
    f.put(TR);

    // Bottom border (row r-2)
    f.at(r - 2, 1);
    f.put(FG_BORDER ~ BG_PANEL ~ BL);
    foreach (_; 2 .. c) f.put(HL);
    // No BR — footer sep draws its own
    f.reset();
}

void renderExtractProgress(ref Frame f, ref UIState s, ref Layout l)
{
    int bh = 11, bw = min(80, l.cols - 4);
    int br = (l.rows - bh) / 2;
    int bc = (l.cols - bw) / 2;

    f.box(br, bc, bh, bw, "Adding ISO", BG_DIALOG);

    int  step    = atomicLoad(g_ext.step);
    long bw2     = atomicLoad(g_ext.bytesWritten);
    long bt      = atomicLoad(g_ext.bytesTotal);
    bool syncing = atomicLoad(g_ext.syncing);
    bool done    = atomicLoad(g_ext.done);
    bool fail    = atomicLoad(g_ext.failed);

    immutable string[] stepLabels = [
        "Scanning ISO",
        "Extracting kernel",
        "Extracting initrd",
        "Extracting rootfs",
        "Writing metadata",
    ];
    string stepLabel = (step >= 0 && step < cast(int) stepLabels.length)
                       ? stepLabels[step] : "Working";
    if (syncing) stepLabel = "Syncing to USB";

    int innerW = bw - 2;

    // Step label + spinner (spinTick is bumped by the main loop, not here)
    f.at(br + 2, bc + 2);
    f.put(BG_DIALOG ~ FG_ACCENT ~ BOLD ~ f.spin(s.spinTick) ~ "  " ~ RESET
          ~ BG_DIALOG ~ FG_NORM ~ stepLabel);

    // Step counter right-aligned
    string stepNum = format("(%d/5)", step + 1);
    f.at(br + 2, bc + bw - cast(int) stepNum.length - 2);
    f.put(BG_DIALOG ~ FG_DIM ~ stepNum);

    // Clear the rows we're about to draw
    f.fill(br + 3, bc + 1, innerW, BG_DIALOG);
    f.fill(br + 4, bc + 1, innerW, BG_DIALOG);
    f.fill(br + 5, bc + 1, innerW, BG_DIALOG);

    // Overall progress — 5 steps × 20% each.  Within a step, extract phase
    // fills the first 80% of that 20% slice (bytes/total), sync phase fills
    // the remaining 20% on a tick-based animation so the bar visibly creeps
    // even when bsdtar is done and we're stuck in fsync.
    float subPct;
    if (syncing)
    {
        // ~30 seconds for the sync portion of the step to fill.  fsync of a
        // big rootfs can take longer; we just cap at 1.0 so the bar pins at
        // the step boundary until fsync finishes and step advances.
        float syncAnim = cast(float) s.syncTicks / 300.0f;
        if (syncAnim > 1.0f) syncAnim = 1.0f;
        subPct = 0.8f + 0.2f * syncAnim;
    }
    else if (bt > 0)
    {
        float realPct = cast(float) bw2 / bt;
        if (realPct > 1.0f) realPct = 1.0f;
        subPct = realPct * 0.8f;        // extract phase = first 80% of step
    }
    else
        subPct = 0.0f;

    float overallPct = (cast(float) step + subPct) / 5.0f;
    if (overallPct > 0.99f) overallPct = 0.99f;

    int barW = innerW - 4;
    int barX = bc + 3;
    f.progressBar(br + 4, barX, barW, overallPct, BG_DIALOG);

    // Quip line above the bar — rotates throughout the entire extraction
    // so the user sees variety regardless of how quick a particular phase
    // (kernel/initrd/sync) actually takes.
    {
        immutable string[] quips = [
                // Hardware / kernel reality
                "syncing to USB",
                "flushing dirty pages",
                "writing through to flash",
                "draining the page cache",
                "convincing the kernel to commit",
                "USB is slower than RAM, hold on",
                "wrangling bytes onto the drive",
                "this would be faster on NVMe",
                "the kernel is taking its time",
                "patiently waiting on hardware",
                "almost there, the I/O is what it is",
                "asking nicely for one last write",
                "your USB stick has feelings too",
                "calling the police",
                "you're not dealing with at&t",
                // Technical snark
                "Bargaining with the garbage collector.",
                "Counting bits. One... zero... one... ish.",
                "Locating the magic smoke.",
                "Wait, I thought we were using the cloud?",
                "Buffering... because physics is a thing.",
                "Teaching the electrons to stay in a straight line.",
                "Poking the CPU to make sure it's still awake.",
                "Calculating the meaning of life (and some file offsets).",
                "Asking the BIOS for permission to exist.",
                "Ignoring the 'Unsafe Removal' warnings from last time.",
                // Pop culture
                "Generating more Vespene Gas.",
                "Constructing additional pylons.",
                "Compensating for the Flux Capacitor.",
                "Calibrating the Normandy's sensors.",
                "Checking for glitches in the Matrix.",
                "Searching for a sense of pride and accomplishment.",
                "Loading... please don't look directly at the pixels.",
                "It's dangerous to go alone! Take this progress bar.",
                "Attempting to bypass the main compressor.",
                "Spinning up the infinite improbability drive.",
                "Reticulating splines.",
                // Absurdist
                "The bits are being very shy today.",
                "Entropy isn't what it used to be.",
                "I'd go faster, but I have a headache.",
                "Actually, let's just pretend this is working.",
                "Applying the law of diminishing returns.",
                "Sending thoughts and prayers to the write buffer.",
                "Mining bitcoin.",
                "Mining ethereum, post-merge.",
                "Mining dogecoin. Much wow.",
                "Validating blocks on the chain.",
                "HODLing through the I/O wait.",
                "Calculating gas fees... they're outrageous.",
                "Questioning the nature of my own reality.",
                // Dev life
                "Scanning for unhelpful StackOverflow threads.",
                "Fixing the bug I introduced five minutes ago.",
                "LGTM (Let's Get This Moving).",
                "Inheriting from a class with no future.",
                "Applying 1,000 layers of abstraction.",
                "Waiting for the CI to find a reason to fail.",
                "It worked on my machine.",
                "Have you tried docker-composing it?",
                "git blame /dev/sdb",
                "Pull request from the kernel: 'please wait'.",
                "Reading the documentation we should have written.",
                "Refactoring the cosmic background radiation.",
                // More hardware/kernel
                "Negotiating with the page cache.",
                "Defragging your patience.",
                "Spinning rust would be faster than this.",
                "Bytes don't move themselves... apparently.",
                "If only I had a faster bus.",
                "Doing the I/O scheduler's job for it.",
                "PCIe lanes are slower than I'd like.",
                "The DMA controller and I aren't on speaking terms.",
                // More pop culture
                "Have you tried turning it off and on again?",
                "I'm sorry Dave, I'm afraid I can't do that.",
                "It's super effective!",
                "Critical hit on the kernel buffer.",
                "Press F to pay respects to the page cache.",
                "Rolling for initiative against I/O wait.",
                "It's a-me, fsync.",
                "Gotta sync 'em all.",
                "All your bytes are belong to USB.",
                "Insert disc 2.",
                "Use the source, Luke.",
                "Resistance is fsync.",
                // More absurdist
                "Plotting a hostile takeover of /dev/null.",
                "Briefly contemplating retirement.",
                "The squashfs is having a midlife crisis.",
                "Counting sheep. Currently at 1.2 million.",
                "Searching for the meaning of life. Found 42 bytes.",
                "Wondering why this isn't async.",
                "Maybe I should learn Rust for this.",
                // Treknobabble
                "Reversing the polarity of the neutron flow.",
                "Recalibrating the deflector dish.",
                "Modulating the warp field harmonics.",
                "Routing power through the EPS conduits.",
                "Engaging the Heisenberg compensators.",
                "Realigning the dilithium matrix.",
                "Initiating a level-3 diagnostic.",
                "The Borg are assimilating the page cache.",
                "Tea, Earl Grey, hot.",
                "Make it so.",
                "Computer? Computer.",
                "Set bytes to stun.",
                "She cannae take much more, Captain.",
                // Galaxy Quest
                "By Grabthar's hammer, you shall be synced.",
                "Never give up, never surrender!",
                "Activating the Omega 13.",
                "Question: what is the deal with this drive?",
                "Did you guys ever WATCH the show?",
            ];

        // Murmur-style hash on the 5-second tick, scatters consecutive
        // values to look random.
        uint h = cast(uint)(s.spinTick / 50);
        h = (h ^ (h >> 16)) * 0x85ebca6b;
        h = (h ^ (h >> 13)) * 0xc2b2ae35;
        h =  h ^ (h >> 16);
        int qi = cast(int)(h % cast(uint) quips.length);
        string quipText = quips[qi];

        string vquip = trunc(quipText, innerW);
        int qx = bc + 1 + max(0, (innerW - cast(int) vquip.length) / 2);
        f.at(br + 3, qx);
        f.put(BG_DIALOG ~ FG_WARN ~ vquip);
    }

    // Bytes / sync label, centred on the row below the bar
    {
        string label;
        if (syncing)
            label = format("syncing %d MB to USB", bt >> 20);
        else if (bt > 0)
            label = format("%d / %d MB written", bw2 >> 20, bt >> 20);
        else
            label = stepLabel;

        string visible = trunc(label, innerW);
        int labelX = bc + 1 + max(0, (innerW - cast(int) visible.length) / 2);
        f.at(br + 5, labelX);
        f.put(BG_DIALOG ~ FG_DIM ~ visible);
    }

    // Status row
    if (fail)
    {
        f.at(br + 7, bc + 2);
        f.put(BG_DIALOG ~ FG_ERR ~ BOLD ~ "Extraction failed — check terminal output.");
    }
    else if (done)
    {
        f.at(br + 7, bc + 2);
        f.put(BG_DIALOG ~ FG_OK ~ BOLD ~ "Done!  grub.cfg updated.");
    }
    else
    {
        f.at(br + 7, bc + 2);
        f.put(BG_DIALOG ~ FG_DIM ~ "Ctrl+C to abort");
    }

    f.reset();
}

void renderFileBrowser(ref Frame f, ref UIState s, ref Layout l)
{
    int bh = min(l.rows - 4, 22), bw = min(l.cols - 4, 76);
    int br = (l.rows - bh) / 2;
    int bc = (l.cols - bw) / 2;

    f.box(br, bc, bh, bw, "Select ISO", BG_DIALOG);

    // Layout (column-relative to box left edge bc):
    //   col bc       : left  border │
    //   col bc+1..   : 1-char left margin
    //   col bc+2..   : name field (nameW chars)
    //   col bc+...   : 2-char gap
    //   col bc+...   : size field (6 chars)
    //   col bc+bw-2  : 1-char right margin
    //   col bc+bw-1  : right border │
    //
    // Total inner width = bw - 2 = 1 + nameW + 2 + 6 + 1  →  nameW = bw - 12
    int innerW = bw - 2;
    int nameW  = innerW - 10;             // -1 left margin -2 gap -6 size -1 right margin
    int sizeW  = 6;
    int sizeX  = bc + 1 + 1 + nameW + 2;  // start column of size field

    // Path on the row just inside the top border
    f.at(br + 1, bc + 2);
    f.put(BG_DIALOG ~ FG_DIM ~ trunc(s.fbPath, innerW - 2));

    // List occupies rows br+2 .. br+bh-3 (footer is at br+bh-2)
    int listTop  = br + 2;
    int listRows = (br + bh - 3) - listTop + 1;

    if (s.fbSel < s.fbScroll) s.fbScroll = s.fbSel;
    if (s.fbSel >= s.fbScroll + listRows) s.fbScroll = s.fbSel - listRows + 1;
    if (s.fbScroll < 0) s.fbScroll = 0;

    foreach (vi; 0 .. listRows)
    {
        int ei  = vi + s.fbScroll;
        int row = listTop + vi;

        // Always paint the full row background first — guarantees no leftover columns
        f.fill(row, bc + 1, innerW, BG_DIALOG);

        if (ei >= cast(int) s.fbEntries.length) continue;

        bool   sel    = (ei == s.fbSel);
        string entry  = s.fbEntries[ei];
        long   sz     = s.fbSizes[ei];
        bool   isDir  = (sz < 0);

        string rowBg = sel ? BG_SEL : BG_DIALOG;
        string rowFg = sel ? FG_SEL : (isDir ? FG_ACCENT : FG_NORM);

        // Size field: exactly 6 chars
        string sizeStr;
        if (isDir)              sizeStr = "      ";
        else if (sz >= 1L << 30) sizeStr = format("%5.1fG", cast(float)sz / (1L << 30));
        else                     sizeStr = format("%5.0fM", cast(float)sz / (1L << 20));
        if (sizeStr.length > sizeW) sizeStr = sizeStr[0 .. sizeW];

        // Selection highlight spans the full inner width
        if (sel) f.fill(row, bc + 1, innerW, BG_SEL);

        // Name field (left-padded to nameW so the size column always lines up)
        f.at(row, bc + 2);
        f.put(rowBg ~ rowFg ~ pad(trunc(entry, nameW), nameW));

        // Size field
        f.at(row, sizeX);
        f.put(rowBg ~ FG_DIM ~ sizeStr);

        f.reset();
    }

    // Footer hint, one row above the bottom border
    f.fill(br + bh - 2, bc + 1, innerW, BG_DIALOG);
    f.at(br + bh - 2, bc + 2);
    f.put(BG_DIALOG ~ BOLD ~ FG_KEY ~ "Enter" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " select   "
          ~ BOLD ~ FG_KEY ~ "Bksp" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " up   "
          ~ BOLD ~ FG_KEY ~ "Esc"  ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " cancel");
    f.reset();
}

void renderDevicePicker(ref Frame f, ref UIState s, ref Layout l)
{
    int rowsForList = max(1, cast(int) s.devices.length);
    int bh = min(rowsForList + 6, l.rows - 4);
    int bw = min(l.cols - 4, 76);
    int br = (l.rows - bh) / 2;
    int bc = (l.cols - bw) / 2;

    f.box(br, bc, bh, bw, "Select USB Device", BG_DIALOG);

    int innerW = bw - 2;

    // Header text
    f.fill(br + 1, bc + 1, innerW, BG_DIALOG);
    f.at(br + 1, bc + 2);
    f.put(BG_DIALOG ~ FG_DIM ~ trunc("Choose the USB drive to use as boot media:", innerW - 2));

    int listTop = br + 3;
    int listBot = br + bh - 3;

    if (s.devices.length == 0)
    {
        f.fill(listTop, bc + 1, innerW, BG_DIALOG);
        f.at(listTop, bc + 2);
        f.put(BG_DIALOG ~ FG_ERR ~ trunc("No removable devices found.  Plug in USB and press R to rescan.", innerW - 2));
    }
    else
    {
        foreach (size_t i, ref dev; s.devices)
        {
            int row = listTop + cast(int) i;
            if (row > listBot) break;

            bool   sel   = (cast(int) i == s.deviceSel);
            string rowBg = sel ? BG_SEL : BG_DIALOG;
            string rowFg = sel ? FG_SEL : FG_NORM;

            // Full-width row background
            f.fill(row, bc + 1, innerW, rowBg);

            // Selector marker
            f.at(row, bc + 2);
            f.put(rowBg ~ (sel ? FG_OK ~ BOLD ~ "▸ " ~ RESET ~ rowBg ~ rowFg : "  "));

            string label = dev.label.length ? dev.label : "(no label)";
            string line  = format("%-10s  %6s  %-18s  %s",
                                  dev.device, dev.size, label, dev.mountpoint);
            f.put(rowFg ~ trunc(line, innerW - 6));
            f.reset();
        }
    }

    // Footer
    f.fill(br + bh - 2, bc + 1, innerW, BG_DIALOG);
    f.at(br + bh - 2, bc + 2);
    f.put(BG_DIALOG ~ BOLD ~ FG_KEY ~ "Enter" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " select   "
          ~ BOLD ~ FG_KEY ~ "R" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " rescan   "
          ~ BOLD ~ FG_KEY ~ "Q" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " quit");
    f.reset();
}

void renderConfirm(ref Frame f, ref UIState s, ref Layout l)
{
    int bh = 6, bw = min(52, l.cols - 4);
    int br = (l.rows - bh) / 2;
    int bc = (l.cols - bw) / 2;

    f.box(br, bc, bh, bw, "Confirm Delete", BG_DIALOG);

    f.at(br + 2, bc + 2);
    f.put(BG_DIALOG ~ FG_ERR ~ BOLD ~ "Delete: " ~ RESET ~ BG_DIALOG ~ FG_NORM
          ~ trunc(s.confirmMsg, bw - 12));

    f.at(br + 3, bc + 2);
    f.put(BG_DIALOG ~ FG_DIM ~ "This removes the distro files from the USB.");

    f.at(br + 4, bc + 2);
    f.put(BG_DIALOG ~ BOLD ~ FG_KEY ~ "Y" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " Confirm    "
          ~ BOLD ~ FG_KEY ~ "N" ~ RESET ~ BG_DIALOG ~ FG_KDESC ~ " Cancel");

    f.reset();
}

// ── Main render ───────────────────────────────────────────────────────────────

void render(ref Frame f, ref UIState s, TermSize ts)
{
    f.begin(ts);
    auto l = calcLayout(ts);

    renderHeader(f, s, l);
    renderOuterBox(f, l);

    // Divider
    f.vdiv(l.contentTop, l.contentBot, l.divCol);

    renderList(f, s, l);
    renderDetail(f, s, l);
    renderFooter(f, s, l);

    // Overlay modes
    switch (s.mode)
    {
        case Mode.Extracting:   renderExtractProgress(f, s, l);  break;
        case Mode.Confirm:      renderConfirm(f, s, l);          break;
        case Mode.FileBrowser:  renderFileBrowser(f, s, l);      break;
        case Mode.DevicePicker: renderDevicePicker(f, s, l);     break;
        default: break;
    }

    bool needCursor = (s.mode == Mode.EditArgs || s.mode == Mode.EditGlobal);
    f.flush(needCursor);
}

// ── Input handlers ────────────────────────────────────────────────────────────

// Simple line-editor for inputBuf.
bool handleLineEdit(ref UIState s, KeyEvent k)
{
    switch (k.key)
    {
        case Key.Char:
            s.inputBuf ~= k.ch;
            s.cursor = cast(int) s.inputBuf.length;
            break;
        case Key.Backspace:
            if (s.inputBuf.length) { s.inputBuf = s.inputBuf[0 .. $ - 1]; s.cursor--; }
            break;
        case Key.CtrlU:
            s.inputBuf = []; s.cursor = 0;
            break;
        default: break;
    }
    return true;
}

bool handleNormal(ref UIState s, KeyEvent k)
{
    if (k.key == Key.Char)
    {
        switch (k.ch)
        {
            case 'q', 'Q': return false;

            case 'j': goto case;
            case 'J': s.sel = min(s.sel + 1, cast(int) s.distros.length - 1); break;
            case 'k': goto case;
            case 'K': s.sel = max(s.sel - 1, 0); break;

            case 'a', 'A':
                s.mode    = Mode.FileBrowser;
                s.fbPath  = getcwd();
                refreshFileBrowser(s);
                break;

            case 'u', 'U':
                s.mode      = Mode.DevicePicker;
                s.devices   = scanUSBDevices();
                s.deviceSel = 0;
                break;

            case 'd', 'D':
                if (s.distros.length)
                {
                    s.mode = Mode.Confirm;
                    s.confirmMsg = s.distros[s.sel].label;
                    s.confirmTarget = s.sel;
                }
                break;

            case 'e', 'E':
                if (s.distros.length)
                {
                    s.mode = Mode.EditArgs;
                    auto args = s.distros[s.sel].args;
                    s.inputBuf = cast(char[]) args.dup;
                    s.cursor = cast(int) s.inputBuf.length;
                }
                break;

            case 'g', 'G':
                s.mode = Mode.EditGlobal;
                s.inputBuf = cast(char[]) s.globalArgs.dup;
                s.cursor = cast(int) s.inputBuf.length;
                break;

            case 'r', 'R':
                try {
                    regenerate(s.usbMount);
                    setStatus(s, "grub.cfg regenerated");
                } catch (Exception e) {
                    setStatus(s, e.msg, true);
                }
                break;

            default: break;
        }
    }
    else if (k.key == Key.Up)   s.sel = max(s.sel - 1, 0);
    else if (k.key == Key.Down) s.sel = min(s.sel + 1, cast(int) s.distros.length - 1);

    return true;
}

bool handleEditArgs(ref UIState s, KeyEvent k)
{
    if (k.key == Key.Enter)
    {
        auto name = s.distros[s.sel].name;
        auto path = metaPath(s.usbMount, name);
        if (exists(path))
        {
            auto meta = readMeta(path);
            meta.args = (cast(string) s.inputBuf).strip();
            writeMeta(s.usbMount, meta);
            s.distros[s.sel] = meta;
        }
        try regenerate(s.usbMount);
        catch (Exception) {}
        setStatus(s, "Args saved. grub.cfg updated.");
        s.mode = Mode.Normal;
        return true;
    }
    if (k.key == Key.Escape) { s.mode = Mode.Normal; return true; }
    return handleLineEdit(s, k);
}

bool handleEditGlobal(ref UIState s, KeyEvent k)
{
    if (k.key == Key.Enter)
    {
        s.globalArgs = (cast(string) s.inputBuf).strip();
        writeGlobalArgs(s.usbMount, s.globalArgs);
        try regenerate(s.usbMount);
        catch (Exception) {}
        setStatus(s, "Global args saved. grub.cfg updated.");
        s.mode = Mode.Normal;
        return true;
    }
    if (k.key == Key.Escape) { s.mode = Mode.Normal; return true; }
    return handleLineEdit(s, k);
}

bool handleConfirm(ref UIState s, KeyEvent k)
{
    if (k.key == Key.Char && (k.ch == 'y' || k.ch == 'Y'))
    {
        try {
            removeDistro(s.usbMount, s.distros[s.confirmTarget].name);
            s.distros = listDistros(s.usbMount);
            s.sel = min(s.sel, cast(int) s.distros.length - 1);
            if (s.sel < 0) s.sel = 0;
            setStatus(s, "Distro removed.");
        } catch (Exception e) {
            setStatus(s, e.msg, true);
        }
        s.mode = Mode.Normal;
    }
    else if (k.key == Key.Escape || (k.key == Key.Char && (k.ch == 'n' || k.ch == 'N')))
        s.mode = Mode.Normal;
    return true;
}

// Kick off an extraction in a background thread.  Returns false if a previous
// extraction is still running (e.g. user aborted but bsdtar hasn't exited).
bool startExtraction(ref UIState s, string isoPath)
{
    if (s.extractThread !is null && s.extractThread.isRunning())
    {
        setStatus(s, "Previous extraction still running — wait for it to finish", true);
        return false;
    }

    s.mode = Mode.Extracting;
    s.spinTick = 0;
    atomicStore(g_ext.step, 0);
    atomicStore(g_ext.bytesWritten, 0L);
    atomicStore(g_ext.bytesTotal, 0L);
    atomicStore(g_ext.done, false);
    atomicStore(g_ext.failed, false);

    string usbM = s.usbMount;
    string iso_ = isoPath;
    s.extractThread = new Thread({ doExtract(usbM, iso_); });
    s.extractThread.isDaemon = true;
    s.extractThread.start();
    return true;
}

// ── File browser helpers ──────────────────────────────────────────────────────

void refreshFileBrowser(ref UIState s)
{
    s.fbEntries = [];
    s.fbSizes   = [];
    s.fbSel     = 0;
    s.fbScroll  = 0;

    try {
        if (s.fbPath != "/") { s.fbEntries ~= ".."; s.fbSizes ~= -1L; }

        string[] dirs_, isos_;
        foreach (entry; dirEntries(s.fbPath, SpanMode.shallow))
        {
            if (entry.isDir) dirs_ ~= entry.name.baseName();
            else if (entry.name.length >= 4 &&
                     entry.name[$ - 4 .. $].toLower() == ".iso")
                isos_ ~= entry.name.baseName();
        }
        sort(dirs_);
        sort(isos_);

        foreach (d; dirs_) { s.fbEntries ~= d ~ "/"; s.fbSizes ~= -1L; }
        foreach (i; isos_)
        {
            s.fbEntries ~= i;
            try   s.fbSizes ~= getSize(buildPath(s.fbPath, i));
            catch (Exception) s.fbSizes ~= -1L;
        }
    } catch (Exception) {}
}

bool handleFileBrowser(ref UIState s, KeyEvent k)
{
    if (k.key == Key.Up   || (k.key == Key.Char && k.ch == 'k'))
        s.fbSel = max(s.fbSel - 1, 0);
    else if (k.key == Key.Down || (k.key == Key.Char && k.ch == 'j'))
        s.fbSel = min(s.fbSel + 1, cast(int) s.fbEntries.length - 1);
    else if (k.key == Key.Enter && s.fbEntries.length)
    {
        string entry = s.fbEntries[s.fbSel];
        long   sz    = s.fbSizes[s.fbSel];
        if (sz < 0)
        {
            // directory
            if (entry == "..") s.fbPath = s.fbPath.dirName();
            else               s.fbPath = buildPath(s.fbPath, entry[0 .. $ - 1]);
            refreshFileBrowser(s);
        }
        else
        {
            string isoPath = buildPath(s.fbPath, entry);
            startExtraction(s, isoPath);
        }
    }
    else if (k.key == Key.Backspace)
    {
        if (s.fbPath != "/") { s.fbPath = s.fbPath.dirName(); refreshFileBrowser(s); }
    }
    else if (k.key == Key.Escape)
        s.mode = Mode.Normal;
    return true;
}

bool handleDevicePicker(ref UIState s, KeyEvent k)
{
    if (k.key == Key.Up   || (k.key == Key.Char && k.ch == 'k'))
        s.deviceSel = max(s.deviceSel - 1, 0);
    else if (k.key == Key.Down || (k.key == Key.Char && k.ch == 'j'))
        s.deviceSel = min(s.deviceSel + 1, cast(int) s.devices.length - 1);
    else if (k.key == Key.Enter && s.devices.length)
    {
        s.usbMount   = s.devices[s.deviceSel].mountpoint;
        s.distros    = listDistros(s.usbMount);
        s.globalArgs = readGlobalArgs(s.usbMount);
        s.mode       = Mode.Normal;
        setStatus(s, "Using " ~ s.usbMount);
    }
    else if (k.key == Key.Char && (k.ch == 'r' || k.ch == 'R'))
    {
        s.devices   = scanUSBDevices();
        s.deviceSel = 0;
    }
    else if (k.key == Key.Char && (k.ch == 'q' || k.ch == 'Q'))
        return false;
    return true;
}

// ── Extraction worker (runs in background Thread) ─────────────────────────────

// Extract one file while updating g_ext progress atomics.
// expectedBytes == -1 → size unknown, shows live counter without a bar.
//
// After bsdtar exits we sync the dest file's filesystem to actual USB
// storage.  We do this via a `sync -f <file>` subprocess rather than an
// inline fsync() syscall: D's GC needs to stop-the-world to collect, and
// when the UI thread allocates (every render does) the GC tries to suspend
// every thread.  Linux's fsync() can be uninterruptible by signals, which
// blocks GC for the duration of the flush — freezing the UI.  waitpid() on
// the subprocess is interruptible, so the GC can suspend/resume the worker
// cleanly even while the kernel drains gigabytes to a slow USB.
void extractWithProgress(string isoPath, string isoNormPath,
                         string destPath, long expectedBytes)
{
    import std.process : execute;

    atomicStore(g_ext.bytesWritten, 0L);
    atomicStore(g_ext.bytesTotal, expectedBytes);
    atomicStore(g_ext.syncing, false);

    shared bool monDone = false;
    auto mon = new Thread({
        while (!atomicLoad(monDone))
        {
            Thread.sleep(dur!"msecs"(200));
            try atomicStore(g_ext.bytesWritten, cast(long) getSize(destPath));
            catch (Exception) {}
        }
    });
    mon.isDaemon = true;
    mon.start();

    extractFile(isoPath, isoNormPath, destPath);
    atomicStore(monDone, true);
    mon.join();

    // Switch to the syncing phase BEFORE the final size update so the UI
    // never sees a "100% but not syncing" frame.
    atomicStore(g_ext.syncing, true);
    try atomicStore(g_ext.bytesWritten, cast(long) getSize(destPath));
    catch (Exception) {}

    // `sync -f <file>` syncs only the filesystem containing the file,
    // not the whole system.  Available since coreutils 7.6.
    try execute(["sync", "-f", destPath]);
    catch (Exception) {}

    atomicStore(g_ext.syncing, false);
}

void doExtract(string usbMount, string isoPath)
{
    import usb : PB_DIR, writeMeta;

    atomicStore(g_ext.step, 0);
    atomicStore(g_ext.bytesWritten, 0L);
    atomicStore(g_ext.bytesTotal, 0L);

    string destBase;
    bool   destCreated = false;

    try
    {
        ISOFiles isoFiles = inspectISO(isoPath);
        if (!isoFiles.kernel || !isoFiles.initrd)
            throw new Exception("kernel or initrd not found in ISO");

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
        auto usbLabel  = getVolumeLabel(usbMount);
        auto args      = translateArgs(dtype, best.args, distroDir, usbLabel);
        destBase       = buildPath(usbMount, PB_DIR, name);
        destCreated    = true;

        // One bsdtar -tvf pass gets all sizes upfront
        string[] szTargets = [isoFiles.kernel, isoFiles.initrd];
        if (isoFiles.squashfs.length) szTargets ~= isoFiles.squashfs;
        long[] sizes  = getISOFileSizes(isoPath, szTargets);
        long kernelSz = sizes[0];
        long initrdSz = sizes[1];
        long squashSz = sizes.length > 2 ? sizes[2] : -1L;

        // ── Kernel
        atomicStore(g_ext.step, 1);
        extractWithProgress(isoPath, isoFiles.kernel,
                            buildPath(destBase, "vmlinuz"), kernelSz);

        // ── Initrd
        atomicStore(g_ext.step, 2);
        auto initrdDest = buildPath(destBase, "initrd.img");
        extractWithProgress(isoPath, isoFiles.initrd, initrdDest, initrdSz);

        // T2/SDE's initrd hardcodes ISO9660 mount probing; patch in place
        // so it can find live.squash on our ext4 USB.
        if (dtype == DistroType.T2SDE)
        {
            if (!patchT2Initrd(initrdDest))
                throw new Exception("T2 initrd patch failed (need zstd and cpio)");
        }

        // ── Rootfs image
        if (isoFiles.squashfs.length)
        {
            atomicStore(g_ext.step, 3);

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

            extractWithProgress(isoPath, isoFiles.squashfs, squashDest, squashSz);
        }

        // ── Metadata + endian detection
        atomicStore(g_ext.step, 4);
        atomicStore(g_ext.bytesWritten, 0L);
        atomicStore(g_ext.bytesTotal, 0L);

        string endian = detectKernelEndian(buildPath(destBase, "vmlinuz"));
        auto meta = DistroMeta(name, label,
                               distroDir ~ "/vmlinuz",
                               distroDir ~ "/initrd.img",
                               args, endian);
        writeMeta(usbMount, meta);

        try regenerate(usbMount);
        catch (Exception) {}

        atomicStore(g_ext.done, true);
    }
    catch (Throwable t)
    {
        // Roll back partial extraction so the USB doesn't keep half-distros
        if (destCreated && destBase.length && exists(destBase))
        {
            try rmdirRecurse(destBase);
            catch (Exception) {}
        }
        g_extError = t.msg;
        atomicStore(g_ext.failed, true);
        atomicStore(g_ext.done, true);
    }
}

// ── Main entry point ──────────────────────────────────────────────────────────

void runTUI(string usbMount)
{
    UIState s;
    s.usbMount = usbMount;

    if (!usbMount.length)
    {
        // No mount given — open device picker immediately
        s.devices   = scanUSBDevices();
        s.deviceSel = 0;
        s.mode      = Mode.DevicePicker;
    }
    else
    {
        s.distros    = listDistros(usbMount);
        s.globalArgs = readGlobalArgs(usbMount);
    }

    enterRaw();
    scope(exit)
    {
        exitRaw();
        // Restore terminal cleanly
        import std.stdio : stdout;
        stdout.write(SHOW_CURSOR ~ RESET ~ "\x1b[2J\x1b[H");
        stdout.flush();
        writeln("petitbootusb exited.");
    }

    Frame f;
    TermSize ts = termSize();
    render(f, s, ts);

    while (true)
    {
        // Resize check
        if (atomicLoad(g_resized))
        {
            atomicStore(g_resized, false);
            ts = termSize();
        }

        auto k = readKey();

        // Global Ctrl+C
        if (k.key == Key.CtrlC)
        {
            if (s.mode == Mode.Extracting)
            {
                // Can't cleanly abort bsdtar here; mark failed and bail to Normal.
                // The worker thread will finish on its own and clean up partial files.
                atomicStore(g_ext.failed, true);
                setStatus(s, "Extraction aborted — wait before adding another", true);
                s.mode = Mode.Normal;
                if (s.usbMount.length) s.distros = listDistros(s.usbMount);
            }
            else return;
        }

        // Extracting tick — poll for completion
        if (s.mode == Mode.Extracting)
        {
            s.spinTick++;
            if (atomicLoad(g_ext.syncing)) s.syncTicks++;
            else                            s.syncTicks = 0;
            bool done   = atomicLoad(g_ext.done);
            bool failed = atomicLoad(g_ext.failed);
            if (done)
            {
                s.mode = Mode.Normal;
                if (s.usbMount.length) s.distros = listDistros(s.usbMount);
                if (failed)
                {
                    string msg = g_extError.length
                        ? "Failed: " ~ g_extError
                        : "Extraction failed.";
                    setStatus(s, msg, true);
                }
                else
                    setStatus(s, "ISO added successfully.");
            }
            render(f, s, ts);
            continue;
        }

        // Auto-clear stale status messages (~5s of idle ticks)
        if (s.statusMsg.length)
        {
            s.statusAge++;
            if (s.statusAge > 50) { s.statusMsg = ""; s.statusErr = false; s.statusAge = 0; }
        }

        bool cont;
        final switch (s.mode)
        {
            case Mode.Normal:       cont = handleNormal(s, k);        break;
            case Mode.EditArgs:     cont = handleEditArgs(s, k);      break;
            case Mode.EditGlobal:   cont = handleEditGlobal(s, k);    break;
            case Mode.Confirm:      cont = handleConfirm(s, k);       break;
            case Mode.FileBrowser:  cont = handleFileBrowser(s, k);   break;
            case Mode.DevicePicker: cont = handleDevicePicker(s, k);  break;
            case Mode.Extracting:   cont = true;                      break;
        }
        if (!cont) return;

        render(f, s, ts);
    }
}

// ── Utility ───────────────────────────────────────────────────────────────────

// Strip ANSI escape codes to measure display length.
string stripAnsi(string s)
{
    import std.regex : replaceAll, regex;
    return replaceAll(s, regex(`\x1b\[[0-9;]*m`), "");
}
