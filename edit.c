/*
 * nextsh: interactive command line editing and history.
 */

/*
 * Command line editing: shared machinery and completion
 */

/*
 * Command line editing - common code
 *
 */

X_chars edchars;

static void x_sigwinch(int);
volatile sig_atomic_t got_sigwinch;
static void check_sigwinch(void);

static int	x_file_glob(int, const char *, int, char ***, int);
static char	*x_tilde_expand(const char *);
static int	x_tilde_is_dir(const char *, int);
static int	x_tilde_glob(const char *, int, char ***);
static const char *x_tilde_name(const char *);
static int	x_command_glob(int, const char *, int, char ***);
static int	x_locate_word(const char *, int, int, int *, int *);
static void	x_preserve_tilde(char **, int, const char *, const char *);


/* Called from main */
void
x_init(void)
{
	/* set to -2 to force initial binding */
	edchars.erase = edchars.kill = edchars.intr = edchars.quit =
	    edchars.eof = -2;
	/* default value for deficient systems */
	edchars.werase = 027;	/* ^W */

	if (setsig(&sigtraps[SIGWINCH], x_sigwinch, SS_RESTORE_ORIG|SS_SHTRAP))
		sigtraps[SIGWINCH].flags |= TF_SHELL_USES;
	got_sigwinch = 1; /* force initial check */
	check_sigwinch();

	x_init_emacs();
}

static void
x_sigwinch(int sig)
{
	got_sigwinch = 1;
}

static void
check_sigwinch(void)
{
	if (got_sigwinch) {
		struct winsize ws;

		got_sigwinch = 0;
		if (procpid == kshpid && ioctl(tty_fd, TIOCGWINSZ, &ws) == 0) {
			struct tbl *vp;

			/* Do NOT export COLUMNS/LINES.  Many applications
			 * check COLUMNS/LINES before checking ws.ws_col/row,
			 * so if the app is started with C/L in the environ
			 * and the window is then resized, the app won't
			 * see the change cause the environ doesn't change.
			 */
			if (ws.ws_col) {
				x_cols = ws.ws_col < MIN_COLS ? MIN_COLS :
				    ws.ws_col;

				if ((vp = typeset("COLUMNS", 0, 0, 0, 0)))
					setint(vp, (int64_t) ws.ws_col);
			}
			if (ws.ws_row && (vp = typeset("LINES", 0, 0, 0, 0)))
				setint(vp, (int64_t) ws.ws_row);
		}
	}
}

/*
 * read an edited command line
 */
int
x_read(char *buf, size_t len)
{
	int	i;

	x_mode(true);
	if (Flag(FEMACS) || Flag(FGMACS))
		i = x_emacs(buf, len);
	else
	if (Flag(FVI))
		i = x_vi(buf, len);
	else
		i = -1;		/* internal error */
	x_mode(false);
	check_sigwinch();
	return i;
}

/* tty I/O */

int
x_getc(void)
{
	char c;
	int n;

	while ((n = blocking_read(STDIN_FILENO, &c, 1)) < 0 && errno == EINTR)
		if (trap) {
			x_mode(false);
			runtraps(0);
			x_mode(true);
		}
	if (n != 1)
		return -1;
	return (int) (unsigned char) c;
}

void
x_flush(void)
{
	shf_flush(shl_out);
}

int
x_putc(int c)
{
	return shf_putc(c, shl_out);
}

void
x_puts(const char *s)
{
	while (*s != 0)
		shf_putc(*s++, shl_out);
}

bool
x_mode(bool onoff)
{
	static bool	x_cur_mode;
	bool		prev;

	if (x_cur_mode == onoff)
		return x_cur_mode;
	prev = x_cur_mode;
	x_cur_mode = onoff;

	if (onoff) {
		struct termios	cb;
		X_chars		oldchars;

		oldchars = edchars;
		cb = tty_state;

		edchars.erase = cb.c_cc[VERASE];
		edchars.kill = cb.c_cc[VKILL];
		edchars.intr = cb.c_cc[VINTR];
		edchars.quit = cb.c_cc[VQUIT];
		edchars.eof = cb.c_cc[VEOF];
#ifdef VWERASE
		edchars.werase = cb.c_cc[VWERASE];
#endif
		cb.c_iflag &= ~(INLCR|ICRNL);
		cb.c_lflag &= ~(ISIG|ICANON|ECHO);
#ifdef VLNEXT
		/* osf/1 processes lnext when ~icanon */
		cb.c_cc[VLNEXT] = _POSIX_VDISABLE;
#endif
#ifdef VDISCARD
		/* sunos 4.1.x & osf/1 processes discard(flush) when ~icanon */
		cb.c_cc[VDISCARD] = _POSIX_VDISABLE;
#endif
		cb.c_cc[VTIME] = 0;
		cb.c_cc[VMIN] = 1;

		tcsetattr(tty_fd, TCSADRAIN, &cb);

		/* Convert unset values to internal `unset' value */
		if (edchars.erase == _POSIX_VDISABLE)
			edchars.erase = -1;
		if (edchars.kill == _POSIX_VDISABLE)
			edchars.kill = -1;
		if (edchars.intr == _POSIX_VDISABLE)
			edchars.intr = -1;
		if (edchars.quit == _POSIX_VDISABLE)
			edchars.quit = -1;
		if (edchars.eof == _POSIX_VDISABLE)
			edchars.eof = -1;
		if (edchars.werase == _POSIX_VDISABLE)
			edchars.werase = -1;
		if (memcmp(&edchars, &oldchars, sizeof(edchars)) != 0) {
			x_emacs_keys(&edchars);
		}
	} else {
		tcsetattr(tty_fd, TCSADRAIN, &tty_state);
	}

	return prev;
}

void
set_editmode(const char *ed)
{
	static const enum sh_flag edit_flags[] = {
		FEMACS, FGMACS,
		FVI,
	};
	const char *rcp;
	unsigned int ele;

	if ((rcp = strrchr(ed, '/')))
		ed = ++rcp;
	for (ele = 0; ele < NELEM(edit_flags); ele++)
		if (strstr(ed, sh_options[(int) edit_flags[ele]].name)) {
			change_flag(edit_flags[ele], OF_SPECIAL, 1);
			return;
		}
}

/* ------------------------------------------------------------------------- */
/*           Misc common code for vi/emacs				     */

/* Handle the commenting/uncommenting of a line.
 * Returns:
 *	1 if a carriage return is indicated (comment added)
 *	0 if no return (comment removed)
 *	-1 if there is an error (not enough room for comment chars)
 * If successful, *lenp contains the new length.  Note: cursor should be
 * moved to the start of the line after (un)commenting.
 */
int
x_do_comment(char *buf, int bsize, int *lenp)
{
	int i, j;
	int len = *lenp;

	if (len == 0)
		return 1; /* somewhat arbitrary - it's what at&t ksh does */

	/* Already commented? */
	if (buf[0] == '#') {
		int saw_nl = 0;

		for (j = 0, i = 1; i < len; i++) {
			if (!saw_nl || buf[i] != '#')
				buf[j++] = buf[i];
			saw_nl = buf[i] == '\n';
		}
		*lenp = j;
		return 0;
	} else {
		int n = 1;

		/* See if there's room for the #'s - 1 per \n */
		for (i = 0; i < len; i++)
			if (buf[i] == '\n')
				n++;
		if (len + n >= bsize)
			return -1;
		/* Now add them... */
		for (i = len, j = len + n; --i >= 0; ) {
			if (buf[i] == '\n')
				buf[--j] = '#';
			buf[--j] = buf[i];
		}
		buf[0] = '#';
		*lenp += n;
		return 1;
	}
}

/* ------------------------------------------------------------------------- */
/*           Common file/command completion code for vi/emacs	             */


static char	*add_glob(const char *str, int slen);
static void	glob_table(const char *pat, XPtrV *wp, struct table *tp);
static void	glob_path(int flags, const char *pat, XPtrV *wp,
				const char *path);

static char *
plain_fmt_entry(void *arg, int i, char *buf, int bsize)
{
	const char *str = ((char *const *)arg)[i];
	char *buf0 = buf;
	int ch;

	if (buf == NULL || bsize <= 0)
		internal_errorf("%s: buf %lx, bsize %d",
		    __func__, (long) buf, bsize);

	while ((ch = (unsigned char)*str++) != '\0') {
		if (iscntrl(ch)) {
			if (bsize < 3)
				break;
			*buf++ = '^';
			*buf++ = UNCTRL(ch);
			bsize -= 2;
			continue;
		}
		if (bsize < 2)
			break;
		*buf++ = ch;
		bsize--;
	}
	*buf = '\0';

	return buf0;
}

/* Compute the length of string taking into account escape characters. */
static size_t
strlen_esc(const char *str)
{
	size_t len = 0;
	int ch;

	while ((ch = (unsigned char)*str++) != '\0') {
		if (iscntrl(ch))
			len++;
		len++;
	}
	return len;
}

static int
pr_list(char *const *ap)
{
	char *const *pp;
	int nwidth;
	int i, n;

	for (n = 0, nwidth = 0, pp = ap; *pp; n++, pp++) {
		i = strlen_esc(*pp);
		nwidth = (i > nwidth) ? i : nwidth;
	}
	print_columns(shl_out, n, plain_fmt_entry, (void *) ap, nwidth + 1, 0);

	return n;
}

void
x_print_expansions(int nwords, char *const *words, int is_command)
{
	int prefix_len;

	/* Check if all matches are in the same directory (in this
	 * case, we want to omit the directory name)
	 */
	if (!is_command &&
	    (prefix_len = x_longest_prefix(nwords, words)) > 0) {
		int i;

		/* Special case for 1 match (prefix is whole word) */
		if (nwords == 1)
			prefix_len = x_basename(words[0], NULL);
		/* Any (non-trailing) slashes in non-common word suffixes? */
		for (i = 0; i < nwords; i++)
			if (x_basename(words[i] + prefix_len, NULL) >
			    prefix_len)
				break;
		/* All in same directory? */
		if (i == nwords) {
			XPtrV l;

			while (prefix_len > 0 && words[0][prefix_len - 1] != '/')
				prefix_len--;
			XPinit(l, nwords + 1);
			for (i = 0; i < nwords; i++)
				XPput(l, words[i] + prefix_len);
			XPput(l, NULL);

			/* Enumerate expansions */
			x_putc('\r');
			x_putc('\n');
			pr_list((char **) XPptrv(l));

			XPfree(l); /* not x_free_words() */
			return;
		}
	}

	/* Enumerate expansions */
	x_putc('\r');
	x_putc('\n');
	pr_list(words);
}

static char *
x_tilde_expand(const char *tilde)
{
	struct passwd *pw;
	struct tbl *tp;
	char *dp;

	if (tilde[0] != '~')
		return NULL;
	if (tilde[1] == '\0')
		dp = str_val(global("HOME"));
	else if (tilde[1] == '+' && tilde[2] == '\0')
		dp = str_val(global("PWD"));
	else if (tilde[1] == '-' && tilde[2] == '\0')
		dp = str_val(global("OLDPWD"));
	else {
		tp = ktsearch(&homedirs, tilde + 1, hash(tilde + 1));
		if (tp != NULL && (tp->flag & ISSET))
			dp = tp->val.s;
		else if ((pw = getpwnam(tilde + 1)) != NULL)
			dp = pw->pw_dir;
		else
			dp = NULL;
	}
	if (dp == null || dp == NULL || dp[0] == '~')
		return NULL;
	return str_save(dp, ATEMP);
}

static int
x_tilde_is_dir(const char *tilde, int len)
{
	struct stat statb;
	char *expanded, *copy;
	int isdir;

	copy = str_nsave(tilde, len, ATEMP);
	expanded = x_tilde_expand(copy);
	afree(copy, ATEMP);
	if (expanded == NULL)
		return 0;
	isdir = stat(expanded, &statb) == 0 && S_ISDIR(statb.st_mode);
	afree(expanded, ATEMP);

	return isdir;
}

static int
x_tilde_glob(const char *str, int slen, char ***wordsp)
{
	struct passwd *pw;
	const char *prefix;
	char *word;
	size_t len, prefix_len;
	int i, nwords;
	XPtrV w;

	if (slen < 2 || str[0] != '~')
		return 0;
	if (str[1] == '+' || str[1] == '-')
		return 0;
	for (i = 1; i < slen; i++) {
		if (str[i] == '/')
			return 0;
		if (str[i] == '\\' || str[i] == '*' || str[i] == '?' ||
		    str[i] == '[' || str[i] == '$')
			return 0;
	}

	prefix = str + 1;
	prefix_len = slen - 1;

	XPinit(w, 32);
	setpwent();
	while ((pw = getpwent()) != NULL) {
		if (strncmp(pw->pw_name, prefix, prefix_len) != 0)
			continue;
		len = strlen(pw->pw_name);
		word = areallocarray(NULL, len + 2, sizeof(char), ATEMP);
		word[0] = '~';
		memcpy(word + 1, pw->pw_name, len + 1);
		XPput(w, word);
	}
	endpwent();

	nwords = XPsize(w);
	if (nwords == 0) {
		XPfree(w);
		return 0;
	}
	if (nwords == 1 && x_tilde_is_dir(str, slen)) {
		afree(XPptrv(w)[0], ATEMP);
		XPfree(w);
		return 0;
	}

	qsortp(XPptrv(w), (size_t)nwords, xstrcmp);
	XPput(w, NULL);
	*wordsp = (char **)XPclose(w);

	return nwords;
}

static const char *
x_tilde_name(const char *tilde)
{
	if (tilde[0] != '~' || tilde[1] == '\0')
		return NULL;
	if ((tilde[1] == '+' || tilde[1] == '-') && tilde[2] == '\0')
		return NULL;
	return tilde + 1;
}

int
x_is_tilde_user_completion(const char *str, int slen, const char *word,
    int wlen)
{
	int i;

	if (slen < 2 || wlen <= slen || str[0] != '~' ||
	    word[0] != '~')
		return 0;
	if (strncmp(str, word, slen) != 0)
		return 0;
	for (i = 1; i < slen; i++)
		if (str[i] == '/')
			return 0;
	for (i = 1; i < wlen; i++)
		if (word[i] == '/')
			return 0;
	return 1;
}

/*
 *  Do file globbing:
 *	- appends * to (copy of) str if no globbing chars found
 *	- does expansion, checks for no match, etc.
 *	- sets *wordsp to array of matching strings
 *	- returns number of matching strings
 */
static int
x_file_glob(int flags, const char *str, int slen, char ***wordsp,
    int preserve_tilde)
{
	char *toglob;
	char **words;
	int nwords;
	XPtrV w;
	struct source *s, *sold;
	struct tbl *tp;
	char *tilde = NULL;
	char *tilde_expanded = NULL;
	const char *tilde_name = NULL;
	int tilde_cached = 0;
	int tlen = 0;

	if (slen < 0)
		return 0;

	nwords = x_tilde_glob(str, slen, wordsp);
	if (nwords)
		return nwords;

	if (slen > 0 && str[0] == '~') {
		for (tlen = 1; tlen < slen; tlen++)
			if (str[tlen] == '/')
				break;
		tilde = str_nsave(str, tlen, ATEMP);
		tilde_name = x_tilde_name(tilde);
		if (tilde_name != NULL) {
			tp = ktsearch(&homedirs, tilde_name,
			    hash(tilde_name));
			if (tp != NULL && (tp->flag & ISSET))
				tilde_cached = 1;
		}
	}

	toglob = add_glob(str, slen);

	/*
	 * Convert "foo*" (toglob) to an array of strings (words)
	 */
	sold = source;
	s = pushs(SWSTR, ATEMP);
	s->start = s->str = toglob;
	source = s;
	if (yylex(ONEWORD|UNESCAPE) != LWORD) {
		source = sold;
		internal_warningf("%s: substitute error", __func__);
		afree(toglob, ATEMP);
		nwords = 0;
		goto done;
	}
	source = sold;
	XPinit(w, 32);
	expand(yylval.cp, &w, DOGLOB|DOTILDE|DOMARKDIRS);
	XPput(w, NULL);
	words = (char **) XPclose(w);

	for (nwords = 0; words[nwords]; nwords++)
		;
	if (nwords == 1) {
		struct stat statb;

		/* Check if file exists, also, check for empty
		 * result - happens if we tried to glob something
		 * which evaluated to an empty string (e.g.,
		 * "$FOO" when there is no FOO, etc).
		 */
		if ((lstat(words[0], &statb) == -1) ||
		    words[0][0] == '\0') {
			x_free_words(nwords, words);
			words = NULL;
			nwords = 0;
		}
	}
	afree(toglob, ATEMP);

	if (nwords) {
		if (preserve_tilde && tilde != NULL &&
		    (tilde_expanded = x_tilde_expand(tilde)) != NULL)
			x_preserve_tilde(words, nwords, tilde,
			    tilde_expanded);
		*wordsp = words;
	} else if (words) {
		x_free_words(nwords, words);
		*wordsp = NULL;
	}
done:
	if (tilde_name != NULL && !tilde_cached) {
		/* Do not let completion cache the home directory. */
		tp = ktsearch(&homedirs, tilde_name, hash(tilde_name));
		if (tp != NULL) {
			if (tp->flag & ALLOC) {
				tp->flag &= ~(ALLOC|ISSET);
				afree(tp->val.s, APERM);
			}
			ktdelete(tp);
		}
	}
	if (tilde)
		afree(tilde, ATEMP);
	if (tilde_expanded)
		afree(tilde_expanded, ATEMP);

	return nwords;
}

static void
x_preserve_tilde(char **words, int nwords, const char *tilde,
    const char *tilde_expanded)
{
	size_t tilde_len, exp_len;
	int i;

	tilde_len = strlen(tilde);
	exp_len = strlen(tilde_expanded);
	if (exp_len == 0)
		return;

	for (i = 0; i < nwords; i++) {
		char *w = words[i];
		size_t rest_len;
		char *nw;

		if (strncmp(w, tilde_expanded, exp_len) != 0)
			continue;
		if (w[exp_len] != '\0' && w[exp_len] != '/')
			continue;

		rest_len = strlen(w + exp_len);
		nw = areallocarray(NULL, tilde_len + rest_len + 1,
		    sizeof(char), ATEMP);
		memcpy(nw, tilde, tilde_len);
		memcpy(nw + tilde_len, w + exp_len, rest_len + 1);
		afree(w, ATEMP);
		words[i] = nw;
	}
}

/* Data structure used in x_command_glob() */
struct path_order_info {
	char *word;
	int base;
	int path_order;
};

static int path_order_cmp(const void *aa, const void *bb);

/* Compare routine used in x_command_glob() */
static int
path_order_cmp(const void *aa, const void *bb)
{
	const struct path_order_info *a = (const struct path_order_info *) aa;
	const struct path_order_info *b = (const struct path_order_info *) bb;
	int t;

	t = strcmp(a->word + a->base, b->word + b->base);
	return t ? t : a->path_order - b->path_order;
}

static int
x_command_glob(int flags, const char *str, int slen, char ***wordsp)
{
	char *toglob;
	char *pat;
	char *fpath;
	int nwords;
	XPtrV w;
	struct block *l;

	if (slen < 0)
		return 0;

	toglob = add_glob(str, slen);

	/* Convert "foo*" (toglob) to a pattern for future use */
	pat = evalstr(toglob, DOPAT|DOTILDE);
	afree(toglob, ATEMP);

	XPinit(w, 32);

	glob_table(pat, &w, &keywords);
	glob_table(pat, &w, &aliases);
	glob_table(pat, &w, &builtins);
	for (l = genv->loc; l; l = l->next)
		glob_table(pat, &w, &l->funs);

	glob_path(flags, pat, &w, search_path);
	if ((fpath = str_val(global("FPATH"))) != null)
		glob_path(flags, pat, &w, fpath);

	nwords = XPsize(w);

	if (!nwords) {
		*wordsp = NULL;
		XPfree(w);
		return 0;
	}

	/* Sort entries */
	if (flags & XCF_FULLPATH) {
		/* Sort by basename, then path order */
		struct path_order_info *info;
		struct path_order_info *last_info = NULL;
		char **words = (char **) XPptrv(w);
		int path_order = 0;
		int i;

		info = areallocarray(NULL, nwords,
		    sizeof(struct path_order_info), ATEMP);

		for (i = 0; i < nwords; i++) {
			info[i].word = words[i];
			info[i].base = x_basename(words[i], NULL);
			if (!last_info || info[i].base != last_info->base ||
			    strncmp(words[i], last_info->word, info[i].base) != 0) {
				last_info = &info[i];
				path_order++;
			}
			info[i].path_order = path_order;
		}
		qsort(info, nwords, sizeof(struct path_order_info),
			path_order_cmp);
		for (i = 0; i < nwords; i++)
			words[i] = info[i].word;
		afree(info, ATEMP);
	} else {
		/* Sort and remove duplicate entries */
		char **words = (char **) XPptrv(w);
		int i, j;

		qsortp(XPptrv(w), (size_t) nwords, xstrcmp);

		for (i = j = 0; i < nwords - 1; i++) {
			if (strcmp(words[i], words[i + 1]))
				words[j++] = words[i];
			else
				afree(words[i], ATEMP);
		}
		words[j++] = words[i];
		nwords = j;
		w.cur = (void **) &words[j];
	}

	XPput(w, NULL);
	*wordsp = (char **) XPclose(w);

	return nwords;
}

#define IS_WORDC(c)	!( ctype(c, C_LEX1) || (c) == '\'' || (c) == '"' || \
			    (c) == '`' || (c) == '=' || (c) == ':' )

static int
x_locate_word(const char *buf, int buflen, int pos, int *startp,
    int *is_commandp)
{
	int p;
	int start, end;

	/* Bad call?  Probably should report error */
	if (pos < 0 || pos > buflen) {
		*startp = pos;
		*is_commandp = 0;
		return 0;
	}
	/* The case where pos == buflen happens to take care of itself... */

	start = pos;
	/* Keep going backwards to start of word (has effect of allowing
	 * one blank after the end of a word)
	 */
	for (; (start > 0 && IS_WORDC(buf[start - 1])) ||
	    (start > 1 && buf[start-2] == '\\'); start--)
		;
	/* Go forwards to end of word */
	for (end = start; end < buflen && IS_WORDC(buf[end]); end++) {
		if (buf[end] == '\\' && (end+1) < buflen)
			end++;
	}

	if (is_commandp) {
		int iscmd;

		/* Figure out if this is a command */
		for (p = start - 1; p >= 0 && isspace((unsigned char)buf[p]);
		    p--)
			;
		iscmd = p < 0 || strchr(";|&()`", buf[p]);
		if (iscmd) {
			/* If command has a /, path, etc. is not searched;
			 * only current directory is searched, which is just
			 * like file globbing.
			 */
			for (p = start; p < end; p++)
				if (buf[p] == '/')
					break;
			iscmd = p == end;
		}
		*is_commandp = iscmd;
	}

	*startp = start;

	return end - start;
}

static int
x_try_array(const char *buf, int buflen, const char *want, int wantlen,
    int *nwords, char ***words)
{
	const char *cmd, *cp;
	int cmdlen, n, i, slen;
	char *name, *s;
	struct tbl *v, *vp;

	*nwords = 0;
	*words = NULL;

	/* Walk back to find start of command. */
	if (want == buf)
		return 0;
	for (cmd = want; cmd > buf; cmd--) {
		if (strchr(";|&()`", cmd[-1]) != NULL)
			break;
	}
	while (cmd < want && isspace((u_char)*cmd))
		cmd++;
	cmdlen = 0;
	while (cmd + cmdlen < want && !isspace((u_char)cmd[cmdlen]))
		cmdlen++;
	for (i = 0; i < cmdlen; i++) {
		if (!isalnum((u_char)cmd[i]) && cmd[i] != '_')
			return 0;
	}

	/* Take a stab at argument count from here. */
	n = 1;
	for (cp = cmd + cmdlen + 1; cp < want; cp++) {
		if (!isspace((u_char)cp[-1]) && isspace((u_char)*cp))
			n++;
	}

	/* Try to find the array. */
	if (asprintf(&name, "complete_%.*s_%d", cmdlen, cmd, n) == -1)
		internal_errorf("unable to allocate memory");
	v = global(name);
	free(name);
	if (~v->flag & (ISSET|ARRAY)) {
		if (asprintf(&name, "complete_%.*s", cmdlen, cmd) == -1)
			internal_errorf("unable to allocate memory");
		v = global(name);
		free(name);
		if (~v->flag & (ISSET|ARRAY))
			return 0;
	}

	/* Walk the array and build words list. */
	for (vp = v; vp; vp = vp->u.array) {
		if (~vp->flag & ISSET)
			continue;

		s = str_val(vp);
		slen = strlen(s);

		if (slen < wantlen)
			continue;
		if (slen > wantlen)
			slen = wantlen;
		if (slen != 0 && strncmp(s, want, slen) != 0)
			continue;

		*words = areallocarray(*words, (*nwords) + 2, sizeof **words,
		    ATEMP);
		(*words)[(*nwords)++] = str_save(s, ATEMP);
	}
	if (*nwords != 0)
		(*words)[*nwords] = NULL;

	return *nwords != 0;
}

int
x_cf_glob(int flags, const char *buf, int buflen, int pos, int *startp,
    int *endp, char ***wordsp, int *is_commandp)
{
	int len;
	int nwords;
	char **words = NULL;
	int is_command;
	int preserve_tilde;

	len = x_locate_word(buf, buflen, pos, startp, &is_command);
	if (!(flags & XCF_COMMAND))
		is_command = 0;
	preserve_tilde = len > 0 && buf[*startp] == '~';
	/* Don't do command globing on zero length strings - it takes too
	 * long and isn't very useful.  File globs are more likely to be
	 * useful, so allow these.
	 */
	if (len == 0 && is_command)
		return 0;

	if (is_command && (flags & XCF_FILE) && len > 0 &&
	    buf[*startp] == '~') {
		nwords = x_file_glob(flags, buf + *startp, len, &words,
		    preserve_tilde);
		if (nwords == 0)
			nwords = x_command_glob(flags, buf + *startp, len,
			    &words);
		else
			is_command = 0;
	} else if (is_command)
		nwords = x_command_glob(flags, buf + *startp, len, &words);
	else if (!x_try_array(buf, buflen, buf + *startp, len, &nwords, &words))
		nwords = x_file_glob(flags, buf + *startp, len, &words,
		    preserve_tilde);
	if (nwords == 0) {
		*wordsp = NULL;
		return 0;
	}

	if (is_commandp)
		*is_commandp = is_command;
	*wordsp = words;
	*endp = *startp + len;

	return nwords;
}

/* Given a string, copy it and possibly add a '*' to the end.  The
 * new string is returned.
 */
static char *
add_glob(const char *str, int slen)
{
	char *toglob;
	char *s;
	bool saw_slash = false;

	if (slen < 0)
		return NULL;

	toglob = str_nsave(str, slen + 1, ATEMP); /* + 1 for "*" or "/" */
	toglob[slen] = '\0';

	/*
	 * If the pathname contains a wildcard (an unquoted '*',
	 * '?', or '[') or parameter expansion ('$'), or a ~username
	 * with no trailing slash, then it is globbed based on that
	 * value.  Existing tilde directories get a slash appended
	 * instead of '*'; other tilde forms are left exact.
	 */
	for (s = toglob; *s; s++) {
		if (*s == '\\' && s[1])
			s++;
		else if (*s == '*' || *s == '[' || *s == '?' || *s == '$' ||
		    (s[1] == '(' /*)*/ && strchr("+@!", *s)))
			break;
		else if (*s == '/')
			saw_slash = true;
	}
	if (!*s) {
		if (*toglob != '~' || saw_slash) {
			toglob[slen] = '*';
			toglob[slen + 1] = '\0';
		} else if (x_tilde_is_dir(toglob, slen)) {
			toglob[slen] = '/';
			toglob[slen + 1] = '\0';
		}
	}

	return toglob;
}

/*
 * Find longest common prefix
 */
int
x_longest_prefix(int nwords, char *const *words)
{
	int i, j;
	int prefix_len;
	char *p;

	if (nwords <= 0)
		return 0;

	prefix_len = strlen(words[0]);
	for (i = 1; i < nwords; i++)
		for (j = 0, p = words[i]; j < prefix_len; j++)
			if (p[j] != words[0][j]) {
				prefix_len = j;
				break;
			}
	return prefix_len;
}

void
x_free_words(int nwords, char **words)
{
	int i;

	for (i = 0; i < nwords; i++)
		afree(words[i], ATEMP);
	afree(words, ATEMP);
}

/* Return the offset of the basename of string s (which ends at se - need not
 * be null terminated).  Trailing slashes are ignored.  If s is just a slash,
 * then the offset is 0 (actually, length - 1).
 *	s		Return
 *	/etc		1
 *	/etc/		1
 *	/etc//		1
 *	/etc/fo		5
 *	foo		0
 *	///		2
 *			0
 */
int
x_basename(const char *s, const char *se)
{
	const char *p;

	if (se == NULL)
		se = s + strlen(s);
	if (s == se)
		return 0;

	/* Skip trailing slashes */
	for (p = se - 1; p > s && *p == '/'; p--)
		;
	for (; p > s && *p != '/'; p--)
		;
	if (*p == '/' && p + 1 < se)
		p++;

	return p - s;
}

/*
 *  Apply pattern matching to a table: all table entries that match a pattern
 * are added to wp.
 */
static void
glob_table(const char *pat, XPtrV *wp, struct table *tp)
{
	struct tstate ts;
	struct tbl *te;

	for (ktwalk(&ts, tp); (te = ktnext(&ts)); ) {
		if (gmatch_(te->name, pat, false))
			XPput(*wp, str_save(te->name, ATEMP));
	}
}

static void
glob_path(int flags, const char *pat, XPtrV *wp, const char *path)
{
	const char *sp, *p;
	char *xp;
	int staterr;
	int pathlen;
	int patlen;
	int oldsize, newsize, i, j;
	char **words;
	XString xs;

	patlen = strlen(pat) + 1;
	sp = path;
	Xinit(xs, xp, patlen + 128, ATEMP);
	while (sp) {
		xp = Xstring(xs, xp);
		if (!(p = strchr(sp, ':')))
			p = sp + strlen(sp);
		pathlen = p - sp;
		if (pathlen) {
			/* Copy sp into xp, stuffing any MAGIC characters
			 * on the way
			 */
			const char *s = sp;

			XcheckN(xs, xp, pathlen * 2);
			while (s < p) {
				if (ISMAGIC(*s))
					*xp++ = MAGIC;
				*xp++ = *s++;
			}
			*xp++ = '/';
			pathlen++;
		}
		sp = p;
		XcheckN(xs, xp, patlen);
		memcpy(xp, pat, patlen);

		oldsize = XPsize(*wp);
		glob_str(Xstring(xs, xp), wp, 1); /* mark dirs */
		newsize = XPsize(*wp);

		/* Check that each match is executable... */
		words = (char **) XPptrv(*wp);
		for (i = j = oldsize; i < newsize; i++) {
			staterr = 0;
			if ((search_access(words[i], X_OK, &staterr) >= 0) ||
			    (staterr == EISDIR)) {
				words[j] = words[i];
				if (!(flags & XCF_FULLPATH))
					memmove(words[j], words[j] + pathlen,
					    strlen(words[j] + pathlen) + 1);
				j++;
			} else
				afree(words[i], ATEMP);
		}
		wp->cur = (void **) &words[j];

		if (!*sp++)
			break;
	}
	Xfree(xs, xp);
}

/*
 * if argument string contains any special characters, they will
 * be escaped and the result will be put into edit buffer by
 * keybinding-specific function
 */
int
x_escape(const char *s, size_t len, int (*putbuf_func) (const char *, size_t))
{
	size_t add, wlen;
	const char *ifs = str_val(local("IFS", 0));
	int rval = 0;

	for (add = 0, wlen = len; wlen - add > 0; add++) {
		if (strchr("!\"#$&'()*:;<=>?[\\]`{|}", s[add]) ||
		    strchr(ifs, s[add])) {
			if (putbuf_func(s, add) != 0) {
				rval = -1;
				break;
			}

			putbuf_func("\\", 1);
			putbuf_func(&s[add], 1);

			add++;
			wlen -= add;
			s += add;
			add = -1; /* after the increment it will go to 0 */
		}
	}
	if (wlen > 0 && rval == 0)
		rval = putbuf_func(s, wlen);

	return (rval);
}

/*
 * Emacs command line editing
 */

/*
 *  Emacs-like command line editing and history
 *
 *  created by Ron Natalie at BRL
 *  modified by Doug Kingston, Doug Gwyn, and Lou Salkind
 *  adapted to PD ksh by Eric Gisin
 *
 * partial rewrite by Marco Peereboom <marco@openbsd.org>
 * under the same license
 */

static	Area	aedit;
#define	AEDIT	&aedit		/* area for kill ring and macro defns */

/* values returned by keyboard functions */
#define	KSTD	0
#define	KEOL	1		/* ^M, ^J */
#define	KINTR	2		/* ^G, ^C */

typedef int (*kb_func)(int);

struct	x_ftab {
	kb_func		xf_func;
	const char	*xf_name;
	short		xf_flags;
};

#define XF_ARG		1	/* command takes number prefix */
#define	XF_NOBIND	2	/* not allowed to bind to function */
#define	XF_PREFIX	4	/* function sets prefix */

/* Separator for completion */
#define	is_cfs(c)	(c == ' ' || c == '\t' || c == '"' || c == '\'')

/* Separator for motion */
#define	is_mfs(c)	(!(isalnum((unsigned char)c) || \
			c == '_' || c == '$' || c & 0x80))

/* Arguments for do_complete()
 * 0 = enumerate  M-= complete as much as possible and then list
 * 1 = complete   M-Esc
 * 2 = list       M-?
 */
typedef enum {
	CT_LIST,	/* list the possible completions */
	CT_COMPLETE,	/* complete to longest prefix */
	CT_COMPLIST	/* complete and then list (if non-exact) */
} Comp_type;

/* keybindings */
struct kb_entry {
	TAILQ_ENTRY(kb_entry)	entry;
	unsigned char		*seq;
	int			len;
	struct x_ftab		*ftab;
	void			*args;
};
TAILQ_HEAD(kb_list, kb_entry);
struct kb_list			kblist = TAILQ_HEAD_INITIALIZER(kblist);

/* { from 4.9 edit.h */
/*
 * The following are used for my horizontal scrolling stuff
 */
static char    *xbuf;		/* beg input buffer */
static char    *xend;		/* end input buffer */
static char    *xcp;		/* current position */
static char    *xep;		/* current end */
static char    *xbp;		/* start of visible portion of input buffer */
static char    *xlp;		/* last byte visible on screen */
static int	x_adj_ok;
/*
 * we use x_adj_done so that functions can tell
 * whether x_adjust() has been called while they are active.
 */
static int	x_adj_done;

static int	xx_cols;
static int	x_col;
static int	x_displen;
static int	x_arg;		/* general purpose arg */
static int	x_arg_defaulted;/* x_arg not explicitly set; defaulted to 1 */

static int	xlp_valid;
/* end from 4.9 edit.h } */
static	int	x_tty;		/* are we on a tty? */
static	int	x_bind_quiet;	/* be quiet when binding keys */
static int	(*x_last_command)(int);

static	char   **x_histp;	/* history position */
static	int	x_nextcmd;	/* for newline-and-next */
static	char	*xmp;		/* mark pointer */
#define	KILLSIZE	20
static	char	*killstack[KILLSIZE];
static	int	killsp, killtp;
static	int	x_literal_set;
static	int	x_arg_set;
static	char	*macro_args;
static	int	em_prompt_skip;
static	int	prompt_redraw;

static int	x_ins(char *);
static void	x_delete(int, int);
static int	x_bword(void);
static int	x_fword(void);
static void	x_goto(char *);
static void	x_bs(int);
static int	x_size_str(char *);
static int	x_size(int);
static void	x_zots(char *);
static void	x_zotc(int);
static void	x_load_hist(char **);
static int	x_search(char *, int, int);
static int	x_match(char *, char *);
static void	x_redraw(int);
static void	x_push(int);
static void	x_adjust(void);
static void	x_e_ungetc(int);
static int	x_e_getc(void);
static int	x_e_getu8(char *, int);
static void	x_e_putc(int);
static void	x_e_puts(const char *);
static int	x_comment(int);
static int	x_fold_case(int);
static char	*x_lastcp(void);
static void	do_complete(int, Comp_type);
static int	em_isu8cont(unsigned char);

/* proto's for keybindings */
static int	x_abort(int);
static int	x_beg_hist(int);
static int	x_clear_screen(int);
static int	x_comp_comm(int);
static int	x_comp_file(int);
static int	x_complete(int);
static int	x_del_back(int);
static int	x_del_bword(int);
static int	x_del_char(int);
static int	x_del_fword(int);
static int	x_del_line(int);
static int	x_draw_line(int);
static int	x_end_hist(int);
static int	x_end_of_text(int);
static int	x_enumerate(int);
static int	x_eot_del(int);
static int	x_error(int);
static int	x_goto_hist(int);
static int	x_ins_string(int);
static int	x_insert(int);
static int	x_kill(int);
static int	x_kill_region(int);
static int	x_list_comm(int);
static int	x_list_file(int);
static int	x_literal(int);
static int	x_meta_yank(int);
static int	x_mv_back(int);
static int	x_mv_begin(int);
static int	x_mv_bword(int);
static int	x_mv_end(int);
static int	x_mv_forw(int);
static int	x_mv_fword(int);
static int	x_newline(int);
static int	x_next_com(int);
static int	x_nl_next_com(int);
static int	x_noop(int);
static int	x_prev_com(int);
static int	x_prev_histword(int);
static int	x_search_char_forw(int);
static int	x_search_char_back(int);
static int	x_search_hist(int);
static int	x_set_mark(int);
static int	x_transpose(int);
static int	x_xchg_point_mark(int);
static int	x_yank(int);
static int	x_comp_list(int);
static int	x_expand(int);
static int	x_fold_capitalize(int);
static int	x_fold_lower(int);
static int	x_fold_upper(int);
static int	x_set_arg(int);
static int	x_comment(int);
#ifdef DEBUG
static int	x_debug_info(int);
#endif

static const struct x_ftab x_ftab[] = {
	{ x_abort,		"abort",			0 },
	{ x_beg_hist,		"beginning-of-history",		0 },
	{ x_clear_screen,	"clear-screen",			0 },
	{ x_comp_comm,		"complete-command",		0 },
	{ x_comp_file,		"complete-file",		0 },
	{ x_complete,		"complete",			0 },
	{ x_del_back,		"delete-char-backward",		XF_ARG },
	{ x_del_bword,		"delete-word-backward",		XF_ARG },
	{ x_del_char,		"delete-char-forward",		XF_ARG },
	{ x_del_fword,		"delete-word-forward",		XF_ARG },
	{ x_del_line,		"kill-line",			0 },
	{ x_draw_line,		"redraw",			0 },
	{ x_end_hist,		"end-of-history",		0 },
	{ x_end_of_text,	"eot",				0 },
	{ x_enumerate,		"list",				0 },
	{ x_eot_del,		"eot-or-delete",		XF_ARG },
	{ x_error,		"error",			0 },
	{ x_goto_hist,		"goto-history",			XF_ARG },
	{ x_ins_string,		"macro-string",			XF_NOBIND },
	{ x_insert,		"auto-insert",			XF_ARG },
	{ x_kill,		"kill-to-eol",			XF_ARG },
	{ x_kill_region,	"kill-region",			0 },
	{ x_list_comm,		"list-command",			0 },
	{ x_list_file,		"list-file",			0 },
	{ x_literal,		"quote",			0 },
	{ x_meta_yank,		"yank-pop",			0 },
	{ x_mv_back,		"backward-char",		XF_ARG },
	{ x_mv_begin,		"beginning-of-line",		0 },
	{ x_mv_bword,		"backward-word",		XF_ARG },
	{ x_mv_end,		"end-of-line",			0 },
	{ x_mv_forw,		"forward-char",			XF_ARG },
	{ x_mv_fword,		"forward-word",			XF_ARG },
	{ x_newline,		"newline",			0 },
	{ x_next_com,		"down-history",			XF_ARG },
	{ x_nl_next_com,	"newline-and-next",		0 },
	{ x_noop,		"no-op",			0 },
	{ x_prev_com,		"up-history",			XF_ARG },
	{ x_prev_histword,	"prev-hist-word",		XF_ARG },
	{ x_search_char_forw,	"search-character-forward",	XF_ARG },
	{ x_search_char_back,	"search-character-backward",	XF_ARG },
	{ x_search_hist,	"search-history",		0 },
	{ x_set_mark,		"set-mark-command",		0 },
	{ x_transpose,		"transpose-chars",		0 },
	{ x_xchg_point_mark,	"exchange-point-and-mark",	0 },
	{ x_yank,		"yank",				0 },
	{ x_comp_list,		"complete-list",		0 },
	{ x_expand,		"expand-file",			0 },
	{ x_fold_capitalize,	"capitalize-word",		XF_ARG },
	{ x_fold_lower,		"downcase-word",		XF_ARG },
	{ x_fold_upper,		"upcase-word",			XF_ARG },
	{ x_set_arg,		"set-arg",			XF_NOBIND },
	{ x_comment,		"comment",			0 },
	{ 0, 0, 0 },
#ifdef DEBUG
	{ x_debug_info,		"debug-info",			0 },
#else
	{ 0, 0, 0 },
#endif
	{ 0, 0, 0 },
};

static int
em_isu8cont(unsigned char c)
{
	return (c & (0x80 | 0x40)) == 0x80;
}

int
x_emacs(char *buf, size_t len)
{
	struct kb_entry		*k, *kmatch = NULL;
	char			line[LINE + 1];
	int			at = 0, ntries = 0, submatch, ret;
	const char		*p;

	xbp = xbuf = buf; xend = buf + len;
	xlp = xcp = xep = buf;
	*xcp = 0;
	xlp_valid = true;
	xmp = NULL;
	x_histp = histptr + 1;

	xx_cols = x_cols;
	x_col = promptlen(prompt, &p);
	em_prompt_skip = p - prompt;
	x_adj_ok = 1;
	prompt_redraw = 1;
	if (x_col > xx_cols)
		x_col = x_col - (x_col / xx_cols) * xx_cols;
	x_displen = xx_cols - 2 - x_col;
	x_adj_done = 0;

	pprompt(prompt, 0);
	if (x_displen < 1) {
		x_col = 0;
		x_displen = xx_cols - 2;
		x_e_putc('\n');
		prompt_redraw = 0;
	}

	if (x_nextcmd >= 0) {
		int off = source->line - x_nextcmd;
		if (histptr - history >= off)
			x_load_hist(histptr - off);
		x_nextcmd = -1;
	}

	x_literal_set = 0;
	x_arg = -1;
	x_last_command = NULL;
	while (1) {
		x_flush();
		if ((at = x_e_getu8(line, at)) < 0)
			return 0;
		ntries++;

		if (x_arg == -1) {
			x_arg = 1;
			x_arg_defaulted = 1;
		}

		if (x_literal_set) {
			/* literal, so insert it */
			x_literal_set = 0;
			submatch = 0;
		} else {
			submatch = 0;
			kmatch = NULL;
			TAILQ_FOREACH(k, &kblist, entry) {
				if (at > k->len)
					continue;

				if (memcmp(k->seq, line, at) == 0) {
					/* sub match */
					submatch++;
					if (k->len == at)
						kmatch = k;
				}

				/* see if we can abort search early */
				if (submatch > 1)
					break;
			}
		}

		if (submatch == 1 && kmatch) {
			if (kmatch->ftab->xf_func == x_ins_string &&
			    kmatch->args && !macro_args) {
				/* treat macro string as input */
				macro_args = kmatch->args;
				ret = KSTD;
			} else
				ret = kmatch->ftab->xf_func(line[at - 1]);
		} else {
			if (submatch)
				continue;
			if (ntries > 1) {
				ret = x_error(0); /* unmatched meta sequence */
			} else if (at > 1) {
				x_ins(line);
				ret = KSTD;
			} else {
				ret = x_insert(line[0]);
			}
		}

		switch (ret) {
		case KSTD:
			if (kmatch)
				x_last_command = kmatch->ftab->xf_func;
			else
				x_last_command = NULL;
			break;
		case KEOL:
			ret = xep - xbuf;
			return (ret);
			break;
		case KINTR:
			trapsig(SIGINT);
			x_mode(false);
			unwind(LSHELL);
			x_arg = -1;
			break;
		default:
			bi_errorf("invalid return code"); /* can't happen */
		}

		/* reset meta sequence */
		at = ntries = 0;
		if (x_arg_set)
			x_arg_set = 0; /* reset args next time around */
		else
			x_arg = -1;
	}
}

static int
x_insert(int c)
{
	char	str[2];

	/*
	 *  Should allow tab and control chars.
	 */
	if (c == 0) {
		x_e_putc(BEL);
		return KSTD;
	}
	str[0] = c;
	str[1] = '\0';
	while (x_arg--)
		x_ins(str);
	return KSTD;
}

static int
x_ins_string(int c)
{
	return x_insert(c);
}

static int
x_do_ins(const char *cp, size_t len)
{
	if (xep+len >= xend) {
		x_e_putc(BEL);
		return -1;
	}

	memmove(xcp+len, xcp, xep - xcp + 1);
	memmove(xcp, cp, len);
	xcp += len;
	xep += len;
	return 0;
}

static int
x_ins(char *s)
{
	char	*cp = xcp;
	int	adj = x_adj_done;

	if (x_do_ins(s, strlen(s)) < 0)
		return -1;
	/*
	 * x_zots() may result in a call to x_adjust()
	 * we want xcp to reflect the new position.
	 */
	xlp_valid = false;
	x_lastcp();
	x_adj_ok = (xcp >= xlp);
	x_zots(cp);
	if (adj == x_adj_done) {	/* has x_adjust() been called? */
		/* no */
		for (cp = xlp; cp > xcp; )
			x_bs(*--cp);
	}

	x_adj_ok = 1;
	return 0;
}

static int
x_del_back(int c)
{
	int col = xcp - xbuf;

	if (col == 0) {
		x_e_putc(BEL);
		return KSTD;
	}
	if (x_arg > col)
		x_arg = col;
	while (x_arg < col && em_isu8cont(xcp[-x_arg]))
		x_arg++;
	x_goto(xcp - x_arg);
	x_delete(x_arg, false);
	return KSTD;
}

static int
x_del_char(int c)
{
	int nleft = xep - xcp;

	if (!nleft) {
		x_e_putc(BEL);
		return KSTD;
	}
	if (x_arg > nleft)
		x_arg = nleft;
	while (x_arg < nleft && em_isu8cont(xcp[x_arg]))
		x_arg++;
	x_delete(x_arg, false);
	return KSTD;
}

/* Delete nc bytes to the right of the cursor (including cursor position) */
static void
x_delete(int nc, int push)
{
	int	i,j;
	char	*cp;

	if (nc == 0)
		return;
	if (xmp != NULL && xmp > xcp) {
		if (xcp + nc > xmp)
			xmp = xcp;
		else
			xmp -= nc;
	}

	/*
	 * This lets us yank a word we have deleted.
	 */
	if (push)
		x_push(nc);

	xep -= nc;
	cp = xcp;
	j = 0;
	i = nc;
	while (i--) {
		j += x_size((unsigned char)*cp++);
	}
	memmove(xcp, xcp+nc, xep - xcp + 1);	/* Copies the null */
	x_adj_ok = 0;			/* don't redraw */
	xlp_valid = false;
	x_zots(xcp);
	/*
	 * if we are already filling the line,
	 * there is no need to ' ','\b'.
	 * But if we must, make sure we do the minimum.
	 */
	if ((i = xx_cols - 2 - x_col) > 0) {
		j = (j < i) ? j : i;
		i = j;
		while (i--)
			x_e_putc(' ');
		i = j;
		while (i--)
			x_e_putc('\b');
	}
	/*x_goto(xcp);*/
	x_adj_ok = 1;
	xlp_valid = false;
	for (cp = x_lastcp(); cp > xcp; )
		x_bs(*--cp);

	return;
}

static int
x_del_bword(int c)
{
	x_delete(x_bword(), true);
	return KSTD;
}

static int
x_mv_bword(int c)
{
	(void)x_bword();
	return KSTD;
}

static int
x_mv_fword(int c)
{
	x_goto(xcp + x_fword());
	return KSTD;
}

static int
x_del_fword(int c)
{
	x_delete(x_fword(), true);
	return KSTD;
}

static int
x_bword(void)
{
	int	nc = 0;
	char	*cp = xcp;

	if (cp == xbuf) {
		x_e_putc(BEL);
		return 0;
	}
	while (x_arg--) {
		while (cp != xbuf && is_mfs(cp[-1])) {
			cp--;
			nc++;
		}
		while (cp != xbuf && !is_mfs(cp[-1])) {
			cp--;
			nc++;
		}
	}
	x_goto(cp);
	return nc;
}

static int
x_fword(void)
{
	int	nc = 0;
	char	*cp = xcp;

	if (cp == xep) {
		x_e_putc(BEL);
		return 0;
	}
	while (x_arg--) {
		while (cp != xep && is_mfs(*cp)) {
			cp++;
			nc++;
		}
		while (cp != xep && !is_mfs(*cp)) {
			cp++;
			nc++;
		}
	}
	return nc;
}

static void
x_goto(char *cp)
{
	if (cp < xbp || cp >= (xbp + x_displen)) {
		/* we are heading off screen */
		xcp = cp;
		x_adjust();
	} else if (cp < xcp) {		/* move back */
		while (cp < xcp)
			x_bs((unsigned char)*--xcp);
	} else if (cp > xcp) {		/* move forward */
		while (cp > xcp)
			x_zotc((unsigned char)*xcp++);
	}
}

static void
x_bs(int c)
{
	int i;

	i = x_size(c);
	while (i--)
		x_e_putc('\b');
}

static int
x_size_str(char *cp)
{
	int size = 0;
	while (*cp)
		size += x_size(*cp++);
	return size;
}

static int
x_size(int c)
{
	if (c=='\t')
		return 4;	/* Kludge, tabs are always four spaces. */
	if (iscntrl(c))		/* control char */
		return 2;
	if (em_isu8cont(c))
		return 0;
	return 1;
}

static void
x_zots(char *str)
{
	int	adj = x_adj_done;

	if (str > xbuf && em_isu8cont(*str)) {
		while (str > xbuf && em_isu8cont(*str))
			str--;
		x_e_putc('\b');
	}
	x_lastcp();
	while (*str && str < xlp && adj == x_adj_done)
		x_zotc(*str++);
}

static void
x_zotc(int c)
{
	if (c == '\t') {
		/*  Kludge, tabs are always four spaces.  */
		x_e_puts("    ");
	} else if (iscntrl(c)) {
		x_e_putc('^');
		x_e_putc(UNCTRL(c));
	} else
		x_e_putc(c);
}

static int
x_mv_back(int c)
{
	int col = xcp - xbuf;

	if (col == 0) {
		x_e_putc(BEL);
		return KSTD;
	}
	if (x_arg > col)
		x_arg = col;
	while (x_arg < col && em_isu8cont(xcp[-x_arg]))
		x_arg++;
	x_goto(xcp - x_arg);
	return KSTD;
}

static int
x_mv_forw(int c)
{
	int nleft = xep - xcp;

	if (!nleft) {
		x_e_putc(BEL);
		return KSTD;
	}
	if (x_arg > nleft)
		x_arg = nleft;
	while (x_arg < nleft && em_isu8cont(xcp[x_arg]))
		x_arg++;
	x_goto(xcp + x_arg);
	return KSTD;
}

static int
x_search_char_forw(int c)
{
	char *cp = xcp;

	*xep = '\0';
	c = x_e_getc();
	while (x_arg--) {
		if (c < 0 ||
		    ((cp = (cp == xep) ? NULL : strchr(cp + 1, c)) == NULL &&
		    (cp = strchr(xbuf, c)) == NULL)) {
			x_e_putc(BEL);
			return KSTD;
		}
	}
	x_goto(cp);
	return KSTD;
}

static int
x_search_char_back(int c)
{
	char *cp = xcp, *p;

	c = x_e_getc();
	for (; x_arg--; cp = p)
		for (p = cp; ; ) {
			if (p-- == xbuf)
				p = xep;
			if (c < 0 || p == cp) {
				x_e_putc(BEL);
				return KSTD;
			}
			if (*p == c)
				break;
		}
	x_goto(cp);
	return KSTD;
}

static int
x_newline(int c)
{
	x_e_putc('\r');
	x_e_putc('\n');
	x_flush();
	*xep++ = '\n';
	return KEOL;
}

static int
x_end_of_text(int c)
{
	x_zotc(edchars.eof);
	x_putc('\r');
	x_putc('\n');
	x_flush();
	return KEOL;
}

static int x_beg_hist(int c) { x_load_hist(history); return KSTD;}

static int x_end_hist(int c) { x_load_hist(histptr); return KSTD;}

static int x_prev_com(int c) { x_load_hist(x_histp - x_arg); return KSTD;}

static int x_next_com(int c) { x_load_hist(x_histp + x_arg); return KSTD;}

/* Goto a particular history number obtained from argument.
 * If no argument is given history 1 is probably not what you
 * want so we'll simply go to the oldest one.
 */
static int
x_goto_hist(int c)
{
	if (x_arg_defaulted)
		x_load_hist(history);
	else
		x_load_hist(histptr + x_arg - source->line);
	return KSTD;
}

static void
x_load_hist(char **hp)
{
	int	oldsize;

	if (hp < history || hp > histptr) {
		x_e_putc(BEL);
		return;
	}
	x_histp = hp;
	oldsize = x_size_str(xbuf);
	strlcpy(xbuf, *hp, xend - xbuf);
	xbp = xbuf;
	xep = xcp = xbuf + strlen(xbuf);
	xlp_valid = false;
	if (xep <= x_lastcp())
		x_redraw(oldsize);
	x_goto(xep);
}

static int
x_nl_next_com(int c)
{
	x_nextcmd = source->line - (histptr - x_histp) + 1;
	return (x_newline(c));
}

static int
x_eot_del(int c)
{
	if (xep == xbuf && x_arg_defaulted)
		return (x_end_of_text(c));
	else
		return (x_del_char(c));
}

static kb_func
kb_find_hist_func(char c)
{
	struct kb_entry		*k;
	char			line[LINE + 1];

	line[0] = c;
	line[1] = '\0';
	TAILQ_FOREACH(k, &kblist, entry)
		if (!strcmp(k->seq, line))
			return (k->ftab->xf_func);

	return (x_insert);
}

/* reverse incremental history search */
static int
x_search_hist(int c)
{
	int offset = -1;	/* offset of match in xbuf, else -1 */
	char pat [256+1];	/* pattern buffer */
	char *p = pat;
	int (*f)(int);

	*p = '\0';
	while (1) {
		if (offset < 0) {
			x_e_puts("\nI-search: ");
			x_e_puts(pat);
		}
		x_flush();
		if ((c = x_e_getc()) < 0)
			return KSTD;
		f = kb_find_hist_func(c);
		if (c == CTRL('[') || c == CTRL('@')) {
			x_e_ungetc(c);
			break;
		} else if (f == x_search_hist)
			offset = x_search(pat, 0, offset);
		else if (f == x_del_back) {
			if (p == pat) {
				offset = -1;
				break;
			}
			if (p > pat)
				*--p = '\0';
			if (p == pat)
				offset = -1;
			else
				offset = x_search(pat, 1, offset);
			continue;
		} else if (f == x_insert) {
			/* add char to pattern */
			/* overflow check... */
			if (p >= &pat[sizeof(pat) - 1]) {
				x_e_putc(BEL);
				continue;
			}
			*p++ = c, *p = '\0';
			if (offset >= 0) {
				/* already have partial match */
				offset = x_match(xbuf, pat);
				if (offset >= 0) {
					x_goto(xbuf + offset + (p - pat) -
					    (*pat == '^'));
					continue;
				}
			}
			offset = x_search(pat, 0, offset);
		} else { /* other command */
			x_e_ungetc(c);
			break;
		}
	}
	if (offset < 0)
		x_redraw(-1);
	return KSTD;
}

/* search backward from current line */
static int
x_search(char *pat, int sameline, int offset)
{
	char **hp;
	int i;

	for (hp = x_histp - (sameline ? 0 : 1) ; hp >= history; --hp) {
		i = x_match(*hp, pat);
		if (i >= 0) {
			if (offset < 0)
				x_e_putc('\n');
			x_load_hist(hp);
			x_goto(xbuf + i + strlen(pat) - (*pat == '^'));
			return i;
		}
	}
	x_e_putc(BEL);
	x_histp = histptr;
	return -1;
}

/* return position of first match of pattern in string, else -1 */
static int
x_match(char *str, char *pat)
{
	if (*pat == '^') {
		return (strncmp(str, pat+1, strlen(pat+1)) == 0) ? 0 : -1;
	} else {
		char *q = strstr(str, pat);
		return (q == NULL) ? -1 : q - str;
	}
}

static int
x_del_line(int c)
{
	int	i, j;

	*xep = 0;
	i = xep - xbuf;
	j = x_size_str(xbuf);
	xcp = xbuf;
	x_push(i);
	xlp = xbp = xep = xbuf;
	xlp_valid = true;
	*xcp = 0;
	xmp = NULL;
	x_redraw(j);
	return KSTD;
}

static int
x_mv_end(int c)
{
	x_goto(xep);
	return KSTD;
}

static int
x_mv_begin(int c)
{
	x_goto(xbuf);
	return KSTD;
}

static int
x_draw_line(int c)
{
	x_redraw(-1);
	return KSTD;
}

static int
x_clear_screen(int c)
{
	x_redraw(-2);
	return KSTD;
}

/* Redraw (part of) the line.
 * A non-negative limit is the screen column up to which needs
 * redrawing. A limit of -1 redraws on a new line, while a limit
 * of -2 (attempts to) clear the screen.
 */
static void
x_redraw(int limit)
{
	int	i, j, truncate = 0;
	char	*cp;

	x_adj_ok = 0;
	if (limit == -2)
		x_puts(CLEAR_SCREEN);
	else if (limit == -1)
		x_e_putc('\n');
	else if (limit >= 0)
		x_e_putc('\r');
	x_flush();
	if (xbp == xbuf) {
		x_col = promptlen(prompt, NULL);
		if (x_col > xx_cols)
			truncate = (x_col / xx_cols) * xx_cols;
		if (prompt_redraw)
			pprompt(prompt + em_prompt_skip, truncate);
	}
	if (x_col > xx_cols)
		x_col = x_col - (x_col / xx_cols) * xx_cols;
	x_displen = xx_cols - 2 - x_col;
	if (x_displen < 1) {
		x_col = 0;
		x_displen = xx_cols - 2;
	}
	xlp_valid = false;
	x_lastcp();
	x_zots(xbp);
	if (xbp != xbuf || xep > xlp)
		limit = xx_cols;
	if (limit >= 0) {
		if (xep > xlp)
			i = 0;			/* we fill the line */
		else
			i = limit - (xlp - xbp);

		for (j = 0; j < i && x_col < (xx_cols - 2); j++)
			x_e_putc(' ');
		i = ' ';
		if (xep > xlp) {		/* more off screen */
			if (xbp > xbuf)
				i = '*';
			else
				i = '>';
		} else if (xbp > xbuf)
			i = '<';
		x_e_putc(i);
		j++;
		while (j--)
			x_e_putc('\b');
	}
	for (cp = xlp; cp > xcp; )
		x_bs(*--cp);
	x_adj_ok = 1;
#ifdef DEBUG
	x_flush();
#endif
	return;
}

static int
x_transpose(int c)
{
	char	tmp;

	/* What transpose is meant to do seems to be up for debate. This
	 * is a general summary of the options; the text is abcd with the
	 * upper case character or underscore indicating the cursor position:
	 *     Who			Before	After  Before	After
	 *     at&t ksh in emacs mode:	abCd	abdC   abcd_	(bell)
	 *     at&t ksh in gmacs mode:	abCd	baCd   abcd_	abdc_
	 *     gnu emacs:		abCd	acbD   abcd_	abdc_
	 * Pdksh currently goes with GNU behavior since I believe this is the
	 * most common version of emacs, unless in gmacs mode, in which case
	 * it does the at&t ksh gmacs mode.
	 * This should really be broken up into 3 functions so users can bind
	 * to the one they want.
	 */
	if (xcp == xbuf) {
		x_e_putc(BEL);
		return KSTD;
	} else if (xcp == xep || Flag(FGMACS)) {
		if (xcp - xbuf == 1) {
			x_e_putc(BEL);
			return KSTD;
		}
		/* Gosling/Unipress emacs style: Swap two characters before the
		 * cursor, do not change cursor position
		 */
		x_bs(xcp[-1]);
		x_bs(xcp[-2]);
		x_zotc(xcp[-1]);
		x_zotc(xcp[-2]);
		tmp = xcp[-1];
		xcp[-1] = xcp[-2];
		xcp[-2] = tmp;
	} else {
		/* GNU emacs style: Swap the characters before and under the
		 * cursor, move cursor position along one.
		 */
		x_bs(xcp[-1]);
		x_zotc(xcp[0]);
		x_zotc(xcp[-1]);
		tmp = xcp[-1];
		xcp[-1] = xcp[0];
		xcp[0] = tmp;
		x_bs(xcp[0]);
		x_goto(xcp + 1);
	}
	return KSTD;
}

static int
x_literal(int c)
{
	x_literal_set = 1;
	return KSTD;
}

static int
x_kill(int c)
{
	int col = xcp - xbuf;
	int lastcol = xep - xbuf;
	int ndel;

	if (x_arg_defaulted)
		x_arg = lastcol;
	else if (x_arg > lastcol)
		x_arg = lastcol;
	while (x_arg < lastcol && em_isu8cont(xbuf[x_arg]))
		x_arg++;
	ndel = x_arg - col;
	if (ndel < 0) {
		x_goto(xbuf + x_arg);
		ndel = -ndel;
	}
	x_delete(ndel, true);
	return KSTD;
}

static void
x_push(int nchars)
{
	char	*cp = str_nsave(xcp, nchars, AEDIT);
	afree(killstack[killsp], AEDIT);
	killstack[killsp] = cp;
	killsp = (killsp + 1) % KILLSIZE;
}

static int
x_yank(int c)
{
	if (killsp == 0)
		killtp = KILLSIZE;
	else
		killtp = killsp;
	killtp --;
	if (killstack[killtp] == 0) {
		x_e_puts("\nnothing to yank");
		x_redraw(-1);
		return KSTD;
	}
	xmp = xcp;
	x_ins(killstack[killtp]);
	return KSTD;
}

static int
x_meta_yank(int c)
{
	int	len;
	if ((x_last_command != x_yank && x_last_command != x_meta_yank) ||
	    killstack[killtp] == 0) {
		killtp = killsp;
		x_e_puts("\nyank something first");
		x_redraw(-1);
		return KSTD;
	}
	len = strlen(killstack[killtp]);
	x_goto(xcp - len);
	x_delete(len, false);
	do {
		if (killtp == 0)
			killtp = KILLSIZE - 1;
		else
			killtp--;
	} while (killstack[killtp] == 0);
	x_ins(killstack[killtp]);
	return KSTD;
}

static int
x_abort(int c)
{
	/* x_zotc(c); */
	xlp = xep = xcp = xbp = xbuf;
	xlp_valid = true;
	*xcp = 0;
	return KINTR;
}

static int
x_error(int c)
{
	x_e_putc(BEL);
	return KSTD;
}

static char *
kb_encode(const char *s)
{
	static char		l[LINE + 1];
	int			at = 0;

	l[at] = '\0';
	while (*s) {
		if (*s == '^') {
			s++;
			if (*s >= '?')
				l[at++] = CTRL(*s);
			else {
				l[at++] = '^';
				s--;
			}
		} else
			l[at++] = *s;
		l[at] = '\0';
		s++;
	}
	return (l);
}

static char *
kb_decode(const char *s)
{
	static char		l[LINE + 1];
	unsigned int		i, at = 0;

	l[0] = '\0';
	for (i = 0; i < strlen(s); i++) {
		if (iscntrl((unsigned char)s[i])) {
			l[at++] = '^';
			l[at++] = UNCTRL(s[i]);
		} else
			l[at++] = s[i];
		l[at] = '\0';
	}

	return (l);
}

static int
kb_match(char *s)
{
	int			len = strlen(s);
	struct kb_entry		*k;

	TAILQ_FOREACH(k, &kblist, entry) {
		if (len > k->len)
			continue;

		if (memcmp(k->seq, s, len) == 0)
			return (1);
	}

	return (0);
}

static void
kb_del(struct kb_entry *k)
{
	TAILQ_REMOVE(&kblist, k, entry);
	free(k->args);
	afree(k, AEDIT);
}

static struct kb_entry *
kb_add_string(kb_func func, void *args, char *str)
{
	unsigned int		ele, count;
	struct kb_entry		*k;
	struct x_ftab		*xf = NULL;

	for (ele = 0; ele < NELEM(x_ftab); ele++)
		if (x_ftab[ele].xf_func == func) {
			xf = (struct x_ftab *)&x_ftab[ele];
			break;
		}
	if (xf == NULL)
		return (NULL);

	if (kb_match(str)) {
		if (x_bind_quiet == 0)
			bi_errorf("duplicate binding for %s", kb_decode(str));
		return (NULL);
	}
	count = strlen(str);

	k = alloc(sizeof *k + count + 1, AEDIT);
	k->seq = (unsigned char *)(k + 1);
	k->len = count;
	k->ftab = xf;
	k->args = args ? strdup(args) : NULL;

	strlcpy(k->seq, str, count + 1);

	TAILQ_INSERT_TAIL(&kblist, k, entry);

	return (k);
}

static struct kb_entry *
kb_add(kb_func func, ...)
{
	va_list			ap;
	unsigned char		ch;
	unsigned int		i;
	char			line[LINE + 1];

	va_start(ap, func);
	for (i = 0; i < sizeof(line) - 1; i++) {
		ch = va_arg(ap, unsigned int);
		if (ch == 0)
			break;
		line[i] = ch;
	}
	va_end(ap);
	line[i] = '\0';

	return (kb_add_string(func, NULL, line));
}

static void
kb_print(struct kb_entry *k)
{
	if (!(k->ftab->xf_flags & XF_NOBIND))
		shprintf("%s = %s\n",
		    kb_decode(k->seq), k->ftab->xf_name);
	else if (k->args) {
		shprintf("%s = ", kb_decode(k->seq));
		shprintf("'%s'\n", kb_decode(k->args));
	}
}

int
x_bind(const char *a1, const char *a2,
	int macro,		/* bind -m */
	int list)		/* bind -l */
{
	unsigned int		i;
	struct kb_entry		*k, *kb;
	char			in[LINE + 1];

	if (x_tty == 0) {
		bi_errorf("cannot bind, not a tty");
		return (1);
	}

	if (list) {
		/* show all function names */
		for (i = 0; i < NELEM(x_ftab); i++) {
			if (x_ftab[i].xf_name == NULL)
				continue;
			if (x_ftab[i].xf_name &&
			    !(x_ftab[i].xf_flags & XF_NOBIND))
				shprintf("%s\n", x_ftab[i].xf_name);
		}
		return (0);
	}

	if (a1 == NULL) {
		/* show all bindings */
		TAILQ_FOREACH(k, &kblist, entry)
			kb_print(k);
		return (0);
	}

	snprintf(in, sizeof in, "%s", kb_encode(a1));
	if (a2 == NULL) {
		/* print binding */
		TAILQ_FOREACH(k, &kblist, entry)
			if (!strcmp(k->seq, in)) {
				kb_print(k);
				return (0);
			}
		shprintf("%s = %s\n", kb_decode(a1), "auto-insert");
		return (0);
	}

	if (strlen(a2) == 0) {
		/* clear binding */
		TAILQ_FOREACH_SAFE(k, &kblist, entry, kb)
			if (!strcmp(k->seq, in)) {
				kb_del(k);
				break;
			}
		return (0);
	}

	/* set binding */
	if (macro) {
		/* delete old mapping */
		TAILQ_FOREACH_SAFE(k, &kblist, entry, kb)
			if (!strcmp(k->seq, in)) {
				kb_del(k);
				break;
			}
		kb_add_string(x_ins_string, kb_encode(a2), in);
		return (0);
	}

	/* set non macro binding */
	for (i = 0; i < NELEM(x_ftab); i++) {
		if (x_ftab[i].xf_name == NULL)
			continue;
		if (!strcmp(x_ftab[i].xf_name, a2)) {
			/* delete old mapping */
			TAILQ_FOREACH_SAFE(k, &kblist, entry, kb)
				if (!strcmp(k->seq, in)) {
					kb_del(k);
					break;
				}
			kb_add_string(x_ftab[i].xf_func, NULL, in);
			return (0);
		}
	}
	bi_errorf("%s: no such function", a2);
	return (1);
}

void
x_init_emacs(void)
{
	x_tty = 1;
	ainit(AEDIT);
	x_nextcmd = -1;

	TAILQ_INIT(&kblist);

	/* man page order */
	kb_add(x_abort,			CTRL('G'), 0);
	kb_add(x_mv_back,		CTRL('B'), 0);
	kb_add(x_mv_back,		CTRL('X'), CTRL('D'), 0);
	kb_add(x_mv_bword,		CTRL('['), 'b', 0);
	kb_add(x_beg_hist,		CTRL('['), '<', 0);
	kb_add(x_mv_begin,		CTRL('A'), 0);
	kb_add(x_fold_capitalize,	CTRL('['), 'C', 0);
	kb_add(x_fold_capitalize,	CTRL('['), 'c', 0);
	kb_add(x_comment,		CTRL('['), '#', 0);
	kb_add(x_complete,		CTRL('['), CTRL('['), 0);
	kb_add(x_comp_comm,		CTRL('X'), CTRL('['), 0);
	kb_add(x_comp_file,		CTRL('['), CTRL('X'), 0);
	kb_add(x_comp_list,		CTRL('I'), 0);
	kb_add(x_comp_list,		CTRL('['), '=', 0);
	kb_add(x_del_back,		CTRL('?'), 0);
	kb_add(x_del_back,		CTRL('H'), 0);
	kb_add(x_del_char,		CTRL('['), '[', '3', '~', 0); /* delete */
	kb_add(x_del_bword,		CTRL('W'), 0);
	kb_add(x_del_bword,		CTRL('['), CTRL('?'), 0);
	kb_add(x_del_bword,		CTRL('['), CTRL('H'), 0);
	kb_add(x_del_bword,		CTRL('['), 'h', 0);
	kb_add(x_del_fword,		CTRL('['), 'd', 0);
	kb_add(x_next_com,		CTRL('N'), 0);
	kb_add(x_next_com,		CTRL('X'), 'B', 0);
	kb_add(x_fold_lower,		CTRL('['), 'L', 0);
	kb_add(x_fold_lower,		CTRL('['), 'l', 0);
	kb_add(x_end_hist,		CTRL('['), '>', 0);
	kb_add(x_mv_end,		CTRL('E'), 0);
	/* how to handle: eot: ^_, underneath copied from original keybindings */
	kb_add(x_end_of_text,		CTRL('_'), 0);
	kb_add(x_eot_del,		CTRL('D'), 0);
	/* error */
	kb_add(x_xchg_point_mark,	CTRL('X'), CTRL('X'), 0);
	kb_add(x_expand,		CTRL('['), '*', 0);
	kb_add(x_mv_forw,		CTRL('F'), 0);
	kb_add(x_mv_forw,		CTRL('X'), 'C', 0);
	kb_add(x_mv_fword,		CTRL('['), 'f', 0);
	kb_add(x_goto_hist,		CTRL('['), 'g', 0);
	/* kill-line */
	kb_add(x_kill,			CTRL('K'), 0);
	kb_add(x_enumerate,		CTRL('['), '?', 0);
	kb_add(x_list_comm,		CTRL('X'), '?', 0);
	kb_add(x_list_file,		CTRL('X'), CTRL('Y'), 0);
	kb_add(x_newline,		CTRL('J'), 0);
	kb_add(x_newline,		CTRL('M'), 0);
	kb_add(x_nl_next_com,		CTRL('O'), 0);
	/* no-op */
	kb_add(x_prev_histword,		CTRL('['), '.', 0);
	kb_add(x_prev_histword,		CTRL('['), '_', 0);
	/* how to handle: quote: ^^ */
	kb_add(x_literal,		CTRL('^'), 0);
	kb_add(x_clear_screen,		CTRL('L'), 0);
	kb_add(x_search_char_back,	CTRL('['), CTRL(']'), 0);
	kb_add(x_search_char_forw,	CTRL(']'), 0);
	kb_add(x_search_hist,		CTRL('R'), 0);
	kb_add(x_set_mark,		CTRL('['), ' ', 0);
	kb_add(x_transpose,		CTRL('T'), 0);
	kb_add(x_prev_com,		CTRL('P'), 0);
	kb_add(x_prev_com,		CTRL('X'), 'A', 0);
	kb_add(x_fold_upper,		CTRL('['), 'U', 0);
	kb_add(x_fold_upper,		CTRL('['), 'u', 0);
	kb_add(x_literal,		CTRL('V'), 0);
	kb_add(x_yank,			CTRL('Y'), 0);
	kb_add(x_meta_yank,		CTRL('['), 'y', 0);
	/* man page ends here */

	/* arrow keys */
	kb_add(x_prev_com,		CTRL('['), '[', 'A', 0); /* up */
	kb_add(x_next_com,		CTRL('['), '[', 'B', 0); /* down */
	kb_add(x_mv_forw,		CTRL('['), '[', 'C', 0); /* right */
	kb_add(x_mv_back,		CTRL('['), '[', 'D', 0); /* left */
	kb_add(x_prev_com,		CTRL('['), 'O', 'A', 0); /* up */
	kb_add(x_next_com,		CTRL('['), 'O', 'B', 0); /* down */
	kb_add(x_mv_forw,		CTRL('['), 'O', 'C', 0); /* right */
	kb_add(x_mv_back,		CTRL('['), 'O', 'D', 0); /* left */

	/* more navigation keys */
	kb_add(x_mv_begin,		CTRL('['), '[', 'H', 0); /* home */
	kb_add(x_mv_end,		CTRL('['), '[', 'F', 0); /* end */
	kb_add(x_mv_begin,		CTRL('['), 'O', 'H', 0); /* home */
	kb_add(x_mv_end,		CTRL('['), 'O', 'F', 0); /* end */
	kb_add(x_mv_begin,		CTRL('['), '[', '1', '~', 0); /* home */
	kb_add(x_mv_end,		CTRL('['), '[', '4', '~', 0); /* end */
	kb_add(x_mv_begin,		CTRL('['), '[', '7', '~', 0); /* home */
	kb_add(x_mv_end,		CTRL('['), '[', '8', '~', 0); /* end */

	/* can't be bound */
	kb_add(x_set_arg,		CTRL('['), '0', 0);
	kb_add(x_set_arg,		CTRL('['), '1', 0);
	kb_add(x_set_arg,		CTRL('['), '2', 0);
	kb_add(x_set_arg,		CTRL('['), '3', 0);
	kb_add(x_set_arg,		CTRL('['), '4', 0);
	kb_add(x_set_arg,		CTRL('['), '5', 0);
	kb_add(x_set_arg,		CTRL('['), '6', 0);
	kb_add(x_set_arg,		CTRL('['), '7', 0);
	kb_add(x_set_arg,		CTRL('['), '8', 0);
	kb_add(x_set_arg,		CTRL('['), '9', 0);

	/* ctrl arrow keys */
	kb_add(x_mv_end,		CTRL('['), '[', '1', ';', '5', 'A', 0); /* ctrl up */
	kb_add(x_mv_begin,		CTRL('['), '[', '1', ';', '5', 'B', 0); /* ctrl down */
	kb_add(x_mv_fword,		CTRL('['), '[', '1', ';', '5', 'C', 0); /* ctrl right */
	kb_add(x_mv_bword,		CTRL('['), '[', '1', ';', '5', 'D', 0); /* ctrl left */
}

void
x_emacs_keys(X_chars *ec)
{
	x_bind_quiet = 1;
	if (ec->erase >= 0) {
		kb_add(x_del_back, ec->erase, 0);
		kb_add(x_del_bword, CTRL('['), ec->erase, 0);
	}
	if (ec->kill >= 0)
		kb_add(x_del_line, ec->kill, 0);
	if (ec->werase >= 0)
		kb_add(x_del_bword, ec->werase, 0);
	if (ec->intr >= 0)
		kb_add(x_abort, ec->intr, 0);
	if (ec->quit >= 0)
		kb_add(x_noop, ec->quit, 0);
	x_bind_quiet = 0;
}

static int
x_set_mark(int c)
{
	xmp = xcp;
	return KSTD;
}

static int
x_kill_region(int c)
{
	int	rsize;
	char	*xr;

	if (xmp == NULL) {
		x_e_putc(BEL);
		return KSTD;
	}
	if (xmp > xcp) {
		rsize = xmp - xcp;
		xr = xcp;
	} else {
		rsize = xcp - xmp;
		xr = xmp;
	}
	x_goto(xr);
	x_delete(rsize, true);
	xmp = xr;
	return KSTD;
}

static int
x_xchg_point_mark(int c)
{
	char	*tmp;

	if (xmp == NULL) {
		x_e_putc(BEL);
		return KSTD;
	}
	tmp = xmp;
	xmp = xcp;
	x_goto( tmp );
	return KSTD;
}

static int
x_noop(int c)
{
	return KSTD;
}

/*
 *	File/command name completion routines
 */

static int
x_comp_comm(int c)
{
	do_complete(XCF_COMMAND, CT_COMPLETE);
	return KSTD;
}
static int
x_list_comm(int c)
{
	do_complete(XCF_COMMAND, CT_LIST);
	return KSTD;
}
static int
x_complete(int c)
{
	do_complete(XCF_COMMAND_FILE, CT_COMPLETE);
	return KSTD;
}
static int
x_enumerate(int c)
{
	do_complete(XCF_COMMAND_FILE, CT_LIST);
	return KSTD;
}
static int
x_comp_file(int c)
{
	do_complete(XCF_FILE, CT_COMPLETE);
	return KSTD;
}
static int
x_list_file(int c)
{
	do_complete(XCF_FILE, CT_LIST);
	return KSTD;
}
static int
x_comp_list(int c)
{
	do_complete(XCF_COMMAND_FILE, CT_COMPLIST);
	return KSTD;
}
static int
x_expand(int c)
{
	char **words;
	int nwords = 0;
	int start, end;
	int is_command;
	int i;

	nwords = x_cf_glob(XCF_FILE, xbuf, xep - xbuf, xcp - xbuf,
	    &start, &end, &words, &is_command);

	if (nwords == 0) {
		x_e_putc(BEL);
		return KSTD;
	}

	x_goto(xbuf + start);
	x_delete(end - start, false);
	for (i = 0; i < nwords;) {
		if (x_escape(words[i], strlen(words[i]), x_do_ins) < 0 ||
		    (++i < nwords && x_ins(" ") < 0)) {
			x_e_putc(BEL);
			return KSTD;
		}
	}
	x_adjust();

	return KSTD;
}

/* type == 0 for list, 1 for complete and 2 for complete-list */
static void
do_complete(int flags,	/* XCF_{COMMAND,FILE,COMMAND_FILE} */
    Comp_type type)
{
	char **words;
	int nwords;
	int start, end, nlen, olen;
	int is_command;
	int completed = 0;

	nwords = x_cf_glob(flags, xbuf, xep - xbuf, xcp - xbuf,
	    &start, &end, &words, &is_command);
	/* no match */
	if (nwords == 0) {
		x_e_putc(BEL);
		return;
	}

	if (type == CT_LIST) {
		x_print_expansions(nwords, words, is_command);
		x_redraw(0);
		x_free_words(nwords, words);
		return;
	}

	olen = end - start;
	nlen = x_longest_prefix(nwords, words);
	/* complete */
	if (nwords == 1 || nlen > olen) {
		x_goto(xbuf + start);
		x_delete(olen, false);
		x_escape(words[0], nlen, x_do_ins);
		x_adjust();
		completed = 1;
	}
	/* add space if single non-dir match */
	if (nwords == 1 && words[0][nlen - 1] != '/' &&
	    !x_is_tilde_user_completion(xbuf + start, olen, words[0],
	    nlen)) {
		x_ins(" ");
		completed = 1;
	}

	if (type == CT_COMPLIST && !completed) {
		x_print_expansions(nwords, words, is_command);
		completed = 1;
	}

	if (completed)
		x_redraw(0);

	x_free_words(nwords, words);
}

/* NAME:
 *      x_adjust - redraw the line adjusting starting point etc.
 *
 * DESCRIPTION:
 *      This function is called when we have exceeded the bounds
 *      of the edit window.  It increments x_adj_done so that
 *      functions like x_ins and x_delete know that we have been
 *      called and can skip the x_bs() stuff which has already
 *      been done by x_redraw.
 *
 * RETURN VALUE:
 *      None
 */

static void
x_adjust(void)
{
	x_adj_done++;			/* flag the fact that we were called. */
	/*
	 * we had a problem if the prompt length > xx_cols / 2
	 */
	if ((xbp = xcp - (x_displen / 2)) < xbuf)
		xbp = xbuf;
	xlp_valid = false;
	x_redraw(xx_cols);
	x_flush();
}

static int unget_char = -1;

static void
x_e_ungetc(int c)
{
	unget_char = c;
}

static int
x_e_getc(void)
{
	int c;

	if (unget_char >= 0) {
		c = unget_char;
		unget_char = -1;
	} else if (macro_args) {
		c = *macro_args++;
		if (!c) {
			macro_args = NULL;
			c = x_getc();
		}
	} else
		c = x_getc();

	return c;
}

static int
x_e_getu8(char *buf, int off)
{
	int	c, cc, len;

	c = x_e_getc();
	if (c == -1)
		return -1;
	buf[off++] = c;

	/*
	 * In the following, comments refer to violations of
	 * the inequality tests at the ends of the lines.
	 * See the utf8(7) manual page for details.
	 */

	if ((c & 0xf8) == 0xf0 && c < 0xf5)  /* beyond Unicode */
		len = 4;
	else if ((c & 0xf0) == 0xe0)
		len = 3;
	else if ((c & 0xe0) == 0xc0 && c > 0xc1)  /* use single byte */
		len = 2;
	else
		len = 1;

	for (; len > 1; len--) {
		cc = x_e_getc();
		if (cc == -1)
			break;
		if (em_isu8cont(cc) == 0 ||
		    (c == 0xe0 && len == 3 && cc < 0xa0) ||  /* use 2 bytes */
		    (c == 0xed && len == 3 && cc > 0x9f) ||  /* surrogates  */
		    (c == 0xf0 && len == 4 && cc < 0x90) ||  /* use 3 bytes */
		    (c == 0xf4 && len == 4 && cc > 0x8f)) {  /* beyond Uni. */
			x_e_ungetc(cc);
			break;
		}
		buf[off++] = cc;
	}
	buf[off] = '\0';

	return off;
}

static void
x_e_putc(int c)
{
	if (c == '\r' || c == '\n')
		x_col = 0;
	if (x_col < xx_cols) {
		x_putc(c);
		switch (c) {
		case BEL:
			break;
		case '\r':
		case '\n':
			break;
		case '\b':
			x_col--;
			break;
		default:
			if (!em_isu8cont(c))
				x_col++;
			break;
		}
	}
	if (x_adj_ok && (x_col < 0 || x_col >= (xx_cols - 2)))
		x_adjust();
}

#ifdef DEBUG
static int
x_debug_info(int c)
{
	x_flush();
	shellf("\nksh debug:\n");
	shellf("\tx_col == %d,\t\tx_cols == %d,\tx_displen == %d\n",
	    x_col, xx_cols, x_displen);
	shellf("\txcp == 0x%lx,\txep == 0x%lx\n", (long) xcp, (long) xep);
	shellf("\txbp == 0x%lx,\txbuf == 0x%lx\n", (long) xbp, (long) xbuf);
	shellf("\txlp == 0x%lx\n", (long) xlp);
	shellf("\txlp == 0x%lx\n", (long) x_lastcp());
	shellf("\n");
	x_redraw(-1);
	return 0;
}
#endif

static void
x_e_puts(const char *s)
{
	int	adj = x_adj_done;

	while (*s && adj == x_adj_done)
		x_e_putc(*s++);
}

/* NAME:
 *      x_set_arg - set an arg value for next function
 *
 * DESCRIPTION:
 *      This is a simple implementation of M-[0-9].
 *
 * RETURN VALUE:
 *      KSTD
 */

static int
x_set_arg(int c)
{
	int n = 0;
	int first = 1;

	for (; c >= 0 && isdigit(c); c = x_e_getc(), first = 0)
		n = n * 10 + (c - '0');
	if (c < 0 || first) {
		x_e_putc(BEL);
		x_arg = 1;
		x_arg_defaulted = 1;
	} else {
		x_e_ungetc(c);
		x_arg = n;
		x_arg_defaulted = 0;
		x_arg_set = 1;
	}
	return KSTD;
}


/* Comment or uncomment the current line. */
static int
x_comment(int c)
{
	int oldsize = x_size_str(xbuf);
	int len = xep - xbuf;
	int ret = x_do_comment(xbuf, xend - xbuf, &len);

	if (ret < 0)
		x_e_putc(BEL);
	else {
		xep = xbuf + len;
		*xep = '\0';
		xcp = xbp = xbuf;
		x_redraw(oldsize);
		if (ret > 0)
			return x_newline('\n');
	}
	return KSTD;
}


/* NAME:
 *      x_prev_histword - recover word from prev command
 *
 * DESCRIPTION:
 *      This function recovers the last word from the previous
 *      command and inserts it into the current edit line.  If a
 *      numeric arg is supplied then the n'th word from the
 *      start of the previous command is used.
 *
 *      Bound to M-.
 *
 * RETURN VALUE:
 *      KSTD
 */

static int
x_prev_histword(int c)
{
	char *rcp;
	char *cp;

	cp = *histptr;
	if (!cp)
		x_e_putc(BEL);
	else if (x_arg_defaulted) {
		rcp = &cp[strlen(cp) - 1];
		/*
		 * ignore white-space after the last word
		 */
		while (rcp > cp && is_cfs(*rcp))
			rcp--;
		while (rcp > cp && !is_cfs(*rcp))
			rcp--;
		if (is_cfs(*rcp))
			rcp++;
		x_ins(rcp);
	} else {
		rcp = cp;
		/*
		 * ignore white-space at start of line
		 */
		while (*rcp && is_cfs(*rcp))
			rcp++;
		while (x_arg-- > 1) {
			while (*rcp && !is_cfs(*rcp))
				rcp++;
			while (*rcp && is_cfs(*rcp))
				rcp++;
		}
		cp = rcp;
		while (*rcp && !is_cfs(*rcp))
			rcp++;
		c = *rcp;
		*rcp = '\0';
		x_ins(cp);
		*rcp = c;
	}
	return KSTD;
}

/* Uppercase N(1) words */
static int
x_fold_upper(int c)
{
	return x_fold_case('U');
}

/* Lowercase N(1) words */
static int
x_fold_lower(int c)
{
	return x_fold_case('L');
}

/* Lowercase N(1) words */
static int
x_fold_capitalize(int c)
{
	return x_fold_case('C');
}

/* NAME:
 *      x_fold_case - convert word to UPPER/lower/Capital case
 *
 * DESCRIPTION:
 *      This function is used to implement M-U,M-u,M-L,M-l,M-C and M-c
 *      to UPPER case, lower case or Capitalize words.
 *
 * RETURN VALUE:
 *      None
 */

static int
x_fold_case(int c)
{
	char *cp = xcp;

	if (cp == xep) {
		x_e_putc(BEL);
		return KSTD;
	}
	while (x_arg--) {
		/*
		 * first skip over any white-space
		 */
		while (cp != xep && is_mfs(*cp))
			cp++;
		/*
		 * do the first char on its own since it may be
		 * a different action than for the rest.
		 */
		if (cp != xep) {
			if (c == 'L') {		/* lowercase */
				if (isupper((unsigned char)*cp))
					*cp = tolower((unsigned char)*cp);
			} else {		/* uppercase, capitalize */
				if (islower((unsigned char)*cp))
					*cp = toupper((unsigned char)*cp);
			}
			cp++;
		}
		/*
		 * now for the rest of the word
		 */
		while (cp != xep && !is_mfs(*cp)) {
			if (c == 'U') {		/* uppercase */
				if (islower((unsigned char)*cp))
					*cp = toupper((unsigned char)*cp);
			} else {		/* lowercase, capitalize */
				if (isupper((unsigned char)*cp))
					*cp = tolower((unsigned char)*cp);
			}
			cp++;
		}
	}
	x_goto(cp);
	return KSTD;
}

/* NAME:
 *      x_lastcp - last visible byte
 *
 * SYNOPSIS:
 *      x_lastcp()
 *
 * DESCRIPTION:
 *      This function returns a pointer to that byte in the
 *      edit buffer that will be the last displayed on the
 *      screen.  The sequence:
 *
 *      for (cp = x_lastcp(); cp > xcp; cp)
 *        x_bs(*--cp);
 *
 *      Will position the cursor correctly on the screen.
 *
 * RETURN VALUE:
 *      cp or NULL
 */

static char *
x_lastcp(void)
{
	char *rcp;
	int i;

	if (!xlp_valid) {
		for (i = 0, rcp = xbp; rcp < xep && i < x_displen; rcp++)
			i += x_size((unsigned char)*rcp);
		xlp = rcp;
	}
	xlp_valid = true;
	return (xlp);
}

/*
 * Vi command line editing
 */

/*
 *	vi command editing
 *	written by John Rochester (initially for nsh)
 *	bludgeoned to fit pdksh by Larry Bouzane, Jeff Sparkes & Eric Gisin
 *
 */

#undef CTRL
#define	CTRL(x)		((x) & 0x1F)	/* ASCII */

struct edstate {
	char	*cbuf;		/* main buffer to build the command line */
	int	cbufsize;	/* number of bytes allocated for cbuf */
	int	linelen;	/* current number of bytes in cbuf */
	int	winleft;	/* first byte# in cbuf to be displayed */
	int	cursor;		/* byte# in cbuf having the cursor */
};


static int	vi_hook(int);
static void	vi_reset(char *, size_t);
static int	nextstate(int);
static int	vi_insert(int);
static int	vi_cmd(int, const char *);
static int	domove(int, const char *, int);
static int	redo_insert(int);
static void	yank_range(int, int);
static int	bracktype(int);
static void	save_cbuf(void);
static void	restore_cbuf(void);
static void	edit_reset(char *, size_t);
static int	putbuf(const char *, int, int);
static void	del_range(int, int);
static int	findch(int, int, int, int);
static int	forwword(int);
static int	backword(int);
static int	endword(int);
static int	Forwword(int);
static int	Backword(int);
static int	Endword(int);
static int	grabhist(int, int);
static int	grabsearch(int, int, int, char *);
static void	do_clear_screen(void);
static void	redraw_line(int, int);
static void	refresh_line(int);
static int	outofwin(void);
static void	rewindow(void);
static int	newcol(int, int);
static void	display(char *, char *, int);
static void	ed_mov_opt(int, char *);
static int	expand_word(int);
static int	complete_word(int, int);
static int	print_expansions(struct edstate *);
static int	char_len(int);
static void	x_vi_zotc(int);
static void	vi_pprompt(int);
static void	vi_error(void);
static void	vi_macro_reset(void);
static int	x_vi_putbuf(const char *, size_t);
static int	isu8cont(unsigned char);

#define C_	0x1		/* a valid command that isn't a M_, E_, U_ */
#define M_	0x2		/* movement command (h, l, etc.) */
#define E_	0x4		/* extended command (c, d, y) */
#define X_	0x8		/* long command (@, f, F, t, T, etc.) */
#define U_	0x10		/* an UN-undoable command (that isn't a M_) */
#define B_	0x20		/* bad command (^@) */
#define Z_	0x40		/* repeat count defaults to 0 (not 1) */
#define S_	0x80		/* search (/, ?) */

#define is_bad(c)	(classify[(c)&0x7f]&B_)
#define is_cmd(c)	(classify[(c)&0x7f]&(M_|E_|C_|U_))
#define is_move(c)	(classify[(c)&0x7f]&M_)
#define is_extend(c)	(classify[(c)&0x7f]&E_)
#define is_long(c)	(classify[(c)&0x7f]&X_)
#define is_undoable(c)	(!(classify[(c)&0x7f]&U_))
#define is_srch(c)	(classify[(c)&0x7f]&S_)
#define is_zerocount(c)	(classify[(c)&0x7f]&Z_)

const unsigned char	classify[128] = {
   /*       0       1       2       3       4       5       6       7        */
   /*   0   ^@     ^A      ^B      ^C      ^D      ^E      ^F      ^G        */
	    B_,     0,      0,      0,      0,      C_|U_,  C_|Z_,  0,
   /*  01   ^H     ^I      ^J      ^K      ^L      ^M      ^N      ^O        */
	    M_,     C_|Z_,  0,      0,      C_|U_,  0,      C_,     0,
   /*  02   ^P     ^Q      ^R      ^S      ^T      ^U      ^V      ^W        */
	    C_,     0,      C_|U_,  0,      0,      0,      C_,     0,
   /*  03   ^X     ^Y      ^Z      ^[      ^\      ^]      ^^      ^_        */
	    C_,     0,      0,      C_|Z_,  0,      0,      0,      0,
   /*  04  <space>  !       "       #       $       %       &       '        */
	    M_,     0,      0,      C_,     M_,     M_,     0,      0,
   /*  05   (       )       *       +       ,       -       .       /        */
	    0,      0,      C_,     C_,     M_,     C_,     0,      C_|S_,
   /*  06   0       1       2       3       4       5       6       7        */
	    M_,     0,      0,      0,      0,      0,      0,      0,
   /*  07   8       9       :       ;       <       =       >       ?        */
	    0,      0,      0,      M_,     0,      C_,     0,      C_|S_,
   /* 010   @       A       B       C       D       E       F       G        */
	    C_|X_,  C_,     M_,     C_,     C_,     M_,     M_|X_,  C_|U_|Z_,
   /* 011   H       I       J       K       L       M       N       O        */
	    0,      C_,     0,      0,      0,      0,      C_|U_,  0,
   /* 012   P       Q       R       S       T       U       V       W        */
	    C_,     0,      C_,     C_,     M_|X_,  C_,     0,      M_,
   /* 013   X       Y       Z       [       \       ]       ^       _        */
	    C_,     C_|U_,  0,      0,      C_|Z_,  0,      M_,     C_|Z_,
   /* 014   `       a       b       c       d       e       f       g        */
	    0,      C_,     M_,     E_,     E_,     M_,     M_|X_,  C_|Z_,
   /* 015   h       i       j       k       l       m       n       o        */
	    M_,     C_,     C_|U_,  C_|U_,  M_,     0,      C_|U_,  0,
   /* 016   p       q       r       s       t       u       v       w        */
	    C_,     0,      X_,     C_,     M_|X_,  C_|U_,  C_|U_|Z_,M_,
   /* 017   x       y       z       {       |       }       ~      ^?        */
	    C_,     E_|U_,  0,      0,      M_|Z_,  0,      C_,     0
};

#define MAXVICMD	3
#define SRCHLEN		40

#define INSERT		1
#define REPLACE		2

#define VNORMAL		0		/* command, insert or replace mode */
#define VARG1		1		/* digit prefix (first, eg, 5l) */
#define VEXTCMD		2		/* cmd + movement (eg, cl) */
#define VARG2		3		/* digit prefix (second, eg, 2c3l) */
#define VXCH		4		/* f, F, t, T, @ */
#define VFAIL		5		/* bad command */
#define VCMD		6		/* single char command (eg, X) */
#define VREDO		7		/* . */
#define VLIT		8		/* ^V */
#define VSEARCH		9		/* /, ? */

static char		undocbuf[LINE];

static struct edstate	*save_edstate(struct edstate *old);
static void		restore_edstate(struct edstate *old, struct edstate *new);
static void		free_edstate(struct edstate *old);

static struct edstate	ebuf;
static struct edstate	undobuf = { undocbuf, LINE, 0, 0, 0 };

static struct edstate	*es;			/* current editor state */
static struct edstate	*undo;

static char	ibuf[LINE];		/* input buffer */
static int	first_insert;		/* set when starting in insert mode */
static int	saved_inslen;		/* saved inslen for first insert */
static int	inslen;			/* length of input buffer */
static int	srchlen;		/* number of bytes in search pattern */
static char	ybuf[LINE];		/* yank buffer */
static int	yanklen;		/* length of yank buffer */
static int	fsavecmd = ' ';		/* last find command */
static int	fsavech;		/* character to find */
static char	lastcmd[MAXVICMD];	/* last non-move command */
static int	lastac;			/* argcnt for lastcmd */
static int	lastsearch = ' ';	/* last search command */
static char	srchpat[SRCHLEN];	/* last search pattern */
static int	insert;			/* mode: INSERT, REPLACE, or 0 */
static int	hnum;			/* position in history */
static int	ohnum;			/* history line copied (after mod) */
static int	hlast;			/* 1 past last position in history */
static int	modified;		/* buffer has been "modified" */
static int	state;

/* Information for keeping track of macros that are being expanded.
 * The format of buf is the alias contents followed by a null byte followed
 * by the name (letter) of the alias.  The end of the buffer is marked by
 * a double null.  The name of the alias is stored so recursive macros can
 * be detected.
 */
struct macro_state {
    unsigned char	*p;	/* current position in buf */
    unsigned char	*buf;	/* pointer to macro(s) being expanded */
    int			len;	/* how much data in buffer */
};
static struct macro_state macro;

enum expand_mode { NONE, EXPAND, COMPLETE, PRINT };
static enum expand_mode expanded = NONE;/* last input was expanded */

int
x_vi(char *buf, size_t len)
{
	int	c;

	vi_reset(buf, len > LINE ? LINE : len);
	vi_pprompt(1);
	x_flush();
	while (1) {
		if (macro.p) {
			c = (unsigned char)*macro.p++;
			/* end of current macro? */
			if (!c) {
				/* more macros left to finish? */
				if (*macro.p++)
					continue;
				/* must be the end of all the macros */
				vi_macro_reset();
				c = x_getc();
			}
		} else
			c = x_getc();

		if (c == -1)
			break;
		if (state != VLIT) {
			if (c == edchars.intr || c == edchars.quit) {
				/* pretend we got an interrupt */
				x_vi_zotc(c);
				x_flush();
				trapsig(c == edchars.intr ? SIGINT : SIGQUIT);
				x_mode(false);
				unwind(LSHELL);
			} else if (c == edchars.eof) {
				if (es->linelen == 0) {
					x_vi_zotc(edchars.eof);
					c = -1;
					break;
				}
				continue;
			}
		}
		if (vi_hook(c))
			break;
		x_flush();
	}

	x_putc('\r'); x_putc('\n'); x_flush();

	if (c == -1 || len <= (size_t)es->linelen)
		return -1;

	if (es->cbuf != buf)
		memmove(buf, es->cbuf, es->linelen);

	buf[es->linelen++] = '\n';

	return es->linelen;
}

static int
vi_hook(int ch)
{
	static char	curcmd[MAXVICMD], locpat[SRCHLEN];
	static int	cmdlen, argc1, argc2;

	switch (state) {

	case VNORMAL:
		if (insert != 0) {
			if (ch == CTRL('v')) {
				state = VLIT;
				ch = '^';
			}
			switch (vi_insert(ch)) {
			case -1:
				vi_error();
				state = VNORMAL;
				break;
			case 0:
				if (state == VLIT) {
					es->cursor--;
					refresh_line(0);
				} else
					refresh_line(insert != 0);
				break;
			case 1:
				return 1;
			}
		} else {
			if (ch == '\r' || ch == '\n')
				return 1;
			cmdlen = 0;
			argc1 = 0;
			if (ch >= '1' && ch <= '9') {
				argc1 = ch - '0';
				state = VARG1;
			} else {
				curcmd[cmdlen++] = ch;
				state = nextstate(ch);
				if (state == VSEARCH) {
					save_cbuf();
					es->cursor = 0;
					es->linelen = 0;
					if (ch == '/') {
						if (putbuf("/", 1, 0) != 0)
							return -1;
					} else if (putbuf("?", 1, 0) != 0)
						return -1;
					refresh_line(0);
				}
			}
		}
		break;

	case VLIT:
		if (is_bad(ch)) {
			del_range(es->cursor, es->cursor + 1);
			vi_error();
		} else
			es->cbuf[es->cursor++] = ch;
		refresh_line(1);
		state = VNORMAL;
		break;

	case VARG1:
		if (isdigit(ch))
			argc1 = argc1 * 10 + ch - '0';
		else {
			curcmd[cmdlen++] = ch;
			state = nextstate(ch);
		}
		break;

	case VEXTCMD:
		argc2 = 0;
		if (ch >= '1' && ch <= '9') {
			argc2 = ch - '0';
			state = VARG2;
			return 0;
		} else {
			curcmd[cmdlen++] = ch;
			if (ch == curcmd[0])
				state = VCMD;
			else if (is_move(ch))
				state = nextstate(ch);
			else
				state = VFAIL;
		}
		break;

	case VARG2:
		if (isdigit(ch))
			argc2 = argc2 * 10 + ch - '0';
		else {
			if (argc1 == 0)
				argc1 = argc2;
			else
				argc1 *= argc2;
			curcmd[cmdlen++] = ch;
			if (ch == curcmd[0])
				state = VCMD;
			else if (is_move(ch))
				state = nextstate(ch);
			else
				state = VFAIL;
		}
		break;

	case VXCH:
		if (ch == CTRL('['))
			state = VNORMAL;
		else {
			curcmd[cmdlen++] = ch;
			state = VCMD;
		}
		break;

	case VSEARCH:
		if (ch == '\r' || ch == '\n' /*|| ch == CTRL('[')*/ ) {
			restore_cbuf();
			/* Repeat last search? */
			if (srchlen == 0) {
				if (!srchpat[0]) {
					vi_error();
					state = VNORMAL;
					refresh_line(0);
					return 0;
				}
			} else {
				locpat[srchlen] = '\0';
				(void) strlcpy(srchpat, locpat, sizeof srchpat);
			}
			state = VCMD;
		} else if (ch == edchars.erase || ch == CTRL('h')) {
			if (srchlen != 0) {
				do {
					srchlen--;
					es->linelen -= char_len(
					    (unsigned char)locpat[srchlen]);
				} while (srchlen > 0 &&
				    isu8cont(locpat[srchlen]));
				es->cursor = es->linelen;
				refresh_line(0);
				return 0;
			}
			restore_cbuf();
			state = VNORMAL;
			refresh_line(0);
		} else if (ch == edchars.kill) {
			srchlen = 0;
			es->linelen = 1;
			es->cursor = 1;
			refresh_line(0);
			return 0;
		} else if (ch == edchars.werase) {
			struct edstate new_es, *save_es;
			int i;
			int n = srchlen;

			new_es.cursor = n;
			new_es.cbuf = locpat;

			save_es = es;
			es = &new_es;
			n = backword(1);
			es = save_es;

			for (i = srchlen; --i >= n; )
				es->linelen -= char_len((unsigned char)locpat[i]);
			srchlen = n;
			es->cursor = es->linelen;
			refresh_line(0);
			return 0;
		} else {
			if (srchlen == SRCHLEN - 1)
				vi_error();
			else {
				locpat[srchlen++] = ch;
				if ((ch & 0x80) && Flag(FVISHOW8)) {
					if (es->linelen + 2 > es->cbufsize)
						vi_error();
					es->cbuf[es->linelen++] = 'M';
					es->cbuf[es->linelen++] = '-';
					ch &= 0x7f;
				}
				if (ch < ' ' || ch == 0x7f) {
					if (es->linelen + 2 > es->cbufsize)
						vi_error();
					es->cbuf[es->linelen++] = '^';
					es->cbuf[es->linelen++] = ch ^ '@';
				} else {
					if (es->linelen >= es->cbufsize)
						vi_error();
					es->cbuf[es->linelen++] = ch;
				}
				es->cursor = es->linelen;
				refresh_line(0);
			}
			return 0;
		}
		break;
	}

	switch (state) {
	case VCMD:
		state = VNORMAL;
		switch (vi_cmd(argc1, curcmd)) {
		case -1:
			vi_error();
			refresh_line(0);
			break;
		case 0:
			if (insert != 0)
				inslen = 0;
			refresh_line(insert != 0);
			break;
		case 1:
			refresh_line(0);
			return 1;
		case 2:
			/* back from a 'v' command - don't redraw the screen */
			return 1;
		}
		break;

	case VREDO:
		state = VNORMAL;
		if (argc1 != 0)
			lastac = argc1;
		switch (vi_cmd(lastac, lastcmd)) {
		case -1:
			vi_error();
			refresh_line(0);
			break;
		case 0:
			if (insert != 0) {
				if (lastcmd[0] == 's' || lastcmd[0] == 'c' ||
				    lastcmd[0] == 'C') {
					if (redo_insert(1) != 0)
						vi_error();
				} else {
					if (redo_insert(lastac) != 0)
						vi_error();
				}
			}
			refresh_line(0);
			break;
		case 1:
			refresh_line(0);
			return 1;
		case 2:
			/* back from a 'v' command - can't happen */
			break;
		}
		break;

	case VFAIL:
		state = VNORMAL;
		vi_error();
		break;
	}
	return 0;
}

static void
vi_reset(char *buf, size_t len)
{
	state = VNORMAL;
	ohnum = hnum = hlast = histnum(-1) + 1;
	insert = INSERT;
	saved_inslen = inslen;
	first_insert = 1;
	inslen = 0;
	modified = 1;
	vi_macro_reset();
	edit_reset(buf, len);
}

static int
nextstate(int ch)
{
	if (is_extend(ch))
		return VEXTCMD;
	else if (is_srch(ch))
		return VSEARCH;
	else if (is_long(ch))
		return VXCH;
	else if (ch == '.')
		return VREDO;
	else if (is_cmd(ch))
		return VCMD;
	else
		return VFAIL;
}

static int
vi_insert(int ch)
{
	int	tcursor;

	if (ch == edchars.erase || ch == CTRL('h')) {
		if (insert == REPLACE) {
			if (es->cursor == undo->cursor) {
				vi_error();
				return 0;
			}
		} else {
			if (es->cursor == 0) {
				/* x_putc(BEL); no annoying bell here */
				return 0;
			}
		}
		tcursor = es->cursor - 1;
		while(tcursor > 0 && isu8cont(es->cbuf[tcursor]))
			tcursor--;
		if (insert == INSERT)
			memmove(es->cbuf + tcursor, es->cbuf + es->cursor,
			    es->linelen - es->cursor);
		if (insert == REPLACE && es->cursor < undo->linelen)
			memcpy(es->cbuf + tcursor, undo->cbuf + tcursor,
			    es->cursor - tcursor);
		else
			es->linelen -= es->cursor - tcursor;
		if (inslen < es->cursor - tcursor)
			inslen = 0;
		else
			inslen -= es->cursor - tcursor;
		es->cursor = tcursor;
		expanded = NONE;
		return 0;
	}
	if (ch == edchars.kill) {
		if (es->cursor != 0) {
			inslen = 0;
			memmove(es->cbuf, &es->cbuf[es->cursor],
			    es->linelen - es->cursor);
			es->linelen -= es->cursor;
			es->cursor = 0;
		}
		expanded = NONE;
		return 0;
	}
	if (ch == edchars.werase) {
		if (es->cursor != 0) {
			tcursor = backword(1);
			memmove(&es->cbuf[tcursor], &es->cbuf[es->cursor],
			    es->linelen - es->cursor);
			es->linelen -= es->cursor - tcursor;
			if (inslen < es->cursor - tcursor)
				inslen = 0;
			else
				inslen -= es->cursor - tcursor;
			es->cursor = tcursor;
		}
		expanded = NONE;
		return 0;
	}
	/* If any chars are entered before escape, trash the saved insert
	 * buffer (if user inserts & deletes char, ibuf gets trashed and
	 * we don't want to use it)
	 */
	if (first_insert && ch != CTRL('['))
		saved_inslen = 0;
	switch (ch) {
	case '\0':
		return -1;

	case '\r':
	case '\n':
		return 1;

	case CTRL('['):
		expanded = NONE;
		if (first_insert) {
			first_insert = 0;
			if (inslen == 0) {
				inslen = saved_inslen;
				return redo_insert(0);
			}
			lastcmd[0] = 'a';
			lastac = 1;
		}
		if (lastcmd[0] == 's' || lastcmd[0] == 'c' ||
		    lastcmd[0] == 'C')
			return redo_insert(0);
		else
			return redo_insert(lastac - 1);

	/* { Begin nonstandard vi commands */
	case CTRL('x'):
		expand_word(0);
		break;

	case CTRL('f'):
		complete_word(0, 0);
		break;

	case CTRL('e'):
		print_expansions(es);
		break;

	case CTRL('l'):
		do_clear_screen();
		break;

	case CTRL('r'):
		redraw_line(1, 0);
		break;

	case CTRL('i'):
		if (Flag(FVITABCOMPLETE)) {
			complete_word(0, 0);
			break;
		}
		/* FALLTHROUGH */
	/* End nonstandard vi commands } */

	default:
		if (es->linelen >= es->cbufsize - 1)
			return -1;
		ibuf[inslen++] = ch;
		if (insert == INSERT) {
			memmove(&es->cbuf[es->cursor+1], &es->cbuf[es->cursor],
			    es->linelen - es->cursor);
			es->linelen++;
		}
		es->cbuf[es->cursor++] = ch;
		if (insert == REPLACE && es->cursor > es->linelen)
			es->linelen++;
		expanded = NONE;
	}
	return 0;
}

static int
vi_cmd(int argcnt, const char *cmd)
{
	int		ncursor;
	int		cur, c1, c2, c3 = 0;
	struct edstate	*t;

	if (argcnt == 0 && !is_zerocount(*cmd))
		argcnt = 1;

	if (is_move(*cmd)) {
		if ((cur = domove(argcnt, cmd, 0)) >= 0) {
			if (cur == es->linelen && cur != 0)
				while (isu8cont(es->cbuf[--cur]))
					continue;
			es->cursor = cur;
		} else
			return -1;
	} else {
		/* Don't save state in middle of macro.. */
		if (is_undoable(*cmd) && !macro.p) {
			undo->winleft = es->winleft;
			memmove(undo->cbuf, es->cbuf, es->linelen);
			undo->linelen = es->linelen;
			undo->cursor = es->cursor;
			lastac = argcnt;
			memmove(lastcmd, cmd, MAXVICMD);
		}
		switch (*cmd) {

		case CTRL('l'):
			do_clear_screen();
			break;

		case CTRL('r'):
			redraw_line(1, 0);
			break;

		case '@':
			{
				static char alias[] = "_\0";
				struct tbl *ap;
				int	olen, nlen;
				char	*p, *nbuf;

				/* lookup letter in alias list... */
				alias[1] = cmd[1];
				ap = ktsearch(&aliases, alias, hash(alias));
				if (!cmd[1] || !ap || !(ap->flag & ISSET))
					return -1;
				/* check if this is a recursive call... */
				if ((p = (char *) macro.p))
					while ((p = strchr(p, '\0')) && p[1])
						if (*++p == cmd[1])
							return -1;
				/* insert alias into macro buffer */
				nlen = strlen(ap->val.s) + 1;
				olen = !macro.p ? 2 :
				    macro.len - (macro.p - macro.buf);
				nbuf = alloc(nlen + 1 + olen, APERM);
				memcpy(nbuf, ap->val.s, nlen);
				nbuf[nlen++] = cmd[1];
				if (macro.p) {
					memcpy(nbuf + nlen, macro.p, olen);
					afree(macro.buf, APERM);
					nlen += olen;
				} else {
					nbuf[nlen++] = '\0';
					nbuf[nlen++] = '\0';
				}
				macro.p = macro.buf = (unsigned char *) nbuf;
				macro.len = nlen;
			}
			break;

		case 'a':
			modified = 1; hnum = hlast;
			if (es->linelen != 0)
				while (isu8cont(es->cbuf[++es->cursor]))
					continue;
			insert = INSERT;
			break;

		case 'A':
			modified = 1; hnum = hlast;
			del_range(0, 0);
			es->cursor = es->linelen;
			insert = INSERT;
			break;

		case 'S':
			es->cursor = domove(1, "^", 1);
			del_range(es->cursor, es->linelen);
			modified = 1; hnum = hlast;
			insert = INSERT;
			break;

		case 'Y':
			cmd = "y$";
			/* ahhhhhh... */
		case 'c':
		case 'd':
		case 'y':
			if (*cmd == cmd[1]) {
				c1 = *cmd == 'c' ? domove(1, "^", 1) : 0;
				c2 = es->linelen;
			} else if (!is_move(cmd[1]))
				return -1;
			else {
				if ((ncursor = domove(argcnt, &cmd[1], 1)) < 0)
					return -1;
				if (*cmd == 'c' &&
				    (cmd[1]=='w' || cmd[1]=='W') &&
				    !isspace((unsigned char)es->cbuf[es->cursor])) {
					while (isspace(
					    (unsigned char)es->cbuf[--ncursor]))
						;
					ncursor++;
				}
				if (ncursor > es->cursor) {
					c1 = es->cursor;
					c2 = ncursor;
				} else {
					c1 = ncursor;
					c2 = es->cursor;
					if (cmd[1] == '%')
						c2++;
				}
			}
			if (c1 != c2)
				yank_range(c1, c2);
			if (*cmd != 'y') {
				del_range(c1, c2);
				es->cursor = c1;
			}
			if (*cmd == 'c') {
				modified = 1; hnum = hlast;
				insert = INSERT;
			}
			break;

		case 'p':
			modified = 1; hnum = hlast;
			while (es->cursor < es->linelen)
				if (!isu8cont(es->cbuf[++es->cursor]))
					break;
			while (putbuf(ybuf, yanklen, 0) == 0 && --argcnt > 0)
				;
			while (es->cursor > 0)
				if (!isu8cont(es->cbuf[--es->cursor]))
					break;
			if (argcnt != 0)
				return -1;
			break;

		case 'P':
			modified = 1; hnum = hlast;
			while (putbuf(ybuf, yanklen, 0) == 0 && --argcnt > 0)
				continue;
			while (es->cursor > 0)
				if (!isu8cont(es->cbuf[--es->cursor]))
					break;
			if (argcnt != 0)
				return -1;
			break;

		case 'C':
			modified = 1; hnum = hlast;
			yank_range(es->cursor, es->linelen);
			del_range(es->cursor, es->linelen);
			insert = INSERT;
			break;

		case 'D':
			yank_range(es->cursor, es->linelen);
			del_range(es->cursor, es->linelen);
			break;

		case 'g':
			if (!argcnt)
				argcnt = hlast;
			/* FALLTHROUGH */
		case 'G':
			if (!argcnt)
				argcnt = 1;
			else
				argcnt = hlast - (source->line - argcnt);
			if (grabhist(modified, argcnt - 1) < 0)
				return -1;
			else {
				modified = 0;
				hnum = argcnt - 1;
			}
			break;

		case 'i':
			modified = 1; hnum = hlast;
			insert = INSERT;
			break;

		case 'I':
			modified = 1; hnum = hlast;
			es->cursor = domove(1, "^", 1);
			insert = INSERT;
			break;

		case 'j':
		case '+':
		case CTRL('n'):
			if (grabhist(modified, hnum + argcnt) < 0)
				return -1;
			else {
				modified = 0;
				hnum += argcnt;
			}
			break;

		case 'k':
		case '-':
		case CTRL('p'):
			if (grabhist(modified, hnum - argcnt) < 0)
				return -1;
			else {
				modified = 0;
				hnum -= argcnt;
			}
			break;

		case 'r':
			if (es->linelen == 0)
				return -1;
			modified = 1; hnum = hlast;
			if (cmd[1] == 0)
				vi_error();
			else {
				c1 = 0;
				for (cur = es->cursor;
				    cur < es->linelen; cur++) {
					if (!isu8cont(es->cbuf[cur]))
						c1++;
					if (c1 > argcnt)
						break;
				}
				if (argcnt > c1)
					return -1;

				del_range(es->cursor, cur);
				while (argcnt-- > 0)
					putbuf(&cmd[1], 1, 0);
				while (es->cursor > 0)
					if (!isu8cont(es->cbuf[--es->cursor]))
						break;
				es->cbuf[es->linelen] = '\0';
			}
			break;

		case 'R':
			modified = 1; hnum = hlast;
			insert = REPLACE;
			break;

		case 's':
			if (es->linelen == 0)
				return -1;
			modified = 1; hnum = hlast;
			for (cur = es->cursor; cur < es->linelen; cur++)
				if (!isu8cont(es->cbuf[cur]))
					if (argcnt-- == 0)
						break;
			del_range(es->cursor, cur);
			insert = INSERT;
			break;

		case 'v':
			if (es->linelen == 0 && argcnt == 0)
				return -1;
			if (!argcnt) {
				if (modified) {
					es->cbuf[es->linelen] = '\0';
					source->line++;
					histsave(source->line, es->cbuf, 1);
				} else
					argcnt = source->line + 1
						- (hlast - hnum);
			}
			shf_snprintf(es->cbuf, es->cbufsize,
			    argcnt ? "%s %d" : "%s",
			    "fc -e ${VISUAL:-${EDITOR:-vi}} --",
			    argcnt);
			es->linelen = strlen(es->cbuf);
			return 2;

		case 'x':
			if (es->linelen == 0)
				return -1;
			modified = 1; hnum = hlast;
			for (cur = es->cursor; cur < es->linelen; cur++)
				if (!isu8cont(es->cbuf[cur]))
					if (argcnt-- == 0)
						break;
			yank_range(es->cursor, cur);
			del_range(es->cursor, cur);
			break;

		case 'X':
			if (es->cursor == 0)
				return -1;
			modified = 1; hnum = hlast;
			for (cur = es->cursor; cur > 0; cur--)
				if (!isu8cont(es->cbuf[cur]))
					if (argcnt-- == 0)
						break;
			yank_range(cur, es->cursor);
			del_range(cur, es->cursor);
			es->cursor = cur;
			break;

		case 'u':
			t = es;
			es = undo;
			undo = t;
			break;

		case 'U':
			if (!modified)
				return -1;
			if (grabhist(modified, ohnum) < 0)
				return -1;
			modified = 0;
			hnum = ohnum;
			break;

		case '?':
			if (hnum == hlast)
				hnum = -1;
			/* ahhh */
		case '/':
			c3 = 1;
			srchlen = 0;
			lastsearch = *cmd;
			/* FALLTHROUGH */
		case 'n':
		case 'N':
			if (lastsearch == ' ')
				return -1;
			if (lastsearch == '?')
				c1 = 1;
			else
				c1 = 0;
			if (*cmd == 'N')
				c1 = !c1;
			if ((c2 = grabsearch(modified, hnum,
			    c1, srchpat)) < 0) {
				if (c3) {
					restore_cbuf();
					refresh_line(0);
				}
				return -1;
			} else {
				modified = 0;
				hnum = c2;
				ohnum = hnum;
			}
			break;
		case '_': {
			int	inspace;
			char	*p, *sp;

			if (histnum(-1) < 0)
				return -1;
			p = *histpos();
#define issp(c)		(isspace((unsigned char)(c)) || (c) == '\n')
			if (argcnt) {
				while (*p && issp(*p))
					p++;
				while (*p && --argcnt) {
					while (*p && !issp(*p))
						p++;
					while (*p && issp(*p))
						p++;
				}
				if (!*p)
					return -1;
				sp = p;
			} else {
				sp = p;
				inspace = 0;
				while (*p) {
					if (issp(*p))
						inspace = 1;
					else if (inspace) {
						inspace = 0;
						sp = p;
					}
					p++;
				}
				p = sp;
			}
			modified = 1; hnum = hlast;
			if (es->cursor != es->linelen)
				es->cursor++;
			while (*p && !issp(*p)) {
				argcnt++;
				p++;
			}
			if (putbuf(" ", 1, 0) != 0)
				argcnt = -1;
			else if (putbuf(sp, argcnt, 0) != 0)
				argcnt = -1;
			if (argcnt < 0) {
				if (es->cursor != 0)
					es->cursor--;
				return -1;
			}
			insert = INSERT;
			}
			break;

		case '~': {
			char	*p;
			unsigned char c;
			int	i;

			if (es->linelen == 0)
				return -1;
			for (i = 0; i < argcnt; i++) {
				p = &es->cbuf[es->cursor];
				c = (unsigned char)*p;
				if (islower(c)) {
					modified = 1; hnum = hlast;
					*p = toupper(c);
				} else if (isupper(c)) {
					modified = 1; hnum = hlast;
					*p = tolower(c);
				}
				if (es->cursor < es->linelen - 1)
					es->cursor++;
			}
			break;
			}

		case '#':
		    {
			int ret = x_do_comment(es->cbuf, es->cbufsize,
			    &es->linelen);
			if (ret >= 0)
				es->cursor = 0;
			return ret;
		    }

		case '=':			/* at&t ksh */
		case CTRL('e'):			/* Nonstandard vi/ksh */
			print_expansions(es);
			break;


		case CTRL('i'):			/* Nonstandard vi/ksh */
			if (!Flag(FVITABCOMPLETE))
				return -1;
			complete_word(1, argcnt);
			break;

		case CTRL('['):			/* some annoying at&t ksh's */
			if (!Flag(FVIESCCOMPLETE))
				return -1;
		case '\\':			/* at&t ksh */
		case CTRL('f'):			/* Nonstandard vi/ksh */
			complete_word(1, argcnt);
			break;


		case '*':			/* at&t ksh */
		case CTRL('x'):			/* Nonstandard vi/ksh */
			expand_word(1);
			break;
		}
		if (insert == 0 && es->cursor >= es->linelen)
			while (es->cursor > 0)
				if (!isu8cont(es->cbuf[--es->cursor]))
					break;
	}
	return 0;
}

static int
domove(int argcnt, const char *cmd, int sub)
{
	int	bcount, i = 0, t;
	int	ncursor = 0;

	switch (*cmd) {

	case 'b':
	case 'B':
		if (!sub && es->cursor == 0)
			return -1;
		ncursor = (*cmd == 'b' ? backword : Backword)(argcnt);
		break;

	case 'e':
	case 'E':
		if (!sub && es->cursor + 1 >= es->linelen)
			return -1;
		ncursor = (*cmd == 'e' ? endword : Endword)(argcnt);
		if (!sub)
			while (isu8cont((unsigned char)es->cbuf[--ncursor]))
				continue;
		break;

	case 'f':
	case 'F':
	case 't':
	case 'T':
		fsavecmd = *cmd;
		fsavech = cmd[1];
		/* drop through */

	case ',':
	case ';':
		if (fsavecmd == ' ')
			return -1;
		i = fsavecmd == 'f' || fsavecmd == 'F';
		t = fsavecmd > 'a';
		if (*cmd == ',')
			t = !t;
		if ((ncursor = findch(fsavech, argcnt, t, i)) < 0)
			return -1;
		if (sub && t)
			ncursor++;
		break;

	case 'h':
	case CTRL('h'):
		if (!sub && es->cursor == 0)
			return -1;
		for (ncursor = es->cursor; ncursor > 0; ncursor--)
			if (!isu8cont(es->cbuf[ncursor]))
				if (argcnt-- == 0)
					break;
		break;

	case ' ':
	case 'l':
		if (!sub && es->cursor + 1 >= es->linelen)
			return -1;
		for (ncursor = es->cursor; ncursor < es->linelen; ncursor++)
			if (ncursor == es->cursor ||
			    !isu8cont(es->cbuf[ncursor]))
				if (argcnt-- == 0)
					break;
		break;

	case 'w':
	case 'W':
		if (!sub && es->cursor + 1 >= es->linelen)
			return -1;
		ncursor = (*cmd == 'w' ? forwword : Forwword)(argcnt);
		break;

	case '0':
		ncursor = 0;
		break;

	case '^':
		ncursor = 0;
		while (ncursor < es->linelen - 1 &&
		    isspace((unsigned char)es->cbuf[ncursor]))
			ncursor++;
		break;

	case '|':
		ncursor = argcnt;
		if (ncursor > es->linelen)
			ncursor = es->linelen;
		if (ncursor)
			ncursor--;
		while (isu8cont(es->cbuf[ncursor]))
			ncursor--;
		break;

	case '$':
		ncursor = es->linelen;
		break;

	case '%':
		ncursor = es->cursor;
		while (ncursor < es->linelen &&
		    (i = bracktype(es->cbuf[ncursor])) == 0)
			ncursor++;
		if (ncursor == es->linelen)
			return -1;
		bcount = 1;
		do {
			if (i > 0) {
				if (++ncursor >= es->linelen)
					return -1;
			} else {
				if (--ncursor < 0)
					return -1;
			}
			t = bracktype(es->cbuf[ncursor]);
			if (t == i)
				bcount++;
			else if (t == -i)
				bcount--;
		} while (bcount != 0);
		if (sub && i > 0)
			ncursor++;
		break;

	default:
		return -1;
	}
	return ncursor;
}

static int
redo_insert(int count)
{
	while (count-- > 0)
		if (putbuf(ibuf, inslen, insert==REPLACE) != 0)
			return -1;
	if (es->cursor > 0)
		while (isu8cont(es->cbuf[--es->cursor]))
			continue;
	insert = 0;
	return 0;
}

static void
yank_range(int a, int b)
{
	yanklen = b - a;
	if (yanklen != 0)
		memmove(ybuf, &es->cbuf[a], yanklen);
}

static int
bracktype(int ch)
{
	switch (ch) {

	case '(':
		return 1;

	case '[':
		return 2;

	case '{':
		return 3;

	case ')':
		return -1;

	case ']':
		return -2;

	case '}':
		return -3;

	default:
		return 0;
	}
}

/*
 *	Non user interface editor routines below here
 */

static int	cur_col;		/* current display column */
static int	pwidth;			/* display columns needed for prompt */
static int	prompt_trunc;		/* how much of prompt to truncate */
static int	prompt_skip;		/* how much of prompt to skip */
static int	winwidth;		/* available column positions */
static char	*wbuf[2];		/* current & previous window buffer */
static int	wbuf_len;		/* length of window buffers (x_cols-3)*/
static int	win;			/* number of window buffer in use */
static char	morec;			/* more character at right of window */
static char	holdbuf[LINE];		/* place to hold last edit buffer */
static int	holdlen;		/* length of holdbuf */

static void
save_cbuf(void)
{
	memmove(holdbuf, es->cbuf, es->linelen);
	holdlen = es->linelen;
	holdbuf[holdlen] = '\0';
}

static void
restore_cbuf(void)
{
	es->cursor = 0;
	es->linelen = holdlen;
	memmove(es->cbuf, holdbuf, holdlen);
}

/* return a new edstate */
static struct edstate *
save_edstate(struct edstate *old)
{
	struct edstate *new;

	new = alloc(sizeof(struct edstate), APERM);
	new->cbuf = alloc(old->cbufsize, APERM);
	memcpy(new->cbuf, old->cbuf, old->linelen);
	new->cbufsize = old->cbufsize;
	new->linelen = old->linelen;
	new->cursor = old->cursor;
	new->winleft = old->winleft;
	return new;
}

static void
restore_edstate(struct edstate *new, struct edstate *old)
{
	memcpy(new->cbuf, old->cbuf, old->linelen);
	new->linelen = old->linelen;
	new->cursor = old->cursor;
	new->winleft = old->winleft;
	free_edstate(old);
}

static void
free_edstate(struct edstate *old)
{
	afree(old->cbuf, APERM);
	afree(old, APERM);
}

static void
edit_reset(char *buf, size_t len)
{
	const char *p;

	es = &ebuf;
	es->cbuf = buf;
	es->cbufsize = len;
	undo = &undobuf;
	undo->cbufsize = len;

	es->linelen = undo->linelen = 0;
	es->cursor = undo->cursor = 0;
	es->winleft = undo->winleft = 0;

	cur_col = pwidth = promptlen(prompt, &p);
	prompt_skip = p - prompt;
	if (pwidth > x_cols - 3 - MIN_EDIT_SPACE) {
		cur_col = x_cols - 3 - MIN_EDIT_SPACE;
		prompt_trunc = pwidth - cur_col;
		pwidth -= prompt_trunc;
	} else
		prompt_trunc = 0;
	if (!wbuf_len || wbuf_len != x_cols - 3) {
		wbuf_len = x_cols - 3;
		wbuf[0] = aresize(wbuf[0], wbuf_len, APERM);
		wbuf[1] = aresize(wbuf[1], wbuf_len, APERM);
	}
	(void) memset(wbuf[0], ' ', wbuf_len);
	(void) memset(wbuf[1], ' ', wbuf_len);
	winwidth = x_cols - pwidth - 3;
	win = 0;
	morec = ' ';
	holdlen = 0;
}

/*
 * this is used for calling x_escape() in complete_word()
 */
static int
x_vi_putbuf(const char *s, size_t len)
{
	return putbuf(s, len, 0);
}

static int
putbuf(const char *buf, int len, int repl)
{
	if (len == 0)
		return 0;
	if (repl) {
		if (es->cursor + len >= es->cbufsize)
			return -1;
		if (es->cursor + len > es->linelen)
			es->linelen = es->cursor + len;
	} else {
		if (es->linelen + len >= es->cbufsize)
			return -1;
		memmove(&es->cbuf[es->cursor + len], &es->cbuf[es->cursor],
		    es->linelen - es->cursor);
		es->linelen += len;
	}
	memmove(&es->cbuf[es->cursor], buf, len);
	es->cursor += len;
	return 0;
}

static void
del_range(int a, int b)
{
	if (es->linelen != b)
		memmove(&es->cbuf[a], &es->cbuf[b], es->linelen - b);
	es->linelen -= b - a;
}

static int
findch(int ch, int cnt, int forw, int incl)
{
	int	ncursor;

	if (es->linelen == 0)
		return -1;
	ncursor = es->cursor;
	while (cnt--) {
		do {
			if (forw) {
				if (++ncursor == es->linelen)
					return -1;
			} else {
				if (--ncursor < 0)
					return -1;
			}
		} while (es->cbuf[ncursor] != ch);
	}
	if (!incl) {
		if (forw)
			ncursor--;
		else
			ncursor++;
	}
	return ncursor;
}

/* Move right one character, and then to the beginning of the next word. */
static int
forwword(int argcnt)
{
	int ncursor, skip_space, want_letnum;
	unsigned char uc;

	ncursor = es->cursor;
	while (ncursor < es->linelen && argcnt--) {
		skip_space = 0;
		want_letnum = -1;
		ncursor--;
		while (++ncursor < es->linelen) {
			uc = es->cbuf[ncursor];
			if (isspace(uc)) {
				skip_space = 1;
				continue;
			} else if (skip_space)
				break;
			if (uc & 0x80)
				continue;
			if (want_letnum == -1)
				want_letnum = letnum(uc);
			else if (want_letnum != letnum(uc))
				break;
		}
	}
	return ncursor;
}

/* Move left one character, and then to the beginning of the word. */
static int
backword(int argcnt)
{
	int ncursor, skip_space, want_letnum;
	unsigned char uc;

	ncursor = es->cursor;
	while (ncursor > 0 && argcnt--) {
		skip_space = 1;
		want_letnum = -1;
		while (ncursor-- > 0) {
			uc = es->cbuf[ncursor];
			if (isspace(uc)) {
				if (skip_space)
					continue;
				else
					break;
			}
			skip_space = 0;
			if (uc & 0x80)
				continue;
			if (want_letnum == -1)
				want_letnum = letnum(uc);
			else if (want_letnum != letnum(uc))
				break;
		}
		ncursor++;
	}
	return ncursor;
}

/* Move right one character, and then to the byte after the word. */
static int
endword(int argcnt)
{
	int ncursor, skip_space, want_letnum;
	unsigned char uc;

	ncursor = es->cursor;
	while (ncursor < es->linelen && argcnt--) {
		skip_space = 1;
		want_letnum = -1;
		while (++ncursor < es->linelen) {
			uc = es->cbuf[ncursor];
			if (isspace(uc)) {
				if (skip_space)
					continue;
				else
					break;
			}
			skip_space = 0;
			if (uc & 0x80)
				continue;
			if (want_letnum == -1)
				want_letnum = letnum(uc);
			else if (want_letnum != letnum(uc))
				break;
		}
	}
	return ncursor;
}

/* Move right one character, and then to the beginning of the next big word. */
static int
Forwword(int argcnt)
{
	int	ncursor;

	ncursor = es->cursor;
	while (ncursor < es->linelen && argcnt--) {
		while (!isspace((unsigned char)es->cbuf[ncursor]) &&
		    ncursor < es->linelen)
			ncursor++;
		while (isspace((unsigned char)es->cbuf[ncursor]) &&
		    ncursor < es->linelen)
			ncursor++;
	}
	return ncursor;
}

/* Move left one character, and then to the beginning of the big word. */
static int
Backword(int argcnt)
{
	int	ncursor;

	ncursor = es->cursor;
	while (ncursor > 0 && argcnt--) {
		while (--ncursor >= 0 &&
		    isspace((unsigned char)es->cbuf[ncursor]))
			;
		while (ncursor >= 0 &&
		    !isspace((unsigned char)es->cbuf[ncursor]))
			ncursor--;
		ncursor++;
	}
	return ncursor;
}

/* Move right one character, and then to the byte after the big word. */
static int
Endword(int argcnt)
{
	int	ncursor;

	ncursor = es->cursor;
	while (ncursor < es->linelen && argcnt--) {
		while (++ncursor < es->linelen &&
		    isspace((unsigned char)es->cbuf[ncursor]))
			;
		while (ncursor < es->linelen &&
		    !isspace((unsigned char)es->cbuf[ncursor]))
			ncursor++;
	}
	return ncursor;
}

static int
grabhist(int save, int n)
{
	char	*hptr;

	if (n < 0 || n > hlast)
		return -1;
	if (n == hlast) {
		restore_cbuf();
		ohnum = n;
		return 0;
	}
	(void) histnum(n);
	if ((hptr = *histpos()) == NULL) {
		internal_warningf("%s: bad history array", __func__);
		return -1;
	}
	if (save)
		save_cbuf();
	if ((es->linelen = strlen(hptr)) >= es->cbufsize)
		es->linelen = es->cbufsize - 1;
	memmove(es->cbuf, hptr, es->linelen);
	es->cursor = 0;
	ohnum = n;
	return 0;
}

static int
grabsearch(int save, int start, int fwd, char *pat)
{
	char	*hptr;
	int	hist;
	int	anchored;

	if ((start == 0 && fwd == 0) || (start >= hlast-1 && fwd == 1))
		return -1;
	if (fwd)
		start++;
	else
		start--;
	anchored = *pat == '^' ? (++pat, 1) : 0;
	if ((hist = findhist(start, fwd, pat, anchored)) < 0) {
		/* if (start != 0 && fwd && match(holdbuf, pat) >= 0) { */
		/* XXX should strcmp be strncmp? */
		if (start != 0 && fwd && strcmp(holdbuf, pat) >= 0) {
			restore_cbuf();
			return 0;
		} else
			return -1;
	}
	if (save)
		save_cbuf();
	histnum(hist);
	hptr = *histpos();
	if ((es->linelen = strlen(hptr)) >= es->cbufsize)
		es->linelen = es->cbufsize - 1;
	memmove(es->cbuf, hptr, es->linelen);
	es->cursor = 0;
	return hist;
}

static void
do_clear_screen(void)
{
	x_puts(CLEAR_SCREEN);
	redraw_line(0, 1);
}

static void
redraw_line(int neednl, int full)
{
	(void) memset(wbuf[win], ' ', wbuf_len);
	if (neednl) {
		x_putc('\r');
		x_putc('\n');
	}
	vi_pprompt(full);
	cur_col = pwidth;
	morec = ' ';
}

static void
refresh_line(int leftside)
{
	if (outofwin())
		rewindow();
	display(wbuf[1 - win], wbuf[win], leftside);
	win = 1 - win;
}

static int
outofwin(void)
{
	int	cur, col;

	if (es->cursor < es->winleft)
		return 1;
	col = 0;
	cur = es->winleft;
	while (cur < es->cursor)
		col = newcol((unsigned char) es->cbuf[cur++], col);
	if (col >= winwidth)
		return 1;
	return 0;
}

static void
rewindow(void)
{
	int		cur;	/* byte# in the main command line buffer */
	int		col;	/* corresponding display column */
	int		tabc;	/* columns a tab character can take up */
	int		thisc;	/* columns the current character requires */
	unsigned char	uc;	/* the current byte */

	/* The desired cursor position is near the middle of the window. */
	cur = es->cursor;
	col = winwidth / 2;
	tabc = 0;

	/* Step left to find the desired left margin. */
	while (cur > 0 && col > 0) {
		uc = es->cbuf[--cur];

		/* Never start the window on a continuation byte. */
		if (isu8cont(uc))
			continue;

		if (uc == '\t') {
			/*
			 * If two tabs occur close together,
			 * count the right one, including optional
			 * characters between both, as 8 columns.
			 */
			if (tabc > 0) {
				col -= 8;
				/* Prefer starting after a tab. */
				if (col <= 0)
					cur++;
			}

			/*
			 * A tab can be preceded by up to 7 characters
			 * without taking up additional space.
			 */
			tabc = 7;
			continue;
		}
		thisc = char_len(uc);
		if (tabc > 0) {
			if (tabc > thisc) {
				/* The character still fits in the tab. */
				tabc -= thisc;
				continue;
			}
			col -= 8;	/* The tab is now full. */
			thisc -= tabc;	/* This may produce overflow. */
			tabc = 0;
		}

		/* Handle a normal character or the overflow. */
		col -= thisc;
	}
	es->winleft = cur;
}

/* Printing the byte ch at display column col moves to which column? */
static int
newcol(int ch, int col)
{
	if (ch == '\t')
		return (col | 7) + 1;
	if (isu8cont(ch))
		return col;
	return col + char_len(ch);
}

/* Display wb1 assuming that wb2 is currently displayed. */
static void
display(char *wb1, char *wb2, int leftside)
{
	char	*twb1;	/* pointer into the buffer to display */
	char	*twb2;	/* pointer into the previous display buffer */
	static int lastb = -1; /* last byte# written from wb1, if UTF-8 */
	int	 cur;	/* byte# in the main command line buffer */
	int	 col;	/* display column loop variable */
	int	 ncol;	/* display column of the cursor */
	int	 cnt;	/* remaining display columns to fill */
	int	 moreright;
	char	 mc;	/* new "more character" at the right of window */
	unsigned char ch;

	/*
	 * Fill the current display buffer with data from cbuf.
	 * In this first loop, col does not include the prompt.
	 */

	ncol = col = 0;
	cur = es->winleft;
	moreright = 0;
	twb1 = wb1;
	while (col < winwidth && cur < es->linelen) {
		if (cur == es->cursor && leftside)
			ncol = col + pwidth;
		if ((ch = es->cbuf[cur]) == '\t') {
			do {
				*twb1++ = ' ';
			} while (++col < winwidth && (col & 7) != 0);
		} else {
			if ((ch & 0x80) && Flag(FVISHOW8)) {
				*twb1++ = 'M';
				if (++col < winwidth) {
					*twb1++ = '-';
					col++;
				}
				ch &= 0x7f;
			}
			if (col < winwidth) {
				if (ch < ' ' || ch == 0x7f) {
					*twb1++ = '^';
					if (++col < winwidth) {
						*twb1++ = ch ^ '@';
						col++;
					}
				} else {
					*twb1++ = ch;
					if (col == 0 || !isu8cont(ch))
						col++;
				}
			}
		}
		if (cur == es->cursor && !leftside)
			ncol = col + pwidth - 1;
		cur++;
	}
	if (cur == es->cursor)
		ncol = col + pwidth;

	/* Pad the current display buffer to the right margin. */

	if (col < winwidth) {
		while (col < winwidth) {
			*twb1++ = ' ';
			col++;
		}
	} else
		moreright++;
	*twb1 = ' ';

	/*
	 * Update the terminal display with data from wb1.
	 * In this final loop, col includes the prompt.
	 */

	col = pwidth;
	cnt = winwidth;
	for (twb1 = wb1, twb2 = wb2; cnt; twb1++, twb2++) {
		if (*twb1 != *twb2) {

			/*
			 * When a byte changes in the middle of a UTF-8
			 * character, back up to the start byte, unless
			 * the previous byte was the last one written.
			 */

			if (isu8cont(*twb1)) {
				if (col > pwidth)
					col--;
				if (lastb >= 0 && twb1 == wb1 + lastb + 1)
					cur_col = col;
				else while (twb1 > wb1 && isu8cont(*twb1)) {
					twb1--;
					twb2--;
				}
			}

			if (cur_col != col)
				ed_mov_opt(col, wb1);

			/*
			 * Always write complete characters, and
			 * advance all pointers accordingly.
			 */

			x_putc(*twb1);
			while (isu8cont(twb1[1])) {
				x_putc(*++twb1);
				twb2++;
			}
			lastb = *twb1 & 0x80 ? twb1 - wb1 : -1;
			cur_col++;
		} else if (twb1 > wb1 && isu8cont(*twb1))
			continue;

		/*
		 * For changed continuation bytes, we backed up.
		 * For unchanged ones, we jumped to the next byte.
		 * So, getting here, we had a real column.
		 */

		col++;
		cnt--;
	}

	/* Update the "more character". */

	if (es->winleft > 0 && moreright)
		/* POSIX says to use * for this but that is a globbing
		 * character and may confuse people; + is more innocuous
		 */
		mc = '+';
	else if (es->winleft > 0)
		mc = '<';
	else if (moreright)
		mc = '>';
	else
		mc = ' ';
	if (mc != morec) {
		ed_mov_opt(pwidth + winwidth + 1, wb1);
		x_putc(mc);
		cur_col++;
		morec = mc;
		lastb = -1;
	}

	/* Move the cursor to its new position. */

	if (cur_col != ncol) {
		ed_mov_opt(ncol, wb1);
		lastb = -1;
	}
}

/* Move the display cursor to display column number col. */
static void
ed_mov_opt(int col, char *wb)
{
	int ci;

	/* The cursor is already at the right place. */

	if (cur_col == col)
		return;

	/* The cursor is too far right. */

	if (cur_col > col) {
		if (cur_col > 2 * col + 1) {
			/* Much too far right, redraw from scratch. */
			x_putc('\r');
			vi_pprompt(0);
			cur_col = pwidth;
		} else {
			/* Slightly too far right, back up. */
			do {
				x_putc('\b');
			} while (--cur_col > col);
			return;
		}
	}

	/* Advance the cursor. */

	ci = pwidth;
	while (ci < col || (ci > pwidth && isu8cont(*wb))) {
		ci = newcol((unsigned char)*wb, ci);
		if (ci == pwidth)
			ci++;
		if (ci > cur_col)
			x_putc(*wb);
		wb++;
	}
	cur_col = ci;
}


/* replace word with all expansions (ie, expand word*) */
static int
expand_word(int command)
{
	static struct edstate *buf;
	int rval = 0;
	int nwords;
	int start, end;
	char **words;
	int i;

	/* Undo previous expansion */
	if (command == 0 && expanded == EXPAND && buf) {
		restore_edstate(es, buf);
		buf = NULL;
		expanded = NONE;
		return 0;
	}
	if (buf) {
		free_edstate(buf);
		buf = NULL;
	}

	nwords = x_cf_glob(XCF_COMMAND_FILE|XCF_FULLPATH,
	    es->cbuf, es->linelen, es->cursor,
	    &start, &end, &words, NULL);
	if (nwords == 0) {
		vi_error();
		return -1;
	}

	buf = save_edstate(es);
	expanded = EXPAND;
	del_range(start, end);
	es->cursor = start;
	for (i = 0; i < nwords; ) {
		if (x_escape(words[i], strlen(words[i]), x_vi_putbuf) != 0) {
			rval = -1;
			break;
		}
		if (++i < nwords && putbuf(" ", 1, 0) != 0) {
			rval = -1;
			break;
		}
	}
	i = buf->cursor - end;
	if (rval == 0 && i > 0)
		es->cursor += i;
	modified = 1; hnum = hlast;
	insert = INSERT;
	lastac = 0;
	refresh_line(0);
	return rval;
}

static int
complete_word(int command, int count)
{
	static struct edstate *buf;
	int rval = 0;
	int nwords;
	int start, end;
	char **words;
	char *match;
	int match_len;
	int is_unique;
	int is_command;

	/* Undo previous completion */
	if (command == 0 && expanded == COMPLETE && buf) {
		print_expansions(buf);
		expanded = PRINT;
		return 0;
	}
	if (command == 0 && expanded == PRINT && buf) {
		restore_edstate(es, buf);
		buf = NULL;
		expanded = NONE;
		return 0;
	}
	if (buf) {
		free_edstate(buf);
		buf = NULL;
	}

	/* XCF_FULLPATH for count 'cause the menu printed by print_expansions()
	 * was done this way.
	 */
	nwords = x_cf_glob(XCF_COMMAND_FILE | (count ? XCF_FULLPATH : 0),
	    es->cbuf, es->linelen, es->cursor,
	    &start, &end, &words, &is_command);
	if (nwords == 0) {
		vi_error();
		return -1;
	}
	if (count) {
		int i;

		count--;
		if (count >= nwords) {
			vi_error();
			x_print_expansions(nwords, words, is_command);
			x_free_words(nwords, words);
			redraw_line(0, 0);
			return -1;
		}
		/*
		 * Expand the count'th word to its basename
		 */
		if (is_command) {
			match = words[count] +
			    x_basename(words[count], NULL);
			/* If more than one possible match, use full path */
			for (i = 0; i < nwords; i++)
				if (i != count &&
				    strcmp(words[i] + x_basename(words[i],
				    NULL), match) == 0) {
					match = words[count];
					break;
				}
		} else
			match = words[count];
		match_len = strlen(match);
		is_unique = 1;
		/* expanded = PRINT;	next call undo */
	} else {
		match = words[0];
		match_len = x_longest_prefix(nwords, words);
		expanded = COMPLETE;	/* next call will list completions */
		is_unique = nwords == 1;
	}

	buf = save_edstate(es);
	del_range(start, end);
	es->cursor = start;

	/* escape all shell-sensitive characters and put the result into
	 * command buffer */
	rval = x_escape(match, match_len, x_vi_putbuf);

	if (rval == 0 && is_unique) {
		/* If exact match, don't undo.  Allows directory completions
		 * to be used (ie, complete the next portion of the path).
		 */
		expanded = NONE;

		/* If not a directory, add a space to the end... */
		if (match_len > 0 && match[match_len - 1] != '/' &&
		    !x_is_tilde_user_completion(es->cbuf + start,
		    end - start, match, match_len))
			rval = putbuf(" ", 1, 0);
	}
	x_free_words(nwords, words);

	modified = 1; hnum = hlast;
	insert = INSERT;
	lastac = 0;	 /* prevent this from being redone... */
	refresh_line(0);

	return rval;
}

static int
print_expansions(struct edstate *e)
{
	int nwords;
	int start, end;
	char **words;
	int is_command;

	nwords = x_cf_glob(XCF_COMMAND_FILE|XCF_FULLPATH,
	    e->cbuf, e->linelen, e->cursor,
	    &start, &end, &words, &is_command);
	if (nwords == 0) {
		vi_error();
		return -1;
	}
	x_print_expansions(nwords, words, is_command);
	x_free_words(nwords, words);
	redraw_line(0, 0);
	return 0;
}

/*
 * The number of bytes needed to encode byte c.
 * Control bytes get "M-" or "^" prepended.
 * This function does not handle tabs.
 */
static int
char_len(int c)
{
	int len = 1;

	if ((c & 0x80) && Flag(FVISHOW8)) {
		len += 2;
		c &= 0x7f;
	}
	if (c < ' ' || c == 0x7f)
		len++;
	return len;
}

/* Similar to x_zotc(emacs.c), but no tab weirdness */
static void
x_vi_zotc(int c)
{
	if (Flag(FVISHOW8) && (c & 0x80)) {
		x_puts("M-");
		c &= 0x7f;
	}
	if (c < ' ' || c == 0x7f) {
		x_putc('^');
		c ^= '@';
	}
	x_putc(c);
}

static void
vi_pprompt(int full)
{
	pprompt(prompt + (full ? 0 : prompt_skip), prompt_trunc);
}

static void
vi_error(void)
{
	/* Beem out of any macros as soon as an error occurs */
	vi_macro_reset();
	x_putc(BEL);
	x_flush();
}

static void
vi_macro_reset(void)
{
	if (macro.p) {
		afree(macro.buf, APERM);
		memset((char *) &macro, 0, sizeof(macro));
	}
}

static int
isu8cont(unsigned char c)
{
	return !Flag(FVISHOW8) && (c & (0x80 | 0x40)) == 0x80;
}

/*
 * Command history
 */

/*
 * command history
 */

/*
 *	This file contains
 *	a)	the original in-memory history  mechanism
 *	b)	a more complicated mechanism done by  pc@hillside.co.uk
 *		that more closely follows the real ksh way of doing
 *		things.
 */

static void	history_write(void);
static FILE	*history_open(void);
static void	history_load(Source *);
static void	history_close(void);

static int	hist_execute(char *);
static int	hist_replace(char **, const char *, const char *, int);
static char   **hist_get(const char *, int, int);
static char   **hist_get_oldest(void);
static void	histbackup(void);

static FILE	*histfh;
static char   **histbase;	/* actual start of the history[] allocation */
static char   **current;	/* current position in history[] */
static char    *hname;		/* current name of history file */
static int	hstarted;	/* set after hist_init() called */
static int	ignoredups;	/* ditch duplicated history lines? */
static int	ignorespace;	/* ditch lines starting with a space? */
static Source	*hist_source;
static uint32_t	line_co;

static struct stat last_sb;

static volatile sig_atomic_t	c_fc_depth;

int
c_fc(char **wp)
{
	struct shf *shf;
	struct temp *tf = NULL;
	char *p, *editor = NULL;
	int gflag = 0, lflag = 0, nflag = 0, sflag = 0, rflag = 0;
	int optc, ret;
	char *first = NULL, *last = NULL;
	char **hfirst, **hlast, **hp;

	if (c_fc_depth != 0) {
		bi_errorf("history function called recursively");
		return 1;
	}

	if (!Flag(FTALKING_I)) {
		bi_errorf("history functions not available");
		return 1;
	}

	while ((optc = ksh_getopt(wp, &builtin_opt,
	    "e:glnrs0,1,2,3,4,5,6,7,8,9,")) != -1)
		switch (optc) {
		case 'e':
			p = builtin_opt.optarg;
			if (strcmp(p, "-") == 0)
				sflag++;
			else {
				size_t len = strlen(p) + 4;
				editor = str_nsave(p, len, ATEMP);
				strlcat(editor, " $_", len);
			}
			break;
		case 'g': /* non-at&t ksh */
			gflag++;
			break;
		case 'l':
			lflag++;
			break;
		case 'n':
			nflag++;
			break;
		case 'r':
			rflag++;
			break;
		case 's':	/* posix version of -e - */
			sflag++;
			break;
		  /* kludge city - accept -num as -- -num (kind of) */
		case '0': case '1': case '2': case '3': case '4':
		case '5': case '6': case '7': case '8': case '9':
			p = shf_smprintf("-%c%s",
					optc, builtin_opt.optarg);
			if (!first)
				first = p;
			else if (!last)
				last = p;
			else {
				bi_errorf("too many arguments");
				return 1;
			}
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	/* Substitute and execute command */
	if (sflag) {
		char *pat = NULL, *rep = NULL;

		if (editor || lflag || nflag || rflag) {
			bi_errorf("can't use -e, -l, -n, -r with -s (-e -)");
			return 1;
		}

		/* Check for pattern replacement argument */
		if (*wp && **wp && (p = strchr(*wp + 1, '='))) {
			pat = str_save(*wp, ATEMP);
			p = pat + (p - *wp);
			*p++ = '\0';
			rep = p;
			wp++;
		}
		/* Check for search prefix */
		if (!first && (first = *wp))
			wp++;
		if (last || *wp) {
			bi_errorf("too many arguments");
			return 1;
		}

		hp = first ? hist_get(first, false, false) :
		    hist_get_newest(false);
		if (!hp)
			return 1;
		c_fc_depth++;
		ret = hist_replace(hp, pat, rep, gflag);
		c_fc_reset();
		return ret;
	}

	if (editor && (lflag || nflag)) {
		bi_errorf("can't use -l, -n with -e");
		return 1;
	}

	if (!first && (first = *wp))
		wp++;
	if (!last && (last = *wp))
		wp++;
	if (*wp) {
		bi_errorf("too many arguments");
		return 1;
	}
	if (!first) {
		hfirst = lflag ? hist_get("-16", true, true) :
		    hist_get_newest(false);
		if (!hfirst)
			return 1;
		/* can't fail if hfirst didn't fail */
		hlast = hist_get_newest(false);
	} else {
		/* POSIX says not an error if first/last out of bounds
		 * when range is specified; at&t ksh and pdksh allow out of
		 * bounds for -l as well.
		 */
		hfirst = hist_get(first, (lflag || last) ? true : false,
		    lflag ? true : false);
		if (!hfirst)
			return 1;
		hlast = last ? hist_get(last, true, lflag ? true : false) :
		    (lflag ? hist_get_newest(false) : hfirst);
		if (!hlast)
			return 1;
	}
	if (hfirst > hlast) {
		char **temp;

		temp = hfirst; hfirst = hlast; hlast = temp;
		rflag = !rflag; /* POSIX */
	}

	/* List history */
	if (lflag) {
		char *s, *t;
		const char *nfmt = nflag ? "\t" : "%d\t";

		for (hp = rflag ? hlast : hfirst;
		    hp >= hfirst && hp <= hlast; hp += rflag ? -1 : 1) {
			shf_fprintf(shl_stdout, nfmt,
			    hist_source->line - (int) (histptr - hp));
			/* print multi-line commands correctly */
			for (s = *hp; (t = strchr(s, '\n')); s = t)
				shf_fprintf(shl_stdout, "%.*s\t", ++t - s, s);
			shf_fprintf(shl_stdout, "%s\n", s);
		}
		shf_flush(shl_stdout);
		return 0;
	}

	/* Run editor on selected lines, then run resulting commands */

	tf = maketemp(ATEMP, TT_HIST_EDIT, &genv->temps);
	if (!(shf = tf->shf)) {
		bi_errorf("cannot create temp file %s - %s",
		    tf->name, strerror(errno));
		return 1;
	}
	for (hp = rflag ? hlast : hfirst;
	    hp >= hfirst && hp <= hlast; hp += rflag ? -1 : 1)
		shf_fprintf(shf, "%s\n", *hp);
	if (shf_close(shf) == EOF) {
		bi_errorf("error writing temporary file - %s", strerror(errno));
		return 1;
	}

	/* Ignore setstr errors here (arbitrary) */
	setstr(local("_", false), tf->name, KSH_RETURN_ERROR);

	/* XXX: source should not get trashed by this.. */
	{
		Source *sold = source;

		ret = command(editor ? editor : "${FCEDIT:-/bin/ed} $_", 0);
		source = sold;
		if (ret)
			return ret;
	}

	{
		struct stat statb;
		XString xs;
		char *xp;
		int n;

		if (!(shf = shf_open(tf->name, O_RDONLY, 0, 0))) {
			bi_errorf("cannot open temp file %s", tf->name);
			return 1;
		}

		n = fstat(shf->fd, &statb) == -1 ? 128 :
		    statb.st_size + 1;
		Xinit(xs, xp, n, hist_source->areap);
		while ((n = shf_read(xp, Xnleft(xs, xp), shf)) > 0) {
			xp += n;
			if (Xnleft(xs, xp) <= 0)
				XcheckN(xs, xp, Xlength(xs, xp));
		}
		if (n < 0) {
			bi_errorf("error reading temp file %s - %s",
			    tf->name, strerror(shf->errno_));
			shf_close(shf);
			return 1;
		}
		shf_close(shf);
		*xp = '\0';
		strip_nuls(Xstring(xs, xp), Xlength(xs, xp));
		c_fc_depth++;
		ret = hist_execute(Xstring(xs, xp));
		c_fc_reset();
		return ret;
	}
}

/* Reset the c_fc depth counter.
 * Made available for when an fc call is interrupted.
 */
void
c_fc_reset(void)
{
	c_fc_depth = 0;
}

/* Save cmd in history, execute cmd (cmd gets trashed) */
static int
hist_execute(char *cmd)
{
	Source *sold;
	int ret;
	char *p, *q;

	histbackup();

	for (p = cmd; p; p = q) {
		if ((q = strchr(p, '\n'))) {
			*q++ = '\0'; /* kill the newline */
			if (!*q) /* ignore trailing newline */
				q = NULL;
		}
		histsave(++(hist_source->line), p, 1);

		shellf("%s\n", p); /* POSIX doesn't say this is done... */
		if ((p = q)) /* restore \n (trailing \n not restored) */
			q[-1] = '\n';
	}

	/* Commands are executed here instead of pushing them onto the
	 * input 'cause posix says the redirection and variable assignments
	 * in
	 *	X=y fc -e - 42 2> /dev/null
	 * are to effect the repeated commands environment.
	 */
	/* XXX: source should not get trashed by this.. */
	sold = source;
	ret = command(cmd, 0);
	source = sold;
	return ret;
}

static int
hist_replace(char **hp, const char *pat, const char *rep, int global)
{
	char *line;

	if (!pat)
		line = str_save(*hp, ATEMP);
	else {
		char *s, *s1;
		int pat_len = strlen(pat);
		int rep_len = strlen(rep);
		int len;
		XString xs;
		char *xp;
		int any_subst = 0;

		Xinit(xs, xp, 128, ATEMP);
		for (s = *hp; (s1 = strstr(s, pat)) && (!any_subst || global);
		    s = s1 + pat_len) {
			any_subst = 1;
			len = s1 - s;
			XcheckN(xs, xp, len + rep_len);
			memcpy(xp, s, len);		/* first part */
			xp += len;
			memcpy(xp, rep, rep_len);	/* replacement */
			xp += rep_len;
		}
		if (!any_subst) {
			bi_errorf("substitution failed");
			return 1;
		}
		len = strlen(s) + 1;
		XcheckN(xs, xp, len);
		memcpy(xp, s, len);
		xp += len;
		line = Xclose(xs, xp);
	}
	return hist_execute(line);
}

/*
 * get pointer to history given pattern
 * pattern is a number or string
 */
static char **
hist_get(const char *str, int approx, int allow_cur)
{
	char **hp = NULL;
	int n;

	if (getn(str, &n)) {
		hp = histptr + (n < 0 ? n : (n - hist_source->line));
		if ((long)hp < (long)history) {
			if (approx)
				hp = hist_get_oldest();
			else {
				bi_errorf("%s: not in history", str);
				hp = NULL;
			}
		} else if (hp > histptr) {
			if (approx)
				hp = hist_get_newest(allow_cur);
			else {
				bi_errorf("%s: not in history", str);
				hp = NULL;
			}
		} else if (!allow_cur && hp == histptr) {
			bi_errorf("%s: invalid range", str);
			hp = NULL;
		}
	} else {
		int anchored = *str == '?' ? (++str, 0) : 1;

		/* the -1 is to avoid the current fc command */
		n = findhist(histptr - history - 1, 0, str, anchored);
		if (n < 0) {
			bi_errorf("%s: not in history", str);
			hp = NULL;
		} else
			hp = &history[n];
	}
	return hp;
}

/* Return a pointer to the newest command in the history */
char **
hist_get_newest(int allow_cur)
{
	if (histptr < history || (!allow_cur && histptr == history)) {
		bi_errorf("no history (yet)");
		return NULL;
	}
	if (allow_cur)
		return histptr;
	return histptr - 1;
}

/* Return a pointer to the oldest command in the history */
static char **
hist_get_oldest(void)
{
	if (histptr <= history) {
		bi_errorf("no history (yet)");
		return NULL;
	}
	return history;
}

/******************************/
/* Back up over last histsave */
/******************************/
static void
histbackup(void)
{
	static int last_line = -1;

	if (histptr >= history && last_line != hist_source->line) {
		hist_source->line--;
		afree(*histptr, APERM);
		histptr--;
		last_line = hist_source->line;
	}
}

static void
histreset(void)
{
	char **hp;

	for (hp = history; hp <= histptr; hp++)
		afree(*hp, APERM);

	histptr = history - 1;
	hist_source->line = 0;
}

/*
 * Return the current position.
 */
char **
histpos(void)
{
	return current;
}

int
histnum(int n)
{
	int	last = histptr - history;

	if (n < 0 || n >= last) {
		current = histptr;
		return last;
	} else {
		current = &history[n];
		return n;
	}
}

/*
 * This will become unnecessary if hist_get is modified to allow
 * searching from positions other than the end, and in either
 * direction.
 */
int
findhist(int start, int fwd, const char *str, int anchored)
{
	char	**hp;
	int	maxhist = histptr - history;
	int	incr = fwd ? 1 : -1;
	int	len = strlen(str);

	if (start < 0 || start >= maxhist)
		start = maxhist;

	hp = &history[start];
	for (; hp >= history && hp <= histptr; hp += incr)
		if ((anchored && strncmp(*hp, str, len) == 0) ||
		    (!anchored && strstr(*hp, str)))
			return hp - history;

	return -1;
}

int
findhistrel(const char *str)
{
	const char *errstr;
	int	maxhist = histptr - history;
	int	rec;

	rec = strtonum(str, -maxhist, maxhist, &errstr);
	if (errstr)
		return -1;

	if (rec == 0)
		return -1;
	if (rec > 0)
		return rec - 1;
	return maxhist + rec;
}

void
sethistcontrol(const char *str)
{
	char *spec, *tok, *state;

	ignorespace = 0;
	ignoredups = 0;

	if (str == NULL)
		return;

	spec = str_save(str, ATEMP);
	for (tok = strtok_r(spec, ":", &state); tok != NULL;
	     tok = strtok_r(NULL, ":", &state)) {
		if (strcmp(tok, "ignoredups") == 0)
			ignoredups = 1;
		else if (strcmp(tok, "ignorespace") == 0)
			ignorespace = 1;
	}
	afree(spec, ATEMP);
}

/*
 *	set history
 *	this means reallocating the dataspace
 */
void
sethistsize(int n)
{
	if (n > 0 && (uint32_t)n != histsize) {
		char **tmp;
		int offset = histptr - history;

		/* save most recent history */
		if (offset > n - 1) {
			char **hp;

			offset = n - 1;
			for (hp = history; hp < histptr - offset; hp++)
				afree(*hp, APERM);
			memmove(history, histptr - offset, n * sizeof(char *));
		}

		tmp = reallocarray(histbase, n + 1, sizeof(char *));
		if (tmp != NULL) {
			histbase = tmp;
			histsize = n;
			history = histbase + 1;
			histptr = history + offset;
		} else
			warningf(false, "resizing history storage: %s",
			    strerror(errno));
	}
}

/*
 *	set history file
 *	This can mean reloading/resetting/starting history file
 *	maintenance
 */
void
sethistfile(const char *name)
{
	/* if not started then nothing to do */
	if (hstarted == 0)
		return;

	/* if the name is the same as the name we have */
	if (hname && strcmp(hname, name) == 0)
		return;
	/*
	 * its a new name - possibly
	 */
	if (hname) {
		afree(hname, APERM);
		hname = NULL;
		histreset();
	}

	history_close();
	hist_init(hist_source);
}

/*
 *	initialise the history vector
 */
void
init_histvec(void)
{
	if (histbase == NULL) {
		histsize = HISTORYSIZE;
		/*
		 * allocate one extra element so that histptr always
		 * lies within array bounds
		 */
		histbase = reallocarray(NULL, histsize + 1, sizeof(char *));
		if (histbase == NULL)
			internal_errorf("allocating history storage: %s",
			    strerror(errno));
		*histbase = NULL;
		history = histbase + 1;
		histptr = history - 1;
	}
}

static void
history_lock(int operation)
{
	while (flock(fileno(histfh), operation) != 0) {
		if (errno == EINTR || errno == EAGAIN)
			continue;
		else
			break;
	}
}

/*
 *	Routines added by Peter Collinson BSDI(Europe)/Hillside Systems to
 *	a) permit HISTSIZE to control number of lines of history stored
 *	b) maintain a physical history file
 *
 *	It turns out that there is a lot of ghastly hackery here
 */


/*
 * save command in history
 */
void
histsave(int lno, const char *cmd, int dowrite)
{
	char		*c, *cp;

	if (ignorespace && cmd[0] == ' ')
		return;

	c = str_save(cmd, APERM);
	if ((cp = strrchr(c, '\n')) != NULL)
		*cp = '\0';

	/*
	 * XXX to properly check for duplicated lines we should first reload
	 * the histfile if needed
	 */
	if (ignoredups && histptr >= history && strcmp(*histptr, c) == 0) {
		afree(c, APERM);
		return;
	}

	if (dowrite && histfh) {
		struct stat	sb;

		history_lock(LOCK_EX);
		if (fstat(fileno(histfh), &sb) != -1) {
			if (timespeccmp(&sb.st_mtim, &last_sb.st_mtim, ==))
				; /* file is unchanged */
			else {
				histreset();
				history_load(hist_source);
			}
		}
	}

	if (histptr < history + histsize - 1)
		histptr++;
	else { /* remove oldest command */
		afree(*history, APERM);
		memmove(history, history + 1,
		    (histsize - 1) * sizeof(*history));
	}
	*histptr = c;

	if (dowrite && histfh) {
		char *encoded;

		/* append to file */
		if (fseeko(histfh, 0, SEEK_END) == 0 &&
		    stravis(&encoded, c, VIS_SAFE | VIS_NL) != -1) {
			fprintf(histfh, "%s\n", encoded);
			fflush(histfh);
			fstat(fileno(histfh), &last_sb);
			line_co++;
			history_write();
			free(encoded);
		}
		history_lock(LOCK_UN);
	}
}

static FILE *
history_open(void)
{
	FILE		*f = NULL;
	struct stat	sb;
	int		fd, fddup;

	if ((fd = open(hname, O_RDWR | O_CREAT | O_EXLOCK, 0600)) == -1)
		return NULL;
	if (fstat(fd, &sb) == -1 || sb.st_uid != getuid()) {
		close(fd);
		return NULL;
	}
	fddup = savefd(fd);
	if (fddup != fd)
		close(fd);

	if ((f = fdopen(fddup, "r+")) == NULL)
		close(fddup);
	else
		last_sb = sb;
	return f;
}

static void
history_close(void)
{
	if (histfh) {
		fflush(histfh);
		fclose(histfh);
		histfh = NULL;
	}
}

static void
history_load(Source *s)
{
	char		*p, encoded[LINE + 1], line[LINE + 1];
	int		 toolongseen = 0;

	rewind(histfh);
	line_co = 1;

	/* just read it all; will auto resize history upon next command */
	while (fgets(encoded, sizeof(encoded), histfh)) {
		if ((p = strchr(encoded, '\n')) == NULL) {
			/* discard overlong line */
			do {
				/* maybe a missing trailing newline? */
				if (strlen(encoded) != sizeof(encoded) - 1) {
					bi_errorf("history file is corrupt");
					return;
				}
			} while (fgets(encoded, sizeof(encoded), histfh)
			    && strchr(encoded, '\n') == NULL);

			if (!toolongseen) {
				toolongseen = 1;
				bi_errorf("ignored history line(s) longer than"
				    " %d bytes", LINE);
			}

			continue;
		}
		*p = '\0';
		s->line = line_co;
		s->cmd_offset = line_co;
		strunvis(line, encoded);
		histsave(line_co, line, 0);
		line_co++;
	}

	history_write();
}

#define HMAGIC1 0xab
#define HMAGIC2 0xcd

void
hist_init(Source *s)
{
	int oldmagic1, oldmagic2;

	if (Flag(FTALKING) == 0)
		return;

	hstarted = 1;

	hist_source = s;

	if (str_val(global("HISTFILE")) == null)
		return;
	hname = str_save(str_val(global("HISTFILE")), APERM);
	histfh = history_open();
	if (histfh == NULL)
		return;

	oldmagic1 = fgetc(histfh);
	oldmagic2 = fgetc(histfh);

	if (oldmagic1 == EOF || oldmagic2 == EOF) {
		if (!feof(histfh) && ferror(histfh)) {
			history_close();
			return;
		}
	} else if (oldmagic1 == HMAGIC1 && oldmagic2 == HMAGIC2) {
		bi_errorf("ignoring old style history file");
		history_close();
		return;
	}

	history_load(s);

	history_lock(LOCK_UN);
}

static void
history_write(void)
{
	char		**hp, *encoded;

	/* see if file has grown over 25% */
	if (line_co < histsize + (histsize / 4))
		return;

	/* rewrite the whole caboodle */
	rewind(histfh);
	if (ftruncate(fileno(histfh), 0) == -1) {
		bi_errorf("failed to rewrite history file - %s",
		    strerror(errno));
	}
	for (hp = history; hp <= histptr; hp++) {
		if (stravis(&encoded, *hp, VIS_SAFE | VIS_NL) != -1) {
			if (fprintf(histfh, "%s\n", encoded) == -1) {
				free(encoded);
				return;
			}
			free(encoded);
		}
	}

	line_co = histsize;

	fflush(histfh);
	fstat(fileno(histfh), &last_sb);
}

void
hist_finish(void)
{
	history_close();
}
