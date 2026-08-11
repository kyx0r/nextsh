#!/bin/sh

POSIXLY_CORRECT=1
cbuild_OPWD="$PWD"
BASE="${0%/*}" && [ "$BASE" = "$0" ] && BASE="."
cd "$BASE" || exit 1
BASE="${PWD%/}"
trap 'cd "$cbuild_OPWD"' EXIT

# Color escape sequences
G="\033[32m" #     Green
R="\033[31m" #     Red
B="\033[34m" #     Blue
NC="\033[m"  #     Unset

log() {
    # shellcheck disable=SC2059 # Using %s with ANSII escape sequences is not possible
    printf "${1}->$NC "
    shift
    printf "%s\n" "$*"
}

require() {
    set -- $1
    command -v "$1" >/dev/null 2>&1 || {
        log "$R" "[$1] is not installed. Please ensure the command is available [$1] and try again."
        exit 1
    }
}

run() {
    log "$B" "$*"
    # shellcheck disable=SC2068 # We want to split elements, but avoid whitespace problems (`$*`)
    $@
}

: "${CC:=cc}"
: "${STRIP:=strip}"
: "${PREFIX:=/usr/local}"
: "${OS:=$(uname)}"
: "${CFLAGS:=-O2}"

CFLAGS="\
-Wall -Wextra \
-Wno-implicit-fallthrough \
-Wno-missing-field-initializers \
-Wno-unused-parameter \
-Wno-unused-result \
-Wno-pointer-sign \
-std=c99 \
$CFLAGS"

case "$OS" in
*Linux*|*_NT*|*CYGWIN*|*MSYS*) CFLAGS="$CFLAGS -D_GNU_SOURCE" ;;
*Darwin*) CFLAGS="$CFLAGS -D_DARWIN_C_SOURCE" ;;
*AIX*|*OS400*) CFLAGS="$CFLAGS -D_ALL_SOURCE" ;;
*SunOS*) CFLAGS="$CFLAGS -D__EXTENSIONS__" ;;
*Haiku*|*QNX*) CFLAGS="$CFLAGS -D_DEFAULT_SOURCE" ;;
*) CFLAGS="$CFLAGS -D_BSD_SOURCE -D_DEFAULT_SOURCE" ;;
esac

build() {
    require "${CC}"
    log "$G" "Entering step: \"Build \"${BASE##*/}\" using \"$CC\"\""
    run "$CC sh.c -o sh $CFLAGS $LDFLAGS" || {
        log "$R" "Failed during step: \"Build \"${BASE##*/}\" using \"$CC\""
        exit 1
    }
}

install() {
    run rm -f "$DESTDIR$PREFIX/bin/sh" 2> /dev/null
    command -v "$STRIP" >/dev/null 2>&1 && run "$STRIP" sh
    run mkdir -p "$DESTDIR$PREFIX/bin/" &&
    run cp -f sh "$DESTDIR$PREFIX/bin/sh" &&
    [ -x "$DESTDIR$PREFIX/bin/sh" ] && log "$G" "\"${BASE##*/}\" has been installed to $DESTDIR$PREFIX/bin/sh" || log "$R" "Couldn't finish installation"
}

check() {
    [ -x ./sh ] || build
    log "$G" "Entering step: \"Check \"${BASE##*/}\"\""
    fail=0
    t() { # t <name> <script> <expected>
        got="$(printf '%s\n' "$2" | ./sh 2>&1)"
        if [ "$got" = "$3" ]; then
            log "$B" "ok    $1"
        else
            log "$R" "FAIL  $1: expected [$3], got [$got]"
            fail=$((fail + 1))
        fi
    }
    t "arithmetic"  'echo $((3 * (2 + 5)))' '21'
    t "expansion"   'x=abcdef; echo ${x#abc} ${x%def} ${#x}' 'def abc 6'
    t "command sub" 'echo $(echo nested $(echo deep))' 'nested deep'
    t "loops"       'for i in 1 2 3; do printf "%s" "$i"; done; echo' '123'
    t "functions"   'f() { echo "$1$2"; }; f a b' 'ab'
    t "case"        'case foobar in foo*) echo match;; *) echo no;; esac' 'match'
    t "test"        '[ 2 -gt 1 ] && [[ ab == a? ]] && echo yes' 'yes'
    t "printf"      'printf "%s-%03d-%x\n" str 7 255' 'str-007-ff'
    t "typeset"     'typeset -i n=010; echo $((n + 1))' '9'
    t "here doc"    'cat <<EOF
here $((1 + 1))
EOF' 'here 2'
    t "pipeline"    'echo one two three | tr " " "\n" | sed -n 2p' 'two'
    t "subshell"    'x=1; (x=2); echo $x' '1'
    t "trap"        'trap "echo caught" USR1; kill -USR1 $$; echo after' 'caught
after'
    t "exit status" 'false; echo $?' '1'
    t "aliases"     'alias hi="echo aliased"
hi' 'aliased'
    if [ "$fail" -eq 0 ]; then
        log "$G" "All checks passed."
    else
        log "$R" "$fail check(s) failed."
        exit 1
    fi
}

print_usage() {
    echo "Usage: $0 {build|install|debug|pgobuild|check|clean}"
    exit "$1"
}

# Argument processing
while [ $# -gt 0 ] || [ "$1" = "" ]; do
    case "$1" in
    "install")
        shift
        [ -x ./sh ] && install && exit 0 || build && install && exit 0
        ;;
    "debug")
        shift
        if command -v scan-build >/dev/null 2>&1; then
            CC="scan-build $CC"
        fi
        CFLAGS="$CFLAGS -O0 -g -fsanitize=address -fsanitize=undefined"
        log "$G" "Entering step: \"Append \"\$CFLAGS\" with debugging flags\""
        set -- build "$@"
        ;;
    "check")
        shift
        check && exit 0 || exit 1
        ;;
    "pgobuild")
        shift
        pgobuild() {
            ccversion="$($CC --version)"
            case "$ccversion" in *clang*) clang=1 ;; esac
            if [ "$clang" = 1 ] && [ -z "$PROFDATA" ]; then
                if command -v llvm-profdata >/dev/null 2>&1; then
                    PROFDATA=llvm-profdata
                elif xcrun -f llvm-profdata >/dev/null 2>&1; then
                    PROFDATA="xcrun llvm-profdata"
                fi
                [ -z "$PROFDATA" ] && log "$R" "pgobuild with clang requires llvm-profdata" && exit 1
            fi
            run "$CC sh.c -fprofile-generate=. -o sh -O2 $CFLAGS $LDFLAGS"
            ./sh -c 'i=0; while [ $i -lt 2000 ]; do i=$((i + 1)); x="$(echo pgo $i)"; case $x in pgo*) : ;; esac; done' > /dev/null
            [ "$clang" = 1 ] && run "$PROFDATA" merge ./*.profraw -o default.profdata
            run "$CC sh.c -fprofile-use=. -o sh -O2 $CFLAGS $LDFLAGS"
            rm -f ./*.gcda ./*.profraw ./default.profdata
        }
        require "${CC}"
        log "$G" "Entering step: \"Build \"${BASE##*/}\" using \"$CC\" and PGO\""
        pgobuild || {
            log "$R" "Failed during step: \"Build \"${BASE##*/}\" using \"$CC\" and PGO\""
            exit 1
        } && exit 0 || exit 1
        ;;
    "clean")
        shift
        run rm -f sh callgrind.out.* cachegrind.out.* ./*.gcda ./*.profraw default.profdata 2>/dev/null
        exit 0
        ;;
    "" | "build")
        if [ "$1" = "build" ]; then
            shift
        fi
        build && exit 0 || exit 1
        ;;
    *)
        print_usage 1
        ;;
    esac
done
