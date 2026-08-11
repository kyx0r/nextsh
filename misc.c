/*
 * nextsh: housekeeping - memory, tables, options, paths and mail.
 *
 * Public domain, except where noted.
 */

/*
 * Area based allocation, built on malloc/free
 */

/* Public domain, like most of the rest of ksh */

/*
 * area-based allocation built on malloc/free
 */



struct link {
	struct link *prev;
	struct link *next;
};

Area *
ainit(Area *ap)
{
	ap->freelist = NULL;
	return ap;
}

void
afreeall(Area *ap)
{
	struct link *l, *l2;

	for (l = ap->freelist; l != NULL; l = l2) {
		l2 = l->next;
		free(l);
	}
	ap->freelist = NULL;
}

#define L2P(l)	( (void *)(((char *)(l)) + sizeof(struct link)) )
#define P2L(p)	( (struct link *)(((char *)(p)) - sizeof(struct link)) )

void *
alloc(size_t size, Area *ap)
{
	struct link *l;

	/* ensure that we don't overflow by allocating space for link */
	if (size > SIZE_MAX - sizeof(struct link))
		internal_errorf("unable to allocate memory");

	l = malloc(sizeof(struct link) + size);
	if (l == NULL)
		internal_errorf("unable to allocate memory");
	l->next = ap->freelist;
	l->prev = NULL;
	if (ap->freelist)
		ap->freelist->prev = l;
	ap->freelist = l;

	return L2P(l);
}

void *
areallocarray(void *ptr, size_t nmemb, size_t size, Area *ap)
{
	/* condition logic cloned from calloc() */
	if ((nmemb >= MUL_NO_OVERFLOW || size >= MUL_NO_OVERFLOW) &&
	    nmemb > 0 && SIZE_MAX / nmemb < size) {
		internal_errorf("unable to allocate memory");
	}

	return aresize(ptr, nmemb * size, ap);
}

void *
aresize(void *ptr, size_t size, Area *ap)
{
	struct link *l, *l2, *lprev, *lnext;

	if (ptr == NULL)
		return alloc(size, ap);

	/* ensure that we don't overflow by allocating space for link */
	if (size > SIZE_MAX - sizeof(struct link))
		internal_errorf("unable to allocate memory");

	l = P2L(ptr);
	lprev = l->prev;
	lnext = l->next;

	l2 = realloc(l, sizeof(struct link) + size);
	if (l2 == NULL)
		internal_errorf("unable to allocate memory");
	if (lprev)
		lprev->next = l2;
	else
		ap->freelist = l2;
	if (lnext)
		lnext->prev = l2;

	return L2P(l2);
}

void
afree(void *ptr, Area *ap)
{
	struct link *l;

	if (!ptr)
		return;

	l = P2L(ptr);
	if (l->prev)
		l->prev->next = l->next;
	else
		ap->freelist = l->next;
	if (l->next)
		l->next->prev = l->prev;

	free(l);
}

/*
 * Hash tables: symbol and command tables
 */

/*
 * dynamic hashed associative table for commands and variables
 */



#define	INIT_TBLS	8	/* initial table size (power of 2) */

struct table taliases;	/* tracked aliases */
struct table builtins;	/* built-in commands */
struct table aliases;	/* aliases */
struct table keywords;	/* keywords */
struct table homedirs;	/* homedir() cache */

char *search_path;	/* copy of either PATH or def_path */
const char *def_path;	/* path to use if PATH not set */
char *tmpdir;		/* TMPDIR value */
const char *prompt;
int cur_prompt;		/* PS1 or PS2 */
int current_lineno;	/* LINENO value */

static void	texpand(struct table *, int);
static int	tnamecmp(const void *, const void *);


unsigned int
hash(const char *n)
{
	unsigned int h = 0;

	while (*n != '\0')
		h = 33*h + (unsigned char)(*n++);
	return h;
}

void
ktinit(struct table *tp, Area *ap, int tsize)
{
	tp->areap = ap;
	tp->tbls = NULL;
	tp->size = tp->nfree = 0;
	if (tsize)
		texpand(tp, tsize);
}

static void
texpand(struct table *tp, int nsize)
{
	int i;
	struct tbl *tblp, **p;
	struct tbl **ntblp, **otblp = tp->tbls;
	int osize = tp->size;

	ntblp = areallocarray(NULL, nsize, sizeof(struct tbl *), tp->areap);
	for (i = 0; i < nsize; i++)
		ntblp[i] = NULL;
	tp->size = nsize;
	tp->nfree = 7*nsize/10;	/* table can get 70% full */
	tp->tbls = ntblp;
	if (otblp == NULL)
		return;
	for (i = 0; i < osize; i++)
		if ((tblp = otblp[i]) != NULL) {
			if ((tblp->flag&DEFINED)) {
				for (p = &ntblp[hash(tblp->name) &
				    (tp->size-1)]; *p != NULL; p--)
					if (p == ntblp) /* wrap */
						p += tp->size;
				*p = tblp;
				tp->nfree--;
			} else if (!(tblp->flag & FINUSE)) {
				afree(tblp, tp->areap);
			}
		}
	afree(otblp, tp->areap);
}

/* table */
/* name to enter */
/* hash(n) */
struct tbl *
ktsearch(struct table *tp, const char *n, unsigned int h)
{
	struct tbl **pp, *p;

	if (tp->size == 0)
		return NULL;

	/* search for name in hashed table */
	for (pp = &tp->tbls[h & (tp->size-1)]; (p = *pp) != NULL; pp--) {
		if (*p->name == *n && strcmp(p->name, n) == 0 &&
		    (p->flag&DEFINED))
			return p;
		if (pp == tp->tbls) /* wrap */
			pp += tp->size;
	}

	return NULL;
}

/* table */
/* name to enter */
/* hash(n) */
struct tbl *
ktenter(struct table *tp, const char *n, unsigned int h)
{
	struct tbl **pp, *p;
	int len;

	if (tp->size == 0)
		texpand(tp, INIT_TBLS);
  Search:
	/* search for name in hashed table */
	for (pp = &tp->tbls[h & (tp->size-1)]; (p = *pp) != NULL; pp--) {
		if (*p->name == *n && strcmp(p->name, n) == 0)
			return p;	/* found */
		if (pp == tp->tbls) /* wrap */
			pp += tp->size;
	}

	if (tp->nfree <= 0) {	/* too full */
		if (tp->size <= INT_MAX/2)
			texpand(tp, 2*tp->size);
		else
			internal_errorf("too many vars");
		goto Search;
	}

	/* create new tbl entry */
	len = strlen(n) + 1;
	p = alloc(offsetof(struct tbl, name[0]) + len,
				 tp->areap);
	p->flag = 0;
	p->type = 0;
	p->areap = tp->areap;
	p->u2.field = 0;
	p->u.array = NULL;
	memcpy(p->name, n, len);

	/* enter in tp->tbls */
	tp->nfree--;
	*pp = p;
	return p;
}

void
ktdelete(struct tbl *p)
{
	p->flag = 0;
}

void
ktwalk(struct tstate *ts, struct table *tp)
{
	ts->left = tp->size;
	ts->next = tp->tbls;
}

struct tbl *
ktnext(struct tstate *ts)
{
	while (--ts->left >= 0) {
		struct tbl *p = *ts->next++;
		if (p != NULL && (p->flag&DEFINED))
			return p;
	}
	return NULL;
}

static int
tnamecmp(const void *p1, const void *p2)
{
	char *name1 = (*(struct tbl **)p1)->name;
	char *name2 = (*(struct tbl **)p2)->name;
	return strcmp(name1, name2);
}

struct tbl **
ktsort(struct table *tp)
{
	int i;
	struct tbl **p, **sp, **dp;

	p = areallocarray(NULL, tp->size + 1,
	    sizeof(struct tbl *), ATEMP);
	sp = tp->tbls;		/* source */
	dp = p;			/* dest */
	for (i = 0; i < tp->size; i++)
		if ((*dp = *sp++) != NULL && (((*dp)->flag&DEFINED) ||
		    ((*dp)->flag&ARRAY)))
			dp++;
	i = dp - p;
	qsortp((void**)p, (size_t)i, tnamecmp);
	p[i] = NULL;
	return p;
}

#ifdef PERF_DEBUG /* performance debugging */

void tprintinfo(struct table *tp);

void
tprintinfo(struct table *tp)
{
	struct tbl *te;
	char *n;
	unsigned int h;
	int ncmp;
	int totncmp = 0, maxncmp = 0;
	int nentries = 0;
	struct tstate ts;

	shellf("table size %d, nfree %d\n", tp->size, tp->nfree);
	shellf("    Ncmp name\n");
	ktwalk(&ts, tp);
	while ((te = ktnext(&ts))) {
		struct tbl **pp, *p;

		h = hash(n = te->name);
		ncmp = 0;

		/* taken from ktsearch() and added counter */
		for (pp = &tp->tbls[h & (tp->size-1)]; (p = *pp); pp--) {
			ncmp++;
			if (*p->name == *n && strcmp(p->name, n) == 0 &&
			    (p->flag&DEFINED))
				break; /* return p; */
			if (pp == tp->tbls) /* wrap */
				pp += tp->size;
		}
		shellf("    %4d %s\n", ncmp, n);
		totncmp += ncmp;
		nentries++;
		if (ncmp > maxncmp)
			maxncmp = ncmp;
	}
	if (nentries)
		shellf("  %d entries, worst ncmp %d, avg ncmp %d.%02d\n",
		    nentries, maxncmp,
		    totncmp / nentries,
		    (totncmp % nentries) * 100 / nentries);
}
#endif /* PERF_DEBUG */

/*
 * Miscellany: options, string and pattern helpers
 */

/*
 * Miscellaneous functions
 */



short ctypes [UCHAR_MAX+1];	/* type bits for unsigned char */
static int dropped_privileges;

static int	do_gmatch(const unsigned char *, const unsigned char *,
		    const unsigned char *, const unsigned char *);
static const unsigned char *cclass(const unsigned char *, int);

/*
 * POSIX character classes, for pattern matching.
 */
static const struct cclass {
	const char *name;
	int (*isctype)(int);
} cclasses[] = {
	{ "alnum",	isalnum },
	{ "alpha",	isalpha },
	{ "blank",	isblank },
	{ "cntrl",	iscntrl },
	{ "digit",	isdigit },
	{ "graph",	isgraph },
	{ "lower",	islower },
	{ "print",	isprint },
	{ "punct",	ispunct },
	{ "space",	isspace },
	{ "upper",	isupper },
	{ "xdigit",	isxdigit },
	{ NULL,		NULL }
};

#define NCCLASSES	(sizeof(cclasses) / sizeof(cclasses[0]) - 1)

/*
 * Fast character classes
 */
void
setctypes(const char *s, int t)
{
	int i;

	if (t & C_IFS) {
		for (i = 0; i < UCHAR_MAX+1; i++)
			ctypes[i] &= ~C_IFS;
		ctypes[0] |= C_IFS; /* include \0 in C_IFS */
	}
	while (*s != 0)
		ctypes[(unsigned char) *s++] |= t;
}

void
initctypes(void)
{
	int c;

	for (c = 'a'; c <= 'z'; c++)
		ctypes[c] |= C_ALPHA;
	for (c = 'A'; c <= 'Z'; c++)
		ctypes[c] |= C_ALPHA;
	ctypes['_'] |= C_ALPHA;
	setctypes(" \t\n|&;<>()", C_LEX1); /* \0 added automatically */
	setctypes("*@#!$-?", C_VAR1);
	setctypes(" \t\n", C_IFSWS);
	setctypes("=-+?", C_SUBOP1);
	setctypes("#%", C_SUBOP2);
	setctypes(" \n\t\"#$&'()*;<>?[\\`|", C_QUOTE);
}

/* convert uint64_t to base N string */

char *
u64ton(uint64_t n, int base)
{
	char *p;
	static char buf [20];

	p = &buf[sizeof(buf)];
	*--p = '\0';
	do {
		*--p = "0123456789ABCDEF"[n%base];
		n /= base;
	} while (n != 0);
	return p;
}

char *
str_save(const char *s, Area *ap)
{
	size_t len;
	char *p;

	if (!s)
		return NULL;
	len = strlen(s)+1;
	p = alloc(len, ap);
	strlcpy(p, s, len);
	return (p);
}

/* Allocate a string of size n+1 and copy upto n characters from the possibly
 * null terminated string s into it.  Always returns a null terminated string
 * (unless n < 0).
 */
char *
str_nsave(const char *s, int n, Area *ap)
{
	char *ns;

	if (n < 0)
		return 0;
	ns = alloc(n + 1, ap);
	ns[0] = '\0';
	return strncat(ns, s, n);
}

/* called from expand.h:XcheckN() to grow buffer */
char *
Xcheck_grow_(XString *xsp, char *xp, size_t more)
{
	char *old_beg = xsp->beg;

	xsp->len += more > xsp->len ? more : xsp->len;
	xsp->beg = aresize(xsp->beg, xsp->len + 8, xsp->areap);
	xsp->end = xsp->beg + xsp->len;
	return xsp->beg + (xp - old_beg);
}

const struct option sh_options[] = {
	/* Special cases (see parse_args()): -A, -o, -s.
	 * Options are sorted by their longnames - the order of these
	 * entries MUST match the order of sh_flag F* enumerations in sh.h.
	 */
	{ "allexport",	'a',		OF_ANY },
	{ "braceexpand",  0,		OF_ANY }, /* non-standard */
	{ "bgnice",	  0,		OF_ANY },
	{ NULL,	'c',	    OF_CMDLINE },
	{ "csh-history",  0,		OF_ANY }, /* non-standard */
	{ "emacs",	  0,		OF_ANY },
	{ "errexit",	'e',		OF_ANY },
	{ "gmacs",	  0,		OF_ANY },
	{ "ignoreeof",	  0,		OF_ANY },
	{ "interactive",'i',	    OF_CMDLINE },
	{ "keyword",	'k',		OF_ANY },
	{ "login",	'l',	    OF_CMDLINE },
	{ "markdirs",	'X',		OF_ANY },
	{ "monitor",	'm',		OF_ANY },
	{ "noclobber",	'C',		OF_ANY },
	{ "noexec",	'n',		OF_ANY },
	{ "noglob",	'f',		OF_ANY },
	{ "nohup",	  0,		OF_ANY },
	{ "nolog",	  0,		OF_ANY }, /* no effect */
	{ "notify",	'b',		OF_ANY },
	{ "nounset",	'u',		OF_ANY },
	{ "physical",	  0,		OF_ANY }, /* non-standard */
	{ "pipefail",	  0,		OF_ANY }, /* non-standard */
	{ "posix",	  0,		OF_ANY }, /* non-standard */
	{ "privileged",	'p',		OF_ANY },
	{ "restricted",	'r',	    OF_CMDLINE },
	{ "sh",		  0,		OF_ANY }, /* non-standard */
	{ "stdin",	's',	    OF_CMDLINE }, /* pseudo non-standard */
	{ "trackall",	'h',		OF_ANY },
	{ "verbose",	'v',		OF_ANY },
	{ "vi",		  0,		OF_ANY },
	{ "viraw",	  0,		OF_ANY }, /* no effect */
	{ "vi-show8",	  0,		OF_ANY }, /* non-standard */
	{ "vi-tabcomplete",  0,		OF_ANY }, /* non-standard */
	{ "vi-esccomplete",  0,		OF_ANY }, /* non-standard */
	{ "xtrace",	'x',		OF_ANY },
	/* Anonymous flags: used internally by shell only
	 * (not visible to user)
	 */
	{ NULL,	0,		OF_INTERNAL }, /* FTALKING_I */
};

/*
 * translate -o option into F* constant (also used for test -o option)
 */
int
option(const char *n)
{
	unsigned int ele;

	for (ele = 0; ele < NELEM(sh_options); ele++)
		if (sh_options[ele].name && strcmp(sh_options[ele].name, n) == 0)
			return ele;

	return -1;
}

struct options_info {
	int opt_width;
	struct {
		const char *name;
		int	flag;
	} opts[NELEM(sh_options)];
};

static char *options_fmt_entry(void *arg, int i, char *buf, int buflen);
static void printoptions(int verbose);

/* format a single select menu item */
static char *
options_fmt_entry(void *arg, int i, char *buf, int buflen)
{
	struct options_info *oi = (struct options_info *) arg;

	shf_snprintf(buf, buflen, "%-*s %s",
	    oi->opt_width, oi->opts[i].name,
	    Flag(oi->opts[i].flag) ? "on" : "off");
	return buf;
}

static void
printoptions(int verbose)
{
	unsigned int ele;

	if (verbose) {
		struct options_info oi;
		unsigned int n;
		int len;

		/* verbose version */
		shprintf("Current option settings\n");

		for (ele = n = oi.opt_width = 0; ele < NELEM(sh_options); ele++) {
			if (sh_options[ele].name) {
				len = strlen(sh_options[ele].name);
				oi.opts[n].name = sh_options[ele].name;
				oi.opts[n++].flag = ele;
				if (len > oi.opt_width)
					oi.opt_width = len;
			}
		}
		print_columns(shl_stdout, n, options_fmt_entry, &oi,
		    oi.opt_width + 5, 1);
	} else {
		/* short version ala ksh93 */
		shprintf("set");
		for (ele = 0; ele < NELEM(sh_options); ele++) {
			if (sh_options[ele].name)
				shprintf(" %co %s",
					 Flag(ele) ? '-' : '+',
					 sh_options[ele].name);
		}
		shprintf("\n");
	}
}

char *
getoptions(void)
{
	unsigned int ele;
	char m[(int) FNFLAGS + 1];
	char *cp = m;

	for (ele = 0; ele < NELEM(sh_options); ele++)
		if (sh_options[ele].c && Flag(ele))
			*cp++ = sh_options[ele].c;
	*cp = 0;
	return str_save(m, ATEMP);
}

/* change a Flag(*) value; takes care of special actions */
void
change_flag(enum sh_flag f,
    int what,		/* flag to change */
    int newval)		/* what is changing the flag (command line vs set) */
{
	int oldval;

	oldval = Flag(f);
	Flag(f) = newval;
	if (f == FMONITOR) {
		if (what != OF_CMDLINE && newval != oldval)
			j_change();
	} else
	if (0
	    || f == FVI
	    || f == FEMACS || f == FGMACS
	   )
	{
		if (newval) {
			Flag(FVI) = 0;
			Flag(FEMACS) = Flag(FGMACS) = 0;
			Flag(f) = newval;
		}
	} else
	/* Turning off -p? */
	if (f == FPRIVILEGED && oldval && !newval && sh_issetugid() &&
	    !dropped_privileges) {
		gid_t gid = getgid();

		setresgid(gid, gid, gid);
		setgroups(1, &gid);
		setresuid(ksheuid, ksheuid, ksheuid);

		if (pledge("stdio rpath wpath cpath fattr flock getpw proc "
		    "exec tty", NULL) == -1)
			bi_errorf("pledge fail");

		dropped_privileges = 1;
	} else if (f == FPOSIX && newval) {
		Flag(FBRACEEXPAND) = 0;
	}
	/* Changing interactive flag? */
	if (f == FTALKING) {
		if ((what == OF_CMDLINE || what == OF_SET) && procpid == kshpid)
			Flag(FTALKING_I) = newval;
	}
}

/* parse command line & set command arguments.  returns the index of
 * non-option arguments, -1 if there is an error.
 */
int
parse_args(char **argv,
    int what,			/* OF_CMDLINE or OF_SET */
    int *setargsp)
{
	static char cmd_opts[NELEM(sh_options) + 3]; /* o:\0 */
	static char set_opts[NELEM(sh_options) + 5]; /* Ao;s\0 */
	char *opts;
	char *array = NULL;
	Getopt go;
	int i, optc, sortargs = 0, arrayset = 0;
	unsigned int ele;

	/* First call?  Build option strings... */
	if (cmd_opts[0] == '\0') {
		char *p, *q;

		/* see cmd_opts[] declaration */
		strlcpy(cmd_opts, "o:", sizeof cmd_opts);
		p = cmd_opts + strlen(cmd_opts);
		/* see set_opts[] declaration */
		strlcpy(set_opts, "A:o;s", sizeof set_opts);
		q = set_opts + strlen(set_opts);
		for (ele = 0; ele < NELEM(sh_options); ele++) {
			if (sh_options[ele].c) {
				if (sh_options[ele].flags & OF_CMDLINE)
					*p++ = sh_options[ele].c;
				if (sh_options[ele].flags & OF_SET)
					*q++ = sh_options[ele].c;
			}
		}
		*p = '\0';
		*q = '\0';
	}

	if (what == OF_CMDLINE) {
		char *p;
		/* Set FLOGIN before parsing options so user can clear
		 * flag using +l.
		 */
		Flag(FLOGIN) = (argv[0][0] == '-' ||
		    ((p = strrchr(argv[0], '/')) && *++p == '-'));
		opts = cmd_opts;
	} else
		opts = set_opts;
	ksh_getopt_reset(&go, GF_ERROR|GF_PLUSOPT);
	while ((optc = ksh_getopt(argv, &go, opts)) != -1) {
		int set = (go.info & GI_PLUS) ? 0 : 1;
		switch (optc) {
		case 'A':
			arrayset = set ? 1 : -1;
			array = go.optarg;
			break;

		case 'o':
			if (go.optarg == NULL) {
				/* lone -o: print options
				 *
				 * Note that on the command line, -o requires
				 * an option (ie, can't get here if what is
				 * OF_CMDLINE).
				 */
				printoptions(set);
				break;
			}
			i = option(go.optarg);
			if (i != -1 && set == Flag(i))
				/* Don't check the context if the flag
				 * isn't changing - makes "set -o interactive"
				 * work if you're already interactive.  Needed
				 * if the output of "set +o" is to be used.
				 */
				;
			else if (i != -1 && (sh_options[i].flags & what))
				change_flag((enum sh_flag) i, what, set);
			else {
				bi_errorf("%s: bad option", go.optarg);
				return -1;
			}
			break;

		case '?':
			return -1;

		default:
			/* -s: sort positional params (at&t ksh stupidity) */
			if (what == OF_SET && optc == 's') {
				sortargs = 1;
				break;
			}
			for (ele = 0; ele < NELEM(sh_options); ele++)
				if (optc == sh_options[ele].c &&
				    (what & sh_options[ele].flags)) {
					change_flag((enum sh_flag) ele, what,
					    set);
					break;
				}
			if (ele == NELEM(sh_options)) {
				internal_errorf("%s: `%c'", __func__, optc);
				return -1; /* not reached */
			}
		}
	}
	if (!(go.info & GI_MINUSMINUS) && argv[go.optind] &&
	    (argv[go.optind][0] == '-' || argv[go.optind][0] == '+') &&
	    argv[go.optind][1] == '\0') {
		/* lone - clears -v and -x flags */
		if (argv[go.optind][0] == '-' && !Flag(FPOSIX))
			Flag(FVERBOSE) = Flag(FXTRACE) = 0;
		/* set skips lone - or + option */
		go.optind++;
	}
	if (setargsp)
		/* -- means set $#/$* even if there are no arguments */
		*setargsp = !arrayset && ((go.info & GI_MINUSMINUS) ||
		    argv[go.optind]);

	if (arrayset && (!*array || *skip_varname(array, false))) {
		bi_errorf("%s: is not an identifier", array);
		return -1;
	}
	if (sortargs) {
		for (i = go.optind; argv[i]; i++)
			;
		qsortp((void **) &argv[go.optind], (size_t) (i - go.optind),
		    xstrcmp);
	}
	if (arrayset) {
		set_array(array, arrayset, argv + go.optind);
		for (; argv[go.optind]; go.optind++)
			;
	}

	return go.optind;
}

/* parse a decimal number: returns 0 if string isn't a number, 1 otherwise */
int
getn(const char *as, int *ai)
{
	char *p;
	long n;

	n = strtol(as, &p, 10);

	if (!*as || *p || INT_MIN >= n || n >= INT_MAX)
		return 0;

	*ai = (int)n;
	return 1;
}

/* getn() that prints error */
int
bi_getn(const char *as, int *ai)
{
	int rv = getn(as, ai);

	if (!rv)
		bi_errorf("%s: bad number", as);
	return rv;
}

/* -------- gmatch.c -------- */

/*
 * int gmatch(string, pattern)
 * char *string, *pattern;
 *
 * Match a pattern as in sh(1).
 * pattern character are prefixed with MAGIC by expand.
 */

int
gmatch_(const char *s, const char *p, int isfile)
{
	const char *se, *pe;

	if (s == NULL || p == NULL)
		return 0;
	se = s + strlen(s);
	pe = p + strlen(p);
	/* isfile is false iff no syntax check has been done on
	 * the pattern.  If check fails, just to a strcmp().
	 */
	if (!isfile && !has_globbing(p, pe)) {
		size_t len = pe - p + 1;
		char tbuf[64];
		char *t = len <= sizeof(tbuf) ? tbuf :
		    alloc(len, ATEMP);
		debunk(t, p, len);
		return !strcmp(t, s);
	}
	return do_gmatch((const unsigned char *) s, (const unsigned char *) se,
	    (const unsigned char *) p, (const unsigned char *) pe);
}

/* Returns if p is a syntacticly correct globbing pattern, false
 * if it contains no pattern characters or if there is a syntax error.
 * Syntax errors are:
 *	- [ with no closing ]
 *	- imbalanced $(...) expression
 *	- [...] and *(...) not nested (eg, [a$(b|]c), *(a[b|c]d))
 */
/*XXX
- if no magic,
	if dest given, copy to dst
	return ?
- if magic && (no globbing || syntax error)
	debunk to dst
	return ?
- return ?
*/
int
has_globbing(const char *xp, const char *xpe)
{
	const unsigned char *p = (const unsigned char *) xp;
	const unsigned char *pe = (const unsigned char *) xpe;
	int c;
	int nest = 0, bnest = 0;
	int saw_glob = 0;
	int in_bracket = 0; /* inside [...] */

	for (; p < pe; p++) {
		if (!ISMAGIC(*p))
			continue;
		if ((c = *++p) == '*' || c == '?')
			saw_glob = 1;
		else if (c == '[') {
			if (!in_bracket) {
				saw_glob = 1;
				in_bracket = 1;
				if (ISMAGIC(p[1]) && p[2] == '!')
					p += 2;
				if (ISMAGIC(p[1]) && p[2] == ']')
					p += 2;
			}
			/* XXX Do we need to check ranges here? POSIX Q */
		} else if (c == ']') {
			if (in_bracket) {
				if (bnest)		/* [a*(b]) */
					return 0;
				in_bracket = 0;
			}
		} else if ((c & 0x80) && strchr("*+?@! ", c & 0x7f)) {
			saw_glob = 1;
			if (in_bracket)
				bnest++;
			else
				nest++;
		} else if (c == '|') {
			if (in_bracket && !bnest)	/* *(a[foo|bar]) */
				return 0;
		} else if (c == /*(*/ ')') {
			if (in_bracket) {
				if (!bnest--)		/* *(a[b)c] */
					return 0;
			} else if (nest)
				nest--;
		}
		/* else must be a MAGIC-MAGIC, or MAGIC-!, MAGIC--, MAGIC-]
			 MAGIC-{, MAGIC-,, MAGIC-} */
	}
	return saw_glob && !in_bracket && !nest;
}

/* Function must return either 0 or 1 (assumed by code for 0x80|'!') */
static int
do_gmatch(const unsigned char *s, const unsigned char *se,
    const unsigned char *p, const unsigned char *pe)
{
	int sc, pc;
	const unsigned char *prest, *psub, *pnext;
	const unsigned char *srest;

	if (s == NULL || p == NULL)
		return 0;
	while (p < pe) {
		pc = *p++;
		sc = s < se ? *s : '\0';
		s++;
		if (!ISMAGIC(pc)) {
			if (sc != pc)
				return 0;
			continue;
		}
		switch (*p++) {
		case '[':
			if (sc == 0 || (p = cclass(p, sc)) == NULL)
				return 0;
			break;

		case '?':
			if (sc == 0)
				return 0;
			break;

		case '*':
			/* collapse consecutive stars */
			while (ISMAGIC(p[0]) && p[1] == '*')
				p += 2;
			if (p == pe)
				return 1;
			s--;
			do {
				if (do_gmatch(s, se, p, pe))
					return 1;
			} while (s++ < se);
			return 0;

		  /*
		   * [*+?@!](pattern|pattern|..)
		   *
		   * Not ifdef'd KSH as this is needed for ${..%..}, etc.
		   */
		case 0x80|'+': /* matches one or more times */
		case 0x80|'*': /* matches zero or more times */
			if (!(prest = pat_scan(p, pe, 0)))
				return 0;
			s--;
			/* take care of zero matches */
			if (p[-1] == (0x80 | '*') &&
			    do_gmatch(s, se, prest, pe))
				return 1;
			for (psub = p; ; psub = pnext) {
				pnext = pat_scan(psub, pe, 1);
				for (srest = s; srest <= se; srest++) {
					if (do_gmatch(s, srest, psub, pnext - 2) &&
					    (do_gmatch(srest, se, prest, pe) ||
					    (s != srest && do_gmatch(srest,
					    se, p - 2, pe))))
						return 1;
				}
				if (pnext == prest)
					break;
			}
			return 0;

		case 0x80|'?': /* matches zero or once */
		case 0x80|'@': /* matches one of the patterns */
		case 0x80|' ': /* simile for @ */
			if (!(prest = pat_scan(p, pe, 0)))
				return 0;
			s--;
			/* Take care of zero matches */
			if (p[-1] == (0x80 | '?') &&
			    do_gmatch(s, se, prest, pe))
				return 1;
			for (psub = p; ; psub = pnext) {
				pnext = pat_scan(psub, pe, 1);
				srest = prest == pe ? se : s;
				for (; srest <= se; srest++) {
					if (do_gmatch(s, srest, psub, pnext - 2) &&
					    do_gmatch(srest, se, prest, pe))
						return 1;
				}
				if (pnext == prest)
					break;
			}
			return 0;

		case 0x80|'!': /* matches none of the patterns */
			if (!(prest = pat_scan(p, pe, 0)))
				return 0;
			s--;
			for (srest = s; srest <= se; srest++) {
				int matched = 0;

				for (psub = p; ; psub = pnext) {
					pnext = pat_scan(psub, pe, 1);
					if (do_gmatch(s, srest, psub,
					    pnext - 2)) {
						matched = 1;
						break;
					}
					if (pnext == prest)
						break;
				}
				if (!matched &&
				    do_gmatch(srest, se, prest, pe))
					return 1;
			}
			return 0;

		default:
			if (sc != p[-1])
				return 0;
			break;
		}
	}
	return s == se;
}

static int
posix_cclass(const unsigned char *pattern, int test, const unsigned char **ep)
{
	const struct cclass *cc;
	const unsigned char *colon;
	size_t len;
	int rval = 0;

	if ((colon = strchr(pattern, ':')) == NULL || colon[1] != MAGIC) {
		*ep = pattern - 2;
		return -1;
	}
	*ep = colon + 3; /* skip MAGIC */
	len = (size_t)(colon - pattern);

	for (cc = cclasses; cc->name != NULL; cc++) {
		if (!strncmp(pattern, cc->name, len) && cc->name[len] == '\0') {
			if (cc->isctype(test))
				rval = 1;
			break;
		}
	}
	if (cc->name == NULL) {
		rval = -2;	/* invalid character class */
	}
	return rval;
}

static const unsigned char *
cclass(const unsigned char *p, int sub)
{
	int c, d, rv, not, found = 0;
	const unsigned char *orig_p = p;

	if ((not = (ISMAGIC(*p) && *++p == '!')))
		p++;
	do {
		/* check for POSIX character class (e.g. [[:alpha:]]) */
		if ((p[0] == MAGIC && p[1] == '[' && p[2] == ':') ||
		    (p[0] == '[' && p[1] == ':')) {
			do {
				const char *pp = p + (*p == MAGIC) + 2;
				rv = posix_cclass(pp, sub, &p);
				switch (rv) {
				case 1:
					found = 1;
					break;
				case -2:
					return NULL;
				}
			} while (rv != -1 && p[0] == MAGIC && p[1] == '[' && p[2] == ':');
			if (p[0] == MAGIC && p[1] == ']')
				break;
		}

		c = *p++;
		if (ISMAGIC(c)) {
			c = *p++;
			if ((c & 0x80) && !ISMAGIC(c)) {
				c &= 0x7f;/* extended pattern matching: *+?@! */
				/* XXX the ( char isn't handled as part of [] */
				if (c == ' ') /* simile for @: plain (..) */
					c = '(' /*)*/;
			}
		}
		if (c == '\0')
			/* No closing ] - act as if the opening [ was quoted */
			return sub == '[' ? orig_p : NULL;
		if (ISMAGIC(p[0]) && p[1] == '-' &&
		    (!ISMAGIC(p[2]) || p[3] != ']')) {
			p += 2; /* MAGIC- */
			d = *p++;
			if (ISMAGIC(d)) {
				d = *p++;
				if ((d & 0x80) && !ISMAGIC(d))
					d &= 0x7f;
			}
			/* POSIX says this is an invalid expression */
			if (c > d)
				return NULL;
		} else
			d = c;
		if (c == sub || (c <= sub && sub <= d))
			found = 1;
	} while (!(ISMAGIC(p[0]) && p[1] == ']'));

	return (found != not) ? p+2 : NULL;
}

/* Look for next ) or | (if match_sep) in *(foo|bar) pattern */
const unsigned char *
pat_scan(const unsigned char *p, const unsigned char *pe, int match_sep)
{
	int nest = 0;

	for (; p < pe; p++) {
		if (!ISMAGIC(*p))
			continue;
		if ((*++p == /*(*/ ')' && nest-- == 0) ||
		    (*p == '|' && match_sep && nest == 0))
			return ++p;
		if ((*p & 0x80) && strchr("*+?@! ", *p & 0x7f))
			nest++;
	}
	return NULL;
}

/*
 * quick sort of array of generic pointers to objects.
 */
void
qsortp(void **base,			/* base address */
    size_t n,				/* elements */
    int (*f) (const void *, const void *)) /* compare function */
{
	qsort(base, n, sizeof(char *), f);
}

int
xstrcmp(const void *p1, const void *p2)
{
	return (strcmp(*(char **)p1, *(char **)p2));
}

/* Initialize a Getopt structure */
void
ksh_getopt_reset(Getopt *go, int flags)
{
	go->optind = 1;
	go->optarg = NULL;
	go->p = 0;
	go->flags = flags;
	go->info = 0;
	go->buf[1] = '\0';
}


/* getopt() used for shell built-in commands, the getopts command, and
 * command line options.
 * A leading ':' in options means don't print errors, instead return '?'
 * or ':' and set go->optarg to the offending option character.
 * If GF_ERROR is set (and option doesn't start with :), errors result in
 * a call to bi_errorf().
 *
 * Non-standard features:
 *	- ';' is like ':' in options, except the argument is optional
 *	  (if it isn't present, optarg is set to 0).
 *	  Used for 'set -o'.
 *	- ',' is like ':' in options, except the argument always immediately
 *	  follows the option character (optarg is set to the null string if
 *	  the option is missing).
 *	  Used for 'read -u2', 'print -u2' and fc -40.
 *	- '#' is like ':' in options, expect that the argument is optional
 *	  and must start with a digit or be the string "unlimited".  If the
 *	  argument doesn't match, it is assumed to be missing and normal option
 *	  processing continues (optarg is set to 0 if the option is missing).
 *	  Used for 'typeset -LZ4' and 'ulimit -adunlimited'.
 *	- accepts +c as well as -c IF the GF_PLUSOPT flag is present.  If an
 *	  option starting with + is accepted, the GI_PLUS flag will be set
 *	  in go->info.
 */
int
ksh_getopt(char **argv, Getopt *go, const char *options)
{
	char c;
	char *o;

	if (go->p == 0 || (c = argv[go->optind - 1][go->p]) == '\0') {
		char *arg = argv[go->optind], flag = arg ? *arg : '\0';

		go->p = 1;
		if (flag == '-' && arg[1] == '-' && arg[2] == '\0') {
			go->optind++;
			go->p = 0;
			go->info |= GI_MINUSMINUS;
			return -1;
		}
		if (arg == NULL ||
		    ((flag != '-' ) && /* neither a - nor a + (if + allowed) */
		    (!(go->flags & GF_PLUSOPT) || flag != '+')) ||
		    (c = arg[1]) == '\0') {
			go->p = 0;
			return -1;
		}
		go->optind++;
		go->info &= ~(GI_MINUS|GI_PLUS);
		go->info |= flag == '-' ? GI_MINUS : GI_PLUS;
	}
	go->p++;
	if (c == '?' || c == ':' || c == ';' || c == ',' || c == '#' ||
	    !(o = strchr(options, c))) {
		if (options[0] == ':') {
			go->buf[0] = c;
			go->optarg = go->buf;
		} else {
			warningf(false, "%s%s-%c: unknown option",
			    (go->flags & GF_NONAME) ? "" : argv[0],
			    (go->flags & GF_NONAME) ? "" : ": ", c);
			if (go->flags & GF_ERROR)
				bi_errorf(NULL);
		}
		return '?';
	}
	/* : means argument must be present, may be part of option argument
	 *   or the next argument
	 * ; same as : but argument may be missing
	 * , means argument is part of option argument, and may be null.
	 */
	if (*++o == ':' || *o == ';') {
		if (argv[go->optind - 1][go->p])
			go->optarg = argv[go->optind - 1] + go->p;
		else if (argv[go->optind])
			go->optarg = argv[go->optind++];
		else if (*o == ';')
			go->optarg = NULL;
		else {
			if (options[0] == ':') {
				go->buf[0] = c;
				go->optarg = go->buf;
				return ':';
			}
			warningf(false, "%s%s-`%c' requires argument",
			    (go->flags & GF_NONAME) ? "" : argv[0],
			    (go->flags & GF_NONAME) ? "" : ": ", c);
			if (go->flags & GF_ERROR)
				bi_errorf(NULL);
			return '?';
		}
		go->p = 0;
	} else if (*o == ',') {
		/* argument is attached to option character, even if null */
		go->optarg = argv[go->optind - 1] + go->p;
		go->p = 0;
	} else if (*o == '#') {
		/* argument is optional and may be attached or unattached
		 * but must start with a digit.  optarg is set to 0 if the
		 * argument is missing.
		 */
		if (argv[go->optind - 1][go->p]) {
			if (digit(argv[go->optind - 1][go->p]) ||
			    !strcmp(&argv[go->optind - 1][go->p], "unlimited")) {
				go->optarg = argv[go->optind - 1] + go->p;
				go->p = 0;
			} else
				go->optarg = NULL;
		} else {
			if (argv[go->optind] && (digit(argv[go->optind][0]) ||
			    !strcmp(argv[go->optind], "unlimited"))) {
				go->optarg = argv[go->optind++];
				go->p = 0;
			} else
				go->optarg = NULL;
		}
	}
	return c;
}

/* print variable/alias value using necessary quotes
 * (POSIX says they should be suitable for re-entry...)
 * No trailing newline is printed.
 */
void
print_value_quoted(const char *s)
{
	const char *p;
	int inquote = 0;

	/* Test if any quotes are needed */
	for (p = s; *p; p++)
		if (ctype(*p, C_QUOTE))
			break;
	if (!*p) {
		shprintf("%s", s);
		return;
	}
	for (p = s; *p; p++) {
		if (*p == '\'') {
			shprintf(inquote ? "'\\'" : "\\'");
			inquote = 0;
		} else {
			if (!inquote) {
				shprintf("'");
				inquote = 1;
			}
			shf_putc(*p, shl_stdout);
		}
	}
	if (inquote)
		shprintf("'");
}

/* Print things in columns and rows - func() is called to format the ith
 * element
 */
void
print_columns(struct shf *shf, int n, char *(*func) (void *, int, char *, int),
    void *arg, int max_width, int prefcol)
{
	char *str = alloc(max_width + 1, ATEMP);
	int i;
	int r, c;
	int rows, cols;
	int nspace;
	int col_width;

	/* max_width + 1 for the space.  Note that no space
	 * is printed after the last column to avoid problems
	 * with terminals that have auto-wrap.
	 */
	cols = x_cols / (max_width + 1);
	if (!cols)
		cols = 1;
	rows = (n + cols - 1) / cols;
	if (prefcol && n && cols > rows) {
		int tmp = rows;

		rows = cols;
		cols = tmp;
		if (rows > n)
			rows = n;
	}

	col_width = max_width;
	if (cols == 1)
		col_width = 0; /* Don't pad entries in single column output. */
	nspace = (x_cols - max_width * cols) / cols;
	if (nspace <= 0)
		nspace = 1;
	for (r = 0; r < rows; r++) {
		for (c = 0; c < cols; c++) {
			i = c * rows + r;
			if (i < n) {
				shf_fprintf(shf, "%-*s",
				    col_width,
				    (*func)(arg, i, str, max_width + 1));
				if (c + 1 < cols)
					shf_fprintf(shf, "%*s", nspace, "");
			}
		}
		shf_putchar('\n', shf);
	}
	afree(str, ATEMP);
}

/* Strip any nul bytes from buf - returns new length (nbytes - # of nuls) */
int
strip_nuls(char *buf, int nbytes)
{
	char *dst;

	if ((dst = memchr(buf, '\0', nbytes))) {
		char *end = buf + nbytes;
		char *p, *q;

		for (p = dst; p < end; p = q) {
			/* skip a block of nulls */
			while (++p < end && *p == '\0')
				;
			/* find end of non-null block */
			if (!(q = memchr(p, '\0', end - p)))
				q = end;
			memmove(dst, p, q - p);
			dst += q - p;
		}
		*dst = '\0';
		return dst - buf;
	}
	return nbytes;
}

/* Like read(2), but if read fails due to non-blocking flag, resets flag
 * and restarts read.
 */
int
blocking_read(int fd, char *buf, int nbytes)
{
	int ret;
	int tried_reset = 0;

	while ((ret = read(fd, buf, nbytes)) == -1) {
		if (!tried_reset && errno == EAGAIN) {
			int oerrno = errno;
			if (reset_nonblock(fd) > 0) {
				tried_reset = 1;
				continue;
			}
			errno = oerrno;
		}
		break;
	}
	return ret;
}

/* Reset the non-blocking flag on the specified file descriptor.
 * Returns -1 if there was an error, 0 if non-blocking wasn't set,
 * 1 if it was.
 */
int
reset_nonblock(int fd)
{
	int flags;

	if ((flags = fcntl(fd, F_GETFL)) == -1)
		return -1;
	if (!(flags & O_NONBLOCK))
		return 0;
	flags &= ~O_NONBLOCK;
	if (fcntl(fd, F_SETFL, flags) == -1)
		return -1;
	return 1;
}


/* Like getcwd(), except bsize is ignored if buf is 0 (PATH_MAX is used) */
char *
ksh_get_wd(char *buf, int bsize)
{
	char *b;
	char *ret;

	/* Note: we could just use plain getcwd(), but then we'd had to
	 * inject possibly allocated space into the ATEMP area. */
	/* Assume getcwd() available */
	if (!buf) {
		bsize = PATH_MAX;
		b = alloc(bsize, ATEMP);
	} else
		b = buf;

	ret = getcwd(b, bsize);

	if (!buf) {
		if (ret)
			ret = aresize(b, strlen(b) + 1, ATEMP);
		else
			afree(b, ATEMP);
	}

	return ret;
}

/*
 * Path name manipulation and $PATH searching
 */

/* Like basename(3), but never modifies or allocates. */
const char *
sh_basename(const char *path)
{
	const char *s = strrchr(path, '/');

	if (s == NULL)
		return path;
	return s[1] != '\0' ? s + 1 : "/";
}

/*
 *	Contains a routine to search a : separated list of
 *	paths (a la CDPATH) and make appropriate file names.
 *	Also contains a routine to simplify .'s and ..'s out of
 *	a path name.
 *
 *	Larry Bouzane (larry@cs.mun.ca)
 */

static char	*do_phys_path(XString *, char *, const char *);

/*
 *	Makes a filename into result using the following algorithm.
 *	- make result NULL
 *	- if file starts with '/', append file to result & set cdpathp to NULL
 *	- if file starts with ./ or ../ append cwd and file to result
 *	  and set cdpathp to NULL
 *	- if the first element of cdpathp doesnt start with a '/' xx or '.' xx
 *	  then cwd is appended to result.
 *	- the first element of cdpathp is appended to result
 *	- file is appended to result
 *	- cdpathp is set to the start of the next element in cdpathp (or NULL
 *	  if there are no more elements.
 *	The return value indicates whether a non-null element from cdpathp
 *	was appended to result.
 */
int
make_path(const char *cwd, const char *file,
    char **cdpathp,		/* & of : separated list */
    XString *xsp,
    int *phys_pathp)
{
	int	rval = 0;
	int	use_cdpath = 1;
	char	*plist;
	int	len;
	int	plen = 0;
	char	*xp = Xstring(*xsp, xp);

	if (!file)
		file = null;

	if (file[0] == '/') {
		*phys_pathp = 0;
		use_cdpath = 0;
	} else {
		if (file[0] == '.') {
			char c = file[1];

			if (c == '.')
				c = file[2];
			if (c == '/' || c == '\0')
				use_cdpath = 0;
		}

		plist = *cdpathp;
		if (!plist)
			use_cdpath = 0;
		else if (use_cdpath) {
			char *pend;

			for (pend = plist; *pend && *pend != ':'; pend++)
				;
			plen = pend - plist;
			*cdpathp = *pend ? ++pend : NULL;
		}

		if ((use_cdpath == 0 || !plen || plist[0] != '/') &&
		    (cwd && *cwd)) {
			len = strlen(cwd);
			XcheckN(*xsp, xp, len);
			memcpy(xp, cwd, len);
			xp += len;
			if (cwd[len - 1] != '/')
				Xput(*xsp, xp, '/');
		}
		*phys_pathp = Xlength(*xsp, xp);
		if (use_cdpath && plen) {
			XcheckN(*xsp, xp, plen);
			memcpy(xp, plist, plen);
			xp += plen;
			if (plist[plen - 1] != '/')
				Xput(*xsp, xp, '/');
			rval = 1;
		}
	}

	len = strlen(file) + 1;
	XcheckN(*xsp, xp, len);
	memcpy(xp, file, len);

	if (!use_cdpath)
		*cdpathp = NULL;

	return rval;
}

/*
 * Simplify pathnames containing "." and ".." entries.
 * ie, simplify_path("/a/b/c/./../d/..") returns "/a/b"
 */
void
simplify_path(char *path)
{
	char	*cur;
	char	*t;
	int	isrooted;
	char	*very_start = path;
	char	*start;

	if (!*path)
		return;

	if ((isrooted = (path[0] == '/')))
		very_start++;

	/* Before			After
	 *  /foo/			/foo
	 *  /foo/../../bar		/bar
	 *  /foo/./blah/..		/foo
	 *  .				.
	 *  ..				..
	 *  ./foo			foo
	 *  foo/../../../bar		../../bar
	 */

	for (cur = t = start = very_start; ; ) {
		/* treat multiple '/'s as one '/' */
		while (*t == '/')
			t++;

		if (*t == '\0') {
			if (cur == path)
				/* convert empty path to dot */
				*cur++ = '.';
			*cur = '\0';
			break;
		}

		if (t[0] == '.') {
			if (!t[1] || t[1] == '/') {
				t += 1;
				continue;
			} else if (t[1] == '.' && (!t[2] || t[2] == '/')) {
				if (!isrooted && cur == start) {
					if (cur != very_start)
						*cur++ = '/';
					*cur++ = '.';
					*cur++ = '.';
					start = cur;
				} else if (cur != start)
					while (--cur > start && *cur != '/')
						;
				t += 2;
				continue;
			}
		}

		if (cur != very_start)
			*cur++ = '/';

		/* find/copy next component of pathname */
		while (*t && *t != '/')
			*cur++ = *t++;
	}
}


void
set_current_wd(char *path)
{
	int len;
	char *p = path;

	if (!p && !(p = ksh_get_wd(NULL, 0)))
		p = null;

	len = strlen(p) + 1;

	if (len > current_wd_size)
		current_wd = aresize(current_wd, current_wd_size = len, APERM);
	memcpy(current_wd, p, len);
	if (p != path && p != null)
		afree(p, ATEMP);
}

char *
get_phys_path(const char *path)
{
	XString xs;
	char *xp;

	Xinit(xs, xp, strlen(path) + 1, ATEMP);

	xp = do_phys_path(&xs, xp, path);

	if (!xp)
		return NULL;

	if (Xlength(xs, xp) == 0)
		Xput(xs, xp, '/');
	Xput(xs, xp, '\0');

	return Xclose(xs, xp);
}

static char *
do_phys_path(XString *xsp, char *xp, const char *path)
{
	const char *p, *q;
	int len, llen;
	int savepos;
	char lbuf[PATH_MAX];

	Xcheck(*xsp, xp);
	for (p = path; p; p = q) {
		while (*p == '/')
			p++;
		if (!*p)
			break;
		len = (q = strchr(p, '/')) ? (size_t)(q - p) : strlen(p);
		if (len == 1 && p[0] == '.')
			continue;
		if (len == 2 && p[0] == '.' && p[1] == '.') {
			while (xp > Xstring(*xsp, xp)) {
				xp--;
				if (*xp == '/')
					break;
			}
			continue;
		}

		savepos = Xsavepos(*xsp, xp);
		Xput(*xsp, xp, '/');
		XcheckN(*xsp, xp, len + 1);
		memcpy(xp, p, len);
		xp += len;
		*xp = '\0';

		llen = readlink(Xstring(*xsp, xp), lbuf, sizeof(lbuf) - 1);
		if (llen == -1) {
			/* EINVAL means it wasn't a symlink... */
			if (errno != EINVAL)
				return NULL;
			continue;
		}
		lbuf[llen] = '\0';

		/* If absolute path, start from scratch.. */
		xp = lbuf[0] == '/' ? Xstring(*xsp, xp) :
		    Xrestpos(*xsp, xp, savepos);
		if (!(xp = do_phys_path(xsp, xp, lbuf)))
			return NULL;
	}
	return xp;
}

/*
 * $MAIL, $MAILPATH and $MAILCHECK
 */

/*
 * Mailbox checking code by Robert J. Gibson, adapted for PD ksh by
 * John R. MacMillan
 */




#define MBMESSAGE	"you have mail in $_"

typedef struct mbox {
	struct mbox    *mb_next;	/* next mbox in list */
	char	       *mb_path;	/* path to mail file */
	char	       *mb_msg;		/* to announce arrival of new mail */
	time_t		mb_mtime;	/* mtime of mail file */
} mbox_t;

/*
 * $MAILPATH is a linked list of mboxes.  $MAIL is a treated as a
 * special case of $MAILPATH, where the list has only one node.  The
 * same list is used for both since they are exclusive.
 */

static mbox_t	*mplist;
static mbox_t	mbox;
static struct	timespec mlastchkd;	/* when mail was last checked */
static time_t	mailcheck_interval;

static void	munset(mbox_t *); /* free mlist and mval */
static mbox_t * mballoc(char *, char *); /* allocate a new mbox */
static void	mprintit(mbox_t *);

void
mcheck(void)
{
	mbox_t		*mbp;
	struct timespec	 elapsed, now;
	struct tbl	*vp;
	struct stat	 stbuf;
	static int	 first = 1;

	if (mplist)
		mbp = mplist;
	else if ((vp = global("MAIL")) && (vp->flag & ISSET))
		mbp = &mbox;
	else
		mbp = NULL;
	if (mbp == NULL)
		return;

	clock_gettime(CLOCK_MONOTONIC, &now);
	if (first) {
		mlastchkd = now;
		first = 0;
	}
	timespecsub(&now, &mlastchkd, &elapsed);
	if (elapsed.tv_sec >= mailcheck_interval) {
		mlastchkd = now;

		while (mbp) {
			if (mbp->mb_path && stat(mbp->mb_path, &stbuf) == 0 &&
			    S_ISREG(stbuf.st_mode)) {
				if (stbuf.st_size &&
				    mbp->mb_mtime != stbuf.st_mtime &&
				    stbuf.st_atime <= stbuf.st_mtime)
					mprintit(mbp);
				mbp->mb_mtime = stbuf.st_mtime;
			} else {
				/*
				 * Some mail readers remove the mail
				 * file if all mail is read.  If file
				 * does not exist, assume this is the
				 * case and set mtime to zero.
				 */
				mbp->mb_mtime = 0;
			}
			mbp = mbp->mb_next;
		}
	}
}

void
mcset(int64_t interval)
{
	mailcheck_interval = interval;
}

void
mbset(char *p)
{
	struct stat	stbuf;

	afree(mbox.mb_msg, APERM);
	afree(mbox.mb_path, APERM);
	/* Save a copy to protect from export (which munges the string) */
	mbox.mb_path = str_save(p, APERM);
	mbox.mb_msg = NULL;
	if (p && stat(p, &stbuf) == 0 && S_ISREG(stbuf.st_mode))
		mbox.mb_mtime = stbuf.st_mtime;
	else
		mbox.mb_mtime = 0;
}

void
mpset(char *mptoparse)
{
	mbox_t	*mbp;
	char	*mpath, *mmsg, *mval;
	char *p;

	munset( mplist );
	mplist = NULL;
	mval = str_save(mptoparse, APERM);
	while (mval) {
		mpath = mval;
		if ((mval = strchr(mval, ':')) != NULL) {
			*mval = '\0';
			mval++;
		}
		/* POSIX/bourne-shell say file%message */
		for (p = mpath; (mmsg = strchr(p, '%')); ) {
			/* a literal percent? (POSIXism) */
			if (mmsg > mpath && mmsg[-1] == '\\') {
				/* use memmove() to avoid overlap problems */
				memmove(mmsg - 1, mmsg, strlen(mmsg) + 1);
				p = mmsg;
				continue;
			}
			break;
		}
		/* at&t ksh says file?message */
		if (!mmsg && !Flag(FPOSIX))
			mmsg = strchr(mpath, '?');
		if (mmsg) {
			*mmsg = '\0';
			mmsg++;
			if (*mmsg == '\0')
				mmsg = NULL;
		}
		if (*mpath == '\0')
			continue;
		mbp = mballoc(mpath, mmsg);
		mbp->mb_next = mplist;
		mplist = mbp;
	}
}

static void
munset(mbox_t *mlist)
{
	mbox_t	*mbp;

	while (mlist != NULL) {
		mbp = mlist;
		mlist = mbp->mb_next;
		if (!mlist)
			afree(mbp->mb_path, APERM);
		afree(mbp, APERM);
	}
}

static mbox_t *
mballoc(char *p, char *m)
{
	struct stat	stbuf;
	mbox_t	*mbp;

	mbp = alloc(sizeof(mbox_t), APERM);
	mbp->mb_next = NULL;
	mbp->mb_path = p;
	mbp->mb_msg = m;
	if (stat(mbp->mb_path, &stbuf) == 0 && S_ISREG(stbuf.st_mode))
		mbp->mb_mtime = stbuf.st_mtime;
	else
		mbp->mb_mtime = 0;
	return(mbp);
}

static void
mprintit(mbox_t *mbp)
{
	struct tbl	*vp;

#if 0
	/*
	 * I doubt this $_ overloading is bad in /bin/sh mode.  Anyhow, we
	 * crash as the code looks now if we do not set vp.  Now, this is
	 * easy to fix too, but I'd like to see what POSIX says before doing
	 * a change like that.
	 */
	if (!Flag(FSH))
#endif
		/* Ignore setstr errors here (arbitrary) */
		setstr((vp = local("_", false)), mbp->mb_path, KSH_RETURN_ERROR);

	shellf("%s\n", substitute(mbp->mb_msg ? mbp->mb_msg : MBMESSAGE, 0));

	unset(vp, 0);
}
