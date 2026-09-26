#!/usr/bin/env python3
"""Exercise vi window buffers through a PTY; use an ASan/UBSan shell build.

Usage: python3 tests/vi-window.py ./sh
Only summaries are printed. Failed sessions are saved in a temporary directory.
"""
import fcntl
import os
import pathlib
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time

binary = str(pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else './sh').resolve())
work = pathlib.Path(tempfile.mkdtemp(prefix='nextsh-vi-window-'))


def case(name, payload, width=80, prompt='P> ', show8=False):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
        env = dict(os.environ, PS1=prompt, ENV='/dev/null', HOME=str(work),
                   HISTFILE='/dev/null', TERM='xterm', LC_ALL='C.UTF-8',
                   COLUMNS=str(width), ASAN_OPTIONS='detect_leaks=0:halt_on_error=1',
                   UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
        args = [binary, '-o', 'vi']
        if show8:
            args += ['-o', 'vi-show8']
        os.execve(binary, args + ['-i'], env)
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
            _, status = os.waitpid(pid, 0)
        drain(.1)
    finally:
        os.close(fd)
    ok = (os.waitstatus_to_exitcode(status) == 0
          and b'VERIFIED:done\r\n' in output
          and b'runtime error:' not in output
          and b'AddressSanitizer' not in output)
    print(('PASS ' if ok else 'FAIL ') + name, flush=True)
    if not ok:
        (work / (name + '.log')).write_bytes(output)
    return ok


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
print('%d/%d passed' % (sum(results), len(results)))
if not all(results):
    print('Failure logs:', work)
sys.exit(0 if all(results) else 1)
