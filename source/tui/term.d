module tui.term;

import core.sys.posix.termios;
import core.sys.posix.unistd : STDOUT_FILENO, STDIN_FILENO, isatty;
import core.sys.posix.signal : signal, SIGUSR1;
import core.atomic;

extern(C) int ioctl(int, ulong, ...) nothrow @nogc;

version(linux)
{
    struct winsize { ushort ws_row, ws_col, ws_xpixel, ws_ypixel; }
    enum ulong TIOCGWINSZ = 0x5413;
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
    raw.c_cc[VMIN]  = 0;
    raw.c_cc[VTIME] = 1;   // 100 ms read timeout — drives the UI tick rate
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
