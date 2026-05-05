module tui.input;

import core.sys.posix.unistd : read, STDIN_FILENO;

enum Key
{
    None, Char,
    Up, Down, Left, Right, Home, End, PageUp, PageDown,
    Enter, Backspace, Delete, Escape, Tab,
    CtrlC, CtrlD, CtrlU, CtrlK, CtrlA, CtrlE,
}

struct KeyEvent
{
    Key  key = Key.None;
    char ch;
}

KeyEvent readKey()
{
    ubyte[8] buf = void;
    auto n = read(STDIN_FILENO, buf.ptr, buf.sizeof);
    if (n <= 0) return KeyEvent(Key.None);

    ubyte c = buf[0];

    // Control characters
    switch (c)
    {
        case  1: return KeyEvent(Key.CtrlA);
        case  3: return KeyEvent(Key.CtrlC);
        case  4: return KeyEvent(Key.CtrlD);
        case  5: return KeyEvent(Key.CtrlE);
        case  8: return KeyEvent(Key.Backspace);
        case  9: return KeyEvent(Key.Tab);
        case 10,
             13: return KeyEvent(Key.Enter);
        case 11: return KeyEvent(Key.CtrlK);
        case 21: return KeyEvent(Key.CtrlU);
        case 127: return KeyEvent(Key.Backspace);
        default: break;
    }

    // Escape / escape sequences
    if (c == 0x1b)
    {
        if (n == 1) return KeyEvent(Key.Escape);

        if (n >= 3 && buf[1] == '[')
        {
            switch (buf[2])
            {
                case 'A': return KeyEvent(Key.Up);
                case 'B': return KeyEvent(Key.Down);
                case 'C': return KeyEvent(Key.Right);
                case 'D': return KeyEvent(Key.Left);
                case 'H': return KeyEvent(Key.Home);
                case 'F': return KeyEvent(Key.End);
                default:  break;
            }
            // ESC [ n ~
            if (n >= 4 && buf[3] == '~')
            {
                switch (buf[2])
                {
                    case '1': return KeyEvent(Key.Home);
                    case '3': return KeyEvent(Key.Delete);
                    case '4': return KeyEvent(Key.End);
                    case '5': return KeyEvent(Key.PageUp);
                    case '6': return KeyEvent(Key.PageDown);
                    default:  break;
                }
            }
        }
        // ESC O sequences (application cursor keys)
        if (n >= 3 && buf[1] == 'O')
        {
            switch (buf[2])
            {
                case 'A': return KeyEvent(Key.Up);
                case 'B': return KeyEvent(Key.Down);
                case 'C': return KeyEvent(Key.Right);
                case 'D': return KeyEvent(Key.Left);
                default:  break;
            }
        }
        return KeyEvent(Key.Escape);
    }

    // Printable ASCII
    if (c >= 32 && c < 127)
        return KeyEvent(Key.Char, cast(char) c);

    return KeyEvent(Key.None);
}
