/// Minimal terminal library, only doing "password" readline.
module termdd;

version (Windows)
{
    import core.sys.windows.winbase;
    import core.sys.windows.wincon;
    import core.sys.windows.winnt;
}
else
{
    import core.sys.posix.fcntl;
    import core.sys.posix.termios;
    import core.sys.posix.unistd;
    
    private __gshared termios oistdin;
}

import core.stdc.stdlib : atexit;
import core.stdc.stdio : EOF, fflush, stdout, stdin;
import core.stdc.ctype : iscntrl;

// Redefined here due to bad mangling names
extern (C) int putchar(int);

// Internal state
private enum TERM_INIT = 1;
private __gshared int state;

void term_init()
{
    // If already initiated, return
    if (state & TERM_INIT)
        return;
    
    version (Posix)
    {
        // Save current attributes
        if (tcgetattr(STDIN_FILENO, &oistdin) < 0)
        {
            assert(false, "tcgetattr(STDIN_FILENO, &oistdin) < 0");
        }
        
        // Restore those attributes on exit
        atexit(&term_exiting);
    }
    
    state |= TERM_INIT;
}

version (Posix)
extern (C)
void term_exiting()
{
    tcsetattr(STDIN_FILENO, TCSANOW, &oistdin);
}

private
int term_getchar_internal(void *handle)
{
    assert(handle);
    version (Windows)
    {
        HANDLE hstdin = GetStdHandle(STD_INPUT_HANDLE);
        DWORD r;
        INPUT_RECORD rec = void;
    Lretry:
        if (ReadConsoleInputA(hstdin, &rec, 1, &r) == FALSE ||
            rec.EventType != KEY_EVENT ||
            rec.KeyEvent.bKeyDown == FALSE)
            goto Lretry;
        return rec.KeyEvent.AsciiChar;
    }
    else version (Posix)
    {
        // Should be enough for escape codes
        char[8] b = void;
    Lagain:
        ssize_t r = read(*cast(int*)handle, b.ptr, b.sizeof);
        
        // Error or zero bytes read (EOF)
        if (r <= 0)
        {
            // Okay for EAGAIN, but problematic for others
            goto Lagain;
        }
        
        // ESC... Likely an escape code, retry.
        if (b[0] == '\033')
            goto Lagain;
        
        return b[0];
    }
    else static assert(0, "term_getchar()");
}

// rep = Replacement character
/// Read a line as a password.
///
/// The newline character is not included.
/// Params:
///   rep = Replacement character, defaults to '*'.
/// Returns: String buffer.
string term_getpass(char rep = '*')
{
    // Init terminal internals
    term_init();
    
    // To avoid the shell/cmd saving line buffers into their history,
    // open a new handle to the native standard input.
    // On error, fallback to the already existing standard input stream.
    version (Windows)
    {
        HANDLE h = CreateFileA("CONIN$",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null,
            OPEN_EXISTING,
            0,
            null);
        if (h == INVALID_HANDLE_VALUE)
            h = GetStdHandle(STD_INPUT_HANDLE);
    }
    else version (Posix)
    {
        int fd = open("/dev/tty", O_RDWR | O_NOCTTY);
        if (fd < 0)
            fd = open("/dev/stdin", O_RDWR | O_NOCTTY); // works as-is
        if (fd < 0)
            fd = STDIN_FILENO;
        void *h = &fd;
    }
    
    // Hide terminal output
    version (Windows)
    {
        enum LFLAGS = ENABLE_ECHO_INPUT;
        DWORD mode = void;
        GetConsoleMode(h, &mode);
        SetConsoleMode(h, mode & ~LFLAGS);
    }
    else version (Posix)
    {
        enum LFLAGS = ECHO|ICANON;
        termios term = void;
        tcgetattr(fd, &term);
        term.c_lflag &= ~LFLAGS;
        tcsetattr(fd, TCSANOW, &term);
    }
    
    string buf;
Lchar:
    // Flush CRT stdout as it is, by default, line-buffered.
    // Useful when text was written without a newline, like for a
    // prompt, or anything we have written to it.
    fflush(stdout);
    
    // Read input and exit on newline or EOF,
    // imitating a line input buffer.
    int c = term_getchar_internal(h);
    switch (c) {
    // EOL/EOF - Input is done
    case '\n', '\r', EOF: break;
    
    // Erase character
    case 127 /* DEL */, '\b' /* BS */:
        if (buf.length <= 0)
            goto Lchar;
        
        buf.length--;
        // Emit backspace change visibly
        cast(void)putchar('\b');
        cast(void)putchar(' ');
        cast(void)putchar('\b');
        goto Lchar;
    
    default:
        // Just print the control character, it could be anything
        if (iscntrl(c))
        {
            cast(void)putchar(c);
            goto Lchar;
        }
        
        // Insert character
        buf ~= cast(char)c;
        cast(void)putchar(rep);
        goto Lchar;
    }
    
    // Imitate readln(), no need to flush
    cast(void)putchar('\n');
    
    // Restore state to echo characters
    version (Windows)
    {
        DWORD mode = void;
        GetConsoleMode(h, &mode);
        SetConsoleMode(h, mode | LFLAGS);
    }
    else version (Posix)
    {
        tcgetattr(fd, &term);
        term.c_lflag |= LFLAGS;
        tcsetattr(fd, TCSANOW, &term);
    }
    
    return buf;
}

unittest
{
    import std.stdio : writeln, write;
    write(`Type "test": `);
    string output = term_getpass();
    writeln("Output: ", output);
    assert(output == `test`);
}