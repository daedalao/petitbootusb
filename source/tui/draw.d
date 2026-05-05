module tui.draw;

import std.format : format;
import std.array  : Appender, appender;
import std.algorithm : min, max;
import std.string : strip;
import tui.term : TermSize;

// ── ANSI primitives ──────────────────────────────────────────────────────────

string moveTo(int row, int col)  { return format("\x1b[%d;%dH", row, col); }
enum   HIDE_CURSOR   = "\x1b[?25l";
enum   SHOW_CURSOR   = "\x1b[?25h";
enum   CLEAR_SCREEN  = "\x1b[2J\x1b[H";
enum   RESET         = "\x1b[0m";
enum   BOLD          = "\x1b[1m";
enum   DIM           = "\x1b[2m";
enum   ITALIC        = "\x1b[3m";

string fg(int r, int g, int b) { return format("\x1b[38;2;%d;%d;%dm", r, g, b); }
string bg(int r, int g, int b) { return format("\x1b[48;2;%d;%d;%dm", r, g, b); }

// ── Colour palette (btop-inspired dark theme) ─────────────────────────────────

// Backgrounds
enum BG_APP    = "\x1b[48;2;15;18;24m";    // near-black blue
enum BG_PANEL  = "\x1b[48;2;22;26;35m";    // dark panel
enum BG_SEL    = "\x1b[48;2;33;60;100m";   // selected row
enum BG_TITLE  = "\x1b[48;2;10;12;20m";    // header/footer strip
enum BG_DIALOG = "\x1b[48;2;18;22;32m";    // overlay dialog
enum BG_INPUT  = "\x1b[48;2;28;34;48m";    // text input field
enum BG_PROG   = "\x1b[48;2;25;55;90m";    // progress bar filled

// Foregrounds
enum FG_NORM   = "\x1b[38;2;188;199;214m"; // normal text
enum FG_DIM    = "\x1b[38;2;88;105;128m";  // secondary / muted
enum FG_BORDER = "\x1b[38;2;48;98;158m";   // box borders
enum FG_TITLE  = "\x1b[38;2;95;178;240m";  // panel titles
enum FG_SEL    = "\x1b[38;2;225;238;255m"; // selected item text
enum FG_LE     = "\x1b[38;2;85;210;140m";  // little-endian badge
enum FG_BE     = "\x1b[38;2;230;148;55m";  // big-endian badge
enum FG_ERR    = "\x1b[38;2;222;65;65m";   // errors
enum FG_OK     = "\x1b[38;2;95;210;130m";  // success
enum FG_WARN   = "\x1b[38;2;218;195;75m";  // warnings / args
enum FG_KEY    = "\x1b[38;2;240;240;248m"; // keybinding key letter
enum FG_KDESC  = "\x1b[38;2;130;148;170m"; // keybinding description
enum FG_LABEL  = "\x1b[38;2;110;155;200m"; // field labels
enum FG_ACCENT = "\x1b[38;2;120;190;255m"; // accent / header text
enum FG_PATH   = "\x1b[38;2;155;175;210m"; // file paths (dimmer)

// ── Box-drawing characters ────────────────────────────────────────────────────

enum TL = "┌", TR = "┐", BL = "└", BR = "┘";
enum HL = "─", VL = "│";
enum ML = "├", MR = "┤", MT = "┬", MB = "┴", MC = "┼";
enum DBL_HL = "━";

// Spinner frames — old-school ASCII rotor
immutable SPIN = ["|", "/", "-", "\\"];

// ── Frame ─────────────────────────────────────────────────────────────────────
// Accumulates all rendering for one screen refresh; written atomically.

struct Frame
{
    private Appender!string _b;
    int rows, cols;

    void begin(TermSize ts)
    {
        rows = ts.rows; cols = ts.cols;
        _b = appender!string();
        _b ~= BG_APP ~ FG_NORM;
        _b ~= CLEAR_SCREEN;
        _b ~= HIDE_CURSOR;
    }

    void flush(bool showCursor = false)
    {
        if (showCursor) _b ~= SHOW_CURSOR;
        import std.stdio : stdout;
        stdout.write(_b.data);
        stdout.flush();
    }

    // Position cursor (1-based row/col)
    void at(int row, int col)        { _b ~= moveTo(row, col); }
    void put(string s)               { _b ~= s; }
    void nl()                        { _b ~= "\r\n"; }

    // Reset colours to app defaults
    void reset() { _b ~= RESET ~ BG_APP ~ FG_NORM; }

    // Write text, clipped to maxCols display columns (ASCII-safe).
    void text(int row, int col, int maxCols, string attrs, string s)
    {
        at(row, col);
        _b ~= attrs;
        int w = min(cast(int) s.length, maxCols);
        _b ~= s[0 .. w];
        reset();
    }

    // Fill a run of spaces with given attributes.
    void fill(int row, int col, int width, string attrs = "")
    {
        at(row, col);
        if (attrs.length) _b ~= attrs;
        foreach (_; 0 .. width) _b ~= " ";
        reset();
    }

    // Draw a box.  Interior and border-row backgrounds use `bg` (defaults
    // to BG_PANEL for inline panels; dialog overlays should pass BG_DIALOG).
    void box(int row, int col, int h, int w, string title = "", string bg = BG_PANEL)
    {
        // Top border
        at(row, col);
        _b ~= FG_BORDER ~ bg;
        _b ~= TL;
        if (title.length)
        {
            string t = " " ~ title ~ " ";
            _b ~= HL ~ FG_TITLE ~ BOLD ~ t ~ RESET ~ FG_BORDER ~ bg;
            int remain = w - 2 - 1 - cast(int) t.length;
            foreach (_; 0 .. max(0, remain)) _b ~= HL;
        }
        else
            foreach (_; 0 .. w - 2) _b ~= HL;
        _b ~= TR;

        // Content rows
        foreach (r; 1 .. h - 1)
        {
            at(row + r, col);
            _b ~= FG_BORDER ~ bg ~ VL ~ bg ~ FG_NORM;
            foreach (_; 0 .. w - 2) _b ~= " ";
            _b ~= FG_BORDER ~ VL;
        }

        // Bottom border
        at(row + h - 1, col);
        _b ~= FG_BORDER ~ bg ~ BL;
        foreach (_; 0 .. w - 2) _b ~= HL;
        _b ~= BR;
        reset();
    }

    // Draw a horizontal separator (├ ... ┤) with optional mid-junction.
    void hline(int row, int colL, int colR, int divAt = 0)
    {
        at(row, colL);
        _b ~= FG_BORDER ~ BG_PANEL ~ ML;
        foreach (c; colL + 1 .. colR)
            _b ~= (c == divAt) ? MB : HL;
        _b ~= MR;
        reset();
    }

    // Draw a vertical divider within a content area.
    void vdiv(int rowStart, int rowEnd, int col)
    {
        _b ~= FG_BORDER ~ BG_PANEL;
        foreach (r; rowStart .. rowEnd + 1)
        {
            at(r, col);
            _b ~= VL;
        }
        reset();
    }

    // Progress bar: `[■■■■·····] NN%` rendered in *exactly* w columns.
    // Caller is responsible for any label — keeping that out of this
    // function lets the bar honour its width and the label live elsewhere.
    void progressBar(int row, int col, int w, float pct, string bg = BG_PANEL)
    {
        import std.format : format;
        int barW = max(4, w - 7);   // [ + barW + ] + space + 4-char "NN%"
        int filled = cast(int)(barW * pct);
        at(row, col);
        _b ~= bg ~ FG_BORDER ~ "[";
        foreach (i; 0 .. barW)
        {
            if (i < filled) { _b ~= BG_PROG ~ FG_SEL ~ "■" ~ bg; }
            else            { _b ~= bg ~ FG_DIM ~ "·"; }
        }
        _b ~= bg ~ FG_BORDER ~ "] ";
        _b ~= bg ~ FG_ACCENT ~ BOLD ~ format("%3.0f%%", pct * 100);
        reset();
    }

    // Spinner character for given tick.
    string spin(int tick) const { return SPIN[tick % SPIN.length]; }
}

// Pad/trim to exactly n ASCII columns.
string pad(string s, int n, char fill = ' ')
{
    import std.array : replicate;
    if (cast(int) s.length >= n) return s[0 .. n];
    return s ~ cast(string) replicate([fill], n - cast(int) s.length);
}

// Truncate with ellipsis if over width.
string trunc(string s, int n)
{
    if (n <= 0) return "";
    if (cast(int) s.length <= n) return s;
    if (n <= 3) return s[0 .. n];
    return s[0 .. n - 1] ~ "…";
}

// Wrap s to lines of maxW.
string[] wrapArgs(string s, int maxW)
{
    import std.string : split;
    string[] result;
    string cur;
    foreach (tok; s.split())
    {
        if (cur.length && cast(int)(cur.length + 1 + tok.length) > maxW)
        {
            result ~= cur;
            cur = tok;
        }
        else
            cur = cur.length ? cur ~ " " ~ tok : tok;
    }
    if (cur.length) result ~= cur;
    return result;
}
