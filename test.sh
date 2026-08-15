#!/bin/sh
# Nextsh test suite - POSIX shell
# Tests the lexer, mostly the parts that scan the raw text of a $(..)
# body: quoting, here documents, comments and case patterns.
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

printf '\n%s\n' '─── Summary ──────────────────────────────────────────────────────────────────'

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
