/*
 * printf(1) as a shell builtin.
 *
 * Having printf built in avoids the kernel's per-argument size limit
 * (MAX_ARG_STRLEN) that execve(2) imposes on the external utility, and
 * is what most other shells do.
 */

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sh.h"

#define PF_STOP		1	/* \c seen: stop all output */

static char	**pf_argv;	/* remaining arguments */
static int	  pf_used;	/* an argument was consumed */
static int	  pf_error;	/* bad numeric argument seen */

static char *
pf_getarg(void)
{
	static char null[] = "";

	if (*pf_argv == NULL)
		return null;
	pf_used = 1;
	return *pf_argv++;
}

static intmax_t
pf_getsigned(void)
{
	char *s = pf_getarg();
	char *ep;
	intmax_t v;

	if (*s == '\'' || *s == '"')
		return (unsigned char) s[1];
	errno = 0;
	v = strtoimax(s, &ep, 0);
	if (ep == s || *ep != '\0') {
		bi_errorf("%s: invalid number", s);
		pf_error = 1;
	} else if (errno == ERANGE) {
		bi_errorf("%s: out of range", s);
		pf_error = 1;
	}
	return v;
}

static uintmax_t
pf_getunsigned(void)
{
	char *s = pf_getarg();
	char *ep;
	uintmax_t v;

	if (*s == '\'' || *s == '"')
		return (unsigned char) s[1];
	errno = 0;
	v = strtoumax(s, &ep, 0);
	if (ep == s || *ep != '\0') {
		bi_errorf("%s: invalid number", s);
		pf_error = 1;
	} else if (errno == ERANGE) {
		bi_errorf("%s: out of range", s);
		pf_error = 1;
	}
	return v;
}

static double
pf_getdouble(void)
{
	char *s = pf_getarg();
	char *ep;
	double v;

	if (*s == '\'' || *s == '"')
		return (unsigned char) s[1];
	errno = 0;
	v = strtod(s, &ep);
	if (ep == s || *ep != '\0') {
		bi_errorf("%s: invalid number", s);
		pf_error = 1;
	} else if (errno == ERANGE) {
		bi_errorf("%s: out of range", s);
		pf_error = 1;
	}
	return v;
}

/* Handle the backslash sequence at *sp (which points at the backslash),
 * printing its expansion and advancing *sp past it.  Returns PF_STOP if
 * a \c was seen in a %b argument, 0 otherwise.
 */
static int
pf_backslash(const char **sp, int is_b)
{
	const char *s = *sp + 1;
	int c, i;

	switch ((c = *s++)) {
	case 'a': c = '\a'; break;
	case 'b': c = '\b'; break;
	case 'c':
		if (is_b) {
			*sp = s;
			return PF_STOP;
		}
		shf_putc('\\', shl_stdout);
		break;
	case 'f': c = '\f'; break;
	case 'n': c = '\n'; break;
	case 'r': c = '\r'; break;
	case 't': c = '\t'; break;
	case 'v': c = '\v'; break;
	case '\\': c = '\\'; break;
	case '\0':
		s--;
		c = '\\';
		break;
	case '0': case '1': case '2': case '3':
	case '4': case '5': case '6': case '7':
		/* \ddd (three digits) in a format, \0ddd in a %b argument */
		if (is_b && c == '0') {
			c = 0;
			i = 0;
		} else {
			c -= '0';
			i = 1;
		}
		for (; i < 3 && *s >= '0' && *s <= '7'; i++)
			c = c * 8 + *s++ - '0';
		break;
	default:
		shf_putc('\\', shl_stdout);
		break;
	}
	shf_putc(c, shl_stdout);
	*sp = s;
	return 0;
}

/* Print a %b argument: like a format string, but \c stops all output. */
static int
pf_escape(const char *s)
{
	while (*s != '\0') {
		if (*s == '\\') {
			if (pf_backslash(&s, 1) == PF_STOP)
				return PF_STOP;
		} else
			shf_putc(*s++, shl_stdout);
	}
	return 0;
}

/* Format one conversion with the system's printf(3) and write the result. */
static void
pf_conv(const char *fmt, int nstar, int w1, int w2, int conv)
{
	char *bp = NULL;
	int len;

	switch (conv) {
	case 'd': case 'i': {
		intmax_t v = pf_getsigned();
		len = nstar == 0 ? asprintf(&bp, fmt, v) :
		    nstar == 1 ? asprintf(&bp, fmt, w1, v) :
		    asprintf(&bp, fmt, w1, w2, v);
		break;
	}
	case 'o': case 'u': case 'x': case 'X': {
		uintmax_t v = pf_getunsigned();
		len = nstar == 0 ? asprintf(&bp, fmt, v) :
		    nstar == 1 ? asprintf(&bp, fmt, w1, v) :
		    asprintf(&bp, fmt, w1, w2, v);
		break;
	}
	case 'a': case 'A': case 'e': case 'E':
	case 'f': case 'F': case 'g': case 'G': {
		double v = pf_getdouble();
		len = nstar == 0 ? asprintf(&bp, fmt, v) :
		    nstar == 1 ? asprintf(&bp, fmt, w1, v) :
		    asprintf(&bp, fmt, w1, w2, v);
		break;
	}
	case 'c': {
		char *s = pf_getarg();
		len = nstar == 0 ? asprintf(&bp, fmt, *s) :
		    nstar == 1 ? asprintf(&bp, fmt, w1, *s) :
		    asprintf(&bp, fmt, w1, w2, *s);
		break;
	}
	default: {	/* 's' */
		char *s = pf_getarg();
		len = nstar == 0 ? asprintf(&bp, fmt, s) :
		    nstar == 1 ? asprintf(&bp, fmt, w1, s) :
		    asprintf(&bp, fmt, w1, w2, s);
		break;
	}
	}
	if (len < 0 || bp == NULL) {
		bi_errorf("out of memory");
		pf_error = 1;
		return;
	}
	shf_write(bp, len, shl_stdout);
	free(bp);
}

int
c_printf(char **wp)
{
	const char *fmt, *s;
	char spec[64], *sp;
	int c, nstar, w1, w2, stop;

	if (wp[1] != NULL && strcmp(wp[1], "--") == 0 && wp[2] != NULL)
		wp++;
	if (wp[1] == NULL) {
		bi_errorf("usage: printf format [arg ...]");
		return 1;
	}
	fmt = wp[1];
	pf_argv = wp + 2;
	pf_error = 0;
	stop = 0;

	do {
		pf_used = 0;
		for (s = fmt; !stop && (c = *s++) != '\0'; ) {
			if (c != '%') {
				if (c == '\\') {
					s--;
					pf_backslash(&s, 0);
				} else
					shf_putc(c, shl_stdout);
				continue;
			}
			if (*s == '%') {
				shf_putc('%', shl_stdout);
				s++;
				continue;
			}
			/* collect flags, width and precision */
			sp = spec;
			*sp++ = '%';
			nstar = 0;
			w1 = w2 = 0;
			while (*s != '\0' && strchr("#-+ 0'", *s) != NULL) {
				if (*s == '\'') {	/* not portable */
					s++;
					continue;
				}
				if (sp - spec < (int) sizeof(spec) - 8)
					*sp++ = *s;
				s++;
			}
			for (c = 0; c < 2; c++) {
				if (c == 1) {
					if (*s != '.')
						break;
					if (sp - spec < (int) sizeof(spec) - 8)
						*sp++ = *s;
					s++;
				}
				if (*s == '*') {
					intmax_t v = pf_getsigned();
					if (nstar == 0)
						w1 = (int) v;
					else
						w2 = (int) v;
					nstar++;
					if (sp - spec < (int) sizeof(spec) - 8)
						*sp++ = '*';
					s++;
				} else
					while (isdigit((unsigned char) *s)) {
						if (sp - spec <
						    (int) sizeof(spec) - 8)
							*sp++ = *s;
						s++;
					}
			}
			/* the shell decides the argument size, not the user */
			while (*s != '\0' && strchr("hlLqjzt", *s) != NULL)
				s++;
			c = *s++;
			switch (c) {
			case 'b': {
				char *arg = pf_getarg();
				if (pf_escape(arg) == PF_STOP)
					stop = 1;
				break;
			}
			case 'd': case 'i': case 'o': case 'u':
			case 'x': case 'X':
				*sp++ = 'j';
				*sp++ = c;
				*sp = '\0';
				pf_conv(spec, nstar, w1, w2, c);
				break;
			case 'a': case 'A': case 'e': case 'E':
			case 'f': case 'F': case 'g': case 'G':
			case 'c': case 's':
				*sp++ = c;
				*sp = '\0';
				pf_conv(spec, nstar, w1, w2, c);
				break;
			case '\0':
				bi_errorf("missing conversion character");
				return 1;
			default:
				bi_errorf("%%%c: invalid conversion", c);
				return 1;
			}
		}
	} while (!stop && pf_used && *pf_argv != NULL);

	return pf_error ? 1 : 0;
}
