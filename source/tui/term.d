module tui.term;

import core.sys.posix.termios;
import core.sys.posix.unistd : STDOUT_FILENO, STDIN_FILENO, isatty;
import core.sys.posix.signal : signal, SIGUSR1;
import core.atomic;

extern(C) int ioctl(int, ulong, ...) nothrow @nogc;

version(linux)
{
    struct winsize { ushort ws_row, ws_col, ws_xpixel, ws_ypixel; }

    // TIOCGWINSZ is architecture-specific on Linux: x86/ARM/RISC-V use the
    // simple form, while the BSD-derived ioctl encoding (PPC, SPARC, MIPS,
    // Alpha) packs direction/size/group into the request number.
    version (PPC)        enum ulong TIOCGWINSZ = 0x40087468;
    else version (PPC64) enum ulong TIOCGWINSZ = 0x40087468;
    else version (SPARC) enum ulong TIOCGWINSZ = 0x40087468;
    else version (SPARC64) enum ulong TIOCGWINSZ = 0x40087468;
    else version (MIPS32)  enum ulong TIOCGWINSZ = 0x40087468;
    else version (MIPS64)  enum ulong TIOCGWINSZ = 0x40087468;
    else version (Alpha)   enum ulong TIOCGWINSZ = 0x40087468;
    else                   enum ulong TIOCGWINSZ = 0x5413;

    // c_cc[] indices for VMIN/VTIME also differ per architecture, and
    // druntime's core.sys.posix.termios hardcodes the x86 values. The
    // kernel's true indices (from arch/<arch>/include/uapi/asm/termbits.h)
    // are: PPC = (5, 7), MIPS = (4, 5), Alpha = (4, 5); all others = (6, 5).
    version (PPC)        enum int _VMIN = 5, _VTIME = 7;
    else version (PPC64) enum int _VMIN = 5, _VTIME = 7;
    else version (MIPS32)  enum int _VMIN = 4, _VTIME = 5;
    else version (MIPS64)  enum int _VMIN = 4, _VTIME = 5;
    else version (Alpha)   enum int _VMIN = 4, _VTIME = 5;
    else                   enum int _VMIN = 6, _VTIME = 5;

    enum SIGWINCH = 28;
}

private termios _saved;
private bool    _inRaw;

shared bool g_resized;

extern(C) private void _onResize(int) nothrow @nogc
{
    atomicStore(g_resized, true);
}

struct TermSize { int rows, cols; }

TermSize termSize() nothrow @nogc
{
    winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
        return TermSize(ws.ws_row, ws.ws_col);
    return TermSize(24, 80);
}

bool isTTY()
{
    return isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0;
}

void enterRaw()
{
    tcgetattr(STDIN_FILENO, &_saved);
    termios raw = _saved;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.c_iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
    raw.c_cflag |= CS8;
    raw.c_oflag &= ~OPOST;
    raw.c_cc[_VMIN]  = 0;
    raw.c_cc[_VTIME] = 1;   // 100 ms read timeout — drives the UI tick rate
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    _inRaw = true;

    signal(SIGWINCH, &_onResize);
}

void exitRaw()
{
    if (!_inRaw) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &_saved);
    _inRaw = false;
}
