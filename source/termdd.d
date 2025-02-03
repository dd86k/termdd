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
import core.stdc.stdio : EOF;
import core.stdc.ctype : iscntrl;

// Due to bad mangling
extern (C) int getchar();
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

/// Hide key input from being echo'd.
void term_hide()
{
    term_init();
    
version (Windows)
{
    HANDLE hstdin = GetStdHandle(STD_INPUT_HANDLE); 
    DWORD mode = void;
    GetConsoleMode(hstdin, &mode);
    SetConsoleMode(hstdin, mode & ~ENABLE_ECHO_INPUT);
}
else version (Posix)
{
    termios term = void;
    tcgetattr(STDIN_FILENO, &term);
    term.c_lflag &= ~(ECHO|ICANON);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term);
}
else static assert(0, "Implement term_hide()");
}

/// Show key input again.
void term_show()
{
    term_init();
    
version (Windows)
{
    HANDLE hstdin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = void;
    GetConsoleMode(hstdin, &mode);
    SetConsoleMode(hstdin, mode | ENABLE_ECHO_INPUT);
}
else version (Posix)
{
    //tcsetattr(STDIN_FILENO, TCSANOW, &oistdin);
    termios term = void;
    tcgetattr(STDIN_FILENO, &term);
    term.c_lflag |= ECHO|ICANON;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term);
}
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
        int c;
        read(*cast(int*)handle, &c, c.sizeof);
        return c;
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
    term_hide();
    
    // To avoid the shell/cmd saving line buffers into their history,
    // open the handle to the OS standard input.
    // On error, fallback to standard input for the shell.
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
            fd = STDIN_FILENO;
        void *h = &fd;
    }
    
    // Read input and exit on newline, imitating a line
    // buffer
    string buf;
Lchar:
    int c = term_getchar_internal(h);
    switch (c) {
    case '\n', '\r', EOF: break;
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
        if (iscntrl(c))
        {
            cast(void)putchar(c);
            goto Lchar;
        }
        
        buf ~= cast(char)c;
        cast(void)putchar(rep);
        goto Lchar;
    }
    
    cast(void)putchar('\n'); // Imitate readln()
    term_show(); // Echo characters again
    return buf;
}

unittest
{
    import std.stdio : writeln, write, stdout;
    write(`Type "test": `); stdout.flush();
    string output = term_getpass();
    writeln("Output: ", output);
    assert(output == `test`);
}