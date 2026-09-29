#!/bin/sh
# Nextsh test suite - POSIX shell
# Tests the lexer, mostly the parts that scan the raw text of a $(..)
# body: quoting, here documents, comments and case patterns. Also tests
# vi-mode UTF-8 redraw, window buffers and completion through a PTY
# (requires Python 3).
#
# The shell under test is $SH (./sh by default), the shell running this
# script can be any POSIX shell.

SH=${SH:-./sh}
PASS=0
FAIL=0
N=0

TMPFILE=$(mktemp /tmp/nextsh_test_XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

# t: run the script on stdin, compare its output with the expected one
t() {
	name="$1" expected="$2"
	N=$((N + 1))
	cat > "$TMPFILE"
	actual=$("$SH" "$TMPFILE" 2>/dev/null)
	printf 'Test %d: "%s"\n' "$N" "$name"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL\n  expected: |%s|\n  actual:   |%s|\n' \
			"$expected" "$actual"
	fi
}

# terr: the script on stdin must be rejected
terr() {
	name="$1"
	N=$((N + 1))
	cat > "$TMPFILE"
	"$SH" "$TMPFILE" >/dev/null 2>&1
	actual=$?
	printf 'Test %d: "%s"\n' "$N" "$name"
	if [ "$actual" -ne 0 ]; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL\n  expected: non-zero exit\n  actual:   %s\n' \
			"$actual"
	fi
}

printf '%s\n' '─── Quoting inside $(..) ─────────────────────────────────────────────────────'

t 'nested command substitution' 'a' <<'S'
echo "$(echo "$(echo a)")"
S

t 'single quotes inside double quotes inside $()' "a'b" <<'S'
echo "$(printf '%s' 'a'"'"'b')"
S

t 'double quotes inside ${} inside double quotes inside $()' 'a)b' <<'S'
echo "$(echo "${x:-"a)b"}")"
S

t 'backquotes inside double quotes inside $()' 'a)b' <<'S'
echo "$(echo "`echo "a)b"`")"
S

t 'arithmetic inside double quotes inside $()' '3' <<'S'
echo "$(echo "$((1+2))")"
S

t 'single quote inside double quotes is literal' "it's" <<'S'
echo "$(echo "it's")"
S

t 'parenthesis inside single quotes' ')(' <<'S'
echo $(echo ')(')
S

t 'double quote inside single quotes' 'a"b' <<'S'
echo $(echo 'a"b')
S

t 'escaped parenthesis and quotes' ') " \' <<'S'
echo "$(echo \) \" \\)"
S

t 'closing brace inside ${} default value' ')' <<'S'
echo "$(echo "${x:-)}")"
S

t 'three levels of nesting' 'deep' <<'S'
echo "$(echo "$(echo "$(echo deep)")")"
S

t 'lone dollar is not a substitution' '$ $ x' <<'S'
x=x; echo "$(echo '$' "$" $x)"
S

t 'backquotes at the top level are unaffected' 'a b' <<'S'
echo "`echo a` `echo b`"
S

printf '%s\n' '─── Here documents inside $(..) ──────────────────────────────────────────────'

t 'here document body may hold a parenthesis' 'a)b' <<'S'
echo "$(cat <<EOF
a)b
EOF
)"
S

t 'here document body may hold unbalanced quotes' 'a"b (c' <<'S'
echo "$(cat <<EOF
a"b (c
EOF
)"
S

t '<<- with a quoted delimiter holding a parenthesis' 'a)b' <<'S'
echo "$(cat <<-'E)F'
	a)b
	E)F
)"
S

t 'two here documents in one $()' 'one)
two)' <<'S'
echo "$(cat <<A; cat <<B
one)
A
two)
B
)"
S

t 'here document in a nested $() inside double quotes' 'q)r' <<'S'
echo "$(echo "$(cat <<Z
q)r
Z
)")"
S

t 'quoted delimiter suppresses expansion' '$x `date` $(echo)' <<'S'
x=set
echo "$(cat <<'E'
$x `date` $(echo)
E
)"
S

t 'unquoted delimiter expands the body' 'set' <<'S'
x=set
echo "$(cat <<E
$x
E
)"
S

t 'text after the here document is still part of $()' 'body
tail' <<'S'
echo "$(cat <<E
body
E
echo tail)"
S

printf '%s\n' '─── Comments inside $(..) ────────────────────────────────────────────────────'

t 'comment holding a parenthesis' 'hi' <<'S'
echo "$(echo hi # )
)"
S

t 'comment on its own line' 'a
b' <<'S'
echo "$(echo a
# comment with ) paren
echo b)"
S

t 'hash in the middle of a word is not a comment' 'a#b' <<'S'
echo "$(echo a#b)"
S

t 'hash inside quotes is not a comment' '# )' <<'S'
echo "$(echo "# )")"
S

t 'hash in a here document body is literal' '# )' <<'S'
echo "$(cat <<E
# )
E
)"
S

printf '%s\n' '─── case patterns inside $(..) ───────────────────────────────────────────────'

t 'case pattern parenthesis does not end $()' 'one' <<'S'
echo "$(case x in x) echo one;; esac)"
S

t 'parenthesised case pattern' 'two' <<'S'
echo "$(case x in (a|x) echo two;; *) echo no;; esac)"
S

t 'nested case' 'three' <<'S'
echo "$(case x in x) case y in y) echo three;; esac;; esac)"
S

t 'case inside a subshell inside $()' 'four' <<'S'
echo "$( (case x in x) echo four;; esac) )"
S

t 'subshell inside a case body' 'five' <<'S'
echo "$(case x in x) (echo five);; esac)"
S

t 'commands after esac' 'six
seven' <<'S'
echo "$(case x in x) echo six;; esac; echo seven)"
S

t 'case as an argument is not a keyword' 'case esac' <<'S'
echo "$(echo case) $(echo esac)"
S

t 'empty case' 'eight' <<'S'
echo "$(case x in x) ;; esac; echo eight)"
S

t 'case over several lines' 'nine' <<'S'
echo "$(case x in
x)
	echo nine
	;;
esac)"
S

printf '%s\n' '─── Substitutions in other contexts ──────────────────────────────────────────'

t 'assignment from $() with quotes' "a'b" <<'S'
v=$(printf '%s' 'a'"'"'b'); echo "$v"
S

t 'unquoted $() splits, quoted does not' '2 1' <<'S'
set -- $(echo a b); n=$#
set -- "$(echo a b)"; echo "$n $#"
S

t '$() in a here document body' 'x=hi' <<'S'
cat <<E
x=$(echo hi)
E
S

t '$() inside ${} default value' 'sub' <<'S'
echo "${x:-$(echo sub)}"
S

t '$() as a redirection target' 'redir' <<'S'
out=/tmp/nextsh_redir_$$
echo redir > "$(echo "$out")"
cat "$out"
rm -f "$out"
S

t 'nested arithmetic and substitution' '7' <<'S'
echo $(( $(echo 3) + 4 ))
S

printf '%s\n' '─── Plain lexing (regressions) ───────────────────────────────────────────────'

t 'here document at the top level' 'plain 2' <<'S'
cat <<EOF
plain $((1+1))
EOF
S

t 'quoted here document delimiter at the top level' '$x `date`' <<'S'
cat <<'EOF'
$x `date`
EOF
S

t '<<- strips leading tabs' 'a
b' <<'S'
cat <<-EOF
	a
	b
	EOF
S

t 'here document as loop input' 'L:x y
L:z' <<'S'
while read l; do echo "L:$l"; done <<E
x y
z
E
S

t 'redirections and arithmetic operators' '1 20' <<'S'
x=5; echo $((x<6)) $((x << 2))
S

t 'parameter expansions' 'set def 1' <<'S'
x=5; echo "${x:+set}" "${nope:-def}" "${#x}"
S

t 'functions and positional parameters' 'f:p q r)s' <<'S'
f() { echo "f:$*"; }
f "$(echo p q)" 'r)s'
S

t 'for loop over a substitution' '12' <<'S'
for i in $(echo 1 2); do printf '%s' "$i"; done; echo
S

printf '%s\n' '─── Parameter operators before parentheses ───────────────────────────────────'

t 'here document alternate and default words' '[unset] ||(DEFAULT)|(DEFAULT)
[empty] (NOLOAD)|||(DEFAULT)
[set] (NOLOAD)|(NOLOAD)|yes|yes' <<'S'
for state in unset empty set; do
	unset V
	case $state in empty) V=;; set) V=yes;; esac
	cat <<EOF
[$state] ${V+(NOLOAD)}|${V:+(NOLOAD)}|${V-(DEFAULT)}|${V:-(DEFAULT)}
EOF
done
S

t 'here document assignment and error words' '(DEFAULT)|(DEFAULT)|(DEFAULT)
(DEFAULT)|(DEFAULT)|(DEFAULT)' <<'S'
unset V
cat <<EOF
${V=(DEFAULT)}|${V?(ERROR)}|${V:?(ERROR)}
EOF
V=
cat <<EOF
${V:=(DEFAULT)}|${V?(ERROR)}|${V:?(ERROR)}
EOF
S

t 'unquoted and quoted alternate and error words' '<(NOLOAD)>
<(NOLOAD)>
<yes>
<yes>
<(NOLOAD)>' <<'S'
V=yes
printf '<%s>\n' ${V+(NOLOAD)} ${V:+(NOLOAD)} ${V?(ERROR)} ${V:?(ERROR)} "${V+(NOLOAD)}"
S

t 'nested and unused alternate words' '<(DEFAULT)>' <<'S'
unset V
printf '<%s>\n' ${V+(${V?(unused)})} "${V:-${V+(unused)}(DEFAULT)}"
S

t 'patterns in substitution words still work' '+(unlikely_nextsh_file)
b
aaa' <<'S'
V=yes
printf '%s\n' ${V++(unlikely_nextsh_file)}
V=aaab
printf '%s\n' ${V##+(a)} ${V%%+(b)}
S

t 'sourced PE linker script template' '.bss   : { *(.bss) }
.bss BLOCK(__section_alignment__) (NOLOAD) : { *(.bss) }' <<'S'
template=$0.template
trap 'rm -f "$template"' EXIT
cat > "$template" <<'T'
cat <<EOF
.bss ${RELOCATING+BLOCK(__section_alignment__)} ${RELOCATING+(NOLOAD)} : { *(.bss) }
EOF
T
unset RELOCATING
. "$template"
RELOCATING=yes
. "$template"
S

printf '%s\n' '─── Rejected input ───────────────────────────────────────────────────────────'

terr 'unterminated $(' <<'S'
echo "$(echo hi"
S

terr 'unterminated quote' <<'S'
echo "hi
S

# bash and dash accept this one, taking eof as the delimiter
terr 'unterminated here document' <<'S'
cat <<EOF
body
S

terr 'unterminated case' <<'S'
echo "$(case x in x) echo hi;;)"
S

# Keep the PTY driver here so ./test.sh is the single test entry point.
# Python emits one PASS/FAIL record per case; shell counters below include
# these in the same summary as the non-interactive tests.
printf '%s\n' '─── Interactive editing and completion ───────────────────────────────────────'

if command -v python3 >/dev/null 2>&1; then
	python3 - "$SH" > "$TMPFILE" <<'PY_PTY'
import codecs
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
import unittest

SHELL = str(Path(sys.argv[1]).resolve())
work = Path(tempfile.mkdtemp(prefix='nextsh-vi-tests-'))
base_env = dict(os.environ, ENV='/dev/null', HOME=str(work),
                HISTFILE='/dev/null', TERM='xterm', LC_ALL='C.UTF-8',
                ASAN_OPTIONS=os.environ.get('ASAN_OPTIONS',
                                            'detect_leaks=0:halt_on_error=1'),
                UBSAN_OPTIONS=os.environ.get('UBSAN_OPTIONS',
                                             'halt_on_error=1:print_stacktrace=1'))

# These screen assertions use single-column Unicode characters: the
# editor currently counts each non-ASCII character as one display column.
class Terminal:
    def __init__(self, width=24):
        self.width = width
        self.row = [' '] * width
        self.col = 0
        self.escape = ''
        self.decode = codecs.getincrementaldecoder('utf-8')('strict')
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            env = dict(base_env, PS1='> ', PS2='+ ', COLUMNS=str(width))
            fcntl.ioctl(0, termios.TIOCSWINSZ,
                        struct.pack('HHHH', 24, width, 0, 0))
            os.execve(SHELL, [SHELL, '-i'], env)
        try:
            self.read()
            self.send(b'set -o vi\n')
        except BaseException:
            self.close()
            raise

    def read(self):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if not select.select([self.fd], [], [], 0.08)[0]:
                return
            data = os.read(self.fd, 65536)
            for ch in self.decode.decode(data):
                if self.escape:
                    self.escape += ch
                    if self.escape == '\x1b[':
                        continue
                    if ch.isalpha():
                        if ch == 'H':
                            self.col = 0
                        elif ch in 'JK':
                            self.row = [' '] * self.width
                        else:
                            raise AssertionError('unexpected escape ' + repr(self.escape))
                        self.escape = ''
                    continue
                if ch == '\x1b':
                    self.escape = ch
                elif ch == '\r':
                    self.col = 0
                elif ch == '\n':
                    self.row = [' '] * self.width
                elif ch == '\b':
                    self.col = max(0, self.col - 1)
                elif ch == '\a':
                    pass
                else:
                    if self.col < self.width:
                        self.row[self.col] = ch
                    self.col += 1

    def send(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)
        self.read()

    def close(self):
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        os.close(self.fd)


class ViUTF8(unittest.TestCase):
    def setUp(self):
        self.t = Terminal()

    def tearDown(self):
        self.t.close()

    def check(self, text, cursor, marker=' '):
        self.assertEqual(''.join(self.t.row[:len(text) + 2]), '> ' + text)
        self.assertEqual(self.t.col, cursor + 2)
        self.assertEqual(''.join(self.t.row[len(text) + 2:self.t.width - 2]),
                         ' ' * max(0, self.t.width - len(text) - 4))
        self.assertEqual(self.t.row[self.t.width - 2], marker)

    def test_insert_move_delete_and_redraw(self):
        self.t.send('aé€𝄞z')
        self.check('aé€𝄞z', 5)
        self.t.send(b'\x1bhh')
        self.check('aé€𝄞z', 2)
        self.t.send(b'x')
        self.check('aé𝄞z', 2)
        self.t.send(b'iX\x1b')
        self.check('aéX𝄞z', 2)
        self.t.send(b'\x0c')
        self.check('aéX𝄞z', 2)

    def test_different_utf8_lengths_and_shared_prefix(self):
        self.t.send('éê€𝄞abc')
        self.t.send(b'\x1b0x')
        self.check('ê€𝄞abc', 0)
        self.t.send(b'x')
        self.check('€𝄞abc', 0)
        self.t.send(b'iZ\x1b')
        self.check('Z€𝄞abc', 0)
        self.t.send(b'lx')
        self.check('Z𝄞abc', 1)

    def test_fragmented_input(self):
        for ch in 'é€𝄞':
            for byte in ch.encode():
                self.t.send(bytes([byte]))
        self.check('é€𝄞', 3)
        self.t.send(b'\x7f')
        self.check('é€', 2)
        self.t.send(b'\x1b0i')
        for byte in 'ê'.encode():
            self.t.send(bytes([byte]))
        self.check('êé€', 1)
        self.t.send(b'\x1bl')
        self.check('êé€', 1)

    def test_right_margin_and_scrolling(self):
        # winwidth = 24 - 2 (prompt) - 3 = 19; a command-mode
        # character in its last column must include all its bytes.
        self.t.send('a' * 18)
        self.t.send(b'\x1b')
        self.t.send('a€')
        self.t.send(b'\x1b0$')
        self.check('a' * 18 + '€', 18)
        self.t.send(b'\x0c')
        self.check('a' * 18 + '€', 18)
        self.t.send('Aê𝄞xyz')
        self.assertEqual(self.t.row[self.t.width - 2], '<')
        self.t.send(b'\x1b0')
        self.check('a' * 18 + '€', 0, '>')

    def test_history_search_ending_on_utf8(self):
        self.t.send(': abcé\n')
        self.t.send(b'\x1b\x12abc\x1b')
        # Search recall and subsequent end-of-line motion must land on
        # the leading byte of the final character, never its continuation.
        self.t.send(b'$')
        self.check(': abcé', 5)
        self.t.send(b'x')
        self.check(': abc', 4)

    def test_show8_and_ascii_controls(self):
        self.t.send('set -o vi-show8\n')
        self.t.send('é')
        self.check('M-CM-)', 6)
        self.t.send(b'\x15abc\x16\x01')
        self.check('abc^A', 5)
        self.t.send(b'\x1b0x')
        self.check('bc^A', 0)


def case(name, payload, width=80, prompt='P> ', show8=False):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        env = dict(base_env, PS1=prompt, COLUMNS=str(width))
        args = [SHELL, '-o', 'vi']
        if show8:
            args += ['-o', 'vi-show8']
        os.execve(SHELL, args + ['-i'], env)
    output = bytearray()
    eof = False

    def drain(seconds):
        nonlocal eof
        deadline = time.monotonic() + seconds
        while not eof and time.monotonic() < deadline:
            if not select.select([fd], [], [], max(0, deadline-time.monotonic()))[0]:
                break
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b''
            if not data:
                eof = True
            output.extend(data)

    def send(data):
        for start in range(0, len(data), 64):
            if eof:
                return
            chunk = data[start:start+64]
            while chunk:
                try:
                    count = os.write(fd, chunk)
                except OSError:
                    return
                chunk = chunk[count:]
            drain(.01)
        drain(.15)

    done = 0
    try:
        drain(.3)
        send(b': ' + payload)
        # Enter command mode, move both ways, delete/undo, and redraw.
        send(b'\x1b0$xu\x0c\n')
        send(b'printf "VERIFIED:%s\\n" done\n')
        send(b'exit\n')
        deadline = time.monotonic() + 5
        done, status = os.waitpid(pid, os.WNOHANG)
        while not done and time.monotonic() < deadline:
            drain(.1)
            if eof:
                time.sleep(.01)
            done, status = os.waitpid(pid, os.WNOHANG)
        if not done:
            os.kill(pid, signal.SIGKILL)
            done, status = os.waitpid(pid, 0)
        drain(.1)
    finally:
        if not done:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)
    ok = (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
          and b'VERIFIED:done\r\n' in output
          and b'runtime error:' not in output
          and b'AddressSanitizer' not in output)
    print(('PASS ' if ok else 'FAIL ') + 'vi window: ' + name, flush=True)
    if not ok:
        (work / (name + '.log')).write_bytes(output)
    return ok


class ShellResult(unittest.TestResult):
    def report(self, test, ok):
        name = test._testMethodName[len('test_'):].replace('_', ' ')
        print(('PASS ' if ok else 'FAIL ') + 'vi UTF-8: ' + name, flush=True)

    def addSuccess(self, test):
        super().addSuccess(test)
        self.report(test, True)

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.report(test, False)
        print(self.failures[-1][1], file=sys.stderr)

    def addError(self, test, error):
        super().addError(test, error)
        self.report(test, False)
        print(self.errors[-1][1], file=sys.stderr)


class CompletionSession:
    def __init__(self, directory):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(directory)
                fcntl.ioctl(0, termios.TIOCSWINSZ,
                            struct.pack('HHHH', 24, 200, 0, 0))
                env = base_env.copy()
                env.update(HOME=directory, ENV='/dev/null', HISTFILE='/dev/null',
                           PS1='NEXTSH> ', PS2='MORE> ', TERM='xterm',
                           LC_ALL='C.UTF-8')
                env.setdefault('ASAN_OPTIONS', 'detect_leaks=0:abort_on_error=1')
                env.setdefault('UBSAN_OPTIONS', 'halt_on_error=1:print_stacktrace=1')
                os.execve(SHELL, [SHELL, '-i'], env)
            except BaseException:
                os._exit(127)
        self.log = b''

    def read(self, prompt=False):
        data = b''
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], .05)[0]:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b''
                if not chunk:
                    raise AssertionError('shell exited unexpectedly')
                data += chunk
                self.log += chunk
            elif data and (not prompt or data.endswith(b'NEXTSH> ')):
                return data
        raise AssertionError('timed out waiting for ' + ('prompt' if prompt else 'completion'))

    def send(self, data, prompt=False):
        os.write(self.fd, data)
        return self.read(prompt)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)
        os.close(self.fd)


def completion_case(mode, ifs, kind, name=None):
    label = '%s / IFS %s / %s' % (mode, ifs, kind)
    if name is not None:
        label += ' / ' + repr(name)
    session = None
    ok = False
    with tempfile.TemporaryDirectory(prefix='completion-', dir=str(work)) as directory:
        try:
            if kind == 'unique':
                target = name
                os.mkdir(os.path.join(directory, target))
                command = b'cd case\t'
            elif kind == 'nested':
                target = 'case café space/子 😀 folder'
                os.makedirs(os.path.join(directory, target))
                command = b'cd case\t'
            else:
                target = 'case café common-a'
                os.mkdir(os.path.join(directory, target))
                os.mkdir(os.path.join(directory, 'case café common-b'))
                command = b'cd case\t'
            session = CompletionSession(directory)
            session.read(prompt=True)
            session.send(('set -o %s\n' % mode).encode(), prompt=True)
            setting = {'default': ':', 'colon': 'IFS=:', 'empty': "IFS=''",
                       'unset': 'unset IFS', 'newline': "IFS='\n'"}[ifs]
            session.send((setting + '\n').encode(), prompt=True)
            screen = session.send(command)
            if name is None or ' ' in name:
                assert b'\\ ' in screen, 'completion did not escape spaces'
            # Tabs are expanded for terminal display; execution below checks
            # that the completed tab remains part of the directory argument.
            if kind == 'nested':
                session.send('子\t'.encode())
            elif kind == 'common-prefix':
                session.send(b'a\t')
            session.send(b'\n', prompt=True)
            # Check the executed argument, not merely what the terminal echoed.
            result = os.path.join(directory, 'result')
            session.send(('printf \'%s\\n\' "$PWD" > "' + result +
                          '"\n').encode(), prompt=True)
            with open(result, 'rb') as output:
                actual = output.read()
            expected = (os.path.join(directory, target) + '\n').encode()
            assert actual == expected, 'cd reached %r, expected %r' % (actual, expected)
            assert not any(report in session.log for report in
                           (b'AddressSanitizer', b'UndefinedBehaviorSanitizer',
                            b'runtime error:')), 'sanitizer report'
            ok = True
            print('PASS completion: ' + label, flush=True)
        except Exception as error:
            print('FAIL completion: ' + label, flush=True)
            print(label + ': ' + str(error), file=sys.stderr)
            if session is not None:
                log = work / ('completion-%s-%s-%s.log' % (mode, ifs,
                              kind if name is None else names.index(name)))
                log.write_bytes(session.log)
                print('  PTY log:', log, file=sys.stderr)
        finally:
            if session is not None:
                session.close()
    return ok


utf8_result = ShellResult()
unittest.defaultTestLoader.loadTestsFromTestCase(ViUTF8).run(utf8_result)

names = ['case ascii space', 'case café space', 'case 子 folder',
         'case 😀 folder', 'case é子😀 two spaces', 'case space before é',
         'case é $cash;[x]', 'case é\ttab']
completion_results = []
for mode in ('vi', 'emacs'):
    for ifs in ('default', 'colon', 'empty', 'unset', 'newline'):
        for name in names:
            completion_results.append(completion_case(mode, ifs, 'unique', name))
        completion_results.append(completion_case(mode, ifs, 'nested'))
        completion_results.append(completion_case(mode, ifs, 'common-prefix'))

payloads = [
    ('ascii', b'a' * 300),
    ('utf2', ('é' * 200).encode()),
    ('utf3', ('界' * 200).encode()),
    ('utf4', ('😀' * 200).encode()),
    ('continuations', b'\x80' * 4093),  # LINE - 1, including ': '
    ('truncated', b'\xe2\x82' * 1500),
    ('mixed', ('abcé界😀' * 150).encode()),
]
results = []
for width in (12, 20, 80, 132, 256):
    for name, payload in payloads:
        results.append(case(name + '-w' + str(width), payload, width))
results.append(case('empty-prompt', b'a' * 300, prompt=''))
results.append(case('long-prompt', ('界é😀' * 200).encode(), prompt='prompt' * 40))
results.append(case('show8', b'\x80\xff' * 1500, show8=True))
ok = (utf8_result.wasSuccessful() and all(results)
      and all(completion_results))
if ok:
    shutil.rmtree(work)
else:
    print('PTY failure logs:', work, file=sys.stderr)
sys.exit(0 if ok else 1)
PY_PTY
	pty_status=$?
	pty_fail=0
	while read -r result name; do
		N=$((N + 1))
		printf 'Test %d: "%s"\n' "$N" "$name"
		case $result in
		PASS) PASS=$((PASS + 1)) ;;
		*)
			FAIL=$((FAIL + 1))
			pty_fail=$((pty_fail + 1))
			printf 'FAIL\n'
			;;
		esac
	done < "$TMPFILE"
	# A missing module, exec failure, or other driver error must not be
	# mistaken for success just because it produced no failure records.
	if [ "$pty_status" -ne 0 ] && [ "$pty_fail" -eq 0 ]; then
		N=$((N + 1))
		FAIL=$((FAIL + 1))
		printf 'Test %d: "PTY test driver"\nFAIL (exit %d)\n' "$N" "$pty_status"
	fi
else
	N=$((N + 1))
	FAIL=$((FAIL + 1))
	printf 'Test %d: "PTY test driver"\nFAIL (Python 3 is required)\n' "$N"
fi

printf '\n%s\n' '─── Summary ──────────────────────────────────────────────────────────────────'

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
