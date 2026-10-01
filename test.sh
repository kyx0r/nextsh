#!/bin/sh
# Nextsh test suite - POSIX shell
# Tests the lexer, mostly the parts that scan the raw text of a $(..)
# body: quoting, here documents, comments and case patterns. Also tests
# vi-mode UTF-8 redraw, window buffers and completion through a PTY
# (requires script(1)).
#
# The shell under test is $SH (./sh by default), the shell running this
# script can be any POSIX shell.

SH=${SH:-./sh}
PASS=0
FAIL=0
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

printf '\n%s\n' '─── Summary ──────────────────────────────────────────────────────────────────'

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
