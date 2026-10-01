#!/bin/sh
# Nextsh test suite - POSIX shell
# Basic sanity checks, then the lexer, mostly the parts that scan the
# raw text of a $(..) body: quoting, here documents, comments and case
# patterns. Also tests bad substitutions, arithmetic limits, deep
# nesting, and vi-mode UTF-8 redraw, window buffers and completion
# through a PTY (requires script(1)). Finally runs the test suites of
# FreeBSD sh, smoosh and yash (see "Established test suites"); SUITES=
# skips them.
#
# The shell under test is $SH (./sh by default), the shell running this
# script can be any POSIX shell.

SH=${SH:-./sh}
PASS=0
FAIL=0
SKIP=0
N=0

TMPFILE=$(mktemp /tmp/nextsh_test_XXXXXX)
trap 'rm -rf "$TMPFILE" "$TMPFILE.d"' EXIT

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

printf '%s\n' '─── Basics ───────────────────────────────────────────────────────────────────'

t 'arithmetic' '21' <<'S'
echo $((3 * (2 + 5)))
S

t 'expansion' 'def abc 6' <<'S'
x=abcdef; echo ${x#abc} ${x%def} ${#x}
S

t 'command sub' 'nested deep' <<'S'
echo $(echo nested $(echo deep))
S

t 'loops' '123' <<'S'
for i in 1 2 3; do printf "%s" "$i"; done; echo
S

t 'functions' 'ab' <<'S'
f() { echo "$1$2"; }; f a b
S

t 'case' 'match' <<'S'
case foobar in foo*) echo match;; *) echo no;; esac
S

t 'test' 'yes' <<'S'
[ 2 -gt 1 ] && [[ ab == a? ]] && echo yes
S

t 'printf' 'str-007-ff' <<'S'
printf "%s-%03d-%x\n" str 7 255
S

t 'typeset' '9' <<'S'
typeset -i n=010; echo $((n + 1))
S

t 'here doc' 'here 2' <<'S'
cat <<EOF
here $((1 + 1))
EOF
S

t 'pipeline' 'two' <<'S'
echo one two three | tr " " "\n" | sed -n 2p
S

t 'subshell' '1' <<'S'
x=1; (x=2); echo $x
S

t 'trap' 'caught
after' <<'S'
trap "echo caught" USR1; kill -USR1 $$; echo after
S

t 'exit status' '1' <<'S'
false; echo $?
S

t 'aliases' 'aliased' <<'S'
alias hi="echo aliased"
hi
S

printf '\n%s\n' '─── Quoting inside $(..)─────────────────────────────────────────────────────'

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

printf '%s\n' '─── Bad substitutions and read-only variables ────────────────────────────────'

# these used to read and write past the end of the word before printing
# the error; the overflow itself only shows up with SH set to a
# -fsanitize=address build, which dies before the message is printed
t 'bad substitution ${x/a/b}' '${x/l/L}: bad substitution' <<'S'
x=hello
(echo ${x/l/L}) 2>&1 | sed 's/^[^[]*\[[0-9]*\]: //'
S

t 'bad substitution ${x:n}' '${x:2}: bad substitution' <<'S'
x=hello
(echo ${x:2}) 2>&1 | sed 's/^[^[]*\[[0-9]*\]: //'
S

t 'bad substitution inside a word' '${x/l/L}: bad substitution' <<'S'
x=hello
(echo "a${x/l/L}b$x") 2>&1 | sed 's/^[^[]*\[[0-9]*\]: //'
S

t 'bad substitution on positional parameters' '${@#a}: bad substitution' <<'S'
set -- a b
(echo ${@#a} ${*:1}) 2>&1 | sed 's/^[^[]*\[[0-9]*\]: //'
S

t 'shell continues after a bad substitution' 'after 1' <<'S'
x=hello
(echo ${x/l/L}) 2>/dev/null; echo "after $?"
S

t 'bad substitution inside $(..)' 'after' <<'S'
x=$(x=a; echo ${x/a/b}) 2>/dev/null; echo after
S

t 'read-only variable with a short name' 'x1 y' <<'S'
readonly a=1
echo ${a+x}${a:-z} ${b-y}
S

t 'read-only special variable' 'set' <<'S'
echo ${PPID+set}
S

t 'several read-only variables in one word' '1-2' <<'S'
readonly a=1 bb=2
echo "${a}-${bb:+$bb}"
S

printf '%s\n' '─── Arithmetic limits ────────────────────────────────────────────────────────'

# overflow used to be undefined behaviour that happened to give these
# results on common hardware; run with SH set to a -fsanitize=undefined
# build and UBSAN_OPTIONS=halt_on_error=1 to catch regressions

t 'x++ and x-- keep 64 bits' '4294967296 4294967297 4294967297 4294967296' <<'S'
x=4294967296
echo $((x++)) $x $((x--)) $x
S

t 'addition and subtraction wrap' '-9223372036854775808 9223372036854775807' <<'S'
echo $((9223372036854775807 + 1)) $((-9223372036854775807 - 2))
S

t 'multiplication wraps' '-2 0' <<'S'
echo $((9223372036854775807 * 2)) $(((1 << 62) * 4))
S

t 'increment wraps' '-9223372036854775808 -9223372036854775807' <<'S'
x=9223372036854775807
echo $((x += 1)) $((++x))
S

t 'negating INT64_MIN' '-9223372036854775808 -9223372036854775808' <<'S'
echo $((-9223372036854775807 - 1)) $((-(-9223372036854775807 - 1)))
S

t 'INT64_MIN divided by -1' '-9223372036854775808 0' <<'S'
echo $(((-9223372036854775807 - 1) / -1)) $(((-9223372036854775807 - 1) % -1))
S

t 'INT64_MIN in a variable and in base 2' '-9223372036854775808 -2#1000000000000000000000000000000000000000000000000000000000000000' <<'S'
x=-9223372036854775808
typeset -i2 b=x
echo $((x)) $b
S

t 'shift counts are taken modulo 64' '1 -9223372036854775808 -4 2' <<'S'
echo $((1 << 64)) $((1 << -1)) $((-8 >> 1)) $((4 >> 65))
S

t 'literals too large for 64 bits wrap' '7766279631452241919 -1' <<'S'
echo $((99999999999999999999)) $((16#ffffffffffffffffff))
S

terr 'base out of range' <<'S'
echo $((99#1))
S

printf '%s\n' '─── Deep nesting ─────────────────────────────────────────────────────────────'

# these used to overflow the stack and crash
t 'runaway function recursion' 'after' <<'S'
f() { f; }
f 2>/dev/null; echo after
S

t 'runaway recursion through eval' 'after' <<'S'
f() { eval f; }
f 2>/dev/null; echo after
S

t 'deeply nested subshells' 'after 1' <<'S'
o=$(printf '%200000s' | tr ' ' '(')
c=$(printf '%200000s' | tr ' ' ')')
(eval "$o:$c") 2>/dev/null; echo "after $?"
S

t 'deeply nested groups' 'after 1' <<'S'
o=$(printf '%200000s' | sed 's/ /{ /g')
c=$(printf '%200000s' | sed 's/ /;}/g')
(eval "$o:$c") 2>/dev/null; echo "after $?"
S

t 'deeply nested arithmetic' 'after 1' <<'S'
o=$(printf '%20000s' | tr ' ' '(')
c=$(printf '%20000s' | tr ' ' ')')
(eval "echo \$(($o 1 $c))") 2>/dev/null; echo "after $?"
S

t 'deeply nested test negation' 'after 1' <<'S'
(test $(printf '%300000s' | sed 's/ /! /g') x) 2>/dev/null; echo "after $?"
S

t 'deeply nested [[ ]]' 'after 1' <<'S'
o=$(printf '%100000s' | sed 's/ /( /g')
c=$(printf '%100000s' | sed 's/ / )/g')
(eval "[[ $o x $c ]]") 2>/dev/null; echo "after $?"
S

t 'nesting within the limit still works' '1000 3' <<'S'
f() { [ $1 -lt 1000 ] && f $(($1 + 1)) || echo $1; }
echo $(f 0) $(( ((((((((1)))))))) + ((((((((2)))))))) ))
S

printf '%s\n' '─── Interactive editing and completion ───────────────────────────────────────'

# The interactive tests type into "$SH -i" on a pseudo-terminal made by
# script(1). The whole input is typed ahead, without waiting for the
# shell: the terminal is set to raw mode without echo before the shell
# starts, so the line discipline neither echoes nor interprets anything
# (^U, ^V, ^R, ...), and the editor, which reads one byte at a time,
# sees the same bytes as from a typist. No sleeps, so each session takes
# a few milliseconds.

# pass name, fail name reason: record the result of an interactive test;
# a failure keeps what the shell wrote to the terminal as a log
pass() {
	N=$((N + 1))
	PASS=$((PASS + 1))
	printf 'Test %d: "%s"\n' "$N" "$1"
}
fail() {
	N=$((N + 1))
	FAIL=$((FAIL + 1))
	cp "$OUT" "$TMPFILE.$N.log"
	printf 'Test %d: "%s"\nFAIL\n  %s\n  PTY log: %s\n' \
		"$N" "$1" "$2" "$TMPFILE.$N.log"
}

# Run in the pseudo-terminal: make it raw and W columns wide, tell the
# typist (waiting on the fifo F) to start, then start the shell.
PTYCMD='stty rows 24 cols "$W" -echo -icanon -isig -ixon -iexten min 1 time 0
echo > "$F"
PS1=$P PS2="+ " exec "$SH" $A -i'

if ! command -v script >/dev/null 2>&1; then
	PTY=
elif script -V 2>/dev/null | grep util-linux >/dev/null; then
	PTY=util-linux
	runpty() { exec script -qec "$PTYCMD" /dev/null; }
else
	PTY=bsd
	runpty() { exec script -q /dev/null /bin/sh -c "$PTYCMD"; }
fi

# pty width prompt dir [args]: type the file $IN into "$SH args -i" run
# in dir on a pseudo-terminal of the given width, saving what the shell
# writes to the terminal in $OUT. Returns the shell's exit status; a
# shell still running after 10 seconds is killed, returning 124.
#
# The typist waits on the fifo $RDY for the terminal to be set up, and
# keeps script's input open until script exits: on end of input script
# waits up to 2 seconds for the shell to read everything.
pty() {
	pw=$1 pp=$2 pd=$3
	shift 3
	{ read -r _ < "$RDY"; cat "$IN"; read -r _ < "$RDY"; } > "$TTY" 2>/dev/null &
	typist=$!
	(
		cd "$pd" || exit 1
		W=$pw P=$pp F=$RDY A="$*" SHELL=/bin/sh HOME=$pd COLUMNS=$pw
		ENV=/dev/null HISTFILE=/dev/null TERM=xterm LC_ALL=C.UTF-8
		export SH W P F A SHELL HOME COLUMNS ENV HISTFILE TERM LC_ALL
		runpty
	) < "$TTY" > "$OUT" 2>&1 &
	pid=$!
	{
		trap 'kill "$s"; exit' TERM
		sleep 10 & s=$!
		wait "$s" && : > "$PTYDIR/timeout" && kill -9 "$pid"
	} > /dev/null 2>&1 &
	dog=$!
	wait "$pid" 2>/dev/null
	st=$?
	kill "$typist" "$dog" 2>/dev/null
	wait "$typist" "$dog" 2>/dev/null
	[ ! -e "$PTYDIR/timeout" ] || { rm -f "$PTYDIR/timeout"; st=124; }
	return "$st"
}

# sanitized: a sanitizer reported an error in $OUT
sanitized() {
	LC_ALL=C grep -e 'runtime error:' -e AddressSanitizer \
		-e UndefinedBehaviorSanitizer "$OUT" >/dev/null
}

# A single line terminal, as wide as $W, emulated over $OUT up to the
# last ^C (typed to end the session). Each UTF-8 character takes one
# column, as the editor assumes. Checks that the row is "> $T" followed
# by blanks with the cursor on character $C of $T (or skips that check
# when $C is empty), and that the window marker is $M.
SCREEN='
BEGIN {
	for (i = 128; i < 192; i++)
		cont = cont sprintf("%c", i)
	w = ENVIRON["W"] + 0
	for (i = 0; i < w; i++)
		row[i] = " "
}
{ buf = buf (NR > 1 ? "\n" : "") $0 }
function clear(	i) { for (i = 0; i < w; i++) row[i] = " " }
END {
	for (p = 0; (i = index(substr(buf, p + 1), "^C")) > 0; p += i)
		;
	if (!p)
		bad = " (no ^C)"
	n = p - 1
	col = 0
	last = -1
	for (k = 1; k <= n; k++) {
		c = substr(buf, k, 1)
		if (esc != "") {
			esc = esc c
			if (esc != "\033[" && c ~ /[A-Za-z]/) {
				if (c == "H")
					col = 0
				else if (c == "J" || c == "K")
					clear()
				else
					bad = bad " (unexpected escape ^[" substr(esc, 2) ")"
				esc = ""
			}
			continue
		}
		if (index(cont, c) && last >= 0) {
			row[last] = row[last] c
			continue
		}
		last = -1
		if (c == "\033")
			esc = c
		else if (c == "\r")
			col = 0
		else if (c == "\n")
			clear()
		else if (c == "\b")
			col -= col > 0
		else if (c != "\007") {
			if (col < w)
				row[last = col] = c
			col++
		}
	}
	t = "> " ENVIRON["T"]
	nt = 0
	for (k = 1; k <= length(t); k++) {
		c = substr(t, k, 1)
		if (index(cont, c) && nt)
			e[nt - 1] = e[nt - 1] c
		else
			e[nt++] = c
	}
	ok = bad == ""
	if (ENVIRON["C"] != "") {
		for (i = 0; i < w - 2; i++)
			if (row[i] != (i < nt ? e[i] : " "))
				ok = 0
		if (col != ENVIRON["C"] + 2)
			ok = 0
	}
	if (row[w - 2] != ENVIRON["M"])
		ok = 0
	if (!ok) {
		s = ""
		for (i = 0; i < w; i++)
			s = s row[i]
		printf "screen |%s| cursor %d%s\n", s, col, bad
	}
	exit !ok
}'

# vi_start name: start a vi UTF-8 test on a 24 column terminal
# vt keys text cursor [marker]: type keys (a printf format) after those
# typed so far, then check that the screen shows text with the cursor on
# its character cursor (any text and cursor when both are empty) and the
# window marker (blank by default). Every check is a new session that
# types all the keys and ends with ^C.
vi_start() {
	vname=$1 vkeys= vstep=0
}
vt() {
	vkeys=$vkeys$1 vstep=$((vstep + 1))
	printf "$vkeys\\003exit\\n" > "$IN"
	pty 24 '> ' "$PTYDIR" -o vi
	if [ $? -eq 124 ]; then
		fail "vi UTF-8: $vname ($vstep)" 'timed out'
	elif res=$(W=24 T=$2 C=$3 M=${4:- } LC_ALL=C awk "$SCREEN" "$OUT") &&
	    ! sanitized; then
		pass "vi UTF-8: $vname ($vstep)"
	else
		fail "vi UTF-8: $vname ($vstep)" "${res:-sanitizer report}"
	fi
}

# win name width prompt payload [args]: type the payload file in a long
# line in vi mode, move both ways, delete and undo, redraw, then run it;
# the shell must survive and still run commands
win() {
	wname=$1 wwidth=$2 wprompt=$3 wpay=$4
	shift 4
	{
		printf ': '
		cat "$wpay"
		printf '\0330$xu\014\nprintf "VERIFIED:%%s\\n" done\nexit\n'
	} > "$IN"
	pty "$wwidth" "$wprompt" "$PTYDIR" -o vi "$@"
	st=$?
	if [ "$st" -ne 0 ]; then
		fail "vi window: $wname" "exit status $st"
	elif ! LC_ALL=C grep "VERIFIED:done$CR\$" "$OUT" >/dev/null; then
		fail "vi window: $wname" 'no VERIFIED:done'
	elif sanitized; then
		fail "vi window: $wname" 'sanitizer report'
	else
		pass "vi window: $wname"
	fi
}

# comp mode ifs kind [name]: in mode with IFS set as named by ifs, cd into
# the directory name (kind unique), a nested directory (kind nested) or
# one of two directories with a common prefix (kind common-prefix) using
# completion; the shell must have escaped the spaces and reached it
comp() {
	cmode=$1 cifs=$2 ckind=$3 cname=$4
	cdir=$PTYDIR/c$N
	mkdir "$cdir"
	case $ckind in
	unique)
		ctarget=$cname more=
		mkdir "$cdir/$ctarget"
		;;
	nested)
		ctarget='case café space/子 😀 folder' more='子\t'
		mkdir -p "$cdir/$ctarget"
		;;
	*)
		ctarget='case café common-a' more='a\t'
		mkdir "$cdir/$ctarget" "$cdir/case café common-b"
		;;
	esac
	case $cifs in
	default) cset=: ;;
	colon) cset=IFS=: ;;
	empty) cset="IFS=''" ;;
	unset) cset='unset IFS' ;;
	newline) cset="IFS='$NL'" ;;
	esac
	{
		printf 'set -o %s\n%s\ncd case\t' "$cmode" "$cset"
		printf "$more"
		printf '\nprintf %s "$PWD" > %s/result\nexit\n' "'%s\\n'" "$cdir"
	} > "$IN"
	clabel="completion: $cmode / IFS $cifs / $ckind${cname:+ / $cname}"
	pty 200 'NEXTSH> ' "$cdir"
	st=$?
	if [ "$st" -ne 0 ]; then
		fail "$clabel" "exit status $st"
	elif ! printf '%s\n' "$cdir/$ctarget" | cmp -s - "$cdir/result"; then
		fail "$clabel" "cd reached $(cat "$cdir/result" 2>/dev/null)"
	elif ! grep -F '\ ' "$OUT" >/dev/null; then
		fail "$clabel" 'completion did not escape spaces'
	elif sanitized; then
		fail "$clabel" 'sanitizer report'
	else
		pass "$clabel"
	fi
}

# rep string count: string repeated count times
rep() {
	printf "%$2s" '' | LC_ALL=C sed "s/ /$1/g"
}

if [ -z "$PTY" ] || ! command -v mkfifo >/dev/null 2>&1; then
	N=$((N + 1))
	FAIL=$((FAIL + 1))
	printf 'Test %d: "PTY test driver"\nFAIL (script(1) and mkfifo are required)\n' "$N"
else
	case $SH in
	*/*) SH=$(cd "${SH%/*}" && pwd)/${SH##*/} ;;
	esac
	: "${ASAN_OPTIONS=detect_leaks=0:halt_on_error=1}"
	: "${UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1}"
	export ASAN_OPTIONS UBSAN_OPTIONS
	PTYDIR=$TMPFILE.d
	mkdir "$PTYDIR"
	RDY=$PTYDIR/rdy TTY=$PTYDIR/tty IN=$PTYDIR/in OUT=$PTYDIR/out
	mkfifo "$RDY" "$TTY"
	CR=$(printf '\r')
	NL='
'
	TAB=$(printf '\t')

	vi_start 'insert move delete and redraw'
	vt 'aé€𝄞z'		'aé€𝄞z' 5
	vt '\033hh'		'aé€𝄞z' 2
	vt 'x'			'aé𝄞z' 2
	vt 'iX\033'		'aéX𝄞z' 2
	vt '\014'		'aéX𝄞z' 2

	vi_start 'different UTF-8 lengths and shared prefix'
	vt 'éê€𝄞abc\0330x'	'ê€𝄞abc' 0
	vt 'x'			'€𝄞abc' 0
	vt 'iZ\033'		'Z€𝄞abc' 0
	vt 'lx'			'Z𝄞abc' 1

	# The bytes of a character arrive one by one, as the editor
	# always reads them.
	vi_start 'fragmented input'
	vt 'é€𝄞'		'é€𝄞' 3
	vt '\177'		'é€' 2
	vt '\0330iê'		'êé€' 1
	vt '\033l'		'êé€' 1

	# winwidth = 24 - 2 (prompt) - 3 = 19; a command-mode character
	# in its last column must include all its bytes.
	vi_start 'right margin and scrolling'
	a18=aaaaaaaaaaaaaaaaaa
	vt "$a18\\033a€\\0330\$"	"$a18€" 18
	vt '\014'		"$a18€" 18
	vt 'Aê𝄞xyz'		'' '' '<'
	vt '\0330'		"$a18€" 0 '>'

	# Search recall and subsequent end-of-line motion must land on the
	# leading byte of the final character, never its continuation.
	vi_start 'history search ending on UTF-8'
	vt ': abcé\n\033\022abc\033$'	': abcé' 5
	vt 'x'			': abc' 4

	vi_start 'show8 and ASCII controls'
	vt 'set -o vi-show8\né'	'M-CM-)' 6
	vt '\025abc\026\001'	'abc^A' 5
	vt '\0330x'		'bc^A' 0

	set -- 'case ascii space' 'case café space' 'case 子 folder' \
		'case 😀 folder' 'case é子😀 two spaces' 'case space before é' \
		'case é $cash;[x]' "case é${TAB}tab"
	for mode in vi emacs; do
		for ifs in default colon empty unset newline; do
			for name do
				comp "$mode" "$ifs" unique "$name"
			done
			comp "$mode" "$ifs" nested
			comp "$mode" "$ifs" common-prefix
		done
	done

	P=$PTYDIR/p
	rep a 300 > "$P.ascii"
	rep é 200 > "$P.utf2"
	rep 界 200 > "$P.utf3"
	rep 😀 200 > "$P.utf4"
	rep "$(printf '\200')" 4093 > "$P.continuations"  # LINE - 1 with ': '
	rep "$(printf '\342\202')" 1500 > "$P.truncated"
	rep 'abcé界😀' 150 > "$P.mixed"
	rep '界é😀' 200 > "$P.long-prompt"
	rep "$(printf '\200\377')" 1500 > "$P.show8"
	for width in 12 20 80 132 256; do
		for pay in ascii utf2 utf3 utf4 continuations truncated mixed; do
			win "$pay-w$width" "$width" 'P> ' "$P.$pay"
		done
	done
	win empty-prompt 80 '' "$P.ascii"
	win long-prompt 80 "$(rep prompt 40)" "$P.long-prompt"
	win show8 80 'P> ' "$P.show8" -o vi-show8
	rm -rf "$PTYDIR"
fi

printf '\n%s\n' '─── Established test suites ──────────────────────────────────────────────────'

# Test suites of other shells, embedded verbatim and run against $SH the
# way their own harnesses would. Expected stderr is compared exactly, so
# a few tests fail only on the wording of a diagnostic.
#
#   fbsd    FreeBSD bin/sh/tests, BSD-2-Clause
#           freebsd-src 43b0384bc7e87df5bd164ce833617e68824f4828
#   smoosh  smoosh tests/shell and tests/util, MIT, (c) Michael Greenberg
#           mgree/smoosh cc67dbe6a4953e51431997eac025b5e3f46c3d2d
#   yash    yash tests/*-p.tst (the POSIX subset), GPL-2.0-or-later,
#           (c) magicant; run by a re-implementation of run-test.sh
#           magicant/yash 0105ae707bce655034522372f8b2a20072819c28
#
# Some of these test behaviour that POSIX leaves unspecified or that is
# an extension of the shell they come from. SUITES selects which suites
# to run; set it to the empty string to skip them all. If timeout(1) is
# available, each fbsd and smoosh test is killed after 30 seconds and
# each yash test file after 300 (not each yash test: timeout(1) would
# reset the ignored signals its signal tests rely on). The yash harness
# runs under $HSH, by default the first of dash, yash, bash, mksh, ksh
# and sh found, since /bin/sh may well be the shell under test.

SUITES=${SUITES-fbsd smoosh yash}
EXT=$TMPFILE.d/ext
XW=$EXT/w
NL='
'
mkdir -p "$EXT"
SHABS=$(command -v -- "$SH")
case $SHABS in /*) ;; *) SHABS=$PWD/$SHABS ;; esac
# The yash harness needs a trustworthy shell; /bin/sh may be nextsh
HSH=${HSH-}
if [ -z "$HSH" ]; then
	for h in dash yash 'bash --posix' mksh ksh sh; do
		if command -v ${h%% *} >/dev/null 2>&1; then HSH=$h; break; fi
	done
fi
if timeout --foreground -k 5 1 true 2>/dev/null; then
	TIMEOUT='timeout --foreground -k 5'
elif timeout 1 true 2>/dev/null; then
	TIMEOUT='timeout'
else
	TIMEOUT=
fi

# put: save stdin as $EXT/$1; with -n, without its final newline
put() {
	mkdir -p "$EXT/${1%/*}"
	if [ "${2-}" = -n ]; then
		awk 'NR > 1 { printf "\n" } { printf "%s", $0 }' > "$EXT/$1"
	else
		cat > "$EXT/$1"
	fi
}

# ext_result: record test $1; $2 is empty if it passed, SKIP if it was
# skipped, otherwise what went wrong
ext_result() {
	N=$((N + 1))
	printf 'Test %d: "%s"\n' "$N" "$1"
	case $2 in
	'')	PASS=$((PASS + 1)) ;;
	SKIP)	SKIP=$((SKIP + 1)); printf 'SKIP\n' ;;
	*)	FAIL=$((FAIL + 1)); printf 'FAIL\n%s\n' "$2" | sed '2,$s/^/  /' ;;
	esac
}

# ext_diff: describe how actual output $3 differs from expected $2
ext_diff() {
	printf '%s differs (-expected +actual):\n' "$1"
	diff -u "$2" "$3" 2>/dev/null | sed '1,2d' | head -n 20
}

# ext_run: run script $1 in an empty directory, set st, $XW.out, $XW.err
ext_run() {
	rm -rf "$XW" && mkdir "$XW" && (
		cd "$XW" || exit 125
		export SH="$SHABS" TEST_SHELL="$SHABS" TEST_UTIL="$EXT/smoosh/util"
		exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
		exec ${TIMEOUT:+$TIMEOUT 30} "$SHABS" "$1" >"$XW.out" 2>"$XW.err" </dev/null
	)
	st=$?
	rm -rf "$XW"
}

# ext_err: compare stderr $XW.err with the expected file $1
ext_err() {
	cmp -s "$1" "$XW.err" || ext_diff stderr "$1" "$XW.err"
}
put fbsd/builtins/alias.0 <<'EOF'
set -e

unalias -a
alias foo=bar
alias bar=
alias quux="1 2 3"
alias
alias foo
EOF
put fbsd/builtins/alias.0.stdout <<'EOF'
bar=''
foo=bar
quux='1 2 3'
foo=bar
EOF
put fbsd/builtins/alias.1 <<'EOF'
unalias -a
alias foo
EOF
put fbsd/builtins/alias.1.stderr <<'EOF'
alias: foo: not found
EOF
put fbsd/builtins/alias3.0 <<'EOF'
set -e

unalias -a
alias foo=bar
alias bar=
alias quux="1 2 3"
alias foo=bar
alias bar=
alias quux="1 2 3"
alias
alias foo
EOF
put fbsd/builtins/alias3.0.stdout <<'EOF'
bar=''
foo=bar
quux='1 2 3'
foo=bar
EOF
put fbsd/builtins/alias4.0 <<'EOF'

unalias -a
alias --
EOF
put fbsd/builtins/break1.0 <<'EOF'

if [ "$1" != nested ]; then
	while :; do
		set -- nested
		. "$0"
		echo bad2
		exit 2
	done
	exit 0
fi
# To trigger the bug, the following commands must be at the top level,
# with newlines in between.
break
echo bad1
exit 1
EOF
put fbsd/builtins/break2.0 <<'EOF'

# It is not immediately obvious that this should work, and someone probably
# relies on it.

while :; do
	trap 'break' USR1
	kill -USR1 $$
	echo bad
	exit 1
done
echo good
EOF
put fbsd/builtins/break2.0.stdout <<'EOF'
good
EOF
put fbsd/builtins/break3.0 <<'EOF'

# We accept this and people might rely on it.
# However, various other shells do not accept it.

f() {
	break
	echo bad1
}

while :; do
	f
	echo bad2
	exit 2
done
EOF
put fbsd/builtins/break4.4 <<'EOF'

# Although this is not specified by POSIX, some configure scripts (gawk 4.1.0)
# appear to depend on it.

break
exit 4
EOF
put fbsd/builtins/break5.4 <<'EOF'

# Although this is not specified by POSIX, some configure scripts (gawk 4.1.0)
# appear to depend on it.
# In some uncommitted code, the subshell environment corrupted the outer
# shell environment's state.

(for i in a b c; do
	exit 3
done)
break
exit 4
EOF
put fbsd/builtins/break6.0 <<'EOF'
# Per POSIX, this need only work if LONG_MAX > 4294967295.

while :; do
	break 4294967296
	echo bad
	exit 3
done
EOF
put fbsd/builtins/builtin1.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

builtin : || echo "Bad return code at $LINENO"
builtin true || echo "Bad return code at $LINENO"
builtin ls 2>/dev/null && echo "Bad return code at $LINENO"
check '"$(builtin pwd)" = "$(pwd)"'
check '-z "$(builtin :)"'
check '-z "$(builtin true)"'
check '-z "$( (builtin nosuchtool) 2>/dev/null)"'
check '-z "$(builtin nosuchtool 2>/dev/null)"'
check '-z "$(builtin nosuchtool 2>/dev/null; :)"'
check '-z "$( (builtin ls) 2>/dev/null)"'
check '-z "$(builtin ls 2>/dev/null)"'
check '-z "$(builtin ls 2>/dev/null; :)"'
check '-n "$( (builtin nosuchtool) 2>&1)"'
check '-n "$(builtin nosuchtool 2>&1)"'
check '-n "$(builtin nosuchtool 2>&1; :)"'
check '-n "$( (builtin ls) 2>&1)"'
check '-n "$(builtin ls 2>&1)"'
check '-n "$(builtin ls 2>&1; :)"'

exit $((failures > 0))
EOF
put fbsd/builtins/case1.0 <<'EOF'
f()
{
	false
	case $1 in
	foo) true ;;
	bar) false ;;
	esac
}

f foo || exit 1
f bar && exit 1
f quux || exit 1
EOF
put fbsd/builtins/case10.0 <<'EOF'

case ! in
[\!!]) ;;
*) echo Failed at $LINENO ;;
esac

case ! in
['!'!]) ;;
*) echo Failed at $LINENO ;;
esac

case ! in
["!"!]) ;;
*) echo Failed at $LINENO ;;
esac
EOF
put fbsd/builtins/case11.0 <<'EOF'

false
case x in
*)
esac
EOF
put fbsd/builtins/case12.0 <<'EOF'

false
case x in
y)
esac
EOF
put fbsd/builtins/case13.0 <<'EOF'

case ^ in
[\^^]) ;;
*) echo Failed at $LINENO ;;
esac

case s in
[\^^]) echo Failed at $LINENO ;;
[s\]]) ;;
*) echo Failed at $LINENO ;;
esac
EOF
put fbsd/builtins/case14.0 <<'EOF'

case `false` in
no) exit 3 ;;
esac
EOF
put fbsd/builtins/case15.0 <<'EOF'

case x in
`false`) exit 3 ;;
esac
EOF
put fbsd/builtins/case16.0 <<'EOF'

f() { return 42; }
f
case x in
x) [ $? = 42 ] ;;
esac
EOF
put fbsd/builtins/case17.0 <<'EOF'

! case x in x) false ;& y) esac
EOF
put fbsd/builtins/case18.0 <<'EOF'

case x$(false) in
x)	;&
y)	[ $? != 0 ] ;;
z)	false ;;
esac
EOF
put fbsd/builtins/case19.0 <<'EOF'

[ "`case x in
x)	false ;&
y)	;&
z)	echo $? ;;
esac`" != 0 ]
EOF
put fbsd/builtins/case2.0 <<'EOF'
# Generated by ./test-fnmatch -s 1, do not edit.
failures=
failed() { printf '%s\n' "Failed: $1 '$2' '$3'"; failures=x$failures; }
testmatch() { eval "case \$2 in ''$1) ;; *) failed testmatch \"\$@\";; esac"; }
testnomatch() { eval "case \$2 in ''$1) failed testnomatch \"\$@\";; esac"; }
testmatch '' ''
testmatch 'a' 'a'
testnomatch 'a' 'b'
testnomatch 'a' 'A'
testmatch '*' 'a'
testmatch '*' 'aa'
testmatch '*a' 'a'
testnomatch '*a' 'b'
testnomatch '*a*' 'b'
testmatch '*a*b*' 'ab'
testmatch '*a*b*' 'qaqbq'
testmatch '*a*bb*' 'qaqbqbbq'
testmatch '*a*bc*' 'qaqbqbcq'
testmatch '*a*bb*' 'qaqbqbb'
testmatch '*a*bc*' 'qaqbqbc'
testmatch '*a*bb' 'qaqbqbb'
testmatch '*a*bc' 'qaqbqbc'
testnomatch '*a*bb' 'qaqbqbbq'
testnomatch '*a*bc' 'qaqbqbcq'
testnomatch '*a*a*a*a*a*a*a*a*a*a*' 'aaaaaaaaa'
testmatch '*a*a*a*a*a*a*a*a*a*a*' 'aaaaaaaaaa'
testmatch '*a*a*a*a*a*a*a*a*a*a*' 'aaaaaaaaaaa'
testnomatch '.*.*.*.*.*.*.*.*.*.*' '.........'
testmatch '.*.*.*.*.*.*.*.*.*.*' '..........'
testmatch '.*.*.*.*.*.*.*.*.*.*' '...........'
testnomatch '*?*?*?*?*?*?*?*?*?*?*' '123456789'
testnomatch '??????????*' '123456789'
testnomatch '*??????????' '123456789'
testmatch '*?*?*?*?*?*?*?*?*?*?*' '1234567890'
testmatch '??????????*' '1234567890'
testmatch '*??????????' '1234567890'
testmatch '*?*?*?*?*?*?*?*?*?*?*' '12345678901'
testmatch '??????????*' '12345678901'
testmatch '*??????????' '12345678901'
testmatch '[x]' 'x'
testmatch '[*]' '*'
testmatch '[?]' '?'
testmatch '[' '['
testmatch '[[]' '['
testnomatch '[[]' 'x'
testnomatch '[*]' ''
testnomatch '[*]' 'x'
testnomatch '[?]' 'x'
testmatch '*[*]*' 'foo*foo'
testnomatch '*[*]*' 'foo'
testmatch '[0-9]' '0'
testmatch '[0-9]' '5'
testmatch '[0-9]' '9'
testnomatch '[0-9]' '/'
testnomatch '[0-9]' ':'
testnomatch '[0-9]' '*'
testnomatch '[!0-9]' '0'
testnomatch '[!0-9]' '5'
testnomatch '[!0-9]' '9'
testmatch '[!0-9]' '/'
testmatch '[!0-9]' ':'
testmatch '[!0-9]' '*'
testmatch '*[0-9]' 'a0'
testmatch '*[0-9]' 'a5'
testmatch '*[0-9]' 'a9'
testnomatch '*[0-9]' 'a/'
testnomatch '*[0-9]' 'a:'
testnomatch '*[0-9]' 'a*'
testnomatch '*[!0-9]' 'a0'
testnomatch '*[!0-9]' 'a5'
testnomatch '*[!0-9]' 'a9'
testmatch '*[!0-9]' 'a/'
testmatch '*[!0-9]' 'a:'
testmatch '*[!0-9]' 'a*'
testmatch '*[0-9]' 'a00'
testmatch '*[0-9]' 'a55'
testmatch '*[0-9]' 'a99'
testmatch '*[0-9]' 'a0a0'
testmatch '*[0-9]' 'a5a5'
testmatch '*[0-9]' 'a9a9'
testmatch '\*' '*'
testmatch '\?' '?'
testmatch '\[x]' '[x]'
testmatch '\[' '['
testmatch '\\' '\'
testmatch '*\**' 'foo*foo'
testnomatch '*\**' 'foo'
testmatch '*\\*' 'foo\foo'
testnomatch '*\\*' 'foo'
testmatch '\(' '('
testmatch '\a' 'a'
testnomatch '\*' 'a'
testnomatch '\?' 'a'
testnomatch '\*' '\*'
testnomatch '\?' '\?'
testnomatch '\[x]' '\[x]'
testnomatch '\[x]' '\x'
testnomatch '\[' '\['
testnomatch '\(' '\('
testnomatch '\a' '\a'
testmatch '.*' '.'
testmatch '.*' '..'
testmatch '.*' '.a'
testmatch 'a*' 'a.'
[ -z "$failures" ]
EOF
put fbsd/builtins/case20.0 <<'EOF'

# Shells do not agree about what this pattern should match, but it is
# certain that it must not crash and the missing close bracket must not
# be simply ignored.

case B in
[[:alpha:]) echo bad ;;
esac
EOF
put fbsd/builtins/case21.0 <<'EOF'

case 5 in
[0$((-9))]) ;;
*) echo bad1 ;;
esac

case - in
[0$((-9))]) echo bad2 ;;
esac
EOF
put fbsd/builtins/case22.0 <<'EOF'

case 5 in
[0"$((-9))"]) echo bad1 ;;
esac

case - in
[0"$((-9))"]) ;;
*) echo bad2 ;;
esac
EOF
put fbsd/builtins/case23.0 <<'EOF'

case [ in
[[:alpha:]]) echo bad
esac
EOF
put fbsd/builtins/case3.0 <<'EOF'
# Generated by ./test-fnmatch -s 2, do not edit.
failures=
failed() { printf '%s\n' "Failed: $1 '$2' '$3'"; failures=x$failures; }
# We do not treat a backslash specially in this case,
# but this is not the case in all shells.
netestmatch() { case $2 in $1) ;; *) failed netestmatch "$@";; esac; }
netestnomatch() { case $2 in $1) failed netestnomatch "$@";; esac; }
netestmatch '' ''
netestmatch 'a' 'a'
netestnomatch 'a' 'b'
netestnomatch 'a' 'A'
netestmatch '*' 'a'
netestmatch '*' 'aa'
netestmatch '*a' 'a'
netestnomatch '*a' 'b'
netestnomatch '*a*' 'b'
netestmatch '*a*b*' 'ab'
netestmatch '*a*b*' 'qaqbq'
netestmatch '*a*bb*' 'qaqbqbbq'
netestmatch '*a*bc*' 'qaqbqbcq'
netestmatch '*a*bb*' 'qaqbqbb'
netestmatch '*a*bc*' 'qaqbqbc'
netestmatch '*a*bb' 'qaqbqbb'
netestmatch '*a*bc' 'qaqbqbc'
netestnomatch '*a*bb' 'qaqbqbbq'
netestnomatch '*a*bc' 'qaqbqbcq'
netestnomatch '*a*a*a*a*a*a*a*a*a*a*' 'aaaaaaaaa'
netestmatch '*a*a*a*a*a*a*a*a*a*a*' 'aaaaaaaaaa'
netestmatch '*a*a*a*a*a*a*a*a*a*a*' 'aaaaaaaaaaa'
netestnomatch '.*.*.*.*.*.*.*.*.*.*' '.........'
netestmatch '.*.*.*.*.*.*.*.*.*.*' '..........'
netestmatch '.*.*.*.*.*.*.*.*.*.*' '...........'
netestnomatch '*?*?*?*?*?*?*?*?*?*?*' '123456789'
netestnomatch '??????????*' '123456789'
netestnomatch '*??????????' '123456789'
netestmatch '*?*?*?*?*?*?*?*?*?*?*' '1234567890'
netestmatch '??????????*' '1234567890'
netestmatch '*??????????' '1234567890'
netestmatch '*?*?*?*?*?*?*?*?*?*?*' '12345678901'
netestmatch '??????????*' '12345678901'
netestmatch '*??????????' '12345678901'
netestmatch '[x]' 'x'
netestmatch '[*]' '*'
netestmatch '[?]' '?'
netestmatch '[' '['
netestmatch '[[]' '['
netestnomatch '[[]' 'x'
netestnomatch '[*]' ''
netestnomatch '[*]' 'x'
netestnomatch '[?]' 'x'
netestmatch '*[*]*' 'foo*foo'
netestnomatch '*[*]*' 'foo'
netestmatch '[0-9]' '0'
netestmatch '[0-9]' '5'
netestmatch '[0-9]' '9'
netestnomatch '[0-9]' '/'
netestnomatch '[0-9]' ':'
netestnomatch '[0-9]' '*'
netestnomatch '[!0-9]' '0'
netestnomatch '[!0-9]' '5'
netestnomatch '[!0-9]' '9'
netestmatch '[!0-9]' '/'
netestmatch '[!0-9]' ':'
netestmatch '[!0-9]' '*'
netestmatch '*[0-9]' 'a0'
netestmatch '*[0-9]' 'a5'
netestmatch '*[0-9]' 'a9'
netestnomatch '*[0-9]' 'a/'
netestnomatch '*[0-9]' 'a:'
netestnomatch '*[0-9]' 'a*'
netestnomatch '*[!0-9]' 'a0'
netestnomatch '*[!0-9]' 'a5'
netestnomatch '*[!0-9]' 'a9'
netestmatch '*[!0-9]' 'a/'
netestmatch '*[!0-9]' 'a:'
netestmatch '*[!0-9]' 'a*'
netestmatch '*[0-9]' 'a00'
netestmatch '*[0-9]' 'a55'
netestmatch '*[0-9]' 'a99'
netestmatch '*[0-9]' 'a0a0'
netestmatch '*[0-9]' 'a5a5'
netestmatch '*[0-9]' 'a9a9'
netestmatch '\*' '\*'
netestmatch '\?' '\?'
netestmatch '\' '\'
netestnomatch '\\' '\'
netestmatch '\\' '\\'
netestmatch '*\*' 'foo\foo'
netestnomatch '*\*' 'foo'
netestmatch '.*' '.'
netestmatch '.*' '..'
netestmatch '.*' '.a'
netestmatch 'a*' 'a.'
[ -z "$failures" ]
EOF
put fbsd/builtins/case4.0 <<'EOF'

set -- "*"
case x in
"$1") echo failed ;;
esac
EOF
put fbsd/builtins/case5.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.UTF-8
export LC_CTYPE

c1=e
# a umlaut
c2=$(printf '\303\244')
# euro sign
c3=$(printf '\342\202\254')
# some sort of 't' outside BMP
c4=$(printf '\360\235\225\245')

ok=0
case $c1$c2$c3$c4 in
*) ok=1 ;;
esac
if [ $ok = 0 ]; then
	echo wrong at $LINENO
	exit 3
fi

case $c1$c2$c3$c4 in
$c1$c2$c3$c4) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
"$c1$c2$c3$c4") ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
????) ;;
*) echo wrong at $LINENO ;;
esac

case $c1.$c2.$c3.$c4 in
?.?.?.?) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
[!a][!b][!c][!d]) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
[$c1][$c2][$c3][$c4]) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
["$c1"]["$c2"]["$c3"]["$c4"]) ;;
*) echo wrong at $LINENO ;;
esac
EOF
put fbsd/builtins/case6.0 <<'EOF'

unset LC_ALL
LC_CTYPE=de_DE.ISO8859-1
export LC_CTYPE

c1=e
# o umlaut
c2=$(printf '\366')
# non-break space
c3=$(printf '\240')
c4=$(printf '\240')
# $c2$c3$c4 form one utf-8 character

ok=0
case $c1$c2$c3$c4 in
*) ok=1 ;;
esac
if [ $ok = 0 ]; then
	echo wrong at $LINENO
	exit 3
fi

case $c1$c2$c3$c4 in
$c1$c2$c3$c4) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
"$c1$c2$c3$c4") ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
????) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
[!$c2][!b][!c][!d]) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
[$c1][$c2][$c3][$c4]) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2$c3$c4 in
["$c1"]["$c2"]["$c3"]["$c4"]) ;;
*) echo wrong at $LINENO ;;
esac
EOF
put fbsd/builtins/case7.0 <<'EOF'

# Character ranges in a locale other than the POSIX locale, not specified
# by POSIX.

unset LC_ALL
LC_CTYPE=de_DE.ISO8859-1
export LC_CTYPE
LC_COLLATE=de_DE.ISO8859-1
export LC_COLLATE

c1=e
# o umlaut
c2=$(printf '\366')

case $c1$c2 in
[a-z][a-z]) ;;
*) echo wrong at $LINENO ;;
esac

case $c1$c2 in
[a-f][n-p]) ;;
*) echo wrong at $LINENO ;;
esac
EOF
put fbsd/builtins/case8.0 <<'EOF'

case aZ_ in
[[:alpha:]_][[:upper:]_][[:alpha:]_]) ;;
*) echo Failed at $LINENO ;;
esac

case ' ' in
[[:alpha:][:digit:]]) echo Failed at $LINENO ;;
[![:alpha:][:digit:]]) ;;
*) echo Failed at $LINENO ;;
esac

case '.X.' in
*[[:lower:]]*) echo Failed at $LINENO ;;
*[[:upper:]]*) ;;
*) echo Failed at $LINENO ;;
esac

case ' ' in
[![:print:]]) echo Failed at $LINENO ;;
[![:alnum:][:punct:]]) ;;
*) echo Failed at $LINENO ;;
esac

case '
' in
[[:print:]]) echo Failed at $LINENO ;;
['
'[:digit:]]) ;;
*) echo Failed at $LINENO ;;
esac
EOF
put fbsd/builtins/case9.0 <<'EOF'

errors=0

f() {
	result=
	case $1 in
	a) result=${result}a ;;
	b) result=${result}b ;&
	c) result=${result}c ;&
	d) result=${result}d ;;
	e) result=${result}e ;&
	esac
}

check() {
	f "$1"
	if [ "$result" != "$2" ]; then
		printf "For %s, expected %s got %s\n" "$1" "$2" "$result"
		errors=$((errors + 1))
	fi
}

check '' ''
check a a
check b bcd
check c cd
check d d
check e e

if ! (case 1 in
	1) false ;&
	2) true ;;
esac) then
	echo "Subshell bad"
	errors=$((errors + 1))
fi

exit $((errors != 0))
EOF
put fbsd/builtins/cd1.0 <<'EOF'
set -e

P=${TMPDIR:-/tmp}
cd $P
T=$(mktemp -d sh-test.XXXXXX)

chmod 0 $T
if [ `id -u` -ne 0 ]; then
	# Root can always cd, regardless of directory permissions.
	cd -L $T 2>/dev/null && exit 1
	[ "$PWD" = "$P" ]
	[ "$(pwd)" = "$P" ]
	cd -P $T 2>/dev/null && exit 1
	[ "$PWD" = "$P" ]
	[ "$(pwd)" = "$P" ]
fi

chmod 755 $T
cd $T
mkdir -p 1/2/3
ln -s 1/2 link1
ln -s 2/3 1/link2
(cd -L 1/../1 && [ "$(pwd -L)" = "$P/$T/1" ])
(cd -L link1 && [ "$(pwd -L)" = "$P/$T/link1" ])
(cd -L link1 && [ "$(pwd -P)" = "$P/$T/1/2" ])
(cd -P link1 && [ "$(pwd -L)" = "$P/$T/1/2" ])
(cd -P link1 && [ "$(pwd -P)" = "$P/$T/1/2" ])

rm -rf ${P}/${T}
EOF
put fbsd/builtins/cd10.0 <<'EOF'

# Precondition
(cd /bin) || exit
# Verify write error is ignored.
ENV= $SH +m -ic 'CDPATH=/:; cd bin 1</dev/null'
EOF
put fbsd/builtins/cd11.0 <<'EOF'

set -e
T=$(mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXX")
trap 'rm -rf "$T"' 0

mkdir "$T/%?^&*"
cd -P "$T/%?^&*"
D=$(pwd)

mkdir a a/1 b b/1 b/2

CDPATH=$D/a:
# Basic test.
cd 1 >/dev/null
[ "$(pwd)" = "$D/a/1" ]
# Test that the current directory is not checked before CDPATH.
cd "$D/b"
cd 1 >/dev/null
[ "$(pwd)" = "$D/a/1" ]
# Test not using a CDPATH entry.
cd "$D/b"
cd 2
[ "$(pwd)" = "$D/b/2" ]
EOF
put fbsd/builtins/cd12.0 <<'EOF'
(cd /bin) || exit 1
cd "" && exit 1
exit 0
EOF
put fbsd/builtins/cd12.0.stderr <<'EOF'
cd: : No such file or directory
EOF
put fbsd/builtins/cd2.0 <<'EOF'
set -e

L=$(getconf PATH_MAX / 2>/dev/null) || L=4096
[ "$L" -lt 100000 ] 2>/dev/null || L=4096
L=$((L+100))
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf ${T}' 0
cd $T
D=$T
while [ ${#D} -lt $L ]; do
	mkdir veryverylongdirectoryname
	cd veryverylongdirectoryname
	D=$D/veryverylongdirectoryname
done
[ $(pwd | wc -c) -eq $((${#D} + 1)) ] # +\n
EOF
put fbsd/builtins/cd3.0 <<'EOF'

# If fully successful, cd -Pe must be like cd -P.

set -e

cd "${TMPDIR:-/tmp}"
cd -Pe /
[ "$PWD" = / ]
[ "$(pwd)" = / ]
cd "${TMPDIR:-/tmp}"
cd -eP /
[ "$PWD" = / ]
[ "$(pwd)" = / ]

set +e

# If cd -Pe cannot chdir, the exit status must be greater than 1.

v=$( (cd -Pe /var/empty/nonexistent) 2>&1 >/dev/null)
[ $? -gt 1 ] && [ -n "$v" ]
EOF
put fbsd/builtins/cd4.0 <<'EOF'

# This test assumes that whatever mechanism cd -P uses to determine the
# pathname to the current directory if it is longer than PATH_MAX requires
# read permission on all parent directories. It also works if this
# requirement always applies.

set -e
L=$(getconf PATH_MAX / 2>/dev/null) || L=4096
[ "$L" -lt 100000 ] 2>/dev/null || L=4096
L=$((L+100))
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'chmod u+r ${T}; rm -rf ${T}' 0
cd -Pe $T
D=$(pwd)
chmod u-r "$D"
if [ -r "$D" ]; then
	# Running as root, cannot test.
	exit 0
fi
set +e
while [ ${#D} -lt $L ]; do
	mkdir veryverylongdirectoryname || exit
	cd -Pe veryverylongdirectoryname 2>/dev/null
	r=$?
	[ $r -gt 1 ] && exit $r
	if [ $r -eq 1 ]; then
		# Verify that the directory was changed correctly.
		cd -Pe .. || exit
		[ "$(pwd)" = "$D" ] || exit
		# Verify that omitting -e results in success.
		cd -P veryverylongdirectoryname 2>/dev/null || exit
		exit 0
	fi
	D=$D/veryverylongdirectoryname
done
echo "cd -Pe never returned 1"
exit 0
EOF
put fbsd/builtins/cd5.0 <<'EOF'

set -e
T=$(mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXX")
trap 'rm -rf "$T"' 0

cd -P "$T"
D=$(pwd)

mkdir a a/1 b b/1 b/2

CDPATH=$D/a:
# Basic test.
cd 1 >/dev/null
[ "$(pwd)" = "$D/a/1" ]
# Test that the current directory is not checked before CDPATH.
cd "$D/b"
cd 1 >/dev/null
[ "$(pwd)" = "$D/a/1" ]
# Test not using a CDPATH entry.
cd "$D/b"
cd 2
[ "$(pwd)" = "$D/b/2" ]
EOF
put fbsd/builtins/cd6.0 <<'EOF'

set -e
cd -P /bin
d=$PWD
CDPATH=/:
cd -P .
[ "$d" = "$PWD" ]
cd -P ./
[ "$d" = "$PWD" ]
EOF
put fbsd/builtins/cd7.0 <<'EOF'

set -e
cd /usr/bin
[ "$PWD" = /usr/bin ]
CDPATH=/:
cd .
[ "$PWD" = /usr/bin ]
cd ./
[ "$PWD" = /usr/bin ]
cd ..
[ "$PWD" = /usr ]
cd /usr/bin
cd ../
[ "$PWD" = /usr ]
EOF
put fbsd/builtins/cd8.0 <<'EOF'

# The exact wording of the error message is not standardized, but giving
# a description of the errno is useful.

LC_ALL=C
export LC_ALL
r=0

t() {
	exec 3>&1
	errmsg=`cd "$1" 2>&1 >&3 3>&-`
	exec 3>&-
	case $errmsg in
	*[Nn]ot\ a\ directory*)
		;;
	*)
		printf "Wrong error message for %s: %s\n" "$1" "$errmsg"
		r=3
		;;
	esac
}

t /dev/tty
t /dev/tty/x
exit $r
EOF
put fbsd/builtins/cd9.0 <<'EOF'

cd /dev
cd /bin
cd - >/dev/null
pwd
cd - >/dev/null
pwd
EOF
put fbsd/builtins/cd9.0.stdout <<'EOF'
/dev
/bin
EOF
put fbsd/builtins/command1.0 <<'EOF'
true() {
	false
}
command true
EOF
put fbsd/builtins/command10.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$(f() { shift x; }; { command eval f 2>/dev/null; } >/dev/null; echo hi)" = hi'

exit $((failures > 0))
EOF
put fbsd/builtins/command11.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$({ command eval \{ shift x\; \} 2\>/dev/null; } >/dev/null; echo hi)" = hi'

exit $((failures > 0))
EOF
put fbsd/builtins/command12.0 <<'EOF'

alias aa=echo\ \'\"\'
cmd=$(command -v aa)
alias aa=echo\ bad
eval "$cmd"
[ "$(eval aa)" = \" ]
EOF
put fbsd/builtins/command13.0 <<'EOF'

failures=0

check() {
	if [ "$1" != "$2" ] && { [ "$#" -lt 3 ] || [ "$1" != "$3" ]; } then
		echo "Mismatch found"
		echo "Expected: $2"
		if [ "$#" -ge 3 ]; then
			echo "Alternative expected: $3"
		fi
		echo "Actual: $1"
		: $((failures += 1))
	fi
}

check "$(cd /bin && PATH=. command -v ls)" /bin/ls /bin/./ls
check "$(cd /bin && PATH=:/var/empty/nosuch command -v ls)" /bin/ls /bin/./ls
check "$(cd / && PATH=bin command -v ls)" /bin/ls
check "$(cd / && command -v bin/ls)" /bin/ls
check "$(cd /bin && command -v ./ls)" /bin/ls /bin/./ls
EOF
put fbsd/builtins/command14.0 <<'EOF'

r=`cd /bin && PATH=. command -V ls`
case $r in
*/bin/ls*|*/bin/./ls*) ;;
*)
	echo "Unexpected result: $r"
	exit 1
esac
EOF
put fbsd/builtins/command2.0 <<'EOF'
PATH=
command -p cat < /dev/null
EOF
put fbsd/builtins/command3.0 <<'EOF'
command -v ls
command -v true
command -v /bin/ls

fun() {
	:
}
command -v fun
command -v break
command -v if

alias foo=bar
command -v foo
EOF
put fbsd/builtins/command3.0.stdout <<'EOF'
/bin/ls
true
/bin/ls
fun
break
if
alias foo=bar
EOF
put fbsd/builtins/command4.0 <<'EOF'
! command -v nonexisting
EOF
put fbsd/builtins/command5.0 <<'EOF'
command -V ls
command -V true
command -V /bin/ls

fun() {
	:
}
command -V fun
command -V break
command -V if
command -V {

alias foo=bar
command -V foo
EOF
put fbsd/builtins/command5.0.stdout <<'EOF'
ls is /bin/ls
true is a shell builtin
/bin/ls is /bin/ls
fun is a shell function
break is a special shell builtin
if is a shell keyword
{ is a shell keyword
foo is an alias for bar
EOF
put fbsd/builtins/command6.0 <<'EOF'
PATH=/var/empty
case $(command -pV ls) in
*/var/empty/ls*)
	echo "Failed: \$(command -pV ls) should not match */var/empty/ls*" ;;
"ls is"*" "/*/ls) ;;
*)
	echo "Failed: \$(command -pV ls) match \"ls is\"*\" \"/*/ls" ;;
esac
command -pV true
command -pV /bin/ls

fun() {
	:
}
command -pV fun
command -pV break
command -pV if
command -pV {

alias foo=bar
command -pV foo
EOF
put fbsd/builtins/command6.0.stdout <<'EOF'
true is a shell builtin
/bin/ls is /bin/ls
fun is a shell function
break is a special shell builtin
if is a shell keyword
{ is a shell keyword
foo is an alias for bar
EOF
put fbsd/builtins/command7.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$(PATH=/libexec command -V ld-elf.so.1)" = "ld-elf.so.1 is /libexec/ld-elf.so.1"'
check '"$(PATH=/libexec command -V ld-elf.so.1; :)" = "ld-elf.so.1 is /libexec/ld-elf.so.1"'
check '"$(PATH=/libexec command -pv ld-elf.so.1)" = ""'
check '"$(PATH=/libexec command -pv ld-elf.so.1; :)" = ""'

PATH=/libexec:$PATH

check '"$(command -V ld-elf.so.1)" = "ld-elf.so.1 is /libexec/ld-elf.so.1"'
check '"$(command -V ld-elf.so.1; :)" = "ld-elf.so.1 is /libexec/ld-elf.so.1"'
check '"$(command -pv ld-elf.so.1)" = ""'
check '"$(command -pv ld-elf.so.1; :)" = ""'

PATH=/libexec

check '"$(command -v ls)" = ""'
case $(command -pv ls) in
/*/ls) ;;
*)
	echo "Failed: \$(command -pv ls) match /*/ls"
	: $((failures += 1)) ;;
esac

exit $((failures > 0))
EOF
put fbsd/builtins/command8.0 <<'EOF'
IFS=,

SPECIAL="break,\
	:,\
	continue,\
	. /dev/null,\
	eval,\
	exec,\
	export -p,\
	readonly -p,\
	set,\
	shift 0,\
	times,\
	trap,\
	unset foo"

set -e

# Check that special builtins can be executed via "command".

set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "v=:; while \$v; do v=false; command ${cmd}; done" >/dev/null
done

while :; do
	command break
	echo Error on line $LINENO
done

set p q r
command shift 2
if [ $# -ne 1 ]; then
	echo Error on line $LINENO
fi

(
	command exec >/dev/null
	echo Error on line $LINENO
)

set +e
! command shift 2 2>/dev/null
EOF
put fbsd/builtins/command9.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$({ command eval shift x 2>/dev/null; } >/dev/null; echo hi)" = hi'

exit $((failures > 0))
EOF
put fbsd/builtins/dot1.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX) || exit
trap 'rm -rf $T' 0
cd $T || exit 3
unset x
echo 'x=2' >testscript
. ./testscript
[ "$x" = 2 ] || failure $LINENO
cd / || exit 3
x=1
PATH=$T:$PATH . testscript
[ "$x" = 2 ] || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/dot2.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX) || exit
trap 'rm -rf $T' 0
cd $T || exit 3
unset x
echo 'x=2' >testscript
. -- ./testscript
[ "$x" = 2 ] || failure $LINENO
cd / || exit 3
x=1
PATH=$T:$PATH . -- testscript
[ "$x" = 2 ] || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/dot3.0 <<'EOF'

# . should return 0 if no command was executed.

if false; then
	exit 3
else
	. /dev/null
	exit $?
fi
EOF
put fbsd/builtins/dot4.0 <<'EOF'

v=abcd
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
r=$( (
	trap 'exit 0' 0
	. "$v"
) 2>&1 >/dev/null) && [ -n "$r" ]
EOF
put fbsd/builtins/echo1.0 <<'EOF'

# Not specified by POSIX.

[ "`echo -n a b; echo c d; echo e f`" = "a bc d
e f" ]
EOF
put fbsd/builtins/echo2.0 <<'EOF'

# Not specified by POSIX.

a=`echo -e '\a\b\e\f\n\r\t\v\\\\\0041\c'; echo .`
b=`printf '\a\b\033\f\n\r\t\v\\\\!.'`
[ "$a" = "$b" ]
EOF
put fbsd/builtins/echo3.0 <<'EOF'

# Not specified by POSIX.

[ "`echo -e 'a\cb' c; echo d`" = "ad" ]
EOF
put fbsd/builtins/eval1.0 <<'EOF'
set -e

eval
eval "" ""
eval "true"
! eval "false

"
EOF
put fbsd/builtins/eval2.0 <<'EOF'

eval '
false

' && exit 1
exit 0
EOF
put fbsd/builtins/eval3.0 <<'EOF'

eval 'false;' && exit 1
eval 'true;' || exit 1
eval 'false;
' && exit 1
eval 'true;
' || exit 1
exit 0
EOF
put fbsd/builtins/eval4.0 <<'EOF'

# eval should preserve $? from command substitutions when starting
# the parsed command.
[ $(eval 'echo $?' $(false)) = 1 ]
EOF
put fbsd/builtins/eval5.0 <<'EOF'

# eval should return 0 if no command was executed.
eval $(false)
EOF
put fbsd/builtins/eval6.0 <<'EOF'

# eval should preserve $? from command substitutions when starting
# the parsed command.
[ $(false; eval 'echo $?' $(:)) = 0 ]
EOF
put fbsd/builtins/eval7.0 <<'EOF'
# Assumes that break can break out of a loop outside eval.

while :; do
	eval "break
echo bad1"
	echo bad2
	exit 3
done
EOF
put fbsd/builtins/eval8.7 <<'EOF'

f() {
	eval "return 7
echo bad2"
}
f
EOF
put fbsd/builtins/exec1.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

(
	exec >/dev/null
	echo bad
)
[ $? = 0 ] || failure $LINENO
(
	exec ${SH} -c 'exit 42'
	echo bad
)
[ $? = 42 ] || failure $LINENO
(
	exec /var/empty/nosuch
	echo bad
) 2>/dev/null
[ $? = 127 ] || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/exec2.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

(
	exec -- >/dev/null
	echo bad
)
[ $? = 0 ] || failure $LINENO
(
	exec -- ${SH} -c 'exit 42'
	echo bad
)
[ $? = 42 ] || failure $LINENO
(
	exec -- /var/empty/nosuch
	echo bad
) 2>/dev/null
[ $? = 127 ] || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/exit1.0 <<'EOF'

# exit with an argument should overwrite the exit status in an EXIT trap.

trap 'true; exit $?' 0
false
EOF
put fbsd/builtins/exit2.8 <<'EOF'

# exit without arguments is the same as exit $? outside a trap.

trap 'true; true' 0
(exit 8)
exit
EOF
put fbsd/builtins/exit3.0 <<'EOF'

# exit without arguments differs from exit $? in an EXIT trap.

trap 'false; exit' 0
EOF
put fbsd/builtins/export1.0 <<'EOF'

env @badness=1 ${SH} -c 'v=`export -p`; eval "$v"'
EOF
put fbsd/builtins/fc1.0 <<'EOF'
set -e
trap 'echo Broken pipe -- test failed' PIPE

P=${TMPDIR:-/tmp}
cd $P
T=$(mktemp -d sh-test.XXXXXX)
cd $T

mkfifo input output error
ENV= HISTFILE=/dev/null ${SH} +m -i <input >output 2>error &
{
	# Syntax error
	echo ')' >&3
	# Read error message, shell will read new input now
	read dummy <&5
	# Execute bad command again
	echo 'fc -e true' >&3
	# Verify that the shell is still running
	echo 'echo continued' >&3 || rc=3
	echo 'exit' >&3 || rc=3
	read line <&4 && [ "$line" = continued ] && : ${rc:=0}
} 3>input 4<output 5<error

rm input output error
rmdir ${P}/${T}
exit ${rc:-3}
EOF
put fbsd/builtins/fc2.0 <<'EOF'
set -e
trap 'echo Broken pipe -- test failed' PIPE

P=${TMPDIR:-/tmp}
cd $P
T=$(mktemp -d sh-test.XXXXXX)
cd $T

mkfifo input output error
HISTFILE=/dev/null ${SH} +m -i <input >output 2>error &
exec 3>input
{
	# Command not found, containing slash
	echo '/var/empty/nonexistent' >&3
	# Read error message, shell will read new input now
	read dummy <&5
	# Execute bad command again
	echo 'fc -e true; echo continued' >&3
	read dummy <&5
	read line <&4 && [ "$line" = continued ] && : ${rc:=0}
	exec 3>&-
	# Old sh duplicates itself after the fc, producing another line
	# of output.
	if read line <&4; then
		echo "Extraneous output: $line"
		rc=1
	fi
} 4<output 5<error
exec 3>&-

rm input output error
rmdir ${P}/${T}
exit ${rc:-3}
EOF
put fbsd/builtins/fc3.0 <<'EOF'
export PS1='_ ' # cannot predict whether ran by root or not

echo ': command1
: command2
: command3
: command4
fc -l -n -1
fc -ln 2 3
' | ENV= HISTFILE=/dev/null ${SH} +m -i
EOF
put fbsd/builtins/fc3.0.stderr <<'EOF'
_ _ _ _ _ _ _ _ 
EOF
put fbsd/builtins/fc3.0.stdout <<'EOF'
: command4
: command2
: command3
EOF
put fbsd/builtins/fc4.0 <<'EOF1'
v=1234
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
#v=$v$v$v$v
v=beginlong$v$v$v${v}endlong
result=$(ENV= HISTFILE=/dev/null script -q /dev/null ${SH} +m -i -o emacs <<EOF
printf '%s\n' "$v"
printf 'running %s\n' fc; fc -l
EOF
)
case $result in
	*'running fc'*beginlong*endlong*) ;;
	*)
		set -x
		: result is "$result"
		exit 2
esac
result=${result#*running fc}
result=${result#*beginlong}
result=${result%endlong*}
reflected=beginlong${result}endlong
if [ "$v" != "$reflected" ]; then
	set -x
	: expected "$v" reflected "$reflected"
	exit 3
fi
EOF1
put fbsd/builtins/for1.0 <<'EOF'

false
for i in `false`; do exit 3; done
EOF
put fbsd/builtins/for2.0 <<'EOF'

r=x
f() { return 42; }
f
for i in x; do
	r=$?
done
[ "$r" = 42 ]
EOF
put fbsd/builtins/for3.0 <<'EOF'

r=x
f() { return 42; }
for i in x`f`; do
	r=$?
done
[ "$r" = 42 ]
EOF
put fbsd/builtins/getopts1.0 <<'EOF'

printf -- '-1-\n'
set -- -abc
getopts "ab:" OPTION
printf '%s\n' "${OPTION}"

# In this case 'getopts' should realize that we have not provided the
# required argument for "-b".
# Note that Solaris 10's (UNIX 03) /usr/xpg4/bin/sh, /bin/sh, and /bin/ksh;
# ksh93 20090505; pdksh 5.2.14p2; mksh R39c; bash 4.1 PL7; and zsh 4.3.10.
# all recognize that "b" is missing its argument on the *first* iteration
# of 'getopts' and do not produce the "a" in $OPTION.
printf -- '-2-\n'
set -- -ab
getopts "ab:" OPTION
printf '%s\n' "${OPTION}"
getopts "ab:" OPTION 3>&2 2>&1 >&3 3>&-
printf '%s\n' "${OPTION}"

# The 'shift' is aimed at causing an error.
printf -- '-3-\n'
shift 1
getopts "ab:" OPTION
printf '%s\n' "${OPTION}"
EOF
put fbsd/builtins/getopts1.0.stdout <<'EOF'
-1-
a
-2-
a
No arg for -b option
?
-3-
?
EOF
put fbsd/builtins/getopts10.0 <<'EOF'

set -- -x arg
opt=not
getopts x opt
r1=$? OPTIND1=$OPTIND opt1=$opt
: $(: $((OPTIND = 1)))
getopts x opt
r2=$? OPTIND2=$OPTIND
[ "$r1" = 0 ] && [ "$OPTIND1" = 2 ] && [ "$opt1" = x ] && [ "$r2" != 0 ] &&
	[ "$OPTIND2" = 2 ]
EOF
put fbsd/builtins/getopts2.0 <<'EOF'
set - -ax
getopts ax option
set -C
getopts ax option
printf '%s\n' "$option"
EOF
put fbsd/builtins/getopts2.0.stdout <<'EOF'
x
EOF
put fbsd/builtins/getopts3.0 <<'EOF'

shift $#
getopts x opt
r=$?
[ "$r" != 0 ] && [ "$OPTIND" = 1 ]
EOF
put fbsd/builtins/getopts4.0 <<'EOF'

set -- -x
opt=not
getopts x opt
r1=$? OPTIND1=$OPTIND opt1=$opt
getopts x opt
r2=$? OPTIND2=$OPTIND
[ "$r1" = 0 ] && [ "$OPTIND1" = 2 ] && [ "$opt1" = x ] && [ "$r2" != 0 ] &&
	[ "$OPTIND2" = 2 ]
EOF
put fbsd/builtins/getopts5.0 <<'EOF'

set -- -x arg
opt=not
getopts x opt
r1=$? OPTIND1=$OPTIND opt1=$opt
getopts x opt
r2=$? OPTIND2=$OPTIND
[ "$r1" = 0 ] && [ "$OPTIND1" = 2 ] && [ "$opt1" = x ] && [ "$r2" != 0 ] &&
	[ "$OPTIND2" = 2 ]
EOF
put fbsd/builtins/getopts6.0 <<'EOF'

set -- -x -y
getopts :x var || echo "First getopts bad: $?"
getopts :x var
r=$?
[ r != 0 ] && [ "$OPTIND" = 3 ]
EOF
put fbsd/builtins/getopts7.0 <<'EOF'

set -- -x
getopts :x: var
r=$?
[ r != 0 ] && [ "$OPTIND" = 2 ]
EOF
put fbsd/builtins/getopts8.0 <<'EOF'

set -- -yz -wx
opt=wrong1 OPTARG=wrong2
while getopts :x opt; do
	echo "$opt:${OPTARG-unset}"
done
echo "OPTIND=$OPTIND"
EOF
put fbsd/builtins/getopts8.0.stdout <<'EOF'
?:y
?:z
?:w
x:unset
OPTIND=3
EOF
put fbsd/builtins/getopts9.0 <<'EOF'

args='-ab'
getopts ab opt $args
printf '%s\n' "$?:$opt:$OPTARG"
for dummy in dummy1 dummy2; do
	getopts ab opt $args
	printf '%s\n' "$?:$opt:$OPTARG"
done
EOF
put fbsd/builtins/getopts9.0.stdout <<'EOF'
0:a:
0:b:
1:?:
EOF
put fbsd/builtins/hash1.0 <<'EOF'
cat /dev/null
hash
hash -r
hash
EOF
put fbsd/builtins/hash1.0.stdout <<'EOF'
/bin/cat
EOF
put fbsd/builtins/hash2.0 <<'EOF'
hash
hash cat
hash
EOF
put fbsd/builtins/hash2.0.stdout <<'EOF'
/bin/cat
EOF
put fbsd/builtins/hash3.0 <<'EOF'
hash -v cat
hash
EOF
put fbsd/builtins/hash3.0.stdout <<'EOF'
/bin/cat
/bin/cat
EOF
put fbsd/builtins/hash4.0 <<'EOF'

exec 3>&1
m=`hash nosuchtool 2>&1 >&3`
r=$?
[ "$r" != 0 ] && [ -n "$m" ]
EOF
put fbsd/builtins/jobid1.0 <<'EOF'
# Non-standard builtin.

: &
p1=$!
p2=$(jobid)
[ "${p1:?}" = "${p2:?}" ]
EOF
put fbsd/builtins/jobid2.0 <<'EOF'

: &
p1=$(jobid)
p2=$(jobid --)
p3=$(jobid %+)
p4=$(jobid -- %+)
[ "${p1:?}" = "${p2:?}" ] && [ "${p2:?}" = "${p3:?}" ] &&
[ "${p3:?}" = "${p4:?}" ] && [ "${p4:?}" = "${p1:?}" ]
EOF
put fbsd/builtins/kill1.0 <<'EOF'

: &
p1=$!
: &
p2=$!
wait $p2
kill %1
EOF
put fbsd/builtins/kill2.0 <<'EOF'

sleep 1 | sleep 1 &
kill %+
wait "$!"
r=$?
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = TERM ]
EOF
put fbsd/builtins/lineno.0 <<'EOF'
echo $LINENO
echo $LINENO

f() {	
	echo $LINENO
	echo $LINENO
}

f

echo ${LINENO:-foo}
echo ${LINENO=foo}
echo ${LINENO:+foo}
echo ${LINENO+foo}
echo ${#LINENO}
EOF
put fbsd/builtins/lineno.0.stdout <<'EOF'
1
2
2
3
11
12
foo
foo
2
EOF
put fbsd/builtins/lineno2.0 <<'EOF'

f() {
	: ${LINENO+${x?}}
}

unset -v x
command eval f 2>/dev/null && exit 3
x=1
f
EOF
put fbsd/builtins/lineno3.0 <<'EOF'

echo before: $LINENO
dummy=$'a\0
'
echo after: $LINENO
EOF
put fbsd/builtins/lineno3.0.stdout <<'EOF'
before: 2
after: 5
EOF
put fbsd/builtins/local1.0 <<'EOF'
# A commonly used but non-POSIX builtin.

f() {
	local x
	x=2
	[ "$x" = 2 ]
}
x=1
f || exit 3
[ "$x" = 1 ] || exit 3
f || exit 3
[ "$x" = 1 ] || exit 3
EOF
put fbsd/builtins/local2.0 <<'EOF'

f() {
	local -
	set -a
	case $- in
	*a*) : ;;
	*) echo In-function \$- bad
	esac
}
case $- in
*a*) echo Initial \$- bad
esac
f
case $- in
*a*) echo Final \$- bad
esac
EOF
put fbsd/builtins/local3.0 <<'EOF'

f() {
	local "$@"
	set -a
	x=7
	case $- in
	*a*) : ;;
	*) echo In-function \$- bad
	esac
	[ "$x" = 7 ] || echo In-function \$x bad
}
x=1
case $- in
*a*) echo Initial \$- bad
esac
f x -
case $- in
*a*) echo Intermediate \$- bad
esac
[ "$x" = 1 ] || echo Intermediate \$x bad
f - x
case $- in
*a*) echo Final \$- bad
esac
[ "$x" = 1 ] || echo Final \$x bad
EOF
put fbsd/builtins/local4.0 <<'EOF'

f() {
	local -- x
	x=2
	[ "$x" = 2 ]
}
x=1
f || exit 3
[ "$x" = 1 ] || exit 3
f || exit 3
[ "$x" = 1 ] || exit 3
EOF
put fbsd/builtins/local5.0 <<'EOF'

f() {
	local PATH IFS elem
	IFS=:
	for elem in ''$PATH''; do
		PATH=/var/empty/$elem:$PATH
	done
	ls -d / >/dev/null
}

p1=$(command -v ls)
f
p2=$(command -v ls)
[ "$p1" = "$p2" ]
EOF
put fbsd/builtins/local6.0 <<'EOF'

f() {
	local x
	readonly x=2
}
x=3
f
x=4
[ "$x" = 4 ]
EOF
put fbsd/builtins/local7.0 <<'EOF'

f() {
	local x
	readonly x=2
}
unset x
f
x=4
[ "$x" = 4 ]
EOF
put fbsd/builtins/locale1.0 <<'EOF'
# Note: this test depends on strerror() using locale.

failures=0

check() {
	if ! eval "[ $1 ]"; then
		echo "Failed: $1 at $2"
		: $((failures += 1))
	fi
}

unset LANG LC_ALL LC_COLLATE LC_CTYPE LC_MONETARY LC_NUMERIC LC_TIME LC_MESSAGES
unset LANGUAGE

msgeng="No such file or directory"
msgdut="Bestand of map niet gevonden"

# Verify C locale error message.
case $(command . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

# Various locale variables that should not affect the message.
case $(LC_ALL=C command . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_ALL=C LANG=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_ALL=C LC_MESSAGES=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_CTYPE=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

# Verify Dutch message.
case $(export LANG=nl_NL.ISO8859-1; command . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(export LC_MESSAGES=nl_NL.ISO8859-1; command . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(export LC_ALL=nl_NL.ISO8859-1; command . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LANG=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_MESSAGES=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_ALL=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

# Verify that command assignments do not set the locale persistently.
case $(command . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LANG=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1; command . /var/empty/foo 2>&1) in
	*"$msgdut"*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_MESSAGES=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1; command . /var/empty/foo 2>&1) in
	*"$msgdut"*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(LC_ALL=nl_NL.ISO8859-1 command . /var/empty/foo 2>&1; command . /var/empty/foo 2>&1) in
	*"$msgdut"*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

# Check special builtin; add colon invocation to avoid depending on certain fix.
case $(LC_ALL=nl_NL.ISO8859-1 . /var/empty/foo 2>&1; :) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

# Assignments on special builtins are exported to that builtin; the export
# is not persistent.
case $(LC_ALL=nl_NL.ISO8859-1 . /dev/null; . /var/empty/foo 2>&1) in
	*"$msgeng"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

case $(export LC_ALL; LC_ALL=nl_NL.ISO8859-1 . /dev/null; . /var/empty/foo 2>&1) in
	*"$msgdut"*) ok=1 ;;
	*) ok=0 ;;
esac
check '$ok -eq 1' $LINENO

exit $((failures > 0))
EOF
put fbsd/builtins/locale2.0 <<'EOF'

$SH -c 'LC_ALL=C true; kill -INT $$; echo continued'
r=$?
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = INT ]
EOF
put fbsd/builtins/printf1.0 <<'EOF'

[ "$(printf '%c\0%s%d' x '\' 010 | tr '\0' Z)" = 'xZ\8' ]
EOF
put fbsd/builtins/printf2.0 <<'EOF'

[ "$(printf '%cZ%s%d' x '\' 010)" = 'xZ\8' ]
EOF
put fbsd/builtins/printf3.0 <<'EOF'

set -e
v=$(! printf "%d" @wrong 2>/dev/null)
[ "$v" = "0" ]
EOF
put fbsd/builtins/printf4.0 <<'EOF'

set -e
v=$(! printf "%d" 4wrong 2>/dev/null)
[ "$v" = "4" ]
EOF
put fbsd/builtins/read1.0 <<'EOF'
set -e

echo "1 2 3"		| { read a; echo "x${a}x"; }
echo "1 2 3"		| { read a b; echo "x${a}x${b}x"; }
echo "1 2 3"		| { read a b c; echo "x${a}x${b}x${c}x"; }
echo "1 2 3"		| { read a b c d; echo "x${a}x${b}x${c}x${d}x"; }

echo "	1  2 3 "	| { read a b c; echo "x${a}x${b}x${c}x"; }
echo "	1  2 3 "	| { unset IFS; read a b c; echo "x${a}x${b}x${c}x"; }
echo "	1  2 3 "	| { IFS=$(printf ' \t\n') read a b c; echo "x${a}x${b}x${c}x"; }
echo "	1  2 3 "	| { IFS= read a b; echo "x${a}x${b}x"; }

echo " 1,2 3 "		| { IFS=' ,' read a b c; echo "x${a}x${b}x${c}x"; }
echo ", 2 ,3"		| { IFS=' ,' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 ,,3"		| { IFS=' ,' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 , , 3"		| { IFS=' ,' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 ,2 3,"		| { IFS=' ,' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 ,2 3,,"	| { IFS=' ,' read a b c; echo "x${a}x${b}x${c}x"; }

echo " 1,2 3 "		| { IFS=', ' read a b c; echo "x${a}x${b}x${c}x"; }
echo ", 2 ,3"		| { IFS=', ' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 ,,3"		| { IFS=', ' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 , , 3"		| { IFS=', ' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 ,2 3,"		| { IFS=', ' read a b c; echo "x${a}x${b}x${c}x"; }
echo " 1 ,2 3,,"	| { IFS=', ' read a b c; echo "x${a}x${b}x${c}x"; }
EOF
put fbsd/builtins/read1.0.stdout <<'EOF'
x1 2 3x
x1x2 3x
x1x2x3x
x1x2x3xx
x1x2x3x
x1x2x3x
x1x2x3x
x	1  2 3 xx
x1x2x3x
xx2x3x
x1xx3x
x1xx3x
x1x2x3x
x1x2x3,,x
x1x2x3x
xx2x3x
x1xx3x
x1xx3x
x1x2x3x
x1x2x3,,x
EOF
put fbsd/builtins/read10.0 <<'EOF'

set -e

v=original_value
r=0
read v < /dev/null || r=$?
[ "$r" -eq 1 ]
[ -z "$v" ]
EOF
put fbsd/builtins/read11.0 <<'EOF'
# Verify that `read -t 0 v` succeeds immediately if input is available
# and fails immediately if not

set -e

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf "$T"' 0
cd $T
mkfifo fifo1
# Open fifo1 for writing
{ echo new_value; sleep 10; } >fifo1 &
# Wait for the child to open fifo1 for writing
exec 3<fifo1

v=original_value
r=0
ts=$(date +%s%3N)
read -t 0 v <&3 || r=$?
te=$(date +%s%3N)
[ "$r" -eq 0 ]
[ $((te-ts)) -lt 250 ]
[ "$v" = "new_value" ]

v=original_value
r=0
ts=$(date +%s%3N)
read -t 0 v <&3 || r=$?
te=$(date +%s%3N)
kill -TERM "$!" || :
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = ALRM ]
[ $((te-ts)) -lt 250 ]
[ -z "$v" ]
EOF
put fbsd/builtins/read12.0 <<'EOF'
# Verify that `read -t 3 v` succeeds immediately if input is available
# and times out after 3 s if not

set -e

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf "$T"' 0
cd $T
mkfifo fifo1
# Open fifo1 for writing
{ echo new_value; sleep 10; } >fifo1 &
# Wait for the child to open fifo1 for writing
exec 3<fifo1

v=original_value
r=0
ts=$(date +%s%3N)
read -t 3 v <&3 || r=$?
te=$(date +%s%3N)
[ "$r" -eq 0 ]
[ $((te-ts)) -lt 250 ]
[ "$v" = "new_value" ]

v=original_value
r=0
ts=$(date +%s%3N)
read -t 3 v <&3 || r=$?
te=$(date +%s%3N)
kill -TERM "$!" || :
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = ALRM ]
[ $((te-ts)) -gt 3000 ] && [ $((te-ts)) -lt 3250 ]
[ -z "$v" ]
EOF
put fbsd/builtins/read2.0 <<'EOF'

set -e
{
	echo 1
	echo two
	echo three
} | {
	read x
	[ "$x" = 1 ]
	(read x
	[ "$x" = two ])
	read x
	[ "$x" = three ]
}

T=`mktemp sh-test.XXXXXX`
trap 'rm -f "$T"' 0
{
	echo 1
	echo two
	echo three
} >$T
{
	read x
	[ "$x" = 1 ]
	(read x
	[ "$x" = two ])
	read x
	[ "$x" = three ]
} <$T
EOF
put fbsd/builtins/read3.0 <<'EOF'

printf '%s\n' 'a\ b c'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' 'a b\ c'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' 'a\:b:c'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' 'a:b\:c'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\ a'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\:a'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\\ a'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\\ a'	| { read -r a b; printf '%s\n' "x${a}x${b}x"; }
EOF
put fbsd/builtins/read3.0.stdout <<'EOF'
xa bxcx
xaxb cx
xa:bxcx
xaxb:cx
x axx
x:axx
x\xx
x\ axx
x\\\xax
EOF
put fbsd/builtins/read4.0 <<'EOF'

printf '%s\n' '\a\ b c'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\a b\ c'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\a\:b:c'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\a:b\:c'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\ a'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\:a'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\\ a'	| { read a b; printf '%s\n' "x${a}x${b}x"; }
printf '%s\n' '\\\:a'	| { IFS=: read a b; printf '%s\n' "x${a}x${b}x"; }
EOF
put fbsd/builtins/read4.0.stdout <<'EOF'
xa bxcx
xaxb cx
xa:bxcx
xaxb:cx
x\xax
x\xax
x\ axx
x\:axx
EOF
put fbsd/builtins/read5.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.ISO8859-1
export LC_CTYPE

# Note: the first and last characters are not whitespace.
# Exclude backslash and newline.
bad1=`printf %03o \'\\\\`
bad2=`printf %03o \''
'`
e=
for i in 0 1 2 3; do
	for j in 0 1 2 3 4 5 6 7; do
		for k in 0 1 2 3 4 5 6 7; do
			case $i$j$k in
			000|$bad1|$bad2) continue ;;
			esac
			e="$e\\$i$j$k"
		done
	done
done
e=`printf "$e"`
[ "${#e}" = 253 ] || echo length bad

r1=`printf '%s\n' "$e" | { read -r x; printf '%s' "$x"; }`
[ "$r1" = "$e" ] || echo "read with -r bad"
r2=`printf '%s\n' "$e" | { read x; printf '%s' "$x"; }`
[ "$r2" = "$e" ] || echo "read without -r bad 1"
IFS=
r3=`printf '%s\n' "$e" | { read x; printf '%s' "$x"; }`
[ "$r3" = "$e" ] || echo "read without -r bad 2"
EOF
put fbsd/builtins/read6.0 <<'EOF'

: | read x
r=$?
[ "$r" = 1 ]
EOF
put fbsd/builtins/read7.0 <<'EOF'

{ errmsg=`read x <&- 2>&1 >&3`; } 3>&1
r=$?
[ "$r" -ge 2 ] && [ "$r" -le 128 ] && [ -n "$errmsg" ]
EOF
put fbsd/builtins/read8.0 <<'EOF1'

read a b c <<\EOF
\
A\
 \
 \
 \
B\
 \
 \
C\
 \
 \
 \
EOF
[ "$a.$b.$c" = "A.B.C" ]
EOF1
put fbsd/builtins/read9.0 <<'EOF1'

empty=''
read a b c <<EOF
\ \ A B\ \ B C\ \ $empty
EOF
read d e <<EOF
D\ $empty
EOF
[ "$a.$b.$c.$d.$e" = "  A.B  B.C  .D ." ]
EOF1
put fbsd/builtins/return1.0 <<'EOF'
f() {
	return 0
	exit 1
}

f
EOF
put fbsd/builtins/return2.1 <<'EOF'
f() {
	true && return 1
	return 0
}

f
EOF
put fbsd/builtins/return3.1 <<'EOF'
return 1
exit 0
EOF
put fbsd/builtins/return4.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX) || exit
trap 'rm -rf $T' 0
cd $T || exit 3
echo 'return 42; exit 4' >testscript
. ./testscript
[ "$?" = 42 ] || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/return5.0 <<'EOF'

if [ "$1" != nested ]; then
	f() {
		set -- nested
		. "$0"
		# Allow return to return from the function or the dot script.
		return 4
	}
	f
	exit $(($? ^ 4))
fi
# To trigger the bug, the following commands must be at the top level,
# with newlines in between.
return 4
echo bad
exit 1
EOF
put fbsd/builtins/return6.4 <<'EOF'

while return 4; do exit 3; done
EOF
put fbsd/builtins/return7.4 <<'EOF'

f() {
	while return 4; do exit 3; done
}
f
EOF
put fbsd/builtins/return8.0 <<'EOF'

if [ "$1" = nested ]; then
	return 17
fi

f() {
	set -- nested
	. "$0"
	return $(($? ^ 1))
}
f
exit $(($? ^ 16))
EOF
put fbsd/builtins/set1.0 <<'EOF'

set +C
set +f
set -e

settings=$(set +o)
set -C
set -f
set +e
case $- in
*C*) ;;
*) echo missing C ;;
esac
case $- in
*f*) ;;
*) echo missing C ;;
esac
case $- in
*e*) echo bad e ;;
esac
eval "$settings"
case $- in
*C*) echo bad C ;;
esac
case $- in
*f*) echo bad f ;;
esac
case $- in
*e*) ;;
*) echo missing e ;;
esac
EOF
put fbsd/builtins/set2.0 <<'EOF'

! env @badness=1 ${SH} -c 'v=`set`; eval "$v"' 2>&1 | grep @badness
EOF
put fbsd/builtins/set3.0 <<'EOF'

settings1=$(set +o) && set -o nolog && settings2=$(set +o) &&
[ "$settings1" != "$settings2" ]
EOF
put fbsd/builtins/trap1.0 <<'EOF'

test "$(trap 'echo trapped' EXIT; :)" = trapped || exit 1

test "$(trap 'echo trapped' EXIT; /usr/bin/true)" = trapped || exit 1

result=$(${SH} -c 'trap "echo trapped" EXIT; /usr/bin/false')
test $? -eq 1 || exit 1
test "$result" = trapped || exit 1

result=$(${SH} -c 'trap "echo trapped" EXIT; exec /usr/bin/false')
test $? -eq 1 || exit 1
test -z "$result" || exit 1

result=0
trap 'result=$((result+1))' INT
kill -INT $$
test "$result" -eq 1 || exit 1
(kill -INT $$)
test "$result" -eq 2 || exit 1

exit 0
EOF
put fbsd/builtins/trap10.0 <<'EOF'

# Check that the return statement will not break the EXIT trap, ie. all
# trap commands are executed before the script exits.

test "$(trap 'printf trap; echo ped' EXIT; f() { return; }; f)" = trapped || exit 1
EOF
put fbsd/builtins/trap11.0 <<'EOF'

# Check that the return statement will not break the USR1 trap, ie. all
# trap commands are executed before the script resumes.

result=$(${SH} -c 'trap "printf trap; echo ped" USR1; f() { return $(kill -USR1 $$); }; f')
test $? -eq 0 || exit 1
test "$result" = trapped || exit 1
EOF
put fbsd/builtins/trap12.0 <<'EOF'

f() {
	trap 'return 42' USR1
	kill -USR1 $$
	return 3
}
f
r=$?
[ "$r" = 42 ]
EOF
put fbsd/builtins/trap13.0 <<'EOF'

{
	trap 'exit 0' INT
	${SH} -c 'kill -INT $PPID'
	exit 3
} &
wait $!
EOF
put fbsd/builtins/trap14.0 <<'EOF'

{
	trap - INT
	${SH} -c 'kill -INT $PPID' &
	wait
} &
wait $!
r=$?
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = INT ]
EOF
put fbsd/builtins/trap15.0 <<'EOF'

(${SH} -c 'term(){ exit 5;}; trap term TERM; kill -TERM $$') &
wait >/dev/null 2>&1 $!
[ $? -eq 5 ]
EOF
put fbsd/builtins/trap16.0 <<'EOF'

traps=$(${SH} -c 'trap "echo bad" 0; trap - 0; trap')
[ -z "$traps" ] || exit 1
traps=$(${SH} -c 'trap "echo bad" 0; trap "" 0; trap')
expected_traps=$(${SH} -c 'trap "" EXIT; trap')
[ "$traps" = "$expected_traps" ] || exit 2
traps=$(${SH} -c 'trap "echo bad" 0; trap 0; trap')
[ -z "$traps" ] || exit 3
traps=$(${SH} -c 'trap "echo bad" 0; trap -- 0; trap')
[ -z "$traps" ] || exit 4
traps=$(${SH} -c 'trap "echo bad" 0 1 2; trap - 0 1 2; trap')
[ -z "$traps" ] || exit 5
traps=$(${SH} -c 'trap "echo bad" 0 1 2; trap "" 0 1 2; trap')
expected_traps=$(${SH} -c 'trap "" EXIT HUP INT; trap')
[ "$traps" = "$expected_traps" ] || exit 6
traps=$(${SH} -c 'trap "echo bad" 0 1 2; trap 0 1 2; trap')
[ -z "$traps" ] || exit 7
traps=$(${SH} -c 'trap "echo bad" 0 1 2; trap -- 0 1 2; trap')
[ -z "$traps" ] || exit 8
EOF
put fbsd/builtins/trap17.0 <<'EOF'
# This use-after-free bug probably needs non-default settings to show up.

v1=nothing v2=nothing
trap 'trap "echo bad" USR1
v1=trap_received
v2=trap_invoked
:' USR1
kill -USR1 "$$"
[ "$v1.$v2" = trap_received.trap_invoked ]
EOF
put fbsd/builtins/trap2.0 <<'EOF'
# This is really a test for outqstr(), which is readily accessible via trap.

runtest()
{
	teststring=$1
	trap -- "$teststring" USR1
	traps=$(trap)
	if [ "$teststring" != "-" ] && [ -z "$traps" ]; then
		# One possible reading of POSIX requires the above to return an
		# empty string because backquote commands are executed in a
		# subshell and subshells shall reset traps. However, an example
		# in the normative description of the trap builtin shows the
		# same usage as here, it is useful and our /bin/sh allows it.
		echo '$(trap) is broken'
		exit 1
	fi
	trap - USR1
	eval "$traps"
	traps2=$(trap)
	if [ "$traps" != "$traps2" ]; then
		echo "Mismatch for '$teststring'"
		exit 1
	fi
}

runtest 'echo'
runtest 'echo hi'
runtest "'echo' 'hi'"
runtest '"echo" $PATH'
runtest '\echo "$PATH"'
runtest ' 0'
runtest '0 '
runtest ' 1'
runtest '1 '
i=1
while [ $i -le 127 ]; do
	c=$(printf \\"$(printf %o $i)")
	if [ $i -lt 48 ] || [ $i -gt 57 ]; then
		runtest "$c"
	fi
	runtest " $c$c"
	runtest "a$c"
	i=$((i+1))
done
IFS=,
runtest ' '
runtest ','
unset IFS
runtest ' '

exit 0
EOF
put fbsd/builtins/trap3.0 <<'EOF'

{
	trap '' garbage && exit 3
	trap - garbage && exit 3
	trap true garbage && exit 3
	trap '' 99999 && exit 3
	trap - 99999 && exit 3
	trap true 99999 && exit 3
} 2>/dev/null
exit 0
EOF
put fbsd/builtins/trap4.0 <<'EOF'

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1

v=$(
	exec 3>&1
	: <fifo1 &
	{
		wait $!
		trap 'trap "" PIPE; echo trapped >&3 2>/dev/null' PIPE
		echo x 2>/dev/null
	} >fifo1
)
test "$v" = trapped
EOF
put fbsd/builtins/trap5.0 <<'EOF'

set -e
trap - USR1
initial=$(trap)
trap -- -l USR1
added=$(trap)
[ -n "$added" ]
trap - USR1
second=$(trap)
[ "$initial" = "$second" ]
eval "$added"
added2=$(trap)
added3=$(trap --)
[ "$added" = "$added2" ]
[ "$added2" = "$added3" ]
trap -- - USR1
third=$(trap)
[ "$initial" = "$third" ]
EOF
put fbsd/builtins/trap6.0 <<'EOF'

v=$(
	${SH} -c 'trap "echo ok; exit" USR1; kill -USR1 $$' &
	# Suppress possible message about exit on signal
	wait $! >/dev/null 2>&1
)
r=$(kill -l $?)
[ "$v" = "ok" ] && { [ "$r" = "USR1" ] || [ "$r" = "usr1" ]; }
EOF
put fbsd/builtins/trap7.0 <<'EOF'

[ "$(trap 'echo trapped' EXIT)" = trapped ]
EOF
put fbsd/builtins/trap8.0 <<'EOF'

# I am not sure if POSIX requires the shell to continue processing
# further trap names in the same trap command after an invalid one.

test -n "$(trap true garbage TERM 2>/dev/null || trap)" || exit 3
exit 0
EOF
put fbsd/builtins/trap9.0 <<'EOF'

test "$(trap 'printf trap; echo ped' EXIT; f() { :; }; f)" = trapped || exit 1
EOF
put fbsd/builtins/type1.0 <<'EOF'
command -v not-here && exit 1
command -v /not-here && exit 1
command -V not-here && exit 1
command -V /not-here && exit 1
type not-here && exit 1
type /not-here && exit 1
exit 0
EOF
put fbsd/builtins/type1.0.stderr <<'EOF'
not-here: not found
/not-here: No such file or directory
not-here: not found
/not-here: No such file or directory
EOF
put fbsd/builtins/type2.0 <<'EOF'

failures=0

check() {
	if ! eval "$*"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check 'PATH=/libexec type ld-elf.so.1 >/dev/null'
check '! PATH=/libexec type ls 2>/dev/null'

PATH=/libexec:$PATH

check 'type ld-elf.so.1 >/dev/null'

PATH=/libexec

check 'type ld-elf.so.1 >/dev/null'
check '! type ls 2>/dev/null'
check 'PATH=/bin type ls >/dev/null'
check '! PATH=/bin type ld-elf.so.1 2>/dev/null'

exit $((failures > 0))
EOF
put fbsd/builtins/type3.0 <<'EOF'

[ "$(type type)" = "$(type -- type)" ]
EOF
put fbsd/builtins/type4.0 <<'EOF'

r=`cd /bin && PATH=. type ls`
case $r in
*/bin/ls*|*/bin/./ls*) ;;
*)
	echo "Unexpected result: $r"
	exit 1
esac
EOF
put fbsd/builtins/unalias.0 <<'EOF'
set -e

alias false=true
false
unalias false
false && exit 1
unalias false && exit 1

alias a1=foo a2=bar
unalias a1 a2
unalias a1 && exit 1
unalias a2 && exit 1
alias a2=bar
unalias a1 a2 && exit 1

alias a1=foo a2=bar
unalias -a
unalias a1 && exit 1
unalias a2 && exit 1
exit 0
EOF
put fbsd/builtins/var-assign.0 <<'EOF'
IFS=,

SPECIAL="break,\
	:,\
	continue,\
	. /dev/null,
	eval,
	exec,
	export -p,
	readonly -p,
	set,
	shift 0,
	times,
	trap,
	unset foo"

UTILS="alias,\
	bg,\
	bind,\
	cd,\
	command echo,\
	echo,\
	false,\
	fc -l,\
	fg,\
	getopts a var,\
	hash,\
	jobs,\
	printf a,\
	pwd,\
	read var < /dev/null,\
	test,\
	true,\
	type ls,\
	ulimit,\
	umask,\
	unalias -a,\
	wait"

set -e

# For special built-ins variable assignments affect the shell environment.
set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "VAR=1; VAR=0 ${cmd}; exit \${VAR}" >/dev/null 2>&1
done

# For other built-ins and utilities they do not.
set -- ${UTILS}
for cmd in "$@"
do
	${SH} -c "VAR=0; VAR=1 ${cmd}; exit \${VAR}" >/dev/null 2>&1
done
EOF
put fbsd/builtins/var-assign2.0 <<'EOF'
IFS=,

SPECIAL="break,\
	:,\
	continue,\
	. /dev/null,\
	eval,\
	exec,\
	export -p,\
	readonly -p,\
	set,\
	shift 0,\
	times,\
	trap,\
	unset foo"

UTILS="alias,\
	bg,\
	bind,\
	cd,\
	command echo,\
	echo,\
	false,\
	fc -l,\
	fg,\
	getopts a var,\
	hash,\
	jobs,\
	printf a,\
	pwd,\
	read var < /dev/null,\
	test,\
	true,\
	type ls,\
	ulimit,\
	umask,\
	unalias -a,\
	wait"

set -e

# With 'command', variable assignments do not affect the shell environment.

set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "VAR=0; VAR=1 command ${cmd}; exit \${VAR}" >/dev/null 2>&1
done

set -- ${UTILS}
for cmd in "$@"
do
	${SH} -c "VAR=0; VAR=1 command ${cmd}; exit \${VAR}" >/dev/null 2>&1
done
EOF
put fbsd/builtins/wait1.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

exit 4 & p4=$!
exit 8 & p8=$!
wait $p4
[ $? = 4 ] || failure $LINENO
wait $p8
[ $? = 8 ] || failure $LINENO

exit 3 & p3=$!
exit 7 & p7=$!
wait $p7
[ $? = 7 ] || failure $LINENO
wait $p3
[ $? = 3 ] || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/wait10.0 <<'EOF'
# Init cannot be a child of the shell.
exit 49 & p49=$!
wait 1 "$p49"
[ "$?" = 49 ]
EOF
put fbsd/builtins/wait11.0 <<'EOF'
sleep 3 | sleep 2 &
sleep 3 &
kill %1
wait %1
r=$?
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = TERM ]
EOF
put fbsd/builtins/wait2.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

for i in 1 2 3 4 5 6 7 8 9 10; do
	exit $i &
done
wait || failure $LINENO
wait || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/wait3.0 <<'EOF'

failures=
failure() {
	echo "Error at line $1" >&2
	failures=x$failures
}

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1
for i in 1 2 3 4 5 6 7 8 9 10; do
	exit $i 4<fifo1 &
done
exec 3>fifo1
wait || failure $LINENO
(${SH} -c echo >&3) 2>/dev/null && failure $LINENO
wait || failure $LINENO

test -z "$failures"
EOF
put fbsd/builtins/wait4.0 <<'EOF'

T=`mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX`
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1
trapped=
trap trapped=1 QUIT
{ kill -QUIT $$; sleep 1; exit 4; } >fifo1 &
wait $! <fifo1
r=$?
[ "$r" -gt 128 ] && [ -n "$trapped" ]
EOF
put fbsd/builtins/wait5.0 <<'EOF'

T=`mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX`
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1
trapped=
trap trapped=1 QUIT
{ kill -QUIT $$; sleep 1; exit 4; } >fifo1 &
wait <fifo1
r=$?
[ "$r" -gt 128 ] && [ -n "$trapped" ]
EOF
put fbsd/builtins/wait6.0 <<'EOF'

wait --
EOF
put fbsd/builtins/wait7.0 <<'EOF'

: &
wait -- $!
EOF
put fbsd/builtins/wait8.0 <<'EOF'

exit 44 & p44=$!
exit 45 & p45=$!
exit 7 & p7=$!
wait "$p44" "$p7" "$p45"
[ "$?" = 45 ]
EOF
put fbsd/builtins/wait9.127 <<'EOF'
# Init cannot be a child of the shell.
wait 1
EOF
put fbsd/errors/assignment-error1.0 <<'EOF'
IFS=,

SPECIAL="break,\
	:,\
	continue,\
	. /dev/null,\
	eval,\
	exec,\
	export -p,\
	readonly -p,\
	set,\
	shift,\
	times,\
	trap,\
	unset foo"

# If there is no command word, the shell must abort on an assignment error.
${SH} -c "readonly a=0; a=2; exit 0" 2>/dev/null && exit 1

# Special built-in utilities must abort on an assignment error.
set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "readonly a=0; a=2 ${cmd}; exit 0" 2>/dev/null && exit 1
done

# Other utilities must not abort; we currently still execute them.
${SH} -c 'readonly a=0; a=1 true; exit $a' 2>/dev/null || exit 1
${SH} -c 'readonly a=0; a=1 command :; exit $a' 2>/dev/null || exit 1
EOF
put fbsd/errors/assignment-error2.0 <<'EOF'

set -e
HOME=/
readonly HOME
cd /sbin
{ HOME=/bin cd; } 2>/dev/null || :
[ "$(pwd)" != /bin ]
EOF
put fbsd/errors/backquote-error1.0 <<'EOF'

echo 'echo `for` echo ".BAD"CODE.' | ${SH} +m -i 2>&1 | grep -q BADCODE && exit 1
exit 0
EOF
put fbsd/errors/backquote-error2.0 <<'EOF'

${SH} -c 'echo `echo .BA"DCODE.`
echo ".BAD"CODE.' 2>&1 | grep -q BADCODE && exit 1
echo '`"`' | ${SH} -n 2>/dev/null && exit 1
echo '`'"'"'`' | ${SH} -n 2>/dev/null && exit 1
exit 0
EOF
put fbsd/errors/bad-binary1.126 <<'EOF'
# Checking for binary "scripts" without magic number is permitted but not
# required by POSIX. However, it is preferable to getting errors like
# Syntax error: word unexpected (expecting ")")
# from trying to execute ELF binaries for the wrong architecture.

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf '\0echo bad\n' >"$T/testshellproc"
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
testshellproc 2>/dev/null
EOF
put fbsd/errors/bad-keyword1.0 <<'EOF'

echo ':; fi' | ${SH} -n 2>/dev/null && exit 1
exit 0
EOF
put fbsd/errors/bad-parm-exp1.0 <<'EOF'
false && {
	${}
	${foo/}
	${foo@bar}
}
:
EOF
put fbsd/errors/bad-parm-exp2.2 <<'EOF'
eval '${}'
EOF
put fbsd/errors/bad-parm-exp2.2.stderr <<'EOF'
eval: ${}: Bad substitution
EOF
put fbsd/errors/bad-parm-exp3.2 <<'EOF'
eval '${foo/}'
EOF
put fbsd/errors/bad-parm-exp3.2.stderr <<'EOF'
eval: ${foo/}: Bad substitution
EOF
put fbsd/errors/bad-parm-exp4.2 <<'EOF'
eval '${foo:@abc}'
EOF
put fbsd/errors/bad-parm-exp4.2.stderr <<'EOF'
eval: ${foo:@...}: Bad substitution
EOF
put fbsd/errors/bad-parm-exp5.2 <<'EOF'
eval '${/}'
EOF
put fbsd/errors/bad-parm-exp5.2.stderr <<'EOF'
eval: ${/}: Bad substitution
EOF
put fbsd/errors/bad-parm-exp6.2 <<'EOF'
eval '${#foo^}'
EOF
put fbsd/errors/bad-parm-exp6.2.stderr <<'EOF'
eval: ${foo...}: Bad substitution
EOF
put fbsd/errors/bad-parm-exp7.0 <<'EOF'

v=1
eval ": $(printf '${v-${\372}}')"
EOF
put fbsd/errors/bad-parm-exp8.0 <<'EOF'

v=1
eval ": $(printf '${v-${w\372}}')"
EOF
put fbsd/errors/option-error.0 <<'EOF'
IFS=,

SPECIAL="break abc,\
	continue abc,\
	.,
	exit abc,
	export -x,
	readonly -x,
	return abc,
	set -z,
	shift abc,
	trap -y,
	unset -y"

UTILS="alias -y,\
	cat -z,\
	cd abc def,\
	command break abc,\
	expr 1 +,\
	fc -z,\
	getopts,\
	hash -z,\
	jobs -z,\
	printf,\
	pwd abc,\
	read,\
	test abc =,\
	ulimit -z,\
	umask -z,\
	unalias -z,\
	wait abc"

# Special built-in utilities must abort on an option or operand error.
set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "${cmd}; exit 0" 2>/dev/null && exit 1
done

# Other utilities must not abort.
set -- ${UTILS}
for cmd in "$@"
do
	${SH} -c "${cmd}; exit 0" 2>/dev/null || exit 1
done
EOF
put fbsd/errors/redirection-error.0 <<'EOF'
IFS=,

SPECIAL="break,\
	:,\
	continue,\
	. /dev/null,
	eval,
	exec,
	export -p,
	readonly -p,
	set,
	shift,
	times,
	trap,
	unset foo"

UTILS="alias,\
	bg,\
	bind,\
	cd,\
	command echo,\
	echo,\
	false,\
	fc -l,\
	fg,\
	getopts a -a,\
	hash,\
	jobs,\
	printf a,\
	pwd,\
	read var < /dev/null,\
	test,\
	true,\
	type ls,\
	ulimit,\
	umask,\
	unalias -a,\
	wait"

# Special built-in utilities must abort on a redirection error.
set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "${cmd} > /; exit 0" 2>/dev/null && exit 1
done

# Other utilities must not abort.
set -- ${UTILS}
for cmd in "$@"
do
	${SH} -c "${cmd} > /; exit 0" 2>/dev/null || exit 1
done
EOF
put fbsd/errors/redirection-error2.2 <<'EOF'

# sh should fail gracefully on this bad redirect
${SH} -c 'echo 1 >&$a' 2>/dev/null
EOF
put fbsd/errors/redirection-error3.0 <<'EOF'
IFS=,

SPECIAL="break,\
	:,\
	continue,\
	. /dev/null,\
	eval,\
	exec,\
	export -p,\
	readonly -p,\
	set,\
	shift,\
	times,\
	trap,\
	unset foo"

UTILS="alias,\
	bg,\
	bind,\
	cd,\
	command echo,\
	echo,\
	false,\
	fc -l,\
	fg,\
	getopts a -a,\
	hash,\
	jobs,\
	printf a,\
	pwd,\
	read var < /dev/null,\
	test,\
	true,\
	type ls,\
	ulimit,\
	umask,\
	unalias -a,\
	wait"

# When used with 'command', neither special built-in utilities nor other
# utilities must abort on a redirection error.

set -- ${SPECIAL}
for cmd in "$@"
do
	${SH} -c "command ${cmd} > /; exit 0" 2>/dev/null || exit 1
done

set -- ${UTILS}
for cmd in "$@"
do
	${SH} -c "command ${cmd} > /; exit 0" 2>/dev/null || exit 1
done
EOF
put fbsd/errors/redirection-error4.0 <<'EOF'
# A redirection error should not abort the shell if there is no command word.
exec 2>/dev/null
</var/empty/x
</var/empty/x y=2
y=2 </var/empty/x
exit 0
EOF
put fbsd/errors/redirection-error5.0 <<'EOF'
# A redirection error on a subshell should not abort the shell.
exec 2>/dev/null
( echo bad ) </var/empty/x
exit 0
EOF
put fbsd/errors/redirection-error6.0 <<'EOF'
# A redirection error on a compound command should not abort the shell.
exec 2>/dev/null
{ echo bad; } </var/empty/x
if :; then echo bad; fi </var/empty/x
for i in 1; do echo bad; done </var/empty/x
i=0
while [ $i = 0 ]; do echo bad; i=1; done </var/empty/x
i=0
until [ $i != 0 ]; do echo bad; i=1; done </var/empty/x
case i in *) echo bad ;; esac </var/empty/x
exit 0
EOF
put fbsd/errors/redirection-error7.0 <<'EOF'

! dummy=$(
	exec 3>&1 >&2 2>&3
	ulimit -n 9
	exec 9<.
) && [ -n "$dummy" ]
EOF
put fbsd/errors/redirection-error8.0 <<'EOF'

$SH -c '{ { :; } </var/empty/x; } 2>/dev/null || kill -INT $$; echo continued'
r=$?
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = INT ]
EOF
put fbsd/errors/script-error1.0 <<'EOF'

{ stderr=$(${SH} /var/empty/nosuchscript 2>&1 >&3); } 3>&1
r=$?
[ -n "$stderr" ] && [ "$r" = 127 ]
EOF
put fbsd/errors/write-error1.0 <<'EOF'

! echo >&- 2>/dev/null
EOF
put fbsd/execution/bg1.0 <<'EOF'

: `false` &
EOF
put fbsd/execution/bg10.0 <<'EOF'
# The redirection overrides the </dev/null implicit in a background command.

echo yes | ${SH} -c '{ cat & wait; } <&0'
EOF
put fbsd/execution/bg10.0.stdout <<'EOF'
yes
EOF
put fbsd/execution/bg11.0 <<'EOF'

T=`mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXXXX`
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1
# Use a trap, not the default action, since the shell may catch SIGINT and
# therefore its processing may be delayed.
{ trap 'exit 5' TERM; read dummy <fifo1; exit 4; } &
exec 3>fifo1
kill -INT "$!"
kill -TERM "$!"
exec 3>&-
wait "$!"
r=$?
[ "$r" = 5 ]
EOF
put fbsd/execution/bg12.0 <<'EOF'

T=`mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXXXX`
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1
{ trap - INT; : >fifo1; sleep 5 & wait; exit 4; } &
: <fifo1
kill -INT "$!"
wait "$!"
r=$?
[ "$r" -gt 128 ] && [ "$(kill -l "$r")" = INT ]
EOF
put fbsd/execution/bg13.0 <<'EOF'

T=`mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXXXX`
trap 'rm -rf $T' 0
cd $T || exit 3
mkfifo fifo1
# Use a trap, not the default action, since the shell may catch SIGINT and
# therefore its processing may be delayed.
{ set -C; trap 'exit 5' TERM; read dummy <fifo1; exit 4; } &
exec 3>fifo1
kill -INT "$!"
kill -TERM "$!"
exec 3>&-
wait "$!"
r=$?
[ "$r" = 5 ]
EOF
put fbsd/execution/bg14.0 <<'EOF'
T=`mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXXXX`
trap 'rm -rf "$T"' 0
cd "$T" || exit 3
mkfifo fifo1 || exit 3
set -T
trap "for i in 1 2 3 4; do sleep 1 & done" USR1
sleep 1 &
{ kill -USR1 "$$"; echo .; } >fifo1 &
(read dummy <fifo1)
EOF
put fbsd/execution/bg2.0 <<'EOF'

f() { return 42; }
f
: | : &
EOF
put fbsd/execution/bg3.0 <<'EOF'

f() { return 42; }
f
(:) &
EOF
put fbsd/execution/bg4.0 <<'EOF'

x=''
: ${x:=1} &
wait
exit ${x:-0}
EOF
put fbsd/execution/bg5.0 <<'EOF'
# A background command has an implicit </dev/null redirection.

echo bad | ${SH} -c '{ cat & wait; }'
EOF
put fbsd/execution/bg6.0 <<'EOF'
# The redirection overrides the </dev/null implicit in a background command.

echo yes | ${SH} -c '{ cat & wait; } </dev/stdin'
EOF
put fbsd/execution/bg6.0.stdout <<'EOF'
yes
EOF
put fbsd/execution/bg7.0 <<'EOF'
# The redirection does not apply to the background command, and therefore
# does not override the implicit </dev/null.

echo bad | ${SH} -c '</dev/null; { cat & wait; }'
EOF
put fbsd/execution/bg8.0 <<'EOF'
# The redirection does not apply to the background command, and therefore
# does not override the implicit </dev/null.

echo bad | ${SH} -c 'command eval \) </dev/null 2>/dev/null; { cat & wait; }'
EOF
put fbsd/execution/bg9.0 <<'EOF'
# The redirection does not apply to the background command, and therefore
# does not override the implicit </dev/null.

echo bad | ${SH} -c 'command eval eval \\\) \</dev/null 2>/dev/null; { cat & wait; }'
EOF
put fbsd/execution/env1.0 <<'EOF'

unset somestrangevar
export somestrangevar
[ "`$SH -c 'echo ${somestrangevar-unset}'`" = unset ]
EOF
put fbsd/execution/fork1.0 <<'EOF'

shname=${SH%% *}
shname=${shname##*/}

result=$(${SH} -c 'ps -p $$ -o comm=')
test "$result" = "ps" || exit 1

result=$(${SH} -c 'ps -p $$ -o comm=; :')
test "$result" = "$shname" || exit 1
EOF
put fbsd/execution/fork2.0 <<'EOF'

result=$(${SH} -c '(/bin/sleep 1)& sleep 0.1; ps -p $! -o comm=; kill $!')
test "$result" = sleep || exit 1

result=$(${SH} -c '{ trap "echo trapped" EXIT; (/usr/bin/true); } & wait')
test "$result" = trapped || exit 1

exit 0
EOF
put fbsd/execution/fork3.0 <<'EOF'

result=$(${SH} -c 'f() { ps -p $$ -o comm=; }; f')
test "$result" = "ps"
EOF
put fbsd/execution/func1.0 <<'EOF'

MALLOC_CONF=junk:true ${SH} -c 'g() { g() { :; }; :; }; g' &&
MALLOC_CONF=junk:true ${SH} -c 'g() { unset -f g; :; }; g'
EOF
put fbsd/execution/func2.0 <<'EOF'
# The empty pairs of braces here are to test that this does not cause a crash.

f() { }
f
hash -v f >/dev/null
f() { { }; }
f
hash -v f >/dev/null
f() { { } }
f
hash -v f >/dev/null
EOF
put fbsd/execution/func3.0 <<'EOF'

# This may fail when parsing or when defining the function, or the definition
# may silently do nothing. In no event may the function be executed.

${SH} -c 'unset() { echo overriding function executed, bad; }; v=1; unset v; exit "${v-0}"' 2>/dev/null
:
EOF
put fbsd/execution/hash1.0 <<'EOF1'

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
PATH=$T:$PATH
ls -ld . >/dev/null
cat <<EOF >"$T/ls"
:
EOF
chmod 755 "$T/ls"
PATH=$PATH
ls -ld .
EOF1
put fbsd/execution/int-cmd1.0 <<'EOF'

! echo echo bad | ENV= $SH -ic 'fi' 2>/dev/null
EOF
put fbsd/execution/killed1.0 <<'EOF'
# Sometimes the "Killed" message is not flushed soon enough and it
# is redirected along with the output of a builtin.
# Do not change the semicolon to a newline as it would hide the bug.

exec 3>&1
exec >/dev/null 2>&1
${SH} -c 'kill -9 $$'; : >&3 2>&3
EOF
put fbsd/execution/killed2.0 <<'EOF'
# Most shells print a message when a foreground job is killed by a signal.
# POSIX allows this, provided the message is sent to stderr, not stdout.
# Some trickery is needed to capture the message as redirecting stderr of
# the command itself does not affect it. The colon command ensures that
# the subshell forks for ${SH}.

exec 3>&1
r=`(${SH} -c 'kill $$'; :) 2>&1 >&3`
[ -n "$r" ]
EOF
put fbsd/execution/not1.0 <<'EOF'

f() { ! return $1; }
f 0 && ! f 1
EOF
put fbsd/execution/not2.0 <<'EOF'

while :; do
	! break
	exit 3
done
EOF
put fbsd/execution/path1.0 <<'EOF'
# Some builtins should not be overridable via PATH.

set -e
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf ${T}' 0
echo '#!/bin/sh
echo bad' >"$T/cd"
chmod 755 "$T/cd"
cd /bin
oPATH=$PATH
PATH=$T:$PATH:%builtin
cd /
PATH=$oPATH
[ "$(pwd)" = / ]
EOF
put fbsd/execution/pipefail1.0 <<'EOF'

set -o pipefail
: && : | : && : | : | : && : | : | : | :
EOF
put fbsd/execution/pipefail2.42 <<'EOF'

set -o pipefail
(exit 42) | :
EOF
put fbsd/execution/pipefail3.42 <<'EOF'

set -o pipefail
: | (exit 42)
EOF
put fbsd/execution/pipefail4.42 <<'EOF'

set -o pipefail
(exit 43) | (exit 42)
EOF
put fbsd/execution/pipefail5.42 <<'EOF'

set -o pipefail
(exit 42) | : &
wait %+
EOF
put fbsd/execution/pipefail6.42 <<'EOF'

set -o pipefail
(exit 42) | : &
set +o pipefail
wait %+
EOF
put fbsd/execution/pipefail7.0 <<'EOF'

(exit 42) | : &
set -o pipefail
wait %+
EOF
put fbsd/execution/redir1.0 <<'EOF'
trap ': $((brokenpipe+=1))' PIPE

P=${TMPDIR:-/tmp}
cd $P
T=$(mktemp -d sh-test.XXXXXX)
cd $T

brokenpipe=0
mkfifo fifo1 fifo2
read dummy >fifo2 <fifo1 &
{
	exec 4>fifo2
} 3<fifo2 # Formerly, sh would keep fd 3 and a duplicate of it open.
echo dummy >fifo1
if [ $brokenpipe -ne 0 ]; then
	rc=3
fi
wait
echo dummy >&4 2>/dev/null
if [ $brokenpipe -eq 1 ]; then
	: ${rc:=0}
fi

rm fifo1 fifo2
rmdir ${P}/${T}
exit ${rc:-3}
EOF
put fbsd/execution/redir2.0 <<'EOF'
trap ': $((brokenpipe+=1))' PIPE

P=${TMPDIR:-/tmp}
cd $P
T=$(mktemp -d sh-test.XXXXXX)
cd $T

brokenpipe=0
mkfifo fifo1 fifo2
{
	{
		exec ${SH} -c 'exec <fifo1; read dummy'
	} 7<&- # fifo2 should be kept open, but not passed to programs
	true
} 7<fifo2 &

exec 4>fifo2
exec 3>fifo1
echo dummy >&4 2>/dev/null
if [ $brokenpipe -eq 1 ]; then
	: ${rc:=0}
fi
echo dummy >&3
wait

rm fifo1 fifo2
rmdir ${P}/${T}
exit ${rc:-3}
EOF
put fbsd/execution/redir3.0 <<'EOF'

3>&- 3>&-
EOF
put fbsd/execution/redir4.0 <<'EOF'

{ echo bad 0>&3; } 2>/dev/null 3>/dev/null 3>&-
exit 0
EOF
put fbsd/execution/redir5.0 <<'EOF'

{ (echo bad) >/dev/null; } </dev/null
EOF
put fbsd/execution/redir6.0 <<'EOF'

failures=0

check() {
	if [ "$2" != "$3" ]; then
		echo "Failure at $1" >&2
		failures=$((failures + 1))
	fi
}

check $LINENO "$(trap "echo bye" EXIT; : >/dev/null)" bye
check $LINENO "$(trap "echo bye" EXIT; { :; } >/dev/null)" bye
check $LINENO "$(trap "echo bye" EXIT; (:) >/dev/null)" bye
check $LINENO "$(trap "echo bye" EXIT; (: >/dev/null))" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; : >/dev/null')" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; { :; } >/dev/null')" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; (:) >/dev/null')" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; (: >/dev/null)')" bye

exit $((failures > 0))
EOF
put fbsd/execution/redir7.0 <<'EOF'

failures=0

check() {
	if [ "$2" != "$3" ]; then
		echo "Failure at $1" >&2
		failures=$((failures + 1))
	fi
}

check $LINENO "$(trap "echo bye" EXIT; f() { :; }; f >/dev/null)" bye
check $LINENO "$(trap "echo bye" EXIT; f() { :; }; { f; } >/dev/null)" bye
check $LINENO "$(trap "echo bye" EXIT; f() { :; }; (f) >/dev/null)" bye
check $LINENO "$(trap "echo bye" EXIT; f() { :; }; (f >/dev/null))" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; f() { :; }; f >/dev/null')" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; f() { :; }; { f; } >/dev/null')" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; f() { :; }; (f) >/dev/null')" bye
check $LINENO "$(${SH} -c 'trap "echo bye" EXIT; f() { :; }; (f >/dev/null)')" bye

exit $((failures > 0))
EOF
put fbsd/execution/set-C1.0 <<'EOF'

T=$(mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX") || exit
trap 'rm -rf "$T"' 0

set -C
echo . >"$T/a" &&
[ -s "$T/a" ] &&
{ ! true >"$T/a"; } 2>/dev/null &&
[ -s "$T/a" ] &&
ln -s /dev/null "$T/b" &&
true >"$T/b"
EOF
put fbsd/execution/set-n1.0 <<'EOF1'

v=$( ($SH -n <<'EOF'
for
EOF
) 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF1
put fbsd/execution/set-n2.0 <<'EOF1'

$SH -n <<'EOF'
echo bad
EOF
EOF1
put fbsd/execution/set-n3.0 <<'EOF'

v=$( ($SH -nc 'for') 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF
put fbsd/execution/set-n4.0 <<'EOF'

$SH -nc 'echo bad'
EOF
put fbsd/execution/set-x1.0 <<'EOF'

key='must_contain_this'
{ r=`set -x; { : "$key"; } 2>&1 >/dev/null`; } 2>/dev/null
case $r in
*"$key"*) true ;;
*) false ;;
esac
EOF
put fbsd/execution/set-x2.0 <<'EOF'

key='must contain this'
PS4="$key+ "
{ r=`set -x; { :; } 2>&1 >/dev/null`; } 2>/dev/null
case $r in
*"$key"*) true ;;
*) false ;;
esac
EOF
put fbsd/execution/set-x3.0 <<'EOF'

key='must contain this'
PS4='$key+ '
{ r=`set -x; { :; } 2>&1 >/dev/null`; } 2>/dev/null
case $r in
*"$key"*) true ;;
*) false ;;
esac
EOF
put fbsd/execution/set-x4.0 <<'EOF'

key=`printf '\r\t\001\200\300'`
r=`{ set -x; : "$key"; } 2>&1 >/dev/null`
case $r in
*[![:print:]]*) echo fail; exit 3
esac
EOF
put fbsd/execution/shellproc1.0 <<'EOF1'

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
cat <<EOF >"$T/testshellproc"
printf 'this '
echo is a test
EOF
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
[ "`testshellproc`" = "this is a test" ]
EOF1
put fbsd/execution/shellproc2.0 <<'EOF'
# This tests a quality of implementation issue.
# Shells are not required to reject executing binary files as shell scripts
# but executing, for example, ELF files for a different architecture as
# shell scripts may have annoying side effects.

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf '\0' >"$T/testshellproc"
chmod 755 "$T/testshellproc"
if [ ! -s "$T/testshellproc" ]; then
	printf "printf did not write a NUL character\n" >&2
	exit 2
fi
PATH=$T:$PATH
errout=`testshellproc 3>&2 2>&1 >&3 3>&-`
r=$?
[ "$r" = 126 ] && [ -n "$errout" ]
EOF
put fbsd/execution/shellproc3.0 <<'EOF'
# This tests a quality of implementation issue.
# Shells are not required to reject executing binary files as shell scripts
# but executing, for example, ELF files for a different architecture as
# shell scripts may have annoying side effects.

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf '\177ELF\001!!\011\0\0\0\0\0\0\0\0' >"$T/testshellproc"
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
errout=`testshellproc 3>&2 2>&1 >&3 3>&-`
r=$?
[ "$r" = 126 ] && [ -n "$errout" ]
EOF
put fbsd/execution/shellproc4.0 <<'EOF'
# This tests a quality of implementation issue.
# Shells are not required to reject executing binary files as shell scripts
# but executing, for example, ELF files for a different architecture as
# shell scripts may have annoying side effects.

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf '\211PNG\015\012\032\012\0\0\0\015IHDR' >"$T/testshellproc"
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
errout=`testshellproc 3>&2 2>&1 >&3 3>&-`
r=$?
[ "$r" = 126 ] && [ -n "$errout" ]
EOF
put fbsd/execution/shellproc5.0 <<'EOF'
# This tests a quality of implementation issue.
# Shells are not required to reject executing binary files as shell scripts
# but executing, for example, ELF files for a different architecture as
# shell scripts may have annoying side effects.

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf '\177ELF\001!!\012\0\0\0\0\0\0\0\0' >"$T/testshellproc"
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
errout=`testshellproc 3>&2 2>&1 >&3 3>&-`
r=$?
[ "$r" = 126 ] && [ -n "$errout" ]
EOF
put fbsd/execution/shellproc6.0 <<'EOF'

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf 'printf "this "\necho is a test\nexit\n\0' >"$T/testshellproc"
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
[ "`testshellproc`" = "this is a test" ]
EOF
put fbsd/execution/shellproc7.0 <<'EOF'
# Non-POSIX trickery that is widely supported,
# used by https://justine.lol/ape.html

T=`mktemp -d "${TMPDIR:-/tmp}/sh-test.XXXXXXXX"` || exit
trap 'rm -rf "${T}"' 0
printf "MZqFpD='\n\0'\n#'\"\necho this is a test\n" >"$T/testshellproc"
chmod 755 "$T/testshellproc"
PATH=$T:$PATH
[ "`testshellproc`" = "this is a test" ]
EOF
put fbsd/execution/subshell1.0 <<'EOF'

(eval "cd /
v=$(printf %0100000d 1)
echo \${#v}")
echo end
EOF
put fbsd/execution/subshell1.0.stdout <<'EOF'
100000
end
EOF
put fbsd/execution/subshell2.0 <<'EOF'

f() {
	x=2
}
(
	x=1
	f
	[ "$x" = 2 ]
)
EOF
put fbsd/execution/subshell3.0 <<'EOF'

(false; exit) && exit 3
exit 0
EOF
put fbsd/execution/subshell4.0 <<'EOF'

(eval "set v=1"; false) && echo bad; :
EOF
put fbsd/execution/unknown1.0 <<'EOF'

nosuchtool 2>/dev/null
[ $? -ne 127 ] && exit 1
/var/empty/nosuchtool 2>/dev/null
[ $? -ne 127 ] && exit 1
(nosuchtool) 2>/dev/null
[ $? -ne 127 ] && exit 1
(/var/empty/nosuchtool) 2>/dev/null
[ $? -ne 127 ] && exit 1
/ 2>/dev/null
[ $? -ne 126 ] && exit 1
PATH=/usr bin 2>/dev/null
[ $? -ne 126 ] && exit 1

dummy=$(nosuchtool 2>/dev/null)
[ $? -ne 127 ] && exit 1
dummy=$(/var/empty/nosuchtool 2>/dev/null)
[ $? -ne 127 ] && exit 1
dummy=$( (nosuchtool) 2>/dev/null)
[ $? -ne 127 ] && exit 1
dummy=$( (/var/empty/nosuchtool) 2>/dev/null)
[ $? -ne 127 ] && exit 1
dummy=$(/ 2>/dev/null)
[ $? -ne 126 ] && exit 1
dummy=$(PATH=/usr bin 2>/dev/null)
[ $? -ne 126 ] && exit 1

exit 0
EOF
put fbsd/execution/unknown2.0 <<'EOF'

{
	: $(/var/empty/nosuchtool) 
	: $(:)
} 2>/dev/null
EOF
put fbsd/execution/var-assign1.0 <<'EOF'

[ "$(HOME=/etc HOME=/ cd && pwd)" = / ]
EOF
put fbsd/expansion/arith1.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

check "0&&0" 0
check "1&&0" 0
check "0&&1" 0
check "1&&1" 1
check "2&&2" 1
check "1&&2" 1
check "1<<40&&1<<40" 1
check "1<<40&&4" 1

check "0||0" 0
check "1||0" 1
check "0||1" 1
check "1||1" 1
check "2||2" 1
check "1||2" 1
check "1<<40||1<<40" 1
check "1<<40||4" 1

exit $((failures != 0))
EOF
put fbsd/expansion/arith10.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

readonly ro=4
rw=1
check "0 && 0 / 0" 0
check "1 || 0 / 0" 1
check "0 && (ro = 2)" 0
check "ro" 4
check "1 || (ro = -1)" 1
check "ro" 4
check "0 && (rw += 1)" 0
check "rw" 1
check "1 || (rw += 1)" 1
check "rw" 1
check "0 ? 44 / 0 : 51" 51
check "0 ? ro = 3 : 52" 52
check "ro" 4
check "0 ? rw += 1 : 52" 52
check "rw" 1
check "1 ? 68 : 30 / 0" 68
check "2 ? 1 : (ro += 2)" 1
check "ro" 4
check "4 ? 1 : (rw += 1)" 1
check "rw" 1

exit $((failures != 0))
EOF
put fbsd/expansion/arith11.0 <<'EOF'
# Try to divide the smallest integer by -1.
# On amd64 this causes SIGFPE, so make sure the shell checks.

# Calculate the minimum possible value, assuming two's complement and
# a certain interpretation of overflow when shifting left.
minint=1
while [ $((minint <<= 1)) -gt 0 ]; do
	:
done
v=$( eval ': $((minint / -1))' 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF
put fbsd/expansion/arith12.0 <<'EOF'

_x=4 y_=5 z_z=6
[ "$((_x*100+y_*10+z_z))" = 456 ]
EOF
put fbsd/expansion/arith13.0 <<'EOF'
# Pre-increment and pre-decrement in arithmetic expansion are not in POSIX.
# Require either an error or a correct implementation.

! (eval 'x=4; [ $((++x)) != 5 ] || [ $x != 5 ]') 2>/dev/null &&
! (eval 'x=2; [ $((--x)) != 1 ] || [ $x != 1 ]') 2>/dev/null
EOF
put fbsd/expansion/arith14.0 <<'EOF'
# Check that <</>> use the low bits of the shift count.

if [ $((1<<16<<16)) = 0 ]; then
	width=32
elif [ $((1<<32<<32)) = 0 ]; then
	width=64
elif [ $((1<<64<<64)) = 0 ]; then
	width=128
elif [ $((1<<64>>64)) = 1 ]; then
	# Integers are wider than 128 bits; assume arbitrary precision.
	# Nothing to test here.
	exit 0
else
	echo "Cannot determine integer width"
	exit 2
fi

twowidth=$((width * 2))
j=43 k=$((1 << (width - 2))) r=0

i=0
while [ $i -lt $twowidth ]; do
	if [ "$((j << i))" != "$((j << (i + width)))" ]; then
		echo "Problem with $j << $i"
		r=2
	fi
	i=$((i + 1))
done

i=0
while [ $i -lt $twowidth ]; do
	if [ "$((k >> i))" != "$((k >> (i + width)))" ]; then
		echo "Problem with $k >> $i"
		r=2
	fi
	i=$((i + 1))
done

exit $r
EOF
put fbsd/expansion/arith15.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

XXX=-9223372036854775808
check "XXX"		-9223372036854775808
check "XXX - 1" 	9223372036854775807
check "$XXX - 1"	9223372036854775807
check "$XXX - 2"	9223372036854775806
check "0x8000000000000000 == 0x7fffffffffffffff" \
			0

exit $((failures != 0))
EOF
put fbsd/expansion/arith16.0 <<'EOF'

failures=0

for x in \
	0x10000000000000000 \
	-0x8000000000000001 \
	0xfffffffffffffffffffffffffffffffff \
	-0xfffffffffffffffffffffffffffffffff \
	02000000000000000000000 \
	9223372036854775808 \
	9223372036854775809 \
	-9223372036854775809 \
	9999999999999999999999999 \
	-9999999999999999999999999
do
	msg=$({
		v=$((x)) || :
	} 3>&1 >&2 2>&3 3>&-)
	r=$?
	if [ "$r" = 0 ] || [ -z "$msg" ]; then
		printf 'Failed: %s\n' "$x"
		: $((failures += 1))
	fi
done
exit $((failures > 0))
EOF
put fbsd/expansion/arith17.0 <<'EOF'

[ $((9223372036854775809)) -gt 0 ]
EOF
put fbsd/expansion/arith2.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

# variables
unset v
check "v=2" 2
check "v" 2
check "$(($v))" 2
check "v+=1" 3
check "v" 3

# constants
check "4611686018427387904" 4611686018427387904
check "0x4000000000000000" 4611686018427387904
check "0400000000000000000000" 4611686018427387904
check "0x4Ab0000000000000" 5381801554707742720
check "010" 8

# try out all operators
v=42
check "!v" 0
check "!!v" 1
check "!0" 1
check "~0" -1
check "~(-1)" 0
check "-0" 0
check "-v" -42
check "v*v" 1764
check "v/2" 21
check "v%10" 2
check "v+v" 84
check "v-4" 38
check "v<<1" 84
check "v>>1" 21
check "v<43" 1
check "v>42" 0
check "v<=43" 1
check "v>=43" 0
check "v==41" 0
check "v!=42" 0
check "v&3" 2
check "v^3" 41
check "v|3" 43
check "v>=40&&v<=44" 1
check "v<40||v>44" 0
check "(v=42)&&(v+=1)==43" 1
check "v" 43
check "(v=42)&&(v-=1)==41" 1
check "v" 41
check "(v=42)&&(v*=2)==84" 1
check "v" 84
check "(v=42)&&(v/=10)==4" 1
check "v" 4
check "(v=42)&&(v%=10)==2" 1
check "v" 2
check "(v=42)&&(v<<=1)==84" 1
check "v" 84
check "(v=42)&&(v>>=2)==10" 1
check "v" 10
check "(v=42)&&(v&=32)==32" 1
check "v" 32
check "(v=42)&&(v^=32)==10" 1
check "v" 10
check "(v=42)&&(v|=32)==42" 1
check "v" 42

# missing: ternary

exit $((failures != 0))
EOF
put fbsd/expansion/arith3.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

check "1 << 1 + 1 | 1" 5

exit $((failures != 0))
EOF
put fbsd/expansion/arith4.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

check '20 / 2 / 2' 5
check '20 - 2 - 2' 16
unset a b c d
check "a = b = c = d = 1" 1
check "a == 1 && b == 1 && c == 1 && d == 1" 1
check "a += b += c += d" 4
check "a == 4 && b == 3 && c == 2 && d == 1" 1

exit $((failures != 0))
EOF
put fbsd/expansion/arith5.0 <<'EOF'

failures=0

check() {
	if [ "$2" != "$3" ]; then
		failures=$((failures+1))
		echo "For $1, expected $3 actual $2"
	fi
}

unset a
check '$((1+${a:-$((7+2))}))' "$((1+${a:-$((7+2))}))" 10
check '$((1+${a:=$((2+2))}))' "$((1+${a:=$((2+2))}))" 5
check '$a' "$a" 4

exit $((failures != 0))
EOF
put fbsd/expansion/arith6.0 <<'EOF'

v1=1\ +\ 1
v2=D
v3=C123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789
f() { v4="$*"; }

while [ ${#v2} -lt 1250 ]; do
	eval $v2=$((3+${#v2})) $v3=$((4-${#v2}))
	eval f $(($v2+ $v1 +$v3))
	if [ $v4 -ne 9 ]; then
		echo bad: $v4 -ne 9 at ${#v2}
	fi
	v2=x$v2
	v3=y$v3
done
EOF
put fbsd/expansion/arith7.0 <<'EOF1'

v=1+
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
[ "$(cat <<EOF
$(($v 1))
EOF
)" = 1025 ]
EOF1
put fbsd/expansion/arith8.0 <<'EOF'

v=$( (eval ': $((08))') 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF
put fbsd/expansion/arith9.0 <<'EOF'

failures=0

check() {
	if [ $(($1)) != $2 ]; then
		failures=$((failures+1))
		echo "For $1, expected $2 actual $(($1))"
	fi
}

check "0 ? 44 : 51" 51
check "1 ? 68 : 30" 68
check "2 ? 1 : -5" 1
check "0 ? 4 : 0 ? 5 : 6" 6
check "0 ? 4 : 1 ? 5 : 6" 5
check "1 ? 4 : 0 ? 5 : 6" 4
check "1 ? 4 : 1 ? 5 : 6" 4

exit $((failures != 0))
EOF
put fbsd/expansion/assign1.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'v=; set -- ${v=a b} $v'		'0|'
testcase 'unset v; set -- ${v=a b} $v'		'4|a|b|a|b'
testcase 'v=; set -- ${v:=a b} $v'		'4|a|b|a|b'
testcase 'v=; set -- "${v:=a b}" "$v"'		'2|a b|a b'
# expect sensible behaviour, although it disagrees with POSIX
testcase 'v=; set -- ${v:=a\ b} $v'		'4|a|b|a|b'
testcase 'v=; set -- ${v:=$p} $v'		'2|/etc/|/etc/'
testcase 'v=; set -- "${v:=$p}" "$v"'		'2|/et[c]/|/et[c]/'
testcase 'v=; set -- "${v:=a\ b}" "$v"'		'2|a\ b|a\ b'
testcase 'v=; set -- ${v:="$p"} $v'		'2|/etc/|/etc/'
# whether $p is quoted or not shouldn't really matter
testcase 'v=; set -- "${v:="$p"}" "$v"'		'2|/et[c]/|/et[c]/'

test "x$failures" = x
EOF
put fbsd/expansion/cmdsubst1.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$(echo abcde)" = "abcde"'
check '"$(echo abcde; :)" = "abcde"'

check '"$(printf abcde)" = "abcde"'
check '"$(printf abcde; :)" = "abcde"'

# regular
check '-n "$(umask)"'
check '-n "$(umask; :)"'
check '-n "$(umask 2>&1)"'
check '-n "$(umask 2>&1; :)"'

# special
check '-n "$(times)"'
check '-n "$(times; :)"'
check '-n "$(times 2>&1)"'
check '-n "$(times 2>&1; :)"'

# regular
check '".$(umask -@ 2>&1)." = ".umask: Illegal option -@."'
check '".$(umask -@ 2>&1; :)." = ".umask: Illegal option -@."'
check '".$({ umask -@; } 2>&1)." = ".umask: Illegal option -@."'

# special
check '".$(shift xyz 2>&1)." = ".shift: Illegal number: xyz."'
check '".$(shift xyz 2>&1; :)." = ".shift: Illegal number: xyz."'
check '".$({ shift xyz; } 2>&1)." = ".shift: Illegal number: xyz."'

v=1
check '-z "$(v=2 :)"'
check '"$v" = 1'
check '-z "$(v=3)"'
check '"$v" = 1'
check '"$(v=4 eval echo \$v)" = 4'
check '"$v" = 1'

exit $((failures > 0))
EOF
put fbsd/expansion/cmdsubst10.0 <<'EOF'

a1=$(alias)
: $(alias testalias=abcd)
a2=$(alias)
[ "$a1" = "$a2" ] || echo Error at line $LINENO

alias testalias2=abcd
a1=$(alias)
: $(unalias testalias2)
a2=$(alias)
[ "$a1" = "$a2" ] || echo Error at line $LINENO

[ "$(command -V pwd)" = "$(command -V pwd; exit $?)" ] || echo Error at line $LINENO

v=1
: $(export v=2)
[ "$v" = 1 ] || echo Error at line $LINENO

rotest=1
: $(readonly rotest=2)
[ "$rotest" = 1 ] || echo Error at line $LINENO

set +u
: $(set -u)
case $- in
*u*) echo Error at line $LINENO ;;
esac
set +u

set +u
: $(set -o nounset)
case $- in
*u*) echo Error at line $LINENO ;;
esac
set +u

set +u
: $(command set -u)
case $- in
*u*) echo Error at line $LINENO ;;
esac
set +u

umask 77
u1=$(umask)
: $(umask 022)
u2=$(umask)
[ "$u1" = "$u2" ] || echo Error at line $LINENO

dummy=$(exit 3); [ $? -eq 3 ] || echo Error at line $LINENO
EOF
put fbsd/expansion/cmdsubst11.0 <<'EOF'

# Not required by POSIX but useful for efficiency.

[ $$ = $(eval '${SH} -c echo\ \$PPID') ]
EOF
put fbsd/expansion/cmdsubst12.0 <<'EOF'

f() {
	echo x$(printf foo >&2)y
}
[ "$(f 2>&1)" = "fooxy" ]
EOF
put fbsd/expansion/cmdsubst13.0 <<'EOF'

x=1 y=2
[ "$(
	case $((x+=1)) in
	($((y+=1)))	echo bad1 ;;
	($((y-1)))	echo $x.$y ;;
	($((y=2)))	echo bad2 ;;
	(*)		echo bad3 ;;
	esac
)" = "2.3" ] || echo "Error at $LINENO"
[ "$x.$y" = "1.2" ] || echo "Error at $LINENO"
EOF
put fbsd/expansion/cmdsubst14.0 <<'EOF'

! v=`false

`
EOF
put fbsd/expansion/cmdsubst15.0 <<'EOF'

! v=`false;

`
EOF
put fbsd/expansion/cmdsubst16.0 <<'EOF'

f() { return 3; }
f
[ `echo $?` = 3 ]
EOF
put fbsd/expansion/cmdsubst17.0 <<'EOF'

f() { return 3; }
f
[ `echo $?; :` = 3 ]
EOF
put fbsd/expansion/cmdsubst18.0 <<'EOF'

x=X
unset n
r=${x+$(echo a)}${x-$(echo b)}${n+$(echo c)}${n-$(echo d)}$(echo e)
[ "$r" = aXde ]
EOF
put fbsd/expansion/cmdsubst19.0 <<'EOF'

b=200 c=30 d=5 x=4
r=$(echo a)$(($(echo b) + ${x+$(echo c)} + ${x-$(echo d)}))$(echo e)
[ "$r" = a234e ]
EOF
put fbsd/expansion/cmdsubst2.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '`echo /et[c]/` = "/etc/"'
check '`printf /var/empty%s /et[c]/` = "/var/empty/etc/"'
check '"`echo /et[c]/`" = "/etc/"'
check '`echo "/et[c]/"` = "/etc/"'
check '`printf /var/empty%s "/et[c]/"` = "/var/empty/et[c]/"'
check '`printf /var/empty/%s \"/et[c]/\"` = "/var/empty/\"/et[c]/\""'
check '"`echo \"/et[c]/\"`" = "/et[c]/"'
check '"`echo "/et[c]/"`" = "/et[c]/"'
check '`echo $$` = $$'
check '"`echo $$`" = $$'
check '`echo \$\$` = $$'
check '"`echo \$\$`" = $$'

# Command substitutions consisting of a single builtin may be treated
# differently.
check '`:; echo /et[c]/` = "/etc/"'
check '`:; printf /var/empty%s /et[c]/` = "/var/empty/etc/"'
check '"`:; echo /et[c]/`" = "/etc/"'
check '`:; echo "/et[c]/"` = "/etc/"'
check '`:; printf /var/empty%s "/et[c]/"` = "/var/empty/et[c]/"'
check '`:; printf /var/empty/%s \"/et[c]/\"` = "/var/empty/\"/et[c]/\""'
check '"`:; echo \"/et[c]/\"`" = "/et[c]/"'
check '"`:; echo "/et[c]/"`" = "/et[c]/"'
check '`:; echo $$` = $$'
check '"`:; echo $$`" = $$'
check '`:; echo \$\$` = $$'
check '"`:; echo \$\$`" = $$'

check '`set -f; echo /et[c]/` = "/etc/"'
check '"`set -f; echo /et[c]/`" = "/et[c]/"'

exit $((failures > 0))
EOF
put fbsd/expansion/cmdsubst20.0 <<'EOF'

set -T
trapped=''
trap "trapped=x$trapped" USR1
[ "x$(kill -USR1 $$)y" = xy ] && [ "$trapped" = x ]
EOF
put fbsd/expansion/cmdsubst21.0 <<'EOF'

set -T
trapped=''
trap "trapped=x$trapped" TERM
[ "x$($SH -c "kill $$")y" = xy ] && [ "$trapped" = x ]
EOF
put fbsd/expansion/cmdsubst22.0 <<'EOF'

set -T
trapped=''
trap "trapped=x$trapped" TERM
[ "x$(:; kill $$)y" = xy ] && [ "$trapped" = x ]
EOF
put fbsd/expansion/cmdsubst23.0 <<'EOF'

unset n
x=abcd
[ "X${n#$(echo a)}X${x#$(echo ab)}X$(echo abc)X" = XXcdXabcX ]
EOF
put fbsd/expansion/cmdsubst24.0 <<'EOF'
# POSIX leaves the effect of NUL bytes in command substitution output
# unspecified but we have always discarded them.

failures=0

check() {
	if [ "$2" != "$3" ]; then
		printf "Failed at line %s: got \"%s\" expected \"%s\"\n" "$1" "$2" "$3"
		: $((failures += 1))
	fi
}

fmt='\0a\0 \0b\0c d\0'
assign_builtin=$(printf "$fmt")
check "$LINENO" "$assign_builtin" "a bc d"
assign_pipeline=$(printf "$fmt" | cat)
check "$LINENO" "$assign_pipeline" "a bc d"
set -- $(printf "$fmt") $(printf "$fmt" | cat) "$(printf "$fmt")" "$(printf "$fmt" | cat)" 
IFS=@
splits="$*"
check "$LINENO" "$splits" "a@bc@d@a@bc@d@a bc d@a bc d"

[ "$failures" = 0 ]
EOF
put fbsd/expansion/cmdsubst25.0 <<'EOF'

IFS=' '
set -- `printf '\n '`
IFS=:
[ "$*" = '
' ]
EOF
put fbsd/expansion/cmdsubst26.0 <<'EOF'

nl='
'
v=$nl`printf '\n'`
[ "$v" = "$nl" ]
EOF
put fbsd/expansion/cmdsubst3.0 <<'EOF'

unset LC_ALL
export LC_CTYPE=en_US.ISO8859-1

e=
for i in 0 1 2 3; do
	for j in 0 1 2 3 4 5 6 7; do
		for k in 0 1 2 3 4 5 6 7; do
			case $i$j$k in
			000) continue ;;
			esac
			e="$e\n\\$i$j$k"
		done
	done
done
e1=$(printf "$e")
e2="$(printf "$e")"
[ "${#e1}" = 510 ] || echo length bad
[ "$e1" = "$e2" ] || echo e1 != e2
[ "$e1" = "$(printf "$e")" ] || echo quoted bad
IFS=
[ "$e1" = $(printf "$e") ] || echo unquoted bad
EOF
put fbsd/expansion/cmdsubst4.0 <<'EOF'

exec 2>/dev/null
! y=$(: </var/empty/nonexistent)
EOF
put fbsd/expansion/cmdsubst5.0 <<'EOF'

unset v
exec 2>/dev/null
! y=$(: ${v?})
EOF
put fbsd/expansion/cmdsubst6.0 <<'EOF'
# This tests if the cmdsubst optimization is still used if possible.

failures=''
ok=''

testcase() {
	code="$1"

	unset v
	eval "pid=\$(dummy=$code echo \$(\$SH -c echo\ \\\$PPID))"

	if [ "$pid" = "$$" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "Failure for $code"
	fi
}

unset v
w=1
testcase '$w'
testcase '1${w+1}'
testcase '1${w-1}'
testcase '1${v+1}'
testcase '1${v-1}'
testcase '1${w:+1}'
testcase '1${w:-1}'
testcase '1${v:+1}'
testcase '1${v:-1}'
testcase '${w?}'
testcase '${w:?}'
testcase '${w#x}'
testcase '${w##x}'
testcase '${w%x}'
testcase '${w%%x}'

testcase '$((w))'
testcase '$(((w+4)*2/3))'
testcase '$((w==1))'
testcase '$((w>=0 && w<=5 && w!=2))'
testcase '$((${#w}))'
testcase '$((${#IFS}))'
testcase '$((${#w}>=1))'
testcase '$(($$))'
testcase '$(($#))'
testcase '$(($?))'

testcase '$(: $((w=4)))'
testcase '$(: ${v=2})'

test "x$failures" = x
EOF
put fbsd/expansion/cmdsubst7.0 <<'EOF'

failures=''
ok=''

testcase() {
	code="$1"

	unset v
	eval ": \$($code)"

	if [ "${v:+bad}" = "" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "Failure for $code"
	fi
}

testcase ': ${v=0}'
testcase ': ${v:=0}'
testcase ': $((v=1))'
testcase ': $((v+=1))'
w='v=1'
testcase ': $(($w))'
testcase ': $((${$+v=1}))'
testcase ': $((v${$+=1}))'
testcase ': $((v $(echo =) 1))'
testcase ': $(($(echo $w)))'

test "x$failures" = x
EOF
put fbsd/expansion/cmdsubst8.0 <<'EOF'
# Not required by POSIX (although referenced in a non-normative section),
# but possibly useful.

: hi there &
p=$!
q=$(jobs -l $p)

# Change tabs to spaces.
set -f
set -- $q
r="$*"

case $r in
*" $p "*) ;;
*) echo Pid missing; exit 3 ;;
esac
EOF
put fbsd/expansion/cmdsubst9.0 <<'EOF'

set -e

cd /
dummy=$(cd /bin)
[ "$(pwd)" = / ]

v=1
dummy=$(eval v=2)
[ "$v" = 1 ]
EOF
put fbsd/expansion/export1.0 <<'EOF'

w='@ vv=6'

v=0 vv=0
export \v=$w
[ "$v" = "@" ] || echo "Expected @ got $v"
[ "$vv" = "6" ] || echo "Expected 6 got $vv"

HOME=/known/value

export \v=~
[ "$v" = \~ ] || echo "Expected ~ got $v"
EOF
put fbsd/expansion/export2.0 <<'EOF'

w='@ @'
check() {
	[ "$v" = "$w" ] || echo "Expected $w got $v"
}

export v=$w
check

HOME=/known/value
check() {
	[ "$v" = ~ ] || echo "Expected $HOME got $v"
}

export v=~
check

check() {
	[ "$v" = "x:$HOME" ] || echo "Expected x:$HOME got $v"
}

export v=x:~
check
EOF
put fbsd/expansion/export3.0 <<'EOF'

w='@ @'
check() {
	[ "$v" = "$w" ] || echo "Expected $w got $v"
}

command export v=$w
check
command command export v=$w
check

HOME=/known/value
check() {
	[ "$v" = ~ ] || echo "Expected $HOME got $v"
}

command export v=~
check
command command export v=~
check

check() {
	[ "$v" = "x:$HOME" ] || echo "Expected x:$HOME got $v"
}

command export v=x:~
check
command command export v=x:~
check
EOF
put fbsd/expansion/heredoc1.0 <<'EOF1'

f() { return $1; }

[ `f 42; { cat; } <<EOF
$?
EOF
` = 42 ] || echo compound command bad

[ `f 42; (cat) <<EOF
$?
EOF
` = 42 ] || echo subshell bad

long=`printf %08192d 0`

[ `f 42; { cat; } <<EOF
$long.$?
EOF
` = $long.42 ] || echo long compound command bad

[ `f 42; (cat) <<EOF
$long.$?
EOF
` = $long.42 ] || echo long subshell bad
EOF1
put fbsd/expansion/heredoc2.0 <<'EOF1'

f() { return $1; }

[ `f 42; cat <<EOF
$?
EOF
` = 42 ] || echo simple command bad

long=`printf %08192d 0`

[ `f 42; cat <<EOF
$long.$?
EOF
` = $long.42 ] || echo long simple command bad
EOF1
put fbsd/expansion/ifs1.0 <<'EOF'

c=: e= s=' '
failures=''
ok=''

check_result() {
	if [ "x$2" = "x$3" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $1, expected $3 actual $2"
	fi
}

IFS=' 	
'
set -- a ''
set -- "$@"
check_result 'set -- "$@"' "($#)($1)($2)" "(2)(a)()"

set -- a ''
set -- "$@"$e
check_result 'set -- "$@"$e' "($#)($1)($2)" "(2)(a)()"

set -- a ''
set -- "$@"$s
check_result 'set -- "$@"$s' "($#)($1)($2)" "(2)(a)()"

IFS="$c"
set -- a ''
set -- "$@"$c
check_result 'set -- "$@"$c' "($#)($1)($2)" "(2)(a)()"

test "x$failures" = x
EOF
put fbsd/expansion/ifs2.0 <<'EOF'

failures=0
i=1
set -f
while [ "$i" -le 127 ]; do
	# A different byte still in the range 1..127.
	i2=$((i^2+(i==2)))
	# Add a character to work around command substitution's removal of
	# final newlines, then remove it again.
	c=$(printf \\"$(printf %o@ "$i")")
	c=${c%@}
	c2=$(printf \\"$(printf %o@ "$i2")")
	c2=${c2%@}
	IFS=$c
	set -- $c2$c$c2$c$c2
	if [ "$#" -ne 3 ] || [ "$1" != "$c2" ] || [ "$2" != "$c2" ] ||
	    [ "$3" != "$c2" ]; then
		echo "Bad results for separator $i (word $i2)" >&2
		: $((failures += 1))
	fi
	i=$((i+1))
done
exit $((failures > 0))
EOF
put fbsd/expansion/ifs3.0 <<'EOF'

failures=0
unset LC_ALL
export LC_CTYPE=en_US.ISO8859-1
i=128
set -f
while [ "$i" -le 255 ]; do
	i2=$((i^2))
	c=$(printf \\"$(printf %o "$i")")
	c2=$(printf \\"$(printf %o "$i2")")
	IFS=$c
	set -- $c2$c$c2$c$c2
	if [ "$#" -ne 3 ] || [ "$1" != "$c2" ] || [ "$2" != "$c2" ] ||
	    [ "$3" != "$c2" ]; then
		echo "Bad results for separator $i (word $i2)" >&2
		: $((failures += 1))
	fi
	i=$((i+1))
done
exit $((failures > 0))
EOF
put fbsd/expansion/ifs4.0 <<'EOF'

c=: e= s=' '
failures=''
ok=''

check_result() {
	if [ "x$2" = "x$3" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $1, expected $3 actual $2"
	fi
}

IFS=' 	
'
set -- a b '' c
set -- $@
check_result 'set -- $@' "($#)($1)($2)($3)($4)" "(3)(a)(b)(c)()"

IFS=''
set -- a b '' c
set -- $@
check_result 'set -- $@' "($#)($1)($2)($3)($4)" "(3)(a)(b)(c)()"

set -- a b '' c
set -- $*
check_result 'set -- $*' "($#)($1)($2)($3)($4)" "(3)(a)(b)(c)()"

set -- a b '' c
set -- "$@"
check_result 'set -- "$@"' "($#)($1)($2)($3)($4)" "(4)(a)(b)()(c)"

set -- a b '' c
set -- "$*"
check_result 'set -- "$*"' "($#)($1)($2)($3)($4)" "(1)(abc)()()()"

test "x$failures" = x
EOF
put fbsd/expansion/ifs5.0 <<'EOF'

set -- $(echo a b c d)
[ "$#" = 4 ]
EOF
put fbsd/expansion/ifs6.0 <<'EOF'

IFS=': '
x=': :'
set -- $x
[ "$#|$1|$2|$3" = "2|||" ]
EOF
put fbsd/expansion/ifs7.0 <<'EOF'

IFS=2
set -- $((123))
[ "$#|$1|$2|$3" = "2|1|3|" ]
EOF
put fbsd/expansion/length1.0 <<'EOF'

v=abcd
[ "${#v}" = 4 ] || echo '${#v} wrong'
v=$$
[ "${#$}" = "${#v}" ] || echo '${#$} wrong'
[ "${#!}" = 0 ] || echo '${#!} wrong'
set -- 01 2 3 4 5 6 7 8 9 10 11 12 0013
[ "${#1}" = 2 ] || echo '${#1} wrong'
[ "${#13}" = 4 ] || echo '${#13} wrong'
v=$0
[ "${#0}" = "${#v}" ] || echo '${#0} wrong'
EOF
put fbsd/expansion/length2.0 <<'EOF'

v=$-
[ "${#-}" = "${#v}" ] || echo '${#-} wrong'
EOF
put fbsd/expansion/length3.0 <<'EOF'

set -- 1 2 3 4 5 6 7 8 9 10 11 12 13
[ "$#" = 13 ] || echo '$# wrong'
[ "${#}" = 13 ] || echo '${#} wrong'
[ "${##}" = 2 ] || echo '${##} wrong'
set --
[ "$#" = 0 ] || echo '$# wrong'
[ "${#}" = 0 ] || echo '${#} wrong'
[ "${##}" = 1 ] || echo '${##} wrong'
EOF
put fbsd/expansion/length4.0 <<'EOF'

# The construct ${#?} is ambiguous in POSIX.1-2008: it could be the length
# of $? or it could be $# giving an error in the (impossible) case that it
# is not set.
# We use the former interpretation; it seems more useful.

:
[ "${#?}" = 1 ] || echo '${#?} wrong'
(exit 42)
[ "${#?}" = 2 ] || echo '${#?} wrong'
EOF
put fbsd/expansion/length5.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.ISO8859-1
export LC_CTYPE

e=
for i in 0 1 2 3; do
	for j in 0 1 2 3 4 5 6 7; do
		for k in 0 1 2 3 4 5 6 7; do
			case $i$j$k in
			000) continue ;;
			esac
			e="$e\\$i$j$k"
		done
	done
done
ee=`printf "$e"`
[ ${#ee} = 255 ] || echo bad 1
[ "${#ee}" = 255 ] || echo bad 2
[ $((${#ee})) = 255 ] || echo bad 3
[ "$((${#ee}))" = 255 ] || echo bad 4
set -- "$ee"
[ ${#1} = 255 ] || echo bad 5
[ "${#1}" = 255 ] || echo bad 6
[ $((${#1})) = 255 ] || echo bad 7
[ "$((${#1}))" = 255 ] || echo bad 8
EOF
put fbsd/expansion/length6.0 <<'EOF'

x='!@#$%^&*()[]'
[ ${#x} = 12 ] || echo bad 1
[ "${#x}" = 12 ] || echo bad 2
IFS=2
[ ${#x} = 1 ] || echo bad 3
[ "${#x}" = 12 ] || echo bad 4
EOF
put fbsd/expansion/length7.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.UTF-8
export LC_CTYPE

# a umlaut
s=$(printf '\303\244')
# euro sign
s=$s$(printf '\342\202\254')
# some sort of 't' outside BMP
s=$s$(printf '\360\235\225\245')
set -- "$s"
[ ${#s} = 3 ] && [ ${#1} = 3 ]
EOF
put fbsd/expansion/length8.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.ISO8859-1
export LC_CTYPE

# a umlaut
s=$(printf '\303\244')
# euro sign
s=$s$(printf '\342\202\254')
# some sort of 't' outside BMP
s=$s$(printf '\360\235\225\245')
set -- "$s"
[ ${#s} = 9 ] && [ ${#1} = 9 ]
EOF
put fbsd/expansion/local1.0 <<'EOF'

run_test() {
	w='@ @'
	check() {
		[ "$v" = "$w" ] || echo "Expected $w got $v"
	}

	local v=$w
	check

	HOME=/known/value
	check() {
		[ "$v" = ~ ] || echo "Expected $HOME got $v"
	}

	local v=~
	check

	check() {
		[ "$v" = "x:$HOME" ] || echo "Expected x:$HOME got $v"
	}

	local v=x:~
	check
}

run_test
EOF
put fbsd/expansion/local2.0 <<'EOF'

run_test() {
	w='@ @'
	check() {
		[ "$v" = "$w" ] || echo "Expected $w got $v"
	}

	command local v=$w
	check
	command command local v=$w
	check

	HOME=/known/value
	check() {
		[ "$v" = ~ ] || echo "Expected $HOME got $v"
	}

	command local v=~
	check
	command command local v=~
	check

	check() {
		[ "$v" = "x:$HOME" ] || echo "Expected x:$HOME got $v"
	}

	command local v=x:~
	check
	command command local v=x:~
	check
}

run_test
EOF
put fbsd/expansion/pathname1.0 <<'EOF'

unset LC_ALL
LC_COLLATE=C
export LC_COLLATE

failures=0

check() {
	testcase=$1
	expect=$2
	eval "set -- $testcase"
	actual="$*"
	if [ "$actual" != "$expect" ]; then
		failures=$((failures+1))
		printf '%s\n' "For $testcase, expected $expect actual $actual"
	fi
}

set -e
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd -P $T

mkdir testdir testdir2 'testdir/*' 'testdir/?' testdir/a testdir/b testdir2/b
mkdir testdir2/.c
touch testf 'testdir/*/1' 'testdir/?/1' testdir/a/1 testdir/b/1 testdir2/b/.a

check '' ''
check 'testdir/b' 'testdir/b'
check 'testdir/c' 'testdir/c'
check '\*' '*'
check '\?' '?'
check '*' 'testdir testdir2 testf'
check '*""' 'testdir testdir2 testf'
check '""*' 'testdir testdir2 testf'
check '*/' 'testdir/ testdir2/'
check 'testdir*/a' 'testdir/a'
check 'testdir*/b' 'testdir/b testdir2/b'
check '*/.c' 'testdir2/.c'
check 'testdir2/*' 'testdir2/b'
check 'testdir2/b/*' 'testdir2/b/*'
check 'testdir/*' 'testdir/* testdir/? testdir/a testdir/b'
check 'testdir/*/1' 'testdir/*/1 testdir/?/1 testdir/a/1 testdir/b/1'
check '"testdir/"*/1' 'testdir/*/1 testdir/?/1 testdir/a/1 testdir/b/1'
check 'testdir/\*/*' 'testdir/*/1'
check 'testdir/\?/*' 'testdir/?/1'
check 'testdir/"?"/*' 'testdir/?/1'
check '"testdir"/"?"/*' 'testdir/?/1'
check '"testdir"/"?"*/*' 'testdir/?/1'
check '"testdir"/*"?"/*' 'testdir/?/1'
check '"testdir/?"*/*' 'testdir/?/1'
check 'testdir/\*/' 'testdir/*/'
check 'testdir/\?/' 'testdir/?/'
check 'testdir/"?"/' 'testdir/?/'
check '"testdir"/"?"/' 'testdir/?/'
check '"testdir"/"?"*/' 'testdir/?/'
check '"testdir"/*"?"/' 'testdir/?/'
check '"testdir/?"*/' 'testdir/?/'
check 'testdir/[*]/' 'testdir/*/'
check 'testdir/[?]/' 'testdir/?/'
check 'testdir/[*?]/' 'testdir/*/ testdir/?/'
check '[tz]estdir/[*]/' 'testdir/*/'

exit $((failures != 0))
EOF
put fbsd/expansion/pathname2.0 <<'EOF'

unset LC_ALL
LC_COLLATE=C
export LC_COLLATE

failures=0

check() {
	testcase=$1
	expect=$2
	eval "set -- $testcase"
	actual="$*"
	if [ "$actual" != "$expect" ]; then
		failures=$((failures+1))
		printf '%s\n' "For $testcase, expected $expect actual $actual"
	fi
}

set -e
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd -P $T

mkdir testdir testdir2 'testdir/*' 'testdir/?' testdir/a testdir/b testdir2/b
mkdir testdir2/.c
touch testf 'testdir/*/1' 'testdir/?/1' testdir/a/1 testdir/b/1 testdir2/b/.a

check '*\/' 'testdir/ testdir2/'
check '"testdir/"*"/1"' 'testdir/*/1 testdir/?/1 testdir/a/1 testdir/b/1'
check '"testdir/"*"/"*' 'testdir/*/1 testdir/?/1 testdir/a/1 testdir/b/1'
check '"testdir/"*\/*' 'testdir/*/1 testdir/?/1 testdir/a/1 testdir/b/1'
check '"testdir"*"/"*"/"*' 'testdir/*/1 testdir/?/1 testdir/a/1 testdir/b/1'

exit $((failures != 0))
EOF
put fbsd/expansion/pathname3.0 <<'EOF'

v=12345678
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
v=$v$v$v$v
# 8192 bytes
v=${v##???}
[ /*/$v = "/*/$v" ] || exit 1

s=////
s=$s$s$s$s
s=$s$s$s$s
s=$s$s$s$s
s=$s$s$s$s
# 1024 bytes
s=${s##??????????}
[ /var/empt[y]/$s/$v = "/var/empt[y]/$s/$v" ] || exit 2
while [ ${#s} -lt 1034 ]; do
	set -- /.${s}et[c]
	[ ${#s} -gt 1018 ] || [ "$1" = /.${s}etc ] || exit 3
	set -- /.${s}et[c]/
	[ ${#s} -gt 1017 ] || [ "$1" = /.${s}etc/ ] || exit 4
	set -- /.${s}et[c]/.
	[ ${#s} -gt 1016 ] || [ "$1" = /.${s}etc/. ] || exit 5
	s=$s/
done
EOF
put fbsd/expansion/pathname4.0 <<'EOF'

failures=0

check() {
	testcase=$1
	expect=$2
	eval "set -- $testcase"
	actual="$*"
	if [ "$actual" != "$expect" ]; then
		failures=$((failures+1))
		printf '%s\n' "For $testcase, expected $expect actual $actual"
	fi
}

set -e
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd -P $T

mkdir !!a
touch !!a/fff

chmod u-r .
check '!!a/ff*' '!!a/fff'
chmod u+r .

exit $((failures != 0))
EOF
put fbsd/expansion/pathname5.0 <<'EOF'

[ `echo '/[e]tc'` = /etc ]
EOF
put fbsd/expansion/pathname6.0 <<'EOF'

unset LC_ALL
LC_COLLATE=en_US.US-ASCII
export LC_COLLATE

failures=0

check() {
	testcase=$1
	expect=$2
	eval "set -- $testcase"
	actual="$*"
	if [ "$actual" != "$expect" ]; then
		failures=$((failures+1))
		printf '%s\n' "For $testcase, expected $expect actual $actual"
	fi
}

set -e
T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd -P $T

touch A B a b

check '*' 'a A b B'

exit $((failures != 0))
EOF
put fbsd/expansion/plus-minus1.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- a b'				'2|a|b'
testcase 'set --'				'0|'
testcase 'set -- ${e}'				'0|'
testcase 'set -- "${e}"'			'1|'

testcase 'set -- $p'				'1|/etc/'
testcase 'set -- "$p"'				'1|/et[c]/'
testcase 'set -- ${s+$p}'			'1|/etc/'
testcase 'set -- "${s+$p}"'			'1|/et[c]/'
testcase 'set -- ${s+"$p"}'			'1|/et[c]/'
# Dquotes in dquotes is undefined for Bourne shell operators
#testcase 'set -- "${s+"$p"}"'			'1|/et[c]/'
testcase 'set -- ${e:-$p}'			'1|/etc/'
testcase 'set -- "${e:-$p}"'			'1|/et[c]/'
testcase 'set -- ${e:-"$p"}'			'1|/et[c]/'
# Dquotes in dquotes is undefined for Bourne shell operators
#testcase 'set -- "${e:-"$p"}"'			'1|/et[c]/'
testcase 'set -- ${e:+"$e"}'			'0|'
testcase 'set -- ${e:+$w"$e"}'			'0|'
testcase 'set -- ${w:+"$w"}'			'1|a b c'
testcase 'set -- ${w:+$w"$w"}'			'3|a|b|ca b c'

testcase 'set -- "${s+a b}"'			'1|a b'
testcase 'set -- "${e:-a b}"'			'1|a b'
testcase 'set -- ${e:-\}}'			'1|}'
testcase 'set -- ${e:+{}}'			'1|}'
testcase 'set -- "${e:+{}}"'			'1|}'

testcase 'set -- ${e+x}${e+x}'			'1|xx'
testcase 'set -- "${e+x}"${e+x}'		'1|xx'
testcase 'set -- ${e+x}"${e+x}"'		'1|xx'
testcase 'set -- "${e+x}${e+x}"'		'1|xx'
testcase 'set -- "${e+x}""${e+x}"'		'1|xx'

testcase 'set -- ${e:-${e:-$p}}'		'1|/etc/'
testcase 'set -- "${e:-${e:-$p}}"'		'1|/et[c]/'
testcase 'set -- ${e:-"${e:-$p}"}'		'1|/et[c]/'
testcase 'set -- ${e:-${e:-"$p"}}'		'1|/et[c]/'
testcase 'set -- ${e:-${e:-${e:-$w}}}'		'3|a|b|c'
testcase 'set -- ${e:-${e:-${e:-"$w"}}}'	'1|a b c'
testcase 'set -- ${e:-${e:-"${e:-$w}"}}'	'1|a b c'
testcase 'set -- ${e:-"${e:-${e:-$w}}"}'	'1|a b c'
testcase 'set -- "${e:-${e:-${e:-$w}}}"'	'1|a b c'

testcase 'shift $#; set -- ${1+"$@"}'		'0|'
testcase 'set -- ""; set -- ${1+"$@"}'		'1|'
testcase 'set -- "" a; set -- ${1+"$@"}'	'2||a'
testcase 'set -- a ""; set -- ${1+"$@"}'	'2|a|'
testcase 'set -- a b; set -- ${1+"$@"}'		'2|a|b'
testcase 'set -- a\ b; set -- ${1+"$@"}'	'1|a b'
testcase 'set -- " " ""; set -- ${1+"$@"}'	'2| |'

test "x$failures" = x
EOF
put fbsd/expansion/plus-minus2.0 <<'EOF'

e=
test "${e:-\}}" = '}'
EOF
put fbsd/expansion/plus-minus3.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

# We follow original ash behaviour for quoted ${var+-=?} expansions:
# a double-quote in one switches back to unquoted state.
# This allows expanding a variable as a single word if it is set
# and substituting multiple words otherwise.
# It is also close to the Bourne and Korn shells.
# POSIX leaves this undefined, and various other shells treat
# such double-quotes as introducing a second level of quoting
# which does not do much except quoting close braces.

testcase 'set -- "${p+"/et[c]/"}"'		'1|/etc/'
testcase 'set -- "${p-"/et[c]/"}"'		'1|/et[c]/'
testcase 'set -- "${p+"$p"}"'			'1|/etc/'
testcase 'set -- "${p-"$p"}"'			'1|/et[c]/'
testcase 'set -- "${p+"""/et[c]/"}"'		'1|/etc/'
testcase 'set -- "${p-"""/et[c]/"}"'		'1|/et[c]/'
testcase 'set -- "${p+"""$p"}"'			'1|/etc/'
testcase 'set -- "${p-"""$p"}"'			'1|/et[c]/'
testcase 'set -- "${p+"\@"}"'			'1|@'
testcase 'set -- "${p+"'\''/et[c]/'\''"}"'	'1|/et[c]/'

test "x$failures" = x
EOF
put fbsd/expansion/plus-minus4.0 <<'EOF'

# These may be a bit unclear in the POSIX spec or the proposed revisions,
# and conflict with bash's interpretation, but I think ksh93's interpretation
# makes most sense. In particular, it makes no sense to me that single-quotes
# must match but are not removed.

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- ${e:-'"'"'}'"'"'}'		'1|}'
testcase "set -- \${e:-\\'}"			"1|'"
testcase "set -- \${e:-\\'\\'}"			"1|''"
testcase "set -- \"\${e:-'}\""			"1|'"
testcase "set -- \"\${e:-'}'}\""		"1|''}"
testcase "set -- \"\${e:-''}\""			"1|''"
testcase 'set -- ${e:-\a}'			'1|a'
testcase 'set -- "${e:-\a}"'			'1|\a'

test "x$failures" = x
EOF
put fbsd/expansion/plus-minus5.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- ${e:-"{x}"}'			'1|{x}'
testcase 'set -- "${e:-"{x}"}"'			'1|{x}'
testcase 'set -- ${h+"{x}"}'			'1|{x}'
testcase 'set -- "${h+"{x}"}"'			'1|{x}'
testcase 'set -- ${h:-"{x}"}'			'1|##'
testcase 'set -- "${h:-"{x}"}"'			'1|##'

test "x$failures" = x
EOF
put fbsd/expansion/plus-minus6.0 <<'EOF'

failures=0
unset LC_ALL
export LC_CTYPE=en_US.ISO8859-1
nl='
'
i=1
set -f
while [ "$i" -le 255 ]; do
	# A different byte still in the range 1..255.
	i2=$((i^2+(i==2)))
	# Add a character to work around command substitution's removal of
	# final newlines, then remove it again.
	c=$(printf \\"$(printf %o@ "$i")")
	c=${c%@}
	c2=$(printf \\"$(printf %o@ "$i2")")
	c2=${c2%@}
	case $c in
		[\'$nl'$}();&|\"`']) c=M
	esac
	case $c2 in
		[\'$nl'$}();&|\"`']) c2=N
	esac
	IFS=$c
	command eval "set -- \${\$+$c2$c$c2$c$c2}"
	if [ "$#" -ne 3 ] || [ "$1" != "$c2" ] || [ "$2" != "$c2" ] ||
	    [ "$3" != "$c2" ]; then
		echo "Bad results for separator $i (word $i2)" >&2
		: $((failures += 1))
	fi
	i=$((i+1))
done
exit $((failures > 0))
EOF
put fbsd/expansion/plus-minus7.0 <<'EOF'

e= s='foo'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- ${s+a b}'			'2|a|b'
testcase 'set -- ${e:-a b}'			'2|a|b'

test "x$failures" = x
EOF
put fbsd/expansion/plus-minus8.0 <<'EOF'

set -- 1 2 3 4 5 6 7 8 9 10 11 12 13
[ "${#+hi}" = hi ] || echo '${#+hi} wrong'
[ "${#-hi}" = 13 ] || echo '${#-hi} wrong'
EOF
put fbsd/expansion/plus-minus9.0 <<'EOF'

a=1
b=${a+
}
n='
'
[ "$b" = "$n" ]
EOF
put fbsd/expansion/question1.0 <<'EOF'

x=a\ b
[ "$x" = "${x?}" ] || exit 1
set -- ${x?}
{ [ "$#" = 2 ] && [ "$1" = a ] && [ "$2" = b ]; } || exit 1
unset x
(echo ${x?abcdefg}) 2>&1 | grep -q abcdefg || exit 1
${SH} -c 'unset foo; echo ${foo?}' 2>/dev/null && exit 1
${SH} -c 'foo=; echo ${foo:?}' 2>/dev/null && exit 1
${SH} -c 'foo=; echo ${foo?}' >/dev/null || exit 1
${SH} -c 'foo=1; echo ${foo:?}' >/dev/null || exit 1
${SH} -c 'echo ${!?}' 2>/dev/null && exit 1
${SH} -c ':& echo ${!?}' >/dev/null || exit 1
${SH} -c 'echo ${#?}' >/dev/null || exit 1
${SH} -c 'echo ${*?}' 2>/dev/null && exit 1
${SH} -c 'echo ${*?}' ${SH} x >/dev/null || exit 1
${SH} -c 'echo ${1?}' 2>/dev/null && exit 1
${SH} -c 'echo ${1?}' ${SH} x >/dev/null || exit 1
${SH} -c 'echo ${2?}' ${SH} x 2>/dev/null && exit 1
${SH} -c 'echo ${2?}' ${SH} x y >/dev/null || exit 1
exit 0
EOF
put fbsd/expansion/question2.0 <<'EOF'

unset dummyvar
msg=`(: ${dummyvar?}) 2>&1`
r=$?
[ "$r" != 0 ] && case $msg in
*dummyvar?* | *?dummyvar*) : ;;
*)
	printf 'Bad message: [%s]\n' "$msg"
	exit 1
esac
EOF
put fbsd/expansion/readonly1.0 <<'EOF'

w='@ @'

v=0 HOME=/known/value
readonly v=~:~/:$w
[ "$v" = "$HOME:$HOME/:$w" ] || echo "Expected $HOME/:$w got $v"
EOF
put fbsd/expansion/redir1.0 <<'EOF'

bad=0
for i in 0 1 2 3; do
	for j in 0 1 2 3 4 5 6 7; do
		for k in 0 1 2 3 4 5 6 7; do
			case $i$j$k in
			000) continue ;;
			esac
			set -- "$(printf \\$i$j$k@)"
			set -- "${1%@}"
			ff=
			for f in /dev/null /dev/zero /; do
				if [ -e "$f" ] && [ ! -e "$f$1" ]; then
					ff=$f
				fi
			done
			[ -n "$ff" ] || continue
			if { true <$ff$1; } 2>/dev/null; then
				echo "Bad: $i$j$k ($ff)" >&2
				: $((bad += 1))
			fi
		done
	done
done
exit $((bad ? 2 : 0))
EOF
put fbsd/expansion/set-u1.0 <<'EOF'

${SH} -uc 'unset foo; echo $foo' 2>/dev/null && exit 1
${SH} -uc 'foo=; echo $foo' >/dev/null || exit 1
${SH} -uc 'foo=1; echo $foo' >/dev/null || exit 1
# -/+/= are unaffected by set -u
${SH} -uc 'unset foo; echo ${foo-}' >/dev/null || exit 1
${SH} -uc 'unset foo; echo ${foo+}' >/dev/null || exit 1
${SH} -uc 'unset foo; echo ${foo=}' >/dev/null || exit 1
# length/trimming are affected
${SH} -uc 'unset foo; echo ${#foo}' 2>/dev/null && exit 1
${SH} -uc 'foo=; echo ${#foo}' >/dev/null || exit 1
${SH} -uc 'unset foo; echo ${foo#?}' 2>/dev/null && exit 1
${SH} -uc 'foo=1; echo ${foo#?}' >/dev/null || exit 1
${SH} -uc 'unset foo; echo ${foo##?}' 2>/dev/null && exit 1
${SH} -uc 'foo=1; echo ${foo##?}' >/dev/null || exit 1
${SH} -uc 'unset foo; echo ${foo%?}' 2>/dev/null && exit 1
${SH} -uc 'foo=1; echo ${foo%?}' >/dev/null || exit 1
${SH} -uc 'unset foo; echo ${foo%%?}' 2>/dev/null && exit 1
${SH} -uc 'foo=1; echo ${foo%%?}' >/dev/null || exit 1

${SH} -uc 'echo $!' 2>/dev/null && exit 1
${SH} -uc ':& echo $!' >/dev/null || exit 1
${SH} -uc 'echo $#' >/dev/null || exit 1
${SH} -uc 'echo $1' 2>/dev/null && exit 1
${SH} -uc 'echo $1' ${SH} x >/dev/null || exit 1
${SH} -uc 'echo $2' ${SH} x 2>/dev/null && exit 1
${SH} -uc 'echo $2' ${SH} x y >/dev/null || exit 1
exit 0
EOF
put fbsd/expansion/set-u2.0 <<'EOF'

set -u
: $* $@ "$@" "$*"
set -- x
: $* $@ "$@" "$*"
shift $#
: $* $@ "$@" "$*"
set -- y
set --
: $* $@ "$@" "$*"
exit 0
EOF
put fbsd/expansion/set-u3.0 <<'EOF'

set -u
unset x
v=$( (eval ': $((x))') 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF
put fbsd/expansion/tilde1.0 <<'EOF1'

HOME=/tmp
roothome=~root
if [ "$roothome" = "~root" ]; then
	echo "~root is not expanded!"
	exit 2
fi

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- ~'				'1|/tmp'
testcase 'set -- ~/foo'				'1|/tmp/foo'
testcase 'set -- x~'				'1|x~'
testcase 'set -- ~root'				"1|$roothome"
h=~
testcase 'set -- "$h"'				'1|/tmp'
ooIFS=$IFS
IFS=m
testcase 'set -- ~'				'1|/tmp'
testcase 'set -- ~/foo'				'1|/tmp/foo'
testcase 'set -- $h'				'2|/t|p'
IFS=$ooIFS
t=\~
testcase 'set -- $t'				'1|~'
r=$(cat <<EOF
~
EOF
)
testcase 'set -- $r'				'1|~'
r=$(cat <<EOF
${t+~}
EOF
)
testcase 'set -- $r'				'1|~'
r=$(cat <<EOF
${t+~/.}
EOF
)
testcase 'set -- $r'				'1|~/.'

test "x$failures" = x
EOF1
put fbsd/expansion/tilde2.0 <<'EOF1'

HOME=/tmp
roothome=~root
if [ "$roothome" = "~root" ]; then
	echo "~root is not expanded!"
	exit 2
fi

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- ${$+~}'			'1|/tmp'
testcase 'set -- ${$+~/}'			'1|/tmp/'
testcase 'set -- ${$+~/foo}'			'1|/tmp/foo'
testcase 'set -- ${$+x~}'			'1|x~'
testcase 'set -- ${$+~root}'			"1|$roothome"
testcase 'set -- ${$+"~"}'			'1|~'
testcase 'set -- ${$+"~/"}'			'1|~/'
testcase 'set -- ${$+"~/foo"}'			'1|~/foo'
testcase 'set -- ${$+"x~"}'			'1|x~'
testcase 'set -- ${$+"~root"}'			"1|~root"
testcase 'set -- "${$+~}"'			'1|~'
testcase 'set -- "${$+~/}"'			'1|~/'
testcase 'set -- "${$+~/foo}"'			'1|~/foo'
testcase 'set -- "${$+x~}"'			'1|x~'
testcase 'set -- "${$+~root}"'			"1|~root"
testcase 'set -- ${HOME#~}'			'0|'
h=~
testcase 'set -- "$h"'				'1|/tmp'
f=~/foo
testcase 'set -- "$f"'				'1|/tmp/foo'
testcase 'set -- ${f#~}'			'1|/foo'
testcase 'set -- ${f#~/}'			'1|foo'

ooIFS=$IFS
IFS=m
testcase 'set -- ${$+~}'			'1|/tmp'
testcase 'set -- ${$+~/foo}'			'1|/tmp/foo'
testcase 'set -- ${$+$h}'			'2|/t|p'
testcase 'set -- ${HOME#~}'			'0|'
IFS=$ooIFS

t=\~
testcase 'set -- ${$+$t}'			'1|~'
r=$(cat <<EOF
${HOME#~}
EOF
)
testcase 'set -- $r'				'0|'
r=$(cat <<EOF
${HOME#'~'}
EOF
)
testcase 'set -- $r'				'1|/tmp'
r=$(cat <<EOF
${t#'~'}
EOF
)
testcase 'set -- $r'				'0|'
r=$(cat <<EOF
${roothome#~root}
EOF
)
testcase 'set -- $r'				'0|'
r=$(cat <<EOF
${f#~}
EOF
)
testcase 'set -- $r'				'1|/foo'
r=$(cat <<EOF
${f#~/}
EOF
)
testcase 'set -- $r'				'1|foo'

test "x$failures" = x
EOF1
put fbsd/expansion/trim1.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- ${t%t}'			'1|texttex'
testcase 'set -- "${t%t}"'			'1|texttex'
testcase 'set -- ${t%e*}'			'1|textt'
testcase 'set -- "${t%e*}"'			'1|textt'
testcase 'set -- ${t%%e*}'			'1|t'
testcase 'set -- "${t%%e*}"'			'1|t'
testcase 'set -- ${t%%*}'			'0|'
testcase 'set -- "${t%%*}"'			'1|'
testcase 'set -- ${t#t}'			'1|exttext'
testcase 'set -- "${t#t}"'			'1|exttext'
testcase 'set -- ${t#*x}'			'1|ttext'
testcase 'set -- "${t#*x}"'			'1|ttext'
testcase 'set -- ${t##*x}'			'1|t'
testcase 'set -- "${t##*x}"'			'1|t'
testcase 'set -- ${t##*}'			'0|'
testcase 'set -- "${t##*}"'			'1|'
testcase 'set -- ${t%e$a}'			'1|textt'

set -f
testcase 'set -- ${s%[?]*}'			'1|ast*que'
testcase 'set -- "${s%[?]*}"'			'1|ast*que'
testcase 'set -- ${s%[*]*}'			'1|ast'
testcase 'set -- "${s%[*]*}"'			'1|ast'
set +f

testcase 'set -- $b'				'1|{{(#)}}'
testcase 'set -- ${b%\}}'			'1|{{(#)}'
testcase 'set -- ${b#{}'			'1|{(#)}}'
testcase 'set -- "${b#{}"'			'1|{(#)}}'
# Parentheses are special in ksh, check that they can be escaped
testcase 'set -- ${b%\)*}'			'1|{{(#'
testcase 'set -- ${b#{}'			'1|{(#)}}'
testcase 'set -- $h'				'1|##'
testcase 'set -- ${h#\#}'			'1|#'
testcase 'set -- ${h###}'			'1|#'
testcase 'set -- "${h###}"'			'1|#'
testcase 'set -- ${h%#}'			'1|#'
testcase 'set -- "${h%#}"'			'1|#'

set -f
testcase 'set -- ${s%"${s#?}"}'			'1|a'
testcase 'set -- ${s%"${s#????}"}'		'1|ast*'
testcase 'set -- ${s%"${s#????????}"}'		'1|ast*que?'
testcase 'set -- ${s#"${s%?}"}'			'1|n'
testcase 'set -- ${s#"${s%????}"}'		'1|?non'
testcase 'set -- ${s#"${s%????????}"}'		'1|*que?non'
set +f
testcase 'set -- "${s%"${s#?}"}"'		'1|a'
testcase 'set -- "${s%"${s#????}"}"'		'1|ast*'
testcase 'set -- "${s%"${s#????????}"}"'	'1|ast*que?'
testcase 'set -- "${s#"${s%?}"}"'		'1|n'
testcase 'set -- "${s#"${s%????}"}"'		'1|?non'
testcase 'set -- "${s#"${s%????????}"}"'	'1|*que?non'
testcase 'set -- ${p#${p}}'			'1|/etc/'
testcase 'set -- "${p#${p}}"'			'1|/et[c]/'
testcase 'set -- ${p#*[[]}'			'1|c]/'
testcase 'set -- "${p#*[[]}"'			'1|c]/'
testcase 'set -- ${p#*\[}'			'1|c]/'
testcase 'set -- ${p#*"["}'			'1|c]/'
testcase 'set -- "${p#*"["}"'			'1|c]/'

test "x$failures" = x
EOF
put fbsd/expansion/trim10.0 <<'EOF'

a='z
'
b=${a%
}
[ "$b" = z ]
EOF
put fbsd/expansion/trim11.0 <<'EOF'

a='z
'
b="${a%
}"
[ "$b" = z ]
EOF
put fbsd/expansion/trim2.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

set -f
testcase 'set -- $s'				'1|ast*que?non'
testcase 'set -- ${s%\?*}'			'1|ast*que'
testcase 'set -- "${s%\?*}"'			'1|ast*que'
testcase 'set -- ${s%\**}'			'1|ast'
testcase 'set -- "${s%\**}"'			'1|ast'
testcase 'set -- ${s%"$q"*}'			'1|ast*que'
testcase 'set -- "${s%"$q"*}"'			'1|ast*que'
testcase 'set -- ${s%"$a"*}'			'1|ast'
testcase 'set -- "${s%"$a"*}"'			'1|ast'
testcase 'set -- ${s%"$q"$a}'			'1|ast*que'
testcase 'set -- "${s%"$q"$a}"'			'1|ast*que'
testcase 'set -- ${s%"$a"$a}'			'1|ast'
testcase 'set -- "${s%"$a"$a}"'			'1|ast'
set +f

testcase 'set -- "${b%\}}"'			'1|{{(#)}'
# Parentheses are special in ksh, check that they can be escaped
testcase 'set -- "${b%\)*}"'			'1|{{(#'
testcase 'set -- "${h#\#}"'			'1|#'

testcase 'set -- ${p%"${p#?}"}'			'1|/'
testcase 'set -- ${p%"${p#??????}"}'		'1|/etc'
testcase 'set -- ${p%"${p#???????}"}'		'1|/etc/'
testcase 'set -- "${p%"${p#?}"}"'		'1|/'
testcase 'set -- "${p%"${p#??????}"}"'		'1|/et[c]'
testcase 'set -- "${p%"${p#???????}"}"'		'1|/et[c]/'
testcase 'set -- ${p#"${p}"}'			'0|'
testcase 'set -- "${p#"${p}"}"'			'1|'
testcase 'set -- "${p#*\[}"'			'1|c]/'

test "x$failures" = x
EOF
put fbsd/expansion/trim3.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##' c='\\\\'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

# This doesn't make much sense, but it fails in dash so I'm adding it here:
testcase 'set -- "${w%${w#???}}"'		'1|a b'

testcase 'set -- ${p#/et[}'			'1|c]/'
testcase 'set -- "${p#/et[}"'			'1|c]/'
testcase 'set -- "${p%${p#????}}"'		'1|/et['

testcase 'set -- ${b%'\'}\''}'			'1|{{(#)}'

testcase 'set -- ${c#\\}'			'1|\\\'
testcase 'set -- ${c#\\\\}'			'1|\\'
testcase 'set -- ${c#\\\\\\}'			'1|\'
testcase 'set -- ${c#\\\\\\\\}'			'0|'
testcase 'set -- "${c#\\}"'			'1|\\\'
testcase 'set -- "${c#\\\\}"'			'1|\\'
testcase 'set -- "${c#\\\\\\}"'			'1|\'
testcase 'set -- "${c#\\\\\\\\}"'		'1|'
testcase 'set -- "${c#"$c"}"'			'1|'
testcase 'set -- ${c#"$c"}'			'0|'
testcase 'set -- "${c%"$c"}"'			'1|'
testcase 'set -- ${c%"$c"}'			'0|'

test "x$failures" = x
EOF
put fbsd/expansion/trim4.0 <<'EOF'

v1=/homes/SOME_USER
v2=
v3=C123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789

# Trigger bug in VSTRIMRIGHT processing STADJUST() call in expand.c:subevalvar()
while [ ${#v2} -lt 2000 ]; do
	v4="${v2} ${v1%/*} $v3"
	if [ ${#v4} -ne $((${#v2} + ${#v3} + 8)) ]; then
		echo bad: ${#v4} -ne $((${#v2} + ${#v3} + 8))
	fi
	v2=x$v2
	v3=y$v3
done
EOF
put fbsd/expansion/trim5.0 <<'EOF'

e= q='?' a='*' t=texttext s='ast*que?non' p='/et[c]/' w='a b c' b='{{(#)}}'
h='##'
failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- "${b%'\'}\''}"'		'1|{{(#)}'
testcase 'set -- ${b%"}"}'			'1|{{(#)}'
testcase 'set -- "${b%"}"}"'			'1|{{(#)}'

test "x$failures" = x
EOF
put fbsd/expansion/trim6.0 <<'EOF'

e=
for i in 0 1 2 3; do
	for j in 0 1 2 3 4 5 6 7; do
		for k in 0 1 2 3 4 5 6 7; do
			case $i$j$k in
			000) continue ;;
			esac
			e="$e\\$i$j$k"
		done
	done
done
e=$(printf "$e")
v=@$e@$e@
y=${v##*"$e"}
yq="${v##*"$e"}"
[ "$y" = @ ] || echo "error when unquoted in non-splitting context"
[ "$yq" = @ ] || echo "error when quoted in non-splitting context"
[ "${v##*"$e"}" = @ ] || echo "error when quoted in splitting context"
IFS=
[ ${v##*"$e"} = @ ] || echo "error when unquoted in splitting context"
EOF
put fbsd/expansion/trim7.0 <<'EOF'

set -- 1 2 3 4 5 6 7 8 9 10 11 12 13
[ "${##1}" = 3 ] || echo '${##1} wrong'
[ "${###1}" = 3 ] || echo '${###1} wrong'
[ "${###}" = 13 ] || echo '${###} wrong'
[ "${#%3}" = 1 ] || echo '${#%3} wrong'
[ "${#%%3}" = 1 ] || echo '${#%%3} wrong'
[ "${#%%}" = 13 ] || echo '${#%%} wrong'
set --
[ "${##0}" = "" ] || echo '${##0} wrong'
[ "${###0}" = "" ] || echo '${###0} wrong'
[ "${###}" = 0 ] || echo '${###} wrong'
[ "${#%0}" = "" ] || echo '${#%0} wrong'
[ "${#%%0}" = "" ] || echo '${#%%0} wrong'
[ "${#%%}" = 0 ] || echo '${#%%} wrong'
EOF
put fbsd/expansion/trim8.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.UTF-8
export LC_CTYPE

c1=e
# a umlaut
c2=$(printf '\303\244')
# euro sign
c3=$(printf '\342\202\254')
# some sort of 't' outside BMP
c4=$(printf '\360\235\225\245')

s=$c1$c2$c3$c4

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- "$s"'				"1|$s"
testcase 'set -- "${s#$c2}"'			"1|$s"
testcase 'set -- "${s#*}"'			"1|$s"
testcase 'set -- "${s#$c1}"'			"1|$c2$c3$c4"
testcase 'set -- "${s#$c1$c2}"'			"1|$c3$c4"
testcase 'set -- "${s#$c1$c2$c3}"'		"1|$c4"
testcase 'set -- "${s#$c1$c2$c3$c4}"'		"1|"
testcase 'set -- "${s#?}"'			"1|$c2$c3$c4"
testcase 'set -- "${s#??}"'			"1|$c3$c4"
testcase 'set -- "${s#???}"'			"1|$c4"
testcase 'set -- "${s#????}"'			"1|"
testcase 'set -- "${s#*$c3}"'			"1|$c4"
testcase 'set -- "${s%$c4}"'			"1|$c1$c2$c3"
testcase 'set -- "${s%$c3$c4}"'			"1|$c1$c2"
testcase 'set -- "${s%$c2$c3$c4}"'		"1|$c1"
testcase 'set -- "${s%$c1$c2$c3$c4}"'		"1|"
testcase 'set -- "${s%?}"'			"1|$c1$c2$c3"
testcase 'set -- "${s%??}"'			"1|$c1$c2"
testcase 'set -- "${s%???}"'			"1|$c1"
testcase 'set -- "${s%????}"'			"1|"
testcase 'set -- "${s%$c2*}"'			"1|$c1"
testcase 'set -- "${s##$c2}"'			"1|$s"
testcase 'set -- "${s##*}"'			"1|"
testcase 'set -- "${s##$c1}"'			"1|$c2$c3$c4"
testcase 'set -- "${s##$c1$c2}"'		"1|$c3$c4"
testcase 'set -- "${s##$c1$c2$c3}"'		"1|$c4"
testcase 'set -- "${s##$c1$c2$c3$c4}"'		"1|"
testcase 'set -- "${s##?}"'			"1|$c2$c3$c4"
testcase 'set -- "${s##??}"'			"1|$c3$c4"
testcase 'set -- "${s##???}"'			"1|$c4"
testcase 'set -- "${s##????}"'			"1|"
testcase 'set -- "${s##*$c3}"'			"1|$c4"
testcase 'set -- "${s%%$c4}"'			"1|$c1$c2$c3"
testcase 'set -- "${s%%$c3$c4}"'		"1|$c1$c2"
testcase 'set -- "${s%%$c2$c3$c4}"'		"1|$c1"
testcase 'set -- "${s%%$c1$c2$c3$c4}"'		"1|"
testcase 'set -- "${s%%?}"'			"1|$c1$c2$c3"
testcase 'set -- "${s%%??}"'			"1|$c1$c2"
testcase 'set -- "${s%%???}"'			"1|$c1"
testcase 'set -- "${s%%????}"'			"1|"
testcase 'set -- "${s%%$c2*}"'			"1|$c1"

test "x$failures" = x
EOF
put fbsd/expansion/trim9.0 <<'EOF'

# POSIX does not specify these but they occasionally occur in the wild.
# This just serves to keep working what currently works.

failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'shift $#; set -- "${*#Q}"'		'1|'
testcase 'shift $#; set -- "${*##Q}"'		'1|'
testcase 'shift $#; set -- "${*%Q}"'		'1|'
testcase 'shift $#; set -- "${*%%Q}"'		'1|'
testcase 'set -- Q R; set -- "${*#Q}"'		'1| R'
testcase 'set -- Q R; set -- "${*##Q}"'		'1| R'
testcase 'set -- Q R; set -- "${*%R}"'		'1|Q '
testcase 'set -- Q R; set -- "${*%%R}"'		'1|Q '
testcase 'set -- Q R; set -- "${*#S}"'		'1|Q R'
testcase 'set -- Q R; set -- "${*##S}"'		'1|Q R'
testcase 'set -- Q R; set -- "${*%S}"'		'1|Q R'
testcase 'set -- Q R; set -- "${*%%S}"'		'1|Q R'
testcase 'set -- Q R; set -- ${*#Q}'		'1|R'
testcase 'set -- Q R; set -- ${*##Q}'		'1|R'
testcase 'set -- Q R; set -- ${*%R}'		'1|Q'
testcase 'set -- Q R; set -- ${*%%R}'		'1|Q'
testcase 'set -- Q R; set -- ${*#S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${*##S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${*%S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${*%%S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${@#Q}'		'1|R'
testcase 'set -- Q R; set -- ${@##Q}'		'1|R'
testcase 'set -- Q R; set -- ${@%R}'		'1|Q'
testcase 'set -- Q R; set -- ${@%%R}'		'1|Q'
testcase 'set -- Q R; set -- ${@#S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${@##S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${@%S}'		'2|Q|R'
testcase 'set -- Q R; set -- ${@%%S}'		'2|Q|R'
testcase 'set -- Q R; set -- "${@#Q}"'		'2||R'
testcase 'set -- Q R; set -- "${@%R}"'		'2|Q|'
testcase 'set -- Q R; set -- "${@%%R}"'		'2|Q|'
testcase 'set -- Q R; set -- "${@#S}"'		'2|Q|R'
testcase 'set -- Q R; set -- "${@##S}"'		'2|Q|R'
testcase 'set -- Q R; set -- "${@%S}"'		'2|Q|R'
testcase 'set -- Q R; set -- "${@%%S}"'		'2|Q|R'

test "x$failures" = x
EOF
put fbsd/invocation/sh-ac1.0 <<'EOF'
# Test that attached options before c are processed

case `${SH} -ac 'echo $-:$0' moo` in
*a*:moo) true ;;
*) false ;;
esac
EOF
put fbsd/invocation/sh-c-missing1.0 <<'EOF'

! echo echo bad | ${SH} -c 2>/dev/null
EOF
put fbsd/invocation/sh-c1.0 <<'EOF'
# Test that -c executes command_string with the given name and arg

${SH} -c 'echo $0 $@' moo foo | grep -qx -- "moo foo"
EOF
put fbsd/invocation/sh-ca1.0 <<'EOF'
# Test that attached options after c are processed

case `${SH} -ca 'echo $-:$0' moo` in
*a*:moo) true ;;
*) false ;;
esac
EOF
put fbsd/invocation/sh-fca1.0 <<'EOF'
# Test that attached options before and after c are processed

case `${SH} -fca 'echo $-:$-:$0:$@' foo -bar` in
*f*:*a*:foo:-bar) true ;;
*) false ;;
esac
EOF
put fbsd/parameters/env1.0 <<'EOF1'

export key='must contain this'
unset x
r=$(ENV="\${x?\$key}" ${SH} -i +m 2>&1 >/dev/null <<\EOF
exit 0
EOF
) && case $r in
*"$key"*) true ;;
*) false ;;
esac
EOF1
put fbsd/parameters/exitstatus1.0 <<'EOF'
f() {
	[ $? = $1 ] || exit 1
}

true
f 0
false
f 1
EOF
put fbsd/parameters/ifs1.0 <<'EOF'

env IFS=_ ${SH} -c '
rc=2
nosuchtool_function() {
	rc=0
}
v=nosuchtool_function
$v && exit "$rc"
'
EOF
put fbsd/parameters/mail1.0 <<'EOF'
# Test that a non-interactive shell does not access $MAIL.

goodfile=/var/empty/sh-test-goodfile
mailfile=/var/empty/sh-test-mailfile
T=$(mktemp sh-test.XXXXXX) || exit
MAIL=$mailfile ktrace -t n -i -f "$T" ${SH} -c "[ -s $goodfile ]" 3>/dev/null
if ! grep -q $goodfile "$T"; then
	# ktrace problem
	rc=0
elif ! grep -q $mailfile "$T"; then
	rc=0
fi
rm "$T"
exit ${rc:-3}
EOF
put fbsd/parameters/mail2.0 <<'EOF'
# Test that an interactive shell accesses $MAIL.

goodfile=/var/empty/sh-test-goodfile
mailfile=/var/empty/sh-test-mailfile
T=$(mktemp sh-test.XXXXXX) || exit
ENV=$goodfile MAIL=$mailfile ktrace -t n -i -f "$T" ${SH} +m -i </dev/null >/dev/null 2>&1
if ! grep -q $goodfile "$T"; then
	# ktrace problem
	rc=0
elif grep -q $mailfile "$T"; then
	rc=0
fi
rm "$T"
exit ${rc:-3}
EOF
put fbsd/parameters/optind1.0 <<'EOF'

unset OPTIND && [ -z "$OPTIND" ]
EOF
put fbsd/parameters/optind2.0 <<'EOF'

[ "$(OPTIND=42 ${SH} -c 'printf %s "$OPTIND"')" = 1 ]
EOF
put fbsd/parameters/positional1.0 <<'EOF'

set -- a b c d e f g h i j
[ "$1" = a ] || echo "error at line $LINENO"
[ "${1}" = a ] || echo "error at line $LINENO"
[ "${1-foo}" = a ] || echo "error at line $LINENO"
[ "${1+foo}" = foo ] || echo "error at line $LINENO"
[ "$1+foo" = a+foo ] || echo "error at line $LINENO"
[ "$10" = a0 ] || echo "error at line $LINENO"
[ "$100" = a00 ] || echo "error at line $LINENO"
[ "${10}" = j ] || echo "error at line $LINENO"
[ "${10-foo}" = j ] || echo "error at line $LINENO"
[ "${100-foo}" = foo ] || echo "error at line $LINENO"
EOF
put fbsd/parameters/positional2.0 <<'EOF'

failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'set -- a b; set -- p$@q'		'2|pa|bq'
testcase 'set -- a b; set -- $@q'		'2|a|bq'
testcase 'set -- a b; set -- p$@'		'2|pa|b'
testcase 'set -- a b; set -- p$@q'		'2|pa|bq'
testcase 'set -- a b; set -- $@q'		'2|a|bq'
testcase 'set -- a b; set -- p$@'		'2|pa|b'
testcase 'set -- a b; set -- p$*q'		'2|pa|bq'
testcase 'set -- a b; set -- $*q'		'2|a|bq'
testcase 'set -- a b; set -- p$*'		'2|pa|b'
testcase 'set -- a b; set -- p$*q'		'2|pa|bq'
testcase 'set -- a b; set -- $*q'		'2|a|bq'
testcase 'set -- a b; set -- p$*'		'2|pa|b'
testcase 'set -- a b; set -- "p$@q"'		'2|pa|bq'
testcase 'set -- a b; set -- "$@q"'		'2|a|bq'
testcase 'set -- a b; set -- "p$@"'		'2|pa|b'
testcase 'set -- a b; set -- p"$@"q'		'2|pa|bq'
testcase 'set -- a b; set -- "$@"q'		'2|a|bq'
testcase 'set -- a b; set -- p"$@"'		'2|pa|b'
testcase 'set -- "" a b; set -- "p$@q"'		'3|p|a|bq'
testcase 'set -- "" a b; set -- "$@q"'		'3||a|bq'
testcase 'set -- "" a b; set -- "p$@"'		'3|p|a|b'
testcase 'set -- "" a b; set -- p"$@"q'		'3|p|a|bq'
testcase 'set -- "" a b; set -- "$@"q'		'3||a|bq'
testcase 'set -- "" a b; set -- p"$@"'		'3|p|a|b'
testcase 'set -- a; set -- p$@q'		'1|paq'
testcase 'set -- a; set -- $@q'			'1|aq'
testcase 'set -- a; set -- p$@'			'1|pa'
testcase 'set -- a; set -- p$@q'		'1|paq'
testcase 'set -- a; set -- $@q'			'1|aq'
testcase 'set -- a; set -- p$@'			'1|pa'
testcase 'set -- a; set -- p$*q'		'1|paq'
testcase 'set -- a; set -- $*q'			'1|aq'
testcase 'set -- a; set -- p$*'			'1|pa'
testcase 'set -- a; set -- p$*q'		'1|paq'
testcase 'set -- a; set -- $*q'			'1|aq'
testcase 'set -- a; set -- p$*'			'1|pa'
testcase 'set -- a; set -- "p$@q"'		'1|paq'
testcase 'set -- a; set -- "$@q"'		'1|aq'
testcase 'set -- a; set -- "p$@"'		'1|pa'
testcase 'set -- a; set -- p"$@"q'		'1|paq'
testcase 'set -- a; set -- "$@"q'		'1|aq'
testcase 'set -- a; set -- p"$@"'		'1|pa'

test "x$failures" = x
EOF
put fbsd/parameters/positional3.0 <<'EOF'

r=$(${SH} -c 'echo ${01:+yes}${010:+yes}' '' a '' '' '' '' '' '' '' '' b)
[ "$r" = yesyes ]
EOF
put fbsd/parameters/positional4.0 <<'EOF'

set -- "x$0" 2 3 4 5 6 7 8 9 "y$0"
[ "${01}.${010}" = "$1.${10}" ]
EOF
put fbsd/parameters/positional5.0 <<'EOF'

i=1
r=0
while [ $i -lt $((0x100000000)) ]; do
	t=
	eval t=\${$i-x}
	case $t in
	x) ;;
	*) echo "Problem with \${$i}" >&2; r=1 ;;
	esac
	i=$((i + 0x10000000))
done
exit $r
EOF
put fbsd/parameters/positional6.0 <<'EOF'

IFS=?
set p r
v=pqrs
r=${v#"$*"}
[ "$r" = pqrs ]
EOF
put fbsd/parameters/positional7.0 <<'EOF'

set -- / ''
IFS=*
set -- "$*"
IFS=:
args="$*"
[ "$#:$args" = "1:/*" ]
EOF
put fbsd/parameters/positional8.0 <<'EOF'

failures=''
ok=''

testcase() {
	code="$1"
	expected="$2"
	oIFS="$IFS"
	eval "$code"
	IFS='|'
	result="$#|$*"
	IFS="$oIFS"
	if [ "x$result" = "x$expected" ]; then
		ok=x$ok
	else
		failures=x$failures
		echo "For $code, expected $expected actual $result"
	fi
}

testcase 'shift $#; set -- ""$*'		'1|'
testcase 'shift $#; set -- $*""'		'1|'
testcase 'shift $#; set -- ""$@'		'1|'
testcase 'shift $#; set -- $@""'		'1|'
testcase 'shift $#; set -- """$*"'		'1|'
testcase 'shift $#; set -- "$*"""'		'1|'
testcase 'shift $#; set -- """$@"'		'1|'
testcase 'shift $#; set -- "$@"""'		'1|'

test "x$failures" = x
EOF
put fbsd/parameters/positional9.0 <<'EOF'
# Although POSIX leaves the result of expanding ${#@} and ${#*} unspecified,
# make sure it is at least numeric.

set -- bb cc ddd
set -f
lengths=${#*}${#@}"${#*}${#@}"$(echo ${#*}${#@}"${#*}${#@}")
IFS=
lengths=$lengths${#*}${#@}"${#*}${#@}"$(echo ${#*}${#@}"${#*}${#@}")
case $lengths in
*[!0-9]*)
	printf 'bad: %s\n' "$lengths"
	exit 3 ;;
????????????????*) ;;
*)
	printf 'too short: %s\n' "$lengths"
	exit 3 ;;
esac
EOF
put fbsd/parameters/pwd1.0 <<'EOF'
# Check that bogus PWD values are not accepted from the environment.

cd / || exit 3
failures=0
[ "$(PWD=foo ${SH} -c 'pwd')" = / ] || : $((failures += 1))
[ "$(PWD=/var/empty ${SH} -c 'pwd')" = / ] || : $((failures += 1))
[ "$(PWD=/var/empty/foo ${SH} -c 'pwd')" = / ] || : $((failures += 1))
[ "$(PWD=/bin/ls ${SH} -c 'pwd')" = / ] || : $((failures += 1))

exit $((failures != 0))
EOF
put fbsd/parameters/pwd2.0 <<'EOF'
# Check that PWD is exported and accepted from the environment.
set -e

T=$(mktemp -d ${TMPDIR:-/tmp}/sh-test.XXXXXX)
trap 'rm -rf $T' 0
cd -P $T
TP=$(pwd)
mkdir test1
ln -s test1 link
cd link
[ "$PWD" = "$TP/link" ]
[ "$(pwd)" = "$TP/link" ]
[ "$(pwd -P)" = "$TP/test1" ]
[ "$(${SH} -c pwd)" = "$TP/link" ]
[ "$(${SH} -c pwd\ -P)" = "$TP/test1" ]
cd ..
[ "$(pwd)" = "$TP" ]
cd -P link
[ "$PWD" = "$TP/test1" ]
[ "$(pwd)" = "$TP/test1" ]
[ "$(pwd -P)" = "$TP/test1" ]
[ "$(${SH} -c pwd)" = "$TP/test1" ]
[ "$(${SH} -c pwd\ -P)" = "$TP/test1" ]
EOF
put fbsd/parser/alias1.0 <<'EOF'

alias alias0=exit
eval 'alias0 0'
exit 1
EOF
put fbsd/parser/alias10.0 <<'EOF'

# This test may start consuming memory indefinitely if it fails.
ulimit -t 5 2>/dev/null
ulimit -v 100000 2>/dev/null

alias echo='echo'
alias echo='echo'
[ "`eval echo b`" = b ]
EOF
put fbsd/parser/alias11.0 <<'EOF'

alias alias0=alias1
alias alias1=exit
eval 'alias0 0'
exit 3
EOF
put fbsd/parser/alias12.0 <<'EOF'

unalias -a
alias alias0=command
alias true='echo bad'
eval 'alias0 true'
EOF
put fbsd/parser/alias13.0 <<'EOF'

unalias -a
alias command=command
alias true='echo bad'
eval 'command true'
EOF
put fbsd/parser/alias14.0 <<'EOF'

alias command='command '
alias alias0=exit
eval 'command alias0 0'
exit 3
EOF
put fbsd/parser/alias15.0 <<'EOF'

f_echoanddo() {
	printf '%s\n' "$*"
	"$@"
}

alias echoanddo='f_echoanddo '
alias alias0='echo test2'
eval 'echoanddo echo test1'
eval 'echoanddo alias0'
exit 0
EOF
put fbsd/parser/alias15.0.stdout <<'EOF'
echo test1
test1
echo test2
test2
EOF
put fbsd/parser/alias16.0 <<'EOF'

v=1
alias a='unalias a
v=2'
eval a
[ "$v" = 2 ]
EOF
put fbsd/parser/alias17.0 <<'EOF'

v=1
alias a='unalias -a
v=2'
eval a
[ "$v" = 2 ]
EOF
put fbsd/parser/alias18.0 <<'EOF'

v=1
alias a='alias a=v=2
v=3
a'
eval a
[ "$v" = 2 ]
EOF
put fbsd/parser/alias19.0 <<'EOF1'

alias begin={ end=}
begin
cat <<EOF
$(echo ok)
EOF
end
EOF1
put fbsd/parser/alias19.0.stdout <<'EOF'
ok
EOF
put fbsd/parser/alias2.0 <<'EOF'

alias alias0=exit
x=alias0
eval 'case $x in alias0) exit 0;; esac'
exit 1
EOF
put fbsd/parser/alias20.0 <<'EOF1'

alias begin={ end=}
: <<EOF &&
$(echo bad1)
EOF
begin
echo ok
end
EOF1
put fbsd/parser/alias20.0.stdout <<'EOF'
ok
EOF
put fbsd/parser/alias3.0 <<'EOF'

alias alias0=exit
x=alias0
eval 'case $x in "alias0") alias0 0;; esac'
exit 1
EOF
put fbsd/parser/alias4.0 <<'EOF'

alias alias0=exit
eval 'x=1 alias0 0'
exit 1
EOF
put fbsd/parser/alias5.0 <<'EOF'

alias alias0=exit
eval '</dev/null alias0 0'
exit 1
EOF
put fbsd/parser/alias6.0 <<'EOF'

alias alias0='| cat >/dev/null'

eval '{ echo bad; } alias0'
eval '(echo bad)alias0'
EOF
put fbsd/parser/alias7.0 <<'EOF'

alias echo='echo a'
[ "`eval echo b`" = "a b" ]
EOF
put fbsd/parser/alias8.0 <<'EOF'

alias echo='echo'
[ "`eval echo b`" = b ]
EOF
put fbsd/parser/alias9.0 <<'EOF'

alias alias0=:
alias alias0=exit
eval 'alias0 0'
exit 1
EOF
put fbsd/parser/and-pipe-not.0 <<'EOF'
true && ! true | false
EOF
put fbsd/parser/case1.0 <<'EOF'

keywords='if then else elif fi while until for do done { } case esac ! in'

# Keywords can be used unquoted in case statements, except the keyword
# esac as the first pattern of a '|' alternation without a starting '('.
# (POSIX doesn't seem to require (esac) to work.)
for k in $keywords; do
	eval "case $k in (foo|$k) ;; *) echo bad ;; esac"
	eval "case $k in ($k) ;; *) echo bad ;; esac"
	eval "case $k in foo|$k) ;; *) echo bad ;; esac"
	[ "$k" = esac ] && continue
	eval "case $k in $k) ;; *) echo bad ;; esac"
done
EOF
put fbsd/parser/case2.0 <<'EOF'

# Pretty much only ash derivatives can parse all of this.

f1() {
	x=$(case x in
		(x|esac) ;;
		(*) echo bad >&2 ;;
	esac)
}
f1
f2() {
	x=$(case x in
		(x|esac) ;;
		(*) echo bad >&2
	esac)
}
f2
f3() {
	x=$(case x in
		x|esac) ;;
		*) echo bad >&2 ;;
	esac)
}
f3
f4() {
	x=$(case x in
		x|esac) ;;
		*) echo bad >&2
	esac)
}
f4
EOF
put fbsd/parser/comment1.0 <<'EOF'

${SH} -c '#'
EOF
put fbsd/parser/comment2.42 <<'EOF'

${SH} -c '#
exit 42'
EOF
put fbsd/parser/dollar-quote1.0 <<'EOF'

set -e

[ $'hi' = hi ]
[ $'hi
there' = 'hi
there' ]
[ $'\"\'\\\a\b\f\t\v' = "\"'\\$(printf "\a\b\f\t\v")" ]
[ $'hi\nthere' = 'hi
there' ]
[ $'a\rb' = "$(printf "a\rb")" ]
EOF
put fbsd/parser/dollar-quote10.0 <<'EOF'

# a umlaut
s=$(printf '\303\244')
# euro sign
s=$s$(printf '\342\202\254')

# Start a new shell so the locale change is picked up.
ss="$(LC_ALL=en_US.UTF-8 ${SH} -c "printf %s \$'\u00e4\u20ac'")"
[ "$s" = "$ss" ]
EOF
put fbsd/parser/dollar-quote11.0 <<'EOF'

# some sort of 't' outside BMP
s=$s$(printf '\360\235\225\245')

# Start a new shell so the locale change is picked up.
ss="$(LC_ALL=en_US.UTF-8 ${SH} -c "printf %s \$'\U0001d565'")"
[ "$s" = "$ss" ]
EOF
put fbsd/parser/dollar-quote12.0 <<'EOF'

# \u without any digits at all remains invalid.
# Our choice is a parse error.

v=$( (eval ": \$'\u'") 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF
put fbsd/parser/dollar-quote13.0 <<'EOF'

# This Unicode escape sequence that has never been in range should either
# fail to expand or expand to a fallback.

c=$(eval printf %s \$\'\\Uffffff41\' 2>/dev/null)
r=$(($? != 0))
[ "$r.$c" = '1.' ] || [ "$r.$c" = '0.?' ] || [ "$r.$c" = $'0.\u2222' ]
EOF
put fbsd/parser/dollar-quote2.0 <<'EOF'

# This depends on the ASCII character set.

[ $'\e' = "$(printf "\033")" ]
EOF
put fbsd/parser/dollar-quote3.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.ISO8859-1
export LC_CTYPE

e=
for i in 0 1 2 3; do
	for j in 0 1 2 3 4 5 6 7; do
		for k in 0 1 2 3 4 5 6 7; do
			case $i$j$k in
			000) continue ;;
			esac
			e="$e\\$i$j$k"
		done
	done
done
ee=`printf "$e"`
[ "${#ee}" = 255 ] || echo length bad

# Start a new shell so the locale change is picked up.
[ "$(${SH} -c "printf %s \$'$e'")" = "$ee" ]
EOF
put fbsd/parser/dollar-quote4.0 <<'EOF'

unset LC_ALL
LC_CTYPE=en_US.ISO8859-1
export LC_CTYPE

e=
for i in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
	for j in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do
		case $i$j in
		00) continue ;;
		esac
		e="$e\x$i$j"
	done
done

# Start a new shell so the locale change is picked up.
ee="$(${SH} -c "printf %s \$'$e'")"
[ "${#ee}" = 255 ] || echo length bad
EOF
put fbsd/parser/dollar-quote5.0 <<'EOF'

# This depends on the ASCII character set.

set -e

[ $'\ca\cb\cc\cd\ce\cf\cg\ch\ci\cj\ck\cl\cm\cn\co\cp\cq\cr\cs\ct\cu\cv\cw\cx\cy\cz' = $'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032' ]
[ $'\cA\cB\cC\cD\cE\cF\cG\cH\cI\cJ\cK\cL\cM\cN\cO\cP\cQ\cR\cS\cT\cU\cV\cW\cX\cY\cZ' = $'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032' ]
[ $'\c[' = $'\033' ]
[ $'\c]' = $'\035' ]
[ $'\c^' = $'\036' ]
[ $'\c_' = $'\037' ]
EOF
put fbsd/parser/dollar-quote6.0 <<'EOF'

# This depends on the ASCII character set.

[ $'\c\\' = $'\034' ]
EOF
put fbsd/parser/dollar-quote7.0 <<'EOF'

set -e

[ $'\u0024\u0040\u0060' = '$@`' ]
[ $'\U00000024\U00000040\U00000060' = '$@`' ]
EOF
put fbsd/parser/dollar-quote8.0 <<'EOF'

[ $'hello\0' = hello ]
[ $'hello\0world' = hello ]
[ $'hello\0'$'world' = helloworld ]
[ $'hello\000' = hello ]
[ $'hello\000world' = hello ]
[ $'hello\000'$'world' = helloworld ]
[ $'hello\x00' = hello ]
[ $'hello\x00world' = hello ]
[ $'hello\x00'$'world' = helloworld ]
EOF
put fbsd/parser/dollar-quote9.0 <<'EOF'

# POSIX and C99 say D800-DFFF are undefined in a universal character name.
# We reject this but many other shells expand to something that looks like
# CESU-8.

v=$( (eval ": \$'\uD800'") 2>&1 >/dev/null)
[ $? -ne 0 ] && [ -n "$v" ]
EOF
put fbsd/parser/empty-braces1.0 <<'EOF'

# Unfortunately, some scripts depend on the extension of allowing an empty
# pair of braces.

{ } &
wait $!
EOF
put fbsd/parser/empty-cmd1.0 <<'EOF'

! (eval ': || f()') 2>/dev/null
EOF
put fbsd/parser/for1.0 <<'EOF'

nl='
'
list=' a b c'
for s1 in "$nl" " "; do
	for s2 in "$nl" ";" ";$nl"; do
		for s3 in "$nl" " "; do
			r=''
			eval "for i${s1}in ${list}${s2}do${s3}r=\"\$r \$i\"; done"
			[ "$r" = "$list" ] || exit 1
		done
	done
done
set -- $list
for s2 in "$nl" " "; do
	for s3 in "$nl" " "; do
		r=''
		eval "for i${s2}do${s3}r=\"\$r \$i\"; done"
		[ "$r" = "$list" ] || exit 1
	done
done
for s1 in "$nl" " "; do
	for s2 in "$nl" ";" ";$nl"; do
		for s3 in "$nl" " "; do
			eval "for i${s1}in${s2}do${s3}exit 1; done"
		done
	done
done
EOF
put fbsd/parser/for2.0 <<'EOF'

# Common extensions to the 'for' syntax.

nl='
'
list=' a b c'
set -- $list
for s2 in ";" ";$nl"; do
	for s3 in "$nl" " "; do
		r=''
		eval "for i${s2}do${s3}r=\"\$r \$i\"; done"
		[ "$r" = "$list" ] || exit 1
	done
done
EOF
put fbsd/parser/func1.0 <<'EOF'
# POSIX does not require these bytes to work in function names,
# but making them all work seems a good goal.

failures=0
unset LC_ALL
export LC_CTYPE=en_US.ISO8859-1
i=128
set -f
while [ "$i" -le 255 ]; do
	c=$(printf \\"$(printf %o "$i")")
	ok=0
	eval "$c() { ok=1; }"
	$c
	ok1=$ok
	ok=0
	"$c"
	if [ "$ok" != 1 ] || [ "$ok1" != 1 ]; then
		echo "Bad results for character $i" >&2
		: $((failures += 1))
	fi
	unset -f $c
	i=$((i+1))
done
exit $((failures > 0))
EOF
put fbsd/parser/func2.0 <<'EOF'

f() { return 42; }
f() { return 3; } &
f
[ $? -eq 42 ]
EOF
put fbsd/parser/func3.0 <<'EOF'

name=/var/empty/nosuch
f() { true; } <$name
name=/dev/null
f
EOF
put fbsd/parser/heredoc1.0 <<'EOF1'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$(cat <<EOF
hi
EOF
)" = hi'

check '"$(cat <<EOF
${$+hi}
EOF
)" = hi'

unset yy
check '"$(cat <<EOF
${yy-hi}
EOF
)" = hi'

check '"$(cat <<EOF
${$+hi
there}
EOF
)" = "hi
there"'

check '"$(cat <<EOF
$((1+1))
EOF
)" = 2'

check '"$(cat <<EOF
$(echo hi)
EOF
)" = hi'

check '"$(cat <<EOF
`echo hi`
EOF
)" = hi'

check '"$(cat <<\EOF
${$+hi}
EOF
)" = "\${\$+hi}"'

check '"$(cat <<\EOF
$(
EOF
)" = \$\('

check '"$(cat <<\EOF
`
EOF
)" = \`'

check '"$(cat <<EOF
"
EOF
)" = \"'

check '"$(cat <<\EOF
"
EOF
)" = \"'

check '"$(cat <<esac
'"'"'
esac
)" = "'"'"'"'

check '"$(cat <<\)
'"'"'
)
)" = "'"'"'"'

exit $((failures != 0))
EOF1
put fbsd/parser/heredoc10.0 <<'EOF1'

# It may be argued that
#   x=$(cat <<EOF
#   foo
#   EOF)
# is a valid complete command that sets x to foo, because
#   cat <<EOF
#   foo
#   EOF
# is a valid script even without the final newline.
# However, if the here-document is not within a new-style command substitution
# or there are other constructs nested inside the command substitution that
# need terminators, the delimiter at the start of a line followed by a close
# parenthesis is clearly a literal part of the here-document.

# This file contains tests that may not work with simplistic $(...) parsers.
# The open parentheses in comments help mksh, but not zsh.

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$(cat <<EOF # (
EOF )
EOF
)" = "EOF )"'

check '"$({ cat <<EOF # (
EOF)
EOF
})" = "EOF)"'

check '"$(if :; then cat <<EOF # (
EOF)
EOF
fi)" = "EOF)"'

check '"$( (cat <<EOF # (
EOF)
EOF
))" = "EOF)"'

exit $((failures != 0))
EOF1
put fbsd/parser/heredoc11.0 <<'EOF'

failures=''

check() {
	if eval "[ $* ]"; then
		:
	else
		echo "Failed: $*"
		failures=x$failures
	fi
}

check '`cat <<EOF
foo
EOF` = foo'

check '"`cat <<EOF
foo
EOF`" = foo'

check '`eval "cat <<EOF
foo
EOF"` = foo'

test "x$failures" = x
EOF
put fbsd/parser/heredoc12.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

longmark=`printf %01000d 4`
longmarkstripped=`printf %0999d 0`

check '"$(cat <<'"$longmark
$longmark"'
echo yes)" = "yes"'

check '"$(cat <<\'"$longmark
$longmark"'
echo yes)" = "yes"'

check '"$(cat <<'"$longmark
yes
$longmark"'
)" = "yes"'

check '"$(cat <<\'"$longmark
yes
$longmark"'
)" = "yes"'

check '"$(cat <<'"$longmark
$longmarkstripped
$longmark.
$longmark"'
)" = "'"$longmarkstripped
$longmark."'"'

check '"$(cat <<\'"$longmark
$longmarkstripped
$longmark.
$longmark"'
)" = "'"$longmarkstripped
$longmark."'"'

exit $((failures != 0))
EOF
put fbsd/parser/heredoc13.0 <<'EOF'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '"$(cat <<""

echo yes)" = "yes"'

check '"$(cat <<""
yes

)" = "yes"'

exit $((failures != 0))
EOF
put fbsd/parser/heredoc14.0 <<'EOF1'
#
read x <<EOF; for i in "$x"
value
EOF
do
	x=$x.$i
done
[ "$x" = value.value ]
EOF1
put fbsd/parser/heredoc15.0 <<'EOF1'
#
set -- dummy
read x <<EOF; for i
value
EOF
do
	x=$x.$i
done
[ "$x" = value.dummy ]
EOF1
put fbsd/parser/heredoc16.0 <<'EOF1'
#
read x <<EOF; case $x
value
EOF
in
	value) x=$x.extended
esac
[ "$x" = value.extended ]
EOF1
put fbsd/parser/heredoc2.0 <<'EOF1'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

s='ast*que?non' sq=\' dq=\"

check '"$(cat <<EOF
${s}
EOF
)" = "ast*que?non"'

check '"$(cat <<EOF
${s+'$sq'x'$sq'}
EOF
)" = ${sq}x${sq}'

check '"$(cat <<EOF
${s#ast}
EOF
)" = "*que?non"'

check '"$(cat <<EOF
${s##"ast"}
EOF
)" = "*que?non"'

check '"$(cat <<EOF
${s##'$sq'ast'$sq'}
EOF
)" = "*que?non"'

exit $((failures != 0))
EOF1
put fbsd/parser/heredoc3.0 <<'EOF1'

# This may be expected to work, but pretty much only ash derivatives allow it.

test "$(cat <<EOF)" = "hi there"
hi there
EOF
EOF1
put fbsd/parser/heredoc4.0 <<'EOF1'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

f() {
	cat <<EOF && echo `echo bar`
foo
EOF
}
check '"`f`" = "foo
bar"'

f() {
	cat <<EOF && echo $(echo bar)
foo
EOF
}
check '"$(f)" = "foo
bar"'

f() {
	echo `echo bar` && cat <<EOF
foo
EOF
}
check '"`f`" = "bar
foo"'

f() {
	echo $(echo bar) && cat <<EOF
foo
EOF
}
check '"$(f)" = "bar
foo"'

exit $((failures != 0))
EOF1
put fbsd/parser/heredoc5.0 <<'EOF1'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

f() {
	cat <<EOF && echo `cat <<EOF
bar
EOF
`
foo
EOF
}
check '"`f`" = "foo
bar"'

f() {
	cat <<EOF && echo $(cat <<EOF
bar
EOF
)
foo
EOF
}
check '"$(f)" = "foo
bar"'

f() {
	echo `cat <<EOF
bar
EOF
` && cat <<EOF
foo
EOF
}
check '"`f`" = "bar
foo"'

f() {
	echo $(cat <<EOF
bar
EOF
) && cat <<EOF
foo
EOF
}
check '"$(f)" = "bar
foo"'

exit $((failures != 0))
EOF1
put fbsd/parser/heredoc6.0 <<'EOF'

r=
! command eval ": <<EOF; )" 2>/dev/null; command eval : hi \${r:=0}
exit ${r:-3}
EOF
put fbsd/parser/heredoc7.0 <<'EOF'

# Some of these created malformed parse trees with null pointers for here
# documents, causing the here document writing process to segfault.
eval ': <<EOF'
eval ': <<EOF;'
eval '`: <<EOF`'
eval '`: <<EOF;`'
eval '`: <<EOF`;'
eval '`: <<EOF;`;'

# Some of these created malformed parse trees with null pointers for here
# documents, causing sh to segfault.
eval ': <<\EOF'
eval ': <<\EOF;'
eval '`: <<\EOF`'
eval '`: <<\EOF;`'
eval '`: <<\EOF`;'
eval '`: <<\EOF;`;'
EOF
put fbsd/parser/heredoc8.0 <<'EOF1'

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

s='ast*que?non' sq=\' dq=\"

# This is possibly useful but differs from other shells.
check '"$(cat <<EOF
${s+"x"}
EOF
)" = ${dq}x${dq}'

exit $((failures != 0))
EOF1
put fbsd/parser/heredoc9.0 <<'EOF1'

# It may be argued that
#   x=$(cat <<EOF
#   foo
#   EOF)
# is a valid complete command that sets x to foo, because
#   cat <<EOF
#   foo
#   EOF
# is a valid script even without the final newline.
# However, if the here-document is not within a new-style command substitution
# or there are other constructs nested inside the command substitution that
# need terminators, the delimiter at the start of a line followed by a close
# parenthesis is clearly a literal part of the here-document.

# This file contains tests that also work with simplistic $(...) parsers.

failures=0

check() {
	if ! eval "[ $* ]"; then
		echo "Failed: $*"
		: $((failures += 1))
	fi
}

check '`${SH} -c "cat <<EOF
EOF)
EOF
"` = "EOF)"'

check '`${SH} -c "(cat <<EOF
EOF)
EOF
)"` = "EOF)"'

check '"`cat <<EOF
EOF x
EOF
`" = "EOF x"'

check '"`cat <<EOF
EOF )
EOF
`" = "EOF )"'

check '"`cat <<EOF
EOF)
EOF
`" = "EOF)"'

check '"$(cat <<EOF
EOF x
EOF
)" = "EOF x"'

exit $((failures != 0))
EOF1
put fbsd/parser/line-cont1.0 <<'EOF'

i\
f
t\
r\
u\
e
t\
h\
e\
n
:
\
f\
i
EOF
put fbsd/parser/line-cont10.0 <<'EOF'

v=XaaaXbbbX
[ "${v\
#\
*\
a}.${v\
#\
#\
*\
a}.${v\
%\
b\
*}.${v\
%\
%\
b\
*}" = aaXbbbX.XbbbX.XaaaXbb.XaaaX ]
EOF
put fbsd/parser/line-cont11.0 <<'EOF'

T=$(mktemp "${TMPDIR:-/tmp}/sh-test.XXXXXXXX") || exit
trap 'rm -f -- "$T"' 0
w='#A'
# A naive pgetc_linecont() would push back two characters here, which
# fails if a new buffer is read between the two characters.
c='${w#\#}'
c=$c$c$c$c
c=$c$c$c$c
c=$c$c$c$c
c=$c$c$c$c
c=$c$c$c$c
c=$c$c$c$c
printf 'v=%s\n' "$c" >"$T"
. "$T"
if [ "${#v}" != 4096 ]; then
	echo "Length is bad (${#v})"
	exit 3
fi
case $v in
*[!A]*) echo "Content is bad"; exit 3 ;;
esac
EOF
put fbsd/parser/line-cont12.0 <<'EOF'

[ '\
' = "\\
" ]
EOF
put fbsd/parser/line-cont2.0 <<'EOF'

[ "a\
b" = ab ]
EOF
put fbsd/parser/line-cont3.0 <<'EOF'

v=`printf %s 'a\
b'`
w="`printf %s 'c\
d'`"
[ "$v$w" = abcd ]
EOF
put fbsd/parser/line-cont4.0 <<'EOF'

v=abcd
[ "$\
v.$\
{v}.${\
v}.${v\
}" = abcd.abcd.abcd.abcd ]
EOF
put fbsd/parser/line-cont5.0 <<'EOF'

bad=1
case x in
x\
) ;\
; *) exit 7
esac &\
& bad= &\
& : >\
>/dev/null

false |\
| [ -z "$bad" ]
EOF
put fbsd/parser/line-cont6.0 <<'EOF1'

v0\
=abc

v=$(cat <\
<\
E\
O\
F
${v0}d
EOF
)

w=$(cat <\
<\
-\
EOF
	efgh
EOF
)

[ "$v.$w" = "abcd.efgh" ]
EOF1
put fbsd/parser/line-cont7.0 <<'EOF'

[ "$(\
(
1\
+ 1)\
)" = 2 ]
EOF
put fbsd/parser/line-cont8.0 <<'EOF'

set -- a b c d e f g h i j
[ "${1\
0\
}" = j ]
EOF
put fbsd/parser/line-cont9.0 <<'EOF'

[ "${$\
:\
+\
xyz}" = xyz ]
EOF
put fbsd/parser/no-space1.0 <<'EOF'

# These are ugly but are required to work.

set -e

while(false)do(:)done
if(false)then(:)fi
if(false)then(:)else(:)fi
(:&&:)||:
until(:)do(:)done
case x in(x);;*)exit 1;(:)esac
case x in(x);;*)exit 1;;esac
for i do(:)done
{(:)}
f(){(:)}
:|:
(:)|(:)
EOF
put fbsd/parser/no-space2.0 <<'EOF'

# This conflicts with ksh extended patterns but occurs in the wild.

set -e

!(false)
EOF
put fbsd/parser/nul1.0 <<'EOF'
# Although POSIX does not specify the effect of NUL bytes in scripts,
# we ignore them.

{
	printf 'v=%03000d\0%02000d' 7 2
	dd if=/dev/zero bs=1000 count=1 status=none
	printf '1 w=%03000d%02000d1\0\n' 7 2
	printf '\0l\0v\0=\0$\0{\0#\0v\0}\n'
	printf '\0l\0w\0=\0\0$\0{\0#\0w}\0\0\0\n'
	printf '[ "$lv.$lw.$v" = "5001.5001.$w" ]\n'
} | ${SH}
EOF
put fbsd/parser/only-redir1.0 <<'EOF'
</dev/null &
wait $!
EOF
put fbsd/parser/only-redir2.0 <<'EOF'
</dev/null | :
EOF
put fbsd/parser/only-redir3.0 <<'EOF'
case x in x) </dev/null ;; esac
EOF
put fbsd/parser/only-redir4.0 <<'EOF'
case x in x) </dev/null ;& esac
EOF
put fbsd/parser/pipe-not1.0 <<'EOF'

: | ! : | false
EOF
put fbsd/parser/ps1-expand1.0 <<'EOF'
# Test simple variable expansion in PS1
testvar=abcdef
output=$(testvar=abcdef PS1='$testvar:' ENV=/dev/null ${SH} +m -i </dev/null 2>&1)
case $output in
*abcdef*) exit 0 ;;
*) echo "Expected 'abcdef' in prompt output"; exit 1 ;;
esac
EOF
put fbsd/parser/ps1-expand2.0 <<'EOF'
# Test braced variable expansion in PS1
testvar=xyz123
output=$(testvar=xyz123 PS1='prefix-${testvar}-suffix:' ENV=/dev/null ${SH} +m -i </dev/null 2>&1)
case $output in
*xyz123*) exit 0 ;;
*) echo "Expected 'xyz123' in prompt output"; exit 1 ;;
esac
EOF
put fbsd/parser/ps1-expand3.0 <<'EOF'
# Test special parameter $$ (PID) in PS1
output=$(PS1='pid:$$:' ENV=/dev/null ${SH} +m -i </dev/null 2>&1)
# Check that output contains "pid:" followed by a number (not literal $$)
case $output in
*pid:\$\$:*) echo "PID not expanded, got literal \$\$"; exit 1 ;;
*pid:[0-9]*) exit 0 ;;
*) echo "Expected PID after 'pid:' in output"; exit 1 ;;
esac
EOF
put fbsd/parser/ps1-expand4.0 <<'EOF'
# Test special parameter $? (exit status) in PS1
output=$(PS1='status:$?:' ENV=/dev/null ${SH} +m -i </dev/null 2>&1)
# Should start with exit status 0
case $output in
*status:\$?:*) echo "Exit status not expanded, got literal \$?"; exit 1 ;;
*status:0:*) exit 0 ;;
*) echo "Expected 'status:0:' in initial prompt"; exit 1 ;;
esac
EOF
put fbsd/parser/ps1-expand5.0 <<'EOF'
# Test positional parameter $0 in PS1
output=$(PS1='shell:$0:' ENV=/dev/null ${SH} +m -i </dev/null 2>&1)
# $0 should contain the shell name/path
case $output in
*shell:\$0:*) echo "Positional parameter not expanded, got literal \$0"; exit 1 ;;
*shell:*sh*:*) exit 0 ;;
*) echo "Expected shell name after 'shell:' in output"; exit 1 ;;
esac
EOF
put fbsd/parser/ps2-expand1.0 <<'EOF1'
# Test variable expansion in PS2 (continuation prompt)
testvar=continue
# Send incomplete command (backslash at end) to trigger PS2
output=$(testvar=continue PS2='$testvar>' ENV=/dev/null ${SH} +m -i <<EOF 2>&1
echo \\
done
EOF
)
case $output in
*continue\>*) exit 0 ;;
*) echo "Expected 'continue>' in PS2 output"; exit 1 ;;
esac
EOF1
put fbsd/parser/set-v1.0 <<'EOF1'

${SH} <<\EOF
echo one >&2
set -v
echo two >&2
echo three >&2
EOF
EOF1
put fbsd/parser/set-v1.0.stderr <<'EOF'
one
echo two >&2
two
echo three >&2
three
EOF
put fbsd/parser/var-assign1.0 <<'EOF'
# In a variable assignment, both the name and the equals sign must be entirely
# unquoted. Therefore, there is only one assignment below; the other words
# containing equals signs are command words.

abc=0
\abc=1 2>/dev/null
a\bc=2 2>/dev/null
abc\=3 2>/dev/null
a\bc\=4 2>/dev/null
'abc'=5 2>/dev/null
a'b'c=6 2>/dev/null
abc'='7 2>/dev/null
'abc=8' 2>/dev/null
"abc"=9 2>/dev/null
a"b"c=10 2>/dev/null
abc"="11 2>/dev/null
"abc=12" 2>/dev/null
[ "$abc" = 0 ]
EOF
put fbsd/set-e/and1.0 <<'EOF'
set -e
true && true
EOF
put fbsd/set-e/and2.1 <<'EOF'
set -e
true && false
exit 0
EOF
put fbsd/set-e/and3.0 <<'EOF'
set -e
false && true
exit 0
EOF
put fbsd/set-e/and4.0 <<'EOF'
set -e
false && false
exit 0
EOF
put fbsd/set-e/background1.0 <<'EOF'
set -e
false &
EOF
put fbsd/set-e/cmd1.0 <<'EOF'
set -e
true
EOF
put fbsd/set-e/cmd2.1 <<'EOF'
set -e
false
exit 0
EOF
put fbsd/set-e/elif1.0 <<'EOF'
set -e
if false; then
	:
elif false; then
	:
fi
EOF
put fbsd/set-e/elif2.0 <<'EOF'
set -e
if false; then
	:
elif false; false; then
	:
fi
EOF
put fbsd/set-e/eval1.0 <<'EOF'
set -e
eval false || true
EOF
put fbsd/set-e/eval2.1 <<'EOF'
set -e
eval false
exit 0
EOF
put fbsd/set-e/for1.0 <<'EOF'
set -e
f() {
	for i in a b c; do
		false
		true
	done
}
f || true
EOF
put fbsd/set-e/func1.0 <<'EOF'
set -e
f() {
	false
	true
}
f || true
EOF
put fbsd/set-e/func2.1 <<'EOF'
set -e
f() {
	false
	exit 0
}
f
EOF
put fbsd/set-e/if1.0 <<'EOF'
set -e
if false; then
	:
fi
EOF
put fbsd/set-e/if2.0 <<'EOF'
set -e
# PR 28852
if true; then
	false && true
fi
exit 0
EOF
put fbsd/set-e/if3.0 <<'EOF'
set -e
if false; false; then
	:
fi
EOF
put fbsd/set-e/not1.0 <<'EOF'
set -e
! true
exit 0
EOF
put fbsd/set-e/not2.0 <<'EOF'
set -e
! false
! eval false
EOF
put fbsd/set-e/or1.0 <<'EOF'
set -e
true || false
EOF
put fbsd/set-e/or2.0 <<'EOF'
set -e
false || true
EOF
put fbsd/set-e/or3.1 <<'EOF'
set -e
false || false
exit 0
EOF
put fbsd/set-e/pipe1.1 <<'EOF'
set -e
true | false
exit 0
EOF
put fbsd/set-e/pipe2.0 <<'EOF'
set -e
false | true
EOF
put fbsd/set-e/return1.0 <<'EOF'
set -e

# PR 77067, 85267
f() {
	return 1
	true
}

f || true
exit 0
EOF
put fbsd/set-e/semi1.1 <<'EOF'
set -e
false; true
exit 0
EOF
put fbsd/set-e/semi2.1 <<'EOF'
set -e
true; false
exit 0
EOF
put fbsd/set-e/subshell1.0 <<'EOF'
set -e
(true)
EOF
put fbsd/set-e/subshell2.1 <<'EOF'
set -e
(false)
exit 0
EOF
put fbsd/set-e/until1.0 <<'EOF'
set -e
until false; do
	break
done
EOF
put fbsd/set-e/until2.0 <<'EOF'
set -e
until false; false; do
	break
done
EOF
put fbsd/set-e/until3.0 <<'EOF'
set -e
f() {
	until false; do
		false
		break
	done
}
f || true
EOF
put fbsd/set-e/while1.0 <<'EOF'
set -e
while false; do
	:
done
EOF
put fbsd/set-e/while2.0 <<'EOF'
set -e
while false; false; do
	:
done
EOF
put fbsd/set-e/while3.0 <<'EOF'
set -e
f() {
	while true; do
		false
		break
	done
}
f || true
EOF
put smoosh/shell/benchmark.fact5.out <<'EOF'
120
EOF
put smoosh/shell/benchmark.fact5.test <<'EOF'
fact() {
  n=$1
  if [ "$n" -le 0 ]
  then echo 1
  else echo $((n * $(fact $(($n-1)) ) ))
  fi
}

fact 5

timing=$(times | head -n 1)
minutes=$(echo $timing | sed 's/\([0-9]*\)m\([0-9]*\).\([0-9]*\)s.*/\1/')
seconds=$(echo $timing | sed 's/\([0-9]*\)m\([0-9]*\).\([0-9]*\)s.*/\2/')
fractional=$(echo $timing | sed 's/\([0-9]*\)m\([0-9]*\).\([0-9]*\)s.*/\3/')

echo $timing >&2

[ "$minutes" -eq 0 ] && [ "$seconds" -eq 0 ] && [ 1"$fractional" -lt 1003000 ]
EOF
put smoosh/shell/benchmark.while.out <<'EOF'
500
EOF
put smoosh/shell/benchmark.while.test <<'EOF'
x=0
while [ $x -lt 500 ]
do
    : $((x+=1))
done
echo $x

timing=$(times | head -n 1)
minutes=$(echo $timing | sed 's/\([0-9]*\)m\([0-9]*\).\([0-9]*\)s.*/\1/')
seconds=$(echo $timing | sed 's/\([0-9]*\)m\([0-9]*\).\([0-9]*\)s.*/\2/')
fractional=$(echo $timing | sed 's/\([0-9]*\)m\([0-9]*\).\([0-9]*\)s.*/\3/')

if [ "$CI" ] # lolsob
then
    target=002000
else
    target=001000
fi

[ "$minutes" -eq 0 ] && [ "$seconds" -eq 0 ] && [ 1"$fractional" -lt 1"$target" ]

EOF
put smoosh/shell/builtin.alias.empty.err </dev/null
put smoosh/shell/builtin.alias.empty.out </dev/null
put smoosh/shell/builtin.alias.empty.test <<'EOF'
set -e

alias empty=''
empty
EOF
put smoosh/shell/builtin.break.lexical.out <<'EOF'
0
post
1
post
2
post
3
post
4
post
EOF
put smoosh/shell/builtin.break.lexical.test -n <<'EOF'
brk() { break 5 2>/dev/null; echo post; }
i=0; while [ $i -lt 5 ]; do echo $i; brk; : $((i+=1)); done
EOF
put smoosh/shell/builtin.break.nonlexical.out <<'EOF'
0
EOF
put smoosh/shell/builtin.break.nonlexical.test -n <<'EOF'
set -o nonlexicalctrl 2>/dev/null
brk() { break 5 2>/dev/null; echo post; }
i=0; while [ $i -lt 5 ]; do echo $i; brk; : $((i+=1)); done
EOF
put smoosh/shell/builtin.cd.pwd.test <<'EOF'
pwd -P # resolve physical PWD
orig=$(pwd)
echo $orig $PWD
[ "$orig" = "$PWD" ] || exit 1
mkdir inner
cd inner
[ "$orig"/inner = "$PWD" ] || exit 2
[ $(pwd) = "$PWD" ] || exit 3
cd ..
[ "$orig" = "$PWD" ] || exit 4
[ $(pwd) = "$PWD" ] || exit 5
EOF
put smoosh/shell/builtin.command.ec.out <<'EOF'
0
0
EOF
put smoosh/shell/builtin.command.ec.test -n <<'EOF'
false
command -V alias >/dev/null
ec=$?
echo $ec
[ $ec -eq 0 ] || exit 1
false
x=$(command -V alias)
ec=$?
echo $ec
[ $ec -eq 0 ] || exit 2
command -V nonesuch >/dev/null && exit 3
exit 0
EOF
put smoosh/shell/builtin.command.exec.out <<'EOF'
hi
EOF
put smoosh/shell/builtin.command.exec.test -n <<'EOF'
echo hi >file
command exec 8<file
read msg <&8
echo $msg
EOF
put smoosh/shell/builtin.command.keyword.out <<'EOF'
!
while
EOF
put smoosh/shell/builtin.command.keyword.test -n <<'EOF'
# ADDTOPOSIX
set -e
command -v !
command -v while
command -V while >/dev/null 2>&1
type do >/dev/null 2>&1
EOF
put smoosh/shell/builtin.command.nospecial.err <<'EOF'
readonly: x: is read only
EOF
put smoosh/shell/builtin.command.nospecial.out <<'EOF'
?=1
EOF
put smoosh/shell/builtin.command.nospecial.test <<'EOF'
command readonly x=foo
command readonly x=bar
echo ?=$?
EOF
put smoosh/shell/builtin.command.special.assign.out <<'EOF'
unset
EOF
put smoosh/shell/builtin.command.special.assign.test -n <<'EOF'
unset x
x=whoops command :
echo ${x-unset}
EOF
put smoosh/shell/builtin.continue.lexical.out <<'EOF'
0
post
after
1
post
after
2
post
after
3
post
after
4
post
after
EOF
put smoosh/shell/builtin.continue.lexical.test -n <<'EOF'
cnt() { continue 5 2>/dev/null; echo post; }
i=0; while [ $i -lt 5 ]; do echo $i; : $((i+=1)); cnt; echo after; done
EOF
put smoosh/shell/builtin.continue.nonlexical.out <<'EOF'
0
1
2
3
4
EOF
put smoosh/shell/builtin.continue.nonlexical.test -n <<'EOF'
set -o nonlexicalctrl 2>/dev/null
cnt() { continue 2>/dev/null; echo post; }
i=0; while [ $i -lt 5 ]; do echo $i; : $((i+=1)); cnt; echo after; done
EOF
put smoosh/shell/builtin.dot.break.out <<'EOF'
a
b
c
EOF
put smoosh/shell/builtin.dot.break.test -n <<'EOF'
echo break >scr
for x in a b c
do
  echo $x
  . ./scr
done
EOF
put smoosh/shell/builtin.dot.nonexistent.ec -n <<'EOF'
1
EOF
put smoosh/shell/builtin.dot.nonexistent.err <<'EOF'
.: ./nonesuch: not found
EOF
put smoosh/shell/builtin.dot.nonexistent.out </dev/null
put smoosh/shell/builtin.dot.nonexistent.test <<'EOF'
. ./nonesuch
EOF
put smoosh/shell/builtin.dot.path.out <<'EOF'
yep
EOF
put smoosh/shell/builtin.dot.path.test <<'EOF1'
set -e

# manual cleanup to avoid prompt
mkdir p1 p2
trap 'rm -rf p1 p2' EXIT

cat >scr1 <<EOF
PATH="$(pwd)/p1:$(pwd)/p2:$PATH"
. scr2
EOF

echo 'echo nope' >p1/scr2
echo 'echo yep'  >p2/scr2

chmod -f 333 p1/scr2
chmod -f 444 p2/scr2

$TEST_SHELL scr1

EOF1
put smoosh/shell/builtin.dot.return.out <<'EOF'
always
done
EOF
put smoosh/shell/builtin.dot.return.test -n <<'EOF1'
cat >scr <<EOF
echo always
(exit 47)
return
echo never
EOF
. ./scr
[ $? -eq 47 ] || exit 1
echo done
EOF1
put smoosh/shell/builtin.dot.unreadable.out <<'EOF'
yes
done
EOF
put smoosh/shell/builtin.dot.unreadable.test -n <<'EOF'
set -e

echo echo yes >weird
. ./weird

echo echo no >weird
chmod a-r weird
! $TEST_SHELL -c '. ./weird'
rm -f weird
echo done
EOF
put smoosh/shell/builtin.echo.exitcode.out <<'EOF'
OK
OK
EOF
put smoosh/shell/builtin.echo.exitcode.test <<'EOF'
# Make sure that echo properly sets its exitcode.
echo >/dev/null && echo OK
echo >/dev/full || echo OK
EOF
put smoosh/shell/builtin.eval.break.out <<'EOF'
a
EOF
put smoosh/shell/builtin.eval.break.test <<'EOF'
for x in a b c; do echo $x; eval break; done
EOF
put smoosh/shell/builtin.eval.out <<'EOF'
starting
hi
nice
bye
EOF
put smoosh/shell/builtin.eval.test <<'EOF'
echo starting
eval echo hi
echo nice
eval "x=bye"
echo $x

EOF
put smoosh/shell/builtin.eval.trap.out <<'EOF'
ok
EOF
put smoosh/shell/builtin.eval.trap.test -n <<'EOF'
# Harald van Dijk <harald@gigawatt.nl> (2020-01-06) (inbox list)
# Subject: EXIT trap handling in subshells broken
# To: DASH shell mailing list <dash@vger.kernel.org>
# Date: Mon, 06 Jan 2020 21:57:20 +0000

eval '(trap "echo bug" EXIT)' >/dev/null
echo ok
EOF
put smoosh/shell/builtin.exec.badredir.ec <<'EOF'
1
EOF
put smoosh/shell/builtin.exec.badredir.out </dev/null
put smoosh/shell/builtin.exec.badredir.test <<'EOF'
exec 9&<-
EOF
put smoosh/shell/builtin.exec.modernish.mkfifo.loop.out <<'EOF'
0
read [hello]
EOF
put smoosh/shell/builtin.exec.modernish.mkfifo.loop.test -n <<'EOF'
[ -e pipe ] && rm pipe
mkfifo pipe
( echo hello >&8 ) 8>pipe &
command exec 8<pipe
read -r line <&8 ; echo $?
echo read [${line-UNSET}]
EOF
put smoosh/shell/builtin.exec.noargs.ec.out <<'EOF'
ok
EOF
put smoosh/shell/builtin.exec.noargs.ec.test <<'EOF'
false || command exec
echo ok
EOF
put smoosh/shell/builtin.exec.true.test <<'EOF'
exec true
false
EOF
put smoosh/shell/builtin.exit0.test <<'EOF'
exit 0
EOF
put smoosh/shell/builtin.exitcode.out <<'EOF'
Leaking commands:
Silently failing commands:
EOF
put smoosh/shell/builtin.exitcode.test <<'EOF1'
# Check if builtin commands properly set their exit codes.

high_exit() {
    return 42
}

# break, continue, exit, return and newgrp are not tested.
COMMANDS=": shift unset export readonly local times eval source exec
set trap true false pwd echo cd hash type command umask alias unalias
wait jobs read test [ printf kill getopts fg bg help history fc
ulimit"

# Check if every command sets the exit code for itself.
echo Leaking commands:
for command in $COMMANDS; do
    high_exit
    rc=$($command </dev/null >/dev/null 2>/dev/null; echo $?)
    if [ -z $rc ]; then
        # Skip if for some reason the subshell failed.
        continue
    elif [ $rc -eq 42 ]; then
        echo $command
    fi
done

# Check if any command lies about its failure.
echo Silently failing commands:
for command in $COMMANDS; do
    has_output=$($command </dev/null 2>&1 | wc -c)
    if [ $has_output -eq 0 ]; then
        continue
    fi
    true
    rc=$($command </dev/null >/dev/full 2>/dev/full; echo $?)
    if [ -z $rc ]; then
        continue
    elif [ $rc -eq 0 ]; then
        echo $command
    fi
done

# More involved cases.
export FOO=1
readonly FOO
alias foo=bar
alias baz=qux
while read command; do
    true
    rc=$($command </dev/null >/dev/full 2>/dev/full; echo $?)
    if [ -z $rc ]; then
        continue
    elif [ $rc -eq 0 ]; then
        echo $command
    fi
done <<EOF
export -p
readonly -p
type echo
command -p ''
command -v echo
command -V echo
alias
alias foo
alias foo baz
alias bar
printf "foo"
kill -l
kill -l 1
kill -l 2 3
help builtins
help version
help trace
help spec
EOF
EOF1
put smoosh/shell/builtin.export.out <<'EOF'
unset
unset
here
bye
EOF
put smoosh/shell/builtin.export.override.out <<'EOF'
x is unset
x is unset
x='5'
x='6'
x is 5
EOF
put smoosh/shell/builtin.export.override.test <<'EOF'
unset x
$TEST_UTIL/getenv x
x=4
$TEST_UTIL/getenv x
export x=5
$TEST_UTIL/getenv x
x=6 $TEST_UTIL/getenv x
echo x is ${x-unset}
EOF
put smoosh/shell/builtin.export.test <<'EOF1'
cat >scr <<'EOF'
echo ${var-unset}
EOF
$TEST_SHELL scr
var=hi
$TEST_SHELL scr
var=here $TEST_SHELL scr
export var=bye
$TEST_SHELL scr
EOF1
put smoosh/shell/builtin.export.unset.out <<'EOF'
export x
ok
EOF
put smoosh/shell/builtin.export.unset.test -n <<'EOF'
set -e
unset x
export x
export -p | grep 'export x'
echo ok
EOF
put smoosh/shell/builtin.falsetrue.test <<'EOF'
false || true
EOF
put smoosh/shell/builtin.hash.nonposix.out <<'EOF'
ok
EOF
put smoosh/shell/builtin.hash.nonposix.test -n <<'EOF'
ls                >/dev/null
hash | grep ls    >/dev/null || exit 1
touch hi
hash | grep ls    >/dev/null || exit 2
hash | grep touch >/dev/null || exit 3
hash -r
hash | grep ls    >/dev/null && exit 4
hash | grep touch >/dev/null && exit 5
echo ok
EOF
put smoosh/shell/builtin.history.nonposix.out <<'EOF'
ok
EOF
put smoosh/shell/builtin.history.nonposix.test -n <<'EOF1'
cat > scr <<EOF
history | grep history >/dev/null || exit 1
echo hi >/dev/null
history | grep echo >/dev/null || exit 2
history -c
history >hist
grep echo >/dev/null hist && exit 3
set -o nolog
history -c
echo hello >/dev/null
history >hist2
grep echo >/dev/null hist2 && exit 4
echo ok
EOF
$TEST_SHELL -i scr 2>/dev/null
EOF1
put smoosh/shell/builtin.jobs.err </dev/null
put smoosh/shell/builtin.jobs.out </dev/null
put smoosh/shell/builtin.jobs.test -n <<'EOF'
sleep 10 & pid=$!
sleep 1
jobs >job_info
grep "sleep 10" job_info >/dev/null || exit 1
grep "[1]" job_info >/dev/null || exit 2
kill $pid

rm job_info
unset j pid

sleep 10 & pid=$!
sleep 1
jobs -l >job_info
grep "sleep 10" job_info >/dev/null || exit 3
grep "[1]" job_info >/dev/null || exit 4
grep $pid job_info >/dev/null || exit 5
kill $pid

rm job_info
EOF
put smoosh/shell/builtin.kill.jobs.test <<'EOF'
sleep 5 & pid1=$!
sleep 6 & pid2=$!
start=$(date "+%s")
sleep 1
kill %1 %2 && exit 3
kill $pid1 $pid2
wait
stop=$(date "+%s")
elapsed=$((stop - start))
echo $stop - $start = $elapsed
[ $((elapsed)) -lt 3 ] || exit 1

echo setting -m
set -m
echo sleeping
jobs -l
sleep 5 & pid1=$!
sleep 6 & pid2=$!
start=$(date "+%s")
sleep 1
jobs -l
kill %1 %2
wait
stop=$(date "+%s")
elapsed=$((stop - start))
echo $stop - $start = $elapsed
[ $((elapsed)) -lt 3 ] || exit 2
EOF
put smoosh/shell/builtin.kill.signame.out <<'EOF'
plain kill
named (-TERM)
numbered (-15)
EOF
put smoosh/shell/builtin.kill.signame.test <<'EOF'
rm -f foo
set -e

trap 'touch foo' TERM

kill $$
[ -f foo ] && ! [ -s foo ]
rm foo
echo plain kill

kill -TERM $$
[ -f foo ] && ! [ -s foo ]
rm foo
echo named \(-TERM\)

kill -15 $$
[ -f foo ] && ! [ -s foo ]
rm foo
echo numbered \(-15\)
EOF
put smoosh/shell/builtin.kill0.test <<'EOF'
kill -s 0 $$
EOF
put smoosh/shell/builtin.kill0_+5.test <<'EOF'
! kill -s 0 $(($$+5))
EOF
put smoosh/shell/builtin.printf.repeat.out <<'EOF'
1 2
3 4
5 6
7 8
9 0
EOF
put smoosh/shell/builtin.printf.repeat.test -n <<'EOF'
printf '%d %d\n' 1 2 3 4 5 6 7 8 9
EOF
put smoosh/shell/builtin.pwd.exitcode.out <<'EOF'
OK
EOF
put smoosh/shell/builtin.pwd.exitcode.test <<'EOF'
# Make sure that pwd sets its exitcode.
false
pwd >/dev/null 2>/dev/null && echo OK
EOF
put smoosh/shell/builtin.readonly.assign.interactive.out <<'EOF'
bar quux
bar quux
EOF
put smoosh/shell/builtin.readonly.assign.interactive.test -n <<'EOF1'
cat >scr <<'EOF'
foo=bar
readonly -- foo
readonly -- baz=quux
echo $foo $baz >&3
foo=nope
unset baz
echo $foo $baz >&3
EOF
exec 3>&1 1>/dev/null 2>/dev/null
$TEST_SHELL -i scr
EOF1
put smoosh/shell/builtin.readonly.assign.noninteractive.ec <<'EOF'
1
EOF
put smoosh/shell/builtin.readonly.assign.noninteractive.out </dev/null
put smoosh/shell/builtin.readonly.assign.noninteractive.test <<'EOF'
readonly a=b
export a=c
echo egad
EOF
put smoosh/shell/builtin.set.-m.out <<'EOF'
hi
EOF
put smoosh/shell/builtin.set.-m.test <<'EOF'
set -m
echo hi
EOF
put smoosh/shell/builtin.set.quoted.out <<'EOF'
a
b
c
EOF
put smoosh/shell/builtin.set.quoted.test <<'EOF'
myvar='a b c'
set | grep myvar >scr
. ./scr
printf '%s\n' $myvar
EOF
put smoosh/shell/builtin.source.nonexistent.earlyexit.ec <<'EOF'
1
EOF
put smoosh/shell/builtin.source.nonexistent.earlyexit.out </dev/null
put smoosh/shell/builtin.source.nonexistent.earlyexit.test -n <<'EOF'
source not_a_thing
echo hi
exit 0
EOF
put smoosh/shell/builtin.source.nonexistent.ec -n <<'EOF'
1
EOF
put smoosh/shell/builtin.source.nonexistent.err <<'EOF'
source: nonesuch: not found
EOF
put smoosh/shell/builtin.source.nonexistent.out </dev/null
put smoosh/shell/builtin.source.nonexistent.test <<'EOF'
source nonesuch
. nonesuch
EOF
put smoosh/shell/builtin.source.setvar.out <<'EOF'
5
EOF
put smoosh/shell/builtin.source.setvar.test -n <<'EOF'
set -e

echo 'x=5' >to_source
source ./to_source
echo ${x?:unset}
rm to_source
[ "$x" -eq 5 ]
EOF
put smoosh/shell/builtin.special.redir.error.ec <<'EOF'
1
EOF
put smoosh/shell/builtin.special.redir.error.out </dev/null
put smoosh/shell/builtin.special.redir.error.test <<'EOF'
: 2>&9
echo oh no
EOF
put smoosh/shell/builtin.test.-nt.-ot.absent.test <<'EOF'
touch present
[ present -nt absent ] || exit 1
[ absent -ot present ] || exit 2
EOF
put smoosh/shell/builtin.test.bigint.out <<'EOF'
ok
EOF
put smoosh/shell/builtin.test.bigint.test -n <<'EOF'
! test -t 12323454234578326584376438
echo ok
EOF
put smoosh/shell/builtin.test.nonposix.test <<'EOF'
touch first
[ first -ef first ] || exit 3
sleep 1
touch second
[ second -nt first ] || exit 3
[ second -ot first ] && exit 4
[ first -ot second ] || exit 5
[ first -nt second ] && exit 6
mkdir up
[ first -ef up/../first ] || exit 7
[ first -ef up/../up/../second ] && exit 8
exit 0
EOF
put smoosh/shell/builtin.test.numeric.spaces.nonposix.test <<'EOF'
test " 5" -eq " 5 "
EOF
put smoosh/shell/builtin.test.symlink.test -n <<'EOF'
echo hi >file
mkdir dir
ln -s file link_file
ln -s dir link_dir
[ -e file ] && [ -e link_file ] && \
[ -f file ] && [ -f link_file ] && \
[ -e dir ] && [ -e link_dir ] && \
[ -d dir ] && [ -d link_dir ] && \
[ -L link_file ] && [ -L link_dir ]
EOF
put smoosh/shell/builtin.times.ioerror.err <<'EOF'
smoosh: times: I/O error
EOF
put smoosh/shell/builtin.times.ioerror.out <<'EOF'
?=2
EOF
put smoosh/shell/builtin.times.ioerror.test <<'EOF'
exec 3>&1
(
        trap "" PIPE
        sleep 1
        command times
        echo ?=$? >&3
) | true
EOF
put smoosh/shell/builtin.trap.chained.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01771.html
trap exit INT
trap 'true; kill -s INT $$' EXIT
false
EOF
put smoosh/shell/builtin.trap.exit.subshell.out <<'EOF'
hi
hi
bye
EOF
put smoosh/shell/builtin.trap.exit.subshell.test <<'EOF'
trap 'echo bye' EXIT
(echo hi)
echo $(echo hi)
EOF
put smoosh/shell/builtin.trap.exit3.out </dev/null
put smoosh/shell/builtin.trap.exit3.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01750.html
trap '(exit 3) && echo BUG' INT
kill -s INT $$
EOF
put smoosh/shell/builtin.trap.exitcode.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01770.html

trap 'set -o bad@option' INT
kill -s INT $$
EOF
put smoosh/shell/builtin.trap.false.out </dev/null
put smoosh/shell/builtin.trap.false.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01750.html
trap '(false) && echo BUG' INT
kill -s INT $$
EOF
put smoosh/shell/builtin.trap.kill.undef.err </dev/null
put smoosh/shell/builtin.trap.kill.undef.out </dev/null
put smoosh/shell/builtin.trap.kill.undef.test <<'EOF'
trap 'echo derp' KILL
trap 'echo nevah' 9
EOF
put smoosh/shell/builtin.trap.nested.out <<'EOF'
exit
EOF
put smoosh/shell/builtin.trap.nested.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01762.html
trap '(trap "echo exit" EXIT; :)' EXIT
EOF
put smoosh/shell/builtin.trap.noexit.out <<'EOF'
hi
EOF
put smoosh/shell/builtin.trap.noexit.test <<'EOF'
trap - 55
echo hi
EOF
put smoosh/shell/builtin.trap.redirect.out <<'EOF'
ok
EOF
put smoosh/shell/builtin.trap.redirect.test <<'EOF'
# Harald van Dijk <harald@gigawatt.nl> (2020-01-06) (list)
# Subject: EXIT trap handling in subshells broken
# To: DASH shell mailing list <dash@vger.kernel.org>
# Date: Mon, 06 Jan 2020 21:57:20 +0000

f() { (trap "echo $var" EXIT); }
var=bad
var=ok f
EOF
put smoosh/shell/builtin.trap.return.out <<'EOF'
1
EOF
put smoosh/shell/builtin.trap.return.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01792.html
trap 'f() { false; return; }; f; echo $?' EXIT
EOF
put smoosh/shell/builtin.trap.subshell.false.exit.ec <<'EOF'
1
EOF
put smoosh/shell/builtin.trap.subshell.false.exit.out </dev/null
put smoosh/shell/builtin.trap.subshell.false.exit.test <<'EOF'
trap "(false) && echo BUG" EXIT
EOF
put smoosh/shell/builtin.trap.subshell.false.out </dev/null
put smoosh/shell/builtin.trap.subshell.false.test <<'EOF'
trap "(false) && echo BUG" INT; kill -s INT $$
EOF
put smoosh/shell/builtin.trap.subshell.loud.out <<'EOF'
WEIRD
EOF
put smoosh/shell/builtin.trap.subshell.loud.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01766.html
trap '(:; exit) && echo WEIRD' EXIT; false
EOF
put smoosh/shell/builtin.trap.subshell.loud2.out <<'EOF'
HUH
WEIRD
EOF
put smoosh/shell/builtin.trap.subshell.loud2.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01766.html
trap 'set -o bad@option' INT; kill -s INT $$ && echo HUH
trap '(:; exit) && echo WEIRD' EXIT; false
EOF
put smoosh/shell/builtin.trap.subshell.quiet.out </dev/null
put smoosh/shell/builtin.trap.subshell.quiet.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01755.html
(trap '(! :) && echo BUG1' EXIT)
(trap '(false) && echo BUG2' EXIT)
(trap 'readonly foo=bar; (foo=baz) && echo BUG3' EXIT)
(trap '(set -o bad@option) && echo BUG4' EXIT)
exit 0
EOF
put smoosh/shell/builtin.trap.subshell.true.ec1.out </dev/null
put smoosh/shell/builtin.trap.subshell.true.ec1.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01761.html
trap '(true) || echo bug' EXIT; false
EOF
put smoosh/shell/builtin.trap.subshell.truefalse.out <<'EOF'
1
EOF
put smoosh/shell/builtin.trap.subshell.truefalse.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01750.html
trap '(false) && echo BUG' INT; kill -s INT $$
trap "(false) && echo BUG" EXIT
trap "(false); echo \$?" EXIT
EOF
put smoosh/shell/builtin.trap.supershell.out <<'EOF'
trap -- 'echo bye' EXIT
trap -- 'echo so long' EXIT
so long
trap -- 'echo bye' EXIT
bye
EOF
put smoosh/shell/builtin.trap.supershell.test <<'EOF'
trap 'echo bye' EXIT
(trap)
(trap 'echo so long' EXIT; trap)
(trap)
EOF
put smoosh/shell/builtin.unset.ec <<'EOF'
1
EOF
put smoosh/shell/builtin.unset.err <<'EOF'
unset: x is read-only
EOF
put smoosh/shell/builtin.unset.out <<'EOF'
unset
foo
unset
EOF
put smoosh/shell/builtin.unset.test <<'EOF'
readonly x=foo
y=bar
unset y
echo ${y-unset}
echo ${x-error}
unset y
echo ${y-unset}
unset x
EOF
put smoosh/shell/parse.emptyvar.test <<'EOF'
err=$($TEST_SHELL -c ': ${}' 2>&1 >/dev/null)
[ "$err" ]


EOF
put smoosh/shell/parse.error.out <<'EOF'
sh ok
eval ok
dot ok
EOF
put smoosh/shell/parse.error.test <<'EOF'
echo ')' >scr
$TEST_SHELL scr || echo sh ok
{ echo eval ')' | $TEST_SHELL -i ; } || echo eval ok
$TEST_SHELL -c '. ./scr' || echo dot ok
EOF
put smoosh/shell/parse.eval.error.out </dev/null
put smoosh/shell/parse.eval.error.test -n <<'EOF1'
cat >scr <<EOF
eval "if"
echo lived
EOF
$TEST_SHELL scr && exit 1
exit 0
EOF1
put smoosh/shell/semantics.-C.test -n <<'EOF1'
echo >in <<EOF
a one
a two
a one two three
four
EOF

touch out

set -o noclobber
cat <in >out
[ $? -gt 0 ] || exit 2
EOF1
put smoosh/shell/semantics.-h.nonposix.test <<'EOF'
set -h
hash -r
f() {
    ls
    touch hi
    rm hi
}
hash
hash | grep ls || exit 1
hash | grep touch || exit 2
hash | grep rm || exit 3

EOF
put smoosh/shell/semantics.arith.assign.multi.out <<'EOF'
0 0 0
EOF
put smoosh/shell/semantics.arith.assign.multi.test -n <<'EOF'
: $((x = y = z = 0))
echo $x $y $z
EOF
put smoosh/shell/semantics.arith.modernish.out <<'EOF'
ok
ok
EOF
put smoosh/shell/semantics.arith.modernish.test <<'EOF'
# from https://github.com/modernish/modernish/blob/e3b66a8b68695265b9aebd43e1de1ab3fef66e57/lib/modernish/aux/fatal.sh
i=7
j=0
case $(( ((j+=6*i)==0x2A)>0 ? 014 : 015 )) in
( 12 | 14 ) echo ok;;	# OK or BUG_NOOCTAL
( * )	echo fail; exit 1 ;;
esac
case $j in
( 42 )	echo ok;;	# BUG_NOOCTAL
( * )	echo fail; exit 1;;
esac
EOF
put smoosh/shell/semantics.arith.pos.out <<'EOF'
47
EOF
put smoosh/shell/semantics.arith.pos.test -n <<'EOF'
a=+47
[ $((a)) -eq 47 ]
echo $((a))
EOF
put smoosh/shell/semantics.arith.var.space.out <<'EOF'
8 9
EOF
put smoosh/shell/semantics.arith.var.space.test <<'EOF'
x="  8"
y=$((x + 1))
echo $x $y
EOF
put smoosh/shell/semantics.arithmetic.bool_to_num.test <<'EOF'
[ $((5>=5)) -eq 1 ]
EOF
put smoosh/shell/semantics.arithmetic.tilde.out <<'EOF'
-11
EOF
put smoosh/shell/semantics.arithmetic.tilde.test -n <<'EOF'
# bug found in POSIX testing (sh_05.ex tp357)

echo $((~10))
EOF
put smoosh/shell/semantics.assign.noglob.out <<'EOF'
*
EOF
put smoosh/shell/semantics.assign.noglob.test <<'EOF'
x='*'
echo "$x"
EOF
put smoosh/shell/semantics.assign.visible.out <<'EOF'
ok
EOF
put smoosh/shell/semantics.assign.visible.test -n <<'EOF'
set -e
x=5 y=$((x+2))
[ "$x" -eq 5 ]
# either x is treated as unset (and so y = 2) or not (and so y = 7)
[ "$y" -eq 2 ] || [ "$y" -eq 7 ]
echo ok
EOF
put smoosh/shell/semantics.background.nojobs.stdin.test <<'EOF1'
cat >scr <<EOF
set +m
exec <in
cat &
wait
EOF

echo illegible >in
$TEST_SHELL scr
EOF1
put smoosh/shell/semantics.background.out <<'EOF'
hi
bye
derp
EOF
put smoosh/shell/semantics.background.pid.test -n <<'EOF'
echo 'echo $$ > pid.out' >showpid.sh
chmod +x showpid.sh
$TEST_SHELL showpid.sh &
sleep 1
[ "$!" -eq "$(cat pid.out)" ]
EOF
put smoosh/shell/semantics.background.pipe.pid.test -n <<'EOF'
echo 'echo $$ > pid.out' >showpid.sh
chmod +x showpid.sh
true | $TEST_SHELL showpid.sh &
sleep 1
[ "$!" -eq "$(cat pid.out)" ]
EOF
put smoosh/shell/semantics.background.test -n <<'EOF'
echo hi
{ sleep 1 ; echo derp ; } &
echo bye
wait
EOF
put smoosh/shell/semantics.backtick.exit.err <<'EOF'
bar
EOF
put smoosh/shell/semantics.backtick.exit.out </dev/null
put smoosh/shell/semantics.backtick.exit.test <<'EOF'
foo=$(trap 'echo bar' EXIT)
echo $foo >&2
EOF
put smoosh/shell/semantics.backtick.fds.out <<'EOF'
0 open
1 open
2 open
3 closed
4 closed
5 closed
6 closed
7 closed
8 closed
9 closed
10 closed
11 closed
12 closed
13 closed
14 closed
15 closed
16 closed
17 closed
18 closed
19 closed
20 closed
0 open 1 open 2 open 3 closed 4 closed 5 closed 6 closed 7 closed 8 closed 9 closed 10 closed 11 closed 12 closed 13 closed 14 closed 15 closed 16 closed 17 closed 18 closed 19 closed 20 closed
EOF
put smoosh/shell/semantics.backtick.fds.test <<'EOF'
set -e
subshfds=$($TEST_UTIL/fds 0 20)
$TEST_UTIL/fds 0 20
echo $subshfds
EOF
put smoosh/shell/semantics.backtick.ppid.out <<'EOF'
pid1=pid2
ppid=subshell
EOF
put smoosh/shell/semantics.backtick.ppid.test -n <<'EOF'
set -e

pid1=$($TEST_SHELL -c 'echo $PPID')
echo $pid1 >pid1

$TEST_SHELL -c 'echo $PPID' >pid2

[ $(cat pid1) = $(cat pid2) ] || exit 2
echo pid1=pid2

(echo $PPID) >ppid
[ $PPID = $(cat ppid) ] || exit 3
echo ppid=subshell
EOF
put smoosh/shell/semantics.case.ec.out <<'EOF'
3
0
0
visible 1
0
EOF
put smoosh/shell/semantics.case.ec.test <<'EOF'
# ADDTOPOSIX

(exit 3)
echo $? # make sure we're making good ecs
case a in
    ( b ) (exit 4) ;;
    ( * ) ;; # don't alter ec
esac
echo $? # should be 3

(exit 5)
case a$(echo $?>ec) in # observe ec before entering case
    ( b ) (exit 6) ;;
esac
echo $?
[ $(cat ec) = "5" ] || exit 2 # shouldn't have been altered yet!

# make sure the ec is actually visible
false
case a in
    ( a ) echo visible $? ;;
esac

# but make sure that no match cases set the ec to 0
false
case a in
    ( b ) (exit 6) ;;
esac
echo $?

EOF
put smoosh/shell/semantics.case.escape.modernish.out <<'EOF'
good
EOF
put smoosh/shell/semantics.case.escape.modernish.test <<'EOF'
# from https://github.com/modernish/modernish/blob/e3b66a8b68695265b9aebd43e1de1ab3fef66e57/lib/modernish/aux/fatal.sh
case 'foo\
bar' in
( foo\\"
"bar )	echo good ;;
( * )	echo bad  ;;
esac
EOF
put smoosh/shell/semantics.case.escape.quotes.out <<'EOF'
Literal: OK
Unquoted: OK
Quoted: OK
EOF
put smoosh/shell/semantics.case.escape.quotes.test <<'EOF'
foo=\"
echo -n Literal: ''
case "$foo" in
    \" ) echo OK ;;
    * ) echo NOT OK ;;
esac
echo -n Unquoted: ''
case "$foo" in
    $foo ) echo OK ;;
    * ) echo NOT OK ;;
esac
echo -n Quoted: ''
case "$foo" in
    "$foo" ) echo OK ;;
    * ) echo NOT OK ;;
esac
EOF
put smoosh/shell/semantics.command-subst.ec <<'EOF'
1
EOF
put smoosh/shell/semantics.command-subst.newline.out <<'EOF'
1

2
EOF
put smoosh/shell/semantics.command-subst.newline.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01844.html
cat <<END
1
$(echo "")
2
END
EOF
put smoosh/shell/semantics.command-subst.test <<'EOF'
x=$(false)
EOF
put smoosh/shell/semantics.command.argv0.out <<'EOF'
argv[0] = "argv";
EOF
put smoosh/shell/semantics.command.argv0.test <<'EOF'
set -e

explicit=$(${TEST_UTIL}/argv)
[ "$explicit" = "argv[0] = \"${TEST_UTIL}/argv\";" ]

PATH="${TEST_UTIL}:$PATH"
inpath=$(argv)
[ "$inpath" = "argv[0] = \"argv\";" ]
argv

EOF
put smoosh/shell/semantics.command.path.ec <<'EOF'
0
EOF
put smoosh/shell/semantics.defun.ec.out <<'EOF'
0
hi
0
hello
EOF
put smoosh/shell/semantics.defun.ec.test -n <<'EOF'
# ADDTOPOSIX
false
f() { echo hi ; }
echo $?
f

false
f() { echo hello ; }
echo $?
f
EOF
put smoosh/shell/semantics.dot.glob.out <<'EOF'
../foo ./foo
EOF
put smoosh/shell/semantics.dot.glob.test -n <<'EOF'
has_dot() {
  $TEST_UTIL/readdir | grep -e '^.$' >/dev/null
}

has_dotdot() {
  $TEST_UTIL/readdir | grep -e '^..$' >/dev/null
}

mkdir -p bar/inner
touch bar/foo
touch bar/inner/foo
cd bar/inner
echo .*/foo | sort # should be ../foo and ./foo

# some FS may be weird and not give these entries... simulate!
has_dot    || echo "./foo"
has_dotdot || echo "../foo"

cd ../../
rm -r bar

# this issue is under active discussion on the POSIX mailing list

# bash, dash, yash all work
# fish, zsh fail
EOF
put smoosh/shell/semantics.empty.test </dev/null
put smoosh/shell/semantics.errexit.carryover.out <<'EOF'
It should be executed
hello
EOF
put smoosh/shell/semantics.errexit.carryover.test <<'EOF'
set -e
putsn() { echo "$@"; }
false && true
putsn "It should be executed"
false && true
/bin/echo hello
EOF
put smoosh/shell/semantics.errexit.subshell.ec <<'EOF'
1
EOF
put smoosh/shell/semantics.errexit.subshell.out <<'EOF'
1
2
3
4
5
6
EOF
put smoosh/shell/semantics.errexit.subshell.test <<'EOF'
set -o errexit
if ( echo 1; false; echo 2; set -o errexit; echo 3; false; echo 4 ); then
  echo 5;
fi
echo 6  # This is executed because the subshell just returns false
false 
echo 7
EOF
put smoosh/shell/semantics.errexit.trap.ec <<'EOF'
1
EOF
put smoosh/shell/semantics.errexit.trap.test <<'EOF'
set -e; trap "false; echo BUG" USR1; kill -s USR1 $$
EOF
put smoosh/shell/semantics.error.noninteractive.ec <<'EOF'
1
EOF
put smoosh/shell/semantics.error.noninteractive.err <<'EOF'
x: z
EOF
put smoosh/shell/semantics.error.noninteractive.test <<'EOF1'
cat <<EOF > script
unset x
y=z
echo ${x?z}
echo blargh
EOF
chmod +x script
$TEST_SHELL script
EOF1
put smoosh/shell/semantics.escaping.backslash.modernish.out <<'EOF'
good
EOF
put smoosh/shell/semantics.escaping.backslash.modernish.test <<'EOF'
# from https://github.com/modernish/modernish/blob/e3b66a8b68695265b9aebd43e1de1ab3fef66e57/lib/modernish/aux/fatal.sh
t='  ::  \on\e :\tw'\''o \th\'\''re\e :\\'\''fo\u\r:   : :  '
IFS=': '
set -- ${t}
IFS=''
t=${#},${1-U},${2-U},${3-U},${4-U},${5-U},${6-U},${7-U},${8-U},${9-U},${10-U},${11-U},${12-U}
case ${t} in
( '8,,,\on\e,\tw'\''o,\th\'\''re\e,\\'\''fo\u\r,,,U,U,U,U' \
| '9,,,\on\e,\tw'\''o,\th\'\''re\e,\\'\''fo\u\r,,,,U,U,U' )  # QRK_IFSFINAL
	echo good ;;
'8,,,\on\e,\tw'\''o,\th\'\''re\e,\\'\''fo\u\r,,,U,U,U,U') echo weird;;
( * ) echo bad ; exit 1 ;;
esac
EOF
put smoosh/shell/semantics.escaping.backslash.out <<'EOF'
foobar|&;<>()$`\"' ?*[	
EOF
put smoosh/shell/semantics.escaping.backslash.test <<'EOF'
printf '%s\t\n'  > scr \
       'printf %s\\n foobar\|\&\;\<\>\(\)\$\`\\\"\'\''\ \?\*\[\'
$TEST_SHELL scr

EOF
put smoosh/shell/semantics.escaping.heredoc.dollar.out <<'EOF'
echo \$var
echo \\\$var
EOF
put smoosh/shell/semantics.escaping.heredoc.dollar.test <<'EOF1'
cat <<EOF
echo \\\$var
EOF
cat <<'EOF'
echo \\\$var
EOF
EOF1
put smoosh/shell/semantics.escaping.newline.out -n <<'EOF'
\\n\n

\n
EOF
put smoosh/shell/semantics.escaping.newline.test <<'EOF'
printf '%s' '\\'n
printf '%s' "\n"
printf "\n"
printf '\n'
printf '\\n'
EOF
put smoosh/shell/semantics.escaping.quote.out <<'EOF'
"
#
%
&
'
(
)
*
+
,
-
.
/
:
;
<
=
>
?
@
[
]
^
_
{
|
}
~
 
done
EOF
put smoosh/shell/semantics.escaping.quote.test -n <<'EOF1'
set -e

for c in '"' '#' '%' '&' "'" '(' ')' '*' '+' ',' '-' '.' '/' ':' \
    	 ';' '<' '=' '>' '?' '@' '[' ']' '^' '_' '{' '|' '}' '~' ' '
do
        cat >script <<EOF
        x=\`printf '%s' \\$c\`; printf '%s\\n' "\$x"
EOF
        echo "$c"
        $TEST_SHELL script >out
        [ $? -eq 0 ] && [ "$c" = "$(cat out)" ]
done
echo done
EOF1
put smoosh/shell/semantics.escaping.single.out <<'EOF'
line one
line two
"line".${PATH}.\'three\'\xline four
EOF
put smoosh/shell/semantics.escaping.single.test <<'EOF'
# cf tp399
cat <<weirdo
line one
line two
"line".\${PATH}.\'three\'\\x\
line four
weirdo
EOF
put smoosh/shell/semantics.eval.makeadder.out <<'EOF'
6
11
EOF
put smoosh/shell/semantics.eval.makeadder.test <<'EOF'
makeadder() {
    eval "adder() { echo \$((\$1 + $1)) ; }"
}

makeadder 5
adder 1
makeadder 10
adder 1
EOF
put smoosh/shell/semantics.evalorder.fun.out <<'EOF'
got redir
unset after function call
redir exists
EOF
put smoosh/shell/semantics.evalorder.fun.test <<'EOF'
# bash: assign
# yash, dash, smoosh: redir
# ADDTOPOSIX
show() { echo "got ${EFF-unset}"; }
unset x
EFF=${x=assign} show 2>${x=redir}
echo ${EFF-unset after function call}
[ -f assign ] && echo assign exists && rm assign
[ -f redir ] && echo redir exists && rm redir
EOF
put smoosh/shell/semantics.expansion.heredoc.backslash.out <<'EOF'
an escaped \[bracket]
should \ work just fine
exit $?
EOF
put smoosh/shell/semantics.expansion.heredoc.backslash.test -n <<'EOF1'
cat <<EOF
an escaped \\[bracket]
should \\ work just fine
EOF
cat <<EOF
exit \$?
EOF
EOF1
put smoosh/shell/semantics.expansion.quotes.adjacent.out <<'EOF'
a/b a/c
a/b a/c
a/b a/c
foo*[/crazy foo*[/weird foo*[/wild
foo*[/weird foo*[/wild
EOF
put smoosh/shell/semantics.expansion.quotes.adjacent.test -n <<'EOF'
mkdir a
touch a/b
touch a/c
echo a/*
echo "a"/*
echo 'a'/*
mkdir "foo*["
touch "foo*["/weird
touch "foo*["/wild
touch "foo*["/crazy
echo "foo*["/*
echo "foo*["/[wz]*
EOF
put smoosh/shell/semantics.expansion.substring.out <<'EOF'
a
EOF
put smoosh/shell/semantics.expansion.substring.test <<'EOF'
FOO="\\a"
echo ${FOO#*\\}
EOF
put smoosh/shell/semantics.for.readonly.out <<'EOF'
a
EOF
put smoosh/shell/semantics.for.readonly.test <<'EOF'
# ADDTOPOSIX
(for x in a b c; do echo $x; readonly x; done) && exit 1
exit 0
EOF
put smoosh/shell/semantics.fun.error.restore.out <<'EOF'
arg1
<a>
<b>
<c>
EOF
put smoosh/shell/semantics.fun.error.restore.test <<'EOF'
set -u

f() {
    echo $1
    echo <none
}

set -- a b c
f arg1 arg2
printf '<%s>\n' "$@"
EOF
put smoosh/shell/semantics.ifs.combine.ws.out <<'EOF'
x 5 12
x 5 12
EOF
put smoosh/shell/semantics.ifs.combine.ws.test -n <<'EOF'
unset IFS 
echo                  > spaced
printf "%b" '\tx'    >> spaced
echo                 >> spaced
echo "          5"   >> spaced
printf '%b' ' 12\t ' >> spaced
echo `cat spaced`
IFS=$(printf '%b' ' \n\t')
echo `cat spaced`
EOF
put smoosh/shell/semantics.interactive.expansion.exit.out <<'EOF'
hello
EOF
put smoosh/shell/semantics.interactive.expansion.exit.test <<'EOF'
PS1="" $TEST_SHELL -i -c 'echo ${x?alas, poor yorick}; echo hello; exit'
EOF
put smoosh/shell/semantics.kill.traps.err </dev/null
put smoosh/shell/semantics.kill.traps.out </dev/null
put smoosh/shell/semantics.kill.traps.test <<'EOF'
trap "echo hi" TERM
sleep 10 &
pid=$!
sleep 1
kill $pid
[ "$?" -eq 0 ] || exit 1
sleep 1
wait $pid
[ "$?" -ge 128 ] || exit 2

EOF
put smoosh/shell/semantics.length.out <<'EOF'
ab3cd
EOF
put smoosh/shell/semantics.length.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01749.html
v=abc; echo ab${#v}cd
EOF
put smoosh/shell/semantics.monitoring.ttou.out <<'EOF'
all good
EOF
put smoosh/shell/semantics.monitoring.ttou.test <<'EOF'
# id:20201221162442.GA26001@stack.nl
# Jilles Tjoelker <jilles@stack.nl> (2020-12-21) (list)
# Subject: Re: dash 0.5.11.2, busybox sh 1.32.0, FreeBSD 12.2 sh: spring TTOU but should not i think
# To: Harald van Dijk <harald@gigawatt.nl>
# Cc: Steffen Nurpmeso <steffen@sdaoden.eu>, DASH shell mailing list <dash@vger.kernel.org>, Denys Vlasenko <vda.linux@googlemail.com>
# Date: Mon, 21 Dec 2020 17:24:42 +0100

$TEST_SHELL -c  "( $TEST_SHELL -c 'trap echo\ TTOU TTOU; set -m; echo all good' )"
EOF
put smoosh/shell/semantics.no-command-subst.test <<'EOF'
false ; x=hi
EOF
put smoosh/shell/semantics.noninteractive.expansion.exit.ec -n <<'EOF'
1
EOF
put smoosh/shell/semantics.noninteractive.expansion.exit.test <<'EOF'
unset x
echo ${x?alas, poor yorick}
EOF
put smoosh/shell/semantics.pattern.bracket.quoted.out <<'EOF'
OK
UNQUOTED
EOF
put smoosh/shell/semantics.pattern.bracket.quoted.test <<'EOF'
# from https://github.com/modernish/modernish/blob/e3b66a8b68695265b9aebd43e1de1ab3fef66e57/lib/modernish/aux/fatal.sh
t='ab]cd'
case c in
( *["${t}"]* )
	case e in
	( *[!"${t}"]* ) echo OK;;
	( * ) echo FAILED inner ;;
	esac ;;
( * )	echo FAILED outer ;;
esac

case \" in
( *["${t}"]* ) echo QUOTED ;;
( * )	echo UNQUOTED ;;
esac
EOF
put smoosh/shell/semantics.pattern.hyphen.out <<'EOF'
file-
file-
file-
file-
filea
filea
filea
EOF
put smoosh/shell/semantics.pattern.hyphen.test -n <<'EOF'
touch file-
touch filea

echo file[-123]
echo file[123-]
echo file[[.-.]]
echo file[[=-=]]
echo file[!-123]
echo file[[:alpha:]]
echo file[a-z]
EOF
put smoosh/shell/semantics.pattern.modernish.test <<'EOF'
# from https://github.com/modernish/modernish/blob/e3b66a8b68695265b9aebd43e1de1ab3fef66e57/lib/modernish/aux/fatal.sh
t='  ::  \on\e :\tw'\''o \th\'\''re\e :\\'\''fo\u\r:   : :  '
IFS=': '
set -- ${t}
IFS=''
t=${#},${1-U},${2-U},${3-U},${4-U},${5-U},${6-U},${7-U},${8-U},${9-U},${10-U},${11-U},${12-U}
printf "%s\n" "$t"
case ${t} in
( '8,,,\on\e,\tw'\''o,\th\'\''re\e,\\'\''fo\u\r,,,U,U,U,U' \
| '9,,,\on\e,\tw'\''o,\th\'\''re\e,\\'\''fo\u\r,,,,U,U,U' )  # QRK_IFSFINAL
	echo good ;;
'8,,,\on\e,\tw'\''o,\th\'\''re\e,\\'\''fo\u\r,,,U,U,U,U') echo weird;;
( * ) echo bad ; exit 1 ;;
esac
EOF
put smoosh/shell/semantics.pattern.rightbracket.out <<'EOF'
file]
file]
file]
filea
filea
filea
EOF
put smoosh/shell/semantics.pattern.rightbracket.test -n <<'EOF'
touch file]
touch filea

echo file[]123]
echo file[[.].]]
echo file[[=]=]]
echo file[!]123]
echo file[[:alpha:]]
echo file[a-z]
EOF
put smoosh/shell/semantics.pipe.chained.out <<'EOF'
works
EOF
put smoosh/shell/semantics.pipe.chained.test <<'EOF'
c="echo works"
for n in $(seq 1 10)
do
        c="$c | { read x; echo \$x; }"
done

eval $c 2>err
[ -e err ] && ! [ -s err ] || exit 2
EOF
put smoosh/shell/semantics.quote.backslash.out <<'EOF'
[]
\[]
\[]
EOF
put smoosh/shell/semantics.quote.backslash.test <<'EOF'
echo []
echo '\[]'
echo "\[]"
EOF
put smoosh/shell/semantics.quote.tilde.out <<'EOF'
~
EOF
put smoosh/shell/semantics.quote.tilde.test -n <<'EOF'
echo "~"
EOF
put smoosh/shell/semantics.redir.close.ec <<'EOF'
1
EOF
put smoosh/shell/semantics.redir.close.out </dev/null
put smoosh/shell/semantics.redir.close.test <<'EOF'
# https://www.spinics.net/lists/dash/msg01775.html
{ exec 8</dev/null; } 8<&-; : <&8 && echo "oops, still open"
EOF
put smoosh/shell/semantics.redir.fds.out <<'EOF'
0 open
1 open
2 open
3 closed
4 closed
5 closed
6 closed
7 closed
8 closed
9 closed
0 open
1 open
2 open
3 open
4 closed
5 closed
6 closed
7 closed
8 closed
9 closed
EOF
put smoosh/shell/semantics.redir.fds.test <<'EOF'
$TEST_UTIL/fds
exec 3>&1
$TEST_UTIL/fds
EOF
put smoosh/shell/semantics.redir.from.test -n <<'EOF'
set -e
echo hi >file
[ -s file ]
read x <file
[ "$x" = "hi" ]
rm file
EOF
put smoosh/shell/semantics.redir.indirect.out <<'EOF'
ok
EOF
put smoosh/shell/semantics.redir.indirect.test -n <<'EOF'
f() {
    echo message >&2
}

msg=$(f 2>&1)
[ "$msg" = "message" ] || exit 1

unset msg
x=1
msg=$(f 2>&$x)
[ "$msg" = "message" ] || exit 2

echo ok
EOF
put smoosh/shell/semantics.redir.nonregular.out <<'EOF'
ok
EOF
put smoosh/shell/semantics.redir.nonregular.test <<'EOF'
set -C
: >/dev/null || exit 2
echo ok
EOF
put smoosh/shell/semantics.redir.to.test -n <<'EOF'
set -e
echo hi >file
[ -s file ]
[ "$(cat file)" = "hi" ]
rm file
EOF
put smoosh/shell/semantics.redir.toomany.test -n <<'EOF'
c="echo hi"
for n in $(seq 3 10)
do
        c="{ $c; echo hi; } >file_$n"
done

eval $c 2>err
[ -e err ] && ! [ -s err ] || exit 2

rm file_* err

MAX=$(ulimit >/dev/null 2>&1 && ulimit -n 2>/dev/null || echo 10000)

# don't even bother if the FD limit is too high (256 on some macOS)
[ "$MAX" -lt 300 ] || exit 0

c="echo hi"
for n in $(seq 3 $MAX)
do
        c="{ $c; echo hi; } >file_$n"
done

eval $c 2>err
[ -s err ] || exit 3
rm file_*
EOF
put smoosh/shell/semantics.return.and.out <<'EOF'
5
EOF
put smoosh/shell/semantics.return.and.test <<'EOF'
f() {
  return 5 && echo fail passthrough
}
f
echo $?

EOF
put smoosh/shell/semantics.return.if.out <<'EOF'
5
6
EOF
put smoosh/shell/semantics.return.if.test -n <<'EOF'
# id:ce0c3ef7-66a9-08de-546f-d8ef8263b6da@gigawatt.nl
# from Harald van Dijk

f() {
  if ! return 5
  then echo fail then; exit
  else echo fail else; exit
  fi
}
f
echo $?

g() {
  if return 6
  then echo fail then2; exit
  else echo fail else2; exit
  fi     
}
g
echo $?
EOF
put smoosh/shell/semantics.return.not.test <<'EOF'
f() {
  ! return 5
  echo fail passthrough
}
f
echo $?

EOF
put smoosh/shell/semantics.return.or.out <<'EOF'
5
EOF
put smoosh/shell/semantics.return.or.test <<'EOF'
f() {
  return 5 || echo fail passthrough
}
f
echo $?

EOF
put smoosh/shell/semantics.return.trap.out <<'EOF'
FOO
EOF
put smoosh/shell/semantics.return.trap.test <<'EOF'
# Robert Elz <kre@munnari.OZ.AU> (2020-03-16) (inbox list unread)
# Subject: Re: XCU: 'exit' trap condition [was:Re: XCU: 'return' from subshell]
# To: Joerg Schilling <Joerg.Schilling@fokus.fraunhofer.de>
# Cc: fieldhouse@gmx.net, austin-group-l@opengroup.org
# Date: Mon, 16 Mar 2020 22:15:10 +0700

f() ( trap "echo FOO" EXIT; return 5; echo BAR )
f
EOF
put smoosh/shell/semantics.return.while.out <<'EOF'
5
6
EOF
put smoosh/shell/semantics.return.while.test -n <<'EOF'
f() {
    while return 5
    do  
        echo fail while
        break
    done    
}
f
echo $?

g() {
    while ! return 6
    do  
        echo fail while
        break
    done    
}
g
echo $?
EOF
put smoosh/shell/semantics.simple.link.out <<'EOF'
hi
hi
cmd.sh
link.sh
EOF
put smoosh/shell/semantics.simple.link.test -n <<'EOF'
set -e
echo 'echo hi' >cmd.sh
chmod +x cmd.sh
ln -s cmd.sh link.sh
OLDPATH=$PATH
PATH=.
[ -x cmd.sh ]
[ -L link.sh ]
cmd.sh  # command works
link.sh # symlink works
PATH=$OLDPATH
ls
rm cmd.sh link.sh
EOF
put smoosh/shell/semantics.slash.glob.out <<'EOF'
OK
EOF
put smoosh/shell/semantics.slash.glob.test <<'EOF'
arg_len() {
    echo $#
}

trap 'rm -r foo' EXIT

mkdir foo
touch foo/a foo/b foo/c
[ "$(arg_len foo//*)" -eq 3 ] && echo OK
EOF
put smoosh/shell/semantics.special.assign.visible.nonposix.out <<'EOF'
5 7
EOF
put smoosh/shell/semantics.special.assign.visible.nonposix.test <<'EOF'
x=5 y=$((x+2)) :
echo $x $y
EOF
put smoosh/shell/semantics.splitting.ifs.out <<'EOF'
  1   2   3 
EOF
put smoosh/shell/semantics.splitting.ifs.test -n <<'EOF1'
cat << EOF > input
-,1-,-2,-,3,-
EOF

IFS="-,"
echo `cat input`
EOF1
put smoosh/shell/semantics.subshell.background.traps.out <<'EOF'
INT sleeping...
QUIT sleeping...
EOF
put smoosh/shell/semantics.subshell.background.traps.test -n <<'EOF'
(trap - INT; echo INT sleeping...; sleep 10; echo INT awake) & pid=$!
sleep 1
kill $pid
wait $pid
ec=$?
[ "$ec" -ge 128 ] || exit 1
(trap - QUIT; echo QUIT sleeping...; sleep 10; echo QUIT awake) & pid=$!
sleep 1
kill -QUIT $pid
wait $pid
ec=$?
[ "$ec" -ge 128 ] || exit 2
EOF
put smoosh/shell/semantics.subshell.break.err </dev/null
put smoosh/shell/semantics.subshell.break.out <<'EOF'
a
b
EOF
put smoosh/shell/semantics.subshell.break.test -n <<'EOF'
# https://www.spinics.net/lists/dash/msg01773.html
for x in a b
  do
    (
      for y in c d
      do
        break 2
      done
      echo $x
    )
  done 
EOF
put smoosh/shell/semantics.subshell.redirect.out </dev/null
put smoosh/shell/semantics.subshell.redirect.test <<'EOF'
# Ensure that the exit trap is ran with the redirections still active.
(trap 'echo foo' EXIT) >/dev/null
EOF
put smoosh/shell/semantics.subshell.return.out <<'EOF'
42
EOF
put smoosh/shell/semantics.subshell.return.test <<'EOF'
# Stephane Chazelas <stephane@chazelas.org> (2020-03-11) (list)
# Subject: Re: XCU: 'return' from subshell
# To: Robert Elz <kre@munnari.OZ.AU>
# Cc: Dirk Fieldhouse <fieldhouse@gmx.net>, Austin Group <austin-group-l@opengroup.org>
# Date: Wed, 11 Mar 2020 06:37:41 +0000

f() { (return 42; echo x); echo "$?"; }; f
EOF
put smoosh/shell/semantics.subshell.return2.out <<'EOF'
foo
bar
EOF
put smoosh/shell/semantics.subshell.return2.test -n <<'EOF'
# Dirk Fieldhouse <fieldhouse@gmx.net> (2020-03-11) (junk list)
# Subject: Re: XCU: 'return' from subshell
# To: Austin Group <austin-group-l@opengroup.org>
# Cc: chet.ramey@case.edu, Robert Elz <kre@munnari.OZ.AU>
# Date: Wed, 11 Mar 2020 14:49:31 +0000

f1() {
   ( echo foo; return )
   echo bar
}

f1
EOF
put smoosh/shell/semantics.substring.quotes.out <<'EOF'
OK1
OK2
EOF
put smoosh/shell/semantics.substring.quotes.test <<'EOF'
FOO="a?b"
[ "${FOO#*"?"}" = b ] && echo OK1
FOO="abc"
[ "${FOO#"${FOO%???}"}" = "$FOO" ] && echo OK2
EOF
put smoosh/shell/semantics.tilde.colon.test -n <<'EOF1'
tilde=~
cat << EOF >test_script
var=:~
[ "\$var" = ":$tilde" ]
EOF
chmod +x test_script
$TEST_SHELL test_script
EOF1
put smoosh/shell/semantics.tilde.no-exp.out <<'EOF'
hi:~
hello:~
EOF
put smoosh/shell/semantics.tilde.no-exp.test <<'EOF'
echo hi:~
x=:
echo hello${x}~
EOF
put smoosh/shell/semantics.tilde.quoted.out <<'EOF'
weird    times
a*
EOF
put smoosh/shell/semantics.tilde.quoted.prefix.out <<'EOF'
ok
EOF
put smoosh/shell/semantics.tilde.quoted.prefix.test -n <<'EOF'
# ADDTOPOSIX

set -e
tilde=$(echo ~)
[ "$tilde" = "$HOME" ] || exit 1

funny='~'\""$LOGNAME"\"
exp=$(eval "echo $funny")
[ "$exp" = "~$LOGNAME" ] || exit 2

[ ~/ = "$HOME"/ ] || exit 3

echo ok
EOF
put smoosh/shell/semantics.tilde.quoted.test <<'EOF'
HOME="weird    times"
printf '%s\n' ~
touch a1 a2 a3
HOME='a*'
printf '%s\n' ~
EOF
put smoosh/shell/semantics.tilde.sep.out <<'EOF'
ok
EOF
put smoosh/shell/semantics.tilde.sep.test -n <<'EOF'
# ADDTOPOSIX
[ ~: = "~:" ] || exit 1

y=~
[ $y = "$HOME" ] || exit 2

y=~/foo
[ $y = "$HOME/foo" ] || exit 3

y=~:foo
[ $y = "$HOME:foo" ] || exit 4

y=foo:~
[ $y = "foo:$HOME" ] || exit 5

y=foo:~:bar
[ $y = "foo:$HOME:bar" ] || exit 6

echo ok
EOF
put smoosh/shell/semantics.tilde.test <<'EOF'
echo ~ >tilde.out
var=~
echo $var > var.out
[ -f tilde.out ] && [ -f var.out ] && \
[ -s tilde.out ] && [ -s var.out ] && \
[ $(cat tilde.out) = $(cat var.out) ] && \
[ $(cat tilde.out) != "~" ]

EOF
put smoosh/shell/semantics.traps.async.out <<'EOF'
done
EOF
put smoosh/shell/semantics.traps.async.test <<'EOF'
( 
kill -s QUIT $($TEST_SHELL -c 'echo $PPID') || exit 1 
echo done
) &
wait $!
EOF
put smoosh/shell/semantics.traps.inherit.out <<'EOF'
got SIGINT
sending SIGQUIT
131
EOF
put smoosh/shell/semantics.traps.inherit.test <<'EOF'
( 
	trap "echo got SIGINT" INT

        # default trap will mean we actually get a QUIT, overriding the default on asyncs
	trap - QUIT

	mypid=$($TEST_SHELL -c 'echo $PPID')

        # this can be overridden
	kill -s INT "$mypid" || exit 4

        # will kill this shell, 
	echo "sending SIGQUIT"
	kill -s QUIT "$mypid" || exit 2
	exit 0
) &
wait $!
echo $?

EOF
put smoosh/shell/semantics.var.alt.null.out <<'EOF'
2
3
EOF
put smoosh/shell/semantics.var.alt.null.test <<'EOF'
f() { echo $# ; }
unset -v nonesuch
f ${nonesuch+nonempty} a b

x=foo
f ${x+hi} a b
EOF
put smoosh/shell/semantics.var.alt.nullifs.out <<'EOF'
<a>
<b>
2
<a>
<b>
3
<uhoh>
<a>
<b>
EOF
put smoosh/shell/semantics.var.alt.nullifs.test <<'EOF'
IFS=
printf '<%s>\n' ${x+uhoh} a b

f() { echo $#; printf '<%s>\n' "$@" ; }
f ${x+uhoh} a b

x=hi
f ${x+uhoh} a b

EOF
put smoosh/shell/semantics.var.builtin.nonspecial.out <<'EOF'
unset
unset
EOF
put smoosh/shell/semantics.var.builtin.nonspecial.test <<'EOF'
# successful command
unset x
x=value command alias >/dev/null 2>&1
echo ${x-unset}
test -z "$x" || exit 1

# unsuccessful command
unset x
x=value command alias -: >/dev/null 2>&1
echo ${x-unset}
test -z "$x" || exit 2
EOF
put smoosh/shell/semantics.var.dashu.out <<'EOF'
passed
EOF
put smoosh/shell/semantics.var.dashu.test <<'EOF'
unset nonesuch
$TEST_SHELL -u -c 'echo $nonesuch' && exit 1
$TEST_SHELL -u -c 'echo $3' && exit 1
$TEST_SHELL -u -c 'var=val ; echo ${var+$nonesuch}' && exit 1
$TEST_SHELL -u -c 'echo $(($nonesuch + 1))' && exit 1
$TEST_SHELL -u -c 'echo $((nonesuch + 1))' && exit 1
$TEST_SHELL -u -c 'echo ${#nonesuch}' && exit 1
echo passed
EOF
put smoosh/shell/semantics.var.format.tilde.test -n <<'EOF'
unset x
tilde=~
: ${x:=~}
ext=~/foo
[ "$x" = "$tilde" ] && \
[ "/foo" = ${ext#~} ] && \
! $TEST_SHELL -c 'echo ${y?~}'
EOF
put smoosh/shell/semantics.var.ifs.sep.out <<'EOF'
1,2,3
EOF
put smoosh/shell/semantics.var.ifs.sep.test <<'EOF'
IFS=", "
set 1 2 3
echo "$*"
EOF
put smoosh/shell/semantics.var.star.emptyifs.out <<'EOF'
<a>
<b  e   e>
<c>
<HIa>
<b  e   e>
<cBYE>
EOF
put smoosh/shell/semantics.var.star.emptyifs.test <<'EOF'
IFS=""
bee="b  e   e"
set a "$bee" c

printf '<%s>\n' $*
printf '<%s>\n' HI$*BYE
EOF
put smoosh/shell/semantics.var.star.format.out <<'EOF'
<a:s p  aces:b:c:and	tabs
 and newlines>
<a s p  aces b c and	tabs
 and newlines>
EOF
put smoosh/shell/semantics.var.star.format.test <<'EOF'
sp="s p  aces"
tn=$(printf '%b' 'and\ttabs\n and newlines')
set -- a "$sp" b c "$tn"
IFS=": "
printf '<%s>\n' "${var=$*}"
unset var
unset IFS
printf '<%s>\n' "${var=$*}"
EOF
put smoosh/shell/semantics.var.unset.nofield.test -n <<'EOF'
count() { echo $#; }
[ $(count a $nonesuch b) -eq 2 ]
EOF
put smoosh/shell/semantics.varassign.out <<'EOF'
bar
bar
EOF
put smoosh/shell/semantics.varassign.test <<'EOF'
# https://git.kernel.org/pub/scm/utils/dash/dash.git/commit/?id=a29e9a1738a4e7040211842f3f3d90e172fa58ce
foo=bar; echo ${foo=BUG}; echo $foo
EOF
put smoosh/shell/semantics.variable.escape.length.out <<'EOF'
1
2
EOF
put smoosh/shell/semantics.variable.escape.length.test <<'EOF'
x=\n
echo ${#x}
x=\\n
echo ${#x}
EOF
put smoosh/shell/semantics.wait.alreadydead.out <<'EOF'
kill ec: 0
wait ec: 143
EOF
put smoosh/shell/semantics.wait.alreadydead.test <<'EOF'
sleep 10 &
pid=$!
sleep 1
kill $pid
echo kill ec: $?
sleep 1
wait $pid
echo wait ec: $?
EOF
put smoosh/shell/semantics.while.out <<'EOF'
1
2
3
4
5
6
7
8
9
10
0
1
2
3
4
5
6
7
8
9
10
1
EOF
put smoosh/shell/semantics.while.test <<'EOF'
i=0
while [ $i -lt 10 ]
do
    i=$((i + 1))
    echo $i
done
echo $?
i=0
while [ $i -lt 10 ]
do
    i=$((i + 1))
    echo $i;
    false
done
echo $?
EOF
put smoosh/shell/sh.-c.arg0.out <<'EOF'
i am ./scr, hear me roar
EOF
put smoosh/shell/sh.-c.arg0.test -n <<'EOF1'
cat > scr <<EOF
echo "i am \$0, hear me roar"
EOF
$TEST_SHELL -c '. "$0"' ./scr
EOF1
put smoosh/shell/sh.env.ppid.test <<'EOF'
$TEST_SHELL -c 'echo $PPID' >ppid
inner=$(cat ppid)
rm ppid
[ "$inner" -eq "$$" ]

EOF
put smoosh/shell/sh.file.weirdness.out <<'EOF'
works
works
EOF
put smoosh/shell/sh.file.weirdness.test <<'EOF'
$TEST_SHELL nonesuch
echo 'echo works' >scr
$TEST_SHELL scr
$TEST_SHELL ./scr
echo 'echo nope' >scr
chmod -r scr
$TEST_SHELL ./scr && exit 1
$TEST_SHELL scr && exit 1
rm -f scr

EOF
put smoosh/shell/sh.interactive.ps1.err -n <<'EOF'
$ 
EOF
put smoosh/shell/sh.interactive.ps1.test <<'EOF'
echo exit | PS1='$ ' $TEST_SHELL -i
EOF
put smoosh/shell/sh.monitor.bg.test <<'EOF'
set -m

start=$(date "+%s")
sleep 3 & pid=$!
kill -TSTP $pid
jobs -l
stop=$(date "+%s")
elapsed=$((stop - start))
echo $stop - $start = $elapsed
[ $((elapsed)) -lt 2 ] || exit 1

jobs -l
bg >output

stop2=$(date "+%s")
elapsed=$((stop2 - start))
echo $stop2 - $start = $elapsed
[ $((elapsed)) -lt 2 ] || exit 2
grep "[1]" output || exit 3
grep "sleep 3" output || exit 4

wait

stop3=$(date "+%s")
elapsed=$((stop3 - start))
echo $stop3 - $start = $elapsed
[ $((elapsed)) -ge 3 ] || exit 5
EOF
put smoosh/shell/sh.monitor.fg.test <<'EOF'
set -m

start=$(date "+%s")
sleep 3 & pid=$!
kill -TSTP $pid
jobs -l
stop=$(date "+%s")
elapsed=$((stop - start))
echo $stop - $start = $elapsed
[ $((elapsed)) -lt 2 ] || exit 1

jobs -l
fg >output

stop2=$(date "+%s")
elapsed=$((stop2 - start))
echo $stop2 - $start = $elapsed
[ $((elapsed)) -ge 3 ] || exit 2
grep "sleep 3" output || exit 3
EOF
put smoosh/shell/sh.ps1.override.err -n <<'EOF'
$ $ $ PS1$ PS1$ PS1$ 
EOF
put smoosh/shell/sh.ps1.override.out <<'EOF'
hi
bye
hi
bye
EOF
put smoosh/shell/sh.ps1.override.test -n <<'EOF1'
unset PS1
$TEST_SHELL -i <<EOF
echo hi
echo bye
EOF

PS1='PS1$ ' $TEST_SHELL -i <<EOF
echo hi
echo bye
EOF
EOF1
put smoosh/shell/sh.set.ifs.out <<'EOF'
 	
 	
 	
EOF
put smoosh/shell/sh.set.ifs.test <<'EOF1'
cat >show_ifs <<EOF
printf '%s' "$IFS"
EOF
$TEST_SHELL show_ifs || exit 1
export IFS=123
$TEST_SHELL show_ifs || exit 1
IFS=abc $TEST_SHELL show_ifs || exit 1
EOF1
put smoosh/util/argv.c <<'EOF'
#include <stdio.h>

int main(int argc, char *argv[]) {
  for (int i = 0; i < argc; i += 1) {
    printf("argv[%d] = \"%s\";\n", i, argv[i]);
  }

  return 0;
}
EOF
put smoosh/util/fds.c <<'EOF'
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

#define FD_START 0
#define FD_STOP  9

void usage(char *prog) {
  fprintf(stderr, "usage: %s [start_fd] [end_fd]\n", prog);
  exit(1);
}

void parse(char *desc, char *s, int *dst, int def) {
  if (!sscanf(s, "%d", dst)) {
    fprintf(stderr, "couldn't parse '%s' as a number, defaulting to %d for %s",
            s, def, desc);
  }
}

int main(int argc, char** argv) {
  if (argc > 3) {
    usage(argv[0]);
  }

  int start_fd = FD_START;
  if (argc >= 2) {
    parse("start fd", argv[1], &start_fd, FD_START);
  }

  int stop_fd = FD_STOP;
  if (argc == 3) {
    parse("stop fd", argv[2], &stop_fd, FD_STOP);
  }

  for (int fd = start_fd; fd <= stop_fd; fd += 1) {
    int res = fcntl(fd, F_GETFD);

    if (res < 0) {
      if (errno == EBADF) {
        printf("%d closed\n", fd);
      } else {
        char *msg = strerror(errno);
        printf("%d error: %s\n", fd, msg);
      }
    } else {
      printf("%d open\n", fd);
    }

  }

  return 0;
}
EOF
put smoosh/util/getenv.c <<'EOF'
#include <stdlib.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
  for (int i = 1; i < argc; i += 1) {
    char *var = argv[i];
    char *val = getenv(var);
    if (NULL == val) {
      printf("%s is unset\n", var);
    } else {
      printf("%s='%s'\n", var, val);
    }
  }
}
EOF
put smoosh/util/readdir.c <<'EOF'
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {

  char *dir_path;
  if (argc == 1) {
    dir_path = ".";
  } else if (argc == 2) {
    dir_path = argv[1];
  } else {
    fprintf(stderr, "usage: %s [directory]\n", argv[0]);
    exit(2);
  }

  DIR *dir = opendir(dir_path);

  if (NULL == dir) {
    fprintf(stderr, "Couldn't open '%s'\n", dir_path);
    exit(1);
  }

  struct dirent *entry;
  while ( (entry = readdir(dir)) ) {
    printf("%s\n", entry->d_name);
  }

  return 0;
}
EOF
put yash/run-test.sh <<'EOF'
# Runs one yash *-p.tst file against the shell under test. This is a
# small re-implementation of the interface of yash's tests/run-test.sh:
# test_[oOeEx]* aliases, setup, testee, $TESTEE and the "posix" and
# "skip" variables. Results are printed in test.sh's format and one
# line per test case (P, F or S) is appended to the counts file.
#
# usage: sh run-test.sh testee file.tst first-test-number counts-file
set -Ceu
umask u+rwx

testee=$1 test_file=$2 first=$3 counts=$4
use_valgrind="false"
nl='
'

eprintf() {
    printf "$@" >&2
}

absolute()
case "$1" in
    (/*)
        printf '%s\n' "$1";;
    (*)
        printf '%s/%s' "${PWD%/}" "$1";;
esac

ulimit -c 0 2>/dev/null || :
exec </dev/null 3>&- 4>&- 5>&-
cd -L .

export LC_CTYPE="${LC_ALL-${LC_CTYPE-${LANG-}}}"
export LANG=C
unset -v CDPATH COLUMNS COMMAND COMMAND_NOT_FOUND_HANDLER DIRSTACK ECHO_STYLE
unset -v ENV FCEDIT HANDLED HISTFILE HISTRMDUP HISTSIZE HOME IFS LC_ALL
unset -v LC_COLLATE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME LINES MAIL
unset -v MAILCHECK MAILPATH NLSPATH OLDPWD POST_PROMPT_COMMAND PROMPT_COMMAND
unset -v PS1 PS1R PS1S PS2 PS2R PS2S PS3 PS3R PS3S PS4 PS4R PS4S
unset -v RANDOM TERM XDG_CONFIG_HOME YASH_AFTER_CD YASH_LE_TIMEOUT YASH_VERSION
unset -v A B C D E F G H I J K L M N O P Q R S T U V W X Y Z _
unset -v a b c d e f g h i j k l m n o p q r s t u v w x y z
unset -v posix skip

work_dir="tmp.$$"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir"

setup_script=""
setup() {
    case "${1--}" in
        (-)
            setup "$(cat)"
            ;;
        (-d)
            setup <<\END
_empty= _sp=' ' _tab='	' _nl='
'
echoraw() {
    printf '%s\n' "$*"
}
bracket() {
    if [ $# -gt 0 ]; then printf '[%s]' "$@"; fi
    echo
}
END
            ;;
        (*)
            setup_script="$setup_script
$1"
            ;;
    esac
}

echoraw() {
    printf '%s\n' "$*"
}
bracket() {
    if [ $# -gt 0 ]; then printf '[%s]' "$@"; fi
    echo
}

macos_kill_workaround()
if [ "$(uname)" = Darwin ]; then
    setup <<'__EOF__'
kill() (trap 'sleep 0' EXIT; (trap 'sleep 0' EXIT; (trap 'sleep 0' EXIT; command kill "$@")))
__EOF__
fi

testee() (
    exec_testee "$@"
)
exec_testee() {
    if [ "${posix:+set}" = set ]; then
        testee="$testee_sh"
        export TESTEE="$testee"
    fi
    exec "$testee" "$@"
}

# testcase lineno [-d] [-e status] [-f] name [testee-args...]
# fd 3: script, fd 4: expected stdout, fd 5: expected stderr
testcase() {
    test_lineno="${1:?line number unspecified}"
    shift 1
    OPTIND=1
    diagnostic_required="false"
    expected_exit_status=""
    should_succeed="true"
    while getopts de:f opt; do
        case $opt in
            (d) diagnostic_required="true";;
            (e) expected_exit_status="$OPTARG";;
            (f) should_succeed="false";;
            (*) return 64
        esac
    done
    shift "$((OPTIND-1))"
    test_case_name="${1:?unnamed test case}"
    shift 1

    # test cases may run in subshells, so number them by the counts file
    n=$((first + $(wc -l <"$counts") + 1))
    in_file="$n.in" out_file="$n.out" err_file="$n.err"
    {
        if [ "$setup_script" ]; then
            printf '%s\n' "$setup_script"
        fi
        cat <&3
    } >|"$in_file"

    loc="yash/${test_file##*/}"
    case "$test_lineno" in (0|'') ;; (*) loc="$loc:$test_lineno"; esac
    printf 'Test %d: "%s"\n' "$n" "$loc: $test_case_name"
    if [ "${skip-}" ]; then
        printf 'SKIP\n'
        echo S >>"$counts"
        rm -f "$in_file"
        return
    fi

    set +e
    (
    exec_testee "$@" <"$in_file" >>"$out_file" 2>>"$err_file" 3>&- 4>&- 5>&-
    ) 2>/dev/null
    actual_exit_status="$?"
    set -e

    why=""
    case "$expected_exit_status" in
        ('')
            ;;
        (n)
            if [ "$actual_exit_status" -eq 0 ]; then
                why="exit status: expected non-zero, actual 0"
            fi
            ;;
        ([[:alpha:]]*)
            actual_signal=""
            if [ "$actual_exit_status" -gt 128 ]; then
                actual_signal="$(kill -l "$actual_exit_status" 2>/dev/null)" ||
                    actual_signal=""
            fi
            if [ "$actual_signal" != "$expected_exit_status" ]; then
                why="exit status: expected SIG$expected_exit_status, actual $actual_exit_status"
            fi
            ;;
        (*)
            if [ "$actual_exit_status" -ne "$expected_exit_status" ]; then
                why="exit status: expected $expected_exit_status, actual $actual_exit_status"
            fi
            ;;
    esac

    if { <&4; } 2>/dev/null; then
        cat <&4 >|"$n.xout"
        if ! cmp -s "$n.xout" "$out_file"; then
            why="$why${why:+$nl}stdout differs (-expected +actual):$nl$(
                diff -u "$n.xout" "$out_file" 2>/dev/null | sed '1,2d' | head -n 20)"
        fi
    fi

    if "$diagnostic_required"; then
        if ! [ -s "$err_file" ]; then
            why="$why${why:+$nl}stderr: expected a diagnostic, got none"
        fi
    elif { <&5; } 2>/dev/null; then
        cat <&5 >|"$n.xerr"
        if ! cmp -s "$n.xerr" "$err_file"; then
            why="$why${why:+$nl}stderr differs (-expected +actual):$nl$(
                diff -u "$n.xerr" "$err_file" 2>/dev/null | sed '1,2d' | head -n 20)"
        fi
    fi

    if "$should_succeed"; then
        if [ -z "$why" ]; then
            echo P >>"$counts"
        else
            printf 'FAIL\n%s\n' "$why" | sed '2,$s/^/  /'
            echo F >>"$counts"
        fi
    else
        if [ -n "$why" ]; then
            echo P >>"$counts"
        else
            printf 'FAIL\n  passed, but is marked as an expected failure\n'
            echo F >>"$counts"
        fi
    fi
    rm -f "$in_file" "$out_file" "$err_file" "$n.xout" "$n.xerr"
}

alias test_x='testcase "$LINENO" 3<<\__IN__ 4<&- 5<&-'
alias test_o='testcase "$LINENO" 3<<\__IN__ 4<<\__OUT__ 5<&-'
alias test_O='testcase "$LINENO" 3<<\__IN__ 4</dev/null 5<&-'
alias test_e='testcase "$LINENO" 3<<\__IN__ 4<&- 5<<\__ERR__'
alias test_oe='testcase "$LINENO" 3<<\__IN__ 4<<\__OUT__ 5<<\__ERR__'
alias test_Oe='testcase "$LINENO" 3<<\__IN__ 4</dev/null 5<<\__ERR__'
alias test_E='testcase "$LINENO" 3<<\__IN__ 4<&- 5</dev/null'
alias test_oE='testcase "$LINENO" 3<<\__IN__ 4<<\__OUT__ 5</dev/null'
alias test_OE='testcase "$LINENO" 3<<\__IN__ 4</dev/null 5</dev/null'

(
abs_test_file="$(absolute "$test_file")"
cd "$work_dir"
ln -s -- "$testee" sh
testee_sh="$(absolute sh)"
export TESTEE="$testee"
. "$abs_test_file"
)
EOF
put yash/checkfg <<'EOF'
exit 1
EOF
put yash/signal.sh <<'EOF'
# signal.sh: utility for testing signal actions

# $1 = $LINENO
# $2 = signal name
# $3 = target (shell, child, or exec)
# $4 = context (main, subshell, cmdsub, or async)
# $5 = sender (self or other)
# $6 = interactiveness (+i or -i)
# $7 = job control (+m or -m)
# $8 = action inherited from parent (default or ignored)
# $9 = trap set outside context (keep, clear, ignore or command)
# $10 = trap set inside context (keep, clear, ignore or command)
signal_action_test() (

signal=$2
case $2 in
    (CHLD|CONT|URG|WINCH)
        signal_action=spares
        ;;
    (STOP|TSTP|TTIN|TTOU)
        signal_action=stops
        ;;
    (*)
        signal_action=kills
        case $2 in
            (RTMAX|RTMIN)
                if ! "$TESTEE" -c 'trap : RTMAX RTMIN' 2>/dev/null; then
                    skip="true"
                fi
        esac
        ;;
esac

case $3 in
    (shell)
        target=shell
        enter_target=
        exit_target=
        ;;
    (child)
        target='child process'
        enter_target='"$TESTEE" <<\END'
        exit_target='END'
        ;;
    (exec)
        target='execed process'
        enter_target='exec "$TESTEE" <<\END'
        exit_target='END'
        ;;
esac

context=$4
case $4 in
    (main)
        enter_context=
        exit_context=
        ;;
    (subshell)
        enter_context='('
        exit_context=')'
        ;;
    (cmdsub)
        enter_context='x=$('
        exit_context='); s=$?; ${x:+echo "$x"}; exit $s'
        ;;
    (async)
        enter_context='{'
        exit_context='} & wait $!'
        ;;
esac

sender=$5
case $5 in
    (self)
        send="kill -s $signal \$\$"
        ;;
    (other)
        send="\"\$TESTEE\" -c 'kill -s $signal \$PPID'"
        ;;
esac

interact=$6
monitor=$7

parent_action=$8
case $8 in
    (default)
        initial='initially defaulted'
        ;;
    (ignored)
        initial='initially ignored'
        if ! [ "${skip-}" ]; then
            trap '' $signal
        fi
        ;;
esac

outside_trap=$9
case $9 in
    (keep)
        set_outside_trap=''
        ;;
    (clear)
        set_outside_trap="trap - $signal"
        ;;
    (ignore)
        set_outside_trap="trap '' $signal"
        ;;
    (command)
        set_outside_trap="trap 'echo trapped; trap - $signal' $signal"
        ;;
esac

inside_trap=${10}
case ${10} in
    (keep)
        set_inside_trap=''
        ;;
    (clear)
        set_inside_trap="trap - $signal"
        ;;
    (ignore)
        set_inside_trap="trap '' $signal"
        ;;
    (command)
        set_inside_trap="trap 'echo trapped; trap - $signal' $signal"
        ;;
esac

if [ "$parent_action" = ignored ] && [ "$interact" = +i ]; then
    final_trap=ignore
elif [ "$inside_trap" != keep ]; then
    final_trap=$inside_trap
elif [ "$context" = async ] && [ "$monitor" = +m ] &&
    { [ "$signal" = INT ] || [ "$signal" = QUIT ]; } then
    final_trap=ignore
elif [ "$context" = main ] || [ "$outside_trap" = ignore ]; then
    final_trap=$outside_trap
else
    final_trap=keep
fi

if [ "$target $context $interact" = "shell main -i" ] &&
    case $signal in
        (INT|QUIT|TERM)
            true
            ;;
        (*)
            false
            ;;
    esac; then
    default_action=spares
elif [ "$target $context $monitor" = "shell main -m" ] &&
    case $signal in
        (TSTP|TTIN|TTOU)
            true
            ;;
        (*)
            false
            ;;
    esac; then
    default_action=spares
else
    default_action=$signal_action
fi

case $final_trap in
    (keep)
        if [ "$interact" = -i ] && [ "$outside_trap" != keep ]; then
            reset_action=default
        else
            reset_action=$parent_action
        fi
        case $reset_action in
            (default)
                final_action=$default_action
                ;;
            (ignored)
                final_action=spares
                ;;
        esac
        ;;
    (clear)
        final_action=$default_action
        ;;
    (ignore)
        final_action=spares
        ;;
    (command)
        if [ "$target" = shell ]; then
            final_action='is handled by'
        else
            final_action=$default_action
        fi
        ;;
esac

case $signal in
    (KILL)
        final_action=kills
        ;;
    (STOP)
        final_action=stops
        ;;
esac

case $final_action in
    (spares)
        post='echo ok'
        finish=''
        exec 4<<\END
ok
END
        exit_status=0
        ;;
    ('is handled by')
        post='echo ok'
        finish=''
        exec 4<<\END
trapped
ok
END
        exit_status=0
        ;;
    (stops)
        post='echo continued'
        finish='fg >/dev/null'
        exec 4<<\END
continued
END
        exit_status=0
        ;;
    (kills)
        post='echo not printed'
        finish=''
        exec 4</dev/null
        exit_status=$signal
        ;;
esac

testcase "$1" -e "$exit_status" "SIG$signal $final_action $target "\
"($context, $sender, $interact $monitor, $initial, "\
"$outside_trap -> $inside_trap)" $interact $monitor 3<<__IN__ 5<&-
$set_outside_trap
$enter_context
$set_inside_trap
$enter_target
$send
$post
$exit_target
$exit_context
$finish
__IN__

)

# $1 = LINENO
# $2 = interactiveness (+i or -i)
# $3 = job control (+m or -m)
# $4 = action inherited from parent (default or ignored)
# $5, $6, ... = signals
signal_action_test_combo() {
    n=${1}000 d=$2 e=$3 f=$4
    shift 4

    # Enable job-control to make sure every job-controlling testee starts in
    # the foreground. (See #45760)
    if ! [ "${skip-}" ]; then
        set $e
    fi

    for a in shell child exec; do
    for b in main subshell cmdsub async; do
    for g in keep clear ignore command; do
    for h in keep clear ignore command; do
        s=$1
        if [ $a = shell ]; then
            if [ $g = keep ] && [ $h != keep ]; then
                # This case is the same as $g != keep && $h = keep.
                # Skip the redundant test.
                continue
            fi
        fi
        case $s in (STOP|TTIN|TTOU|TSTP)
            if [ $e = +m ]; then
                # The test implementation only works with -m.
                # For +m, handling of TTIN, TTOU and TSTP is POSIXly unspecified.
                continue
            fi
            # Skip combinations that would freeze the test.
            case $a in
                (shell)
                    continue ;;
                (child)
                    if [ $b != main ]; then continue; fi ;;
                (exec)
                    if [ $b != subshell ]; then continue; fi ;;
            esac
            if [ $a = shell ]; then
                continue
            fi
            if [ $a = child ] && [ $b != main ]; then
                continue
            fi
            if [ $a = exec ] && [ $b != subshell ]; then
                continue
            fi
        esac
        case $s in (KILL|STOP)
            if [ $f = ignored ]; then
                # These signals are not ignorable.
                continue
            fi
        esac
        if [ $s = STOP ] && [ $a != child ]; then
            case $b in (main|cmdsub)
                # This combination would freeze the test.
                continue
            esac
        fi
        if [ $s = CHLD ]; then
            # The OS kernel automatically sends SIGCHLD, which confuses tests.
            if [ $a = child ] || [ $b != main ]; then
                if [ $g = command ]; then
                    continue
                fi
            fi
            if [ $a = child ]; then
                if [ $h = command ]; then
                    continue
                fi
            fi
        fi

        if [ $((n%2)) -eq 0 ] && ! { [ $a = shell ] && [ $b != main ]; }; then
            c=self
        else
            c=other
        fi

        signal_action_test $n $s $a $b $c $d $e $f $g $h

        n=$((n+1))
        shift
        set "$@" "$s"
    done
    done
    done
    done

    set +m
}

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/alias-p.tst <<'EOF'
# alias-p.tst: test of aliases for any POSIX-compliant shell

posix="true"
setup 'set -e'

test_OE -e 0 'defining alias'
alias a='echo ABC'
__IN__

(
setup "alias a='echo ABC'"

test_oE -e 0 'using alias'
a
a
a
__IN__
ABC
ABC
ABC
__OUT__

test_OE -e 0 'redefining alias - exit status'
alias a='echo BCD'
__IN__

test_oE 'redefining alias - redefinition'
alias a='echo BCD'
a
__IN__
BCD
__OUT__

test_OE -e 0 'removing specific alias - exit status'
alias true=false
unalias true
__IN__

test_OE -e 0 'removing specific alias - removal'
alias true=false
unalias true
true
__IN__

test_OE -e 0 'removing multiple aliases - exit status'
alias true=a cat=b echo=c
unalias true cat echo
__IN__

test_oE -e 0 'removing multiple aliases - removal'
alias true=a cat=b echo=c
unalias true cat echo
true
echo ok | cat
__IN__
ok
__OUT__

test_OE -e 0 'removing all aliases - exit status'
alias a=a b=b c=c
unalias -a
__IN__

test_OE 'removing all aliases - removal'
alias a=a b=b c=c
unalias -a
alias
__IN__

test_OE -e 0 'printing specific alias'
alias a | grep -q '^a='
__IN__

test_oE -e 0 'reusing printed alias (simple)'
save="$(alias a)"
unalias a
eval alias "$save"
a
__IN__
ABC
__OUT__

test_oE -e 0 'reusing printed alias (complex quotation)'
alias a='printf %s\\n \"['\\\'{'\\'}\\\'']\"'
save="$(alias a)"
unalias a
eval alias "$save"
a
__IN__
"['{\}']"
__OUT__

test_OE -e 0 'printing all aliases'
alias b=b c=c e='echo OK'
alias >save_alias_1
unalias -a
IFS='
' # trick to replace each newline in save_alias_1 with a space
eval alias -- $(cat save_alias_1)
alias >save_alias_2
diff save_alias_1 save_alias_2
__IN__

test_OE -e 0 'subshell inherits aliases'
(alias a) | grep -q '^a='
__IN__

test_oE 'subshell cannot affect main shell'
(alias a='echo BCD')
a
__IN__
ABC
__OUT__

test_O -d -e n 'printing undefined alias is error'
unalias -a
alias a
__IN__

test_O -d -e n 'removing undefined alias is error'
alias true=false
unalias true
unalias true
__IN__

test_oE 'using alias after assignment (simple)'
alias s=sh
a=A s -c 'echo $a'
__IN__
A
__OUT__

test_oE 'using alias after assignment (complex)'
alias b=' b=B s '\''echo $a $b'\''; echo C' s=' sh -c '
a=A b
__IN__
A B
C
__OUT__

test_OE 'using alias after redirection (simple)'
alias e=echo
>/dev/null e not_printed
__IN__

test_OE 'using alias after redirection (complex)'
alias e=' >&- c >/dev/null ' c=' echo '
</dev/null e not_printed
__IN__

test_oE 'using alias in pipeline (simple)'
alias c=cat
! a | c | c
__IN__
ABC
__OUT__

test_oE 'using alias in pipeline (complex)'
alias b=' cat | c - ; a ' c=' cat '
! a | b DEF
__IN__
ABC
ABC DEF
__OUT__

test_oE 'using aliases in compound commands'
alias begin={ end=}
if true; then begin a; end; fi
__IN__
ABC
__OUT__

test_oE 'alias substitution to empty string'
alias a=
a
a echo foo | a
cat
__IN__
foo
__OUT__

(
setup 'alias b=" "'

test_oE 'alias substitution to blank before if'
b if true; then echo ok; fi
__IN__
ok
__OUT__

test_OE -e n 'alias substitution to blank should not change exit status'
set +e
false
b
__IN__

test_oE 'alias substitution to blank before newline'
(
echo ok | b
cat
) </dev/null
__IN__
ok
__OUT__

)

test_oE 'alias substitution to assignment'
alias a='a=A'
a b=B sh -c 'echo $a $b'
__IN__
A B
__OUT__

test_oE 'alias substitution to redirection'
alias r='>/dev/null'
r echo not_printed
echo ok
__IN__
ok
__OUT__

test_oE 'alias substitution to here-document'
alias c='cat <<\END' d='c
here-document
END'
d
__IN__
here-document
__OUT__

test_oE 'alias substitution to here-document operand'
alias c=' cat << ' e=' \END '
c e
here-document
END
__IN__
here-document
__OUT__

test_oE 'alias substitution to !'
alias e='! echo'
if e if; then echo then; else echo else; fi
__IN__
if
else
__OUT__

test_oE 'alias substitution to parenthesis'
alias l='
(
' r='
)
'
a=A
l echo subshell; a=B; r
echo $a
__IN__
subshell
A
__OUT__

test_oE 'alias substitution to if/then/elif/else/fi keywords'
alias i='if echo' t='then echo' ei='elif echo' es='else echo' f='fi </dev/null'
i if; then echo then1; elif echo elif; then echo then2; else echo else; fi
if echo if; t then1; elif echo elif; then echo then2; else echo else; fi
if false; then echo then1; ei elif; then echo then2; else echo else; fi
if false; then echo then1; elif false; then echo then2; es else; fi
if false; then echo then1; elif false; then echo then2; else echo else; f
__IN__
if
then1
if
then1
elif
then2
else
else
__OUT__

test_oE 'alias substitution to while/until/do/done keywords'
alias w='while :' u='until :' d='do echo' dn='done | cat -'
w X; true; d while; break; dn
u X; false; d until; break; dn
__IN__
while
until
__OUT__

test_oE 'alias substitution to for'
alias f='for i in 1 2; do'
f echo $i; done
__IN__
1
2
__OUT__

test_oE 'alias substitution to word (for)'
alias f=' for ' w=' in ' in=' x '
f w in 1; do echo $x; done
__IN__
1
__OUT__

test_oE 'alias substitution to in (for)'
alias forx='for x ' i='in 0' in='in 1' for='in 2'
forx i a; do echo $x; done
forx in a; do echo $x; done
forx for a; do echo $x; done
__IN__
0
a
a
2
a
__OUT__

test_oE 'alias substitution to do/done (for with in)'
alias forx='for x in 1; ' fory='for y in 2; do echo $y;' for='
 do' dn='
 done'
forx for echo $x; dn
fory dn
__IN__
1
2
__OUT__

test_oE 'alias substitution to do/done (for w/o in)'
alias forx='for x ' for=' ; 

 do' done='

 do' do='?' dn='
 #comment
 done'
set a b c
forx for echo $x
dn
forx done echo $x
dn
__IN__
a
b
c
a
b
c
__OUT__

test_oE 'inapplicable alias substitution of do (for)'
alias forx='for x ' do=';'
set 1
forx do echo $x; done
__IN__
1
__OUT__

test_oE 'alias substitution to case/esac keywords'
alias c='case a in a) :' e='
 esac </dev/null | cat -' eb='
 echo B;; '
c X; echo A; e
c X; eb e
__IN__
A
B
__OUT__

test_oE 'alias substitution to in (case)'
alias c='case a ' case='
 in a) :' in=
c case X; echo A; esac
c in a) echo B; esac
__IN__
A
B
__OUT__

test_oE 'alias substitution to case pattern'
alias c='case a in ' a=b p='(a)'
c a) echo 1-1;; a) echo 1-2;; esac
c p echo 2; esac
alias c='case a in x) ;; '
c p echo 3; esac
alias c='case a in x| '
c a) echo 4-1;; a) echo 4-2;; esac
__IN__
1-2
2
3
4-2
__OUT__

test_oE 'alias substitution to ( (case)'
alias c='case a in ' p=' #comment

 (a) echo A; esac'
c p
__IN__
A
__OUT__

test_oE 'alias substitution to | (case)'
alias c='case a in x ' p=' |a) echo A; esac'
c p
__IN__
A
__OUT__

test_oE 'alias substitution to ) (case)'
alias c='case a in a ' p=' ) echo A; esac'
c p
__IN__
A
__OUT__

test_oE 'alias substitution to ;;'
alias s=';;'
case a in
    (b) s
    (a) echo A
esac
__IN__
A
__OUT__

)

test_oE 'alias substitution to function definition'
alias def='f()' f='func'
def
{ echo f; }
func
__IN__
f
__OUT__

test_oE 'alias substitution to parentheses in function definition'
alias f='f ' p='()'
f p
{ echo F; }
f
alias g='g( ' q=')'
g q
{ echo G; }
\g
__IN__
F
G
__OUT__

test_oE 'alias substitution to command in function definition'
alias f='f() ' g=
f g
{ echo F; }
\f
__IN__
F
__OUT__

test_oE 'IO_NUMBER cannot be aliased'
alias 3=:
3>/dev/null echo \>
3</dev/null echo \<
__IN__
>
<
__OUT__

test_oE 'alias starting with blank'
alias e=' echo' b=' { e B; }'
e A
b
__IN__
A
B
__OUT__

test_oE 'alias ending with blank'
alias c=cat e='echo '
e c c cat
alias c='cat '
e c c cat
alias echo='e x x ' x=.
echo echo
alias x='x . '
echo echo
__IN__
cat c cat
cat cat cat
. x echo . x
x . x . echo x . x .
__OUT__

test_oE 'alias ending with blank followed by line continuation'
alias foo=bar a='echo \
'
a foo
__IN__
foo
__OUT__

test_OE 'alias substitution can be part of an operator'
alias lt='<'
# The "lt" token followed by ">" becomes the "<>" redirection operator.
lt>/dev/null >&0 echo not printed
__IN__

test_oE 'aliases cannot substitute reserved words'
alias if=: then=: else=: fi=: for=: in=: do=: done=:
if true; then echo then; else echo else; fi
for a in A; do echo $a; done
__IN__
then
A
__OUT__

test_oE 'quoted aliases are not substituted'
alias echo=:
\echo backslash at head
ech\o backslash at tail
e'c'ho partial single-quotation
'echo' full single-quotation
e"c"ho partial double-quotation
"echo" full double-quotation
__IN__
backslash at head
backslash at tail
partial single-quotation
full single-quotation
partial double-quotation
full double-quotation
__OUT__

test_oE 'line continuation in alias name'
alias eeee=echo
ee\
e\
e ok
__IN__
ok
__OUT__

test_oE 'line continuation between alias names (1)'
alias echo='\
echo\
 ' foo='\
bar\
' bar=X
echo           \
foo
__IN__
X
__OUT__

test_oE 'line continuation between alias names (2)'
alias eeee='echo\
 '
eeee eeee
__IN__
echo
__OUT__

test_oE 'alias substitution to line continuation'
alias e='echo ' bs='\' bsnl='\
'
e bs
 foo
e bsnl bar
__IN__
foo
bar
__OUT__

test_oE 'characters allowed in alias name'
alias Aa0_!%,@=echo
Aa0_!%,@ ok
__IN__
ok
__OUT__

test_oE 'recursive alias'
alias echo='echo % ' e='echo echo'
e !
# e !
# echo echo !
# echo %  echo %  !
__IN__
% echo % !
__OUT__

test_oE 'alias in command substitution'
alias e=:
func() {
    alias e=echo
    echo "$(e ok)"
}
func
__IN__
ok
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/andor-p.tst <<'EOF'
# andor-p.tst: test of and-or lists for any POSIX-compliant shell

posix="true"

test_oE -e 0 '2-command list, success && success'
echo 1 && echo 2
__IN__
1
2
__OUT__

test_oE -e 0 '2-command list, success || success'
echo 1 || echo 2
__IN__
1
__OUT__

test_oE -e n '2-command list, failure && success'
false && echo 2
__IN__
__OUT__

test_oE -e 0 '2-command list, failure || success'
false || echo 2
__IN__
2
__OUT__

test_oE -e n '2-command list, success && failure'
echo 1 && false
__IN__
1
__OUT__

test_oE -e 0 '2-command list, success || failure'
echo 1 || false
__IN__
1
__OUT__

test_oE -e n '2-command list, failure && failure'
false && false
__IN__
__OUT__

test_oE -e n '2-command list, failure || failure'
false || false
__IN__
__OUT__

test_oE '3-command list'
false && echo foo || echo bar
true || echo foo && echo bar
__IN__
bar
bar
__OUT__

test_x -e 0 'exit status of list is from last-executed pipeline (success)'
false && exit 1 || true || exit 1 || exit 2
__IN__

test_x -e 13 'exit status of list is from last-executed pipeline (failure)'
true && (exit 1) || true || exit || exit && (exit 13) && exit 20 && exit 21
__IN__

test_o 'linebreak after &&'
echo 1 &&
    echo 2 &&

    echo 3
__IN__
1
2
3
__OUT__

test_o 'linebreak after ||'
false ||
    false ||

    echo foo
__IN__
foo
__OUT__

test_o 'pipelines in list'
! false && ! true | false && echo foo | cat
__IN__
foo
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/arith-p.tst <<'EOF'
# arith-p.tst: test of arithmetic expansion for any POSIX-compliant shell

posix="true"
setup -d

# POSIX does not specify how the result of an arithmetic expansion should be
# formatted. We assume the result is always formatted by 'printf "%ld"'.

test_oE -e 0 'single constant'
echoraw $((0)) $((1)) $((100)) $((020)) $((0x7F))
__IN__
0 1 100 16 127
__OUT__

test_oE -e 0 'single variable'
zero=0 one=1 hundred=100 plus_one=+1 minus_one=-1
echoraw $((zero)) $((one)) $((hundred)) $((plus_one)) $((minus_one))
__IN__
0 1 100 1 -1
__OUT__

test_oE -e 0 'unset variable is considered 0 (direct)'
unset x
echoraw $((x))
__IN__
0
__OUT__

test_oE -e 0 'unary sign operators'
echoraw $((+1)) $((-1)) $((-+-2))
__IN__
1 -1 2
__OUT__

test_oE -e 0 'unary negation operators'
echoraw $((~0)) $((~1)) $((~2)) $((~-1)) $((~-2))
echoraw $((!0)) $((!1)) $((!2)) $((!-1)) $((!-2))
__IN__
-1 -2 -3 0 1
1 0 0 0 0
__OUT__

test_oE -e 0 'multiplicative operators'
echoraw $((0 * 0)) $((1*0)) $((0*1)) $((1*1)) $((2*3)) $((-5*7))
echoraw $((0 / 1)) $((6/2)) $((-12/3)) $((35/-5)) $((-121/-11))
echoraw $((0 % 1)) $((1%1)) $((1%2)) $((47%7))
__IN__
0 0 0 1 6 -35
0 3 -4 -7 11
0 0 1 5
__OUT__

test_oE -e 0 'additive operators'
echoraw $((0 + 0)) $((0+1)) $((2+3)) $((5+-7)) $((-7+13)) $((-1+-2))
echoraw $((0 - 0)) $((0-1)) $((3-2)) $((5- -7)) $((-7-13)) $((-1- -2))
__IN__
0 1 5 -2 6 -3
0 -1 1 12 -20 1
__OUT__

test_oE -e 0 'shift operators'
echoraw $((0 << 0)) $((3<<2)) $((5<<3)) # undefined: $((-2<<3))
echoraw $((0 >> 0)) $((15>>2)) $((43>>3)) $((-14>>3))
__IN__
0 12 40
0 3 5 -2
__OUT__

test_oE -e 0 'relational operators'
echoraw $((0 < 0)) $((0 <= 0)) $((0 > 0)) $((0 >= 0))
echoraw $((-1< -1)) $((-1< 0)) $((-1< 1)) \
        $(( 0< -1)) $(( 0< 0)) $(( 0< 1)) \
        $(( 1< -1)) $(( 1< 0)) $(( 1< 1))
echoraw $((-1<=-1)) $((-1<=0)) $((-1<=1)) \
        $(( 0<=-1)) $(( 0<=0)) $(( 0<=1)) \
        $(( 1<=-1)) $(( 1<=0)) $(( 1<=1))
echoraw $((-1> -1)) $((-1> 0)) $((-1> 1)) \
        $(( 0> -1)) $(( 0> 0)) $(( 0> 1)) \
        $(( 1> -1)) $(( 1> 0)) $(( 1> 1))
echoraw $((-1>=-1)) $((-1>=0)) $((-1>=1)) \
        $(( 0>=-1)) $(( 0>=0)) $(( 0>=1)) \
        $(( 1>=-1)) $(( 1>=0)) $(( 1>=1))
__IN__
0 1 0 1
0 1 1 0 0 1 0 0 0
1 1 1 0 1 1 0 0 1
0 0 0 1 0 0 1 1 0
1 0 0 1 1 0 1 1 1
__OUT__

test_oE -e 0 'equality operators'
echoraw $((0 == 0)) $((1==0)) $((0==1)) $((1==1)) $((3==3)) $((2==3))
echoraw $((0 != 0)) $((1!=0)) $((0!=1)) $((1!=1)) $((3!=3)) $((2!=3))
__IN__
1 0 0 1 1 0
0 1 1 0 0 1
__OUT__

test_oE -e 0 'bitwise operators'
echoraw $((0 & 0)) $((3&5)) $((-13&5)) $((3&-11)) $((-13&-11))
echoraw $((0 ^ 0)) $((3^5)) $((-13^5)) $((3^-11)) $((-13^-11))
echoraw $((0 | 0)) $((3|5)) $((-13|5)) $((3|-11)) $((-13|-11))
__IN__
0 1 1 1 -15
0 6 -10 -10 6
0 7 -9 -9 -9
__OUT__

test_oE -e 0 'logical operators'
echoraw $((0 && 0)) $((3&&0)) $((0&&-5)) $((3&&-5))
echoraw $((0 || 0)) $((3||0)) $((0||-5)) $((3||-5))
echoraw $((0 ? 0 : 0)) $((0?1:2)) $((1?2:3)) $((-1?2:3))
__IN__
0 0 0 1
0 1 1 1
0 2 2 2
__OUT__

test_oE -e 0 'conditional evaluation of && operator operand'
a=0
echoraw $((1&&(a=5)))
echoraw $((0&&(a=-5)))
echoraw $a
__IN__
1
0
5
__OUT__

test_oE -e 0 'conditional evaluation of || operator operand'
a=0
echoraw $((0||(a=5)))
echoraw $((1||(a=-5)))
echoraw $a
__IN__
1
1
5
__OUT__

test_oE -e 0 'conditional evaluation of ?: operator operand'
a=0 b=0
echoraw $((1?(a=5):(b=-5)))
echoraw $a $b
a=0 b=0
echoraw $((0?(a=-5):(b=5)))
echoraw $a $b
__IN__
5
5 0
5
0 5
__OUT__

test_oE -e 0 'assignment operators'
a=0 b=2 c=15 d=46 e=3 f=3 g=7 h=30 i=3 j=3 k=3
echoraw $((a=5)) $((b*=3)) $((c/=3)) $((d%=7)) $((e+=5)) $((f-=5)) \
    $((g<<=2)) $((h>>=2)) $((i&=5)) $((j^=5)) $((k|=5))
echoraw $a $b $c $d $e $f $g $h $i $j $k
__IN__
5 6 5 4 8 -2 28 7 1 6 7
5 6 5 4 8 -2 28 7 1 6 7
__OUT__

test_O -d -e n 'assigning to read-only variable'
readonly a=3
echoraw $((a=5))
echoraw not reached
__IN__

test_oE -e 0 'unset variable is considered 0 (assignment)'
unset x
echoraw $((a=x)) && echoraw $a
__IN__
0
0
__OUT__

test_oE 'operator precedence: unary and multiplicatives'
echoraw $((!0*3)) $((~-1*3)) $((!1/2)) $((!1%1))
__IN__
3 0 0 0
__OUT__

test_oE 'operator precedence: multiplicatives'
echoraw -          -           $((2*1%2))
echoraw $((2/2*3)) $((12/6/2)) $((6/3%2))
echoraw $((7%4*2)) $((8%12/2)) $((7%2%3))
__IN__
- - 0
3 1 0
6 4 1
__OUT__

test_oE 'operator precedence: multiplicatives and additives'
echoraw $((2*3+1)) $((2*3-1)) $((1/1+1)) $((5%1+1))
echoraw $((1+2*3)) $((9-2*3)) $((2+0/2)) $((1+5%1))
__IN__
7 5 2 1
7 3 2 1
__OUT__

test_oE 'operator precedence: additives'
echoraw $((2-1+3)) $((3-2-1))
__IN__
4 0
__OUT__

test_oE 'operator precedence: additives and shifts'
echoraw $((1+1<<2)) $((3-1<<2)) $((8+8>>2)) $((8-4>>2))
echoraw $((1<<1+1)) $((2<<1-1)) $((8>>1+1)) $((8>>1-1))
__IN__
8 8 4 1
4 2 2 8
__OUT__

test_oE 'operator precedence: shifts'
echoraw $((1<<2<<1)) $((1<<3>>1)) $((8>>2<<1)) $((8>>2>>1))
__IN__
8 4 4 1
__OUT__

test_oE 'operator precedence: shifts and relationals'
echoraw $((1<<1<0)) $((2>>1<=0)) $((1<<1>2)) $((2>>1>=2))
echoraw $((0<2>>1)) $((1<=1<<1)) $((1>1>>1)) $((1>=1<<1))
__IN__
0 0 0 0
1 1 1 0
__OUT__

test_oE 'operator precedence: relationals'
echoraw $((1< 2< 2)) $((0< 1<=2)) $((1< 2> 0)) $((1< 2>=0))
echoraw $((1<=2< 2)) $((0<=0<=0)) $((1<=2> 1)) $((1<=2>=2))
echoraw $((0> 0< 1)) $((0> 0<=1)) $((1> 2> 2)) $((1> 2>=0))
echoraw $((0>=0< 0)) $((0>=0<=1)) $((1>=2> 1)) $((1>=2>=2))
__IN__
1 1 1 1
1 0 0 0
1 1 0 1
0 1 0 0
__OUT__

test_oE 'operator precedence: relationals and equalities'
echoraw $((0<=0==0)) $((0<=0!=1)) $((0==0<=0)) $((0!=2<=1))
echoraw $((1< 0==0)) $((1< 0!=1)) $((0==0< 0)) $((1!=0< 0))
echoraw $((0>=0==0)) $((1>=2!=0)) $((0==0>=0)) $((1!=0>=0))
echoraw $((0> 0==0)) $((0> 0!=1)) $((0==0> 1)) $((1!=0> 1))
__IN__
0 0 0 0
1 1 1 1
0 0 0 0
1 1 1 1
__OUT__

test_oE 'operator precedence: equalities'
echoraw $((0==0==2)) $((0==0!=2)) $((2!=0==0)) $((0!=2!=2))
__IN__
0 1 0 1
__OUT__

test_oE 'operator precedence: equalities and bitwise and'
echoraw $((0==0&0)) $((0&0==0)) $((1!=0&0)) $((0&0!=1))
__IN__
0 0 0 0
__OUT__

test_oE 'operator precedence: bitwise and and xor'
echoraw $((0&0^1)) $((1^0&0))
__IN__
1 1
__OUT__

test_oE 'operator precedence: bitwise xor and or'
echoraw $((1^1|1)) $((1|1^1))
__IN__
1 1
__OUT__

test_oE 'operator precedence: bitwise or and logical and'
echoraw $((1|1&&0)) $((0&&1|1))
__IN__
0 0
__OUT__

test_oE 'operator precedence: logical and and or'
echoraw $((0&&0||1)) $((1||0&&0))
__IN__
1 1
__OUT__

test_oE 'operator precedence: logical or and conditional'
echoraw $((2||0?0:1)) $((1?0:1||1))
__IN__
0 0
__OUT__

test_oE 'operator precedence: conditionals'
echoraw $((4?1:0?2:3))
__IN__
1
__OUT__

test_oE 'operator precedence: assignments in conditionals'
b=5 c=6 d=5 e=0 f=0 g=1 h=8 i=7 j=0 k=0
echoraw $((1?a=2:3)) $((1?b*=2:3)) $((1?c/=2:3)) $((1?d%=2:3)) \
    $((1?e+=2:3)) $((1?f-=2:3)) $((1?g<<=2:3)) $((1?h>>=2:3)) \
    $((1?i&=2:4)) $((1?j^=2:4)) $((1?k|=2:4))
echoraw $a $b $c $d $e $f $g $h $i $j $k
__IN__
2 10 3 1 2 -2 4 2 2 2 2
2 10 3 1 2 -2 4 2 2 2 2
__OUT__

test_oE 'operator precedence: conditionals and assignments'
b=5 c=6 d=5 e=0 f=0 g=1 h=8 i=7 j=0 k=0
echoraw $((a=1?2:3)) $((b*=1?2:3)) $((c/=1?2:3)) $((d%=1?2:3)) \
    $((e+=1?2:3)) $((f-=1?2:3)) $((g<<=1?2:3)) $((h>>=1?2:3)) \
    $((i&=1?2:4)) $((j^=1?2:4)) $((k|=1?2:4))
echoraw $a $b $c $d $e $f $g $h $i $j $k
__IN__
2 10 3 1 2 -2 4 2 2 2 2
2 10 3 1 2 -2 4 2 2 2 2
__OUT__

test_oE 'operator precedence: assignments'
b=5 c=10 d=5 e=10 f=10 g=16 h=2 i=3 j=1 k=2
echoraw $((a=b*=2)) $((c/=d%=3)) $((e+=f-=1)) $((g<<=h>>=1)) $((i&=j^=k|=1))
echoraw $a $b $c $d $e $f $g $h $i $j $k
__IN__
10 5 19 32 2
10 10 5 2 19 9 32 1 2 2 3
__OUT__

test_oE 'parentheses'
echoraw $(((7))) $((-(-3))) $(((1+2)*5)) $((15/(7%4))) $(((0?1:0)?1:(a=2)))
__IN__
7 3 15 5 2
__OUT__

test_oE 'parameter expansion in arithmetic expansion'
a=+123
echoraw $(($a)) $((${a%3})) $(($a-23))
__IN__
123 12 100
__OUT__

test_oE 'command substitution in arithmetic expansion'
echoraw $(($(echo 123))) $((1+$(echo 10)+`echo 100`+1000))
__IN__
123 1111
__OUT__

# Quote removal is tested in arith-y.tst.
#test_oE 'quote removal'
#__IN__
#__OUT__

test_oE 'assignment in parameter expansion in arithmetic expansion'
unset a
echoraw $((${a=1}))
echoraw $a
__IN__
1
1
__OUT__

test_O -d -e n 'malformed arithmetic expansion'
echoraw $((--))
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/async-p.tst <<'EOF'
# async-p.tst: test of asynchronous lists for any POSIX-compliant shell

posix="true"

test_o 'synchronous lists separated by semicolons'
echo 1; echo 2;echo 3;
echo 4

echo 5
__IN__
1
2
3
4
5
__OUT__

test_o 'asynchronous lists separated by ampersands'
echo& echo &echo&
wait
__IN__



__OUT__

test_o 'asynchronous commands run asynchronously'
# Note the blocking nature of opening a FIFO
mkfifo fifo1 fifo2
echo foo >fifo1 &
cat fifo1 >fifo2 &
cat fifo2 &
wait $!
__IN__
foo
__OUT__

test_o 'asynchronous command runs in subshell'
a=1
{ a=2; echo $a; }&
wait $!
echo $a
__IN__
2
1
__OUT__

test_oE 'stdin of asynchronous list is null without job control' +m
cat& wait
echo this line should not be consumed by cat
__IN__
this line should not be consumed by cat
__OUT__

echo foo > file

test_OE 'stdin of asynchronous list is null even if already redirected' +m -c '
exec < file
cat <&0 & wait
'
# In this test case, the script is given as a command line argument
# to prevent the test from being disrupted by the redirection.
__IN__

test_oE 'stdin of asynchronous list is null for first command only' +m
cat - file | cat | cat & wait
exit
__IN__
foo
__OUT__

test_o 'exit status of asynchronous list'
true&
echo $?
false&
echo $?
__IN__
0
0
__OUT__

test_o 'asynchronous and-or lists'
a=1
a=2 && echo $a&
wait
echo $a
__IN__
2
1
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/bg-p.tst <<'EOF'
# bg-p.tst: test of the bg built-in for any POSIX-compliant shell
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

cat >job1 <<\__END__
exec sh -c 'kill -s STOP $$; echo'
__END__

chmod a+x job1
ln job1 job2

test_O -d -e n 'bg cannot be used when job control is disabled'
set -m
:&
set +m
bg
__IN__

test_o 'default operand chooses most recently suspended job' -m
:&
sh -c 'kill -s STOP $$; echo 1'
bg >/dev/null
wait
__IN__
1
__OUT__

test_OE 'already running job is ignored' -m
while kill -s CONT $$; do sleep 1; done &
bg >/dev/null
kill %
__IN__

test_O -e 17 'resumed job is awaitable' -m
sh -c 'kill -s STOP $$; exit 17'
bg >/dev/null
wait %
__IN__

test_o 'resumed job is in background' -m
sh -c 'kill -s STOP $$; ../checkfg || echo bg'
bg >/dev/null
wait %
__IN__
bg
__OUT__

test_o 'specifying job ID' -m
./job1
./job2
echo -
bg %./job1 >/dev/null
bg %./job2 >/dev/null
wait
__IN__
-


__OUT__

test_o 'specifying more than one job ID' -m
./job1
./job2
echo -
bg %./job1 %./job2 >/dev/null
wait
__IN__
-


__OUT__

test_O -e 0 'bg prints resumed job' -m
trap 'kill -s KILL %1' EXIT
sleep 10&
bg >bg.out
grep -q '^\[[[:digit:]][[:digit:]]*][[:blank:]]*sleep 10' bg.out
__IN__

test_O -e 17 'bg updates $!' -m
sh -c 'kill -s STOP $$; exit 17'
bg >/dev/null
wait $!
__IN__

test_O -e 0 'exit status of bg' -m
sh -c 'kill -s STOP $$; exit 17'
bg >/dev/null
__IN__

test_O -d -e n 'no existing job' -m
bg
__IN__

test_O -d -e n 'no such job' -m
sh -c 'kill -s STOP $$'
bg %_no_such_job_
exit_status=$?
fg >/dev/null
exit $exit_status
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/break-p.tst <<'EOF'
# break-p.tst: test of the break built-in for any POSIX-compliant shell

posix="true"

test_oE 'breaking one for loop, unnested'
for i in 1 2 3; do
    echo in $i
    break 1
    echo out $i
done
echo done $?
__IN__
in 1
done 0
__OUT__

test_oE 'breaking one while loop, unnested'
while true; do
    echo in
    break 1
    echo out
done
echo done $?
__IN__
in
done 0
__OUT__

test_oE 'breaking one until loop, unnested'
until false; do
    echo in
    break 1
    echo out
done
echo done $?
__IN__
in
done 0
__OUT__

test_oE 'breaking one for loop, nested in for loop'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        break 1
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
out 1
in 2
in 2 a
out 2
in 3
in 3 a
out 3
done 0
__OUT__

test_oE 'breaking one for loop, nested in while loop'
i=1
while [ $i -le 3 ]; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        break 1
        echo out $i $j
    done
    echo out $i
    i=$((i+1))
done
echo done $?
__IN__
in 1
in 1 a
out 1
in 2
in 2 a
out 2
in 3
in 3 a
out 3
done 0
__OUT__

test_oE 'breaking one while loop, nested in while loop'
i=1
while [ $i -le 3 ]; do
    echo in outer $i
    while true; do
        echo in inner $i
        break 1
        echo out inner $i
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1
out outer 1
in outer 2
in inner 2
out outer 2
in outer 3
in inner 3
out outer 3
done 0
__OUT__

test_oE 'breaking one while loop, nested in until loop'
i=1
until [ $i -gt 3 ]; do
    echo in outer $i
    while true; do
        echo in inner $i
        break 1
        echo out inner $i
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1
out outer 1
in outer 2
in inner 2
out outer 2
in outer 3
in inner 3
out outer 3
done 0
__OUT__

test_oE 'breaking one until loop, nested in until loop'
i=1
until [ $i -gt 3 ]; do
    echo in outer $i
    until false; do
        echo in inner $i
        break 1
        echo out inner $i
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1
out outer 1
in outer 2
in inner 2
out outer 2
in outer 3
in inner 3
out outer 3
done 0
__OUT__

test_oE 'breaking one until loop in function, nested in until loop'
func() {
    until false; do
        echo in inner $i
        break 1
        echo out inner $i
    done
    echo out func
}
i=1
until [ $i -gt 2 ]; do
    echo in outer $i
    func
    echo out outer $i
    i=$((i+1))
done
__IN__
in outer 1
in inner 1
out func
out outer 1
in outer 2
in inner 2
out func
out outer 2
__OUT__

test_oE 'breaking two for loops, outermost'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        break 2
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
done 0
__OUT__

test_oE 'breaking for and while loops, outermost'
i=1
while [ $i -le 3 ]; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        break 2
        echo out $i $j
    done
    echo out $i
    i=$((i+1))
done
echo done $?
__IN__
in 1
in 1 a
done 0
__OUT__

test_oE 'breaking two while loops, outermost'
i=1
while [ $i -le 3 ]; do
    echo in outer $i
    while true; do
        echo in inner $i
        break 2
        echo out inner $i
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1
done 0
__OUT__

test_oE 'breaking while and until loops, outermost'
i=1
until [ $i -gt 3 ]; do
    echo in outer $i
    while true; do
        echo in inner $i
        break 2
        echo out inner $i
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1
done 0
__OUT__

test_oE 'breaking two for loops, nested in another for loop'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        for k in + -; do
            echo in $i $j $k
            break 2
            echo out $i $j $k
        done
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 a +
out 1
in 2
in 2 a
in 2 a +
out 2
in 3
in 3 a
in 3 a +
out 3
done 0
__OUT__

test_oE 'breaking three for loops, outermost'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        for k in + -; do
            echo in $i $j $k
            break 3
            echo out $i $j $k
        done
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 a +
done 0
__OUT__

test_oE 'default operand is 1'
for i in 1; do
    echo in $i
    for j in a; do
        echo in $i $j
        for k in +; do
            echo in $i $j $k
            break
            echo out $i $j $k
        done
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 a +
out 1 a
out 1
done 0
__OUT__

test_OE -e 0 'exit status of break with $? > 0'
for i in 1; do
    false
    break
done
__IN__

test_O -d -e n 'zero operand'
for i in 1; do
    break 0
done
__IN__

test_OE 'breaking one more than actual nest level one'
for i in 1; do
    break 2
    echo not reached
done
__IN__

test_OE 'breaking one more than actual nest level two'
for i in 1; do
    for j in a; do
        break 3
        echo not reached 1
    done
    echo not reached 2
done
__IN__

test_OE 'breaking much more than actual nest level one'
for i in 1; do
    break 100
    echo not reached
done
__IN__

# This is a questionable case. Is this really a "lexically enclosing" loop as
# defined in POSIX? Most shells do support this case.
test_OE 'breaking out of eval'
for i in 1; do
    eval break
    echo not reached
done
__IN__

test_OE 'breaking with !'
for i in 1; do
    ! break
    echo not reached
done
__IN__

test_OE 'breaking before &&'
for i in 1; do
    break && echo not reached 1
    echo not reached 2 $?
done
__IN__

test_OE 'breaking after &&'
for i in 1; do
    true && break
    echo not reached $?
done
__IN__

test_OE 'breaking before ||'
for i in 1; do
    break || echo not reached 1
    echo not reached 2 $?
done
__IN__

test_OE 'breaking after ||'
for i in 1; do
    false || break
    echo not reached $?
done
__IN__

test_OE 'breaking out of brace'
for i in 1; do
    { break; }
    echo not reached
done
__IN__

test_OE 'breaking out of if'
for i in 1; do
    if break; then echo not reached then; else echo not reached else; fi
    echo not reached
done
__IN__

test_OE 'breaking out of then'
for i in 1; do
    if true; then break; echo not reached then; else not reached else; fi
    echo not reached
done
__IN__

test_OE 'breaking out of else'
for i in 1; do
    if false; then echo not reached then; else break; not reached else; fi
    echo not reached
done
__IN__

test_OE 'breaking out of case'
for i in 1; do
    case x in
        x)
            break
            echo not reached in case
    esac
    echo not reached after esac
done
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/builtins-p.tst <<'EOF'
# builtins-p.tst: test of built-ins' attributes for any POSIX-compliant shell

posix="true"

##### Special built-ins

test_o 'assignment on special built-in colon is persistent'
a=a
a=b :
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in dot is persistent'
a=a
a=b . /dev/null
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in break is persistent'
a=a
for i in 1; do
    a=b break
done
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in continue is persistent'
a=a
for i in 1; do
    a=b continue
done
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in eval is persistent'
a=a
a=b eval ''
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in exec is persistent'
a=a
a=b exec
echo $a
__IN__
b
__OUT__

#test_o 'assignment on special built-in exit is persistent'

test_o 'assignment on special built-in export is persistent'
a=a
a=b export c=c
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in readonly is persistent'
a=a
a=b readonly c=c
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in return is persistent'
f() { a=b return; }
a=a
f
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in set is persistent'
a=a
a=b set ''
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in shift is persistent'
a=a
a=b shift 0
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in times is persistent'
a=a
a=b times >/dev/null
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in trap is persistent'
a=a
a=b trap - TERM
echo $a
__IN__
b
__OUT__

test_o 'assignment on special built-in unset is persistent'
a=a
a=b unset b
echo $a
__IN__
b
__OUT__

test_O 'function cannot override special built-in colon'
:() { echo not reached; }
:
__IN__

test_O 'function cannot override special built-in dot'
.() { echo not reached; }
. /dev/null
__IN__

test_OE 'function cannot override special built-in break'
break() { echo not reached; }
for i in 1; do
    break
done
__IN__

test_OE 'function cannot override special built-in continue'
continue() { echo not reached; }
for i in 1; do
    continue
done
__IN__

test_OE 'function cannot override special built-in eval'
eval() { echo not reached; }
eval ''
__IN__

test_OE 'function cannot override special built-in exec'
exec() { echo not reached; }
exec
__IN__

test_OE 'function cannot override special built-in exit'
exit() { echo not reached; }
exit
__IN__

test_OE 'function cannot override special built-in export'
export() { echo not reached; }
export a=a
__IN__

test_OE 'function cannot override special built-in readonly'
readonly() { echo not reached; }
readonly a=a
__IN__

test_OE 'function cannot override special built-in return'
return() { echo not reached; }
fn() { return; }
fn
__IN__

test_OE 'function cannot override special built-in set'
set() { echo not reached; }
set ''
__IN__

test_OE 'function cannot override special built-in shift'
shift() { echo not reached; }
shift 0
__IN__

test_E 'function cannot override special built-in times'
times() { echo not reached >&2; }
times
__IN__

test_OE 'function cannot override special built-in trap'
trap() { echo not reached; }
trap - TERM
__IN__

test_OE 'function cannot override special built-in unset'
unset() { echo not reached; }
unset unset
__IN__

# $1 = line no.
# $2 = command name (other than special built-ins)
test_nonspecial_builtin_function_override() {
    testcase "$1" "function overrides non-special command $2" \
        5<&- 3<<__IN__ 4<<__OUT__
$2() { echo function overrides $2; }
$2 XXX
__IN__
function overrides $2
__OUT__
}

test_nonspecial_builtin_function_override "$LINENO" alias
test_nonspecial_builtin_function_override "$LINENO" bg
test_nonspecial_builtin_function_override "$LINENO" cd
test_nonspecial_builtin_function_override "$LINENO" command
test_nonspecial_builtin_function_override "$LINENO" false
test_nonspecial_builtin_function_override "$LINENO" fc
test_nonspecial_builtin_function_override "$LINENO" fg
test_nonspecial_builtin_function_override "$LINENO" getopts
test_nonspecial_builtin_function_override "$LINENO" hash
test_nonspecial_builtin_function_override "$LINENO" jobs
test_nonspecial_builtin_function_override "$LINENO" kill
test_nonspecial_builtin_function_override "$LINENO" pwd
test_nonspecial_builtin_function_override "$LINENO" read
test_nonspecial_builtin_function_override "$LINENO" true
test_nonspecial_builtin_function_override "$LINENO" type
test_nonspecial_builtin_function_override "$LINENO" ulimit
test_nonspecial_builtin_function_override "$LINENO" umask
test_nonspecial_builtin_function_override "$LINENO" unalias
test_nonspecial_builtin_function_override "$LINENO" wait

test_nonspecial_builtin_function_override "$LINENO" grep
test_nonspecial_builtin_function_override "$LINENO" newgrp
test_nonspecial_builtin_function_override "$LINENO" sed

(
setup 'PATH=; unset PATH'

test_OE -e 0 'special built-in colon can be invoked without $PATH'
:
__IN__

test_OE -e 0 'special built-in dot can be invoked without $PATH'
. /dev/null
__IN__

test_OE -e 0 'special built-in break can be invoked without $PATH'
for i in 1; do
    break
done
__IN__

test_OE -e 0 'special built-in continue can be invoked without $PATH'
for i in 1; do
    continue
done
__IN__

test_OE -e 0 'special built-in eval can be invoked without $PATH'
eval ''
__IN__

test_OE -e 0 'special built-in exec can be invoked without $PATH'
exec
__IN__

test_OE -e 0 'special built-in exit can be invoked without $PATH'
exit
__IN__

test_OE -e 0 'special built-in export can be invoked without $PATH'
export a=a
__IN__

test_OE -e 0 'special built-in readonly can be invoked without $PATH'
readonly a=a
__IN__

test_OE -e 0 'special built-in return can be invoked without $PATH'
fn() { return; }
fn
__IN__

test_OE -e 0 'special built-in set can be invoked without $PATH'
set ''
__IN__

test_OE -e 0 'special built-in shift can be invoked without $PATH'
shift 0
__IN__

test_E -e 0 'special built-in times can be invoked without $PATH'
times
__IN__

test_OE -e 0 'special built-in trap can be invoked without $PATH'
trap - TERM
__IN__

test_OE -e 0 'special built-in unset can be invoked without $PATH'
unset unset
__IN__

)

##### Intrinsic built-ins

(
setup 'PATH=; unset PATH'

test_OE -e 0 'intrinsic built-in alias can be invoked without $PATH'
alias a=a
__IN__

# Tested in builtins-y.tst.
#test_OE -e 0 'intrinsic built-in bg can be invoked without $PATH'

test_OE -e 0 'intrinsic built-in cd can be invoked without $PATH'
cd .
__IN__

test_OE -e 0 'intrinsic built-in command can be invoked without $PATH'
command :
__IN__

# Tested in builtins-y.tst.
#test_OE -e 0 'intrinsic built-in fc can be invoked without $PATH'
#test_OE -e 0 'intrinsic built-in fg can be invoked without $PATH'

test_OE -e 0 'intrinsic built-in getopts can be invoked without $PATH'
getopts o o -o
__IN__

test_OE -e 0 'intrinsic built-in hash can be invoked without $PATH'
hash -r
__IN__

test_OE -e 0 'intrinsic built-in jobs can be invoked without $PATH'
jobs
__IN__

test_OE -e 0 'intrinsic built-in kill can be invoked without $PATH'
kill -0 $$
__IN__

test_OE -e 0 'intrinsic built-in read can be invoked without $PATH'
read a
_this_line_is_read_by_the_read_built_in_
__IN__

test_E -e 0 'intrinsic built-in type can be invoked without $PATH'
type type
__IN__

# Tested in builtins-y.tst.
#test_E -e 0 'intrinsic built-in ulimit can be invoked without $PATH'

test_OE -e 0 'intrinsic built-in umask can be invoked without $PATH'
umask 000
__IN__

test_OE -e 0 'intrinsic built-in unalias can be invoked without $PATH'
unalias -a
__IN__

test_OE -e 0 'intrinsic built-in wait can be invoked without $PATH'
wait
__IN__

)

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/case-p.tst <<'EOF'
# case-p.tst: test of case command for any POSIX-compliant shell

posix="true"

test_oE 'case word is subject to tilde expansion'
HOME=/home
case ~/foo in
    /home/foo) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case word is subject to parameter expansion'
HOME=/home
case $HOME/foo in
    /home/foo) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case word is subject to command substitution'
case $(echo foo)`echo bar` in
    foobar) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case word is subject to arithmetic expansion'
case $((1+2)) in
    3) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case word is subject to quote removal'
w='"1"'"'2'"\3
case '"1"'"'2'"\3 in
    $w) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'quotations arising from expansion in case word'
# XCU 2.6.7 says:
#   The quote characters that were present in the original word shall be
#   removed unless they have themselves been quoted.
# That means backslashes in the word are not special here (because they are
# arising from expansion, not in the original word).
bs='\a\z'
case  $bs  in '\a\z') echo bs1; esac
case "$bs" in '\a\z') echo bs2; esac
__IN__
bs1
bs2
__OUT__

test_oE 'case pattern is subject to tilde expansion'
HOME=/home
case /home/foo in
    ~/foo) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case pattern is subject to parameter expansion'
HOME=/home
case /home/foo in
    $HOME/foo) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case pattern is subject to command substitution'
case foobar in
    $(echo foo)`echo bar`) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case pattern is subject to arithmetic expansion'
case 3 in
    $((1+2))) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'case pattern is subject to quote removal'
w='"1"'"'2'"\3
case $w in
    '"1"'"'2'"\3) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'backslashes arising from expansion in case pattern'
# XCU 2.9.4 implies unquoted backslashes are special in the pattern.
bs='\a\z'
case 'az'   in  $bs ) echo bs1; esac
case '\a\z' in "$bs") echo bs2; esac
__IN__
bs1
bs2
__OUT__

test_oE 'pattern matching and quotes (*)'
case '*ab' in
    \*\*\*) echo not reached;;
    '***') echo not reached;;
     "***") echo not reached;;
    \**) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'pattern matching and quotes (?)'
case '?a' in
    \?\?) echo not reached;;
    '??') echo not reached;;
    "??") echo not reached;;
    \??) echo matched;;
esac
__IN__
matched
__OUT__

test_oE 'pattern matching and quotes ([])'
case '[a' in
    \[\[abc]) echo not reached;;
    '[['abc]) echo not reached;;
    "[["abc]) echo not reached;;
    \[[abc]) echo matched;;
esac
__IN__
matched
__OUT__

test_oE '* and ? match / and .'
case //-/-.-. in
    *-?-*-?) echo matched;;
esac
__IN__
matched
__OUT__

test_oe 'patterns are not expanded after first match'
case 1 in
    $(echo expanded 0 >&2; echo 0)) echo matched 0;;
    $(echo expanded 1 >&2; echo 1)) echo matched 1;;
    $(echo expanded 2 >&2; echo 2)) echo matched 2;;
esac
__IN__
matched 1
__OUT__
expanded 0
expanded 1
__ERR__

test_oE 'multiple patterns for single command list'
case 1 in
    a|b|c) echo not reached;;
    0   | 1     | 2 ) echo matched;;
esac
__IN__
matched
__OUT__

test_OE -e 0 'exit status of case command (unmatched, empty)'
false
case $(false) in
esac
__IN__

test_OE -e 0 'exit status of case command (unmatched, non-empty)'
case $(false) in
    1) true; (exit 11);;
    2) true; (exit 17);;
    3) true; (exit 19);;
esac
__IN__

# The behavior is POSIXly-unspecified for this case. See case-y.tst.
#test_OE -e 0 'exit status of case command (matched, empty)'

test_OE -e 17 'exit status of case command (matched, non-empty)'
case $(echo 2; exit 2) in
    1) true; (exit 11);;
    2) true; (exit 17);;
    3) true; (exit 19);;
esac
__IN__

test_oE -e 42 'executing item after ;&'
case 1 in
    0) echo not reached 0;;
    1) echo matched 1;&
    2) echo matched 2; (exit 42);&
esac
__IN__
matched 1
matched 2
__OUT__

test_oE 'exit status after empty ;& in case command'
(exit 1)
case i in
    i) ;&
    j) echo $?
esac
__IN__
1
__OUT__

test_oE 'patterns can be preceded by ('
case a in
    (a) echo matched 1;;
    (b) echo not reached 1 b;;
    (c) echo not reached 1 c;;
esac
case a in
     a) echo matched 2;;
    (b) echo not reached 2 b;;
     c) echo not reached 2 c;;
    (d) echo not reached 2 d;;
esac
__IN__
matched 1
matched 2
__OUT__

test_oE 'linebreak after word'
case foo

    in foo)echo matched;;esac
__IN__
matched
__OUT__

test_oE 'linebreak after in'
case foo in
    
    foo)echo matched;;esac
__IN__
matched
__OUT__

test_oE 'linebreak after )'
case foo in foo)
    
    echo matched;;esac
__IN__
matched
__OUT__

test_oE 'linebreak before ;;'
case foo in foo)echo matched

    ;;esac
__IN__
matched
__OUT__

test_oE '; before ;;'
case foo in foo)echo matched; ;;esac
__IN__
matched
__OUT__

test_oE '& before ;;'
case foo in foo)echo matched&;;esac
wait
__IN__
matched
__OUT__

test_oE 'linebreak after ;;'
case foo in bar)echo not reached;;
    
    foo)echo matched;;esac
__IN__
matched
__OUT__

test_oE 'linebreak before esac'
case foo in foo)echo matched;;

esac
__IN__
matched
__OUT__

test_oE ';; can be omitted before esac'
case 2 in
    0) echo a;;
    1) echo b;;
    2) echo c
esac
case 2 in
    0) echo A;;
    1) echo B;;
    2) echo C; esac
case 2 in
    0) echo A;;
    1) echo B;;
    *)
esac
case 2 in
    0) echo A;;
    1) echo B;;
    *) esac
__IN__
c
C
__OUT__

# $1 = LINENO
# $2 = reserved word
test_reserved_word_as_pattern() {
    testcase "$1" "reserved word $2 as pattern" 5<&- 3<<__IN__ 4<<\__OUT__
case $2 in $2) echo matched;; esac
__IN__
matched
__OUT__
}

test_reserved_word_as_pattern "$LINENO" !
test_reserved_word_as_pattern "$LINENO" {
test_reserved_word_as_pattern "$LINENO" }
test_reserved_word_as_pattern "$LINENO" [[
test_reserved_word_as_pattern "$LINENO" ]]
test_reserved_word_as_pattern "$LINENO" case
test_reserved_word_as_pattern "$LINENO" do
test_reserved_word_as_pattern "$LINENO" done
test_reserved_word_as_pattern "$LINENO" elif
test_reserved_word_as_pattern "$LINENO" else
#test_reserved_word_as_pattern "$LINENO" esac
test_reserved_word_as_pattern "$LINENO" fi
test_reserved_word_as_pattern "$LINENO" for
test_reserved_word_as_pattern "$LINENO" function
test_reserved_word_as_pattern "$LINENO" if
test_reserved_word_as_pattern "$LINENO" in
test_reserved_word_as_pattern "$LINENO" select
test_reserved_word_as_pattern "$LINENO" then
test_reserved_word_as_pattern "$LINENO" until
test_reserved_word_as_pattern "$LINENO" while

test_oE 'esac as first pattern'
case esac in (esac) echo matched;; esac
__IN__
matched
__OUT__

test_oE 'esac as non-first pattern'
case esac in -|esac) echo matched;; esac
__IN__
matched
__OUT__

test_oE 'redirection on case command'
case $(echo foo >&2) in
    $(echo bar >&2)) echo baz >&2;;
esac 2>redir_out
cat redir_out
__IN__
foo
bar
baz
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/cd-p.tst <<'EOF'
# cd-p.tst: test of the cd built-in for any POSIX-compliant shell

# Tests in this file may fail if the pathname of the current directory is too
# long, making the pathname of temporary directories exceed PATH_MAX.

posix="true"

cd -P .
export ORIGPWD="$PWD"
mkdir -p cdpath1/foo cdpath2/foo/bar cdpath2/dev dev
mkdir -m 400 no_search_dir
ln -s cdpath2/foo link
>file

test_oE 'default operand is HOME (-L)'
HOME=/dev
cd -L
echo --- $?
pwd
__IN__
--- 0
/dev
__OUT__

test_oE 'default operand is HOME (-P)'
HOME=/dev
cd -P
echo --- $?
pwd
__IN__
--- 0
/dev
__OUT__

(
# Ensure $PWD is safe to assign to $PATH
case $PWD in (*[:%]*)
    skip="true"
esac

testcase "$LINENO" 'found in first cd path (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -L foo
echo --- $?
pwd
__IN__
$ORIGPWD/cdpath1/foo
--- 0
$ORIGPWD/cdpath1/foo
__OUT__

testcase "$LINENO" 'found in first cd path (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -P foo
echo --- $?
pwd
__IN__
$ORIGPWD/cdpath1/foo
--- 0
$ORIGPWD/cdpath1/foo
__OUT__

testcase "$LINENO" 'found in last cd path (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -L foo/bar
echo --- $?
pwd
__IN__
$ORIGPWD/cdpath2/foo/bar
--- 0
$ORIGPWD/cdpath2/foo/bar
__OUT__

testcase "$LINENO" 'found in last cd path (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -P foo/bar
echo --- $?
pwd
__IN__
$ORIGPWD/cdpath2/foo/bar
--- 0
$ORIGPWD/cdpath2/foo/bar
__OUT__

testcase "$LINENO" 'found in empty cd path (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -L dev
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'found in empty cd path (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -P dev
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'found in dot cd path (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1:.:$ORIGPWD/cdpath2
cd -L dev
echo --- $?
pwd
__IN__
$ORIGPWD/dev
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'found in dot cd path (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1:.:$ORIGPWD/cdpath2
cd -P dev
echo --- $?
pwd
__IN__
$ORIGPWD/dev
--- 0
$ORIGPWD/dev
__OUT__

test_oE 'cd path ending with slash (-L)'
CDPATH=/
cd -L dev
echo --- $?
pwd
__IN__
/dev
--- 0
/dev
__OUT__

test_oE 'cd path ending with slash (-P)'
CDPATH=/
cd -P dev
echo --- $?
pwd
__IN__
/dev
--- 0
/dev
__OUT__

testcase "$LINENO" 'found not in any cd path, but in PWD (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1:$ORIGPWD/cdpath2
cd -L cdpath1
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/cdpath1
__OUT__

testcase "$LINENO" 'found not in any cd path, but in PWD (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1:$ORIGPWD/cdpath2
cd -P cdpath1
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/cdpath1
__OUT__

test_oE 'cd paths are ignored for absolute path operand (-L)'
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -L /dev
echo --- $?
pwd
__IN__
--- 0
/dev
__OUT__

test_oE 'cd paths are ignored for absolute path operand (-P)'
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -P /dev
echo --- $?
pwd
__IN__
--- 0
/dev
__OUT__

testcase "$LINENO" 'cd paths are ignored for operand starting with dot (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath2
cd -L ./dev
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'cd paths are ignored for operand starting with dot (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
CDPATH=$ORIGPWD/cdpath2
cd -P ./dev
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'cd paths are ignored for operand starting with dot-dot (-L)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
unset CDPATH
cd -L cdpath1
CDPATH=$ORIGPWD/cdpath2
cd ../dev
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'cd paths are ignored for operand starting with dot-dot (-P)' \
    3<<\__IN__ 5</dev/null 4<<__OUT__
unset CDPATH
cd -P cdpath1
CDPATH=$ORIGPWD/cdpath2
cd ../dev
echo --- $?
pwd
__IN__
--- 0
$ORIGPWD/dev
__OUT__

testcase "$LINENO" -d 'not found in any cd path nor in PWD (-L)' \
    3<<\__IN__ 5<&- 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -L _no_such_path_
echo --- $((!$?))
pwd
__IN__
--- 0
$ORIGPWD
__OUT__

testcase "$LINENO" -d 'not found in any cd path nor in PWD (-P)' \
    3<<\__IN__ 5<&- 4<<__OUT__
CDPATH=$ORIGPWD/cdpath1::$ORIGPWD/cdpath2
cd -P _no_such_path_
echo --- $((!$?))
pwd
__IN__
--- 0
$ORIGPWD
__OUT__

)

testcase "$LINENO" -d 'directory not found (with unset CDPATH, -L)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -L _no_such_path_
echo --- $((!$?))
pwd
__IN__
--- 0
$ORIGPWD
__OUT__

testcase "$LINENO" -d 'directory not found (with unset CDPATH, -P)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -P _no_such_path_
echo --- $((!$?))
pwd
__IN__
--- 0
$ORIGPWD
__OUT__

test_O -d -e n 'non-directory file in operand component (-L)'
cd -L ./file/../dev
__IN__

test_O -d -e n 'non-directory file in operand component (-P)'
cd -P ./file/../dev
__IN__

test_O -d -e n 'non-existing file in operand component (-L)'
cd -L ./_no_such_file_/../dev
__IN__

test_O -d -e n 'non-existing file in operand component (-P)'
cd -P ./_no_such_file_/../dev
__IN__

testcase "$LINENO" 'target pathname is canonicalized (-L)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -L link/./../dev/.
printf 'PWD=%s\n' "$PWD"
pwd
__IN__
PWD=$ORIGPWD/dev
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'symbolic links are resolved (in operand, -P)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -P link/./../dev/.
printf 'PWD=%s\n' "$PWD"
pwd
__IN__
PWD=$ORIGPWD/cdpath2/dev
$ORIGPWD/cdpath2/dev
__OUT__

testcase "$LINENO" 'symbolic links are resolved (in old PWD, -P)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -L link
cd -P ./../dev/.
printf 'PWD=%s\n' "$PWD"
pwd
__IN__
PWD=$ORIGPWD/cdpath2/dev
$ORIGPWD/cdpath2/dev
__OUT__

testcase "$LINENO" 'default option is -L' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd link/./../dev/.
printf 'PWD=%s\n' "$PWD"
pwd
__IN__
PWD=$ORIGPWD/dev
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'the last option wins (-L)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -P -L -PL link/./../dev/.
printf 'PWD=%s\n' "$PWD"
pwd
__IN__
PWD=$ORIGPWD/dev
$ORIGPWD/dev
__OUT__

testcase "$LINENO" 'the last option wins (-P)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -L -P -LP link/./../dev/.
printf 'PWD=%s\n' "$PWD"
pwd
__IN__
PWD=$ORIGPWD/cdpath2/dev
$ORIGPWD/cdpath2/dev
__OUT__

test_x -e 0 'exit status of success with -e'
cd -P -e .
__IN__

# There is no reliable way to test this case.
#test_x -e 1 'exit status of failure with -e'

test_x -e 0 'exit status of change error with -e'
cd -P -e _no_such_path_
[ $? -gt 1 ]
__IN__

(
# Skip if we're root.
if [ -d no_search_dir/. ]; then
    skip="true"
fi

test_O -d -e n 'changing to unsearchable directory (-L)'
cd -L no_search_dir
__IN__

test_O -d -e n 'changing to unsearchable directory (-P)'
cd -P no_search_dir
__IN__

)

test_oE 'hyphen operand means OLDPWD (-L)'
OLDPWD=/dev
cd -L -
echo --- $?
pwd
__IN__
/dev
--- 0
/dev
__OUT__

test_oE 'hyphen operand means OLDPWD (-P)'
OLDPWD=/dev
cd -P -
echo --- $?
pwd
__IN__
/dev
--- 0
/dev
__OUT__

testcase "$LINENO" 'OLDPWD is set to old PWD (-L)' \
    3<<\__IN__ 5<&- 4<<__OUT__
unset CDPATH
cd -L /
printf 'OLDPWD=%s\n' "$OLDPWD"
__IN__
OLDPWD=$ORIGPWD
__OUT__

test_O -d -e n 'empty operand (-L)'
cd -L ''
__IN__

test_O -d -e n 'empty operand (-P)'
cd -P ''
__IN__

test_O -d -e n 'readonly PWD (-L)'
# As specified in POSIX XBD 8.1, one of the following should happen:
# - The readonly built-in fails.
# - The cd built-in fails.
# - The cd built-in succeeds as if the readonly built-in had not been executed.
readonly PWD && cd -L / &&
if [ "$PWD" = / ]; then
    printf 'PWD successfully changed\n' >&2
    false # The expected exit status of this test is non-zero.
fi
__IN__

test_O -d -e n 'readonly PWD (-P)'
# As specified in POSIX XBD 8.1, one of the following should happen:
# - The readonly built-in fails.
# - The cd built-in fails.
# - The cd built-in succeeds as if the readonly built-in had not been executed.
readonly PWD && cd -P / &&
if [ "$PWD" = / ]; then
    printf 'PWD successfully changed\n' >&2
    false # The expected exit status of this test is non-zero.
fi
__IN__

test_x -d -e n 'readonly OLDPWD (-L)'
# As specified in POSIX XBD 8.1, one of the following should happen:
# - The readonly built-in fails.
# - The cd built-in fails.
# - The cd built-in succeeds as if the readonly built-in had not been executed.
cd /
readonly OLDPWD && cd -L - &&
if [ "$OLDPWD" = / ]; then
    printf 'OLDPWD successfully changed\n' >&2
    false # The expected exit status of this test is non-zero.
fi
__IN__

test_x -d -e n 'readonly OLDPWD (-P)'
# As specified in POSIX XBD 8.1, one of the following should happen:
# - The readonly built-in fails.
# - The cd built-in fails.
# - The cd built-in succeeds as if the readonly built-in had not been executed.
cd /
readonly OLDPWD && cd -P - &&
if [ "$OLDPWD" = / ]; then
    printf 'OLDPWD successfully changed\n' >&2
    false # The expected exit status of this test is non-zero.
fi
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/cmdsub-p.tst <<'EOF1'
# cmdsub-p.tst: test of command substitution for any POSIX-compliant shell

posix="true"

> dummyfile
setup -d

test_oE -e 0 'result of command substitution'
a=$(echo a) && bracket $a`echo b`
__IN__
[ab]
__OUT__

test_oE 'command substitution executes in subshell'
a=a
b=$(a=x; echo b)
bracket $a$b
__IN__
[ab]
__OUT__

test_oE 'trailing newlines are removed'
a=$(printf 'x\ny') b=$(printf 'x\ny\n') c=$(printf 'x\n\ny\n\n\n\n')
bracket "$a" "$b" "$c"
__IN__
[x
y][x
y][x

y]
__OUT__

test_oE 'stdin is not redirected'
echo a | echo $(cat)
__IN__
a
__OUT__

test_oe -e 0 'stderr is not redirected'
bracket "$(echo x >&2)"
__IN__
[]
__OUT__
x
__ERR__

test_oE 'field splitting on result of command substitution'
bracket $(printf 'a\n\nb')
__IN__
[a][b]
__OUT__

test_oE 'backslash in backquotes / nested backquotes'
echoraw `echoraw \`echoraw x\``
echoraw `echoraw '\$y'`
echoraw `printf '%s\n' \\\\`
__IN__
x
$y
\
__OUT__

test_oE 'quotations in backquotes'
echoraw `echoraw "a"'b'`
echoraw `echoraw \$ "\$" '\$'`
echoraw `echoraw \\\\ "\\\\" '\\\\'`
echoraw `echoraw \" "\"" '\"'`
echoraw `echoraw \' "\'"`
echoraw `echoraw \`echo a\` "\`echo b\`" '\`echo c\`'`
__IN__
ab
$ $ $
\ \ \\
" " \"
' \'
a b `echo c`
__OUT__

test_oE 'quotations in backquotes in double quotes'
echoraw "`echoraw "a"'b'`"
echoraw "`echoraw \$ "\$" '\$'`"
echoraw "`echoraw \\\\ "\\\\" '\\\\'`"
echoraw "`echoraw \"1\"`"
echoraw "`echoraw \'2\'`"
echoraw "`echoraw \`echo a\` "\`echo b\`" '\`echo c\`'`"
__IN__
ab
$ $ $
\ \ \\
1
'2'
a b `echo c`
__OUT__

test_oE 'quotations in backquotes in here-document'
cat <<END
`echoraw \"1\"`
" `echoraw \"2\"` "
END
__IN__
1
" 2 "
__OUT__

test_oE 'quotations in command substitution'
echoraw "$(echoraw ")\$"')\$'\)\$)"
__IN__
)$)\$)$
__OUT__

test_oE 'comment in command substitution'
echoraw "$(
echo a # ) comment
)"
__IN__
a
__OUT__

test_oE 'case command in command substitution'
echoraw "$(
case a in
(a) echo x;;
 *) echo not reached;;
esac
)"
__IN__
x
__OUT__

test_oE 'here-document in command substitution'
echoraw "$(cat <<\END
foo)
END
)"
__IN__
foo)
__OUT__

test_oE 'command substitution between here-document operator and body'
cat <<\OUTER; echoraw "$(cat <<\INNER
inner
INNER
)"
outer
OUTER
__IN__
outer
inner
__OUT__

test_oE 'result of command substitution is not subject to further expansion'
a=A HOME=home
echoraw $(echoraw '~/$a$()$((1))``')
echoraw "$(echoraw '~/$a$()$((1))``')"
__IN__
~/$a$()$((1))``
~/$a$()$((1))``
__OUT__

test_oE 'field splitting on result of command substitution'
bracket $(echoraw 'A B  C')
bracket "$(echoraw 'A B  C')"
__IN__
[A][B][C]
[A B  C]
__OUT__

test_oE 'pathname expansion on result of command substitution'
bracket $(echoraw 'dumm*ile')
bracket "$(echoraw 'dumm*ile')"
__IN__
[dummyfile]
[dumm*ile]
__OUT__

test_oE 'nested command substitutions'
echo $( (echo $(echo $(echo x))))
__IN__
x
__OUT__

# This test case is based on rationale of POSIX. The shell reaches the end of
# script before finding the end of arithmetic expansion and reports a syntax
# error, even if it could have been parsed as a well-formed command
# substitution.
test_O -d -e n 'ambiguity with arithmetic expansion, missing many )s'
echoraw $((cat <<EOF
+((((
EOF
) && (
cat <<EOF
+
EOF
))
__IN__
#))))

test_O -d -e n 'ambiguity with arithmetic expansion, missing one )' -c \
'echo $((cat <<EOF
+(
EOF
))'
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF1
put yash/command-p.tst <<'EOF'
# command-p.tst: test of the command built-in for any POSIX-compliant shell

posix="true"

test_o 'redirection error on special built-in does not kill shell'
command : <_no_such_file_
echo reached
__IN__
reached
__OUT__

test_o 'dot script not found does not kill shell'
command . ./_no_such_file_
echo reached
__IN__
reached
__OUT__

test_o 'assignment on special built-in is temporary'
a=a
a=b command :
echo $a
__IN__
a
__OUT__

test_OE -e 0 'command ignores function (mandatory built-in)'
alias () { false; }
command alias
__IN__

test_E -e 0 'command ignores function (substitutive built-in)'
echo () { false; }
command echo
__IN__

test_OE -e 0 'command ignores function (external command)'
cat () { false; }
command cat </dev/null
__IN__

test_oE -e 0 'command exec retains redirection'
command exec 3<<\__END__
here
__END__
cat <&3
__IN__
here
__OUT__

test_oE 'effect on environment'
command read a <<\__END__
foo
__END__
echo $a
__IN__
foo
__OUT__

test_o -e 0 'executing with standard path'
PATH=
command -p echo foo bar | command -p cat
__IN__
foo bar
__OUT__

(
setup 'set -e'

test_oE -e 0 'describing reserved word ! (-v)'
command -v !
__IN__
!
__OUT__

test_oE -e 0 'describing reserved word { (-v)'
command -v {
__IN__
{
__OUT__

test_oE -e 0 'describing reserved word } (-v)'
command -v }
__IN__
}
__OUT__

test_oE -e 0 'describing reserved word case (-v)'
command -v case
__IN__
case
__OUT__

test_oE -e 0 'describing reserved word do (-v)'
command -v do
__IN__
do
__OUT__

test_oE -e 0 'describing reserved word done (-v)'
command -v done
__IN__
done
__OUT__

test_oE -e 0 'describing reserved word elif (-v)'
command -v elif
__IN__
elif
__OUT__

test_oE -e 0 'describing reserved word else (-v)'
command -v else
__IN__
else
__OUT__

test_oE -e 0 'describing reserved word esac (-v)'
command -v esac
__IN__
esac
__OUT__

test_oE -e 0 'describing reserved word fi (-v)'
command -v fi
__IN__
fi
__OUT__

test_oE -e 0 'describing reserved word for (-v)'
command -v for
__IN__
for
__OUT__

test_oE -e 0 'describing reserved word if (-v)'
command -v if
__IN__
if
__OUT__

test_oE -e 0 'describing reserved word in (-v)'
command -v in
__IN__
in
__OUT__

test_oE -e 0 'describing reserved word then (-v)'
command -v then
__IN__
then
__OUT__

test_oE -e 0 'describing reserved word until (-v)'
command -v until
__IN__
until
__OUT__

test_oE -e 0 'describing reserved word while (-v)'
command -v while
__IN__
while
__OUT__

test_E -e 0 'describing reserved word (-V)'
command -V !
__IN__

test_oE -e 0 'describing special built-in (-v)'
command -v :
__IN__
:
__OUT__

test_E -e 0 'describing special built-in (-V)'
command -V :
__IN__

test_x -e 0 'exit status of describing non-special built-in (-v)'
command -v echo
__IN__

test_x -e 0 'exit status of describing non-special built-in (-V)'
command -V echo
__IN__

test_E -e 0 'output of describing non-special built-in (-v)'
command -v echo | grep '^/'
__IN__

test_x -e 0 'output of describing non-special built-in (-V)'
command -V echo | grep -F "$(command -v echo)"
__IN__

test_x -e 0 'exit status of describing external command (-v, no slash)'
command -v cat
__IN__

test_x -e 0 'exit status of describing external command (-V, no slash)'
command -V cat
__IN__

test_E -e 0 'output of describing external command (-v, no slash)'
command -v cat | grep '^/'
__IN__

test_E -e 0 'output of describing external command (-V, no slash)'
command -V cat | grep -F "$(command -v cat)"
__IN__

>foo
chmod a+x foo

test_x -e 0 'exit status of describing external command (-v, with slash)'
command -v ./foo
__IN__

test_x -e 0 'exit status of describing external command (-V, with slash)'
command -V ./foo
__IN__

test_E -e 0 'output of describing external command (-v, with slash)'
command -v ./foo | grep '^/' | grep '/foo$'
__IN__

test_E -e 0 'output of describing external command (-V, with slash)'
command -V ./foo | grep -F "$(command -v ./foo)"
__IN__

test_oE -e 0 'describing function (-v)'
cat() { :; }
command -v cat
__IN__
cat
__OUT__

test_E -e 0 'describing function (-V)'
cat() { :; }
command -V cat
__IN__

test_oE -e 0 'describing alias (-v)'
alias abc='echo ABC'
command="$(command -v abc)"
unalias abc
eval "$command"
abc
__IN__
ABC
__OUT__

test_OE -e 0 'describing alias (-V)'
alias abc=xyz
d="$(command -V abc)"
case "$d" in
    (*abc*xyz*|*xyz*abc*) # expected output contains alias name and value
        ;;
    (*)
        printf '%s\n' "$d" # print non-conforming result
        ;;
esac
__IN__

test_OE -e n 'describing non-existent command (-v)'
PATH=
command -v _no_such_command_
__IN__

test_x -e n 'describing non-existent command (-V)'
PATH=
command -V _no_such_command_
__IN__

test_x -e 0 'describing external command with standard path (-v)'
PATH=
command -pv cat
__IN__

test_x -e 0 'describing external command with standard path (-V)'
PATH=
command -pV cat
__IN__

)

test_O -d -e 127 'executing non-existent command'
command ./_no_such_command_
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/comment-p.tst <<'EOF'
# comment-p.tst: test of comments for any POSIX-compliant shell

posix="true"

test_OE 'comment without command'
#

# foo

#	bar
 #
	#

##foo
###
__IN__

test_oE 'comment ending with backslash'
# \
echo foo
__IN__
foo
__OUT__

test_oE 'comment in simple command'
v=abc sh -c 'echo $v "$@"' # 0 1 2 3
echo 123 # 456 # 789; echo xyz
</dev/null # < foo
__IN__
abc
123
__OUT__

test_oE 'hash sign in word'
v=abc#def
echo 123#456 $v
echo {# #"
__IN__
123#456 abc#def
{#
__OUT__

test_oE 'comment in pipeline'
echo foo |###
cat #|:
__IN__
foo
__OUT__

test_oE 'comment in and-or list'
echo foo &&###
echo bar ||###
echo baz
__IN__
foo
bar
__OUT__

test_oE 'comment after (a)synchronous list'
echo foo&###
wait;###
__IN__
foo
__OUT__

test_oE 'comment in grouping'
{ ###
    echo foo ###
} ###
__IN__
foo
__OUT__

test_oE 'comment in subshell'
(###
    echo foo ###
)###
__IN__
foo
__OUT__

test_oE 'comment in for loop'
for v ###
in 1 2 3 ###
do ###
    echo $v ###
done </dev/null ###
__IN__
1
2
3
__OUT__

test_oE 'comment in case statement'
case 1 ###
in ### esac
### esac
0)### esac
###
;;###
###
(1|2)# esac
    echo foo # esac
    echo bar #;;
    ;;###
###
esac </dev/null ###
__IN__
foo
bar
__OUT__

test_oE 'comment in if statement'
if ###
    ###
    echo foo
    false
    ###
then ###
    ###
    :
    ###
elif ###
    ###
    echo bar
    ###
then ###
    ###
    echo baz
    ###
else ###
    ###
    echo qux
    ###
fi </dev/null ###
__IN__
foo
bar
baz
__OUT__

test_oE 'comment in while loop'
while ###
    ###
    ! echo foo
    ###
do ###
    ###
    echo not reached
    ###
done </dev/null ###
__IN__
foo
__OUT__

test_oE 'comment in until loop'
until ###
    ###
    echo foo
    ###
do ###
    ###
    echo not reached
    ###
done </dev/null ###
__IN__
foo
__OUT__

test_OE 'comment in function definition'
func()###
###
{ ###
    :
} ###
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/continue-p.tst <<'EOF'
# continue-p.tst: test of the continue built-in for any POSIX-compliant shell

posix="true"

test_oE 'continuing one for loop, unnested'
for i in 1 2 3; do
    echo in $i
    continue 1
    echo out $i
done
echo done $?
__IN__
in 1
in 2
in 3
done 0
__OUT__

test_oE 'continuing one while loop, unnested'
i=1
while [ $i -le 3 ]; do
    echo in $i
    i=$((i+1))
    continue 1
    echo out $i
done
echo done $?
__IN__
in 1
in 2
in 3
done 0
__OUT__

test_oE 'continuing one until loop, unnested'
i=1
until [ $i -gt 3 ]; do
    echo in $i
    i=$((i+1))
    continue 1
    echo out $i
done
echo done $?
__IN__
in 1
in 2
in 3
done 0
__OUT__

test_oE 'continuing one for loop, nested in for loop'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        continue 1
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 b
in 1 c
out 1
in 2
in 2 a
in 2 b
in 2 c
out 2
in 3
in 3 a
in 3 b
in 3 c
out 3
done 0
__OUT__

test_oE 'continuing one for loop, nested in while loop'
i=1
while [ $i -le 3 ]; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        continue 1
        echo out $i $j
    done
    echo out $i
    i=$((i+1))
done
echo done $?
__IN__
in 1
in 1 a
in 1 b
in 1 c
out 1
in 2
in 2 a
in 2 b
in 2 c
out 2
in 3
in 3 a
in 3 b
in 3 c
out 3
done 0
__OUT__

test_oE 'continuing one while loop, nested in while loop'
i=1
while [ $i -le 3 ]; do
    echo in outer $i
    j=1
    while [ $j -le 3 ]; do
        echo in inner $i $j
        j=$((j+1))
        continue 1
        echo out inner $i $j
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1 1
in inner 1 2
in inner 1 3
out outer 1
in outer 2
in inner 2 1
in inner 2 2
in inner 2 3
out outer 2
in outer 3
in inner 3 1
in inner 3 2
in inner 3 3
out outer 3
done 0
__OUT__

test_oE 'continuing one while loop, nested in until loop'
i=1
until [ $i -gt 3 ]; do
    echo in outer $i
    j=1
    while [ $j -le 3 ]; do
        echo in inner $i $j
        j=$((j+1))
        continue 1
        echo out inner $i $j
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1 1
in inner 1 2
in inner 1 3
out outer 1
in outer 2
in inner 2 1
in inner 2 2
in inner 2 3
out outer 2
in outer 3
in inner 3 1
in inner 3 2
in inner 3 3
out outer 3
done 0
__OUT__

test_oE 'continuing one until loop, nested in until loop'
i=1
until [ $i -gt 3 ]; do
    echo in outer $i
    j=1
    until [ $j -gt 3 ]; do
        echo in inner $i $j
        j=$((j+1))
        continue 1
        echo out inner $i $j
    done
    echo out outer $i
    i=$((i+1))
done
echo done $?
__IN__
in outer 1
in inner 1 1
in inner 1 2
in inner 1 3
out outer 1
in outer 2
in inner 2 1
in inner 2 2
in inner 2 3
out outer 2
in outer 3
in inner 3 1
in inner 3 2
in inner 3 3
out outer 3
done 0
__OUT__

test_oE 'continuing two for loops, outermost'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        continue 2
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 2
in 2 a
in 3
in 3 a
done 0
__OUT__

test_oE 'continuing for and while loops, outermost'
i=1
while [ $i -le 3 ]; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        i=$((i+1))
        continue 2
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 2
in 2 a
in 3
in 3 a
done 0
__OUT__

test_oE 'continuing two while loops, outermost'
i=1
while [ $i -le 3 ]; do
    echo in outer $i
    while true; do
        echo in inner $i
        i=$((i+1))
        continue 2
        echo out inner $i
    done
    echo out outer $i
done
echo done $?
__IN__
in outer 1
in inner 1
in outer 2
in inner 2
in outer 3
in inner 3
done 0
__OUT__

test_oE 'continuing while and until loops, outermost'
i=1
until [ $i -gt 3 ]; do
    echo in outer $i
    while true; do
        echo in inner $i
        i=$((i+1))
        continue 2
        echo out inner $i
    done
    echo out outer $i
done
echo done $?
__IN__
in outer 1
in inner 1
in outer 2
in inner 2
in outer 3
in inner 3
done 0
__OUT__

test_oE 'continuing two for loops, nested in another for loop'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        for k in + -; do
            echo in $i $j $k
            continue 2
            echo out $i $j $k
        done
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 a +
in 1 b
in 1 b +
in 1 c
in 1 c +
out 1
in 2
in 2 a
in 2 a +
in 2 b
in 2 b +
in 2 c
in 2 c +
out 2
in 3
in 3 a
in 3 a +
in 3 b
in 3 b +
in 3 c
in 3 c +
out 3
done 0
__OUT__

test_oE 'continuing three for loops, outermost'
for i in 1 2 3; do
    echo in $i
    for j in a b c; do
        echo in $i $j
        for k in + -; do
            echo in $i $j $k
            continue 3
            echo out $i $j $k
        done
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 a +
in 2
in 2 a
in 2 a +
in 3
in 3 a
in 3 a +
done 0
__OUT__

test_oE 'default operand is 1'
for i in 1; do
    echo in $i
    for j in a; do
        echo in $i $j
        for k in + -; do
            echo in $i $j $k
            continue
            echo out $i $j $k
        done
        echo out $i $j
    done
    echo out $i
done
echo done $?
__IN__
in 1
in 1 a
in 1 a +
in 1 a -
out 1 a
out 1
done 0
__OUT__

test_OE -e 0 'exit status of continue with $? > 0'
for i in 1; do
    false
    continue
done
__IN__

test_O -d -e n 'zero operand'
for i in 1; do
    continue 0
done
__IN__

test_OE 'continuing one more than actual nest level one'
for i in 1; do
    continue 2
    echo not reached
done
__IN__

test_OE 'continuing one more than actual nest level two'
for i in 1; do
    for j in a; do
        continue 3
        echo not reached 1
    done
    echo not reached 2
done
__IN__

test_OE 'continuing much more than actual nest level one'
for i in 1; do
    continue 100
    echo not reached
done
__IN__

# This is a questionable case. Is this really a "lexically enclosing" loop as
# defined in POSIX? Most shells do support this case.
test_oE 'continuing out of eval'
for i in 1 2; do
    echo $i
    eval continue
    echo not reached
done
__IN__
1
2
__OUT__

test_OE 'continuing with !'
for i in 1; do
    ! continue
    echo not reached
done
__IN__

test_OE 'continuing before &&'
for i in 1; do
    continue && echo not reached 1
    echo not reached 2 $?
done
__IN__

test_OE 'continuing after &&'
for i in 1; do
    true && continue
    echo not reached $?
done
__IN__

test_OE 'continuing before ||'
for i in 1; do
    continue || echo not reached 1
    echo not reached 2 $?
done
__IN__

test_OE 'continuing after ||'
for i in 1; do
    false || continue
    echo not reached $?
done
__IN__

test_OE 'continuing out of brace'
for i in 1; do
    { continue; }
    echo not reached
done
__IN__

test_OE 'continuing out of if'
for i in 1; do
    if continue; then echo not reached then; else echo not reached else; fi
    echo not reached
done
__IN__

test_OE 'continuing out of then'
for i in 1; do
    if true; then continue; echo not reached then; else not reached else; fi
    echo not reached
done
__IN__

test_OE 'continuing out of else'
for i in 1; do
    if false; then echo not reached then; else continue; not reached else; fi
    echo not reached
done
__IN__

test_OE 'continuing out of case'
for i in 1; do
    case x in
        x)
            continue
            echo not reached in case
    esac
    echo not reached after esac
done
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/declutil-p.tst <<'EOF'
# declutil-p.tst: test of declaration utilities for any POSIX-compliant shell

posix="true"

# Pathname expansion may match this dummy file in incorrect implementations.
>tmpfile

test_oE 'no pathname expansion or field splitting in export A=$a'
a="1  *  2"
export A=$a
sh -c 'printf "%s\n" "$A"'
__IN__
1  *  2
__OUT__

test_oE 'tilde expansions in export A=~:~' 
HOME=/foo
export A=~:~
sh -c 'printf "%s\n" "$A"'
__IN__
/foo:/foo
__OUT__

test_oE 'pathname expansion and field splitting in export $a'
A=foo B=bar a='A B'
export $a
sh -c 'printf "%s\n" "$A" "$B"'
__IN__
foo
bar
__OUT__

test_oE 'no pathname expansion or field splitting in readonly A=$a'
a="1  *  2"
readonly A=$a
printf "%s\n" "$A"
__IN__
1  *  2
__OUT__

test_oE 'tilde expansions in readonly A=~:~'
HOME=/foo
readonly A=~:~
printf "%s\n" "$A"
__IN__
/foo:/foo
__OUT__

test_oE 'pathname expansion and field splitting in readonly $a'
A=foo B=bar a='A B'
readonly $a
printf "%s\n" "$A" "$B"
__IN__
foo
bar
__OUT__

test_oE 'command command export'
a="1  *  2"
command command export A=$a
sh -c 'printf "%s\n" "$A"'
__IN__
1  *  2
__OUT__

test_oE 'command command readonly'
a="1  *  2"
command command readonly A=$a
printf "%s\n" "$A"
__IN__
1  *  2
__OUT__

# POSIX allows any utility to be a declaration utility as an extension,
# so there are no tests to check that a utility is not a declaration utility.

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/dot-p.tst <<'EOF'
# dot-p.tst: test of the dot built-in for any POSIX-compliant shell

posix="true"

cat <<\__END__ >file1
echo $?
(exit 3)
__END__

cat <<\__END__ >file2
echo in
. ./file1
echo out
__END__

cat <<\__END__ >file3
exit 11
__END__

test_OE -e 0 'empty dot script'
(exit 1)
. /dev/null
__IN__

test_oE -e 3 'non-empty dot script'
(exit 5)
. ./file1
__IN__
5
__OUT__

test_oE -e 0 'recursive dot script'
. ./file2
__IN__
in
0
out
__OUT__

test_e 'with verbose option' -v
. ./file3
__IN__
. ./file3
exit 11
__ERR__

test_oE -e 3 'option-operand separator'
(exit 5)
. -- ./file1
__IN__
5
__OUT__

(
# Ensure $PWD is safe to assign to $PATH
case $PWD in (*[:%]*)
    skip="true"
esac

setup 'savepath=$PATH; PATH=$PWD'

test_OE -e 11 'dot script in $PATH'
. file3
__IN__

test_O -d -e n 'dot script not found, in $PATH, non-interactive shell'
. _no_such_file_
PATH=$savepath
echo not reached
__IN__

test_o -d 'dot script not found, in $PATH, subshell, exiting'
(. _no_such_file_)
PATH=$savepath
echo reached
__IN__
reached
__OUT__

test_O -d -e n 'dot script not found, in $PATH, subshell, exit status'
(. _no_such_file_)
__IN__

test_o -d 'dot script not found, in $PATH, interactive shell, no exiting' -i +m
. _no_such_file_
PATH=$savepath
echo reached
__IN__
reached
__OUT__

test_O -d -e n 'dot script not found, in $PATH, interactive shell, exit status' -i +m
. _no_such_file_
__IN__

)

test_O -d -e n 'dot script not found, relative, non-interactive shell'
. ./_no_such_file_
echo not reached
__IN__

test_o -d 'dot script not found, relative, subshell, exiting'
(. ./_no_such_file_)
echo reached
__IN__
reached
__OUT__

test_O -d -e n 'dot script not found, relative, subshell, exit status'
(. ./_no_such_file_)
__IN__

test_o -d 'dot script not found, relative, interactive shell, no exiting' -i +m
. ./_no_such_file_
echo reached
__IN__
reached
__OUT__

test_O -d -e n 'dot script not found, relative, interactive shell, exit status' -i +m
. ./_no_such_file_
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/errexit-p.tst <<'EOF'
# errexit-p.tst: test of the errexit option for any POSIX-compliant shell

posix="true"

test_o -e 0 'noerrexit: successful simple command'
true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: successful simple command' -e
true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: failed simple command'
false
echo reached
__IN__
reached
__OUT__

test_O -e n 'errexit: failed simple command' -e
false
echo not reached
__IN__

test_o -e 0 'noerrexit: independent redirection error'
<_no_such_file_
echo reached
__IN__
reached
__OUT__

test_O -e n 'errexit: independent redirection error' -e
<_no_such_file_
echo not reached
__IN__

test_o -e 0 'noerrexit: redirection error on simple command'
echo not printed <_no_such_file_
echo reached
__IN__
reached
__OUT__

test_O -e n 'errexit: redirection error on simple command' -e
echo not printed <_no_such_file_
echo not reached
__IN__

test_o -e 0 'noerrexit: middle of pipeline'
false | false | true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: middle of pipeline' -e
false | false | true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: last of pipeline'
true | true | false
echo reached
__IN__
reached
__OUT__

test_O -e n 'errexit: last of pipeline' -e
true | true | false
echo not reached
__IN__

test_o -e 0 'noerrexit: negated pipeline'
! false | false | true
! true | true | false
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: negated pipeline' -e
! false | false | true
! true | true | false
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: initially failing and list'
false && ! echo not reached && ! echo not reached
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: initially failing and list' -e
false && ! echo not reached && ! echo not reached
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: finally failing and list'
true && true && false
echo reached
__IN__
reached
__OUT__

test_O -e n 'errexit: finally failing and list' -e
true && true && false
echo not reached
__IN__

test_o -e 0 'noerrexit: all succeeding and list'
true && true && true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: all succeeding and list' -e
true && true && true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: initially succeeding or list'
true || echo not reached || echo not reached
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: initially succeeding or list' -e
true || echo not reached || echo not reached
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: finally succeeding or list'
false || false || true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: finally succeeding or list' -e
false || false || true
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: all failing or list'
false || false || false
echo reached
__IN__
reached
__OUT__

test_O -e n 'errexit: all failing or list' -e
false || false || false
echo not reached
__IN__

test_o -e 0 'noerrexit: subshell'
(echo reached 1; false; echo reached 2) | cat
(echo reached 3; false; echo reached 4)
echo reached 5
__IN__
reached 1
reached 2
reached 3
reached 4
reached 5
__OUT__

test_o -e n 'errexit: subshell' -e
(echo reached 1; false; echo not reached 2) | cat
(echo reached 3; false; echo not reached 4)
echo not reached 5
__IN__
reached 1
reached 3
__OUT__

test_o -e 0 'noerrexit: grouping'
{ echo reached 1; false; echo reached 2; } | cat
{ echo reached 3; false; echo reached 4; }
echo reached 5
__IN__
reached 1
reached 2
reached 3
reached 4
reached 5
__OUT__

test_o -e n 'errexit: grouping' -e
{ echo reached 1; false; echo not reached 2; } | cat
{ echo reached 3; false; echo not reached 4; }
echo not reached 5
__IN__
reached 1
reached 3
__OUT__

test_o -e 0 'noerrexit: for loop body'
for i in 1 2 3; do
    echo a $i
    test $i -ne 2
    echo b $i
done
echo reached
__IN__
a 1
b 1
a 2
b 2
a 3
b 3
reached
__OUT__

test_o -e n 'errexit: for loop body' -e
for i in 1 2 3; do
    echo a $i
    test $i -ne 2
    echo b $i
done
echo not reached
__IN__
a 1
b 1
a 2
__OUT__

test_o -e 0 'noerrexit: case body'
case a in a)
    echo reached 1
    false
    echo reached 2
esac
echo reached 3
__IN__
reached 1
reached 2
reached 3
__OUT__

test_o -e n 'errexit: case body' -e
case a in a)
    echo reached 1
    false
    echo not reached 2
esac
echo not reached 3
__IN__
reached 1
__OUT__

test_o -e 0 'noerrexit: if condition'
if false; true; then
    echo reached 1
else
    echo not reached
fi
echo reached 2
__IN__
reached 1
reached 2
__OUT__

test_o -e 0 'errexit: if condition' -e
if false; true; then
    echo reached 1
else
    echo not reached
fi
echo reached 2
__IN__
reached 1
reached 2
__OUT__

test_o -e 0 'noerrexit: elif condition'
if false; then
    :
elif false; true; then
    echo reached 1
else
    echo not reached
fi
echo reached 2
__IN__
reached 1
reached 2
__OUT__

test_o -e 0 'errexit: elif condition' -e
if false; then
    :
elif false; true; then
    echo reached 1
else
    echo not reached
fi
echo reached 2
__IN__
reached 1
reached 2
__OUT__

test_o -e 0 'noerrexit: then body'
if true; then echo reached 1; false; echo reached 2; fi
echo reached 3
__IN__
reached 1
reached 2
reached 3
__OUT__

test_o -e n 'errexit: then body' -e
if true; then echo reached 1; false; echo not reached 2; fi
echo not reached 3
__IN__
reached 1
__OUT__

test_o -e 0 'noerrexit: else body'
if false; then :; else echo reached 1; false; echo reached 2; fi
echo reached 3
__IN__
reached 1
reached 2
reached 3
__OUT__

test_o -e n 'errexit: else body' -e
if false; then :; else echo reached 1; false; echo not reached 2; fi
echo not reached 3
__IN__
reached 1
__OUT__

test_o -e 0 'noerrexit: while condition'
while false; do
    :
done
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: while condition' -e
while false; do
    :
done
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: while body'
while true; do
    echo reached 1
    false
    echo reached 2
    break
done
echo reached 3
__IN__
reached 1
reached 2
reached 3
__OUT__

test_o -e n 'errexit: while body' -e
while true; do
    echo reached 1
    false
    echo not reached 2
    break
done
echo not reached 3
__IN__
reached 1
__OUT__

test_o -e 0 'noerrexit: until condition'
until false; true; do
    :
done
echo reached
__IN__
reached
__OUT__

test_o -e 0 'errexit: until condition' -e
until false; true; do
    :
done
echo reached
__IN__
reached
__OUT__

test_o -e 0 'noerrexit: until body'
until false; do
    echo reached 1
    false
    echo reached 2
    break
done
echo reached 3
__IN__
reached 1
reached 2
reached 3
__OUT__

test_o -e n 'errexit: until body' -e
until false; do
    echo reached 1
    false
    echo reached 2
    break
done
echo reached 3
__IN__
reached 1
__OUT__

test_O -e n 'ignored failure in subshell' -e
( false && true; )
echo not reached
__IN__

test_o -e 0 'ignored failure in grouping' -e
{ false && true; }
echo reached
__IN__
reached
__OUT__

test_o -e 0 'ignored failure in if body' -e
if true; then false && true; fi
echo reached
__IN__
reached
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/error-p.tst <<'EOF'
# error-p.tst: test of error conditions for any POSIX-compliant shell

posix="true"

test_O -d -e n 'syntax error kills non-interactive shell'
fi
echo not reached
__IN__

test_O -d -e n 'syntax error in eval kills non-interactive shell'
eval fi
echo not reached
__IN__

test_o -d 'syntax error in subshell'
(eval fi; echo not reached)
[ $? -ne 0 ]
echo $?
__IN__
0
__OUT__

test_o -d 'syntax error spares interactive shell' -i +m
fi
echo reached
__IN__
reached
__OUT__

test_o 'redirection error on compound command spares non-interactive shell'
if echo not printed 1; then echo not printed 2; fi <_no_such_dir_/foo
printf 'reached\n'
__IN__
reached
__OUT__

test_o 'redirection error on compound command in subshell'
(if echo not printed 1; then echo not printed 2; fi <_no_such_dir_/foo
[ \$? -ne 0 ]; printf 'reached %d\n' \$?)
__IN__
reached 0
__OUT__

test_o 'redirection error on compound command spares interactive shell' -i +m
if echo not printed 1; then echo not printed 2; fi <_no_such_dir_/foo
printf 'reached\n'
__IN__
reached
__OUT__

test_o 'redirection error on function spares non-interactive shell'
func() { echo not printed; }
func <_no_such_dir_/foo
printf 'reached\n'
__IN__
reached
__OUT__

test_o 'redirection error on function in subshell'
func() { echo not printed; }
(func <_no_such_dir_/foo; [ \$? -ne 0 ]; printf 'reached %d\n' \$?)
__IN__
reached 0
__OUT__

test_o 'redirection error on function spares interactive shell' -i +m
func() { echo not printed; }
func <_no_such_dir_/foo
printf 'reached\n'
__IN__
reached
__OUT__

test_O -d -e n 'expansion error kills non-interactive shell'
unset a
echo ${a?}
echo not reached
__IN__

test_o -d 'expansion error in subshell'
unset a
(echo ${a?}; echo not reached)
[ $? -ne 0 ]
echo $?
__IN__
0
__OUT__

test_o -d 'expansion error spares interactive shell' -i +m
unset a
echo ${a?}
[ $? -ne 0 ]
echo $?
__IN__
0
__OUT__

test_O -d -e 127 'command not found'
./_no_such_command_
__IN__

###############################################################################

test_O 'assignment error without command kills non-interactive shell'
readonly a=a
a=b
printf 'not reached\n'
__IN__

test_o 'assignment error without command in subshell'
readonly a=a
(a=b; printf 'not reached\n')
[ $? -ne 0 ]
echo $?
__IN__
0
__OUT__

test_o 'assignment error without command spares interactive shell' -i +m
readonly a=a
a=b
printf 'reached\n'
__IN__
reached
__OUT__

# $1 = line no.
# $2 = command name
test_assign() {
    testcase "$1" -d \
        "assignment error on command $2 kills non-interactive shell" \
        3<<__IN__ 4</dev/null 5<&-
readonly a=a
a=b $2
printf 'not reached\n'
__IN__
}

# $1 = line no.
# $2 = command name
test_assign_s() {
    testcase "$1" -d \
        "assignment error on command $2 in subshell" \
        3<<__IN__ 4<<\__OUT__ 5<&-
readonly a=a
(a=b $2; echo not reached)
[ \$? -ne 0 ]
echo \$?
__IN__
0
__OUT__
}

# $1 = line no.
# $2 = command name
test_assign_i() {
    testcase "$1" -d \
        "assignment error on command $2 spares interactive shell" \
        -i +m 3<<__IN__ 4<<\__OUT__ 5<&-
readonly a=a
a=b $2
printf 'reached\n'
__IN__
reached
__OUT__
}

test_assign   "$LINENO" :
test_assign_s "$LINENO" :
test_assign_i "$LINENO" :
test_assign   "$LINENO" .
test_assign_s "$LINENO" .
test_assign_i "$LINENO" .
test_assign   "$LINENO" [
test_assign_s "$LINENO" [
test_assign_i "$LINENO" [
test_assign   "$LINENO" alias
test_assign_s "$LINENO" alias
test_assign_i "$LINENO" alias
test_assign   "$LINENO" array
test_assign_s "$LINENO" array
test_assign_i "$LINENO" array
test_assign   "$LINENO" bg
test_assign_s "$LINENO" bg
test_assign_i "$LINENO" bg
test_assign   "$LINENO" bindkey
test_assign_s "$LINENO" bindkey
test_assign_i "$LINENO" bindkey
test_assign   "$LINENO" break
test_assign_s "$LINENO" break
test_assign_i "$LINENO" break
test_assign   "$LINENO" cat # example of external command
test_assign_s "$LINENO" cat
test_assign_i "$LINENO" cat
test_assign   "$LINENO" cd
test_assign_s "$LINENO" cd
test_assign_i "$LINENO" cd
test_assign   "$LINENO" command
test_assign_s "$LINENO" command
test_assign_i "$LINENO" command
test_assign   "$LINENO" complete
test_assign_s "$LINENO" complete
test_assign_i "$LINENO" complete
test_assign   "$LINENO" continue
test_assign_s "$LINENO" continue
test_assign_i "$LINENO" continue
test_assign   "$LINENO" dirs
test_assign_s "$LINENO" dirs
test_assign_i "$LINENO" dirs
test_assign   "$LINENO" disown
test_assign_s "$LINENO" disown
test_assign_i "$LINENO" disown
test_assign   "$LINENO" echo
test_assign_s "$LINENO" echo
test_assign_i "$LINENO" echo
test_assign   "$LINENO" eval
test_assign_s "$LINENO" eval
test_assign_i "$LINENO" eval
test_assign   "$LINENO" exec
test_assign_s "$LINENO" exec
test_assign_i "$LINENO" exec
test_assign   "$LINENO" exit
test_assign_s "$LINENO" exit
test_assign_i "$LINENO" exit
test_assign   "$LINENO" export
test_assign_s "$LINENO" export
test_assign_i "$LINENO" export
test_assign   "$LINENO" false
test_assign_s "$LINENO" false
test_assign_i "$LINENO" false
test_assign   "$LINENO" fc
test_assign_s "$LINENO" fc
test_assign_i "$LINENO" fc
test_assign   "$LINENO" fg
test_assign_s "$LINENO" fg
test_assign_i "$LINENO" fg
test_assign   "$LINENO" getopts
test_assign_s "$LINENO" getopts
test_assign_i "$LINENO" getopts
test_assign   "$LINENO" hash
test_assign_s "$LINENO" hash
test_assign_i "$LINENO" hash
test_assign   "$LINENO" help
test_assign_s "$LINENO" help
test_assign_i "$LINENO" help
test_assign   "$LINENO" history
test_assign_s "$LINENO" history
test_assign_i "$LINENO" history
test_assign   "$LINENO" jobs
test_assign_s "$LINENO" jobs
test_assign_i "$LINENO" jobs
test_assign   "$LINENO" kill
test_assign_s "$LINENO" kill
test_assign_i "$LINENO" kill
test_assign   "$LINENO" popd
test_assign_s "$LINENO" popd
test_assign_i "$LINENO" popd
test_assign   "$LINENO" printf
test_assign_s "$LINENO" printf
test_assign_i "$LINENO" printf
test_assign   "$LINENO" pushd
test_assign_s "$LINENO" pushd
test_assign_i "$LINENO" pushd
test_assign   "$LINENO" pwd
test_assign_s "$LINENO" pwd
test_assign_i "$LINENO" pwd
test_assign   "$LINENO" read
test_assign_s "$LINENO" read
test_assign_i "$LINENO" read
test_assign   "$LINENO" readonly
test_assign_s "$LINENO" readonly
test_assign_i "$LINENO" readonly
test_assign   "$LINENO" return
test_assign_s "$LINENO" return
test_assign_i "$LINENO" return
test_assign   "$LINENO" set
test_assign_s "$LINENO" set
test_assign_i "$LINENO" set
test_assign   "$LINENO" shift
test_assign_s "$LINENO" shift
test_assign_i "$LINENO" shift
test_assign   "$LINENO" suspend
test_assign_s "$LINENO" suspend
test_assign_i "$LINENO" suspend
test_assign   "$LINENO" test
test_assign_s "$LINENO" test
test_assign_i "$LINENO" test
test_assign   "$LINENO" times
test_assign_s "$LINENO" times
test_assign_i "$LINENO" times
test_assign   "$LINENO" trap
test_assign_s "$LINENO" trap
test_assign_i "$LINENO" trap
test_assign   "$LINENO" true
test_assign_s "$LINENO" true
test_assign_i "$LINENO" true
test_assign   "$LINENO" type
test_assign_s "$LINENO" type
test_assign_i "$LINENO" type
test_assign   "$LINENO" typeset
test_assign_s "$LINENO" typeset
test_assign_i "$LINENO" typeset
test_assign   "$LINENO" ulimit
test_assign_s "$LINENO" ulimit
test_assign_i "$LINENO" ulimit
test_assign   "$LINENO" umask
test_assign_s "$LINENO" umask
test_assign_i "$LINENO" umask
test_assign   "$LINENO" unalias
test_assign_s "$LINENO" unalias
test_assign_i "$LINENO" unalias
test_assign   "$LINENO" unset
test_assign_s "$LINENO" unset
test_assign_i "$LINENO" unset
test_assign   "$LINENO" wait
test_assign_s "$LINENO" wait
test_assign_i "$LINENO" wait
test_assign   "$LINENO" ./_no_such_command_
test_assign_s "$LINENO" ./_no_such_command_
test_assign_i "$LINENO" ./_no_such_command_

test_O 'assignment error in for loop kills non-interactive shell'
readonly a=a
for a in b
do
    printf 'not reached 1\n'
done
printf 'not reached 2\n'
__IN__

test_o 'assignment error in for loop spares interactive shell' -i +m
readonly a=a
for a in b
do
    :
done
printf 'reached\n'
__IN__
reached
__OUT__

# $1 = line no.
# $2 = built-in name
test_special_builtin_redirect() {
    testcase "$1" -d \
        "redirection error on special built-in $2 kills non-interactive shell" \
        3<<__IN__ 4</dev/null 5<&-
$2 <_no_such_file_
printf 'not reached\n'
__IN__
}

# $1 = line no.
# $2 = built-in name
test_special_builtin_redirect_s() {
    testcase "$1" -d \
        "redirection error on special built-in $2 in subshell" \
        3<<__IN__ 4<<\__OUT__ 5<&-
($2 <_no_such_file_; echo not reached)
[ \$? -ne 0 ]
echo \$?
__IN__
0
__OUT__
}

# $1 = line no.
# $2 = built-in name
test_special_builtin_redirect_i() {
    testcase "$1" -d \
        "redirection error on special built-in $2 spares interactive shell" \
        -i +m 3<<__IN__ 4<<\__OUT__ 5<&-
$2 <_no_such_file_
printf 'reached\n'
__IN__
reached
__OUT__
}

test_special_builtin_redirect   "$LINENO" :
test_special_builtin_redirect_s "$LINENO" :
test_special_builtin_redirect_i "$LINENO" :
test_special_builtin_redirect   "$LINENO" .
test_special_builtin_redirect_s "$LINENO" .
test_special_builtin_redirect_i "$LINENO" .
test_special_builtin_redirect   "$LINENO" break
test_special_builtin_redirect_s "$LINENO" break
test_special_builtin_redirect_i "$LINENO" break
test_special_builtin_redirect   "$LINENO" continue
test_special_builtin_redirect_s "$LINENO" continue
test_special_builtin_redirect_i "$LINENO" continue
test_special_builtin_redirect   "$LINENO" eval
test_special_builtin_redirect_s "$LINENO" eval
test_special_builtin_redirect_i "$LINENO" eval
test_special_builtin_redirect   "$LINENO" exec
test_special_builtin_redirect_s "$LINENO" exec
test_special_builtin_redirect_i "$LINENO" exec
test_special_builtin_redirect   "$LINENO" exit
test_special_builtin_redirect_s "$LINENO" exit
test_special_builtin_redirect_i "$LINENO" exit
test_special_builtin_redirect   "$LINENO" export
test_special_builtin_redirect_s "$LINENO" export
test_special_builtin_redirect_i "$LINENO" export
test_special_builtin_redirect   "$LINENO" readonly
test_special_builtin_redirect_s "$LINENO" readonly
test_special_builtin_redirect_i "$LINENO" readonly
test_special_builtin_redirect   "$LINENO" return
test_special_builtin_redirect_s "$LINENO" return
test_special_builtin_redirect_i "$LINENO" return
test_special_builtin_redirect   "$LINENO" set
test_special_builtin_redirect_s "$LINENO" set
test_special_builtin_redirect_i "$LINENO" set
test_special_builtin_redirect   "$LINENO" shift
test_special_builtin_redirect_s "$LINENO" shift
test_special_builtin_redirect_i "$LINENO" shift
test_special_builtin_redirect   "$LINENO" times
test_special_builtin_redirect_s "$LINENO" times
test_special_builtin_redirect_i "$LINENO" times
test_special_builtin_redirect   "$LINENO" trap
test_special_builtin_redirect_s "$LINENO" trap
test_special_builtin_redirect_i "$LINENO" trap
test_special_builtin_redirect   "$LINENO" unset
test_special_builtin_redirect_s "$LINENO" unset
test_special_builtin_redirect_i "$LINENO" unset

test_o 'redirection error on non-special built-in cd spares shell'
cd <_no_such_file_
test $? -ne 0 && echo ok
__IN__
ok
__OUT__

test_o 'redirection error on non-existing command spares shell'
./_no_such_command_ <_no_such_file_
test $? -ne 0 && echo ok
__IN__
ok
__OUT__

test_o 'redirection error without command spares shell'
<_no_such_file_
test $? -ne 0 && echo ok
__IN__
ok
__OUT__

# Command syntax error for special built-ins is not tested here because we can
# not portably cause syntax error since any syntax can be accepted as an
# extension.

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/eval-p.tst <<'EOF'
# eval-p.tst: test of the eval built-in for any POSIX-compliant shell

posix="true"

test_OE -e 0 'evaluating no operands'
false
eval
__IN__

test_OE -e 0 'evaluating null operands'
false
eval '' '' ''
__IN__

test_oE -e 0 'evaluating some commands'
eval 'echo foo; echo bar'
__IN__
foo
bar
__OUT__

test_oE -e 0 'separator preceding operand'
eval -- 'echo foo'
__IN__
foo
__OUT__

test_oE -e 0 'operands are concatenated with spaces in-between'
eval 'echo foo' 'echo bar'
eval 'echo 1"' '' '"2'
__IN__
foo echo bar
1  2
__OUT__

test_OE -e 23 'exit status of evaluation'
eval '(exit 23)'
__IN__

test_oE -e 0 'effect on environment in evaluation'
a=foo
eval 'a=bar'
echo $a
eval exit
echo not reached
__IN__
bar
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/exec-p.tst <<'EOF'
# exec-p.tst: test of the exec built-in for any POSIX-compliant shell

posix="true"

(
setup 'set -e'

test_oE 'exec without arguments'
exec
echo reached
__IN__
reached
__OUT__

test_oE 'exec without arguments but -- separator'
exec --
echo $?
__IN__
0
__OUT__

test_Oe 'exec with redirections'
exec >&2 2>/dev/null
echo reached
./_no_such_command_
__IN__
reached
__ERR__

test_Oe -e n 'exec with redirections in grouping'
{ exec 4>&3; } 3>&2
echo foo >&4
{ exec >&3; } 2>/dev/null
__IN__
foo
__ERR__

)

test_oE -e 0 'executing external command'
exec echo foo bar
echo not reached
__IN__
foo bar
__OUT__

test_OE -e 0 'executing external command with option'
exec cat -u /dev/null
__IN__

test_OE -e 0 'executing external command with -- separator'
exec -- cat /dev/null
__IN__

test_OE -e 0 'process ID of executed process'
exec sh -c "[ \$\$ -eq $$ ]"
__IN__

test_oE 'exec in subshell'
(exec echo foo bar)
echo $?
__IN__
foo bar
0
__OUT__

test_O -d -e 127 'executing non-existing command (relative, non-interactive)'
exec ./_no_such_command_
echo not reached
__IN__

test_o -d 'executing non-existing command (relative, interactive)' -i +m
exec ./_no_such_command_
echo $?
__IN__
127
__OUT__

test_x -d -e 0 'redirection error on exec'
command exec <_no_such_file_
status=$?
[ 0 -lt $status ] && [ $status -le 125 ]
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/exit-p.tst <<'EOF'
# exit-p.tst: test of the exit built-in for any POSIX-compliant shell

posix="true"

test_OE -e 0 'exiting with 0'
false
exit 0
__IN__

test_OE -e 17 'exiting with 17'
exit 17
__IN__

test_OE -e 19 'exiting with 19 in subshell'
(exit 19)
__IN__

test_OE -e 0 'default exit status without previous command'
exit
__IN__

test_OE -e 0 'default exit status with previous succeeding command'
true
exit
__IN__

test_OE -e 5 'default exit status with previous failing command'
(exit 5)
exit
__IN__

test_OE -e 3 'default exit status in subshell'
(exit 3)
(exit)
__IN__

test_oE -e 19 'exiting with EXIT trap'
trap 'echo TRAP' EXIT
exit 19
__IN__
TRAP
__OUT__

test_OE -e 1 'exit status with EXIT trap'
trap '(exit 2)' EXIT
(exit 1)
exit
__IN__

test_OE -e 0 'exiting from EXIT trap with 0'
trap 'exit 0' EXIT
exit 1
__IN__

test_OE -e 7 'exiting from EXIT trap with 7'
trap 'exit 7' EXIT
exit 1
__IN__

test_OE -e 2 'default exit status in EXIT trap in exiting with default'
trap exit EXIT
(exit 2)
exit
__IN__

test_OE -e 2 \
    'default exit status with previous command in trap in exiting with default'
trap '(exit 1); exit' EXIT
(exit 2)
exit
__IN__

# POSIX says the exit status in this case should be "the value (of the special
# parameter '?') it had immediately preceding the trap action." Many shells
# including yash interpret it as the exit status of "exit" rather than "trap."
test_OE -e 1 'default exit status in EXIT trap in exiting with 1'
trap exit EXIT
exit 1
__IN__

macos_kill_workaround

test_OE -e 3 'exit from signal trap with 3'
trap '(exit 2); exit 3' INT
(exit 1)
kill -INT $$
__IN__

test_OE -e 0 'default exit status in signal trap'
trap '(exit 2); exit' INT
(exit 1)
kill -INT $$
__IN__

test_oE -e 0 'default exit status in subshell in signal trap'
trap '((exit 2); exit); echo $?' INT
(exit 1)
kill -INT $$
__IN__
2
__OUT__

(
# The test cases below are applicable only if the shell uses exit statuses
# greater than 256 for commands terminated by signals.
if
testee -s <<'__END__'
sh -c 'kill $$'
test $? -le 256
__END__
then
    skip=true
fi

test_o 'exit built-in kills shell according to exit status (TERM)'
"$TESTEE" -s <<'__END__'
# This `sh` kills itself with SIGTERM
sh -c 'kill $$'
# Now the exit status should be a value greater than 256
# indicating that the previous command was terminated by SIGTERM.
# The exit built-in should kill the shell with the same signal
# to propagate the exit status.
exit
__END__
exit_status=$?
test "$exit_status" -gt 256 ||
echo "exit status $exit_status is not greater than 256"
kill -l "$exit_status"
__IN__
TERM
__OUT__

test_o 'exit built-in kills shell according to exit status (KILL)'
"$TESTEE" -s <<'__END__'
# This `sh` kills itself with SIGKILL
sh -c 'kill -s KILL $$'
# Now the exit status should be a value greater than 256
# indicating that the previous command was terminated by SIGKILL.
# The exit built-in should kill the shell with the same signal
# to propagate the exit status.
exit
__END__
exit_status=$?
test "$exit_status" -gt 256 ||
echo "exit status $exit_status is not greater than 256"
kill -l "$exit_status"
__IN__
KILL
__OUT__

test_o 'exit built-in kills subshell according to exit status'
(
# This `sh` kills itself with SIGTERM
sh -c 'kill $$'
# Now the exit status should be a value greater than 256
# indicating that the previous command was terminated by SIGTERM.
# The exit built-in should kill the subshell with the same signal
# to propagate the exit status.
exit
)
exit_status=$?
test "$exit_status" -gt 256 ||
echo "exit status $exit_status is not greater than 256"
kill -l "$exit_status"
__IN__
TERM
__OUT__

test_o 'shell kills itself according to final exit status'
"$TESTEE" -s <<'__END__'
# This `sh` kills itself with SIGTERM
sh -c 'kill $$'
# Now the exit status should be a value greater than 256
# indicating that the previous command was terminated by SIGTERM.
# When reaching the end of the script, the shell should kill
# itself with the same signal to propagate the exit status.
__END__
exit_status=$?
test "$exit_status" -gt 256 ||
echo "exit status $exit_status is not greater than 256"
kill -l "$exit_status"
__IN__
TERM
__OUT__

test_o 'subshell kills itself according to final exit status'
(
# This dummy trap suppresses possible auto-exec optimization
trap 'echo foo' TERM
# This `sh` kills itself with SIGTERM
sh -c 'kill $$'
# Now the exit status should be a value greater than 256
# indicating that the previous command was terminated by SIGTERM.
# When reaching the end of the script, the subshell should kill
# itself with the same signal to propagate the exit status.
)
exit_status=$?
test "$exit_status" -gt 256 ||
echo "exit status $exit_status is not greater than 256"
kill -l "$exit_status"
__IN__
TERM
__OUT__

)

test_OE -e 56 'separator preceding operand'
exit -- 56
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/export-p.tst <<'EOF'
# export-p.tst: test of the export built-in for any POSIX-compliant shell

posix="true"

test_oE -e 0 'exporting one variable' -e
export a=bar
echo 1 $a
sh -c 'echo 2 $a'
__IN__
1 bar
2 bar
__OUT__

test_oE -e 0 'exporting many variables' -e
a=X b=B c=X
export a=A b c=C
echo 1 $a $b $c
sh -c 'echo 2 $a $b $c'
__IN__
1 A B C
2 A B C
__OUT__

test_oE -e 0 'separator preceding operand' -e
export -- a=foo
echo 1 $a
sh -c 'echo 2 $a'
__IN__
1 foo
2 foo
__OUT__

test_oE -e 0 'reusing printed exported variables'
export a=A
e="$(export -p)"
unset a
a=X
eval "$e"
sh -c 'echo $a'
__IN__
A
__OUT__

test_oE 'exporting with assignments'
a=A export b=B
# POSIX requires $a to persist after the export built-in,
# but it is unspecified whether $a is exported.
echo $a
# $a does not affect $b being exported.
sh -c 'echo $b'
__IN__
A
B
__OUT__

test_O -d -e n 'read-only variable cannot be re-assigned'
readonly a=1
export a=2
# The export built-in fails because of the readonly variable.
# Since it is a special built-in, the non-interactive shell exits.
echo not reached
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/fg-p.tst <<'EOF'
# fg-p.tst: test of the fg built-in for any POSIX-compliant shell
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

cat >job1 <<\__END__
exec sh -c 'echo 1; kill -s STOP $$; echo 2'
__END__

cat >job2 <<\__END__
exec sh -c 'echo a; kill -s STOP $$; echo b'
__END__

chmod a+x job1
chmod a+x job2

mkfifo fifo

test_O -d -e n 'fg cannot be used when job control is disabled'
set -m
:&
set +m
fg
__IN__

test_o 'default operand chooses most recently suspended job' -m
:&
sh -c 'kill -s STOP $$; echo 1'
fg >/dev/null
__IN__
1
__OUT__

test_o 'resumed job is in foreground' -m
sh -c 'kill -s STOP $$; ../checkfg && echo fg'
fg >/dev/null
__IN__
fg
__OUT__

test_x -e 127 'resumed job is disowned unless suspended again' -m
cat fifo >/dev/null &
exec 3>fifo
kill -s STOP %
exec 3>&-
fg >/dev/null
wait $!
__IN__

test_o 'specifying job ID' -m
./job1
./job2
fg %./job1 >/dev/null
fg %./job2 >/dev/null
__IN__
1
a
2
b
__OUT__

test_o 'fg prints resumed job' -m
./job1
fg
__IN__
1
./job1
2
__OUT__

test_x -e 42 'exit status of fg' -m
sh -c 'kill -s STOP $$; exit 42'
fg
__IN__

test_O -d -e n 'no existing job' -m
fg
__IN__

test_O -d -e n 'no such job' -m
sh -c 'kill -s STOP $$'
fg %_no_such_job_
exit_status=$?
fg >/dev/null
exit $exit_status
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/fnmatch-p.tst <<'EOF'
# fnmatch-p.tst: test of pattern matching for any POSIX-compliant shell

posix="true"

test_oE 'quotations of a normal character'
case a   in a  ) echo 01; esac
case a   in b  ) echo 02; esac
case a   in A  ) echo 03; esac
case \a  in a  ) echo 11; esac
case \a  in b  ) echo 12; esac
case \a  in A  ) echo 13; esac
case a   in \a ) echo 21; esac
case a   in \b ) echo 22; esac
case a   in \A ) echo 23; esac
case \a  in \a ) echo 31; esac
case \a  in \b ) echo 32; esac
case \a  in \A ) echo 33; esac
case 'a' in a  ) echo 41; esac
case 'a' in b  ) echo 42; esac
case 'a' in A  ) echo 43; esac
case a   in 'a') echo 51; esac
case a   in 'b') echo 52; esac
case a   in 'A') echo 53; esac
case 'a' in 'a') echo 61; esac
case 'a' in 'b') echo 62; esac
case 'a' in 'A') echo 63; esac
case "a" in a  ) echo 71; esac
case "a" in b  ) echo 72; esac
case "a" in A  ) echo 73; esac
case a   in "a") echo 81; esac
case a   in "b") echo 82; esac
case a   in "A") echo 83; esac
case "a" in "a") echo 91; esac
case "a" in "b") echo 92; esac
case "a" in "A") echo 93; esac
__IN__
01
11
21
31
41
51
61
71
81
91
__OUT__

test_oE 'quotations of quotations'
sq=\' dq=\" bs=\\
case \'    in \'   ) echo 111; esac
case \'    in "'"  ) echo 112; esac
case \'    in "$sq") echo 113; esac
case "'"   in \'   ) echo 121; esac
case "'"   in "'"  ) echo 122; esac
case "'"   in "$sq") echo 123; esac
case $sq   in \'   ) echo 131; esac
case $sq   in "'"  ) echo 132; esac
case $sq   in "$sq") echo 133; esac
case "$sq" in \'   ) echo 141; esac
case "$sq" in "'"  ) echo 142; esac
case "$sq" in "$sq") echo 143; esac
case \"    in \"   ) echo 211; esac
case \"    in '"'  ) echo 212; esac
case \"    in "$dq") echo 213; esac
case '"'   in \"   ) echo 221; esac
case '"'   in '"'  ) echo 222; esac
case '"'   in "$dq") echo 223; esac
case $dq   in \"   ) echo 231; esac
case $dq   in '"'  ) echo 232; esac
case $dq   in "$dq") echo 233; esac
case "$dq" in \"   ) echo 241; esac
case "$dq" in '"'  ) echo 242; esac
case "$dq" in "$dq") echo 243; esac
case \\    in \\   ) echo 311; esac
case \\    in '\'  ) echo 312; esac
case \\    in "\\" ) echo 313; esac
case \\    in "$bs") echo 314; esac
case '\'   in \\   ) echo 321; esac
case '\'   in '\'  ) echo 322; esac
case '\'   in "\\" ) echo 323; esac
case '\'   in "$bs") echo 324; esac
case "\\"  in \\   ) echo 331; esac
case "\\"  in '\'  ) echo 332; esac
case "\\"  in "\\" ) echo 333; esac
case "\\"  in "$bs") echo 334; esac
case $bs   in \\   ) echo 341; esac
case $bs   in '\'  ) echo 342; esac
case $bs   in "\\" ) echo 343; esac
case $bs   in "$bs") echo 344; esac
case "$bs" in \\   ) echo 351; esac
case "$bs" in '\'  ) echo 352; esac
case "$bs" in "\\" ) echo 353; esac
case "$bs" in "$bs") echo 354; esac
__IN__
111
112
113
121
122
123
131
132
133
141
142
143
211
212
213
221
222
223
231
232
233
241
242
243
311
312
313
314
321
322
323
324
331
332
333
334
341
342
343
344
351
352
353
354
__OUT__

test_oE 'escapes resulting from expansions'
bs=\\ a=*

# $bs* expands to \* which only matches literal *
case x in $bs*) echo not reached 11; esac
case * in $bs*) echo 12; esac

# $bs$a expands to \* which only matches literal *
case x in $bs$a) echo not reached 21; esac
case * in $bs$a) echo 22; esac

# $bs$bs expands to \\ which only matches literal \
case x  in $bs$bs) echo not reached 31; esac
case \\ in $bs$bs) echo 32; esac
__IN__
12
22
32
__OUT__

test_oE 'blanks'
n=
case ''   in ''  ) echo 11; esac
case ''   in ""  ) echo 12; esac
case ''   in $n  ) echo 13; esac
case ''   in "$n") echo 14; esac
case ""   in ''  ) echo 21; esac
case ""   in ""  ) echo 22; esac
case ""   in $n  ) echo 23; esac
case ""   in "$n") echo 24; esac
case $n   in ''  ) echo 31; esac
case $n   in ""  ) echo 32; esac
case $n   in $n  ) echo 33; esac
case $n   in "$n") echo 34; esac
case "$n" in ''  ) echo 41; esac
case "$n" in ""  ) echo 42; esac
case "$n" in $n  ) echo 43; esac
case "$n" in "$n") echo 44; esac
case $n''"""$n" in "$n"""''$n) echo 99; esac
__IN__
11
12
13
14
21
22
23
24
31
32
33
34
41
42
43
44
99
__OUT__

test_oE '? and * and normal characters'
case a  in a ) echo 01; esac
case aa in a ) echo 02; esac
case a  in aa) echo 03; esac
case aa in aa) echo 04; esac
case a  in ? ) echo 11; esac
case a  in * ) echo 12; esac
case a  in ?*) echo 13; esac
case a  in *?) echo 14; esac
case a  in ??) echo 15; esac
case a  in **) echo 16; esac
case aa in ? ) echo 21; esac
case aa in * ) echo 22; esac
case aa in ?*) echo 23; esac
case aa in *?) echo 24; esac
case aa in ??) echo 25; esac
case aa in **) echo 26; esac
__IN__
01
04
11
12
13
14
16
22
23
24
25
26
__OUT__

test_oE '? and * and quotations'
case ''  in ?) echo 01; esac
case ''  in *) echo 02; esac
case \\  in ?) echo 11; esac
case \\  in *) echo 12; esac
case "'" in ?) echo 21; esac
case "'" in *) echo 22; esac
case '"' in ?) echo 31; esac
case '"' in *) echo 32; esac
__IN__
02
11
12
21
22
31
32
__OUT__

test_oE 'brackets'
case a in [[:lower:]])  echo lower ; esac
case a in [[:upper:]])  echo upper ; esac
case a in [[:alpha:]])  echo alpha ; esac
case a in [[:digit:]])  echo digit ; esac
case a in [[:alnum:]])  echo alnum ; esac
case a in [[:punct:]])  echo punct ; esac
case a in [[:graph:]])  echo graph ; esac
case a in [[:print:]])  echo print ; esac
case a in [[:cntrl:]])  echo cntrl ; esac
case a in [[:blank:]])  echo blank ; esac
case a in [[:space:]])  echo space ; esac
case a in [[:xdigit:]]) echo xdigit; esac
case a in [[.a.]]      ) echo 2; esac
case 1 in [0-2]        ) echo 3; esac
case 1 in [[.0.]-[.2.]]) echo 4; esac
case a in [!a]         ) echo 5; esac
case 1 in [!0-2]       ) echo 6; esac
case a in [[=a=]]      ) echo 7; esac
__IN__
lower
alpha
alnum
graph
print
xdigit
2
3
4
7
__OUT__

test_oE 'brackets and quotations'
case \. in ["."]) echo 01; esac
case \[ in ["."]) echo 02; esac
case \" in ["."]) echo 03; esac
case \\ in ["."]) echo 04; esac
case \] in ["."]) echo 05; esac
case \. in [\".]) echo 11; esac
case \[ in [\".]) echo 12; esac
case \" in [\".]) echo 13; esac
case \\ in [\".]) echo 14; esac
case \] in [\".]) echo 15; esac
case \. in [\.] ) echo 21; esac
case \[ in [\.] ) echo 22; esac
case \" in [\.] ) echo 23; esac
case \\ in [\.] ) echo 24; esac
case \] in [\.] ) echo 25; esac
case \. in "[.]") echo 31; esac
case \[ in "[.]") echo 32; esac
case \" in "[.]") echo 33; esac
case \\ in "[.]") echo 34; esac
case \] in "[.]") echo 35; esac
case \. in [\]] ) echo 41; esac
case \[ in [\]] ) echo 42; esac
case \" in [\]] ) echo 43; esac
case \\ in [\]] ) echo 44; esac
case \] in [\]] ) echo 45; esac
case \. in ["]"]) echo 51; esac
case \[ in ["]"]) echo 52; esac
case \" in ["]"]) echo 53; esac
case \\ in ["]"]) echo 54; esac
case \] in ["]"]) echo 55; esac
__IN__
01
11
13
21
45
55
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/for-p.tst <<'EOF'
# for-p.tst: test of for loop for any POSIX-compliant shell

posix="true"

test_OE 'default words, no positional parameters'
for i do
    echo not reached
done
__IN__

test_oE 'default words, one positional parameter' -s A
for i do
    echo $i
done
__IN__
A
__OUT__

test_oE 'default words, one positional parameter' -s A ' B  B '
for word do
    echo "$word"
done
__IN__
A
 B  B 
__OUT__

test_OE 'explicit words, no words, newline-separated do'
for i in
do
    echo not reached
done
__IN__

test_oE 'explicit words, one word, newline-separated do'
for	i	in	do
do
    echo $i
done
__IN__
do
__OUT__

test_oE 'explicit words, two words, newline-separated do'
for	word	in	do done
do
    echo $word
done
__IN__
do
done
__OUT__

test_oE 'expansion of words'
HOME=/home
for i in ~ $HOME $(echo foo) $((1+2))
do
    echo $i
done
for i in $(echo foo bar)
do
    echo $i
done
for i in
do
    echo $i
done
__IN__
/home
/home
foo
3
foo
bar
__OUT__

test_oE 'words are not treated as assignments'
v=foo
for i in v=bar; do echo $i $v; done
__IN__
v=bar foo
__OUT__

test_oE 'semicolon-separated commands'
for v in 1 2; do echo $v; done
__IN__
1
2
__OUT__

test_oE 'commands ending with an asynchronous command'
for v in 1 2; do true; echo& done
wait
__IN__


__OUT__

test_oE 'for as variable name' -s foo
for for do echo $for; done
__IN__
foo
__OUT__

test_oE 'do as variable name' -s foo
for do do echo $do; done
__IN__
foo
__OUT__

test_oE 'in as variable name'
for in in foo; do echo $in; done
__IN__
foo
__OUT__

test_oE 'in as word'
for i in in; do echo $i; done
__IN__
in
__OUT__

test_oE -e 0 'default words, do separated by semicolon' -s A B
for i; do echo $i; done
__IN__
A
B
__OUT__

test_oE -e 0 'default words, do separated by semicolon and newlines' -s A B
for i ;

do echo $i; done
__IN__
A
B
__OUT__

test_x -e 0 'exit status with no words'
false
for i do
    false
done
__IN__

test_x -e 3 'exit status with some words'
for x in 1 2 3
do
    (exit $x)
done
__IN__

test_o 'redirection on for loop'
for i in a b c; do read j; echo $i $j; done >redir_out <<END
1
2
3
END
cat redir_out
__IN__
a 1
b 2
c 3
__OUT__

test_o 'iteration variable is global'
unset -v i
fn() { for i in a b c; do : ; done; }
fn
echo "${i-UNSET}"
__IN__
c
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/fsplit-p.tst <<'EOF'
# fsplit-p.tst: test of field splitting for any POSIX-compliant shell

posix="true"
setup -d

test_o 'default IFS (no inherited environment variable)'
printf "[%s]\n" "$IFS"
__IN__
[ 	
]
__OUT__

test_o 'default IFS (overriding environment variable)'
IFS=X $TESTEE <<\__INNER__
printf "[%s]\n" "$IFS"
__INNER__
__IN__
[ 	
]
__OUT__

test_oE -e 0 'field splitting applies to results of expansions'
IFS=' 0' a='1 2'
bracket     -${a}- -$(echo '3 4')- -`echo '5 6'`- -$((708))-
bracket ${a+-${a}- -$(echo '3 4')- -`echo '5 6'`- -$((708))-}
bracket ${u--${a}- -$(echo '3 4')- -`echo '5 6'`- -$((708))-}
__IN__
[-1][2-][-3][4-][-5][6-][-7][8-]
[-1][2-][-3][4-][-5][6-][-7][8-]
[-1][2-][-3][4-][-5][6-][-7][8-]
__OUT__

test_oE -e 0 'field splitting does not apply to quoted expansions'
IFS=' 0' a='1 2'
bracket     "-${a}-" "-$(echo '3 4')-" "-`echo '5 6'`-" "-$((708))-"
bracket ${a+"-${a}-" "-$(echo '3 4')-" "-`echo '5 6'`-" "-$((708))-"}
bracket ${u-"-${a}-" "-$(echo '3 4')-" "-`echo '5 6'`-" "-$((708))-"}
bracket "${a+-${a}-   -$(echo '3 4')-   -`echo '5 6'`-   -$((708))-}"
bracket "${u--${a}-   -$(echo '3 4')-   -`echo '5 6'`-   -$((708))-}"
bracket -${a}-"-${a}-"-${a}-
__IN__
[-1 2-][-3 4-][-5 6-][-708-]
[-1 2-][-3 4-][-5 6-][-708-]
[-1 2-][-3 4-][-5 6-][-708-]
[-1 2-   -3 4-   -5 6-   -708-]
[-1 2-   -3 4-   -5 6-   -708-]
[-1][2--1 2--1][2-]
__OUT__

test_oE 'field splitting does not apply to non-expansions'
IFS=' 0'
bracket -102- "-304 5-" '-607 8-' -9\01\ 2-
__IN__
[-102-][-304 5-][-607 8-][-901 2-]
__OUT__

test_oE 'no field splitting with empty IFS'
IFS= a='1 2	3
4'
bracket $a
__IN__
[1 2	3
4]
__OUT__

test_oE 'field splitting with unset IFS'
unset IFS
a='1 2	3
4' b=' 	
5 	
6 	
'
bracket $a $b
__IN__
[1][2][3][4][5][6]
__OUT__

test_oE 'field splitting with standard IFS'
IFS=' 	
'
a='1 2	3
4' b=' 	
5 	
6 	
' c='-"%"\'
bracket $a $b $c
__IN__
[1][2][3][4][5][6][-"%"\]
__OUT__

test_oE 'field splitting with non-whitespace IFS'
IFS='-"'
a='1-2"3' b='--4-"5"-6-7'
bracket $a
bracket $b
__IN__
[1][2][3]
[][][4][][5][][6][7]
__OUT__

test_oE 'complex field splitting with nonsuccessive non-whitespace IFS'
IFS=' -"'
a='1%2-3"4&5' b='- 22- 3- 44 ' c=' -22 -3 -44 ' d=' - 22 - 3 - 44'
bracket $a
bracket $b
bracket $c
bracket $d
__IN__
[1%2][3][4&5]
[][22][3][44]
[][22][3][44]
[][22][3][44]
__OUT__

test_oE 'complex field splitting with successive non-whitespace IFS'
IFS=' -'
a='--3""3' b='  --33' c='-  -33' d='--  33'
bracket $a
bracket $b
bracket $c
bracket $d
__IN__
[][][3""3]
[][][33]
[][][33]
[][][33]
__OUT__

test_oE 'backslash not in IFS'
IFS=' -'
a='\x' b='\ \x' c='\  \x' d='\-\x' e='\--\x' f='-\\ -\-\x'
bracket $a
bracket $b
bracket $c
bracket $d
bracket $e
bracket $f
__IN__
[\x]
[\][\x]
[\][\x]
[\][\x]
[\][][\x]
[][\\][\][\x]
__OUT__

test_oE 'backslash in IFS'
IFS=' \-'
a='\x' b='\ \x' c='\  \x' d='\-\x' e='\--\x' f='-\\ -\-x' g='1\2\\ 4-5\- 7\x'
bracket $a
bracket $b
bracket $c
bracket $d
bracket $e
bracket $f
bracket $g
__IN__
[][x]
[][][x]
[][][x]
[][][][x]
[][][][][x]
[][][][][][][x]
[1][2][][4][5][][7][x]
__OUT__

# If field splitting yields a single empty field and it is not quoted, then it
# is removed.
test_oE 'empty field removal'
a= b=' ' c=' - '
bracket 1 $a
bracket 2 $b
bracket 3 ''$a ""$a
bracket 4 ''$b ""$b
bracket 5 $a'' $a""
bracket 6 $b'' $b""
bracket 7 ''$a'' ""$a""
bracket 8 ''$b'' ""$b""
bracket 9 ''$c'' ""$c""
bracket 10 ${a:-''} ${a:-""}
#bracket 11 "${a:-''}" "${a:-""}"
bracket 12 "$a"
bracket 13 "$b"
bracket 14 "" """"""
bracket 15 '' ''''''
__IN__
[1]
[2]
[3][][]
[4][][]
[5][][]
[6][][]
[7][][]
[8][][][][]
[9][][-][][][-][]
[10][][]
[12][]
[13][ ]
[14][][]
[15][][]
__OUT__

test_oE 'empty field removal with empty IFS'
IFS= a=
bracket $a - $IFS
__IN__
[-]
__OUT__

test_oE 'empty last field is ignored (non-backslash IFS)'
IFS=' ='
a='='; bracket $a
a='=='; bracket $a
a='==='; bracket $a
a='1'; bracket $a
a='1='; bracket $a
a='1=='; bracket $a
a='1==='; bracket $a
echo ===
a='1= '; bracket $a
a='1==  '; bracket $a
a='1===   '; bracket $a
echo ===
a='1= ='; bracket $a
a='1==  ='; bracket $a
a='1===   ='; bracket $a
__IN__
[]
[][]
[][][]
[1]
[1]
[1][]
[1][][]
===
[1]
[1][]
[1][][]
===
[1][]
[1][][]
[1][][][]
__OUT__

test_oE 'empty last field is ignored (backslash IFS)'
IFS=' =\'
a='\'; bracket $a
a='\\'; bracket $a
a='\\\'; bracket $a
a='1'; bracket $a
a='1\'; bracket $a
a='1\\'; bracket $a
a='1\\\'; bracket $a
echo ===
a='1\ '; bracket $a
a='1\\  '; bracket $a
a='1\\\   '; bracket $a
echo ===
a='1\ \'; bracket $a
a='1\\  \'; bracket $a
a='1\\\   \'; bracket $a
__IN__
[]
[][]
[][][]
[1]
[1]
[1][]
[1][][]
===
[1]
[1][]
[1][][]
===
[1][]
[1][][]
[1][][][]
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/function-p.tst <<'EOF'
# function-p.tst: test of functions for any POSIX-compliant shell

posix="true"

test_OE -e 0 'effect of function definition (without executing the function)'
func(){ echo foo; } <_no_such_file_
__IN__

test_oE 'grouping as function body'
func(){ echo foo; }
func
__IN__
foo
__OUT__

test_oE 'subshell as function body'
func()(echo foo; exit; echo not reached)
func
:
__IN__
foo
__OUT__

test_oE 'for loop as function body'
func()for i in 1; do echo $i; done
func
__IN__
1
__OUT__

test_oE 'case statement as function body'
func()case 1 in 1) echo foo; esac
func
__IN__
foo
__OUT__

test_oE 'if statement as function body'
func()if echo foo; then echo bar; fi
func
__IN__
foo
bar
__OUT__

test_oE 'while loop as function body'
func()while true; do echo foo; break; done
func
__IN__
foo
__OUT__

test_oE 'until loop as function body'
func()until false; do echo foo; break; done
func
__IN__
foo
__OUT__

test_oE 're-defining a function'
func() { echo foo; }
func() { echo bar; }
func
__IN__
bar
__OUT__

test_oE 'characters in portable name'
_abcXYZ1() { echo foo; }
_abcXYZ1
__IN__
foo
__OUT__

test_oE 'functions and variables belong to separate namespaces'
foo=variable
foo() { echo function; }
echo $foo
foo=X
foo
__IN__
variable
function
__OUT__

test_OE 'redirections apply to function body'
func() { echo foo; cat; } >/dev/null <<END
bar
END
func
__IN__

test_oE '$# in function'
func() { echo $#; }
func
func 1
func 1 2
func 1 '2  2' 3
__IN__
0
1
2
3
__OUT__

test_oE 'arguments to function'
func() { [ $# -gt 0 ] && printf '[%s]' "$@"; echo; }
func
func 1
func 1 2
func 1 '2  2' 3
set a
func 1
echo "$@"
__IN__

[1]
[1][2]
[1][2  2][3]
[1]
a
__OUT__

test_oE '$0 remains unchanged while executing function'
func() { printf '%s\n' "${0##*/}"; }
func
func 1
__IN__
sh
sh
__OUT__

(
setup 'func() (exit $1)'

test_OE -e 0 'exit status of function call (0)'
func 0
__IN__

test_OE -e 1 'exit status of function call (1)'
func 1
__IN__

test_OE -e 19 'exit status of function call (19)'
func 19
__IN__

)

test_oE 'variable assigned in function remains after return'
func() {
    foo=bar
}
foo=
func
echo $foo
__IN__
bar
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/getopts-p.tst <<'EOF'
# getopts-p.tst: test of the getopts built-in for any POSIX-compliant shell

posix="true"

test_o 'default OPTIND is 1'
printf '%s\n' "$OPTIND"
__IN__
1
__OUT__

test_o 'OPTIND and OPTARG are not exported by default'
getopts a: o -a arg
getopts a: o -a arg
sh -c 'echo ${OPTIND-unset} ${OPTARG-unset}'
__IN__
1 unset
__OUT__

test_o 'operand variable is updated to parsed option on each invocation'
getopts ab:c o -a -b arg -c
printf '1[%s]\n' "$o"
getopts ab:c o -a -b arg -c
printf '2[%s]\n' "$o"
getopts ab:c o -a -b arg -c
printf '3[%s]\n' "$o"
__IN__
1[a]
2[b]
3[c]
__OUT__

test_x -e 0 'exit status is zero after option is parsed' -e
getopts ab:c o -a -b arg -c
getopts ab:c o -a -b arg -c
getopts ab:c o -a -b arg -c
__IN__

test_x -e 1 'exit status is one after parsing all options' -e
getopts ab:c o -a -b arg -c
getopts ab:c o -a -b arg -c
getopts ab:c o -a -b arg -c
getopts ab:c o -a -b arg -c
__IN__

test_o 'OPTIND is set when option argument is parsed: empty'
getopts a:b o -a '' -b
echo "[$OPTIND]"
__IN__
[3]
__OUT__

test_o 'OPTIND is set when option argument is parsed: non-empty separate'
getopts a:b o -a '-x  foo' -b
echo "[$OPTIND]"
__IN__
[3]
__OUT__

test_o 'OPTIND is set when option argument is parsed: non-empty adjoined'
getopts a:b o -a'  foo' -b
echo "[$OPTIND]"
__IN__
[2]
__OUT__

test_o 'OPTARG is set when option argument is parsed: empty'
getopts a: o -a ''
echo "[$OPTARG]"
__IN__
[]
__OUT__

test_o 'OPTARG is set when option argument is parsed: non-empty separate'
getopts a: o -a '-x  foo'
echo "[$OPTARG]"
__IN__
[-x  foo]
__OUT__

test_o 'OPTARG is set when option argument is parsed: non-empty adjoined'
getopts a: o -a'  foo'
echo "[$OPTARG]"
__IN__
[  foo]
__OUT__

test_o 'OPTARG is unset when option without argument is parsed'
getopts a o -a
echo "${OPTARG-un}${OPTARG-set}"
__IN__
unset
__OUT__

test_o 'operand variable is set to "?" on unknown option'
getopts '' o -a
printf '[%s]\n' "$o"
__IN__
[?]
__OUT__

test_o 'OPTARG is set to the option on unknown option (with :)'
getopts : o -a
printf '[%s]\n' "$OPTARG"
__IN__
[a]
__OUT__

test_E 'no error message on unknown option (with :)'
getopts : o -a
__IN__

test_o 'OPTARG is unset on unknown option (without :)'
getopts '' o -a
printf '%s\n' "${OPTARG-un}${OPTARG-set}"
__IN__
unset
__OUT__

test_x -d 'error message is printed on unknown option (without :)'
getopts '' o -a
__IN__

test_o 'operand variable is set to ":" on missing option argument (with :)'
getopts :a: v -a
printf '[%s]\n' "$v"
__IN__
[:]
__OUT__

test_o 'OPTARG is set to the option on missing option argument (with :)'
getopts :a: v -a
printf '[%s]\n' "$OPTARG"
__IN__
[a]
__OUT__

test_o 'operand variable is set to "?" on missing option argument (without :)'
getopts a: v -a
printf '[%s]\n' "$v"
__IN__
[?]
__OUT__

test_o 'OPTARG is unset on missing option argument (without :)'
getopts a: v -a
printf '%s\n' "${OPTARG-un}${OPTARG-set}"
__IN__
unset
__OUT__

test_x -d 'error message is printed on missing option argument (without :)'
getopts a: v -a
__IN__

test_o 'operand variable is set to "?" after parsing all options'
getopts a x -a
getopts a x -a
printf '[%s]\n' "$x"
__IN__
[?]
__OUT__

test_o 'OPTARG is unset after parsing all options'
getopts a x -a
getopts a x -a
printf '%s\n' "${OPTARG-un}${OPTARG-set}"
__IN__
unset
__OUT__

test_o 'options can be grouped after single hyphen'
getopts abc o -abc
printf '1[%s]\n' "$o"
getopts abc o -abc
printf '2[%s]\n' "$o"
getopts abc o -abc
printf '3[%s]\n' "$o"
getopts abc o -abc
printf '4[%s]\n' "$o"
__IN__
1[a]
2[b]
3[c]
4[?]
__OUT__

test_x -e 1 'single hyphen is not an option but an operand'
getopts '' x -
__IN__

test_o 'double hyphen separates options and operands'
getopts ab x -a -- -b
printf '1[%s]\n' "$x"
getopts ab x -a -- -b ||
printf '2[%d]\n' "$OPTIND"
__IN__
1[a]
2[3]
__OUT__

test_o 'OPTIND is first operand index after parsing all options: no operand, no --'
getopts '' x
printf '%d\n' "$OPTIND"
__IN__
1
__OUT__

test_o 'OPTIND is first operand index after parsing all options: one operand, no --'
getopts '' x operand
printf '%d\n' "$OPTIND"
__IN__
1
__OUT__

test_o 'OPTIND is first operand index after parsing all options: no operand, with --'
getopts '' x --
printf '%d\n' "$OPTIND"
__IN__
2
__OUT__

test_o 'OPTIND is first operand index after parsing all options: one operand, with --'
getopts '' x -- operand
printf '%d\n' "$OPTIND"
__IN__
2
__OUT__

test_o 'resetting OPTIND to parse another arguments'
getopts ab p -a -b
getopts ab p -a -b
getopts ab p -a -b
OPTIND=1
getopts xy q -x -y
printf '1[%s]\n' "$q"
getopts xy q -x -y
printf '2[%s]\n' "$q"
getopts xy q -x -y
printf '3[%d]\n' "$OPTIND"
__IN__
1[x]
2[y]
3[3]
__OUT__

test_o 'positional parameters are parsed by default' -s -- -a -b arg -c
getopts ab:c o
printf '1[%s]\n' "$o"
getopts ab:c o
printf '2[%s]\n' "$o"
getopts ab:c o
printf '3[%s]\n' "$o"
__IN__
1[a]
2[b]
3[c]
__OUT__

test_o 'option characters are alphanumeric'
getopts ab:01: o -a -b arg -1 -2 -0
printf '1[%s]\n' "$o"
getopts ab:01: o -a -b arg -1 -2 -0
printf '2[%s]\n' "$o"
getopts ab:01: o -a -b arg -1 -2 -0
printf '3[%s]\n' "$o"
getopts ab:01: o -a -b arg -1 -2 -0
printf '4[%s]\n' "$o"
__IN__
1[a]
2[b]
3[1]
4[0]
__OUT__

test_O -d -e n 'readonly OPTIND'
# As specified in POSIX XBD 8.1, one of the following should happen:
# - The readonly built-in fails.
# - The getopts built-in fails.
# - The getopts built-in succeeds ignoring the readonlyness of the variable.
readonly OPTIND && getopts a opt -- x &&
if [ "$OPTIND" = 2 ]; then
    printf 'OPTIND successfully changed\n' >&2
    false # The expected exit status of this test is non-zero.
fi
__IN__

test_O -d -e n 'readonly OPTARG'
# As specified in POSIX XBD 8.1, one of the following should happen:
# - The readonly built-in fails.
# - The getopts built-in fails.
# - The getopts built-in succeeds ignoring the readonlyness of the variable.
readonly OPTARG && getopts a: opt -a foo &&
if [ "$OPTARG" = foo ]; then
    printf 'OPTARG successfully changed\n' >&2
    false # The expected exit status of this test is non-zero.
fi
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/grouping-p.tst <<'EOF'
# grouping-p.tst: test of grouping commands for any POSIX-compliant shell

posix="true"

mkfifo fifo1

test_oE 'effect of subshell'
a=1
(a=2; echo $a; exit; echo not reached)
echo $a
__IN__
2
1
__OUT__

test_x -e 23 'exit status of subshell'
(true; exit 23)
__IN__

test_oE 'redirection on subshell'
(echo 1; echo 2; echo 3; echo 4) >sub_out
(tail -n 2) <sub_out
__IN__
3
4
__OUT__

test_oE 'subshell ending with semicolon'
(echo foo;)
__IN__
foo
__OUT__

test_oE 'subshell ending with asynchronous list'
(echo foo >fifo1&)
cat fifo1
__IN__
foo
__OUT__

test_oE 'newlines in subshell'
(
echo foo
)
__IN__
foo
__OUT__

test_oE 'effect of brace grouping'
a=1
{ a=2; echo $a; exit; echo not reached; }
echo not reached
__IN__
2
__OUT__

test_x -e 29 'exit status of brace grouping'
{ true; sh -c 'exit 29'; }
__IN__

test_oE 'redirection on brace grouping'
{ echo 1; echo 2; echo 3; echo 4; } >brace_out
{ tail -n 2; } <brace_out
__IN__
3
4
__OUT__

test_oE 'brace grouping ending with semicolon'
{ echo foo; }
__IN__
foo
__OUT__

test_oE 'brace grouping ending with asynchronous list'
{ echo foo >fifo1&}
cat fifo1
__IN__
foo
__OUT__

test_oE 'newlines in brace grouping'
{
echo foo
}
__IN__
foo
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/if-p.tst <<'EOF'
# if-p.tst: test of if conditional construct for any POSIX-compliant shell

posix="true"

test_oE 'execution path of if, true'
if echo foo; then echo bar; fi
__IN__
foo
bar
__OUT__

test_oE 'execution path of if, false'
if ! echo foo; then echo bar; fi
__IN__
foo
__OUT__

test_oE 'execution path of if-else, true'
if echo foo; then echo bar; else echo baz; fi
__IN__
foo
bar
__OUT__

test_oE 'execution path of if-else, false'
if ! echo foo; then echo bar; else echo baz; fi
__IN__
foo
baz
__OUT__

test_oE 'execution path of if-elif, true'
if echo 1; then echo 2; elif echo 3; then echo 4; fi
__IN__
1
2
__OUT__

test_oE 'execution path of if-elif, false-true'
if ! echo 1; then echo 2; elif echo 3; then echo 4; fi
__IN__
1
3
4
__OUT__

test_oE 'execution path of if-elif, false-false'
if ! echo 1; then echo 2; elif ! echo 3; then echo 4; fi
__IN__
1
3
__OUT__

test_oE 'execution path of if-elif-else, true'
if echo 1; then echo 2; elif echo 3; then echo 4; else echo 5; fi
__IN__
1
2
__OUT__

test_oE 'execution path of if-elif-else, false-true'
if ! echo 1; then echo 2; elif echo 3; then echo 4; else echo 5; fi
__IN__
1
3
4
__OUT__

test_oE 'execution path of if-elif-else, false-false'
if ! echo 1; then echo 2; elif ! echo 3; then echo 4; else echo 5; fi
__IN__
1
3
5
__OUT__

test_oE 'execution path of if-elif-elif, true'
if echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; fi
__IN__
1
2
__OUT__

test_oE 'execution path of if-elif-elif, false-true'
if ! echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; fi
__IN__
1
3
4
__OUT__

test_oE 'execution path of if-elif-elif, false-false-true'
if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif echo 5; then echo 6; fi
__IN__
1
3
5
6
__OUT__

test_oE 'execution path of if-elif-elif, false-false-false'
if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif ! echo 5; then echo 6; fi
__IN__
1
3
5
__OUT__

test_oE 'execution path of if-elif-elif-else, true'
if echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; else echo 7; fi
__IN__
1
2
__OUT__

test_oE 'execution path of if-elif-elif-else, false-true'
if ! echo 1; then echo 2; elif echo 3; then echo 4; elif echo 5; then echo 6; else echo 7; fi
__IN__
1
3
4
__OUT__

test_oE 'execution path of if-elif-elif-else, false-false-true'
if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif echo 5; then echo 6; else echo 7; fi
__IN__
1
3
5
6
__OUT__

test_oE 'execution path of if-elif-elif-else, false-false-false'
if ! echo 1; then echo 2; elif ! echo 3; then echo 4; elif ! echo 5; then echo 6; else echo 7; fi
__IN__
1
3
5
7
__OUT__

(
setup <<\__END__
\unalias \x
x() { return $1; }
__END__

test_x -e 0 'exit status of if, true-true'
if x 0; then x 0; fi
__IN__

test_x -e 1 'exit status of if, true-false'
if x 0; then x 1; fi
__IN__

test_x -e 0 'exit status of if, false'
if x 1; then x 2; fi
__IN__

test_x -e 0 'exit status of if-else, true-true'
if x 0; then x 0; else x 1; fi
__IN__

test_x -e 1 'exit status of if-else, true-false'
if x 0; then x 1; else x 2; fi
__IN__

test_x -e 0 'exit status of if-else, false-true'
if x 1; then x 2; else x 0; fi
__IN__

test_x -e 2 'exit status of if-else, false-false'
if x 1; then x 0; else x 2; fi
__IN__

test_x -e 0 'exit status of if-elif, true-true'
if x 0; then x 0; elif x 1; then x 2; fi
__IN__

test_x -e 1 'exit status of if-elif, true-false'
if x 0; then x 1; elif x 2; then x 3; fi
__IN__

test_x -e 0 'exit status of if-elif, false-true-true'
if x 1; then x 2; elif x 0; then x 0; fi
__IN__

test_x -e 3 'exit status of if-elif, false-true-false'
if x 1; then x 2; elif x 0; then x 3; fi
__IN__

test_x -e 0 'exit status of if-elif-elif-else, true-true'
if x 0; then x 0; elif x 1; then x 2; elif x 3; then x 4; else x 5; fi
__IN__

test_x -e 11 'exit status of if-elif-elif-else, true-false'
if x 0; then x 11; elif x 1; then x 2; elif x 3; then x 4; else x 5; fi
__IN__

test_x -e 0 'exit status of if-elif-elif-else, false-true-true'
if x 1; then x 2; elif x 0; then x 0; elif x 3; then x 4; else x 5; fi
__IN__

test_x -e 13 'exit status of if-elif-elif-else, false-true-false'
if x 1; then x 2; elif x 0; then x 13; elif x 3; then x 4; else x 5; fi
__IN__

test_x -e 0 'exit status of if-elif-elif-else, false-false-true-true'
if x 1; then x 2; elif x 3; then x 4; elif x 0; then x 0; else x 5; fi
__IN__

test_x -e 5 'exit status of if-elif-elif-else, false-false-true-false'
if x 1; then x 2; elif x 3; then x 4; elif x 0; then x 5; else x 6; fi
__IN__

test_x -e 0 'exit status of if-elif-elif-else, false-false-false-true'
if x 1; then x 2; elif x 3; then x 4; elif x 5; then x 6; else x 0; fi
__IN__

test_x -e 7 'exit status of if-elif-elif-else, false-false-false-false'
if x 1; then x 2; elif x 3; then x 4; elif x 5; then x 6; else x 7; fi
__IN__

)

test_oE 'linebreak after if'
if

    echo foo;then echo bar;fi
__IN__
foo
bar
__OUT__

test_oE 'linebreak before then (after if)'
if echo foo

    then echo bar;fi
__IN__
foo
bar
__OUT__

test_oE 'linebreak after then (after if)'
if echo foo;then
    
    echo bar;fi
__IN__
foo
bar
__OUT__

test_oE 'linebreak before fi (after then)'
if echo foo;then echo bar

    fi
__IN__
foo
bar
__OUT__

test_oE 'linebreak before elif'
if ! echo foo;then echo bar

    elif echo baz;then echo qux;fi
__IN__
foo
baz
qux
__OUT__

test_oE 'linebreak after elif'
if ! echo foo;then echo bar;elif
    
    echo baz;then echo qux;fi
__IN__
foo
baz
qux
__OUT__

test_oE 'linebreak before then (after elif)'
if ! echo foo;then echo bar;elif echo baz

    then echo qux;fi
__IN__
foo
baz
qux
__OUT__

test_oE 'linebreak after then (after elif)'
if ! echo foo;then echo bar;elif echo baz;then
    
    echo qux;fi
__IN__
foo
baz
qux
__OUT__

test_oE 'linebreak before else'
if ! echo foo;then echo bar

    else echo baz;fi
__IN__
foo
baz
__OUT__

test_oE 'linebreak after else'
if ! echo foo;then echo bar;else
    
    echo baz;fi
__IN__
foo
baz
__OUT__

test_oE 'linebreak before fi (after else)'
if ! echo foo;then echo bar;else echo baz

    fi
__IN__
foo
baz
__OUT__

test_oE 'command ending with asynchronous command (after if)'
if echo foo&then wait;fi
__IN__
foo
__OUT__

test_oE 'command ending with asynchronous command (after then)'
if echo foo;then echo bar&fi;wait
__IN__
foo
bar
__OUT__

test_oE 'command ending with asynchronous command (after elif)'
if ! echo foo;then echo bar;elif echo baz&then wait;fi
__IN__
foo
baz
__OUT__

test_oE 'command ending with asynchronous command (after else)'
if ! echo foo;then echo bar;elif ! echo baz;then echo qux;else echo quux;fi;wait
__IN__
foo
baz
quux
__OUT__

test_oE 'more than one inner command'
if echo 1; echo 2
    echo 3; ! echo 4; then echo x1; echo x2
    echo x3; echo x4; elif echo 5; echo 6
    echo 7; echo 8; then echo 9; echo 10
    echo 11; echo 12; else echo x5; echo x6
    echo x7; echo x8; fi
__IN__
1
2
3
4
5
6
7
8
9
10
11
12
__OUT__

test_oE 'nest between if and then'
if if true; then echo foo; fi then echo bar; fi
__IN__
foo
bar
__OUT__

test_oE 'nest between then and fi'
if echo foo; then if true; then echo bar; fi fi
__IN__
foo
bar
__OUT__

test_oE 'nest between then and elif'
if echo foo; then if echo bar; then true; fi elif echo baz; then echo qux; fi
__IN__
foo
bar
__OUT__

test_oE 'nest between elif and then'
if echo foo; then echo bar; elif if true; then echo baz; fi then echo qux; fi
__IN__
foo
bar
__OUT__

test_oE 'nest between then and else'
if echo foo; then if echo bar; then true; fi else echo baz; fi
__IN__
foo
bar
__OUT__

test_oE 'nest between else and if'
if ! echo foo; then echo bar; else if echo baz; then echo qux; fi fi
__IN__
foo
baz
qux
__OUT__

test_oE 'redirection on if'
if echo foo
then echo bar
else echo baz
fi >redir_out
cat redir_out
__IN__
foo
bar
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/input-p.tst <<'EOF'
# input-p.tst: test of input processing for any POSIX-compliant shell

posix="true"

# Note that this test case depends on the fact that run-test.sh passes the
# input using a regular file. The test would fail if the input was not
# seekable. See also the "Input files" section in POSIX.1-2008, 1.4 Utility
# Description Defaults.
test_oE 'no input more than needed is read'
"$TESTEE" -c 'read -r line && printf "%s\n" "$line"'
echo - this line is consumed by read and printed by printf
echo - this line is consumed and executed by shell
__IN__
echo - this line is consumed by read and printed by printf
- this line is consumed and executed by shell
__OUT__

test_x -e 0 'exit status of empty input'
__IN__

test_x -e 0 'exit status of input containing blank lines only'


__IN__

test_x -e 0 'exit status of input containing blank lines and comments only'

# foo

# bar
__IN__

test_oE 'long line'
echo 1                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        2
__IN__
1 2
__OUT__

test_oE 'line continuation and long line'
echo \
1                                                                             \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              \
                                                                              2
__IN__
1 2
__OUT__

printf 'alias false=:\nfalse\n' >inputfile.sh

test_x -e 0 'shell input is line-wise (file)' ./inputfile.sh
__IN__

test_x -e 0 'shell input is line-wise (standard input)'
alias false=:
false
__IN__

test_x -e 0 'shell input is line-wise (-c)' -c 'alias false=:
false'
__IN__

test_x -e 0 'shell input is line-wise (command substitution)'
x=$(alias false=:
false)
__IN__

test_x -e 0 'shell input is line-wise (eval)'
eval 'alias false=:
false'
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/job-p.tst <<'EOF'
# job-p.tst: test of job control for any POSIX-compliant shell
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

mkfifo sync

test_x -e 17 'job result is not lost when reported automatically (+b)' -im
exec >sync && exit 17 &
pid=$!
cat sync
:
:
:
wait $pid
__IN__

# This test is in async-p.tst.
#test_oE 'stdin of asynchronous list is null without job control' +m

test_oE 'stdin of asynchronous list is not modified with job control' -m
tail -n 1& wait
echo this line should be skipped by tail
echo this line should be printed by tail
__IN__
echo this line should be printed by tail
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/kill1-p.tst <<'EOF'
# kill1-p.tst: test of the kill built-in for any POSIX-compliant shell, part 1

posix="true"

test_E -e 0 'printing all signal names'
kill -l
__IN__

# $1 = LINENO, $2 = signal number, $3 = signal name w/o SIG
test_printing_signal_name_from_number() {
    testcase "$1" -e 0 "printing signal name $3 from number" \
        3<<__IN__ 4<<__OUT__ 5</dev/null
kill -l $2
__IN__
$3
__OUT__
}

test_printing_signal_name_from_number "$LINENO" 1 HUP
test_printing_signal_name_from_number "$LINENO" 2 INT
test_printing_signal_name_from_number "$LINENO" 3 QUIT
test_printing_signal_name_from_number "$LINENO" 6 ABRT
test_printing_signal_name_from_number "$LINENO" 9 KILL
test_printing_signal_name_from_number "$LINENO" 14 ALRM
test_printing_signal_name_from_number "$LINENO" 15 TERM

# $1 = LINENO, $2 = signal name w/o SIG
test_printing_signal_name_from_exit_status() (
    if sh -c "kill -s $2 \$\$"; then
        skip="true"
    fi
    testcase "$1" -e 0 "printing signal name $2 from exit status" \
        3<<__IN__ 4<<__OUT__ 5</dev/null
sh -c 'kill -s $2 \$\$'
kill -l \$?
__IN__
$2
__OUT__
)

test_printing_signal_name_from_exit_status "$LINENO" HUP
test_printing_signal_name_from_exit_status "$LINENO" INT
test_printing_signal_name_from_exit_status "$LINENO" QUIT
test_printing_signal_name_from_exit_status "$LINENO" ABRT
test_printing_signal_name_from_exit_status "$LINENO" KILL
test_printing_signal_name_from_exit_status "$LINENO" ALRM
test_printing_signal_name_from_exit_status "$LINENO" TERM

test_OE -e TERM 'sending default signal TERM'
kill $$
__IN__

test_OE -e 0 'sending null signal: -s 0'
kill -s 0 $$
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/kill2-p.tst <<'EOF'
# kill2-p.tst: test of the kill built-in for any POSIX-compliant shell, part 2

posix="true"

# $1 = LINENO, $2 = signal name w/o SIG, $3 = prefix for $2
test_sending_signal_kill() {
    testcase "$1" -e "$2" "sending signal: $3$2" \
        3<<__IN__ 4</dev/null 5</dev/null
kill $3$2 \$\$
__IN__
}

test_sending_signal_kill "$LINENO" ABRT '-s '
test_sending_signal_kill "$LINENO" ALRM '-s '
test_sending_signal_kill "$LINENO" BUS  '-s '
test_sending_signal_kill "$LINENO" FPE  '-s '
test_sending_signal_kill "$LINENO" HUP  '-s '
test_sending_signal_kill "$LINENO" ILL  '-s '
test_sending_signal_kill "$LINENO" INT  '-s '
test_sending_signal_kill "$LINENO" KILL '-s '
test_sending_signal_kill "$LINENO" PIPE '-s '
test_sending_signal_kill "$LINENO" QUIT '-s '
test_sending_signal_kill "$LINENO" SEGV '-s '
test_sending_signal_kill "$LINENO" TERM '-s '
test_sending_signal_kill "$LINENO" USR1 '-s '
test_sending_signal_kill "$LINENO" USR2 '-s '

test_sending_signal_kill "$LINENO" ABRT -
test_sending_signal_kill "$LINENO" ALRM -
test_sending_signal_kill "$LINENO" BUS  -
test_sending_signal_kill "$LINENO" FPE  -
test_sending_signal_kill "$LINENO" HUP  -
test_sending_signal_kill "$LINENO" ILL  -
test_sending_signal_kill "$LINENO" INT  -
test_sending_signal_kill "$LINENO" KILL -
test_sending_signal_kill "$LINENO" PIPE -
test_sending_signal_kill "$LINENO" QUIT -
test_sending_signal_kill "$LINENO" SEGV -
test_sending_signal_kill "$LINENO" TERM -
test_sending_signal_kill "$LINENO" USR1 -
test_sending_signal_kill "$LINENO" USR2 -

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/kill3-p.tst <<'EOF'
# kill3-p.tst: test of the kill built-in for any POSIX-compliant shell, part 3

posix="true"

# $1 = LINENO, $2 = signal name w/o SIG, $3 = prefix for $2
test_sending_signal_ignore() {
    testcase "$1" -e 0 "sending signal: $3$2" \
        3<<__IN__ 4</dev/null 5</dev/null
kill $3$2 \$\$
__IN__
}

test_sending_signal_ignore "$LINENO" CHLD '-s '
test_sending_signal_ignore "$LINENO" CONT '-s '
test_sending_signal_ignore "$LINENO" URG  '-s '

test_sending_signal_ignore "$LINENO" CHLD -
test_sending_signal_ignore "$LINENO" CONT -
test_sending_signal_ignore "$LINENO" URG  -

# $1 = LINENO, $2 = signal name w/o SIG, $3 = prefix for $2
test_sending_signal_stop() {
    testcase "$1" -e 0 "sending signal: $3$2" \
        3<<__IN__ 4</dev/null 5</dev/null
(kill $3$2 \$\$; status=\$?; kill -s CONT \$\$; exit \$status)
__IN__
}

test_sending_signal_stop "$LINENO" STOP '-s '
test_sending_signal_stop "$LINENO" TSTP '-s '
test_sending_signal_stop "$LINENO" TTIN '-s '
test_sending_signal_stop "$LINENO" TTOU '-s '

test_sending_signal_stop "$LINENO" STOP -
test_sending_signal_stop "$LINENO" TSTP -
test_sending_signal_stop "$LINENO" TTIN -
test_sending_signal_stop "$LINENO" TTOU -

# $1 = LINENO, $2 = signal name w/o SIG, $3 = signal number
test_sending_signal_num_kill_self() {
    testcase "$1" -e "$2" "sending signal: -$3" \
        3<<__IN__ 4</dev/null 5</dev/null
kill -$3 \$\$
__IN__
}

test_sending_signal_num_kill_self "$LINENO" HUP  1
test_sending_signal_num_kill_self "$LINENO" INT  2
test_sending_signal_num_kill_self "$LINENO" QUIT 3
test_sending_signal_num_kill_self "$LINENO" ABRT 6
test_sending_signal_num_kill_self "$LINENO" KILL 9
test_sending_signal_num_kill_self "$LINENO" ALRM 14
test_sending_signal_num_kill_self "$LINENO" TERM 15

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/kill4-p.tst <<'EOF'
# kill4-p.tst: test of the kill built-in for any POSIX-compliant shell, part 4
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

# This FIFO is for synchronization between processes. First, it ensures the
# receiver has started before the sender sends a signal. Next, the receiver
# tries to reopen the FIFO so that the receiver does not exit before it
# receives the signal.
mkfifo fifo

# all processes in the same process group
test_oE 'sending signal to process 0' -m
kill -s HUP 0 >fifo | cat fifo fifo
kill -l $?
__IN__
HUP
__OUT__

test_oE 'sending signal with negative process number: -s HUP' -m
(
pgid="$(exec sh -c 'echo $PPID')"
kill -s HUP -- -$pgid >fifo | cat fifo fifo
)
kill -l $?
__IN__
HUP
__OUT__

test_oE 'sending signal with negative process number: -1' -m
(
pgid="$(exec sh -c 'echo $PPID')"
kill -1 -- -$pgid >fifo | cat fifo fifo
)
kill -l $?
__IN__
HUP
__OUT__

(
setup 'halt() while kill -s CONT $$; do sleep 1; done'
mkfifo fifo1 fifo2 fifo3

test_oE 'sending signal to background job' -m
# The subshells stop at the redirections, waiting for the unopened FIFOs.
(>fifo1; echo not reached 1 >&2) |
(>fifo2; echo not reached 2 >&2) |
(>fifo3; echo not reached 3 >&2) &
halt &
kill -s USR1 '%?echo'
wait '%?echo'
kill -l $?
kill -s USR2 %halt
wait %halt
kill -l $?
__IN__
USR1
USR2
__OUT__

test_oE 'sending to multiple processes' -m
# The subshells stop at the redirections, waiting for the unopened FIFOs.
(>fifo1; echo not reached 1 >&2) &
(>fifo2; echo not reached 2 >&2) &
kill '%?fifo1' '%?fifo2'
wait '%?fifo1'
kill -l $?
wait '%?fifo2'
kill -l $?
__IN__
TERM
TERM
__OUT__

)

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/lineno-p.tst <<'EOF'
# lineno-p.tst: test of the LINENO variable for any POSIX-compliant shell

posix="true"

# POSIX requires the $LINENO variable to be effective only in a script or
# function. However, the meaning of "script" is vague and existing shells
# disagree as to how line numbers are counted within functions. We only test
# common behavior of the shells in this file. More details are tested in
# lineno-y.tst as yash-specific behavior.

test_oE -e 0 'LINENO starts from 1' -s
echo $LINENO
__IN__
1
__OUT__

test_oE -e 0 'LINENO increments for each line' -s
echo $LINENO
echo $LINENO

echo $LINENO
__IN__
1
2
4
__OUT__

test_oE -e 0 'LINENO after expansions' -s
: $(echo foo
echo \
baz)
echo $LINENO
: ${foo#
bar \
baz}
echo $LINENO
: $((1
+ \
2))
echo $LINENO
__IN__
4
8
12
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/nop-p.tst <<'EOF'
# nop-p.tst: test of the colon, true, and false built-ins

posix="true"

test_OE -e 0 'colon (no arguments)'
:
__IN__

test_OE -e 0 'colon (some arguments)'
: unused ignored arguments
__IN__

test_OE -e 0 'true'
true
__IN__

test_OE -e n 'false'
false
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/option-p.tst <<'EOF'
# option-p.tst: test of shell options for any POSIX-compliant shell

posix="true"

test_x -e 0 'allexport (short) on: $-' -a
printf '%s\n' "$-" | grep -q a
__IN__

test_x -e 0 'allexport (long) on: $-' -o allexport
printf '%s\n' "$-" | grep -q a
__IN__

test_x -e 0 'allexport (short) off: $-' +a
printf '%s\n' "$-" | grep -qv a
__IN__

test_x -e 0 'allexport (long) off: $-' +o allexport
printf '%s\n' "$-" | grep -qv a
__IN__

test_oE 'allexport (short) on: effect' -a
unset foo
foo=bar
sh -c 'echo ${foo-unset}'
__IN__
bar
__OUT__

test_oE 'allexport (long) on: effect' -o allexport
unset foo
foo=bar
sh -c 'echo ${foo-unset}'
__IN__
bar
__OUT__

test_oE 'allexport (short) off: effect' +a
unset foo
foo=bar
sh -c 'echo ${foo-unset}'
__IN__
unset
__OUT__

test_oE 'allexport (long) off: effect' +o allexport
unset foo
foo=bar
sh -c 'echo ${foo-unset}'
__IN__
unset
__OUT__

# XXX: test of the -b option is not supported

test_x -e 0 'errexit (short) on: $-' -e
printf '%s\n' "$-" | grep -q e
__IN__

test_x -e 0 'errexit (long) on: $-' -o errexit
printf '%s\n' "$-" | grep -q e
__IN__

test_x -e 0 'errexit (short) off: $-' +e
printf '%s\n' "$-" | grep -qv e
__IN__

test_x -e 0 'errexit (long) off: $-' +o errexit
printf '%s\n' "$-" | grep -qv e
__IN__

# Other tests of the -e option are in errexit-p.tst.

test_x -e 0 'noglob (short) on: $-' -f
printf '%s\n' "$-" | grep -q f
__IN__

test_x -e 0 'noglob (long) on: $-' -o noglob
printf '%s\n' "$-" | grep -q f
__IN__

test_x -e 0 'noglob (short) off: $-' +f
printf '%s\n' "$-" | grep -qv f
__IN__

test_x -e 0 'noglob (long) off: $-' +o noglob
printf '%s\n' "$-" | grep -qv f
__IN__

test_oE 'noglob (short) on: effect' -f
echo /*
__IN__
/*
__OUT__

test_oE 'noglob (long) on: effect' -o noglob
echo /*
__IN__
/*
__OUT__

test_oE 'noglob (short) off: effect' +f
printf '%s\n' /* | grep -x /dev
__IN__
/dev
__OUT__

test_oE 'noglob (long) off: effect' +o noglob
printf '%s\n' /* | grep -x /dev
__IN__
/dev
__OUT__

test_x -e 0 'hashondef (short) on: $-' -h
printf '%s\n' "$-" | grep -q h
__IN__

test_x -e 0 'hashondef (short) off: $-' +h
printf '%s\n' "$-" | grep -qv h
__IN__

# XXX: test of the -m option is not supported

test_x -e 0 'noexec (short) on: $-' -n
printf '%s\n' "$-" | grep -q n
__IN__

test_x -e 0 'noexec (long) on: $-' -o noexec
printf '%s\n' "$-" | grep -q n
__IN__

test_x -e 0 'noexec (short) off: $-' +n
printf '%s\n' "$-" | grep -qv n
__IN__

test_x -e 0 'noexec (long) off: $-' +o noexec
printf '%s\n' "$-" | grep -qv n
__IN__

test_OE 'noexec (short) on: simple command is not executed' -n
echo executed
__IN__

test_OE 'noexec (long) on: simple command is not executed' -o noexec
echo executed
__IN__

test_oE 'noexec (short) off: simple command is executed' +n
echo executed
__IN__
executed
__OUT__

test_oE 'noexec (long) off: simple command is executed' +o noexec
echo executed
__IN__
executed
__OUT__

{
testee -cn 'for i in $(>noexec_file); do :; done'

test_OE -e 0 'noexec (short) on: for command is not executed'
! [ -e noexec_file ]
__IN__

}

# See pipeline-p.tst for the pipefail option tests.

test_x -e 0 'nounset (short) on: $-' -u
printf '%s\n' "$-" | grep -q u
__IN__

test_x -e 0 'nounset (long) on: $-' -o nounset
printf '%s\n' "$-" | grep -q u
__IN__

test_x -e 0 'nounset (short) off: $-' +u
printf '%s\n' "$-" | grep -qv u
__IN__

test_x -e 0 'nounset (long) off: $-' +o nounset
printf '%s\n' "$-" | grep -qv u
__IN__

(
setup -d
setup 'foo=bar s=; unset x'

test_oE -e 0 'nounset on: expansions of set variable' -u
bracket ${foo} ${foo-unset} ${foo:-unset} ${foo+set} ${foo:+set}
bracket "${s}" "${s-unset}" "${s:-unset}" "${s+set}" "${s:+set}"
bracket ${#foo} ${#s}
bracket ${foo#b} ${foo##b} ${foo%r} ${foo%%r}
bracket "${s#b}" "${s##b}" "${s%r}" "${s%%r}"
__IN__
[bar][bar][bar][set][set]
[][][unset][set][]
[3][0]
[ar][ar][ba][ba]
[][][][]
__OUT__

test_oE -e 0 'nounset on: set variable ${foo=bar}' -u
bracket ${foo=X}
bracket ${foo}
__IN__
[bar]
[bar]
__OUT__

test_oE -e 0 'nounset on: set variable ${foo:=bar}' -u
bracket ${foo:=X}
bracket ${foo}
__IN__
[bar]
[bar]
__OUT__

test_oE -e 0 'nounset on: set variable ${foo?bar}' -u
bracket ${foo?X}
__IN__
[bar]
__OUT__

test_oE -e 0 'nounset on: set variable ${foo:?bar}' -u
bracket ${foo:?X}
__IN__
[bar]
__OUT__

test_oE -e 0 'nounset on: set variable $((foo))' -u
bracket $((x=42))
bracket $((x))
__IN__
[42]
[42]
__OUT__

test_oE -e 0 'nounset on: empty variable ${foo=bar}' -u
bracket "${s=X}"
bracket "${s}"
__IN__
[]
[]
__OUT__

test_oE -e 0 'nounset on: empty variable ${foo:=bar}' -u
bracket "${s:=X}"
bracket "${s}"
__IN__
[X]
[X]
__OUT__

test_oE -e 0 'nounset on: empty variable ${foo?bar}' -u
bracket "${s?X}"
__IN__
[]
__OUT__

test_O -d -e n 'nounset on: empty variable ${foo:?bar}' -u
bracket "${s:?X}"
bracket "${s}"
__IN__

test_O -d -e n 'nounset on: unset variable ${foo}' -u
bracket ${x}
__IN__

test_oE -e 0 'nounset on: unset variable ${foo-bar}' -u
bracket ${x-unset}
__IN__
[unset]
__OUT__

test_oE -e 0 'nounset on: unset variable ${foo:-bar}' -u
bracket ${x:-unset}
__IN__
[unset]
__OUT__

test_oE -e 0 'nounset on: unset variable ${foo+bar}' -u
bracket "${x+set}"
__IN__
[]
__OUT__

test_oE -e 0 'nounset on: unset variable ${foo:+bar}' -u
bracket "${x:+set}"
__IN__
[]
__OUT__

test_oE -e 0 'nounset on: unset variable ${foo=bar}' -u
bracket ${x=unset}
bracket ${x}
__IN__
[unset]
[unset]
__OUT__

test_oE -e 0 'nounset on: unset variable ${foo:=bar}' -u
bracket ${x:=unset}
bracket ${x}
__IN__
[unset]
[unset]
__OUT__

test_O -d -e n 'nounset on: unset variable ${foo?bar}' -u
bracket ${x?unset}
__IN__

test_O -d -e n 'nounset on: unset variable ${foo:?bar}' -u
bracket ${x:?unset}
__IN__

test_O -d -e n 'nounset on: unset variable ${#foo}' -u
bracket "${#x}"
__IN__

test_O -d -e n 'nounset on: unset variable ${foo#bar}' -u
bracket "${x#y}"
__IN__

test_O -d -e n 'nounset on: unset variable ${foo##bar}' -u
bracket "${x##y}"
__IN__

test_O -d -e n 'nounset on: unset variable ${foo%bar}' -u
bracket "${x%y}"
__IN__

test_O -d -e n 'nounset on: unset variable ${foo%%bar}' -u
bracket "${x%%y}"
__IN__

test_O -d -e n 'nounset on: unset variable $((foo))' -u
bracket "$((x))"
__IN__

)

test_x -e 0 'verbose (short) on: $-' -v
printf '%s\n' "$-" | grep -q v
__IN__

test_x -e 0 'verbose (long) on: $-' -o verbose
printf '%s\n' "$-" | grep -q v
__IN__

test_x -e 0 'verbose (short) off: $-' +v
printf '%s\n' "$-" | grep -qv v
__IN__

test_x -e 0 'verbose (long) off: $-' +o verbose
printf '%s\n' "$-" | grep -qv v
__IN__

test_oe 'verbose (short) on: effect' -v
echo 1
echo 2
if true; then
echo 3
fi
__IN__
1
2
3
__OUT__
echo 1
echo 2
if true; then
echo 3
fi
__ERR__

test_oe 'verbose (long) on: effect' -o verbose
echo 1
echo 2
if true; then
echo 3
fi
__IN__
1
2
3
__OUT__
echo 1
echo 2
if true; then
echo 3
fi
__ERR__

test_x -e 0 'xtrace (short) on: $-' -x
printf '%s\n' "$-" | grep -q x
__IN__

test_x -e 0 'xtrace (long) on: $-' -o xtrace
printf '%s\n' "$-" | grep -q x
__IN__

test_x -e 0 'xtrace (short) off: $-' +x
printf '%s\n' "$-" | grep -qv x
__IN__

test_x -e 0 'xtrace (long) off: $-' +o xtrace
printf '%s\n' "$-" | grep -qv x
__IN__

test_oe 'xtrace (short) on: effect' -x
foo=bar
echo $foo
__IN__
bar
__OUT__
+ foo=bar
+ echo bar
__ERR__

test_oe 'xtrace (long) on: effect' -o xtrace
foo=bar
echo $foo
__IN__
bar
__OUT__
+ foo=bar
+ echo bar
__ERR__

test_oe '$PS4'
foo=XY PS4='${foo#X} '; set -x 2>/dev/null
echo xtrace
__IN__
xtrace
__OUT__
Y echo xtrace
__ERR__

# To test the ignoreeof option, we need to emulate the terminal device.
#test_oe 'ignoreeof on: effect' -o ignoreeof

test_OE -e 0 'ignoreeof is ignored if not interactive' +i -o ignoreeof
# The shell should exit successfully at EOF
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/param-p.tst <<'EOF'
# param-p.tst: test of parameter expansion for any POSIX-compliant shell

posix="true"

> file
setup -d

test_oE 'format for parameter expansion'
a=a
bracket -${a-\}}- -${a-'}'}- -${a-"}"}- -${a}}-
bracket -${a-${a}}- -${a-$({ :;})}-
bracket -${a-$(($({ :;})))}- -${a-${a-${a-${a}}}}-
__IN__
[-a-][-a-][-a-][-a}-]
[-a-][-a-]
[-a-][-a-]
__OUT__

test_oE -e 0 'simplest expansion'
a=value
unset b
bracket -${a}-
bracket -${b}-
__IN__
[-value-]
[--]
__OUT__

test_oE 'expansion w/o braces, variables'
aa=value _L0NG_variable_name=x
unset aaa
bracket -$aa-
bracket -$aaa-
bracket -$_L0NG_variable_name-
__IN__
[-value-]
[--]
[-x-]
__OUT__

test_oE 'expansion w/o braces, positional parameters'
set a b
bracket -$1- $22
__IN__
[-a-][b2]
__OUT__

test_oE 'expansion w/o braces, special parameters'
set 1
: dummy&
zero="$0" dollar="$$" hyphen="$-" ex="$!" hash="$#" star="$*" at="$@"
echoraw "$??"
[ "$00"  = "${zero}0"       ] || echoraw '$0' [ "$00"  = "${zero}0"       ]
[ "$$$$" = "$dollar$dollar" ] || echoraw '$$' [ "$$$$" = "$dollar$dollar" ]
[ "$--"  = "$hyphen-"       ] || echoraw '$-' [ "$--"  = "$hyphen-"       ]
[ "$!!"  = "$ex!"           ] || echoraw '$!' [ "$!!"  = "$ex!"           ]
[ "$##"  = "$hash#"         ] || echoraw '$#' [ "$##"  = "$hash#"         ]
[ "$**"  = "$star*"         ] || echoraw '$*' [ "$**"  = "$star*"         ]
[ "$@@"  = "$at@"           ] || echoraw '$@' [ "$@@"  = "$at@"           ]
__IN__
0?
__OUT__

test_oE 'double-quoted expansion is not subject to pathname expansion'
a='*'
bracket "${a}"
bracket ${a+"${a}"}
__IN__
[*]
[*]
__OUT__

test_oE 'double-quoted expansion is not subject to field splitting'
a='a b  c'
bracket "${a}"
bracket ${a+"${a}"}
__IN__
[a b  c]
[a b  c]
__OUT__

test_oE 'tilde expansion in embedded word'
HOME=/foo/bar b=b
bracket ${a-~} ${a-~/} ${a-\~}
bracket ${b+~} ${b+~/} ${b+\~}
bracket ${c=~} ${d=~/} ${e=\~}
(: ${a?~} ) 2>&1 | grep -Fq "$HOME" ; echo $?
(: ${a?~/}) 2>&1 | grep -Fq "$HOME/"; echo $?
(: ${a?\~}) 2>&1 | grep -Fq "~"     ; echo $?
__IN__
[/foo/bar][/foo/bar/][~]
[/foo/bar][/foo/bar/][~]
[/foo/bar][/foo/bar/][~]
0
0
0
__OUT__

test_oE 'parameter expansion in embedded word'
b=b
bracket ${a-x${b}x} ${a-\$b}
bracket ${b+x${b}x} ${b+\$b}
bracket ${c=x${b}x} ${d=\$b}
(: ${a?x${b}x}) 2>&1 | grep -Fq "xbx"; echo $?
(: ${a?\$b}   ) 2>&1 | grep -Fq "$b" ; echo $?
__IN__
[xbx][$b]
[xbx][$b]
[xbx][$b]
0
0
__OUT__

test_oE 'command substitution in embedded word'
b=b
bracket ${a-x$(echo -)x}
bracket ${b+x$(echo -)x}
bracket ${c=x$(echo -)x}
(: ${a?x$(echo -)x}) 2>&1 | grep -Fq "x-x"; echo $?
__IN__
[x-x]
[x-x]
[x-x]
0
__OUT__

test_oE 'arithmetic expansion in embedded word'
b=b
bracket ${a-x$((1+1))x}
bracket ${b+x$((1+1))x}
bracket ${c=x$((1+1))x}
(: ${a?x$((1+1))x}) 2>&1 | grep -Fq "x2x"; echo $?
__IN__
[x2x]
[x2x]
[x2x]
0
__OUT__

test_oE 'embedded word is expanded only if needed'
a=
unset b
bracket -${a-${b?}}- -${b+${b?}}- -${a=${b?}}- -${a?${b?}}-
a=a b=
bracket -${a:-${b?}}- -${b:+${b?}}- -${a:=${b?}}- -${a:?${b?}}-
__IN__
[--][--][--][--]
[-a-][--][-a-][-a-]
__OUT__

test_oE 'end of embedded word'
a=a
bracket ${a-x}b} ${a-x${a-x}x}b}
__IN__
[ab}][ab}]
__OUT__

(
setup 'a=a n=; unset u'

test_oE '${a-b}'
bracket "${a-x}" "${n-x}" "${u-x}"
bracket "${a:-x}" "${n:-x}" "${u:-x}"
__IN__
[a][][x]
[a][x][x]
__OUT__

test_oE '${a+b}'
bracket "${a+x}" "${n+x}" "${u+x}"
bracket "${a:+x}" "${n:+x}" "${u:+x}"
__IN__
[x][x][]
[x][][]
__OUT__

test_oE '${a=b}'
bracket "${a=x}" "${n=x}" "${u=x}"
bracket "${a}" "${n}" "${u}"
__IN__
[a][][x]
[a][][x]
__OUT__

test_oE '${a:=b}'
bracket "${a:=x}" "${n:=x}" "${u:=x}"
bracket "${a}" "${n}" "${u}"
__IN__
[a][x][x]
[a][x][x]
__OUT__

test_O -d -e n 'assigning to read-only variable'
readonly n
bracket ${n:=}
__IN__

test_O -d -e n 'assigning to positional parameter'
bracket ${1:=}
__IN__

test_O -d -e n 'assigning to special parameter'
bracket ${*:=}
__IN__

test_oE '${a?b}, success'
bracket "${a?x}" "${n?x}"
bracket "${a:?x}"
__IN__
[a][]
[a]
__OUT__

test_O -d -e n '${unset?b}, failure w/o message'
bracket "${u?}"
__IN__

test_O -e n '${unset?b}, failure with message, exit status and stdout'
bracket "${u?foo bar  baz}"
__IN__

test_OE -e 0 '${unset?b}, failure with message, stderr'
(: "${u?foo bar  baz}") 2>&1 | grep -Fq 'foo bar  baz'
__IN__

test_O -d -e n '${null?b}, failure'
bracket "${n:?}"
__IN__

test_O -d -e n '${unset?b}, failure'
bracket "${u:?}"
__IN__

)

test_oE 'length of valid variables'
zero= one=a two=bb five=ccccc twenty=dddddddddddddddddddd
bracket ${#zero} ${#one} ${#five} ${#twenty}
set '' a bb cccc
bracket ${#1} ${#2} ${#3} ${#4}
: dummy&
zero="$0" dollar="$$" hyphen="$-" ex="$!" hash="$#"
echoraw '${#?}' ${#?}
[ "${#0}" = "${#zero}"   ] || echoraw '$0' [ "${#0}" = "${#zero}"   ]
[ "${#$}" = "${#dollar}" ] || echoraw '$$' [ "${#$}" = "${#dollar}" ]
[ "${#-}" = "${#hyphen}" ] || echoraw '$-' [ "${#-}" = "${#hyphen}" ]
[ "${#!}" = "${#ex}"     ] || echoraw '$!' [ "${#!}" = "${#ex}"     ]
# ambiguous...
# [ "${##}" = "${#hash}"   ] || echoraw '$#' [ "${##}" = "${#hash}"   ]
__IN__
[0][1][5][20]
[0][1][2][4]
${#?} 1
__OUT__

test_oE -e 0 'length of unset variables, success'
unset u
echoraw ${#u}
__IN__
0
__OUT__

test_O -d -e n 'length of unset variables, failure' -u
unset u
echoraw ${#u}
__IN__

test_oE 'disambiguation of ${#...'
bracket ${#-""}
bracket ${#?X}
bracket ${#+""} "${#:+}"
bracket ${#=""} "${#:=}"
__IN__
[0]
[0]
[][]
[0][0]
__OUT__

test_oE 'removing shortest matching prefix'
a=1-2-3-4 s='***' h='###'
bracket "${a#1}" "${a#*1}" "${a#1*}" "${a#1*-}"
bracket "${a#*-}" "${a#*}" "${a#-*}" "${a#*-*}"
bracket "${a#2}" "${s#'*'}" "${h#'#'}"
__IN__
[-2-3-4][-2-3-4][-2-3-4][2-3-4]
[2-3-4][1-2-3-4][1-2-3-4][2-3-4]
[1-2-3-4][**][##]
__OUT__

test_oE 'removing longest matching prefix'
a=1-2-3-4 s='***' h='###'
bracket "${a##1}" "${a##*1}" "${a##1*}" "${a##1*-}"
bracket "${a##*-}" "${a##*}" "${a##-*}" "${a##*-*}"
bracket "${a##2}" "${s##'*'}" "${h###}"
__IN__
[-2-3-4][-2-3-4][][4]
[4][][1-2-3-4][]
[1-2-3-4][**][##]
__OUT__

test_oE 'removing shortest matching suffix'
a=1-2-3-4 s='***' p='%%%'
bracket "${a%4}" "${a%*4}" "${a%4*}" "${a%-*4}"
bracket "${a%*-}" "${a%*}" "${a%-*}" "${a%*-*}"
bracket "${a%3}" "${s%'*'}" "${p%'%'}"
__IN__
[1-2-3-][1-2-3-][1-2-3-][1-2-3]
[1-2-3-4][1-2-3-4][1-2-3][1-2-3]
[1-2-3-4][**][%%]
__OUT__

test_oE 'removing longest matching suffix'
a=1-2-3-4 s='***' p='%%%'
bracket "${a%%4}" "${a%%*4}" "${a%%4*}" "${a%%-*4}"
bracket "${a%%*-}" "${a%%*}" "${a%%-*}" "${a%%*-*}"
bracket "${a%%3}" "${s%%'*'}" "${p%%%}"
__IN__
[1-2-3-][][1-2-3-][1]
[1-2-3-4][][1][]
[1-2-3-4][**][%%]
__OUT__

test_oE 'tilde expansion in embedded pattern'
HOME=/home/foo a=/home/foo/bar b=/usr/home/foo
bracket ${a#~}  "${a#~}"  ${a#"~"}
bracket ${a##~} "${a##~}" ${a##"~"}
bracket ${b%~}  "${b%~}"  ${b%"~"}
bracket ${b%%~} "${b%%~}" ${b%%"~"}
__IN__
[/bar][/bar][/home/foo/bar]
[/bar][/bar][/home/foo/bar]
[/usr][/usr][/usr/home/foo]
[/usr][/usr][/usr/home/foo]
__OUT__

test_oE 'parameter expansion in embedded pattern'
w='ab\bc' a='*' b='\'
bracket ${w#${a}b}  "${w#${a}b}"  ${w#"${a}b"}
bracket ${w##${a}b} "${w##${a}b}" ${w##"${a}b"}
bracket ${w%b${a}}  "${w%b${a}}"  ${w%"b${a}"}
bracket ${w%%b${a}} "${w%%b${a}}" ${w%%"b${a}"}
# XCU 2.9.4 implies unquoted backslashes are special in the pattern.
bracket ${w#*${b}b}  "${w#*${b}b}"  ${w#"*${b}b"}
bracket ${w##*${b}b} "${w##*${b}b}" ${w##"*${b}b"}
bracket ${w%${b}b*}  "${w%${b}b*}"  ${w%"${b}b*"}
bracket ${w%%${b}b*} "${w%%${b}b*}" ${w%%"${b}b*"}
__IN__
[\bc][\bc][ab\bc]
[c][c][ab\bc]
[ab\][ab\][ab\bc]
[a][a][ab\bc]
[\bc][\bc][ab\bc]
[c][c][ab\bc]
[ab\][ab\][ab\bc]
[a][a][ab\bc]
__OUT__

test_oE 'command substitution in embedded pattern'
w='ab\bc'
bracket ${w#$(echo '*')b}  "${w#$(echo '*')b}"  ${w#"$(echo '*')b"}
bracket ${w##$(echo '*')b} "${w##$(echo '*')b}" ${w##"$(echo '*')b"}
bracket ${w%b$(echo '*')}  "${w%b$(echo '*')}"  ${w%"b$(echo '*')"}
bracket ${w%%b$(echo '*')} "${w%%b$(echo '*')}" ${w%%"b$(echo '*')"}
__IN__
[\bc][\bc][ab\bc]
[c][c][ab\bc]
[ab\][ab\][ab\bc]
[a][a][ab\bc]
__OUT__

test_oE 'arithmetic expansion in embedded pattern'
w='12223'
bracket ${w#*$((1+1))}  "${w#*$((1+1))}"  ${w#"*$((1+1))"}
bracket ${w##*$((1+1))} "${w##*$((1+1))}" ${w##"*$((1+1))"}
bracket ${w%$((1+1))*}  "${w%$((1+1))*}"  ${w%"$((1+1))*"}
bracket ${w%%$((1+1))*} "${w%%$((1+1))*}" ${w%%"$((1+1))*"}
__IN__
[223][223][12223]
[3][3][12223]
[122][122][12223]
[1][1][12223]
__OUT__

### Examples from informative sections of POSIX

test_oE 'effects of omitting braces'
a=1
set 2
echo ${a}b-$ab-${1}0-${10}-$10
__IN__
1b--20--20
__OUT__

test_oE 'testing existence of positional parameter'
set a b c
echo ${3:+posix}
echo ${4-posix}
__IN__
posix
posix
__OUT__

test_oE 'removing prefix with expanded word'
HOME=/home/foo
x=$HOME/src/cmd
echo ${x#$HOME}
__IN__
/src/cmd
__OUT__

test_oE 'special parameter #'
echo $#
set x
echo $#
set x 'y  y' z
echo $#
set a b c d e f g h i j k
echo $#
__IN__
0
1
3
11
__OUT__

test_oE 'special parameter ?'
echo $?
(exit 1)
echo $?
(exit 123)
echo $?
(exit 42)
(echo $?)
__IN__
0
1
123
42
__OUT__

test_OE -e 0 'special parameter -' -eu
set +C
v=$-
[ "$(echo $v | grep e | grep u | grep -v C)" ]
__IN__

test_OE 'special parameter $'
[ $$ -eq "$(echo $$)" ] || echo [ $$ -eq "$(echo $$)" ]
kill $$
echo not reached
__IN__

test_O -e USR1 'special parameter !'
while kill -s 0 $$; do sleep 1; done &
kill -s USR1 $!
wait $!
__IN__

# Special parameter 0 is tested in sh-p.tst
#test_oE 'special parameter 0'

test_oE 'special parameter *, quoted, unset IFS'
unset IFS
bracket "$*"
set a
bracket "$*"
set a 'b  b' cc
bracket "$*"
set ''
bracket "$*"
set '' ''
bracket "$*"
set ' a ' '  b  ' ' cc '
bracket "$*"
__IN__
[]
[a]
[a b  b cc]
[]
[ ]
[ a    b    cc ]
__OUT__

test_oE 'special parameter *, quoted, non-default IFS'
IFS=xyz
bracket "$*"
set a
bracket "$*"
set a 'b  b' cc
bracket "$*"
set ''
bracket "$*"
set '' ''
bracket "$*"
set ' a ' '  b  ' ' cc '
bracket "$*"
__IN__
[]
[a]
[axb  bxcc]
[]
[x]
[ a x  b  x cc ]
__OUT__

test_oE 'special parameter *, quoted, empty IFS'
IFS=
bracket "$*"
set a
bracket "$*"
set a 'b  b' cc
bracket "$*"
set ''
bracket "$*"
set '' ''
bracket "$*"
set ' a ' '  b  ' ' cc '
bracket "$*"
__IN__
[]
[a]
[ab  bcc]
[]
[]
[ a   b   cc ]
__OUT__

test_oE 'special parameter *, unquoted'
bracket $*
bracket ""$*
bracket $*""
set a
bracket $*
bracket ""$*
bracket $*""
set a 'b  b' cc
bracket $*
bracket ""$*
bracket $*""
IFS=
bracket $*
bracket ""$*
bracket $*""
__IN__

[]
[]
[a]
[a]
[a]
[a][b][b][cc]
[a][b][b][cc]
[a][b][b][cc]
[a][b  b][cc]
[a][b  b][cc]
[a][b  b][cc]
__OUT__

test_oE 'special parameter @, quoted'
bracket "$@"
bracket "$@""$@" - "$@""$@""$@"
bracket "=$@="
null=
bracket "$null""$@"
bracket "$@""$null"
bracket "$null""$@""$null" - "$null""$null""$@" - "$@""$null""$null"
bracket "$null""$@$null" - "$null""$null$@" - \
        "$@$null""$null" - "$null$@""$null"
set a
bracket "$@"
bracket "=$@="
set a 'b  b' cc
bracket "$@"
bracket "=$@="
bracket "$@$@"
set ''
bracket "$@"
bracket "=$@="
bracket "$@$@" - "$null""$@" - "$@""$null" - "$null""$@""$null"
set '' ''
bracket "$@"
bracket "=$@="
bracket "$@$@"
bracket "$null""$@""$null"
set ' a ' '  b  ' ' cc '
bracket "$@"
__IN__

[-]
[==]
[]
[]
[][-][][-][]
[][-][][-][][-][]
[a]
[=a=]
[a][b  b][cc]
[=a][b  b][cc=]
[a][b  b][cca][b  b][cc]
[]
[==]
[][-][][-][][-][]
[][]
[=][=]
[][][]
[][]
[ a ][  b  ][ cc ]
__OUT__

# Expansion of unquoted $@ is the same as that of unquoted $*
test_oE 'special parameter @, unquoted'
bracket $@
bracket ""$@
bracket $@""
set a
bracket $@
bracket ""$@
bracket $@""
set a 'b  b' cc
bracket $@
bracket ""$@
bracket $@""
IFS=
bracket $@
bracket ""$@
bracket $@""
__IN__

[]
[]
[a]
[a]
[a]
[a][b][b][cc]
[a][b][b][cc]
[a][b][b][cc]
[a][b  b][cc]
[a][b  b][cc]
[a][b  b][cc]
__OUT__

test_oE '${1+"$@"}'
bracket ${1+"$@"}
set a
bracket ${1+"$@"}
set a 'b  b' cc
bracket ${1+"$@"}
set ''
bracket ${1+"$@"}
set '' ''
bracket ${1+"$@"}
set '' '' ''
bracket ${1+"$@"}
set ' ' ' ' ' '
bracket ${1+"$@"}
__IN__

[a]
[a][b  b][cc]
[]
[][]
[][][]
[ ][ ][ ]
__OUT__

test_oE '${foo:-"$@"}'
set a 'b  b' cc
unset foo
bracket ${foo:-"$@"}
foo=
bracket ${foo:-"$@"}
foo=bar
bracket ${foo:-"$@"}
__IN__
[a][b  b][cc]
[a][b  b][cc]
[bar]
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/path-p.tst <<'EOF'
# path-p.tst: test of pathname expansion for any POSIX-compliant shell

posix="true"

mkdir -p foo/dir foo/no_read_dir foo/no_search_dir
>foo/dir/file >foo/no_read_dir/file >foo/no_search_dir/file
chmod a-r foo/no_read_dir
chmod a-x foo/no_search_dir

mkdir -p "bar/a[b/c]d"

mkdir -p baz/.dir/.file

test_oE 'expansion with read-and-searchable directory'
echo foo/*dir
echo foo/d*r/f*e
__IN__
foo/dir foo/no_read_dir foo/no_search_dir
foo/dir/file
__OUT__

test_oE '* does not match slash'
echo foo*dir*file
__IN__
foo*dir*file
__OUT__

test_oE '? does not match slash'
echo foo?dir?file
__IN__
foo?dir?file
__OUT__

test_oE '[...] does not match slash'
echo foo[/]dir[/]file
echo bar/a[b/c]d
__IN__
foo[/]dir[/]file
bar/a[b/c]d
__OUT__

test_oE '* does not match initial dot'
echo baz/*dir/*file
__IN__
baz/*dir/*file
__OUT__

test_oE '? does not match initial dot'
echo baz/?dir/?file
__IN__
baz/?dir/?file
__OUT__

test_oE '[!...] does not match initial dot'
echo baz/[!a]dir/[!1-9]file
__IN__
baz/[!a]dir/[!1-9]file
__OUT__

: This is not yet mandatory in POSIX, so it is tested in path-y.sh <<'__OUT__'
test_oE 'no pattern matches . or ..'
echo .*/ # should not print . or ..
__IN__
.dir/
__OUT__

test_oE 'literal . and .. are not filtered out'
echo b*/../.
__IN__
bar/../. baz/../.
__OUT__

(
# Skip if we're root.
if { ls for/dir || <foo/no_search_dir/file; } 2>/dev/null; then
    skip="true"
fi

test_oE 'expansion with unreadable directory'
echo f*o/no_read_dir
echo foo/no_read_d*r
echo foo/no_read_d*r/file
echo foo/no_read_dir/f*e
echo foo/no_read_d*r/f*e
__IN__
foo/no_read_dir
foo/no_read_dir
foo/no_read_dir/file
foo/no_read_dir/f*e
foo/no_read_d*r/f*e
__OUT__

test_oE 'expansion with unsearchable directory'
echo f*o/no_search_dir
echo foo/no_search_d*r
echo foo/no_search_d*r/file
# echo foo/no_search_dir/f*e
echo foo/no_search_d*r/f*e
__IN__
foo/no_search_dir
foo/no_search_dir
foo/no_search_d*r/file
foo/no_search_dir/file
__OUT__
# POSIX says: "Any component, except the last, that does not contain any '*',
# '?' or '[' characters that will be treated as special shall require search
# permission." This statement is not actually correct. If the last component
# contains a pattern character, only read permission is required for its parent
# directory. The expansion of foo/no_search_dir/f*e succeeds in many shells
# despite the POSIX requirement, so the line for this case is commented out.

)

test_oE 'pathnames are sorted according to current collating sequence'
echo [fb]*/
__IN__
bar/ baz/ foo/
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/pipeline-p.tst <<'EOF'
# pipeline-p.tst: test of pipeline for any POSIX-compliant shell

posix="true"

test_o '2-command pipeline'
echo foo | cat
__IN__
foo
__OUT__

test_o '3-command pipeline'
printf '%s\n' foo bar | tail -n 1 | cat
__IN__
bar
__OUT__

test_o 'linebreak after |'
printf '%s\n' foo bar |
tail -n 1 | 
    
cat
__IN__
bar
__OUT__

test_oE 'without pipefail, exit status of pipeline is from last command'
exit 0 | exit 0 | exit 0
echo a $?
exit 1 | exit 2 | exit 0
echo b $?
exit 3 | exit 0 | exit 0
echo c $?
exit 0 | exit 0 | exit 4
echo d $?
exit 5 | exit 6 | exit 7
echo e $?
__IN__
a 0
b 0
c 0
d 4
e 7
__OUT__

test_oE 'exit status of negated pipelines (without pipefail)'
! exit 0 | exit 0 | exit 0
echo a $?
! exit 1 | exit 2 | exit 0
echo b $?
! exit 3 | exit 0 | exit 0
echo c $?
! exit 0 | exit 0 | exit 4
echo d $?
! exit 5 | exit 6 | exit 7
echo e $?
__IN__
a 1
b 1
c 1
d 0
e 0
__OUT__

test_oE 'with pipefail, last failed command determines exit status' -o pipefail
exit 0 | exit 0 | exit 0
echo a $?
exit 1 | exit 2 | exit 0
echo b $?
exit 3 | exit 0 | exit 0
echo c $?
exit 0 | exit 0 | exit 4
echo d $?
exit 5 | exit 6 | exit 7
echo e $?
__IN__
a 0
b 2
c 3
d 4
e 7
__OUT__

test_oE 'exit status of negated pipelines (with pipefail)' -o pipefail
! exit 0 | exit 0 | exit 0
echo a $?
! exit 1 | exit 2 | exit 0
echo b $?
! exit 3 | exit 0 | exit 0
echo c $?
! exit 0 | exit 0 | exit 4
echo d $?
! exit 5 | exit 6 | exit 7
echo e $?
__IN__
a 1
b 0
c 0
d 0
e 0
__OUT__

test_OE -e 0 'pipeline enabling pipefail does not affect itself'
false | set -o pipefail
__IN__

test_oE 'stdin for first command & stdout for last are not modified'
cat | tail -n 1
foo
bar
__IN__
bar
__OUT__

test_Oe 'stderr is not modified'
(echo >&2) | (echo >&2)
__IN__


__ERR__

test_oE 'compound commands in pipeline'
{
    echo foo
    echo bar
} | (
    tail -n 1
    echo baz
) | if true; then
    cat
else
    :
fi
__IN__
bar
baz
__OUT__

test_OE 'redirection overrides pipeline'
echo foo >/dev/null | cat
echo foo | </dev/null cat
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/ppid-p.tst <<'EOF'
# ppid-p.tst: test of the $PPID variable for any POSIX-compliant shell

posix="true"

test_OE -e 0 'PPID is parent process ID'
echo $PPID >variable.out
echo $(ps -o ppid= $$) >ps.out
diff variable.out ps.out
__IN__

test_OE -e 0 'PPID does not change in subshell'
echo $PPID >main.out
(echo $PPID) >subshell.out
diff main.out subshell.out
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/quote-p.tst <<'EOF'
# quote-p.tst: test of quoting for any POSIX-compliant shell

posix="true"

setup -d

test_oE 'backslash (not preceding newline)'
bracket \ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'
bracket \0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\?
bracket \@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_ \\ \\\\
bracket \a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`
__IN__
[ !$x%&()*+,-./][#]["x"]['x']
[0123456789:;<=>?]
[@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_][\][\\]
[abcdefghijklmnopqrstuvwxyz{|}~][``]
__OUT__

test_oE 'line continuation in normal word'
bracket 123\
456\
\
789 \
ABC\
 DEF
__IN__
[123456789][ABC][DEF]
__OUT__

test_OE -e 0 'line continuation in reserved word !'
\
!\
 false
__IN__

test_oE 'line continuation in reserved words { }'
\
{\
 echo 1
\
}\
||
\
{\
 echo 2
\
}\

__IN__
1
__OUT__

test_oE 'line continuation in reserved words case in esac and operator ;;'
\
c\
a\
s\
e\
 a \
i\
n\
 (a) echo 1\
;\
;\
e\
s\
a\
c\

__IN__
1
__OUT__

test_oE 'line continuation in reserved words for in do done'
\
f\
o\
r\
\
 \
i\
 \
i\
n\
\
 1 2
\
d\
o\
\
 echo $i
\
d\
o\
n\
e\

__IN__
1
2
__OUT__

test_oE 'line continuation in reserved words if then elif else fi'
\
i\
f\
\
 false
\
t\
h\
e\
n\
\
 echo 1
e\
l\
i\
f\
 true
\
t\
h\
e\
n\
\
 echo 2
e\
l\
s\
e\
\
 echo 3
\
f\
i\
\

__IN__
2
__OUT__

test_oE 'line continuation in reserved words while do done'
\
w\
h\
i\
l\
e\
\
 true
\
d\
o\
\
 echo 1
break
\
d\
o\
n\
e\
\

__IN__
1
__OUT__

test_oE 'line continuation in reserved words until do done'
\
u\
n\
t\
i\
l\
\
 false
\
d\
o\
\
 echo 1
break
\
d\
o\
n\
e\
\

__IN__
1
__OUT__

test_oE 'line continuation in operators && ||'
true\
&\
&\
\
false\
|\
|\
\
echo 1
__IN__
1
__OUT__

test_oE 'line continuation in function definition'
\
f\
un\
c \
 ( \
 )  \
 # comment
 \
 ( echo ok )

func
__IN__
ok
__OUT__

test_oE 'line continuation in operators <> >> <& >&'
echo 1 >redir
echo 2 \
3\
>\
>\
\
redir \
>\
&\
\
3
cat \
4\
<\
>\
redir \
<\
&\
\
4
__IN__
1
2
__OUT__

test_oE 'line continuation in operator >|' -C
echo XXX >clobber
echo foo \
>\
|\
\
clobber
cat clobber
__IN__
foo
__OUT__

test_oE 'line continuation in here-document operators'
cat \
<\
<\
\
E\
N\
D\

foo
END
cat \
<\
<\
-\
\
E\
O\
F\

		bar
	EOF
__IN__
foo
bar
__OUT__

test_oE 'line continuation in assignment'
fo\
o\
=\
b\
ar
echo $foo
__IN__
bar
__OUT__

test_oE 'line continuation in parameter expansion'
f=foo
# echo $f ${f} ${#f} ${f#f} ${f:+x}
echo \
\
$\
\
f $\
\
{\
\
f\
\
} $\
{\
\
#\
f\
} $\
{\
f\
\
#\
\
f\
\
} $\
{\
f\
\
:\
\
+\
\
x\
\
}
__IN__
foo foo 3 oo x
__OUT__

test_oE 'line continuation in arithmetic expansion'
echo \
$\
\
(\
\
(\
\
1\
\
 \
 + \
 \
2\
\
)\
\
)
__IN__
3
__OUT__

test_oE 'line continuation in command substitution $(...)'
echo \
$\
\
(\
\
echo 1\
\
)
__IN__
1
__OUT__

test_oE 'line continuation in command substitution `...`'
echo \
`\
\
echo 1\
\
`
__IN__
1
__OUT__

test_oE 'single quotes'
bracket 'abc' '"a"' 'a\\b' 'a''''''b'
bracket 'a
b' 'a

b'
__IN__
[abc]["a"][a\\b][ab]
[a
b][a

b]
__OUT__

test_oE 'dollar-single-quotes'
bracket $'' $'a' $'a
b' -$'\"\'\'"\\\a\b\e\f\n\r\t\v\x20\1000'- =$'\x9'$'\11\7'=
bracket $'\cA\ca\c^\c\\\c?' $'\\
'
__IN__
[][a][a
b][-"''"\

	 @0-][=		=]
[][\
]
__OUT__

test_oE 'double quotes'
bracket "abc" "'a'"
bracket "a
b" "a

b"
__IN__
[abc]['a']
[a
b][a

b]
__OUT__

test_oE 'expansions in double quotes'
a=variable
bracket "$a" "${a}" "$(echo command)" "`echo command`" "$((1+10))"
__IN__
[variable][variable][command][command][11]
__OUT__

test_oE 'double quotes in command substitution in double quotes'
bracket "$(bracket "foo
echo ")"
__IN__
[[foo
echo ]]
__OUT__

test_oE 'aliases are ignored in command substitution in double quotes'
alias echo=')'
f() { bracket "$(echo x)"; }
unalias echo
f
__IN__
[x]
__OUT__

test_oE 'backslashes in double quotes'
bracket "a\\b" "a\\\\b"
bracket "a\$b" "a\`b\`c" "a\"b\"c"
bracket "a\
b\
c"
bracket "\ \!\#\$x\%\&\'\(\)\*\+\,\-\.\/"
bracket "\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\?"
bracket "\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\\\]\^\_"
bracket "\`\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~\`"
bracket "a	
	b"
__IN__
[a\b][a\\b]
[a$b][a`b`c][a"b"c]
[abc]
[\ \!\#$x\%\&\'\(\)\*\+\,\-\.\/]
[\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\?]
[\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\\]\^\_]
[`\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~`]
[a	
	b]
__OUT__

test_oE 'backslashes in substitution of expansion ${a+b}'
a=a
bracket ${a+\ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'}
bracket ${a+\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \\ \\\\}
bracket ${a+\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_}
bracket ${a+\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`}
__IN__
[ !$x%&()*+,-./][#]["x"]['x']
[0123456789:;<=>?][\][\\]
[@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_]
[abcdefghijklmnopqrstuvwxyz{|}~][``]
__OUT__

test_oE 'backslashes in substitution of expansion ${a+b} in double quotes'
a=a
bracket "${a+\ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'}"
bracket "${a+\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \\ \\\\}"
bracket "${a+\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_}"
bracket "${a+\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`}"
__IN__
[\ \!$x\%\&\(\)\*\+\,\-\.\/ \# "x" \'x\']
[\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \ \\]
[\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_]
[\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|}\~ ``]
__OUT__

test_oE 'backslashes in substitution of expansion ${a-b}'
bracket ${u-\ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'}
bracket ${u-\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \\ \\\\}
bracket ${u-\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_}
bracket ${u-\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`}
__IN__
[ !$x%&()*+,-./][#]["x"]['x']
[0123456789:;<=>?][\][\\]
[@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_]
[abcdefghijklmnopqrstuvwxyz{|}~][``]
__OUT__

test_oE 'backslashes in substitution of expansion ${a-b} in double quotes'
bracket "${u-\ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'}"
bracket "${u-\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \\ \\\\}"
bracket "${u-\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_}"
bracket "${u-\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`}"
__IN__
[\ \!$x\%\&\(\)\*\+\,\-\.\/ \# "x" \'x\']
[\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \ \\]
[\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_]
[\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|}\~ ``]
__OUT__

# Quote removal is performed before assignment, so the resultant expansions are
# subject to field splitting.
test_oE 'quotes in substitution of expansion ${a=b}'
bracket ${a=\ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'}
bracket ${b=\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \\ \\\\}
bracket ${c=\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_}
bracket ${d=\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`}
bracket $a
bracket $b
bracket $c
bracket $d
__IN__
[!$x%&()*+,-./][#]["x"]['x']
[0123456789:;<=>?][\][\\]
[@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_]
[abcdefghijklmnopqrstuvwxyz{|}~][``]
[!$x%&()*+,-./][#]["x"]['x']
[0123456789:;<=>?][\][\\]
[@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_]
[abcdefghijklmnopqrstuvwxyz{|}~][``]
__OUT__

# Quote removal is performed before assignment, but the resultant expansions
# are not subject to field splitting because they are double-quoted.
test_oE 'quotes in substitution of expansion ${a=b} in double quotes'
bracket "${a=\ \!\$x\%\&\(\)\*\+\,\-\.\/ \# \"x\" \'x\'}"
bracket "${b=\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \\ \\\\}"
bracket "${c=\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_}"
bracket "${d=\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|\}\~ \`\`}"
bracket "${e=a"b"c}" "${f=a"*"c}" "${g=a"\"\""c}" "${h=a"\\"c}" "${i=a"''"c}"
bracket "${j=a'b'c}" "${k=a'*'c}" "${l=a'""'c}"   "${m=a'\'c}"
bracket "$a"
bracket "$b"
bracket "$c"
bracket "$d"
bracket "$e" "$f" "$g" "$h" "$i"
bracket "$j" "$k" "$l" "$m"
__IN__
[\ \!$x\%\&\(\)\*\+\,\-\.\/ \# "x" \'x\']
[\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \ \\]
[\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_]
[\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|}\~ ``]
[abc][a*c][a""c][a\c][a''c]
[a'b'c][a'*'c][a''c][a'\'c]
[\ \!$x\%\&\(\)\*\+\,\-\.\/ \# "x" \'x\']
[\0\1\2\3\4\5\6\7\8\9\:\;\<\=\>\? \ \\]
[\@\A\B\C\D\E\F\G\H\I\J\K\L\M\N\O\P\Q\R\S\T\U\V\W\X\Y\Z\[\]\^\_]
[\a\b\c\d\e\f\g\h\i\j\k\l\m\n\o\p\q\r\s\t\u\v\w\x\y\z\{\|}\~ ``]
[abc][a*c][a""c][a\c][a''c]
[a'b'c][a'*'c][a''c][a'\'c]
__OUT__

# See quote-y.tst
#test_oE 'backslashes in substitution of expansion ${a?b}'
#__IN__
#__OUT__

test_oE 'single and double quotes in substitution of expansion ${a+b}'
a=a
bracket ${a+a"b"c} ${a+a"*"c} ${a+a"\"\""c} ${a+a"\\"c} ${a+a"''"c}
bracket ${a+a'b'c} ${a+a'*'c} ${a+a'""'c}   ${a+a'\'c}
__IN__
[abc][a*c][a""c][a\c][a''c]
[abc][a*c][a""c][a\c]
__OUT__

test_oE 'single quotes in substitution of expansion ${a+b} in double quotes'
a=a
unset b
bracket "${a+a'$b'c}"
bracket "${a+a'b}"
bracket "${a+a$'\t'b}"
__IN__
[a''c]
[a'b]
[a$'\t'b]
__OUT__
#}"

test_oE 'tilde in substitution of expansion ${a+b}'
HOME=/home a=a
bracket ${a+~} "${a+~}"
__IN__
[/home][~]
__OUT__

test_oE 'single and double quotes in substitution of expansion ${a-b}'
bracket ${u-a"b"c} ${u-a"*"c} ${u-a"\"\""c} ${u-a"\\"c} ${u-a"''"c}
bracket ${u-a'b'c} ${u-a'*'c} ${u-a'""'c}   ${u-a'\'c}
__IN__
[abc][a*c][a""c][a\c][a''c]
[abc][a*c][a""c][a\c]
__OUT__

test_oE 'single quotes in substitution of expansion ${a-b} in double quotes'
unset a b
bracket "${a-a'$b'c}"
bracket "${a-a'b}"
bracket "${a-a$'\t'b}"
__IN__
[a''c]
[a'b]
[a$'\t'b]
__OUT__
#}"

test_oE 'tilde in substitution of expansion ${a-b}'
HOME=/home
bracket ${a-~} "${a-~}"
__IN__
[/home][~]
__OUT__

test_oE 'single and double quotes in substitution of expansion ${a=b}'
bracket ${a=a"b"c} ${b=a"*"c} ${c=a"\"\""c} ${d=a"\\"c} ${e=a"''"c}
bracket ${f=a'b'c} ${g=a'*'c} ${h=a'""'c}   ${i=a'\'c}
bracket $a $b $c $d $e
bracket $f $g $h $i
__IN__
[abc][a*c][a""c][a\c][a''c]
[abc][a*c][a""c][a\c]
[abc][a*c][a""c][a\c][a''c]
[abc][a*c][a""c][a\c]
__OUT__

test_oE 'single quotes in substitution of expansion ${a=b} in double quotes'
unset a b c d
bracket "${a=a'$b'c}"
bracket "${c=a'b}"
bracket "${d=a$'\t'b}"
bracket "$a" "$c" "$d"
__IN__
[a''c]
[a'b]
[a$'\t'b]
[a''c][a'b][a$'\t'b]
__OUT__
#'
#}"

test_oE 'tilde in substitution of expansion ${a=b}'
HOME=/home
bracket ${a=~} "${b=~}"
bracket "$a" "$b"
__IN__
[/home][~]
[/home][~]
__OUT__

# See quote-y.tst
#test_oE 'single and double quotes in substitution of expansion ${a?b}'
#__IN__
#__OUT__

test_oE 'quotes in pattern of expansions'
# double quotes
a='*""ok'
bracket ${a#"*"\"\"} "${a#"*"\"\"}"
# single quotes
b="*''ok"
bracket ${b#'*'\'\'} "${b#'*'\'\'}"
# backslashes
c='*\ok'
bracket ${c#\*\\} "${c#\*\\}"
__IN__
[ok][ok]
[ok][ok]
[ok][ok]
__OUT__

test_oE 'backslashes resulting from expansions (not a pattern)'
# The backslashes are not subject to quote removal since they were not present
# in the original word before parameter expansion.
v='\a\b\c'
bracket "$v"
bracket $v
__IN__
[\a\b\c]
[\a\b\c]
__OUT__

(
(> '\' > '\*') 2>/dev/null || skip="true"

test_oE 'backslashes resulting from expansions (a pattern)'
# This backslash escapes the asterisk, so pathname expansion does not match
# with '\' or '\*'.
v='\*'
bracket "$v"
bracket $v
__IN__
[\*]
[\*]
__OUT__

)

test_oE 'quoted words are not reserved words'
echo echo if command >if
chmod a+x if
PATH=.:$PATH
\if
"i"f
i'f'
__IN__
if command
if command
if command
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/read-p.tst <<'EOF'
# read-p.tst: test of the read built-in for any POSIX-compliant shell

posix="true"
setup -d

test_oE 'single operand - without IFS'
read a <<\END
A
END
echoraw $? "[${a-unset}]"
__IN__
0 [A]
__OUT__

test_oE 'single operand - with IFS whitespace'
read a <<\END
  A  
END
echoraw $? "[${a-unset}]"
__IN__
0 [A]
__OUT__

test_oE 'single operand - with IFS non-whitespace'
read a <<\END
 - A - 
END
echoraw $? "[${a-unset}]"
__IN__
0 [- A -]
__OUT__

test_oE 'EOF fails read'
! read a </dev/null
echoraw $? "[${a-unset}]"
__IN__
0 []
__OUT__

test_oE 'read does not read more than needed'
{
    read a
    echo B
    cat
} <<\END
\
A
C
END
__IN__
B
C
__OUT__

test_oE 'variables are assigned even if EOF is reached without newline'
printf 'foo bar baz' | {
read a b
echo $? [$a] [$b]
}
__IN__
1 [foo] [bar baz]
__OUT__

test_oE 'orphan backslash is ignored'
printf 'foo\' | {
read a
printf '[%s]\n' "$a"
}
__IN__
[foo]
__OUT__

test_oE 'set -o allexport'
(
set -a
read a b <<\END
A B
END
sh -u -c 'echo "[$a]" "[$b]"'
)
__IN__
[A] [B]
__OUT__

test_oE 'line continuation - followed by normal line'
read a b <<\END
A\
A B\
B
END
echoraw $? "[${a-unset}]" "[${b-unset}]"
__IN__
0 [AA] [BB]
__OUT__

test_oE 'line continuation - followed by EOF'
! read a b <<\END
A\
END
echoraw $? "[${a-unset}]" "[${b-unset}]"
__IN__
0 [A] []
__OUT__

test_oE 'field splitting - 1'
IFS=' -' read a b c <<\END
 AA B CC 
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]"
__IN__
0 [AA] [B] [CC]
__OUT__

test_oE 'field splitting - 2-1'
IFS=' -' read a b c d e <<\END
-BB-C-DD-
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [BB] [C] [DD] []
__OUT__

test_oE 'field splitting - 2-2'
IFS=' -' read a b c d e <<\END
- BB- C- DD- 
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [BB] [C] [DD] []
__OUT__

test_oE 'field splitting - 2-3'
IFS=' -' read a b c d e <<\END
 -BB -C -DD -
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [BB] [C] [DD] []
__OUT__

test_oE 'field splitting - 2-4'
IFS=' -' read a b c d e <<\END
 - BB - C - DD - 
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [BB] [C] [DD] []
__OUT__

test_oE 'field splitting - 3-1'
IFS=' -' read a b c d e <<\END
--CC--
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [] [CC] [] []
__OUT__

test_oE 'field splitting - 3-2'
IFS=' -' read a b c d e <<\END
  --CC  --
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [] [CC] [] []
__OUT__

test_oE 'field splitting - 3-3'
IFS=' -' read a b c d e <<\END
-  -CC-  -
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [] [CC] [] []
__OUT__

test_oE 'field splitting - 3-4'
IFS=' -' read a b c d e <<\END
--  CC--  
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" \
    "[${d-unset}]" "[${e-unset}]"
__IN__
0 [] [] [CC] [] []
__OUT__

test_oE 'backslash prevents field splitting - backslash not in IFS'
IFS=' -' read a b c d <<\END
A\ A \ \B\  C\\C\-C\\-D
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]"
__IN__
0 [A A] [ B ] [C\C-C\] [D]
__OUT__

test_oE 'backslash prevents field splitting - backslash in IFS'
IFS=' -\' read a b c d <<\END
A\ A \ \B\  C\\C\-C\\-D
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]"
__IN__
0 [A A] [ B ] [C\C-C\] [D]
__OUT__

test_oE 'line continuation and newline as IFS'
IFS='
' read a b <<\END
A\
B
C
END
echoraw $? "[${a-unset}]" "[${b-unset}]"
__IN__
0 [AB] []
__OUT__

test_oE 'variables are assigned empty string for missing fields'
read a b c d <<\END
A B
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]"
__IN__
0 [A] [B] [] []
__OUT__

test_oE 'exact number of fields with non-whitespace IFS'
IFS=' -' read a b c <<\END
A-B-C - 
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]"
__IN__
0 [A] [B] [C]
__OUT__

test_oE 'too many fields are joined with trailing whitespaces removed'
IFS=' -' read a b c <<\END
A B C-C C\\C\
C   
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]"
__IN__
0 [A] [B] [C-C C\CC]
__OUT__

test_oE 'too many fields are joined, ending with non-whitespace delimiter'
IFS=' -' read a b c <<\END
A B C-C C\\C\
C -  
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]"
__IN__
0 [A] [B] [C-C C\CC -]
__OUT__

test_oE 'no field splitting with empty IFS'
IFS= read a b c d <<\END
 A\ B \ \C\  D\\E\-F\\-G 
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]"
__IN__
0 [ A B  C  D\E-F\-G ] [] [] []
__OUT__

test_oE 'non-default delimiters'
{
read -d : a b
read -d x c d
} <<\END
A B:C D ExF
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]"
__IN__
0 [A] [B] [C] [D E]
__OUT__

test_oE 'raw mode - backslash not in IFS'
IFS=' -' read -r a b c d <<\END
A\A\\ B-C\- D\
X
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]"
__IN__
0 [A\A\\] [B] [C\] [D\]
__OUT__

test_oE 'raw mode - backslash in IFS'
IFS=' -\' read -r a b c d e f <<\END
A\B\\ D-E\- F\
X
END
echoraw $? "[${a-unset}]" "[${b-unset}]" "[${c-unset}]" "[${d-unset}]" \
    "[${e-unset}]" "[${f-unset}]"
__IN__
0 [A] [B] [] [D] [E] [- F\]
__OUT__

test_oE 'in subshell'
(echo A | read a)
echoraw $? "[${a-unset}]"
__IN__
0 [unset]
__OUT__

test_O -e n 'failure by readonly variable'
echo B | (readonly a=A; read a)
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/readonly-p.tst <<'EOF'
# readonly-p.tst: test of the readonly built-in for any POSIX-compliant shell

posix="true"

test_o -d -e n 'making one variable read-only'
readonly a=bar
echo $a
a=X # This should fail, and the shell should exit.
echo not reached
__IN__
bar
__OUT__

test_o -d 'making many variables read-only'
a=X b=B c=X
readonly a=A b c=C
echo $a $b $c
(
    a=X # This should fail, and the subshell should exit.
    echo not reached
) || (
    b=Y # This should fail, and the subshell should exit.
    echo not reached
) || (
    c=Z # This should fail, and the subshell should exit.
    echo not reached
) ||
echo $a $b $c # This should print the values passed to the readonly built-in.
__IN__
A B C
A B C
__OUT__

test_oE -e 0 'separator preceding operand' -e
readonly -- a=foo
echo $a
__IN__
foo
__OUT__

# This test is in readonly-y.tst because it fails on some existing shells
# because of pre-defined read-only variables.
#test_x 'reusing printed read-only variables'

test_O -d -e n 'read-only variable cannot be re-assigned'
readonly a=1
readonly a=2
# The readonly built-in fails because of the readonly variable.
# Since it is a special built-in, the non-interactive shell exits.
echo not reached
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/redir-p.tst <<'EOF'
# redir-p.tst: test of redirections for any POSIX-compliant shell

posix="true"

exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-

echo in0 >in0
echo in1 >in1
echo in2 >in2
echo in3 >in3
echo 'in*' >'in*'

test_o 'quoted file descriptor'
echo \2>quotedfd
echo ---
cat quotedfd
__IN__
---
2
__OUT__

test_oE 'file descriptor must immediately precede operator'
echo 1 >precede1
echo 2>precede2
echo ---
cat precede1
echo ----
cat precede2
__IN__

---
1
----
__OUT__

test_o 'file descriptors up to 9 are supported'
cat 9<in0 8<&9 7<&8 6<&7 5<&6 4<&5 3<&4 0<&3
__IN__
in0
__OUT__

test_x -e 0 'multi-digit file descriptor'
echo 11>multidigit # should not be interpreted as "echo 1 1>multidigit"
test "$(cat multidigit)" != 1
__IN__

test_oE -e 0 'tilde expansion in redirection operand'
HOME=$PWD
cat <~/in0
__IN__
in0
__OUT__

test_oE -e 0 'parameter expansion in redirection operand'
i=xxxin0
cat <${i#xxx}
__IN__
in0
__OUT__

test_oE -e 0 'command substitution in redirection operand'
cat <`echo in`$(echo 0)
__IN__
in0
__OUT__

test_oE -e 0 'arithmetic expansion in redirection operand'
cat <in$((1-1))
__IN__
in0
__OUT__

test_oE -e 0 'quote removal in redirection operand'
cat <\i'n'"0"
__IN__
in0
__OUT__

test_oE -e 0 'pathname expansion in redirection operand (non-interactive)'
cat <in*
__IN__
in*
__OUT__

test_O -e n 'redirections apply in order of appearance'
echo - 1>/dev/null 3>&1 2>&3 3>&-
1>&- 2>&1
__IN__

test_O 'redirection without command name runs in subshell'
unset x
< ${x=no/such/file}
<<END
${x=foo}
END
# The assignments in the subshell are not visible from the main shell.
${x+echo not printed}
__IN__

test_oE 'input redirection, success'
cat 0<in0
cat  <in1
__IN__
in0
in1
__OUT__

test_O -d -e n 'input redirection, failure'
<_no_such_dir_/foo
__IN__

test_oE 'overwrite redirection, +C, success'
echo foo  >overwrite1
echo bar 1>overwrite2
          >overwrite2
echo ---
cat overwrite1 overwrite2
__IN__
---
foo
__OUT__

test_oE 'overwrite redirection, -C, success' -C
echo foo >overwrite3 # non-existing file
echo bar >/dev/null  # existing non-regular file
echo ---
cat overwrite3
__IN__
---
foo
__OUT__

test_O -d -e n 'overwrite redirection, -C, existing file error' -C
echo foo >overwrite4
echo boo >overwrite4
__IN__

test_o 'overwrite redirection, -C, existing file not modified' -C
echo foo >overwrite5
echo boo >overwrite5 || :
echo ---
cat overwrite5
__IN__
---
foo
__OUT__

test_O -d -e n 'overwrite redirection, creation failure'
>_no_such_dir_/foo
__IN__

test_oE 'clobbering redirection, +C, success'
echo foo  >|clobber1
echo bar 1>|clobber2
          >|clobber2
echo --- $?
cat overwrite1 overwrite2
__IN__
--- 0
foo
__OUT__

test_oE 'clobbering redirection, -C, success' -C
echo foo >|clobber3  # non-existing file
echo --- $?
echo bar >|/dev/null # existing non-regular file
echo ---- $?
cat clobber3
echo -----
>|clobber3  # existing file
echo ------ $?
cat clobber3
__IN__
--- 0
---- 0
foo
-----
------ 0
__OUT__

test_O -d -e n 'clobbering redirection, creation failure'
>|_no_such_dir_/foo
__IN__

test_oE 'appending redirection, success, new file'
echo foo >>append1
echo --- $?
cat append1
__IN__
--- 0
foo
__OUT__

test_oE 'appending redirection, success, existing file'
echo foo >>append2
echo --- $?
echo bar >>append2
echo ---- $?
cat append2
__IN__
--- 0
---- 0
foo
bar
__OUT__

test_oE 'effect of appending redirection'
{
    echo foo >&3 &&
    echo bar >&4 &&
    echo baz >&3 &&
    echo qux >&4
} 3>>append3 4>>append3 &&
cat append3
__IN__
foo
bar
baz
qux
__OUT__

test_oE -e 0 'in-out redirection, success'
echo foo 1<>inout1
echo --- $?
cat <>inout1
__IN__
--- 0
foo
__OUT__

test_O -d -e n 'in-out redirection, failure'
<>_no_such_dir_/foo
__IN__

test_oE -e 0 'input duplication, success'
cat 3<in3  <&3 &&
cat 3<in3 0<&"$((1+2))"
__IN__
in3
in3
__OUT__

(
setup 'exec 3<&-'

test_O -d -e n 'input duplication, failure (closed file descriptor)'
<&3
__IN__

)

test_O -d -e n 'input duplication, failure (unreadable file descriptor)'
cat 3>/dev/null <&3
__IN__

test_OE -e 0 'input closing, success, open file descriptor'
<&- && 0<&-
__IN__

test_OE -e 0 'input closing, success, closed file descriptor'
<&- <&-
__IN__

test_O -e n 'effect of input closing'
cat <&-
__IN__

test_oE 'output duplication, success'
echo foo 3>dup1  >&3
echo --- $?
echo bar 3>>dup1 1>&"$((1+2))"
echo ---- $?
cat dup1
__IN__
--- 0
---- 0
foo
bar
__OUT__

(
setup 'exec 3>&-'

test_O -d -e n 'output duplication, failure (closed file descriptor)'
>&3
__IN__

)

test_O -d -e n 'output duplication, failure (unreadable file descriptor)'
3</dev/null >&3
__IN__

test_OE -e 0 'output closing, success, open file descriptor'
>&- && 1>&-
__IN__

test_OE -e 0 'output closing, success, closed file descriptor'
>&- >&-
__IN__

test_O -e n 'effect of output closing'
echo >&-
__IN__

test_oE -e 0 'effect of here-document'
cat <<END
here

	document
END
__IN__
here

	document
__OUT__

test_oE -e 0 'here-document with non-default file descriptor'
cat 3<<END <&3
foo
END
__IN__
foo
__OUT__

test_oE -e 0 'no tilde expansion with unquoted here-document delimiter'
HOME=/home
cat <<END
tilde ~
END
__IN__
tilde ~
__OUT__

test_oE -e 0 'parameter expansion with unquoted here-document delimiter'
foo=foooo
cat <<END
parameter ${foo%"oo"}
END
__IN__
parameter foo
__OUT__

test_oE -e 0 'command substitution with unquoted here-document delimiter'
cat <<END
command $(echo "foo") `echo "bar"`
END
__IN__
command foo bar
__OUT__

test_oE -e 0 'arithmetic expansion with unquoted here-document delimiter'
cat <<END
arithmetic $((1+10))
END
__IN__
arithmetic 11
__OUT__

test_oE -e 0 'backslash with unquoted here-document delimiter'
foo=bar
cat <<END
backslash \a \$foo \\\\ \`\` \"\" line-\
continuation
END
__IN__
backslash \a $foo \\ `` \"\" line-continuation
__OUT__

test_oE -e 0 'single and double quotes with unquoted here-document delimiter'
cat <<END
quote 'single' "double \$ 'a' " \$ 'a'
END
__IN__
quote 'single' "double $ 'a' " $ 'a'
__OUT__

test_oE -e 0 'no tilde expansion with quoted here-document delimiter'
HOME=/home
cat <<'END'
tilde ~
END
__IN__
tilde ~
__OUT__

test_oE -e 0 'no parameter expansion with quoted here-document delimiter'
foo=foooo
cat <<'END'
parameter ${foo%"oo"}
END
__IN__
parameter ${foo%"oo"}
__OUT__

test_oE -e 0 'no command substitution with quoted here-document delimiter'
cat <<'END'
command $(echo "foo") `echo "bar"`
END
__IN__
command $(echo "foo") `echo "bar"`
__OUT__

test_oE -e 0 'no arithmetic expansion with quoted here-document delimiter'
cat <<'END'
arithmetic $((1+10))
END
__IN__
arithmetic $((1+10))
__OUT__

test_oE -e 0 'no quote removal with quoted here-document delimiter'
cat <<'echo'
backslash \a \$foo \\\\ \`\` \"\" line-\
continuation
quote 'single' "double \$ 'a' " \$ 'a'
ec\
ho
echo
__IN__
backslash \a \$foo \\\\ \`\` \"\" line-\
continuation
quote 'single' "double \$ 'a' " \$ 'a'
ec\
ho
__OUT__

test_oE -e 0 'no parameter expansion with double-quoted here-document delimiter'
cat <<"END"
foo=$foo
END
__IN__
foo=$foo
__OUT__

test_O -e n 'expansion error in here-document'
echo not printed <<END
${a?}
END
__IN__

test_oE -e 0 'various quotation of here-document delimiter'
cat <<E'N'D &&
single
END
cat <<E"N"D &&
double
END
cat <<E\ND
backslash
END
__IN__
single
double
backslash
__OUT__

test_oE -e 0 'tab removal with <<-'
cat <<-END
foo
			bar
		END
__IN__
foo
bar
__OUT__

test_oE -e 0 'here-document delimiter containing tab'
cat <<-END\	HERE
foo
	END	HERE
__IN__
foo
__OUT__

test_oE -e 0 'here-document delimiter starting with -'
cat << -END
foo
END
-END
__IN__
foo
END
__OUT__

test_oE -e 0 'multiple here-documents on single command'
foo=bar
{
    cat <&5
    cat <&4
    cat <&3
    cat
} <<END-0 3<<-END-3 4<<'END-4' 5<<-'END-5'
	0 $foo
END-0
	3 $foo
END-3
	4 $foo
END-4
	5 $foo
END-5
__IN__
5 $foo
	4 $foo
3 bar
	0 bar
__OUT__

test_oE -e 0 'multiple commands each with here-document'
cat <<END1; echo ---; cat <<END2
END2
END1
foo
END2
__IN__
END2
---
foo
__OUT__

test_o 'redirection is temporary' -e
{
    cat </dev/null
    cat
} <<END
here
END
__IN__
here
__OUT__

{
    echo 'exec cat <<END'
    i=0
    while [ $i -lt 10000 ]; do
       printf '%d\n' \
           $((i   )) $((i+ 1)) $((i+ 2)) $((i+ 3)) $((i+ 4)) $((i+ 5)) \
           $((i+ 6)) $((i+ 7)) $((i+ 8)) $((i+ 9)) $((i+10)) $((i+11)) \
           $((i+12)) $((i+13)) $((i+14)) $((i+15)) $((i+16)) $((i+17)) \
           $((i+18)) $((i+19)) $((i+20)) $((i+21)) $((i+22)) $((i+23)) \
           $((i+24)) $((i+25)) $((i+26)) $((i+27)) $((i+28)) $((i+29)) \
           $((i+30)) $((i+31)) $((i+32)) $((i+33)) $((i+34)) $((i+35)) \
           $((i+36)) $((i+37)) $((i+38)) $((i+39)) $((i+40)) $((i+41)) \
           $((i+42)) $((i+43)) $((i+44)) $((i+45)) $((i+46)) $((i+47)) \
           $((i+48)) $((i+49))
       i=$((i+50))
    done
    echo 'END'
} >longhere

test_oE -e 0 'long here-document' -e
. ./longhere |
while read -r i; do
    test "$i" -eq "${j:=0}"
    j=$((j+1))
done
__IN__
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/return-p.tst <<'EOF'
# return-p.tst: test of the return built-in for any POSIX-compliant shell

posix="true"

macos_kill_workaround

test_oE 'returning from function, unnested'
fn() {
    echo in function
    return
    echo not reached
}
fn
echo after function
__IN__
in function
after function
__OUT__

test_oE 'returning from function, nested in other functions'
first=true
fn1() {
    echo in fn1
    if $first; then
        first=false
    else
        return
    fi
    echo recurring
    fn1
    echo recurred
}
fn2() {
    echo in fn2
    fn1
    echo out fn2
}
fn2
echo after function
__IN__
in fn2
in fn1
recurring
in fn1
recurred
out fn2
after function
__OUT__

cat <<\__END__ >fn
fn() {
    echo in function
    return
    echo out function, not reached
}
fn
echo after function
__END__

test_oE 'returning from function, nested in dot script'
. ./fn
echo after dot
__IN__
in function
after function
after dot
__OUT__

cat <<\__END__ >return
echo in return
return
echo out return, not reached
__END__

test_oE 'returning from dot script, unnested'
. ./return
echo after .
__IN__
in return
after .
__OUT__

cat <<\__END__ >outer
echo in outer
. ./return
echo out outer
__END__

test_oE 'returning from dot script, nested in another dot script'
. ./outer
echo after .
__IN__
in outer
in return
out outer
after .
__OUT__

test_oE 'returning from dot script, nested in function'
fn() {
    echo in function
    . ./return
    echo out function
}
fn
echo after function
__IN__
in function
in return
out function
after function
__OUT__

test_OE -e 13 'default exit status of returning from function'
fn() {
    (exit 13)
    return
}
fn
__IN__

cat <<\__END__ >exitstatus
(exit 17)
return
__END__

test_OE -e 17 'default exit status of returning from dot script'
. ./exitstatus
__IN__

test_OE -e 13 'specifying exit status in returning from function'
fn() {
    (exit 1)
    return 13
}
fn
__IN__

cat <<\__END__ >exitstatus17
(exit 1)
return 17
__END__

test_OE -e 17 'specifying exit status in returning from dot script'
. ./exitstatus17
__IN__

test_oE -e 0 'default exit status in function in trap'
fn() { true; return; }
trap 'fn; echo trapped $?' USR1
(exit 19)
(kill -s USR1 $$; exit 19)
: # null command to ensure the trap to be handled
__IN__
trapped 19
__OUT__

# TODO Yash does not yet support this
test_oE -e 0 -f 'default exit status in trap in function'
trap '(exit 1); return; echo X $?' INT
f() {
    (kill -INT $$; exit 2)
    echo Y $?
}
f
echo Z $?
__IN__
Z 2
__OUT__

test_OE 'returning out of eval'
fn() {
    eval return
    echo not reached
}
fn
__IN__

test_OE 'returning with !'
fn() {
    ! return
    echo not reached
}
fn
__IN__

test_OE 'returning before &&'
fn() {
    return && echo not reached 1
    echo not reached 2 $?
}
fn
__IN__

test_OE 'returning after &&'
fn() {
    true && return
    echo not reached $?
}
fn
__IN__

test_OE 'returning before ||'
fn() {
    return || echo not reached 1
    echo not reached 2 $?
}
fn
__IN__

test_OE 'returning after ||'
fn() {
    false || return
    echo not reached $?
}
fn
__IN__

test_OE 'returning out of brace'
fn() {
    { return; }
    echo not reached
}
fn
__IN__

test_OE 'returning out of if'
fn() {
    if return; then echo not reached then; else echo not reached else; fi
    echo not reached
}
fn
__IN__

test_OE 'returning out of then'
fn() {
    if true; then return; echo not reached then; else echo not reached else; fi
    echo not reached
}
fn
__IN__

test_OE 'returning out of else'
fn() {
    if false; then echo not reached then; else return; echo not reached else; fi
    echo not reached
}
fn
__IN__

test_OE 'returning out of for loop'
fn() {
    for i in 1; do
        return
        echo not reached in loop
    done
    echo not reached after loop
}
fn
__IN__

test_OE 'returning out of while loop'
fn() {
    while true; do
        return
        echo not reached in loop
    done
    echo not reached after loop
}
fn
__IN__

test_OE 'returning out of until loop'
fn() {
    until false; do
        return
        echo not reached in loop
    done
    echo not reached after loop
}
fn
__IN__

test_OE 'returning out of case'
fn() {
    case x in
        x)
            return
            echo not reached in case
    esac
    echo not reached after esac
}
fn
__IN__

test_OE -e 56 'separator preceding operand'
fn() {
    return -- 56
    echo not reached
}
fn
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/set-p.tst <<'EOF'
# set-p.tst: test of the set built-in for any POSIX-compliant shell

posix="true"

setup -d

test_oE 'setting one positional parameter (no --)' -e
set foo
bracket "$@"
__IN__
[foo]
__OUT__

test_oE 'setting three positional parameters (no --)' -e
set foo 'B  A  R' baz
bracket "$@"
__IN__
[foo][B  A  R][baz]
__OUT__

test_oE 'setting empty positional parameters (no --)' -e
set '' ''
bracket "$@"
__IN__
[][]
__OUT__

test_oE 'setting zero positional parameters' -es 1 2 3
set --
echo $#
__IN__
0
__OUT__

test_oE 'setting three positional parameters (with --)' -e
set -- - -- baz
bracket "$@"
__IN__
[-][--][baz]
__OUT__

# $1 = $LINENO, $2 = short option, $3 = long option
test_short_option_on() {
    testcase "$1" -e 0 "$3 (short) on: \$-" 3<<__IN__ 4<&- 5<&-
set -$2 &&
printf '%s\n' "\$-" | grep -q $2
__IN__
}

# $1 = $LINENO, $2 = short option, $3 = long option
test_short_option_off() {
    testcase "$1" -e 0 "$3 (short) off: \$-" "-$2" 3<<__IN__ 4<&- 5<&-
set +$2 &&
printf '%s\n' "\$-" | grep -qv $2
__IN__
}

# $1 = $LINENO, $2 = short option, $3 = long option
test_long_option_on() {
    testcase "$1" -e 0 "$3 (long) on: \$-" 3<<__IN__ 4<&- 5<&-
set -o $3 &&
printf '%s\n' "\$-" | grep -q $2
__IN__
}

# $1 = $LINENO, $2 = short option, $3 = long option
test_long_option_off() {
    testcase "$1" -e 0 "$3 (long) off: \$-" "-$2" 3<<__IN__ 4<&- 5<&-
set +o $3 &&
printf '%s\n' "\$-" | grep -qv $2
__IN__
}

test_short_option_on  "$LINENO" a allexport
test_short_option_off "$LINENO" a allexport
test_long_option_on   "$LINENO" a allexport
test_long_option_off  "$LINENO" a allexport

test_short_option_on  "$LINENO" b notify
test_short_option_off "$LINENO" b notify
test_long_option_on   "$LINENO" b notify
test_long_option_off  "$LINENO" b notify

test_short_option_on  "$LINENO" C noclobber
test_short_option_off "$LINENO" C noclobber
test_long_option_on   "$LINENO" C noclobber
test_long_option_off  "$LINENO" C noclobber

test_short_option_on  "$LINENO" e errexit
test_short_option_off "$LINENO" e errexit
test_long_option_on   "$LINENO" e errexit
test_long_option_off  "$LINENO" e errexit

test_short_option_on  "$LINENO" f noglob
test_short_option_off "$LINENO" f noglob
test_long_option_on   "$LINENO" f noglob
test_long_option_off  "$LINENO" f noglob

test_short_option_on  "$LINENO" h hashondef
test_short_option_off "$LINENO" h hashondef
# This is not POSIX.
#test_long_option_on   "$LINENO" h hashondef
#test_long_option_off  "$LINENO" h hashondef

# The -m option cannot be tested here due to dependency on the terminal.

test_short_option_on  "$LINENO" n noexec
test_short_option_off "$LINENO" n noexec
# One can never reset the -n option
#test_long_option_on   "$LINENO" n noexec
#test_long_option_off  "$LINENO" n noexec

test_short_option_on  "$LINENO" u nounset
test_short_option_off "$LINENO" u nounset
test_long_option_on   "$LINENO" u nounset
test_long_option_off  "$LINENO" u nounset

test_short_option_on  "$LINENO" v verbose
test_short_option_off "$LINENO" v verbose
test_long_option_on   "$LINENO" v verbose
test_long_option_off  "$LINENO" v verbose

test_short_option_on  "$LINENO" x xtrace
test_short_option_off "$LINENO" x xtrace
test_long_option_on   "$LINENO" x xtrace
test_long_option_off  "$LINENO" x xtrace

test_x -e 0 'setting many shell options at once' -a
set -ex +a -o noclobber -u
printf '%s\n' "$-" | grep -qv a &&
printf '%s\n' "$-" | grep C | grep e | grep u | grep -q x
__IN__

test_oE 'setting only options does not change positional parameters' -s 1 foo
set -e
bracket "$@"
__IN__
[1][foo]
__OUT__

test_oE 'setting positional parameters and shell options at once'
set -a -e foo 2
printf '%s\n' "$-" | grep a | grep -q e && bracket "$@"
__IN__
[foo][2]
__OUT__

# This test assumes that the output from "set -o" is always the same for the
# same option configuration.
test_OE -e 0 'set -o/+o'
set -aeu
set -o > saveset
saveset=$(set +o)
set +aeu -f
eval "$saveset"
set -o | diff saveset -
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/shift-p.tst <<'EOF'
# shift-p.tst: test of the shift built-in for any POSIX-compliant shell

posix="true"

setup -d

test_oE -e 0 'shift 0 -> 0' -es
shift 0 && bracket "$#" "$@"
__IN__
[0]
__OUT__

test_oE -e 0 'shift 1 -> 1' -es a
shift 0 && bracket "$#" "$@"
__IN__
[1][a]
__OUT__

test_oE -e 0 'shift 1 -> 0' -es a
shift 1 && bracket "$#" "$@"
__IN__
[0]
__OUT__

test_oE -e 0 'shift 2 -> 2' -es a 'b  b'
shift 0 && bracket "$#" "$@"
__IN__
[2][a][b  b]
__OUT__

test_oE -e 0 'shift 2 -> 1' -es a 'b  b'
shift 1 && bracket "$#" "$@"
__IN__
[1][b  b]
__OUT__

test_oE -e 0 'shift 2 -> 0' -es a 'b  b'
shift 2 && bracket "$#" "$@"
__IN__
[0]
__OUT__

test_oE -e 0 'shift 10 -> 3' -es a 'b  b' c d e f g '' - j
shift 7 && bracket "$#" "$@"
__IN__
[3][][-][j]
__OUT__

test_O -d -e n 'too large operand 1 for 0' -es
shift 1
__IN__

test_O -d -e n 'too large operand 2 for 1' -es a
shift 2
__IN__

test_O -d -e n 'too large operand 3 for 2' -es a 'b  b'
shift 3
__IN__

test_O -d -e n 'too large operand 100 for 10' -es a 'b  b' c d e f g '' - j
shift 100
__IN__

test_oE -e 0 'default operand is 1: success' -es a 'b  b' c
shift && bracket "$#" "$@"
shift && bracket "$#" "$@"
shift && bracket "$#" "$@"
__IN__
[2][b  b][c]
[1][c]
[0]
__OUT__

test_O -d -e n 'default operand is 1: failure' -es
shift
__IN__

test_oE -e 0 'arguments are shifted in function' -es a 'b  b' c
func() { shift; bracket "$#" "$@"; }
func x 'y  y' z
bracket "$#" "$@"
__IN__
[2][y  y][z]
[3][a][b  b][c]
__OUT__

test_oE -e 0 'separator preceding operand' -es a b c d e
shift -- 2 && bracket "$#" "$@"
__IN__
[3][c][d][e]
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont1-p.tst <<'EOF'
# sigcont1-p.tst: test of SIGCONT handling for any POSIX-compliant shell (1)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m default CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont2-p.tst <<'EOF'
# sigcont2-p.tst: test of SIGCONT handling for any POSIX-compliant shell (2)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m ignored CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont3-p.tst <<'EOF'
# sigcont3-p.tst: test of SIGCONT handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont4-p.tst <<'EOF'
# sigcont4-p.tst: test of SIGCONT handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont5-p.tst <<'EOF'
# sigcont5-p.tst: test of SIGCONT handling for any POSIX-compliant shell (5)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m default CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont6-p.tst <<'EOF'
# sigcont6-p.tst: test of SIGCONT handling for any POSIX-compliant shell (6)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m ignored CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont7-p.tst <<'EOF'
# sigcont7-p.tst: test of SIGCONT handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigcont8-p.tst <<'EOF'
# sigcont8-p.tst: test of SIGCONT handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored CONT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup1-p.tst <<'EOF'
# sighup1-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (1)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m default \
    HUP PIPE USR1 USR2 PIPE USR1 USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup2-p.tst <<'EOF'
# sighup2-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (2)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m ignored \
    PIPE USR1 USR2 PIPE USR1 USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup3-p.tst <<'EOF'
# sighup3-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default \
    USR1 USR2 PIPE USR1 USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP PIPE

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup4-p.tst <<'EOF'
# sighup4-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored \
    USR2 PIPE USR1 USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP PIPE USR1

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup5-p.tst <<'EOF'
# sighup5-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (5)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m default \
    PIPE USR1 USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP PIPE USR1 USR2

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup6-p.tst <<'EOF'
# sighup6-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (6)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m ignored \
    USR1 USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP PIPE USR1 USR2 PIPE

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup7-p.tst <<'EOF'
# sighup7-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default \
    USR2 HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP PIPE USR1 USR2 PIPE USR1

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sighup8-p.tst <<'EOF'
# sighup8-p.tst: test of SIGHUP (etc.) handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored \
    HUP USR1 USR2 HUP PIPE USR2 HUP PIPE USR1 HUP PIPE USR1 USR2 PIPE USR1 USR2

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint1-p.tst <<'EOF'
# sigint1-p.tst: test of SIGINT handling for any POSIX-compliant shell (1)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m default INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint2-p.tst <<'EOF'
# sigint2-p.tst: test of SIGINT handling for any POSIX-compliant shell (2)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m ignored INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint3-p.tst <<'EOF'
# sigint3-p.tst: test of SIGINT handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint4-p.tst <<'EOF'
# sigint4-p.tst: test of SIGINT handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint5-p.tst <<'EOF'
# sigint5-p.tst: test of SIGINT handling for any POSIX-compliant shell (5)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m default INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint6-p.tst <<'EOF'
# sigint6-p.tst: test of SIGINT handling for any POSIX-compliant shell (6)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m ignored INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint7-p.tst <<'EOF'
# sigint7-p.tst: test of SIGINT handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigint8-p.tst <<'EOF'
# sigint8-p.tst: test of SIGINT handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored INT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit1-p.tst <<'EOF'
# sigquit1-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (1)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m default QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit2-p.tst <<'EOF'
# sigquit2-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (2)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m ignored QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit3-p.tst <<'EOF'
# sigquit3-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit4-p.tst <<'EOF'
# sigquit4-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit5-p.tst <<'EOF'
# sigquit5-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (5)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m default QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit6-p.tst <<'EOF'
# sigquit6-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (6)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m ignored QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit7-p.tst <<'EOF'
# sigquit7-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigquit8-p.tst <<'EOF'
# sigquit1-p.tst: test of SIGQUIT handling for any POSIX-compliant shell (1)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored QUIT

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigstop3-p.tst <<'EOF'
# sigstop3-p.tst: test of SIGSTOP handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default STOP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigstop7-p.tst <<'EOF'
# sigstop7-p.tst: test of SIGSTOP handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default STOP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm1-p.tst <<'EOF'
# sigterm1-p.tst: test of SIGTERM handling for any POSIX-compliant shell (1)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m default TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm2-p.tst <<'EOF'
# sigterm2-p.tst: test of SIGTERM handling for any POSIX-compliant shell (2)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m ignored TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm3-p.tst <<'EOF'
# sigterm3-p.tst: test of SIGTERM handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm4-p.tst <<'EOF'
# sigterm4-p.tst: test of SIGTERM handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm5-p.tst <<'EOF'
# sigterm5-p.tst: test of SIGTERM handling for any POSIX-compliant shell (5)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m default TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm6-p.tst <<'EOF'
# sigterm6-p.tst: test of SIGTERM handling for any POSIX-compliant shell (6)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m ignored TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm7-p.tst <<'EOF'
# sigterm7-p.tst: test of SIGTERM handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigterm8-p.tst <<'EOF'
# sigterm8-p.tst: test of SIGTERM handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored TERM

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigtstp3-p.tst <<'EOF'
# sigtstp3-p.tst: test of SIGTSTP handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default TSTP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigtstp4-p.tst <<'EOF'
# sigtstp4-p.tst: test of SIGTSTP handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored TSTP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigtstp7-p.tst <<'EOF'
# sigtstp7-p.tst: test of SIGTSTP handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default TSTP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigtstp8-p.tst <<'EOF'
# sigtstp8-p.tst: test of SIGTSTP handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored TSTP

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttin3-p.tst <<'EOF'
# sigttin3-p.tst: test of SIGTTIN handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default TTIN

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttin4-p.tst <<'EOF'
# sigttin4-p.tst: test of SIGTTIN handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored TTIN

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttin7-p.tst <<'EOF'
# sigttin7-p.tst: test of SIGTTIN handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default TTIN

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttin8-p.tst <<'EOF'
# sigttin8-p.tst: test of SIGTTIN handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored TTIN

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttou3-p.tst <<'EOF'
# sigttou3-p.tst: test of SIGTTOU handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default TTOU

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttou4-p.tst <<'EOF'
# sigttou4-p.tst: test of SIGTTOU handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored TTOU

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttou7-p.tst <<'EOF'
# sigttou7-p.tst: test of SIGTTOU handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default TTOU

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigttou8-p.tst <<'EOF'
# sigttou8-p.tst: test of SIGTTOU handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"
if "$use_valgrind"; then
    skip="true"
fi

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored TTOU

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg1-p.tst <<'EOF'
# sigurg1-p.tst: test of SIGURG handling for any POSIX-compliant shell (1)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m default URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg2-p.tst <<'EOF'
# sigurg2-p.tst: test of SIGURG handling for any POSIX-compliant shell (2)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i +m ignored URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg3-p.tst <<'EOF'
# sigurg3-p.tst: test of SIGURG handling for any POSIX-compliant shell (3)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m default URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg4-p.tst <<'EOF'
# sigurg4-p.tst: test of SIGURG handling for any POSIX-compliant shell (4)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" +i -m ignored URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg5-p.tst <<'EOF'
# sigurg5-p.tst: test of SIGURG handling for any POSIX-compliant shell (5)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m default URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg6-p.tst <<'EOF'
# sigurg6-p.tst: test of SIGURG handling for any POSIX-compliant shell (6)

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i +m ignored URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg7-p.tst <<'EOF'
# sigurg7-p.tst: test of SIGURG handling for any POSIX-compliant shell (7)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m default URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/sigurg8-p.tst <<'EOF'
# sigurg8-p.tst: test of SIGURG handling for any POSIX-compliant shell (8)
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

. ../signal.sh

signal_action_test_combo "$LINENO" -i -m ignored URG

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/simple-p.tst <<'EOF'
# simple-p.tst: test of simple commands for any POSIX-compliant shell

posix="true"

setup -d

test_x -e 11 'exit status of empty command with command substitution'
$(exit 11)
__IN__

test_oE 'command words are expanded before assignments and redirections'
unset a
a=$(echo A 3>|f1) 3>|f1 echo "$(test -f f1 || echo file does not exist $a)"
__IN__
file does not exist
__OUT__

test_OE -e 0 'redirections precedes assignments for non-special-builtin command'
rm -f f2
a=$(cat f2) 3>|$(echo f2) true
__IN__

test_oE 'single assignment'
a=
bracket "$a"
a=value
bracket "$a"
__IN__
[]
[value]
__OUT__

test_oE 'multiple assignments'
a= b=bar
c=$b d=X e=$a
bracket "$c" "$d" "$e"
__IN__
[bar][X][]
__OUT__

test_oE 'assignments are subject to expansion'
x=X
a=$x${x} b=$(echo $x)`echo $x` c=$((1+2))
bracket "$a" "$b" "$c"
__IN__
[XX][XX][3]
__OUT__
# Tilde expansion is tested in tilde-p.tst

test_oE 'quotes in assignment'
a='A"B"C' b="A'B'C" c=\'\"C\"\'
bracket "$a" "$b" "$c"
__IN__
[A"B"C][A'B'C]['"C"']
__OUT__

test_oE 'assignment is persistent for empty command'
unset a b x
a=A
b=B $x
bracket "$a" "$b"
__IN__
[A][B]
__OUT__

# Tested in builtins-p.tst
#test_oE 'assignment is persistent for special built-in'

test_oE 'assigned variable is visible inside function'
f() { echo function $a; }
a=1
a=2 f
__IN__
function 2
__OUT__

test_oE 'assignment is temporary for regular command'
a=1
a=2 echo ok
bracket "$a"
__IN__
ok
[1]
__OUT__

test_oE 'assignment is exported for regular command'
a=A sh -c 'echo $a'
__IN__
A
__OUT__

test_O -d -e n 'assigning to read-only variable: exit with message (empty)'
readonly a=A
a=B
echo not reached
__IN__

test_O -d -e n 'assigning to read-only variable: exit with message (function)'
func() { echo not reached function; }
readonly a=A
a=B func
echo not reached command
__IN__

test_O -d -e n 'assigning to read-only variable in subshell'
readonly a=A
(a=B)
__IN__

test_x -e 0 'exit status of successful assignment'
a=1
__IN__

test_x -e 0 'exit status of successful redirection'
>/dev/null
__IN__

test_x -e 0 'exit status of successful assignments and redirections'
a=1 b=2 </dev/null >/dev/null
__IN__

test_x -e 13 'exit status of assignment with command substitution'
a=$(exit 13)
__IN__

test_o 'assignment is done even if command substitution fails (+e)' +e
a=foo$(false)
bracket "$a"
__IN__
[foo]
__OUT__

test_o 'assignment is done even if command substitution fails (-e)' -e
trap 'bracket "$a"' EXIT
a=foo$(false)
echo not reached
__IN__
[foo]
__OUT__

test_x -e 17 'exit status of redirection with command substitution'
>/dev/null$(exit 17)
__IN__

test_x -e 0 'redirection is done even if command substitution fails (+e)' +e
>f11$(false)
[ -f f11 ]
__IN__

test_o 'redirection is done even if command substitution fails (-e)' -e
trap '[ -f f12 ] && echo f12 created' EXIT
>f12$(false)
__IN__
f12 created
__OUT__

test_o 'assignment-like command argument'
export foo=F
sh -c 'echo $1 $foo' X foo=bar
foo=f sh -c 'echo $1 $foo' X foo=bar
__IN__
foo=bar F
foo=bar f
__OUT__

test_o 'redirection can appear between any tokens in simple command'
</dev/null foo=bar </dev/null sh </dev/null -c 'echo $1' X </dev/null 1 </dev/null
__IN__
1
__OUT__

test_O -d -e 127 'non-intrinsic command echo is not found w/o PATH'
PATH=
echo not printed
__IN__

mkdir dir1 dir2 dir3
cat >dir2/ext_cmd <<\END
echo external
echo command
printf '[%s]\n' "$@"
END
chmod a+x dir2/ext_cmd
ln -s "$(command -v sh)" dir2/link_to_sh

test_o 'searching PATH for command'
PATH=./dir1:./dir2:./dir3:$PATH
ext_cmd argument ' 1  2 '
__IN__
external
command
[argument]
[ 1  2 ]
__OUT__

test_O -d -e 127 'command not found in PATH'
PATH=./dir3
ext_cmd
__IN__

test_O -d -e 127 'PATH is searched after assignments (ls)'
# If PATH is searched before assignments,
# this would find ls in somewhere like /bin.
PATH=./dir3 ls
__IN__

test_O -d -e 127 'PATH is searched after assignments (pwd)'
# If PATH is searched before assignments,
# this would find pwd in somewhere like /bin.
PATH=./dir3 pwd
__IN__

test_o 'command name with slash'
dir2/ext_cmd foo bar baz
__IN__
external
command
[foo]
[bar]
[baz]
__OUT__

(
# Ensure $PWD is safe to assign to $PATH
case $PWD in (*[:%]*)
    skip="true"
esac

setup - <<\__END__
mkdir "$TEST_NO.path" && cd "$TEST_NO.path"
make_command() for c do echo echo "Running $c" >"$c" && chmod a+x "$c"; done
__END__

export TEST_NO="$LINENO"
test_oE 'running command in different directory with relative path in $PATH'
mkdir a b
make_command a/command1 b/command1
PATH=.:$PATH
cd a
command1
cd ../b
command1
__IN__
Running a/command1
Running b/command1
__OUT__

export TEST_NO="$LINENO"
test_oE 'assignment to $PATH removes all remembered command paths'
mkdir a b c
PATH=$PWD/a:$PWD/b:$PWD/c:$PATH
make_command c/command1 c/command2
command1
command2
echo ---
make_command b/command1 b/command2
PATH="$PATH"
make_command a/command1 a/command2
command1
command2
__IN__
Running c/command1
Running c/command2
---
Running a/command1
Running a/command2
__OUT__

export TEST_NO="$LINENO"
test_oE 'remembered command path is ignored if command is missing'
mkdir a b
PATH=$PWD/a:$PWD/b:$PATH
make_command b/command1 b/command2
command1
command2
echo ---
make_command a/command1 a/command2; rm b/command1 b/command2
command1
command2
__IN__
Running b/command1
Running b/command2
---
Running a/command1
Running a/command2
__OUT__

)

test_o 'argv[0] (command name without slash)'
sh -c 'echo "$0"'
PATH=./dir2:$PATH
link_to_sh -c 'echo "$0"'
__IN__
sh
link_to_sh
__OUT__

testcase "$LINENO" 'argv[0] (command name with slash)' \
    3<<\__IN__ 4<<__OUT__ 5<&-
"$(command -v sh)" -c 'echo "$0"'
./dir2/link_to_sh -c 'echo "$0"'
__IN__
$(command -v sh)
./dir2/link_to_sh
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/startup-p.tst <<'EOF'
# startup-p.tst: test of shell startup for any POSIX-compliant shell

test_O -e 17 'one operand with -c' -c 'exit 17'
__IN__

test_o -e 0 'two operands with -c' \
    -c 'printf "[%s]\n" "$0" "$@"' 'command  name'
__IN__
[command  name]
__OUT__

test_o -e 0 'one positional parameter with -c' \
    -c 'printf "[%s]\n" "$0" "$@"' 0 1
__IN__
[0]
[1]
__OUT__

test_o -e 0 'many positional parameters with -c' \
    -c 'printf "[%s]\n" "$0" "$@"' 0 1 '2  2' 3 4 - 6 7 8 9 10 11
__IN__
[0]
[1]
[2  2]
[3]
[4]
[-]
[6]
[7]
[8]
[9]
[10]
[11]
__OUT__

test_oE -e 0 'stdin is not used with -c' -c 'cat'
printed text
__IN__
printed text
__OUT__

test_oE -e 19 'no operands with -s' -s
echo $#
exit 19
__IN__
0
__OUT__

test_oE -e 23 'one operand with -s' -s '1  1'
printf "[%s]\n" "$@"
exit 23
__IN__
[1  1]
__OUT__

test_oE 'two operands with -s' -s '1  1' 2
printf "[%s]\n" "$@"
__IN__
[1  1]
[2]
__OUT__

test_oE 'many operands with -s' -s '1  1' 2 3 4 - 6 7 8 9 10 11
printf "[%s]\n" "$@"
__IN__
[1  1]
[2]
[3]
[4]
[-]
[6]
[7]
[8]
[9]
[10]
[11]
__OUT__

testcase "$LINENO" '$0 with -s' -s X 3<<\__IN__ 4<<__OUT__ 5<&-
printf '[%s]\n' "$0"
__IN__
[$TESTEE]
__OUT__

(
input=./input$LINENO
cat >"$input" <<\__END__
echo input "$*"
cat
exit 3
echo not reached
__END__

test_oE -e 3 'reading file w/o positional parameters' "$input"
stdin
__IN__
input 
stdin
__OUT__

test_oE -e 3 'reading file with one positional parameter' "$input" '1  1'
stdin
__IN__
input 1  1
stdin
__OUT__

test_oE -e 3 'reading file with many positional parameters' \
    "$input" '1  1' 2 3 4 - 6 7 8 9 10 11
stdin
__IN__
input 1  1 2 3 4 - 6 7 8 9 10 11
stdin
__OUT__

)

test_O -d -e 127 'reading non-existing file' ./_no_such_file_
__IN__

(
input=input$LINENO
>"$input"
chmod a-r "$input"

# Skip if we're root.
if { <"$input"; } 2>/dev/null; then
    skip="true"
fi

test_O -d -e n 'reading non-readable file' "$input"
__IN__

)

test_o -d 'all short options' -abCefsuvx +mn
case $- in (*a*)
    case $- in (*b*)
        case $- in (*C*)
            case $- in (*e*)
                case $- in (*f*)
                    case $- in (*u*)
                        case $- in (*v*)
                            case $- in (*x*)
                                echo OK
                            esac
                        esac
                    esac
                esac
            esac
        esac
    esac
esac
__IN__
OK
__OUT__

test_oE 'first operand is ignored if it is a hyphen (-c)' -c - 'echo OK'
__IN__
OK
__OUT__

test_oE 'first operand is ignored if it is a hyphen (no -c or -s)' -
echo OK
__IN__
OK
__OUT__

test_oE 'first operand is ignored if it is a double-hyphen (-c)' -c -- 'echo OK'
__IN__
OK
__OUT__

test_oE 'first operand is ignored if it is a double-hyphen (no -c or -s)' --
echo OK
__IN__
OK
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/test-p.tst <<'EOF'
# test-p.tst: test of the test built-in for any POSIX-compliant shell

posix="true"

# This file is for testing the shell built-in, so we should skip the tests
# if the shell does not seem to implement the test built-in.
case $("$TESTEE" -c 'command -V test') in
    (*built-in*|*builtin*)
        # Okay, the testee seems to support the test command as a built-in.
        # This check is not POSIXly portable because the output of "command -V"
        # is unspecified in POSIX, but it works for yash and most other shells.
        ;;
    (*)
        skip=true
        ;;
esac

umask u=rwx,go=

>file
(umask a-r && >unreadable)
(umask a-w && >unwritable)
(umask a-x && >unexecutable)
>executable
chmod u+x executable

echo >oneline
echo foo >nonempty

mkdir dir setgroupid setuserid
chmod ug-s dir
chmod g+s setgroupid
chmod u+s setuserid

mkfifo fifo

ln file hardlink
ln -s file filelink
ln -s _no_such_file_ brokenlink
ln -s unreadable unreadablelink
ln -s unwritable unwritablelink
ln -s unexecutable unexecutableln
ln -s executable executablelink
ln -s oneline onelinelink
ln -s nonempty nonemptylink
ln -s dir dirlink
ln -s setgroupid setgroupidlink
ln -s setuserid setuseridlink
ln -s fifo fifolink

touch -t 200001010000 older
touch -t 200101010000 newer
touch -a -t 200101010000 old; touch -m -t 200001010000 old
touch -a -t 200001010000 new; touch -m -t 200101010000 new

# $1 = $LINENO, $2 = expected exit status, $3... = expression
assert() (
    setup <<\__END__
    test "$@"
    result_test=$?
    [ "$@" ]
    result_bracket=$?
    case "$result_test" in ("$result_bracket")
        exit "$result_bracket"
    esac
    printf 'result_test=%d result_bracket=%d\n' "$result_test" "$result_bracket"
    exit 100
__END__

    lineno="$1"
    expected_exit_status="$2"
    shift 2
    testcase "$lineno" -e "$expected_exit_status" "test $*" -s -- "$@" \
        3</dev/null 4<&3 5<&3
)

alias assert_true='assert "$LINENO" 0'
alias assert_false='assert "$LINENO" 1'

assert_false

assert_false ''
assert_true -
assert_true --
assert_true A
assert_true X
assert_true ABC
assert_true xyz

(
block_file="$(find /dev -type b 2>/dev/null | head -n 1)"
if [ -e "$block_file" ]; then
    ln -s "$block_file" blocklink
else
    skip="true"
fi

assert_true -b
assert_true -b "$block_file"
assert_true -b blocklink
assert_false -b dir
assert_false -b dirlink
assert_false -b ./_no_such_file_
assert_false -b brokenlink
)

(
character_file="$(find /dev/tty /dev -type c 2>/dev/null | head -n 1)"
if [ -e "$character_file" ]; then
    ln -s "$character_file" characterlink
else
    skip="true"
fi

assert_true -c
assert_true -c "$character_file"
assert_true -c characterlink
assert_false -c dir
assert_false -c dirlink
assert_false -c ./_no_such_file_
assert_false -c brokenlink
)

assert_true -d
assert_true -d .
assert_true -d ..
assert_true -d dir
assert_true -d /dev
assert_true -d dirlink
assert_false -d file
assert_false -d filelink
assert_false -d ./_no_such_file_
assert_false -d brokenlink

assert_true -e
assert_true -e .
assert_true -e ..
assert_true -e dir
assert_true -e dirlink
assert_true -e file
assert_true -e filelink
assert_true -e /dev/null
assert_false -e ./_no_such_file_
assert_false -e brokenlink

assert_true -f
assert_true -f file
assert_true -f filelink
assert_false -f dir
assert_false -f dirlink
assert_false -f ./_no_such_file_
assert_false -f brokenlink

assert_true -g
assert_true -g setgroupid
assert_true -g setgroupidlink
assert_false -g dir
assert_false -g dirlink
assert_false -g file
assert_false -g filelink
assert_false -g ./_no_such_file_
assert_false -g brokenlink

assert_true -h
assert_true -h filelink
assert_true -h brokenlink
assert_false -h dir
assert_false -h file
assert_false -h ./_no_such_file_

assert_true -L
assert_true -L filelink
assert_true -L brokenlink
assert_false -L dir
assert_false -L file
assert_false -L ./_no_such_file_

assert_true -n
assert_false -n ''
assert_true -n .
assert_true -n ..
assert_true -n ...
assert_true -n A
assert_true -n xyz

assert_true -p
assert_true -p fifo
assert_true -p fifolink
assert_false -p dir
assert_false -p dirlink
assert_false -p file
assert_false -p filelink
assert_false -p ./_no_such_file_
assert_false -p brokenlink

assert_true -r
assert_true -r file
assert_true -r filelink
(
if [ -r unreadable ]; then
    skip="true"
fi
assert_false -r unreadable
)
(
if [ -r unreadablelink ]; then
    skip="true"
fi
assert_false -r unreadablelink
)
assert_true -r dir
assert_true -r dirlink
assert_false -r ./_no_such_file_
assert_false -r brokenlink

assert_true -S
# Tests for the -S operator is missing
assert_false -S file
assert_false -S filelink
assert_false -S dir
assert_false -S dirlink
assert_false -S ./_no_such_file_
assert_false -S brokenlink

assert_true -s
assert_true -s oneline
assert_true -s onelinelink
assert_true -s nonempty
assert_true -s nonemptylink
assert_false -s file
assert_false -s filelink
assert_false -s ./_no_such_file_
assert_false -s brokenlink

assert_true -t
# Other tests for the -t operator are in testtty-p.tst.

assert_true -u
assert_true -u setuserid
assert_true -u setuseridlink
assert_false -u file
assert_false -u filelink
assert_false -u dir
assert_false -u dirlink
assert_false -u ./_no_such_file_
assert_false -u brokenlink

assert_true -w
assert_true -w file
assert_true -w filelink
(
if [ -w unwritable ]; then
    skip="true"
fi
assert_false -w unwritable
)
(
if [ -w unwritablelink ]; then
    skip="true"
fi
assert_false -w unwritablelink
)
assert_true -w dir
assert_true -w dirlink
assert_false -w ./_no_such_file_
assert_false -w brokenlink

assert_true -x
assert_true -x executable
assert_true -x executablelink
(
if [ -x unexecutable ]; then
    skip="true"
fi
assert_false -x unexecutable
)
(
if [ -x unexecutableln ]; then
    skip="true"
fi
assert_false -x unexecutableln
)
assert_true -x dir
assert_true -x dirlink
assert_false -x ./_no_such_file_
assert_false -x brokenlink

assert_true -z
assert_true -z ''
assert_false -z .
assert_false -z ..
assert_false -z ...
assert_false -z A
assert_false -z xyz

assert_true "" = ""
assert_true 1 = 1
assert_true abcde = abcde
assert_false 0 = 1
assert_false abcde = 12345
assert_true ! = !
assert_true = = =
assert_false "(" = ")"

assert_false "" != ""
assert_false 1 != 1
assert_false abcde != abcde
assert_true 0 != 1
assert_true abcde != 12345
assert_false ! != !
assert_false != != !=
assert_true "(" != ")"

assert_true -3 -eq -3
assert_true 90 -eq 90
assert_true 0 -eq 0
assert_false -3 -eq 90
assert_false -3 -eq 0
assert_false 90 -eq 0

assert_false -3 -ne -3
assert_false 90 -ne 90
assert_false 0 -ne 0
assert_true -3 -ne 90
assert_true -3 -ne 0
assert_true 90 -ne 0

assert_false -3 -gt -3
assert_false -3 -gt 0
assert_false 0 -gt 90
assert_true 0 -gt -3
assert_true 90 -gt -3
assert_false 0 -gt 0

assert_true -3 -ge -3
assert_false -3 -ge 0
assert_false 0 -ge 90
assert_true 0 -ge -3
assert_true 90 -ge -3
assert_true 0 -ge 0

assert_false -3 -lt -3
assert_true -3 -lt 0
assert_true 0 -lt 90
assert_false 0 -lt -3
assert_false 90 -lt -3
assert_false 0 -lt 0

assert_true -3 -le -3
assert_true -3 -le 0
assert_true 0 -le 90
assert_false 0 -le -3
assert_false 90 -le -3
assert_true 0 -le 0

# The behavior of the < and > operators cannot be fully tested.
assert_false 11 '<' 100
assert_false 11 '<' 11
assert_true 100 '<' 11

assert_true 11 '>' 100
assert_false 11 '>' 11
assert_false 100 '>' 11

assert_true XXXXX -ot newer
assert_false XXXXX -ot XXXXX
assert_false newer -ot XXXXX
assert_true older -ot newer
assert_false newer -ot newer
assert_false newer -ot older

assert_false XXXXX -nt newer
assert_false XXXXX -nt XXXXX
assert_true newer -nt XXXXX
assert_false older -nt newer
assert_false older -nt older
assert_true newer -nt older

assert_false XXXXX -ef newer
assert_false XXXXX -ef XXXXX
assert_false newer -ef XXXXX
assert_false older -ef newer
assert_true older -ef older
assert_false newer -ef older
assert_true file -ef hardlink
assert_false file -ef newer

assert_true !
assert_true ! ''
assert_false ! A
assert_false ! X
assert_false ! ABC
assert_false ! xyz
assert_false ! -f file
assert_true ! -f dir
assert_true ! -d file
assert_false ! -d dir
assert_true ! -n ''
assert_false ! -n .
assert_false ! a = a # ! ( a = a )
assert_false ! ! -n ""
assert_true ! ! -n 1
assert_true ! ! ! ""
assert_false ! ! ! 1

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/testtty-p.tst <<'EOF'
# testtty-p.tst: test of the test built-in for any POSIX-compliant shell
../checkfg || skip="true" # %REQUIRETTY%

if ! testee -c 'command -bv test' >/dev/null; then
    skip="true"
fi

posix="true"

test_OE -e 1 'unary -t: empty operand'
test -t ''
__IN__

test_OE -e 1 'unary -t: non-numeric operand'
test -t x
__IN__

test_OE -e 1 'unary -t: negative operand'
test -t -10
__IN__

test_OE -e 1 'unary -t: closed file descriptor 0'
test -t 0 0>&-
__IN__

test_OE -e 1 'unary -t: non-tty file descriptor 0'
test -t 0 0</dev/null
__IN__

test_OE -e 0 'unary -t: tty file descriptor 0'
test -t 0 0<>/dev/tty
__IN__

test_OE -e 1 'unary -t: closed file descriptor 5'
test -t 5 5>&-
__IN__

test_OE -e 1 'unary -t: non-tty file descriptor 5'
test -t 5 5</dev/null
__IN__

test_OE -e 0 'unary -t: tty file descriptor 5'
test -t 5 5<>/dev/tty
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/tilde-p.tst <<'EOF'
# tilde-p.tst: test of tilde expansion for any POSIX-compliant shell

posix="true"
setup -d

(
setup 'HOME=/foo/bar'

test_oE 'quoted tilde is not expanded (in command word)'
bracket \~ '~' "~" ~\/
__IN__
[~][~][~][~/]
__OUT__

test_oE 'unnamed tilde expansion, end of word'
bracket ~
HOME=/tilde/expansion
bracket ~
__IN__
[/foo/bar]
[/tilde/expansion]
__OUT__

test_oE 'unnamed tilde expansion, followed by slash'
bracket ~/ ~/baz
HOME=/tilde/expansion
bracket ~/ ~/slash
__IN__
[/foo/bar/][/foo/bar/baz]
[/tilde/expansion/][/tilde/expansion/slash]
__OUT__

test_OE -e 0 'exit status of successful unnamed tilde expansion (in command word)'
: ~ ~/ ~/foo
__IN__

test_oE 'quoted tilde is not expanded in assignment'
a=\~ b='~' c="~" d=~\/
bracket "$a" "$b" "$c" "$d"
__IN__
[~][~][~][~/]
__OUT__

test_oE 'unnamed tilde expansion in assignment, end of word'
a=~
HOME=/tilde/expansion
b=~
bracket "$a" "$b"
__IN__
[/foo/bar][/tilde/expansion]
__OUT__

test_oE 'unnamed tilde expansion in assignment, followed by slash'
a=~/ b=~/baz
HOME=/tilde/expansion
c=~/ d=~/slash
bracket "$a" "$b" "$c" "$d"
__IN__
[/foo/bar/][/foo/bar/baz][/tilde/expansion/][/tilde/expansion/slash]
__OUT__

test_oE 'unnamed tilde expansion in assignment, followed by colon'
a=~: b=~:baz
HOME=/tilde/expansion
c=~: d=~:colon
bracket "$a" "$b" "$c" "$d"
__IN__
[/foo/bar:][/foo/bar:baz][/tilde/expansion:][/tilde/expansion:colon]
__OUT__

test_oE -e 0 'unnamed tilde expansion in assignment, following colon'
a=:~ b=baz:~
HOME=/tilde/expansion
c=:~ d=colon:~
bracket "$a" "$b" "$c" "$d"
__IN__
[:/foo/bar][baz:/foo/bar][:/tilde/expansion][colon:/tilde/expansion]
__OUT__

test_oE -e 0 'unnamed tilde expansion in assignment, between colon'
a=:~: b=baz:~:baz
HOME=/tilde/expansion
c=:~: d=colon:~:colon
bracket "$a" "$b" "$c" "$d"
__IN__
[:/foo/bar:][baz:/foo/bar:baz][:/tilde/expansion:][colon:/tilde/expansion:colon]
__OUT__

test_oE -e 0 'many unnamed tilde expansions in assignment'
a=~:x:~/y:~:~
bracket "$a"
__IN__
[/foo/bar:x:/foo/bar/y:/foo/bar:/foo/bar]
__OUT__

test_OE -e 0 'exit status of successful unnamed tilde expansion in assignment'
a=~:x:~/y:~:~
__IN__

)

test_oE -e 0 'empty HOME'
HOME=
bracket ~
__IN__
[]
__OUT__

test_oE -e 0 'HOME with trailing slash'
HOME=/foo/bar/
bracket ~ ~/~
__IN__
[/foo/bar/][/foo/bar/~]
__OUT__

test_oE -e 0 'HOME=/'
HOME=/
bracket ~ ~/foo
__IN__
[/][/foo]
__OUT__

test_oE -e 0 'HOME=//'
HOME=//
bracket ~ ~/foo
__IN__
[//][//foo]
__OUT__

(
if
    logname=$(logname)
    if [ "$logname" ]; then LOGNAME=$logname; fi
    unset logname
    ! { [ "${LOGNAME-}" ] && export LOGNAME; }
then
    skip="true"
elif
    # The current user's name has to be portable.
    printf '%s\n' "$LOGNAME" | \
        grep -q '[^0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]'
then
    skip="true"
elif
    # Tests of named tilde expansions depend on the home directory of the
    # current user.
    ! { HOME="$(eval printf \'%s\\\n\' \~$LOGNAME)" &&
        export HOME &&
        [ "$HOME" ]; }
then
    skip="true"
fi

if "${skip:-false}"; then
    LOGNAME= HOME=
fi

testcase "$LINENO" 'tilde with quoted name is not expanded (in command word)' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
bracket ~\\$LOGNAME ~"$LOGNAME" ~'$LOGNAME' ~$LOGNAME\\/
__IN__
[~$LOGNAME][~$LOGNAME][~$LOGNAME][~$LOGNAME/]
__OUT__

testcase "$LINENO" 'named tilde expansion, end of word' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
bracket ~$LOGNAME
__IN__
[$HOME]
__OUT__

testcase "$LINENO" 'named tilde expansion, followed by slash' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
bracket ~$LOGNAME/ ~$LOGNAME/foo
__IN__
[$HOME/][$HOME/foo]
__OUT__

testcase "$LINENO" -e 0 \
    'exit status of successful named tilde expansion (in command word)' \
    3<<__IN__ 4</dev/null 5</dev/null
: ~$LOGNAME ~$LOGNAME/ ~$LOGNAME/foo
__IN__

testcase "$LINENO" 'tilde with quoted name is not expanded in assignment' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=~\\$LOGNAME b=~"$LOGNAME" c=~'$LOGNAME' d=~$LOGNAME\\/
bracket "\$a" "\$b" "\$c" "\$d"
__IN__
[~$LOGNAME][~$LOGNAME][~$LOGNAME][~$LOGNAME/]
__OUT__

testcase "$LINENO" 'named tilde expansion in assignment, end of word' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=~$LOGNAME
bracket "\$a"
__IN__
[$HOME]
__OUT__

testcase "$LINENO" 'named tilde expansion in assignment, followed by slash' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=~$LOGNAME/ b=~$LOGNAME/foo
bracket "\$a" "\$b"
__IN__
[$HOME/][$HOME/foo]
__OUT__

testcase "$LINENO" 'named tilde expansion in assignment, followed by colon' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=~$LOGNAME: b=~$LOGNAME:foo
bracket "\$a" "\$b"
__IN__
[$HOME:][$HOME:foo]
__OUT__

testcase "$LINENO" 'named tilde expansion in assignment, following colon' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=:~$LOGNAME b=foo:~$LOGNAME
bracket "\$a" "\$b"
__IN__
[:$HOME][foo:$HOME]
__OUT__

testcase "$LINENO" 'named tilde expansion in assignment, between colon' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=:~$LOGNAME: b=foo:~$LOGNAME:bar
bracket "\$a" "\$b"
__IN__
[:$HOME:][foo:$HOME:bar]
__OUT__

testcase "$LINENO" 'many named tilde expansions in assignment' \
    3<<__IN__ 4<<__OUT__ 5</dev/null
a=~$LOGNAME:x:~$LOGNAME/y:~$LOGNAME:~$LOGNAME
bracket "\$a"
__IN__
[$HOME:x:$HOME/y:$HOME:$HOME]
__OUT__

testcase "$LINENO" -e 0 \
    'exit status of successful named tilde expansion in assignment' \
    3<<__IN__ 4</dev/null 5</dev/null
a=~$LOGNAME:x:~$LOGNAME/y:~$LOGNAME:~$LOGNAME
__IN__

)

test_oE 'result of tilde expansion is not subject to field splitting'
HOME='/path/with  space'
bracket ~
__IN__
[/path/with  space]
__OUT__

test_oE 'result of tilde expansion is not subject to parameter expansion'
HOME='$x' x='X'
bracket ~
__IN__
[$x]
__OUT__

test_oE 'result of tilde expansion is not subject to command substitution'
HOME='$(echo X)`echo Y`'
bracket ~
__IN__
[$(echo X)`echo Y`]
__OUT__

test_oE 'result of tilde expansion is not subject to arithmetic expansion'
HOME='$((1+1))'
bracket ~
__IN__
[$((1+1))]
__OUT__

test_oE 'result of tilde expansion is not subject to pathname expansion'
HOME='*'
bracket ~
__IN__
[*]
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/trap-p.tst <<'EOF'
# trap-p.tst: test of the trap built-in for any POSIX-compliant shell

posix="true"

macos_kill_workaround

test_OE -e USR1 'setting default trap'
trap - USR1
kill -s USR1 $$
__IN__

test_OE -e 0 'setting ignore trap'
trap '' USR1
kill -s USR1 $$
(kill -s USR1 $$)
__IN__

test_oE -e 0 'setting command trap'
trap 'echo trap; echo executed' USR1
kill -s USR1 $$
__IN__
trap
executed
__OUT__

test_OE -e USR1 'resetting to default trap'
trap '' USR1
trap - USR1
kill -s USR1 $$
__IN__

test_oE -e 0 'specifying multiple signals'
trap 'echo trapped' USR1 USR2
kill -s USR1 $$
kill -s USR2 $$
__IN__
trapped
trapped
__OUT__

# $1 = $LINENO, $2 = signal number, $3 = signal name w/o SIG-prefix
test_specifying_signal_by_number() {
    testcase "$1" -e 0 "specifying signal by number ($3)" \
        3<<__IN__ 4<<__OUT__ 5</dev/null
trap 'echo trapped' $2
kill -s $3 \$\$
__IN__
trapped
__OUT__
}

test_specifying_signal_by_number "$LINENO" 1  HUP
test_specifying_signal_by_number "$LINENO" 2  INT
test_specifying_signal_by_number "$LINENO" 3  QUIT
test_specifying_signal_by_number "$LINENO" 6  ABRT
#test_specifying_signal_by_number "$LINENO" 9  KILL
test_specifying_signal_by_number "$LINENO" 14 ALRM
test_specifying_signal_by_number "$LINENO" 15 TERM

test_OE -e INT 'initial numeric operand implies default trap (first operand)'
trap 'echo trapped' 2 QUIT
trap 2 QUIT
kill -s INT $$
__IN__

test_OE -e QUIT 'initial numeric operand implies default trap (second operand)'
trap 'echo trapped' 2 QUIT
trap 2 QUIT
kill -s QUIT $$
__IN__

test_oE -e 0 'setting trap for EXIT (EOF)'
trap 'echo trapped; false' EXIT
echo exiting
__IN__
exiting
trapped
__OUT__

test_oE -e 7 'setting trap for EXIT (exit built-in)'
trap 'echo trapped; (exit 9)' EXIT
exit 7
__IN__
trapped
__OUT__

test_oE -e 0 'exit status of succeeding subshell in signal trap'
trap '(true) && echo ok' INT; kill -s INT $$
__IN__
ok
__OUT__

test_oE -e 0 'exit status of failing subshell in signal trap'
trap '(false) || echo ok' INT; kill -s INT $$
__IN__
ok
__OUT__

test_oE -e n 'exit status of succeeding subshell in EXIT'
trap '(true) && echo ok' EXIT
false
__IN__
ok
__OUT__

test_oE -e 0 'exit status of failing subshell in EXIT'
trap '(false) || echo ok' EXIT
__IN__
ok
__OUT__

test_O -e n 'fatal shell error in signal trap'
trap 'set <_no_such_file_' INT
kill -s INT $$
echo not reached
__IN__

test_O -e n 'fatal shell error in EXIT trap'
trap 'set <_no_such_file_' EXIT
__IN__

test_oE -e 0 '$? is restored after signal trap is executed'
trap 'false' USR1
kill -s USR1 $$
echo $?
__IN__
0
__OUT__

test_E -e 0 'exit status of EXIT trap does not affect exit status of shell'
trap 'false' EXIT
__IN__

test_oE 'trap command is not affected by assignment in same simple command' \
    -c 'foo=1 trap "echo EXIT \$foo" EXIT; foo=2; foo=3 echo $foo'
__IN__
2
EXIT 2
__OUT__

test_oE 'trap command is not affected by assignment for calling function' \
    -c 'f() { echo $foo; }; foo=1 trap "echo EXIT \$foo" EXIT; foo=2; foo=3 f'
__IN__
3
EXIT 2
__OUT__

test_oE 'trap command is not affected by redirections effective when set (1)' \
    -c 'trap "echo foo" EXIT >/dev/null'
__IN__
foo
__OUT__

test_oE 'trap command is not affected by redirections effective when set (2)' \
    -c '{ trap "echo foo" EXIT; } >/dev/null'
__IN__
foo
__OUT__

test_oE 'trap command is not affected by redirections effective when set (3)' \
    -c 'f() { eval "trap \"echo foo\" EXIT"; }; f >/dev/null'
__IN__
foo
__OUT__

test_oE 'trap command is not affected by redirections effective when set (4)' \
    -c 'trap "echo foo" EXIT >/dev/null & wait $!'
__IN__
foo
__OUT__

test_OE 'trap command in subshell is affected by outer redirections' \
    -c '(trap "echo foo" EXIT) >/dev/null'
__IN__

test_oE 'command is evaluated each time trap is executed'
trap X USR1
alias X='echo 1'
kill -s USR1 $$
alias X='echo 2'
kill -s USR1 $$
__IN__
1
2
__OUT__

test_oE 'traps are not handled until foreground job finishes'
trap 'echo trapped' USR1
(
    kill -s USR1 $$
    echo signal sent
)
__IN__
signal sent
trapped
__OUT__

test_oE -e 0 'single trap may be invoked more than once'
trap 'echo trapped' USR1
kill -s USR1 $$
(kill -s USR1 $$)
kill -s USR1 $$
__IN__
trapped
trapped
trapped
__OUT__

test_oE -e 0 'setting new trap in trap'
trap 'trap "echo trapped 2" USR1; echo trapped 1' USR1
kill -s USR1 $$
kill -s USR1 $$
__IN__
trapped 1
trapped 2
__OUT__

test_oE -e 0 'setting new EXIT in subshell in EXIT'
trap '(trap "echo exit" EXIT)' EXIT
__IN__
exit
__OUT__

test_oE -e 0 'printing traps' -e
trap 'echo "a"'"'b'"'\c' USR1
trap >printed_trap
trap - USR1
. ./printed_trap
kill -s USR1 $$
__IN__
abc
__OUT__

test_oE -e 0 'traps are printed even in command substitution' -e
trap 'echo "a"'"'b'"'\c' USR1
printed_trap="$(trap)"
trap - USR1
eval "$printed_trap"
kill -s USR1 $$
__IN__
abc
__OUT__

test_oE -e 0 'without -p, only non-default traps are printed' -e
trap - USR1
trap >printed_trap_1 # should not print USR1
trap 'echo trapped' USR1
. ./printed_trap_1
kill -s USR1 $$
__IN__
trapped
__OUT__

test_OE -e USR1 'with -p, all traps are printed' -e
trap - USR1
trap -p >printed_trap_2 # should print USR1
trap 'echo trapped' USR1
. ./printed_trap_2
kill -s USR1 $$
__IN__

test_oE -e QUIT 'with -p and operands, only specified traps are printed' -e
trap '' INT TERM
trap -p TERM QUIT >printed_trap_3 # should not print INT
trap 'echo INT' INT
trap 'echo TERM' TERM
trap '' QUIT
. ./printed_trap_3 # TERM is ignored again, QUIT is now default
kill -s INT $$ # should print INT
kill -s TERM $$ # should be ignored
kill -s QUIT $$
__IN__
INT
__OUT__

echo 'echo "$@"' > ./-
chmod a+x ./-

test_oE 'setting command trap that starts with hyphen'
PATH=.:$PATH
trap -- '- trapped' USR1
kill -s USR1 $$
__IN__
trapped
__OUT__

test_o -d 'invalid signal does not kill non-interactive shell'
trap '' '' || echo reached
__IN__
reached
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/umask-p.tst <<'EOF'
# umask-p.tst: test of the umask built-in for any POSIX-compliant shell

posix="true"

# $1 = $LINENO, $2 = umask
test_restore_non_symbolic() {
    testcase "$1" -e 0 \
        "restoring umask using previous output, non-symbolic, $2" \
        3<<\__IN__ 4</dev/null 5<&4
mask=$(umask)
umask 777
umask "$mask"
test "$mask" = "$(umask)"
__IN__
}

test_restore_non_symbolic "$LINENO" 000
test_restore_non_symbolic "$LINENO" 001
test_restore_non_symbolic "$LINENO" 002
test_restore_non_symbolic "$LINENO" 004
test_restore_non_symbolic "$LINENO" 010
test_restore_non_symbolic "$LINENO" 020
test_restore_non_symbolic "$LINENO" 040
test_restore_non_symbolic "$LINENO" 100
test_restore_non_symbolic "$LINENO" 200
test_restore_non_symbolic "$LINENO" 400
test_restore_non_symbolic "$LINENO" 653
test_restore_non_symbolic "$LINENO" 017

# $1 = $LINENO, $2 = umask
test_restore_symbolic() {
    testcase "$1" -e 0 \
        "restoring umask using previous output, symbolic, $2" \
        3<<\__IN__ 4</dev/null 5<&4
mask=$(umask -S)
umask 777
umask "$mask"
test "$mask" = "$(umask -S)"
__IN__
}

test_restore_symbolic "$LINENO" 000
test_restore_symbolic "$LINENO" 001
test_restore_symbolic "$LINENO" 002
test_restore_symbolic "$LINENO" 004
test_restore_symbolic "$LINENO" 010
test_restore_symbolic "$LINENO" 020
test_restore_symbolic "$LINENO" 040
test_restore_symbolic "$LINENO" 100
test_restore_symbolic "$LINENO" 200
test_restore_symbolic "$LINENO" 400
test_restore_symbolic "$LINENO" 653
test_restore_symbolic "$LINENO" 017

(
# $1 = $LINENO, $2 = expected permission, $3 = umask
test_symbolic_operand() {
    testcase "$1" "symbolic operand $3" 3<<__IN__ 4<<__OUT__ 5</dev/null
umask "$3"
mkdir "dir.$1"
ls -dl "dir.$1" | cut -c 1-10
__IN__
$2
__OUT__
}

umask 777

test_symbolic_operand "$LINENO" d--------- u+
test_symbolic_operand "$LINENO" dr-------- u+r
test_symbolic_operand "$LINENO" d-w------- u+w
test_symbolic_operand "$LINENO" d--x------ u+x
test_symbolic_operand "$LINENO" drw------- u+rw
test_symbolic_operand "$LINENO" dr-x------ u+xr
test_symbolic_operand "$LINENO" d-wx------ u+wx
test_symbolic_operand "$LINENO" drwx------ u+xwr

test_symbolic_operand "$LINENO" d--------- g+
test_symbolic_operand "$LINENO" d---r----- g+r
test_symbolic_operand "$LINENO" d----w---- g+w
test_symbolic_operand "$LINENO" d-----x--- g+x
test_symbolic_operand "$LINENO" d---rw---- g+rw
test_symbolic_operand "$LINENO" d---r-x--- g+xr
test_symbolic_operand "$LINENO" d----wx--- g+wx
test_symbolic_operand "$LINENO" d---rwx--- g+xwr

test_symbolic_operand "$LINENO" d--------- o+
test_symbolic_operand "$LINENO" d------r-- o+r
test_symbolic_operand "$LINENO" d-------w- o+w
test_symbolic_operand "$LINENO" d--------x o+x
test_symbolic_operand "$LINENO" d------rw- o+rw
test_symbolic_operand "$LINENO" d------r-x o+xr
test_symbolic_operand "$LINENO" d-------wx o+wx
test_symbolic_operand "$LINENO" d------rwx o+xwr

test_symbolic_operand "$LINENO" d--------- a+
test_symbolic_operand "$LINENO" dr--r--r-- a+r
test_symbolic_operand "$LINENO" d-w--w--w- a+w
test_symbolic_operand "$LINENO" d--x--x--x a+x
test_symbolic_operand "$LINENO" drw-rw-rw- a+rw
test_symbolic_operand "$LINENO" dr-xr-xr-x a+xr
test_symbolic_operand "$LINENO" d-wx-wx-wx a+wx
test_symbolic_operand "$LINENO" drwxrwxrwx a+xwr

test_symbolic_operand "$LINENO" d--------- +
test_symbolic_operand "$LINENO" dr--r--r-- +r
test_symbolic_operand "$LINENO" d-w--w--w- +w
test_symbolic_operand "$LINENO" d--x--x--x +x
test_symbolic_operand "$LINENO" drw-rw-rw- +rw
test_symbolic_operand "$LINENO" dr-xr-xr-x +xr
test_symbolic_operand "$LINENO" d-wx-wx-wx +wx
test_symbolic_operand "$LINENO" drwxrwxrwx +xwr

test_symbolic_operand "$LINENO" d--------- u=
test_symbolic_operand "$LINENO" dr-------- u=r
test_symbolic_operand "$LINENO" d-w------- u=w
test_symbolic_operand "$LINENO" d--x------ u=x
test_symbolic_operand "$LINENO" drw------- u=rw
test_symbolic_operand "$LINENO" dr-x------ u=xr
test_symbolic_operand "$LINENO" d-wx------ u=wx
test_symbolic_operand "$LINENO" drwx------ u=xwr

test_symbolic_operand "$LINENO" drw------- u=r+w
test_symbolic_operand "$LINENO" dr-------- u+w=r
test_symbolic_operand "$LINENO" dr-x------ u+w=r+x

test_symbolic_operand "$LINENO" drw--wxr-x u=r+w,g=wx,o+xr
test_symbolic_operand "$LINENO" dr-x------ u=rwx,u-w

umask 177

test_symbolic_operand "$LINENO" drw-rw---- g=u
test_symbolic_operand "$LINENO" drw----rw- o=u
test_symbolic_operand "$LINENO" drw-rw-rw- og=u
test_symbolic_operand "$LINENO" drw-rw-rw- og=u
test_symbolic_operand "$LINENO" drw-rw---x g+u,o+rwx-u

)

test_OE -e 0 'with operand, -S option is ignored'
umask -S 000
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/unset-p.tst <<'EOF'
# unset-p.tst: test of the unset built-in for any POSIX-compliant shell

posix="true"

echo echo external a > a
echo echo external b > b
echo echo external c > c
echo echo external d > d
echo echo external x > x
chmod a+x a b c d x
setup 'PATH=.:$PATH'

test_oE -e 0 'deleting existing variable (default)' -e
a=1 b=2
unset a
echo ${a-unset} ${b-unset}
__IN__
unset 2
__OUT__

test_oE -e 0 'deleting non-existing variable (default)' -e
a=1 b=2
unset x
echo ${a-unset} ${b-unset} ${x-unset}
__IN__
1 2 unset
__OUT__

test_oE -e 0 'deleting many variables (default)' -e
a=1 b=2 c=3 d=4
unset a b x c
echo ${a-unset} ${b-unset} ${c-unset} ${d-unset} ${x-unset}
__IN__
unset unset unset 4 unset
__OUT__

test_oE -e 0 'only variable is deleted by default' -e
a() { echo "$@"; }
a=1
unset a
a ${a-unset}
__IN__
unset
__OUT__

test_oE -e 0 'deleting many variables (-v)' -e
a=1 b=2 c=3 d=4
unset -v a b x c
echo ${a-unset} ${b-unset} ${c-unset} ${d-unset} ${x-unset}
__IN__
unset unset unset 4 unset
__OUT__

test_oE -e 0 'only variable is deleted (-v)' -e
a() { echo "$@"; }
a=1
unset -v a
a ${a-unset}
__IN__
unset
__OUT__

test_oE -e 0 'deleting existing function (-f)' -e
a() { echo a; }
b() { echo b; }
unset -f b
a
b
__IN__
a
external b
__OUT__

test_oE -e 0 'deleting non-existing function (-f)' -e
a() { echo a; }
unset -f b
a
b
__IN__
a
external b
__OUT__

test_oE -e 0 'deleting many functions (-f)' -e
a() { echo a; }
b() { echo b; }
c() { echo c; }
d() { echo d; }
unset -f a b x c
a
b
c
d
x
__IN__
external a
external b
external c
d
external x
__OUT__

test_oE -e 0 'only function is deleted (-f)' -e
a=1
a() { echo a; }
unset -f a
echo ${a-unset}
__IN__
1
__OUT__

test_O -d -e n 'read-only variable cannot be deleted (default)'
readonly a=
unset a
echo not reached # special built-in error kills non-interactive shell
__IN__

test_O -d -e n 'read-only variable cannot be deleted (-v)'
readonly a=
unset -v a
echo not reached # special built-in error kills non-interactive shell
__IN__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/until-p.tst <<'EOF'
# until-p.tst: test of until loop for any POSIX-compliant shell

posix="true"

test_oE 'execution path of 0-round loop'
i=0
until [ $((i=i+1)) -gt 0 ];do echo $i;done
echo done $i
__IN__
done 1
__OUT__

test_oE 'execution path of 1-round loop'
i=0
until [ $((i=i+1)) -gt 1 ];do echo $i;done
echo done $i
__IN__
1
done 2
__OUT__

test_oE 'execution path of 2-round loop'
i=0
until [ $((i=i+1)) -gt 2 ];do echo $i;done
echo done $i
__IN__
1
2
done 3
__OUT__

(
setup <<\__END__
\unalias \x
x() { return $1; }
__END__

test_x -e 0 'exit status of 0-round loop'
until true;do :;done
__IN__

test_x -e 1 'exit status of 1-round loop'
i=0
until [ $((i=i+1)) -gt 1 ];do x $i;done
__IN__

test_x -e 2 'exit status of 2-round loop'
i=0
until [ $((i=i+1)) -gt 2 ];do x $i;done
__IN__

)

test_oE 'linebreak after until'
i=0
until
    
    [ $((i=i+1)) -gt 2 ];do echo $i;done
__IN__
1
2
__OUT__

test_oE 'linebreak before do'
i=0
until [ $((i=i+1)) -gt 2 ]

    do echo $i;done
__IN__
1
2
__OUT__

test_oE 'linebreak after do'
i=0
until [ $((i=i+1)) -gt 2 ];do
    
    echo $i;done
__IN__
1
2
__OUT__

test_oE 'linebreak before done'
i=0
until [ $((i=i+1)) -gt 2 ];do echo $i

    done
__IN__
1
2
__OUT__

test_oE 'command ending with asynchronous command (condition)'
until echo foo&do echo not reached;break;done;wait
__IN__
foo
__OUT__

test_oE 'command ending with asynchronous command (body)'
i=0
until [ $((i=i+1)) -gt 1 ];do echo $i&done
wait
__IN__
1
__OUT__

test_oE 'more than one inner command'
i=0
until i=$((i+1)); [ $i -gt 2 ];do echo $i;echo -;done
__IN__
1
-
2
-
__OUT__

test_oE 'nest between until and do'
i=0
until { [ $((i=i+1)) -gt 1 ]; } do echo $i;done
__IN__
1
__OUT__

test_oE 'nest between do and done'
i=0
until [ $((i=i+1)) -gt 1 ]; do { echo $i;} done
__IN__
1
__OUT__

test_oE 'redirection on until loop'
i=0
until echo -;[ $((i=i+1)) -gt 1 ];do echo $i;done >redir_out
cat redir_out
__IN__
-
1
-
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/wait-p.tst <<'EOF'
# wait-p.tst: test of the wait built-in for any POSIX-compliant shell
../checkfg || skip="true" # %REQUIRETTY%

posix="true"

test_oE 'waiting for all jobs (+m)'
echo a > a& echo b > b& echo c > c& exit 1&
wait
cat a b c
__IN__
a
b
c
__OUT__

test_OE -e 11 'waiting for specific single job (+m)'
exit 11&
wait $!
__IN__

test_OE -e 1 'waiting for specific many jobs (+m)'
exit 1& p1=$!
exit 2& p2=$!
exit 3& p3=$!
wait $p3 $p2 $p1
__IN__

test_OE -e 127 'waiting for unknown job (+m)'
exit 1&
wait $! $(($!+1))
__IN__

test_OE -e 127 'jobs are not inherited to subshells (+m, -s)'
exit 1&
p=$!
(wait $p)
__IN__

test_OE -e 127 'jobs are not inherited to subshells (+m, -c)' \
    -c 'exit 1& p=$!; (wait $p)'
__IN__

test_OE -e 1 'jobs are not propagated from subshells (+m)'
exit 1&
(exit 2&)
wait $!
__IN__

test_oE 'waiting for all jobs (-m)' -m
echo a > a& echo b > b& echo c > c& exit 1&
wait
cat a b c
__IN__
a
b
c
__OUT__

test_OE -e 11 'waiting for specific single job (-m)' -m
exit 11&
wait $!
__IN__

test_OE -e 1 'waiting for specific many jobs (-m)' -m
exit 1& p1=$!
exit 2& p2=$!
exit 3& p3=$!
wait $p3 $p2 $p1
__IN__

test_OE -e 127 'waiting for unknown job (-m)' -m
exit 1&
wait $! $(($!+1))
__IN__

test_oE -e 11 'specifying job ID' -m
cat /dev/null&
echo 1&
exit 11&
wait %echo %exit
__IN__
1
__OUT__

test_OE -e 127 'jobs are not inherited to subshells (-m, -s)' -m
exit 1&
p=$!
(wait $p)
__IN__

test_OE -e 127 'jobs are not inherited to subshells (+m, -c)' \
    -cm 'exit 1& p=$!; (wait $p)'
__IN__

test_OE -e 1 'jobs are not propagated from subshells (-m)' -m
exit 1&
(exit 2&)
wait $!
__IN__

test_oE 'trap interrupts wait' -m
interrupted=false
trap 'interrupted=true' USR1
while kill -s 0 $$; do kill -s USR1 $$; done&
# The asynchronous job should eventually interrupt the wait.
wait
status=$?
echo interrupted=$interrupted $((status > 128))
kill -l $status
trap '' USR1
# Now the job should be still running. Kill it.
kill -s USR2 %
wait
echo waited $?
__IN__
interrupted=true 1
USR1
waited 0
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF
put yash/while-p.tst <<'EOF'
# while-p.tst: test of while loop for any POSIX-compliant shell

posix="true"

test_oE 'execution path of 0-round loop'
i=0
while [ $((i=i+1)) -le 0 ];do echo $i;done
echo done $i
__IN__
done 1
__OUT__

test_oE 'execution path of 1-round loop'
i=0
while [ $((i=i+1)) -le 1 ];do echo $i;done
echo done $i
__IN__
1
done 2
__OUT__

test_oE 'execution path of 2-round loop'
i=0
while [ $((i=i+1)) -le 2 ];do echo $i;done
echo done $i
__IN__
1
2
done 3
__OUT__

(
setup <<\__END__
\unalias \x
x() { return $1; }
__END__

test_x -e 0 'exit status of 0-round loop'
while false;do :;done
__IN__

test_x -e 1 'exit status of 1-round loop'
i=0
while [ $((i=i+1)) -le 1 ];do x $i;done
__IN__

test_x -e 2 'exit status of 2-round loop'
i=0
while [ $((i=i+1)) -le 2 ];do x $i;done
__IN__

)

test_oE 'linebreak after while'
i=0
while
    
    [ $((i=i+1)) -le 2 ];do echo $i;done
__IN__
1
2
__OUT__

test_oE 'linebreak before do'
i=0
while [ $((i=i+1)) -le 2 ]

    do echo $i;done
__IN__
1
2
__OUT__

test_oE 'linebreak after do'
i=0
while [ $((i=i+1)) -le 2 ];do
    
    echo $i;done
__IN__
1
2
__OUT__

test_oE 'linebreak before done'
i=0
while [ $((i=i+1)) -le 2 ];do echo $i

    done
__IN__
1
2
__OUT__

test_oE 'command ending with asynchronous command (condition)'
while echo foo&do break;done;wait
__IN__
foo
__OUT__

test_oE 'command ending with asynchronous command (body)'
i=0
while [ $((i=i+1)) -le 1 ];do echo $i&done
wait
__IN__
1
__OUT__

test_oE 'more than one inner command'
i=0
while i=$((i+1)); [ $i -le 2 ];do echo $i;echo -;done
__IN__
1
-
2
-
__OUT__

test_oE 'nest between while and do'
i=0
while { [ $((i=i+1)) -le 1 ]; } do echo $i;done
__IN__
1
__OUT__

test_oE 'nest between do and done'
i=0
while [ $((i=i+1)) -le 1 ]; do { echo $i;} done
__IN__
1
__OUT__

test_oE 'redirection on while loop'
i=0
while echo -;[ $((i=i+1)) -le 1 ];do echo $i;done >redir_out
cat redir_out
__IN__
-
1
-
__OUT__

# vim: set ft=sh ts=8 sts=4 sw=4 et:
EOF

case " $SUITES " in *' fbsd '*)
	printf '\n%s\n' '─── FreeBSD bin/sh/tests ─────────────────────────────────────────────────────'
	# name.N: exit status N; stdout and stderr must match name.N.stdout
	# and name.N.stderr, or be empty if there is none
	for f in "$EXT"/fbsd/*/*; do
		case $f in *.stdout|*.stderr) continue ;; esac
		ext_run "$f"
		why=
		[ "$st" = "${f##*.}" ] ||
			why="exit status: expected ${f##*.}, actual $st"
		exp=/dev/null
		[ -f "$f.stdout" ] && exp=$f.stdout
		cmp -s "$exp" "$XW.out" ||
			why="$why${why:+$NL}$(ext_diff stdout "$exp" "$XW.out")"
		exp=/dev/null
		[ -f "$f.stderr" ] && exp=$f.stderr
		e=$(ext_err "$exp")
		why="$why${why:+${e:+$NL}}$e"
		ext_result "fbsd/${f#"$EXT"/fbsd/}" "$why"
	done
	rm -f "$XW.out" "$XW.err"
esac

case " $SUITES " in *' smoosh '*)
	printf '\n%s\n' '─── smoosh tests/shell ───────────────────────────────────────────────────────'
	# name.test: exit status in name.ec (default 0), stdout and stderr in
	# name.out and name.err when present
	U=$EXT/smoosh/util
	util=1
	for c in argv fds getenv readdir; do
		${CC:-cc} -o "$U/$c" "$U/$c.c" 2>/dev/null || util=
	done
	for f in "$EXT"/smoosh/shell/*.test; do
		b=${f%.test}
		if [ -z "$util" ] && grep -q TEST_UTIL "$f"; then
			ext_result "smoosh/${b##*/}" SKIP
			continue
		fi
		ext_run "$f"
		why=
		ec=0
		[ -f "$b.ec" ] && ec=$(cat "$b.ec")
		[ "$st" = "$ec" ] || why="exit status: expected $ec, actual $st"
		if [ -f "$b.out" ] && ! cmp -s "$b.out" "$XW.out"; then
			why="$why${why:+$NL}$(ext_diff stdout "$b.out" "$XW.out")"
		fi
		if [ -f "$b.err" ]; then
			e=$(ext_err "$b.err")
			why="$why${why:+${e:+$NL}}$e"
		fi
		ext_result "smoosh/${b##*/}" "$why"
	done
	rm -f "$XW.out" "$XW.err"
esac

case " $SUITES " in *' yash '*)
	printf '\n%s\n' '─── yash tests (POSIX subset) ────────────────────────────────────────────────'
	# Job control and terminal tests need ../checkfg to succeed under a
	# pseudo-terminal; ours always fails, so they are skipped.
	chmod +x "$EXT/yash/checkfg"
	for f in "$EXT"/yash/*-p.tst; do
		: > "$EXT/yash.counts"
		(cd "$EXT/yash" && exec ${TIMEOUT:+$TIMEOUT 300} \
			$HSH ./run-test.sh "$SHABS" "${f##*/}" "$N" "$EXT/yash.counts")
		st=$?
		p=$(grep -c '^P$' "$EXT/yash.counts")
		x=$(grep -c '^F$' "$EXT/yash.counts")
		s=$(grep -c '^S$' "$EXT/yash.counts")
		PASS=$((PASS + p)) FAIL=$((FAIL + x)) SKIP=$((SKIP + s))
		N=$((N + p + x + s))
		case $st in 124|137)
			ext_result "yash/${f##*/}" "timed out, killed after test $N"
		esac
	done
esac

printf '\n%s\n' '─── Summary ──────────────────────────────────────────────────────────────────'

printf '\nResults: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
