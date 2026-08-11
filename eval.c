/*
 * nextsh: variables, arithmetic and word expansion.
 */

/*
 * Shell variables and their special behaviour
 */

/*
 * Variables
 *
 * WARNING: unreadable code, needs a rewrite
 *
 * if (flag&INTEGER), val.i contains integer value, and type contains base.
 * otherwise, (val.s + type) contains string value.
 * if (flag&EXPORT), val.s contains "name=value" for E-Z exporting.
 */
static	struct tbl vtemp;
static	struct table specials;
static char	*formatstr(struct tbl *, const char *);
static void	export(struct tbl *, const char *);
static int	special(const char *);
static void	unspecial(const char *);
static void	getspec(struct tbl *);
static void	setspec(struct tbl *);
static void	unsetspec(struct tbl *);
static struct tbl *arraysearch(struct tbl *, int);

/*
 * create a new block for function calls and simple commands
 * assume caller has allocated and set up genv->loc
 */
void
newblock(void)
{
	struct block *l;
	static char *const empty[] = {null};

	l = alloc(sizeof(struct block), ATEMP);
	l->flags = 0;
	ainit(&l->area); /* todo: could use genv->area (l->area => l->areap) */
	if (!genv->loc) {
		l->argc = 0;
		l->argv = (char **) empty;
	} else {
		l->argc = genv->loc->argc;
		l->argv = genv->loc->argv;
	}
	l->exit = l->error = NULL;
	ktinit(&l->vars, &l->area, 0);
	ktinit(&l->funs, &l->area, 0);
	l->next = genv->loc;
	genv->loc = l;
}

/*
 * pop a block handling special variables
 */
void
popblock(void)
{
	struct block *l = genv->loc;
	struct tbl *vp, **vpp = l->vars.tbls, *vq;
	int i;

	genv->loc = l->next;	/* pop block */
	for (i = l->vars.size; --i >= 0; )
		if ((vp = *vpp++) != NULL && (vp->flag&SPECIAL)) {
			if ((vq = global(vp->name))->flag & ISSET)
				setspec(vq);
			else
				unsetspec(vq);
		}
	if (l->flags & BF_DOGETOPTS)
		user_opt = l->getopts_state;
	afreeall(&l->area);
	afree(l, ATEMP);
}

/* called by main() to initialize variable data structures */
void
initvar(void)
{
	static const struct {
		const char *name;
		int v;
	} names[] = {
		{ "COLUMNS",		V_COLUMNS },
		{ "IFS",		V_IFS },
		{ "OPTIND",		V_OPTIND },
		{ "PATH",		V_PATH },
		{ "POSIXLY_CORRECT",	V_POSIXLY_CORRECT },
		{ "TMPDIR",		V_TMPDIR },
		{ "HISTCONTROL",	V_HISTCONTROL },
		{ "HISTFILE",		V_HISTFILE },
		{ "HISTSIZE",		V_HISTSIZE },
		{ "EDITOR",		V_EDITOR },
		{ "VISUAL",		V_VISUAL },
		{ "MAIL",		V_MAIL },
		{ "MAILCHECK",		V_MAILCHECK },
		{ "MAILPATH",		V_MAILPATH },
		{ "RANDOM",		V_RANDOM },
		{ "SECONDS",		V_SECONDS },
		{ "TMOUT",		V_TMOUT },
		{ "LINENO",		V_LINENO },
		{ NULL,	0 }
	};
	int i;
	struct tbl *tp;

	ktinit(&specials, APERM, 32); /* must be 2^n (currently 19 specials) */
	for (i = 0; names[i].name; i++) {
		tp = ktenter(&specials, names[i].name, hash(names[i].name));
		tp->flag = DEFINED|ISSET;
		tp->type = names[i].v;
	}
}

/* Used to calculate an array index for global()/local().  Sets *arrayp to
 * non-zero if this is an array, sets *valp to the array index, returns
 * the basename of the array.
 */
static const char *
array_index_calc(const char *n, bool *arrayp, int *valp)
{
	const char *p;
	int len;

	*arrayp = false;
	p = skip_varname(n, false);
	if (p != n && *p == '[' && (len = array_ref_len(p))) {
		char *sub, *tmp;
		int64_t rval;

		/* Calculate the value of the subscript */
		*arrayp = true;
		tmp = str_nsave(p+1, len-2, ATEMP);
		sub = substitute(tmp, 0);
		afree(tmp, ATEMP);
		n = str_nsave(n, p - n, ATEMP);
		evaluate(sub, &rval, KSH_UNWIND_ERROR, true);
		if (rval < 0 || rval > INT_MAX)
			errorf("%s: subscript %" PRIi64 " out of range",
			    n, rval);
		*valp = rval;
		afree(sub, ATEMP);
	}
	return n;
}

/*
 * Search for variable, if not found create globally.
 */
struct tbl *
global(const char *n)
{
	struct block *l = genv->loc;
	struct tbl *vp;
	long	 num;
	int c;
	unsigned int h;
	bool	 array;
	int	 val;

	/* Check to see if this is an array */
	n = array_index_calc(n, &array, &val);
	h = hash(n);
	c = (unsigned char)n[0];
	if (!letter(c)) {
		if (array)
			errorf("bad substitution");
		vp = &vtemp;
		vp->flag = DEFINED;
		vp->type = 0;
		vp->areap = ATEMP;
		*vp->name = c;
		if (digit(c)) {
			errno = 0;
			num = strtol(n, NULL, 10);
			if (errno == 0 && num <= l->argc)
				/* setstr can't fail here */
				setstr(vp, l->argv[num], KSH_RETURN_ERROR);
			vp->flag |= RDONLY;
			return vp;
		}
		vp->flag |= RDONLY;
		if (n[1] != '\0')
			return vp;
		vp->flag |= ISSET|INTEGER;
		switch (c) {
		case '$':
			vp->val.i = kshpid;
			break;
		case '!':
			/* If no job, expand to nothing */
			if ((vp->val.i = j_async()) == 0)
				vp->flag &= ~(ISSET|INTEGER);
			break;
		case '?':
			vp->val.i = exstat;
			break;
		case '#':
			vp->val.i = l->argc;
			break;
		case '-':
			vp->flag &= ~INTEGER;
			vp->val.s = getoptions();
			break;
		default:
			vp->flag &= ~(ISSET|INTEGER);
		}
		return vp;
	}
	for (l = genv->loc; ; l = l->next) {
		vp = ktsearch(&l->vars, n, h);
		if (vp != NULL) {
			if (array)
				return arraysearch(vp, val);
			else
				return vp;
		}
		if (l->next == NULL)
			break;
	}
	vp = ktenter(&l->vars, n, h);
	if (array)
		vp = arraysearch(vp, val);
	vp->flag |= DEFINED;
	if (special(n))
		vp->flag |= SPECIAL;
	return vp;
}

/*
 * Search for local variable, if not found create locally.
 */
struct tbl *
local(const char *n, bool copy)
{
	struct block *l = genv->loc;
	struct tbl *vp;
	unsigned int h;
	bool	 array;
	int	 val;

	/* Check to see if this is an array */
	n = array_index_calc(n, &array, &val);
	h = hash(n);
	if (!letter(*n)) {
		vp = &vtemp;
		vp->flag = DEFINED|RDONLY;
		vp->type = 0;
		vp->areap = ATEMP;
		return vp;
	}
	vp = ktenter(&l->vars, n, h);
	if (copy && !(vp->flag & DEFINED)) {
		struct block *ll = l;
		struct tbl *vq = NULL;

		while ((ll = ll->next) && !(vq = ktsearch(&ll->vars, n, h)))
			;
		if (vq) {
			vp->flag |= vq->flag &
			    (EXPORT | INTEGER | RDONLY | LJUST | RJUST |
			    ZEROFIL | LCASEV | UCASEV_AL | INT_U | INT_L);
			if (vq->flag & INTEGER)
				vp->type = vq->type;
			vp->u2.field = vq->u2.field;
		}
	}
	if (array)
		vp = arraysearch(vp, val);
	vp->flag |= DEFINED;
	if (special(n))
		vp->flag |= SPECIAL;
	return vp;
}

/* get variable string value */
char *
str_val(struct tbl *vp)
{
	char *s;

	if ((vp->flag&SPECIAL))
		getspec(vp);
	if (!(vp->flag&ISSET))
		s = null;		/* special to dollar() */
	else if (!(vp->flag&INTEGER))	/* string source */
		s = vp->val.s + vp->type;
	else {				/* integer source */
		/* worst case number length is when base=2, so use
		 * minus base # number BITS(int64_t) NUL */
		char strbuf[1 + 2 + 1 + BITS(int64_t) + 1];
		const char *digits = (vp->flag & UCASEV_AL) ?
		    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" :
		    "0123456789abcdefghijklmnopqrstuvwxyz";
		uint64_t n;
		unsigned int base;

		s = strbuf + sizeof(strbuf);
		if (vp->flag & INT_U)
			n = (uint64_t) vp->val.i;
		else
			n = (vp->val.i < 0) ? -vp->val.i : vp->val.i;
		base = (vp->type == 0) ? 10 : vp->type;
		if (base < 2 || base > strlen(digits))
			base = 10;

		*--s = '\0';
		do {
			*--s = digits[n % base];
			n /= base;
		} while (n != 0);
		if (base != 10) {
			*--s = '#';
			*--s = digits[base % 10];
			if (base >= 10)
				*--s = digits[base / 10];
		}
		if (!(vp->flag & INT_U) && vp->val.i < 0)
			*--s = '-';
		if (vp->flag & (RJUST|LJUST)) /* case already dealt with */
			s = formatstr(vp, s);
		else
			s = str_save(s, ATEMP);
	}
	return s;
}

/* get variable integer value, with error checking */
int64_t
intval(struct tbl *vp)
{
	int64_t num;
	int base;

	base = getint(vp, &num, false);
	if (base == -1)
		/* XXX check calls - is error here ok by POSIX? */
		errorf("%s: bad number", str_val(vp));
	return num;
}

/* set variable to string value */
int
setstr(struct tbl *vq, const char *s, int error_ok)
{
	const char *fs = NULL;
	int no_ro_check = error_ok & KSH_IGNORE_RDONLY;
	error_ok &= ~KSH_IGNORE_RDONLY;
	if ((vq->flag & RDONLY) && !no_ro_check) {
		warningf(true, "%s: is read only", vq->name);
		if (!error_ok)
			errorf(NULL);
		return 0;
	}
	if (!(vq->flag&INTEGER)) { /* string dest */
		if ((vq->flag&ALLOC)) {
			/* debugging */
			if (s >= vq->val.s &&
			    s <= vq->val.s + strlen(vq->val.s))
				internal_errorf("%s: %s=%s: assigning to self",
				    __func__, vq->name, s);
			afree(vq->val.s, vq->areap);
		}
		vq->flag &= ~(ISSET|ALLOC);
		vq->type = 0;
		if (s && (vq->flag & (UCASEV_AL|LCASEV|LJUST|RJUST)))
			fs = s = formatstr(vq, s);
		if ((vq->flag&EXPORT))
			export(vq, s);
		else {
			vq->val.s = str_save(s, vq->areap);
			vq->flag |= ALLOC;
		}
	} else {		/* integer dest */
		if (!v_evaluate(vq, s, error_ok, true))
			return 0;
	}
	vq->flag |= ISSET;
	if ((vq->flag&SPECIAL))
		setspec(vq);
	afree((void *)fs, ATEMP);
	return 1;
}

/* set variable to integer */
void
setint(struct tbl *vq, int64_t n)
{
	if (!(vq->flag&INTEGER)) {
		struct tbl *vp = &vtemp;
		vp->flag = (ISSET|INTEGER);
		vp->type = 0;
		vp->areap = ATEMP;
		vp->val.i = n;
		/* setstr can't fail here */
		setstr(vq, str_val(vp), KSH_RETURN_ERROR);
	} else
		vq->val.i = n;
	vq->flag |= ISSET;
	if ((vq->flag&SPECIAL))
		setspec(vq);
}

int
getint(struct tbl *vp, int64_t *nump, bool arith)
{
	char *s;
	int c;
	int base, neg;
	int have_base = 0;
	int64_t num;

	if (vp->flag&SPECIAL)
		getspec(vp);
	/* XXX is it possible for ISSET to be set and val.s to be 0? */
	if (!(vp->flag&ISSET) || (!(vp->flag&INTEGER) && vp->val.s == NULL))
		return -1;
	if (vp->flag&INTEGER) {
		*nump = vp->val.i;
		return vp->type;
	}
	s = vp->val.s + vp->type;
	if (s == NULL)	/* redundant given initial test */
		s = null;
	base = 10;
	num = 0;
	neg = 0;
	if (arith && *s == '0' && *(s+1)) {
		s++;
		if (*s == 'x' || *s == 'X') {
			s++;
			base = 16;
		} else if (vp->flag & ZEROFIL) {
			while (*s == '0')
				s++;
		} else
			base = 8;
		have_base++;
	}
	for (c = (unsigned char)*s++; c ; c = (unsigned char)*s++) {
		if (c == '-') {
			neg++;
		} else if (c == '#') {
			base = (int) num;
			if (have_base || base < 2 || base > 36)
				return -1;
			num = 0;
			have_base = 1;
		} else if (letnum(c)) {
			if (isdigit(c))
				c -= '0';
			else if (islower(c))
				c -= 'a' - 10; /* todo: assumes ascii */
			else if (isupper(c))
				c -= 'A' - 10; /* todo: assumes ascii */
			else
				c = -1; /* _: force error */
			if (c < 0 || c >= base)
				return -1;
			num = num * base + c;
		} else
			return -1;
	}
	if (neg)
		num = -num;
	*nump = num;
	return base;
}

/* convert variable vq to integer variable, setting its value from vp
 * (vq and vp may be the same)
 */
struct tbl *
setint_v(struct tbl *vq, struct tbl *vp, bool arith)
{
	int base;
	int64_t num;

	if ((base = getint(vp, &num, arith)) == -1)
		return NULL;
	if (!(vq->flag & INTEGER) && (vq->flag & ALLOC)) {
		vq->flag &= ~ALLOC;
		afree(vq->val.s, vq->areap);
	}
	vq->val.i = num;
	if (vq->type == 0) /* default base */
		vq->type = base;
	vq->flag |= ISSET|INTEGER;
	if (vq->flag&SPECIAL)
		setspec(vq);
	return vq;
}

static char *
formatstr(struct tbl *vp, const char *s)
{
	int olen, nlen;
	char *p, *q;

	olen = strlen(s);

	if (vp->flag & (RJUST|LJUST)) {
		if (!vp->u2.field)	/* default field width */
			vp->u2.field = olen;
		nlen = vp->u2.field;
	} else
		nlen = olen;

	p = alloc(nlen + 1, ATEMP);
	if (vp->flag & (RJUST|LJUST)) {
		int slen;

		if (vp->flag & RJUST) {
			const char *r = s + olen;
			/* strip trailing spaces (at&t ksh uses r[-1] == ' ') */
			while (r > s && isspace((unsigned char)r[-1]))
				--r;
			slen = r - s;
			if (slen > vp->u2.field) {
				s += slen - vp->u2.field;
				slen = vp->u2.field;
			}
			shf_snprintf(p, nlen + 1,
				((vp->flag & ZEROFIL) && digit(*s)) ?
					  "%0*s%.*s" : "%*s%.*s",
				vp->u2.field - slen, null, slen, s);
		} else {
			/* strip leading spaces/zeros */
			while (isspace((unsigned char)*s))
				s++;
			if (vp->flag & ZEROFIL)
				while (*s == '0')
					s++;
			shf_snprintf(p, nlen + 1, "%-*.*s",
				vp->u2.field, vp->u2.field, s);
		}
	} else
		memcpy(p, s, olen + 1);

	if (vp->flag & UCASEV_AL) {
		for (q = p; *q; q++)
			if (islower((unsigned char)*q))
				*q = toupper((unsigned char)*q);
	} else if (vp->flag & LCASEV) {
		for (q = p; *q; q++)
			if (isupper((unsigned char)*q))
				*q = tolower((unsigned char)*q);
	}

	return p;
}

/*
 * make vp->val.s be "name=value" for quick exporting.
 */
static void
export(struct tbl *vp, const char *val)
{
	char *xp;
	char *op = (vp->flag&ALLOC) ? vp->val.s : NULL;
	int namelen = strlen(vp->name);
	int vallen = strlen(val) + 1;

	vp->flag |= ALLOC;
	xp = alloc(namelen + 1 + vallen, vp->areap);
	memcpy(vp->val.s = xp, vp->name, namelen);
	xp += namelen;
	*xp++ = '=';
	vp->type = xp - vp->val.s; /* offset to value */
	memcpy(xp, val, vallen);
	afree(op, vp->areap);
}

/*
 * lookup variable (according to (set&LOCAL)),
 * set its attributes (INTEGER, RDONLY, EXPORT, TRACE, LJUST, RJUST, ZEROFIL,
 * LCASEV, UCASEV_AL), and optionally set its value if an assignment.
 */
struct tbl *
typeset(const char *var, int set, int clr, int field, int base)
{
	struct tbl *vp;
	struct tbl *vpbase, *t;
	char *tvar;
	const char *val;

	/* check for valid variable name, search for value */
	val = skip_varname(var, false);
	if (val == var)
		return NULL;
	if (*val == '[') {
		int len;

		len = array_ref_len(val);
		if (len == 0)
			return NULL;
		/* IMPORT is only used when the shell starts up and is
		 * setting up its environment.  Allow only simple array
		 * references at this time since parameter/command substitution
		 * is preformed on the [expression], which would be a major
		 * security hole.
		 */
		if (set & IMPORT) {
			int i;
			for (i = 1; i < len - 1; i++)
				if (!digit(val[i]))
					return NULL;
		}
		val += len;
	}
	if (*val == '=')
		tvar = str_nsave(var, val++ - var, ATEMP);
	else {
		/* Importing from original environment: must have an = */
		if (set & IMPORT)
			return NULL;
		tvar = (char *) var;
		val = NULL;
	}

	/* Prevent typeset from creating a local PATH/ENV/SHELL */
	if (Flag(FRESTRICTED) && (strcmp(tvar, "PATH") == 0 ||
	    strcmp(tvar, "ENV") == 0 || strcmp(tvar, "SHELL") == 0))
		errorf("%s: restricted", tvar);

	vp = (set&LOCAL) ? local(tvar, (set & LOCAL_COPY) ? true : false) :
	    global(tvar);
	set &= ~(LOCAL|LOCAL_COPY);

	vpbase = (vp->flag & ARRAY) ? global(arrayname(tvar)) : vp;

	/* only allow export flag to be set.  at&t ksh allows any attribute to
	 * be changed, which means it can be truncated or modified
	 * (-L/-R/-Z/-i).
	 */
	if ((vpbase->flag&RDONLY) &&
	    (val || clr || (set & ~EXPORT)))
		/* XXX check calls - is error here ok by POSIX? */
		errorf("%s: is read only", tvar);
	if (val)
		afree(tvar, ATEMP);

	/* most calls are with set/clr == 0 */
	if (set | clr) {
		int ok = 1;
		/* XXX if x[0] isn't set, there will be problems: need to have
		 * one copy of attributes for arrays...
		 */
		for (t = vpbase; t; t = t->u.array) {
			int fake_assign;
			int error_ok = KSH_RETURN_ERROR;
			char *s = NULL;
			char *free_me = NULL;

			fake_assign = (t->flag & ISSET) && (!val || t != vp) &&
			    ((set & (UCASEV_AL|LCASEV|LJUST|RJUST|ZEROFIL)) ||
			    ((t->flag & INTEGER) && (clr & INTEGER)) ||
			    (!(t->flag & INTEGER) && (set & INTEGER)));
			if (fake_assign) {
				if (t->flag & INTEGER) {
					s = str_val(t);
					free_me = NULL;
				} else {
					s = t->val.s + t->type;
					free_me = (t->flag & ALLOC) ? t->val.s :
					    NULL;
				}
				t->flag &= ~ALLOC;
			}
			if (!(t->flag & INTEGER) && (set & INTEGER)) {
				t->type = 0;
				t->flag &= ~ALLOC;
			}
			if (!(t->flag & RDONLY) && (set & RDONLY)) {
				/* allow var to be initialized read-only */
				error_ok |= KSH_IGNORE_RDONLY;
			}
			t->flag = (t->flag | set) & ~clr;
			/* Don't change base if assignment is to be done,
			 * in case assignment fails.
			 */
			if ((set & INTEGER) && base > 0 && (!val || t != vp))
				t->type = base;
			if (set & (LJUST|RJUST|ZEROFIL))
				t->u2.field = field;
			if (fake_assign) {
				if (!setstr(t, s, error_ok)) {
					/* Somewhat arbitrary action here:
					 * zap contents of variable, but keep
					 * the flag settings.
					 */
					ok = 0;
					if (t->flag & INTEGER)
						t->flag &= ~ISSET;
					else {
						if (t->flag & ALLOC)
							afree(t->val.s, t->areap);
						t->flag &= ~(ISSET|ALLOC);
						t->type = 0;
					}
				}
				afree(free_me, t->areap);
			}
		}
		if (!ok)
		    errorf(NULL);
	}

	if (val != NULL) {
		if (vp->flag&INTEGER) {
			/* do not zero base before assignment */
			setstr(vp, val, KSH_UNWIND_ERROR | KSH_IGNORE_RDONLY);
			/* Done after assignment to override default */
			if (base > 0)
				vp->type = base;
		} else
			/* setstr can't fail (readonly check already done) */
			setstr(vp, val, KSH_RETURN_ERROR | KSH_IGNORE_RDONLY);
	}

	/* only x[0] is ever exported, so use vpbase */
	if ((vpbase->flag&EXPORT) && !(vpbase->flag&INTEGER) &&
	    vpbase->type == 0)
		export(vpbase, (vpbase->flag&ISSET) ? vpbase->val.s : null);

	return vp;
}

/* Unset a variable.  array_ref is set if there was an array reference in
 * the name lookup (eg, x[2]).
 */
void
unset(struct tbl *vp, int array_ref)
{
	if (vp->flag & ALLOC)
		afree(vp->val.s, vp->areap);
	if ((vp->flag & ARRAY) && !array_ref) {
		struct tbl *a, *tmp;

		/* Free up entire array */
		for (a = vp->u.array; a; ) {
			tmp = a;
			a = a->u.array;
			if (tmp->flag & ALLOC)
				afree(tmp->val.s, tmp->areap);
			afree(tmp, tmp->areap);
		}
		vp->u.array = NULL;
	}
	/* If foo[0] is being unset, the remainder of the array is kept... */
	vp->flag &= SPECIAL | (array_ref ? ARRAY|DEFINED : 0);
	if (vp->flag & SPECIAL)
		unsetspec(vp);	/* responsible for `unspecial'ing var */
}

/* return a pointer to the first char past a legal variable name (returns the
 * argument if there is no legal name, returns * a pointer to the terminating
 * null if whole string is legal).
 */
char *
skip_varname(const char *s, int aok)
{
	int alen;

	if (s && letter(*s)) {
		while (*++s && letnum(*s))
			;
		if (aok && *s == '[' && (alen = array_ref_len(s)))
			s += alen;
	}
	return (char *) s;
}

/* Return a pointer to the first character past any legal variable name.  */
char *
skip_wdvarname(const char *s,
    int aok)				/* skip array de-reference? */
{
	if (s[0] == CHAR && letter(s[1])) {
		do {
			s += 2;
		} while (s[0] == CHAR && letnum(s[1]));
		if (aok && s[0] == CHAR && s[1] == '[') {
			/* skip possible array de-reference */
			const char *p = s;
			char c;
			int depth = 0;

			while (1) {
				if (p[0] != CHAR)
					break;
				c = p[1];
				p += 2;
				if (c == '[')
					depth++;
				else if (c == ']' && --depth == 0) {
					s = p;
					break;
				}
			}
		}
	}
	return (char *) s;
}

/* Check if coded string s is a variable name */
int
is_wdvarname(const char *s, int aok)
{
	char *p = skip_wdvarname(s, aok);

	return p != s && p[0] == EOS;
}

/* Check if coded string s is a variable assignment */
int
is_wdvarassign(const char *s)
{
	char *p = skip_wdvarname(s, true);

	return p != s && p[0] == CHAR && p[1] == '=';
}

/*
 * Make the exported environment from the exported names in the dictionary.
 */
char **
makenv(void)
{
	struct block *l;
	XPtrV env;
	struct tbl *vp, **vpp;
	int i;

	XPinit(env, 64);
	for (l = genv->loc; l != NULL; l = l->next)
		for (vpp = l->vars.tbls, i = l->vars.size; --i >= 0; )
			if ((vp = *vpp++) != NULL &&
			    (vp->flag&(ISSET|EXPORT)) == (ISSET|EXPORT)) {
				struct block *l2;
				struct tbl *vp2;
				unsigned int h = hash(vp->name);

				/* unexport any redefined instances */
				for (l2 = l->next; l2 != NULL; l2 = l2->next) {
					vp2 = ktsearch(&l2->vars, vp->name, h);
					if (vp2 != NULL)
						vp2->flag &= ~EXPORT;
				}
				if ((vp->flag&INTEGER)) {
					/* integer to string */
					char *val;
					val = str_val(vp);
					vp->flag &= ~(INTEGER|RDONLY);
					/* setstr can't fail here */
					setstr(vp, val, KSH_RETURN_ERROR);
				}
				XPput(env, vp->val.s);
			}
	XPput(env, NULL);
	return (char **) XPclose(env);
}

/*
 * Called after a fork in parent to bump the random number generator.
 * Done to ensure children will not get the same random number sequence
 * if the parent doesn't use $RANDOM.
 */
void
change_random(void)
{
	rand();
}

/*
 * handle special variables with side effects - PATH, SECONDS.
 */

/* Test if name is a special parameter */
static int
special(const char *name)
{
	struct tbl *tp;

	tp = ktsearch(&specials, name, hash(name));
	return tp && (tp->flag & ISSET) ? tp->type : V_NONE;
}

/* Make a variable non-special */
static void
unspecial(const char *name)
{
	struct tbl *tp;

	tp = ktsearch(&specials, name, hash(name));
	if (tp)
		ktdelete(tp);
}

static	struct	timespec seconds;	/* time SECONDS last set */
static	int	user_lineno;		/* what user set $LINENO to */

static void
getspec(struct tbl *vp)
{
	switch (special(vp->name)) {
	case V_SECONDS:
		vp->flag &= ~SPECIAL;
		/* On start up the value of SECONDS is used before seconds
		 * has been set - don't do anything in this case
		 * (see initcoms[] in main.c).
		 */
		if (vp->flag & ISSET) {
			struct timespec difference, now;

			clock_gettime(CLOCK_MONOTONIC, &now);
			timespecsub(&now, &seconds, &difference);
			setint(vp, (int64_t)difference.tv_sec);
		}
		vp->flag |= SPECIAL;
		break;
	case V_RANDOM:
		vp->flag &= ~SPECIAL;
		setint(vp, (int64_t) (rand() & 0x7fff));
		vp->flag |= SPECIAL;
		break;
	case V_HISTSIZE:
		vp->flag &= ~SPECIAL;
		setint(vp, (int64_t) histsize);
		vp->flag |= SPECIAL;
		break;
	case V_OPTIND:
		vp->flag &= ~SPECIAL;
		setint(vp, (int64_t) user_opt.uoptind);
		vp->flag |= SPECIAL;
		break;
	case V_LINENO:
		vp->flag &= ~SPECIAL;
		setint(vp, (int64_t) current_lineno + user_lineno);
		vp->flag |= SPECIAL;
		break;
	}
}

static void
setspec(struct tbl *vp)
{
	char *s;

	switch (special(vp->name)) {
	case V_PATH:
		afree(search_path, APERM);
		search_path = str_save(str_val(vp), APERM);
		flushcom(1);	/* clear tracked aliases */
		break;
	case V_IFS:
		setctypes(s = str_val(vp), C_IFS);
		ifs0 = *s;
		break;
	case V_OPTIND:
		vp->flag &= ~SPECIAL;
		getopts_reset((int) intval(vp));
		vp->flag |= SPECIAL;
		break;
	case V_POSIXLY_CORRECT:
		change_flag(FPOSIX, OF_SPECIAL, 1);
		break;
	case V_TMPDIR:
		afree(tmpdir, APERM);
		tmpdir = NULL;
		/* Use tmpdir iff it is an absolute path, is writable and
		 * searchable and is a directory...
		 */
		{
			struct stat statb;

			s = str_val(vp);
			if (s[0] == '/' && access(s, W_OK|X_OK) == 0 &&
			    stat(s, &statb) == 0 && S_ISDIR(statb.st_mode))
				tmpdir = str_save(s, APERM);
		}
		break;
	case V_HISTCONTROL:
		sethistcontrol(str_val(vp));
		break;
	case V_HISTSIZE:
		vp->flag &= ~SPECIAL;
		sethistsize((int) intval(vp));
		vp->flag |= SPECIAL;
		break;
	case V_HISTFILE:
		sethistfile(str_val(vp));
		break;
	case V_VISUAL:
		set_editmode(str_val(vp));
		break;
	case V_EDITOR:
		if (!(global("VISUAL")->flag & ISSET))
			set_editmode(str_val(vp));
		break;
	case V_COLUMNS:
		{
			int64_t l;

			if (getint(vp, &l, false) == -1) {
				x_cols = MIN_COLS;
				break;
			}
			if (l <= MIN_COLS || l > INT_MAX)
				x_cols = MIN_COLS;
			else
				x_cols = l;
		}
		break;
	case V_MAIL:
		mbset(str_val(vp));
		break;
	case V_MAILPATH:
		mpset(str_val(vp));
		break;
	case V_MAILCHECK:
		vp->flag &= ~SPECIAL;
		mcset(intval(vp));
		vp->flag |= SPECIAL;
		break;
	case V_RANDOM:
		vp->flag &= ~SPECIAL;
		srand_deterministic((unsigned int)intval(vp));
		vp->flag |= SPECIAL;
		break;
	case V_SECONDS:
		vp->flag &= ~SPECIAL;
		clock_gettime(CLOCK_MONOTONIC, &seconds);
		seconds.tv_sec -= intval(vp);
		vp->flag |= SPECIAL;
		break;
	case V_TMOUT:
		/* Enforce integer to avoid command execution from initcoms[] */
		vp->flag &= ~SPECIAL;
		intval(vp);
		vp->flag |= SPECIAL;
		/* at&t ksh seems to do this (only listen if integer) */
		if (vp->flag & INTEGER)
			ksh_tmout = vp->val.i >= 0 ? vp->val.i : 0;
		break;
	case V_LINENO:
		vp->flag &= ~SPECIAL;
		/* The -1 is because line numbering starts at 1. */
		user_lineno = (unsigned int) intval(vp) - current_lineno - 1;
		vp->flag |= SPECIAL;
		break;
	}
}

static void
unsetspec(struct tbl *vp)
{
	switch (special(vp->name)) {
	case V_PATH:
		afree(search_path, APERM);
		search_path = str_save(def_path, APERM);
		flushcom(1);	/* clear tracked aliases */
		break;
	case V_IFS:
		setctypes(" \t\n", C_IFS);
		ifs0 = ' ';
		break;
	case V_TMPDIR:
		/* should not become unspecial */
		afree(tmpdir, APERM);
		tmpdir = NULL;
		break;
	case V_MAIL:
		mbset(NULL);
		break;
	case V_MAILPATH:
		mpset(NULL);
		break;
	case V_HISTCONTROL:
		sethistcontrol(NULL);
		break;
	case V_LINENO:
	case V_MAILCHECK:	/* at&t ksh leaves previous value in place */
	case V_RANDOM:
	case V_SECONDS:
	case V_TMOUT:		/* at&t ksh leaves previous value in place */
		unspecial(vp->name);
		break;

	  /* at&t ksh man page says OPTIND, OPTARG and _ lose special meaning,
	   * but OPTARG does not (still set by getopts) and _ is also still
	   * set in various places.
	   * Don't know what at&t does for:
	   *		MAIL, MAILPATH, HISTSIZE, HISTFILE,
	   * Unsetting these in at&t ksh does not loose the `specialness':
	   *    no effect: IFS, COLUMNS, PATH, TMPDIR,
	   *		VISUAL, EDITOR,
	   * pdkshisms: no effect:
	   *		POSIXLY_CORRECT (use set +o posix instead)
	   */
	}
}

/*
 * Search for (and possibly create) a table entry starting with
 * vp, indexed by val.
 */
static struct tbl *
arraysearch(struct tbl *vp, int val)
{
	struct tbl *prev, *curr, *new;
	size_t namelen = strlen(vp->name) + 1;

	vp->flag |= ARRAY|DEFINED;
	vp->index = 0;
	/* The table entry is always [0] */
	if (val == 0)
		return vp;
	prev = vp;
	curr = vp->u.array;
	while (curr && curr->index < val) {
		prev = curr;
		curr = curr->u.array;
	}
	if (curr && curr->index == val) {
		if (curr->flag&ISSET)
			return curr;
		else
			new = curr;
	} else
		new = alloc(sizeof(struct tbl) + namelen,
		    vp->areap);
	strlcpy(new->name, vp->name, namelen);
	new->flag = vp->flag & ~(ALLOC|DEFINED|ISSET|SPECIAL);
	new->type = vp->type;
	new->areap = vp->areap;
	new->u2.field = vp->u2.field;
	new->index = val;
	if (curr != new) {		/* not reusing old array entry */
		prev->u.array = new;
		new->u.array = curr;
	}
	return new;
}

/* Return the length of an array reference (eg, [1+2]) - cp is assumed
 * to point to the open bracket.  Returns 0 if there is no matching closing
 * bracket.
 */
int
array_ref_len(const char *cp)
{
	const char *s = cp;
	int c;
	int depth = 0;

	while ((c = *s++) && (c != ']' || --depth))
		if (c == '[')
			depth++;
	if (!c)
		return 0;
	return s - cp;
}

/*
 * Make a copy of the base of an array name
 */
char *
arrayname(const char *str)
{
	const char *p;

	if ((p = strchr(str, '[')) == 0)
		/* Shouldn't happen, but why worry? */
		return (char *) str;

	return str_nsave(str, p - str, ATEMP);
}

/* Set (or overwrite, if !reset) the array variable var to the values in vals.
 */
void
set_array(const char *var, int reset, char **vals)
{
	struct tbl *vp, *vq;
	int i;

	/* to get local array, use "typeset foo; set -A foo" */
	vp = global(var);

	/* Note: at&t ksh allows set -A but not set +A of a read-only var */
	if ((vp->flag&RDONLY))
		errorf("%s: is read only", var);
	/* This code is quite non-optimal */
	if (reset > 0)
		/* trash existing values and attributes */
		unset(vp, 0);
	/* todo: would be nice for assignment to completely succeed or
	 * completely fail.  Only really effects integer arrays:
	 * evaluation of some of vals[] may fail...
	 */
	for (i = 0; vals[i]; i++) {
		vq = arraysearch(vp, i);
		/* would be nice to deal with errors here... (see above) */
		setstr(vq, vals[i], KSH_RETURN_ERROR);
	}
}

/*
 * Arithmetic expression evaluation
 */

/*
 * Korn expression evaluation
 */
/*
 * todo: better error handling: if in builtin, should be builtin error, etc.
 */



/* The order of these enums is constrained by the order of opinfo[] */
enum token {
	/* some (long) unary operators */
	O_PLUSPLUS = 0, O_MINUSMINUS,
	/* binary operators */
	O_EQ, O_NE,
	/* assignments are assumed to be in range O_ASN .. O_BORASN */
	O_ASN, O_TIMESASN, O_DIVASN, O_MODASN, O_PLUSASN, O_MINUSASN,
	O_LSHIFTASN, O_RSHIFTASN, O_BANDASN, O_BXORASN, O_BORASN,
	O_LSHIFT, O_RSHIFT,
	O_LE, O_GE, O_LT, O_GT,
	O_LAND,
	O_LOR,
	O_TIMES, O_DIV, O_MOD,
	O_PLUS, O_MINUS,
	O_BAND,
	O_BXOR,
	O_BOR,
	O_TERN,
	O_COMMA,
	/* things after this aren't used as binary operators */
	/* unary that are not also binaries */
	O_BNOT, O_LNOT,
	/* misc */
	OPEN_PAREN, CLOSE_PAREN, CTERN,
	/* things that don't appear in the opinfo[] table */
	VAR, LIT, END, BAD
};
#define IS_BINOP(op) (((int)op) >= (int)O_EQ && ((int)op) <= (int)O_COMMA)
#define IS_ASSIGNOP(op)	((int)(op) >= (int)O_ASN && (int)(op) <= (int)O_BORASN)

enum prec {
	P_PRIMARY = 0,		/* VAR, LIT, (), ~ ! - + */
	P_MULT,			/* * / % */
	P_ADD,			/* + - */
	P_SHIFT,		/* << >> */
	P_RELATION,		/* < <= > >= */
	P_EQUALITY,		/* == != */
	P_BAND,			/* & */
	P_BXOR,			/* ^ */
	P_BOR,			/* | */
	P_LAND,			/* && */
	P_LOR,			/* || */
	P_TERN,			/* ?: */
	P_ASSIGN,		/* = *= /= %= += -= <<= >>= &= ^= |= */
	P_COMMA			/* , */
};
#define MAX_PREC	P_COMMA

struct opinfo {
	char		name[4];
	int		len;	/* name length */
	enum prec	prec;	/* precedence: lower is higher */
};

/* Tokens in this table must be ordered so the longest are first
 * (eg, += before +).  If you change something, change the order
 * of enum token too.
 */
static const struct opinfo opinfo[] = {
	{ "++",	 2, P_PRIMARY },	/* before + */
	{ "--",	 2, P_PRIMARY },	/* before - */
	{ "==",	 2, P_EQUALITY },	/* before = */
	{ "!=",	 2, P_EQUALITY },	/* before ! */
	{ "=",	 1, P_ASSIGN },		/* keep assigns in a block */
	{ "*=",	 2, P_ASSIGN },
	{ "/=",	 2, P_ASSIGN },
	{ "%=",	 2, P_ASSIGN },
	{ "+=",	 2, P_ASSIGN },
	{ "-=",	 2, P_ASSIGN },
	{ "<<=", 3, P_ASSIGN },
	{ ">>=", 3, P_ASSIGN },
	{ "&=",	 2, P_ASSIGN },
	{ "^=",	 2, P_ASSIGN },
	{ "|=",	 2, P_ASSIGN },
	{ "<<",	 2, P_SHIFT },
	{ ">>",	 2, P_SHIFT },
	{ "<=",	 2, P_RELATION },
	{ ">=",	 2, P_RELATION },
	{ "<",	 1, P_RELATION },
	{ ">",	 1, P_RELATION },
	{ "&&",	 2, P_LAND },
	{ "||",	 2, P_LOR },
	{ "*",	 1, P_MULT },
	{ "/",	 1, P_MULT },
	{ "%",	 1, P_MULT },
	{ "+",	 1, P_ADD },
	{ "-",	 1, P_ADD },
	{ "&",	 1, P_BAND },
	{ "^",	 1, P_BXOR },
	{ "|",	 1, P_BOR },
	{ "?",	 1, P_TERN },
	{ ",",	 1, P_COMMA },
	{ "~",	 1, P_PRIMARY },
	{ "!",	 1, P_PRIMARY },
	{ "(",	 1, P_PRIMARY },
	{ ")",	 1, P_PRIMARY },
	{ ":",	 1, P_PRIMARY },
	{ "",	 0, P_PRIMARY } /* end of table */
};


typedef struct expr_state Expr_state;
struct expr_state {
	const char *expression;		/* expression being evaluated */
	const char *tokp;		/* lexical position */
	enum token  tok;		/* token from token() */
	int	    noassign;		/* don't do assigns (for ?:,&&,||) */
	bool	    arith;		/* true if evaluating an $(())
					 * expression
					 */
	struct tbl *val;		/* value from token() */
	struct tbl *evaling;		/* variable that is being recursively
					 * expanded (EXPRINEVAL flag set)
					 */
};

enum error_type {
	ET_UNEXPECTED, ET_BADLIT, ET_RECURSIVE,
	ET_LVALUE, ET_RDONLY, ET_STR
};

static void	   evalerr(Expr_state *, enum error_type, const char *)
		    __attribute__((__noreturn__));
static struct tbl *evalexpr(Expr_state *, enum prec);
static void	   token(Expr_state *);
static struct tbl *do_ppmm(Expr_state *, enum token, struct tbl *, bool);
static void	   assign_check(Expr_state *, enum token, struct tbl *);
static struct tbl *tempvar(void);
static struct tbl *intvar(Expr_state *, struct tbl *);

/*
 * parse and evaluate expression
 */
int
evaluate(const char *expr, int64_t *rval, int error_ok, bool arith)
{
	struct tbl v;
	int ret;

	v.flag = DEFINED|INTEGER;
	v.type = 0;
	ret = v_evaluate(&v, expr, error_ok, arith);
	*rval = v.val.i;
	return ret;
}

/*
 * parse and evaluate expression, storing result in vp.
 */
int
v_evaluate(struct tbl *vp, const char *expr, volatile int error_ok,
    bool arith)
{
	struct tbl *v;
	Expr_state curstate;
	Expr_state * const es = &curstate;
	int save_disable_subst;
	int i;

	/* save state to allow recursive calls */
	curstate.expression = curstate.tokp = expr;
	curstate.noassign = 0;
	curstate.arith = arith;
	curstate.evaling = NULL;
	curstate.val = NULL;

	newenv(E_ERRH);
	save_disable_subst = disable_subst;
	i = sigsetjmp(genv->jbuf, 0);
	if (i) {
		disable_subst = save_disable_subst;
		/* Clear EXPRINEVAL in of any variables we were playing with */
		if (curstate.evaling)
			curstate.evaling->flag &= ~EXPRINEVAL;
		quitenv(NULL);
		if (i == LAEXPR) {
			if (error_ok == KSH_RETURN_ERROR)
				return 0;
			errorf(NULL);
		}
		unwind(i);
		/* NOTREACHED */
	}

	token(es);
#if 1 /* ifdef-out to disallow empty expressions to be treated as 0 */
	if (es->tok == END) {
		es->tok = LIT;
		es->val = tempvar();
	}
#endif /* 0 */
	v = intvar(es, evalexpr(es, MAX_PREC));

	if (es->tok != END)
		evalerr(es, ET_UNEXPECTED, NULL);

	if (vp->flag & INTEGER)
		setint_v(vp, v, es->arith);
	else
		/* can fail if readonly */
		setstr(vp, str_val(v), error_ok);

	quitenv(NULL);

	return 1;
}

static void
evalerr(Expr_state *es, enum error_type type, const char *str)
{
	char tbuf[2];
	const char *s;

	es->arith = false;
	switch (type) {
	case ET_UNEXPECTED:
		switch (es->tok) {
		case VAR:
			s = es->val->name;
			break;
		case LIT:
			s = str_val(es->val);
			break;
		case END:
			s = "end of expression";
			break;
		case BAD:
			tbuf[0] = *es->tokp;
			tbuf[1] = '\0';
			s = tbuf;
			break;
		default:
			s = opinfo[(int)es->tok].name;
		}
		warningf(true, "%s: unexpected `%s'", es->expression, s);
		break;

	case ET_BADLIT:
		warningf(true, "%s: bad number `%s'", es->expression, str);
		break;

	case ET_RECURSIVE:
		warningf(true, "%s: expression recurses on parameter `%s'",
		    es->expression, str);
		break;

	case ET_LVALUE:
		warningf(true, "%s: %s requires lvalue",
		    es->expression, str);
		break;

	case ET_RDONLY:
		warningf(true, "%s: %s applied to read only variable",
		    es->expression, str);
		break;

	default: /* keep gcc happy */
	case ET_STR:
		warningf(true, "%s: %s", es->expression, str);
		break;
	}
	unwind(LAEXPR);
}

static struct tbl *
evalexpr(Expr_state *es, enum prec prec)
{
	struct tbl *vl, *vr = NULL, *vasn;
	enum token op;
	int64_t res = 0;

	if (prec == P_PRIMARY) {
		op = es->tok;
		if (op == O_BNOT || op == O_LNOT || op == O_MINUS ||
		    op == O_PLUS) {
			token(es);
			vl = intvar(es, evalexpr(es, P_PRIMARY));
			if (op == O_BNOT)
				vl->val.i = ~vl->val.i;
			else if (op == O_LNOT)
				vl->val.i = !vl->val.i;
			else if (op == O_MINUS)
				vl->val.i = -vl->val.i;
			/* op == O_PLUS is a no-op */
		} else if (op == OPEN_PAREN) {
			token(es);
			vl = evalexpr(es, MAX_PREC);
			if (es->tok != CLOSE_PAREN)
				evalerr(es, ET_STR, "missing )");
			token(es);
		} else if (op == O_PLUSPLUS || op == O_MINUSMINUS) {
			token(es);
			vl = do_ppmm(es, op, es->val, true);
			token(es);
		} else if (op == VAR || op == LIT) {
			vl = es->val;
			token(es);
		} else {
			evalerr(es, ET_UNEXPECTED, NULL);
			/* NOTREACHED */
		}
		if (es->tok == O_PLUSPLUS || es->tok == O_MINUSMINUS) {
			vl = do_ppmm(es, es->tok, vl, false);
			token(es);
		}
		return vl;
	}
	vl = evalexpr(es, ((int) prec) - 1);
	for (op = es->tok; IS_BINOP(op) && opinfo[(int) op].prec == prec;
	    op = es->tok) {
		token(es);
		vasn = vl;
		if (op != O_ASN) /* vl may not have a value yet */
			vl = intvar(es, vl);
		if (IS_ASSIGNOP(op)) {
			assign_check(es, op, vasn);
			vr = intvar(es, evalexpr(es, P_ASSIGN));
		} else if (op != O_TERN && op != O_LAND && op != O_LOR)
			vr = intvar(es, evalexpr(es, ((int) prec) - 1));
		if ((op == O_DIV || op == O_MOD || op == O_DIVASN ||
		    op == O_MODASN) && vr->val.i == 0) {
			if (es->noassign)
				vr->val.i = 1;
			else
				evalerr(es, ET_STR, "zero divisor");
		}
		switch ((int) op) {
		case O_TIMES:
		case O_TIMESASN:
			res = vl->val.i * vr->val.i;
			break;
		case O_DIV:
		case O_DIVASN:
			if (vl->val.i == LONG_MIN && vr->val.i == -1)
				res = LONG_MIN;
			else
				res = vl->val.i / vr->val.i;
			break;
		case O_MOD:
		case O_MODASN:
			if (vl->val.i == LONG_MIN && vr->val.i == -1)
				res = 0;
			else
				res = vl->val.i % vr->val.i;
			break;
		case O_PLUS:
		case O_PLUSASN:
			res = vl->val.i + vr->val.i;
			break;
		case O_MINUS:
		case O_MINUSASN:
			res = vl->val.i - vr->val.i;
			break;
		case O_LSHIFT:
		case O_LSHIFTASN:
			res = vl->val.i << vr->val.i;
			break;
		case O_RSHIFT:
		case O_RSHIFTASN:
			res = vl->val.i >> vr->val.i;
			break;
		case O_LT:
			res = vl->val.i < vr->val.i;
			break;
		case O_LE:
			res = vl->val.i <= vr->val.i;
			break;
		case O_GT:
			res = vl->val.i > vr->val.i;
			break;
		case O_GE:
			res = vl->val.i >= vr->val.i;
			break;
		case O_EQ:
			res = vl->val.i == vr->val.i;
			break;
		case O_NE:
			res = vl->val.i != vr->val.i;
			break;
		case O_BAND:
		case O_BANDASN:
			res = vl->val.i & vr->val.i;
			break;
		case O_BXOR:
		case O_BXORASN:
			res = vl->val.i ^ vr->val.i;
			break;
		case O_BOR:
		case O_BORASN:
			res = vl->val.i | vr->val.i;
			break;
		case O_LAND:
			if (!vl->val.i)
				es->noassign++;
			vr = intvar(es, evalexpr(es, ((int) prec) - 1));
			res = vl->val.i && vr->val.i;
			if (!vl->val.i)
				es->noassign--;
			break;
		case O_LOR:
			if (vl->val.i)
				es->noassign++;
			vr = intvar(es, evalexpr(es, ((int) prec) - 1));
			res = vl->val.i || vr->val.i;
			if (vl->val.i)
				es->noassign--;
			break;
		case O_TERN:
			{
				int e = vl->val.i != 0;

				if (!e)
					es->noassign++;
				vl = evalexpr(es, MAX_PREC);
				if (!e)
					es->noassign--;
				if (es->tok != CTERN)
					evalerr(es, ET_STR, "missing :");
				token(es);
				if (e)
					es->noassign++;
				vr = evalexpr(es, P_TERN);
				if (e)
					es->noassign--;
				vl = e ? vl : vr;
			}
			break;
		case O_ASN:
			res = vr->val.i;
			break;
		case O_COMMA:
			res = vr->val.i;
			break;
		}
		if (IS_ASSIGNOP(op)) {
			vr->val.i = res;
			if (vasn->flag & INTEGER)
				setint_v(vasn, vr, es->arith);
			else
				setint(vasn, res);
			vl = vr;
		} else if (op != O_TERN)
			vl->val.i = res;
	}
	return vl;
}

static void
token(Expr_state *es)
{
	const char *cp;
	int c;
	char *tvar;

	/* skip white space */
	for (cp = es->tokp; (c = *cp), isspace((unsigned char)c); cp++)
		;
	es->tokp = cp;

	if (c == '\0')
		es->tok = END;
	else if (letter(c)) {
		for (; letnum(c); c = *cp)
			cp++;
		if (c == '[') {
			int len;

			len = array_ref_len(cp);
			if (len == 0)
				evalerr(es, ET_STR, "missing ]");
			cp += len;
		} else if (c == '(' /*)*/ ) {
			/* todo: add math functions (all take single argument):
			 * abs acos asin atan cos cosh exp int log sin sinh sqrt
			 * tan tanh
			 */
			;
		}
		if (es->noassign) {
			es->val = tempvar();
			es->val->flag |= EXPRLVALUE;
		} else {
			tvar = str_nsave(es->tokp, cp - es->tokp, ATEMP);
			es->val = global(tvar);
			afree(tvar, ATEMP);
		}
		es->tok = VAR;
	} else if (digit(c)) {
		for (; c != '_' && (letnum(c) || c == '#'); c = *cp++)
			;
		tvar = str_nsave(es->tokp, --cp - es->tokp, ATEMP);
		es->val = tempvar();
		es->val->flag &= ~INTEGER;
		es->val->type = 0;
		es->val->val.s = tvar;
		if (setint_v(es->val, es->val, es->arith) == NULL)
			evalerr(es, ET_BADLIT, tvar);
		afree(tvar, ATEMP);
		es->tok = LIT;
	} else {
		int i, n0;

		for (i = 0; (n0 = opinfo[i].name[0]); i++)
			if (c == n0 &&
			    strncmp(cp, opinfo[i].name, opinfo[i].len) == 0) {
				es->tok = (enum token) i;
				cp += opinfo[i].len;
				break;
			}
		if (!n0)
			es->tok = BAD;
	}
	es->tokp = cp;
}

/* Do a ++ or -- operation */
static struct tbl *
do_ppmm(Expr_state *es, enum token op, struct tbl *vasn, bool is_prefix)
{
	struct tbl *vl;
	int oval;

	assign_check(es, op, vasn);

	vl = intvar(es, vasn);
	oval = op == O_PLUSPLUS ? vl->val.i++ : vl->val.i--;
	if (vasn->flag & INTEGER)
		setint_v(vasn, vl, es->arith);
	else
		setint(vasn, vl->val.i);
	if (!is_prefix)		/* undo the inc/dec */
		vl->val.i = oval;

	return vl;
}

static void
assign_check(Expr_state *es, enum token op, struct tbl *vasn)
{
	if (es->tok == END || vasn == NULL ||
	    (vasn->name[0] == '\0' && !(vasn->flag & EXPRLVALUE)))
		evalerr(es, ET_LVALUE, opinfo[(int) op].name);
	else if (vasn->flag & RDONLY)
		evalerr(es, ET_RDONLY, opinfo[(int) op].name);
}

static struct tbl *
tempvar(void)
{
	struct tbl *vp;

	vp = alloc(sizeof(struct tbl), ATEMP);
	vp->flag = ISSET|INTEGER;
	vp->type = 0;
	vp->areap = ATEMP;
	vp->val.i = 0;
	vp->name[0] = '\0';
	return vp;
}

/* cast (string) variable to temporary integer variable */
static struct tbl *
intvar(Expr_state *es, struct tbl *vp)
{
	struct tbl *vq;

	/* try to avoid replacing a temp var with another temp var */
	if (vp->name[0] == '\0' &&
	    (vp->flag & (ISSET|INTEGER|EXPRLVALUE)) == (ISSET|INTEGER))
		return vp;

	vq = tempvar();
	if (setint_v(vq, vp, es->arith) == NULL) {
		if (vp->flag & EXPRINEVAL)
			evalerr(es, ET_RECURSIVE, vp->name);
		es->evaling = vp;
		vp->flag |= EXPRINEVAL;
		disable_subst++;
		v_evaluate(vq, str_val(vp), KSH_UNWIND_ERROR, es->arith);
		disable_subst--;
		vp->flag &= ~EXPRINEVAL;
		es->evaling = NULL;
	}
	return vq;
}

/*
 * Word expansion: substitution, globbing and brace expansion
 */

/*
 * Expansion - quoting, separation, substitution, globbing
 */




/*
 * string expansion
 *
 * first pass: quoting, IFS separation, ~, ${}, $() and $(()) substitution.
 * second pass: alternation ({,}), filename expansion (*?[]).
 */

/* expansion generator state */
typedef struct Expand {
	/* int  type; */	/* see expand() */
	const char *str;	/* string */
	union {
		const char **strv;/* string[] */
		struct shf *shf;/* file */
	} u;			/* source */
	struct tbl *var;	/* variable in ${var..} */
	short	split;		/* split "$@" / call waitlast $() */
} Expand;

#define	XBASE		0	/* scanning original */
#define	XSUB		1	/* expanding ${} string */
#define	XARGSEP		2	/* ifs0 between "$*" */
#define	XARG		3	/* expanding $*, $@ */
#define	XCOM		4	/* expanding $() */
#define XNULLSUB	5	/* "$@" when $# is 0 (don't generate word) */
#define XSUBMID		6	/* middle of expanding ${} */

/* States used for field splitting */
#define IFS_WORD	0	/* word has chars (or quotes) */
#define IFS_WS		1	/* have seen IFS white-space */
#define IFS_NWS		2	/* have seen IFS non-white-space */
#define IFS_IWS		3	/* beginning of word, ignore IFS white-space */
#define IFS_QUOTE	4	/* beg.w/quote, becomes IFS_WORD unless "$@" */

static	int	varsub(Expand *, char *, char *, int *, int *);
static	int	comsub(Expand *, char *);
static	char   *trimsub(char *, char *, int);
static	void	glob(char *, XPtrV *, int);
static	void	globit(XString *, char **, char *, XPtrV *, int);
static char	*maybe_expand_tilde(char *, XString *, char **, int);
static	char   *tilde(char *);
static	char   *homedir(char *);
static void	alt_expand(XPtrV *, char *, char *, char *, int);

static struct tbl *varcpy(struct tbl *);

/* compile and expand word */
char *
substitute(const char *cp, int f)
{
	struct source *s, *sold;

	if (disable_subst)
		return str_save(cp, ATEMP);

	sold = source;
	s = pushs(SWSTR, ATEMP);
	s->start = s->str = cp;
	source = s;
	if (yylex(ONEWORD) != LWORD)
		internal_errorf("substitute");
	source = sold;
	afree(s, ATEMP);
	return evalstr(yylval.cp, f);
}

/*
 * expand arg-list
 */
char **
eval(char **ap, int f)
{
	XPtrV w;

	if (*ap == NULL)
		return ap;
	XPinit(w, 32);
	XPput(w, NULL);		/* space for shell name */
	while (*ap != NULL)
		expand(*ap++, &w, f);
	XPput(w, NULL);
	return (char **) XPclose(w) + 1;
}

/*
 * expand string
 */
char *
evalstr(char *cp, int f)
{
	XPtrV w;

	XPinit(w, 1);
	expand(cp, &w, f);
	cp = (XPsize(w) == 0) ? null : (char*) *XPptrv(w);
	XPfree(w);
	return cp;
}

/*
 * expand string - return only one component
 * used from iosetup to expand redirection files
 */
char *
evalonestr(char *cp, int f)
{
	XPtrV w;

	XPinit(w, 1);
	expand(cp, &w, f);
	switch (XPsize(w)) {
	case 0:
		cp = null;
		break;
	case 1:
		cp = (char*) *XPptrv(w);
		break;
	default:
		cp = evalstr(cp, f&~DOGLOB);
		break;
	}
	XPfree(w);
	return cp;
}

/* for nested substitution: ${var:=$var2} */
typedef struct SubType {
	short	stype;		/* [=+-?%#] action after expanded word */
	short	base;		/* begin position of expanded word */
	short	f;		/* saved value of f (DOPAT, etc) */
	struct tbl *var;	/* variable for ${var..} */
	short	quote;		/* saved value of quote (for ${..[%#]..}) */
	struct SubType *prev;	/* old type */
	struct SubType *next;	/* poped type (to avoid re-allocating) */
} SubType;

void
expand(char *cp,	/* input word */
    XPtrV *wp,		/* output words */
    int f)		/* DO* flags */
{
	int c = 0;
	int type;		/* expansion type */
	int quote = 0;		/* quoted */
	XString ds;		/* destination string */
	char *dp, *sp;		/* dest., source */
	int fdo, word;		/* second pass flags; have word */
	int doblank;		/* field splitting of parameter/command subst */
	Expand x = {
		/* expansion variables */
		NULL, { NULL }, NULL, 0
	};
	SubType st_head, *st;
	int newlines = 0; /* For trailing newlines in COMSUB */
	int saw_eq, tilde_ok;
	int make_magic;
	size_t len;

	if (cp == NULL)
		internal_errorf("expand(NULL)");
	/* for alias, readonly, set, typeset commands */
	if ((f & DOVACHECK) && is_wdvarassign(cp)) {
		f &= ~(DOVACHECK|DOBLANK|DOGLOB|DOTILDE);
		f |= DOASNTILDE;
	}
	if (Flag(FNOGLOB))
		f &= ~DOGLOB;
	if (Flag(FMARKDIRS))
		f |= DOMARKDIRS;
	if (Flag(FBRACEEXPAND) && (f & DOGLOB))
		f |= DOBRACE_;

	Xinit(ds, dp, 128, ATEMP);	/* init dest. string */
	type = XBASE;
	sp = cp;
	fdo = 0;
	saw_eq = 0;
	tilde_ok = (f & (DOTILDE|DOASNTILDE)) ? 1 : 0; /* must be 1/0 */
	doblank = 0;
	make_magic = 0;
	word = (f&DOBLANK) ? IFS_WS : IFS_WORD;

	memset(&st_head, 0, sizeof(st_head));
	st = &st_head;

	while (1) {
		Xcheck(ds, dp);

		switch (type) {
		case XBASE:	/* original prefixed string */
			c = *sp++;
			switch (c) {
			case EOS:
				c = 0;
				break;
			case CHAR:
				c = *sp++;
				break;
			case QCHAR:
				quote |= 2; /* temporary quote */
				c = *sp++;
				break;
			case OQUOTE:
				switch (word) {
				case IFS_QUOTE:
					/* """something */
					word = IFS_WORD;
					break;
				case IFS_WORD:
					break;
				default:
					word = IFS_QUOTE;
					break;
				}
				tilde_ok = 0;
				quote = 1;
				continue;
			case CQUOTE:
				quote = 0;
				continue;
			case COMSUB:
				tilde_ok = 0;
				if (f & DONTRUNCOMMAND) {
					word = IFS_WORD;
					*dp++ = '$'; *dp++ = '(';
					while (*sp != '\0') {
						Xcheck(ds, dp);
						*dp++ = *sp++;
					}
					*dp++ = ')';
				} else {
					type = comsub(&x, sp);
					if (type == XCOM && (f&DOBLANK))
						doblank++;
					sp = strchr(sp, 0) + 1;
					newlines = 0;
				}
				continue;
			case EXPRSUB:
				word = IFS_WORD;
				tilde_ok = 0;
				if (f & DONTRUNCOMMAND) {
					*dp++ = '$'; *dp++ = '('; *dp++ = '(';
					while (*sp != '\0') {
						Xcheck(ds, dp);
						*dp++ = *sp++;
					}
					*dp++ = ')'; *dp++ = ')';
				} else {
					struct tbl v;
					char *p;

					v.flag = DEFINED|ISSET|INTEGER;
					v.type = 10; /* not default */
					v.name[0] = '\0';
					v_evaluate(&v, substitute(sp, 0),
					    KSH_UNWIND_ERROR, true);
					sp = strchr(sp, 0) + 1;
					for (p = str_val(&v); *p; ) {
						Xcheck(ds, dp);
						*dp++ = *p++;
					}
				}
				continue;
			case OSUBST: /* ${{#}var{:}[=+-?#%]word} */
			  /* format is:
			   *   OSUBST [{x] plain-variable-part \0
			   *     compiled-word-part CSUBST [}x]
			   * This is where all syntax checking gets done...
			   */
			    {
				char *varname = ++sp; /* skip the { or x (}) */
				int stype;
				int slen = 0;

				sp = strchr(sp, '\0') + 1; /* skip variable */
				type = varsub(&x, varname, sp, &stype, &slen);
				if (type < 0) {
					char endc;
					char *str, *end;

					sp = varname - 2; /* restore sp */
					end = (char *) wdscan(sp, CSUBST);
					/* ({) the } or x is already skipped */
					endc = *end;
					*end = EOS;
					str = snptreef(NULL, 64, "%S", sp);
					*end = endc;
					errorf("%s: bad substitution", str);
				}
				if (f&DOBLANK)
					doblank++;
				tilde_ok = 0;
				if (word == IFS_QUOTE && type != XNULLSUB)
					word = IFS_WORD;
				if (type == XBASE) {	/* expand? */
					if (!st->next) {
						SubType *newst;

						newst = alloc(
						    sizeof(SubType), ATEMP);
						newst->next = NULL;
						newst->prev = st;
						st->next = newst;
					}
					st = st->next;
					st->stype = stype;
					st->base = Xsavepos(ds, dp);
					st->f = f;
					st->var = varcpy(x.var);
					st->quote = quote;
					/* skip qualifier(s) */
					if (stype)
						sp += slen;
					switch (stype & 0x7f) {
					case '#':
					case '%':
						/* ! DOBLANK,DOBRACE_,DOTILDE */
						f = DOPAT | (f&DONTRUNCOMMAND) |
						    DOTEMP_;
						quote = 0;
						/* Prepend open pattern (so |
						 * in a trim will work as
						 * expected)
						 */
						*dp++ = MAGIC;
						*dp++ = '@' + 0x80U;
						break;
					case '=':
						/* Enabling tilde expansion
						 * after :'s here is
						 * non-standard ksh, but is
						 * consistent with rules for
						 * other assignments.  Not
						 * sure what POSIX thinks of
						 * this.
						 * Not doing tilde expansion
						 * for integer variables is a
						 * non-POSIX thing - makes
						 * sense though, since ~ is
						 * a arithmetic operator.
						 */
						if (!(x.var->flag & INTEGER))
							f |= DOASNTILDE|DOTILDE;
						f |= DOTEMP_;
						/* These will be done after the
						 * value has been assigned.
						 */
						f &= ~(DOBLANK|DOGLOB|DOBRACE_);
						tilde_ok = 1;
						break;
					case '?':
						f &= ~DOBLANK;
						f |= DOTEMP_;
						/* FALLTHROUGH */
					default:
						/* '-' '+' '?' */
						if (quote)
							word = IFS_WORD;
						else if (dp == Xstring(ds, dp))
							word = IFS_IWS;
						/* Enable tilde expansion */
						tilde_ok = 1;
						f |= DOTILDE;
					}
				} else
					/* skip word */
					sp = (char *) wdscan(sp, CSUBST);
				continue;
			    }
			case CSUBST: /* only get here if expanding word */
				sp++; /* ({) skip the } or x */
				tilde_ok = 0;	/* in case of ${unset:-} */
				*dp = '\0';
				quote = st->quote;
				f = st->f;
				if (f&DOBLANK)
					doblank--;
				switch (st->stype&0x7f) {
				case '#':
				case '%':
					/* Append end-pattern */
					*dp++ = MAGIC; *dp++ = ')'; *dp = '\0';
					dp = Xrestpos(ds, dp, st->base);
					/* Must use st->var since calling
					 * global would break things
					 * like x[i+=1].
					 */
					x.str = trimsub(str_val(st->var),
						dp, st->stype);
					if (x.str[0] != '\0') {
						word = IFS_IWS;
						type = XSUB;
					} else if (quote) {
						word = IFS_WORD;
						type = XSUB;
					} else {
						if (dp == Xstring(ds, dp))
							word = IFS_IWS;
						type = XNULLSUB;
					}
					if (f&DOBLANK)
						doblank++;
					st = st->prev;
					continue;
				case '=':
					/* Restore our position and substitute
					 * the value of st->var (may not be
					 * the assigned value in the presence
					 * of integer/right-adj/etc attributes).
					 */
					dp = Xrestpos(ds, dp, st->base);
					/* Must use st->var since calling
					 * global would cause with things
					 * like x[i+=1] to be evaluated twice.
					 */
					/* Note: not exported by FEXPORT
					 * in at&t ksh.
					 */
					/* XXX POSIX says readonly is only
					 * fatal for special builtins (setstr
					 * does readonly check).
					 */
					len = strlen(dp) + 1;
					setstr(st->var,
					    debunk(alloc(len, ATEMP),
					    dp, len), KSH_UNWIND_ERROR);
					x.str = str_val(st->var);
					type = XSUB;
					if (f&DOBLANK)
						doblank++;
					st = st->prev;
					if (quote || !*x.str)
						word = IFS_WORD;
					else
						word = IFS_IWS;
					continue;
				case '?':
				    {
					char *s = Xrestpos(ds, dp, st->base);

					errorf("%s: %s", st->var->name,
					    dp == s ?
					    "parameter null or not set" :
					    (debunk(s, s, strlen(s) + 1), s));
				    }
				}
				st = st->prev;
				type = XBASE;
				continue;

			case OPAT: /* open pattern: *(foo|bar) */
				/* Next char is the type of pattern */
				make_magic = 1;
				c = *sp++ + 0x80;
				break;

			case SPAT: /* pattern separator (|) */
				make_magic = 1;
				c = '|';
				break;

			case CPAT: /* close pattern */
				make_magic = 1;
				c = /*(*/ ')';
				break;
			}
			break;

		case XNULLSUB:
			/* Special case for "$@" (and "${foo[@]}") - no
			 * word is generated if $# is 0 (unless there is
			 * other stuff inside the quotes).
			 */
			type = XBASE;
			if (f&DOBLANK) {
				doblank--;
				if (dp == Xstring(ds, dp) && word != IFS_WORD)
					word = IFS_IWS;
			}
			continue;

		case XSUB:
		case XSUBMID:
			if ((c = *x.str++) == 0) {
				type = XBASE;
				if (f&DOBLANK)
					doblank--;
				continue;
			}
			break;

		case XARGSEP:
			type = XARG;
			quote = 1;
		case XARG:
			if ((c = *x.str++) == '\0') {
				/* force null words to be created so
				 * set -- '' 2 ''; foo "$@" will do
				 * the right thing
				 */
				if (quote && x.split)
					word = IFS_WORD;
				if ((x.str = *x.u.strv++) == NULL) {
					type = XBASE;
					if (f&DOBLANK)
						doblank--;
					continue;
				}
				c = ifs0;
				if (c == 0) {
					if (quote && !x.split)
						continue;
					if (!quote && word == IFS_WS)
						continue;
					/* this is so we don't terminate */
					c = ' ';
					/* now force-emit a word */
					goto emit_word;
				}
				if (quote && x.split) {
					/* terminate word for "$@" */
					type = XARGSEP;
					quote = 0;
				}
			}
			break;

		case XCOM:
			if (x.u.shf == NULL)	/* $(< ...) failed, fake EOF */
				c = EOF;
			else if (newlines) {		/* Spit out saved nl's */
				c = '\n';
				--newlines;
			} else {
				while ((c = shf_getc(x.u.shf)) == 0 || c == '\n')
				    if (c == '\n')
					    newlines++;	/* Save newlines */
				if (newlines && c != EOF) {
					shf_ungetc(c, x.u.shf);
					c = '\n';
					--newlines;
				}
			}
			if (c == EOF) {
				newlines = 0;
				if (x.u.shf != NULL)
					shf_close(x.u.shf);
				if (x.split)
					subst_exstat = waitlast();
				else
					subst_exstat = (x.u.shf == NULL);
				type = XBASE;
				if (f&DOBLANK)
					doblank--;
				continue;
			}
			break;
		}

		/* check for end of word or IFS separation */
		if (c == 0 || (!quote && (f & DOBLANK) && doblank &&
		    !make_magic && ctype(c, C_IFS))) {
			/* How words are broken up:
			 *		   |       value of c
			 *	  word	   |	ws	nws	0
			 *	-----------------------------------
			 *	IFS_WORD	w/WS	w/NWS	w
			 *	IFS_WS		-/WS	w/NWS	-
			 *	IFS_NWS		-/NWS	w/NWS	-
			 *	IFS_IWS		-/WS	w/NWS	-
			 *   (w means generate a word)
			 */
			if ((word == IFS_WORD) || (word == IFS_QUOTE) || (c &&
			    (word == IFS_IWS || word == IFS_NWS) &&
			    !ctype(c, C_IFSWS))) {
 				char *p;
 emit_word:
				*dp++ = '\0';
				p = Xclose(ds, dp);
				if (fdo & DOBRACE_)
					/* also does globbing */
					alt_expand(wp, p, p,
					    p + Xlength(ds, (dp - 1)),
					    fdo | (f & DOMARKDIRS));
				else if (fdo & DOGLOB)
					glob(p, wp, f & DOMARKDIRS);
				else if ((f & DOPAT) || !(fdo & DOMAGIC_))
					XPput(*wp, p);
				else
					XPput(*wp, debunk(p, p, strlen(p) + 1));
				fdo = 0;
				saw_eq = 0;
				tilde_ok = (f & (DOTILDE|DOASNTILDE)) ? 1 : 0;
				if (c != 0)
					Xinit(ds, dp, 128, ATEMP);
			}
			if (c == 0)
				goto done;
			if (word != IFS_NWS)
				word = ctype(c, C_IFSWS) ? IFS_WS : IFS_NWS;
		} else {
			if (type == XSUB) {
				if (word == IFS_NWS &&
				    Xlength(ds, dp) == 0) {
					char *p;

					if ((p = strdup("")) == NULL)
						internal_errorf("unable "
						    "to allocate memory");
					XPput(*wp, p);
				}
				type = XSUBMID;
			}

			/* age tilde_ok info - ~ code tests second bit */
			tilde_ok <<= 1;
			/* mark any special second pass chars */
			if (!quote)
				switch (c) {
				case '[':
				case '!':
				case '-':
				case ']':
					/* For character classes - doesn't hurt
					 * to have magic !,-,]'s outside of
					 * [...] expressions.
					 */
					if (f & (DOPAT | DOGLOB)) {
						fdo |= DOMAGIC_;
						if (c == '[')
							fdo |= f & DOGLOB;
						*dp++ = MAGIC;
					}
					break;
				case '*':
				case '?':
					if (f & (DOPAT | DOGLOB)) {
						fdo |= DOMAGIC_ | (f & DOGLOB);
						*dp++ = MAGIC;
					}
					break;
				case OBRACE:
				case ',':
				case CBRACE:
					if ((f & DOBRACE_) && (c == OBRACE ||
					    (fdo & DOBRACE_))) {
						fdo |= DOBRACE_|DOMAGIC_;
						*dp++ = MAGIC;
					}
					break;
				case '=':
					/* Note first unquoted = for ~ */
					if (!(f & DOTEMP_) && !saw_eq) {
						saw_eq = 1;
						tilde_ok = 1;
					}
					break;
				case ':': /* : */
					/* Note unquoted : for ~ */
					if (!(f & DOTEMP_) && (f & DOASNTILDE))
						tilde_ok = 1;
					break;
				case '~':
					/* tilde_ok is reset whenever
					 * any of ' " $( $(( ${ } are seen.
					 * Note that tilde_ok must be preserved
					 * through the sequence ${A=a=}~
					 */
					if (type == XBASE &&
					    (f & (DOTILDE|DOASNTILDE)) &&
					    (tilde_ok & 2)) {
						char *p, *dp_x;

						dp_x = dp;
						p = maybe_expand_tilde(sp,
						    &ds, &dp_x,
						    f & DOASNTILDE);
						if (p) {
							if (dp != dp_x)
								word = IFS_WORD;
							dp = dp_x;
							sp = p;
							continue;
						}
					}
					break;
				}
			else
				quote &= ~2; /* undo temporary */

			if (make_magic) {
				make_magic = 0;
				fdo |= DOMAGIC_ | (f & DOGLOB);
				*dp++ = MAGIC;
			} else if (ISMAGIC(c)) {
				fdo |= DOMAGIC_;
				*dp++ = MAGIC;
			}
			*dp++ = c; /* save output char */
			word = IFS_WORD;
		}
	}

done:
	for (st = &st_head; st != NULL; st = st->next) {
		if (st->var == NULL || (st->var->flag & RDONLY) == 0)
			continue;

		afree(st->var, ATEMP);
	}
}

/*
 * Prepare to generate the string returned by ${} substitution.
 */
static int
varsub(Expand *xp, char *sp, char *word,
    int *stypep,	/* becomes qualifier type */
    int *slenp)		/* " " len (=, :=, etc.) valid iff *stypep != 0 */
{
	int c;
	int state;	/* next state: XBASE, XARG, XSUB, XNULLSUB */
	int stype;	/* substitution type */
	int slen;
	char *p;
	struct tbl *vp;
	int zero_ok = 0;

	if (sp[0] == '\0')	/* Bad variable name */
		return -1;

	xp->var = NULL;

	/* ${#var}, string length or array size */
	if (sp[0] == '#' && (c = sp[1]) != '\0') {
		/* Can't have any modifiers for ${#...} */
		if (*word != CSUBST)
			return -1;
		sp++;
		/* Check for size of array */
		if ((p=strchr(sp,'[')) && (p[1]=='*'||p[1]=='@') && p[2]==']') {
			int n = 0;

			vp = global(arrayname(sp));
			if (vp->flag & (ISSET|ARRAY))
				zero_ok = 1;
			for (; vp; vp = vp->u.array)
				if (vp->flag & ISSET)
					n++;
			c = n; /* ksh88/ksh93 go for number, not max index */
		} else if (c == '*' || c == '@')
			c = genv->loc->argc;
		else {
			p = str_val(global(sp));
			zero_ok = p != null;
			c = strlen(p);
		}
		if (Flag(FNOUNSET) && c == 0 && !zero_ok)
			errorf("%s: parameter not set", sp);
		*stypep = 0; /* unqualified variable/string substitution */
		xp->str = str_save(u64ton((uint64_t)c, 10), ATEMP);
		return XSUB;
	}

	/* Check for qualifiers in word part */
	stype = 0;
	c = word[slen = 0] == CHAR ? word[1] : 0;
	if (c == ':') {
		slen += 2;
		stype = 0x80;
		c = word[slen + 0] == CHAR ? word[slen + 1] : 0;
	}
	if (ctype(c, C_SUBOP1)) {
		slen += 2;
		stype |= c;
	} else if (ctype(c, C_SUBOP2)) { /* Note: ksh88 allows :%, :%%, etc */
		slen += 2;
		stype = c;
		if (word[slen + 0] == CHAR && c == word[slen + 1]) {
			stype |= 0x80;
			slen += 2;
		}
	} else if (stype)	/* : is not ok */
		return -1;
	if (!stype && *word != CSUBST)
		return -1;
	*stypep = stype;
	*slenp = slen;

	c = sp[0];
	if (c == '*' || c == '@') {
		switch (stype & 0x7f) {
		case '=':	/* can't assign to a vector */
		case '%':	/* can't trim a vector (yet) */
		case '#':
			return -1;
		}
		if (genv->loc->argc == 0) {
			xp->str = null;
			xp->var = global(sp);
			state = c == '@' ? XNULLSUB : XSUB;
		} else {
			xp->u.strv = (const char **) genv->loc->argv + 1;
			xp->str = *xp->u.strv++;
			xp->split = c == '@'; /* $@ */
			state = XARG;
		}
		zero_ok = 1;	/* exempt "$@" and "$*" from 'set -u' */
	} else {
		if ((p=strchr(sp,'[')) && (p[1]=='*'||p[1]=='@') && p[2]==']') {
			XPtrV wv;

			switch (stype & 0x7f) {
			case '=':	/* can't assign to a vector */
			case '%':	/* can't trim a vector (yet) */
			case '#':
			case '?':
				return -1;
			}
			XPinit(wv, 32);
			vp = global(arrayname(sp));
			for (; vp; vp = vp->u.array) {
				if (!(vp->flag&ISSET))
					continue;
				XPput(wv, str_val(vp));
			}
			if (XPsize(wv) == 0) {
				xp->str = null;
				state = p[1] == '@' ? XNULLSUB : XSUB;
				XPfree(wv);
			} else {
				XPput(wv, 0);
				xp->u.strv = (const char **) XPptrv(wv);
				xp->str = *xp->u.strv++;
				xp->split = p[1] == '@'; /* ${foo[@]} */
				state = XARG;
			}
		} else {
			/* Can't assign things like $! or $1 */
			if ((stype & 0x7f) == '=' &&
			    (ctype(*sp, C_VAR1) || digit(*sp)))
				return -1;
			xp->var = global(sp);
			xp->str = str_val(xp->var);
			state = XSUB;
		}
	}

	c = stype&0x7f;
	/* test the compiler's code generator */
	if (ctype(c, C_SUBOP2) ||
	    (((stype&0x80) ? *xp->str=='\0' : xp->str==null) ? /* undef? */
	    c == '=' || c == '-' || c == '?' : c == '+'))
		state = XBASE;	/* expand word instead of variable value */
	if (Flag(FNOUNSET) && xp->str == null && !zero_ok &&
	    (ctype(c, C_SUBOP2) || (state != XBASE && c != '+')))
		errorf("%s: parameter not set", sp);
	return state;
}

/*
 * Run the command in $(...) and read its output.
 */
static int
comsub(Expand *xp, char *cp)
{
	Source *s, *sold;
	struct op *t;
	struct shf *shf;

	s = pushs(SSTRING, ATEMP);
	s->start = s->str = cp;
	sold = source;
	t = compile(s);
	afree(s, ATEMP);
	source = sold;

	if (t == NULL)
		return XBASE;

	if (t != NULL && t->type == TCOM && /* $(<file) */
	    *t->args == NULL && *t->vars == NULL && t->ioact != NULL) {
		struct ioword *io = *t->ioact;
		char *name;

		if ((io->flag&IOTYPE) != IOREAD)
			errorf("funny $() command: %s",
			    snptreef(NULL, 32, "%R", io));
		shf = shf_open(name = evalstr(io->name, DOTILDE), O_RDONLY, 0,
			SHF_MAPHI|SHF_CLEXEC);
		if (shf == NULL)
			warningf(!Flag(FTALKING),
			    "%s: %s", name, strerror(errno));
		xp->split = 0;	/* no waitlast() */
	} else {
		int ofd1, pv[2];
		openpipe(pv);
		shf = shf_fdopen(pv[0], SHF_RD, NULL);
		ofd1 = savefd(1);
		if (pv[1] != 1) {
			ksh_dup2(pv[1], 1, false);
			close(pv[1]);
		}
		execute(t, XFORK|XXCOM|XPIPEO, NULL);
		restfd(1, ofd1);
		startlast();
		xp->split = 1;	/* waitlast() */
	}

	xp->u.shf = shf;
	return XCOM;
}

/*
 * perform #pattern and %pattern substitution in ${}
 */

static char *
trimsub(char *str, char *pat, int how)
{
	char *end = strchr(str, 0);
	char *p, c;

	switch (how&0xff) {	/* UCHAR_MAX maybe? */
	case '#':		/* shortest at beginning */
		for (p = str; p <= end; p++) {
			c = *p; *p = '\0';
			if (gmatch_(str, pat, false)) {
				*p = c;
				return p;
			}
			*p = c;
		}
		break;
	case '#'|0x80:	/* longest match at beginning */
		for (p = end; p >= str; p--) {
			c = *p; *p = '\0';
			if (gmatch_(str, pat, false)) {
				*p = c;
				return p;
			}
			*p = c;
		}
		break;
	case '%':		/* shortest match at end */
		for (p = end; p >= str; p--) {
			if (gmatch_(p, pat, false))
				return str_nsave(str, p - str, ATEMP);
		}
		break;
	case '%'|0x80:	/* longest match at end */
		for (p = str; p <= end; p++) {
			if (gmatch_(p, pat, false))
				return str_nsave(str, p - str, ATEMP);
		}
		break;
	}

	return str;		/* no match, return string */
}

/*
 * glob
 * Name derived from V6's /etc/glob, the program that expanded filenames.
 */

/* XXX cp not const 'cause slashes are temporarily replaced with nulls... */
static void
glob(char *cp, XPtrV *wp, int markdirs)
{
	int oldsize = XPsize(*wp);

	if (glob_str(cp, wp, markdirs) == 0)
		XPput(*wp, debunk(cp, cp, strlen(cp) + 1));
	else
		qsortp(XPptrv(*wp) + oldsize, (size_t)(XPsize(*wp) - oldsize),
			xstrcmp);
}

#define GF_NONE		0
#define GF_EXCHECK	BIT(0)		/* do existence check on file */
#define GF_GLOBBED	BIT(1)		/* some globbing has been done */
#define GF_MARKDIR	BIT(2)		/* add trailing / to directories */

/* Apply file globbing to cp and store the matching files in wp.  Returns
 * the number of matches found.
 */
int
glob_str(char *cp, XPtrV *wp, int markdirs)
{
	int oldsize = XPsize(*wp);
	XString xs;
	char *xp;

	Xinit(xs, xp, 256, ATEMP);
	globit(&xs, &xp, cp, wp, markdirs ? GF_MARKDIR : GF_NONE);
	Xfree(xs, xp);

	return XPsize(*wp) - oldsize;
}

static void
globit(XString *xs,	/* dest string */
    char **xpp,		/* ptr to dest end */
    char *sp,		/* source path */
    XPtrV *wp,		/* output list */
    int check)		/* GF_* flags */
{
	char *np;		/* next source component */
	char *xp = *xpp;
	char *se;
	char odirsep;

	/* This to allow long expansions to be interrupted */
	intrcheck();

	if (sp == NULL) {	/* end of source path */
		/* We only need to check if the file exists if a pattern
		 * is followed by a non-pattern (eg, foo*x/bar; no check
		 * is needed for foo* since the match must exist) or if
		 * any patterns were expanded and the markdirs option is set.
		 * Symlinks make things a bit tricky...
		 */
		if ((check & GF_EXCHECK) ||
		    ((check & GF_MARKDIR) && (check & GF_GLOBBED))) {
#define stat_check()	(stat_done ? stat_done : \
			    (stat_done = stat(Xstring(*xs, xp), &statb) == -1 \
				? -1 : 1))
			struct stat lstatb, statb;
			int stat_done = 0;	 /* -1: failed, 1 ok */

			if (lstat(Xstring(*xs, xp), &lstatb) == -1)
				return;
			/* special case for systems which strip trailing
			 * slashes from regular files (eg, /etc/passwd/).
			 * SunOS 4.1.3 does this...
			 */
			if ((check & GF_EXCHECK) && xp > Xstring(*xs, xp) &&
			    xp[-1] == '/' && !S_ISDIR(lstatb.st_mode) &&
			    (!S_ISLNK(lstatb.st_mode) ||
			    stat_check() < 0 || !S_ISDIR(statb.st_mode)))
				return;
			/* Possibly tack on a trailing / if there isn't already
			 * one and if the file is a directory or a symlink to a
			 * directory
			 */
			if (((check & GF_MARKDIR) && (check & GF_GLOBBED)) &&
			    xp > Xstring(*xs, xp) && xp[-1] != '/' &&
			    (S_ISDIR(lstatb.st_mode) ||
			    (S_ISLNK(lstatb.st_mode) && stat_check() > 0 &&
			    S_ISDIR(statb.st_mode)))) {
				*xp++ = '/';
				*xp = '\0';
			}
		}
		XPput(*wp, str_nsave(Xstring(*xs, xp), Xlength(*xs, xp), ATEMP));
		return;
	}

	if (xp > Xstring(*xs, xp))
		*xp++ = '/';
	while (*sp == '/') {
		Xcheck(*xs, xp);
		*xp++ = *sp++;
	}
	np = strchr(sp, '/');
	if (np != NULL) {
		se = np;
		odirsep = *np;	/* don't assume '/', can be multiple kinds */
		*np++ = '\0';
	} else {
		odirsep = '\0'; /* keep gcc quiet */
		se = sp + strlen(sp);
	}


	/* Check if sp needs globbing - done to avoid pattern checks for strings
	 * containing MAGIC characters, open ['s without the matching close ],
	 * etc. (otherwise opendir() will be called which may fail because the
	 * directory isn't readable - if no globbing is needed, only execute
	 * permission should be required (as per POSIX)).
	 */
	if (!has_globbing(sp, se)) {
		XcheckN(*xs, xp, se - sp + 1);
		debunk(xp, sp, Xnleft(*xs, xp));
		xp += strlen(xp);
		*xpp = xp;
		globit(xs, xpp, np, wp, check);
	} else {
		DIR *dirp;
		struct dirent *d;
		char *name;
		int len;
		int prefix_len;

		*xp = '\0';
		prefix_len = Xlength(*xs, xp);
		dirp = opendir(prefix_len ? Xstring(*xs, xp) : ".");
		if (dirp == NULL)
			goto Nodir;
		while ((d = readdir(dirp)) != NULL) {
			name = d->d_name;
			if (name[0] == '.' &&
			    (name[1] == 0 || (name[1] == '.' && name[2] == 0)))
				continue; /* always ignore . and .. */
			if ((*name == '.' && *sp != '.') ||
			    !gmatch_(name, sp, true))
				continue;

			len = strlen(d->d_name) + 1;
			XcheckN(*xs, xp, len);
			memcpy(xp, name, len);
			*xpp = xp + len - 1;
			globit(xs, xpp, np, wp,
				(check & GF_MARKDIR) | GF_GLOBBED
				| (np ? GF_EXCHECK : GF_NONE));
			xp = Xstring(*xs, xp) + prefix_len;
		}
		closedir(dirp);
	  Nodir:;
	}

	if (np != NULL)
		*--np = odirsep;
}

/* remove MAGIC from string */
char *
debunk(char *dp, const char *sp, size_t dlen)
{
	char *d;
	const char *s;

	if ((s = strchr(sp, MAGIC))) {
		size_t slen = s - sp;
		if (slen >= dlen)
			return dp;
		memcpy(dp, sp, slen);
		for (d = dp + slen; *s && (d < dp + dlen); s++)
			if (!ISMAGIC(*s) || !(*++s & 0x80) ||
			    !strchr("*+?@! ", *s & 0x7f))
				*d++ = *s;
			else {
				/* extended pattern operators: *+?@! */
				if ((*s & 0x7f) != ' ')
					*d++ = *s & 0x7f;
				if (d < dp + dlen)
					*d++ = '(';
			}
		*d = '\0';
	} else if (dp != sp)
		strlcpy(dp, sp, dlen);
	return dp;
}

/* Check if p is an unquoted name, possibly followed by a / or :.  If so
 * puts the expanded version in *dcp,dp and returns a pointer in p just
 * past the name, otherwise returns 0.
 */
static char *
maybe_expand_tilde(char *p, XString *dsp, char **dpp, int isassign)
{
	XString ts;
	char *dp = *dpp;
	char *tp, *r;

	Xinit(ts, tp, 16, ATEMP);
	/* : only for DOASNTILDE form */
	while (p[0] == CHAR && p[1] != '/' && (!isassign || p[1] != ':'))
	{
		Xcheck(ts, tp);
		*tp++ = p[1];
		p += 2;
	}
	*tp = '\0';
	r = (p[0] == EOS || p[0] == CHAR || p[0] == CSUBST) ?
	    tilde(Xstring(ts, tp)) : NULL;
	Xfree(ts, tp);
	if (r) {
		while (*r) {
			Xcheck(*dsp, dp);
			if (ISMAGIC(*r))
				*dp++ = MAGIC;
			*dp++ = *r++;
		}
		*dpp = dp;
		r = p;
	}
	return r;
}

/*
 * tilde expansion
 *
 * based on a version by Arnold Robbins
 */

static char *
tilde(char *cp)
{
	char *dp;

	if (cp[0] == '\0')
		dp = str_val(global("HOME"));
	else if (cp[0] == '+' && cp[1] == '\0')
		dp = str_val(global("PWD"));
	else if (cp[0] == '-' && cp[1] == '\0')
		dp = str_val(global("OLDPWD"));
	else
		dp = homedir(cp);
	/* If HOME, PWD or OLDPWD are not set, don't expand ~ */
	if (dp == null)
		dp = NULL;
	return dp;
}

/*
 * map userid to user's home directory.
 * note that 4.3's getpw adds more than 6K to the shell,
 * and the YP version probably adds much more.
 * we might consider our own version of getpwnam() to keep the size down.
 */

static char *
homedir(char *name)
{
	struct tbl *ap;

	ap = ktenter(&homedirs, name, hash(name));
	if (!(ap->flag & ISSET)) {
		struct passwd *pw;

		pw = getpwnam(name);
		if (pw == NULL)
			return NULL;
		ap->val.s = str_save(pw->pw_dir, APERM);
		ap->flag |= DEFINED|ISSET|ALLOC;
	}
	return ap->val.s;
}

static void
alt_expand(XPtrV *wp, char *start, char *exp_start, char *end, int fdo)
{
	int count = 0;
	char *brace_start, *brace_end, *comma = NULL;
	char *field_start;
	char *p;

	/* search for open brace */
	for (p = exp_start; (p = strchr(p, MAGIC)) && p[1] != OBRACE; p += 2)
		;
	brace_start = p;

	/* find matching close brace, if any */
	if (p) {
		comma = NULL;
		count = 1;
		for (p += 2; *p && count; p++) {
			if (ISMAGIC(*p)) {
				if (*++p == OBRACE)
					count++;
				else if (*p == CBRACE)
					--count;
				else if (*p == ',' && count == 1)
					comma = p;
			}
		}
	}
	/* no valid expansions... */
	if (!p || count != 0) {
		/* Note that given a{{b,c} we do not expand anything (this is
		 * what at&t ksh does.  This may be changed to do the {b,c}
		 * expansion. }
		 */
		if (fdo & DOGLOB)
			glob(start, wp, fdo & DOMARKDIRS);
		else
			XPput(*wp, debunk(start, start, end - start));
		return;
	}
	brace_end = p;
	if (!comma) {
		alt_expand(wp, start, brace_end, end, fdo);
		return;
	}

	/* expand expression */
	field_start = brace_start + 2;
	count = 1;
	for (p = brace_start + 2; p != brace_end; p++) {
		if (ISMAGIC(*p)) {
			if (*++p == OBRACE)
				count++;
			else if ((*p == CBRACE && --count == 0) ||
			    (*p == ',' && count == 1)) {
				char *new;
				int l1, l2, l3;

				l1 = brace_start - start;
				l2 = (p - 1) - field_start;
				l3 = end - brace_end;
				new = alloc(l1 + l2 + l3 + 1, ATEMP);
				memcpy(new, start, l1);
				memcpy(new + l1, field_start, l2);
				memcpy(new + l1 + l2, brace_end, l3);
				new[l1 + l2 + l3] = '\0';
				alt_expand(wp, new, new + l1,
				    new + l1 + l2 + l3, fdo);
				field_start = p + 1;
			}
		}
	}
	return;
}

/*
 * Copy the given variable if it's flagged as read-only.
 * Such variables have static storage and only one can therefore be referenced
 * at a time.
 * This is necessary in order to allow variable expansion expressions to refer
 * to multiple read-only variables.
 */
static struct tbl *
varcpy(struct tbl *vp)
{
	struct tbl *cpy;

	if (vp == NULL || (vp->flag & RDONLY) == 0)
		return vp;

	cpy = alloc(sizeof(struct tbl), ATEMP);
	memcpy(cpy, vp, sizeof(struct tbl));
	return cpy;
}
