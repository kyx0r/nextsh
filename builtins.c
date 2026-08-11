/*
 * nextsh: the builtin commands.
 *
 * Public domain, except where noted.
 */

/*
 * Bourne shell builtins
 */

/*
 * built-in Bourne commands
 */




static void p_tv(struct shf *, int, struct timeval *, int, char *, char *);
static void p_ts(struct shf *, int, struct timespec *, int, char *, char *);

/* :, false and true */
int
c_label(char **wp)
{
	return wp[0][0] == 'f' ? 1 : 0;
}

int
c_shift(char **wp)
{
	struct block *l = genv->loc;
	int n;
	int64_t val;
	char *arg;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	arg = wp[builtin_opt.optind];

	if (arg) {
		evaluate(arg, &val, KSH_UNWIND_ERROR, false);
		n = val;
	} else
		n = 1;
	if (n < 0) {
		bi_errorf("%s: bad number", arg);
		return (1);
	}
	if (l->argc < n) {
		bi_errorf("nothing to shift");
		return (1);
	}
	l->argv[n] = l->argv[0];
	l->argv += n;
	l->argc -= n;
	return 0;
}

int
c_umask(char **wp)
{
	int i;
	char *cp;
	int symbolic = 0;
	mode_t old_umask;
	int optc;

	while ((optc = ksh_getopt(wp, &builtin_opt, "S")) != -1)
		switch (optc) {
		case 'S':
			symbolic = 1;
			break;
		case '?':
			return 1;
		}
	cp = wp[builtin_opt.optind];
	if (cp == NULL) {
		old_umask = umask(0);
		umask(old_umask);
		if (symbolic) {
			char buf[18];
			int j;

			old_umask = ~old_umask;
			cp = buf;
			for (i = 0; i < 3; i++) {
				*cp++ = "ugo"[i];
				*cp++ = '=';
				for (j = 0; j < 3; j++)
					if (old_umask & (1 << (8 - (3*i + j))))
						*cp++ = "rwx"[j];
				*cp++ = ',';
			}
			cp[-1] = '\0';
			shprintf("%s\n", buf);
		} else
			shprintf("%#3.3o\n", old_umask);
	} else {
		mode_t new_umask;

		if (digit(*cp)) {
			for (new_umask = 0; *cp >= '0' && *cp <= '7'; cp++)
				new_umask = new_umask * 8 + (*cp - '0');
			if (*cp) {
				bi_errorf("bad number");
				return 1;
			}
		} else {
			/* symbolic format */
			int positions, new_val;
			char op;

			old_umask = umask(0);
			umask(old_umask); /* in case of error */
			old_umask = ~old_umask;
			new_umask = old_umask;
			positions = 0;
			while (*cp) {
				while (*cp && strchr("augo", *cp))
					switch (*cp++) {
					case 'a':
						positions |= 0111;
						break;
					case 'u':
						positions |= 0100;
						break;
					case 'g':
						positions |= 0010;
						break;
					case 'o':
						positions |= 0001;
						break;
					}
				if (!positions)
					positions = 0111; /* default is a */
				if (!strchr("=+-", op = *cp))
					break;
				cp++;
				new_val = 0;
				while (*cp && strchr("rwxugoXs", *cp))
					switch (*cp++) {
					case 'r': new_val |= 04; break;
					case 'w': new_val |= 02; break;
					case 'x': new_val |= 01; break;
					case 'u': new_val |= old_umask >> 6;
						  break;
					case 'g': new_val |= old_umask >> 3;
						  break;
					case 'o': new_val |= old_umask >> 0;
						  break;
					case 'X': if (old_umask & 0111)
							new_val |= 01;
						  break;
					case 's': /* ignored */
						  break;
					}
				new_val = (new_val & 07) * positions;
				switch (op) {
				case '-':
					new_umask &= ~new_val;
					break;
				case '=':
					new_umask = new_val |
					    (new_umask & ~(positions * 07));
					break;
				case '+':
					new_umask |= new_val;
				}
				if (*cp == ',') {
					positions = 0;
					cp++;
				} else if (!strchr("=+-", *cp))
					break;
			}
			if (*cp) {
				bi_errorf("bad mask");
				return 1;
			}
			new_umask = ~new_umask;
		}
		umask(new_umask);
	}
	return 0;
}

int
c_dot(char **wp)
{
	char *file, *cp;
	char **argv;
	int argc;
	int i;
	int err;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;

	if ((cp = wp[builtin_opt.optind]) == NULL)
		return 0;
	file = search(cp, search_path, R_OK, &err);
	if (file == NULL) {
		bi_errorf("%s: %s", cp, err ? strerror(err) : "not found");
		return 1;
	}

	/* Set positional parameters? */
	if (wp[builtin_opt.optind + 1]) {
		argv = wp + builtin_opt.optind;
		argv[0] = genv->loc->argv[0]; /* preserve $0 */
		for (argc = 0; argv[argc + 1]; argc++)
			;
	} else {
		argc = 0;
		argv = NULL;
	}
	i = include(file, argc, argv, 0);
	if (i < 0) { /* should not happen */
		bi_errorf("%s: %s", cp, strerror(errno));
		return 1;
	}
	return i;
}

int
c_wait(char **wp)
{
	int rv = 0;
	int sig;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	wp += builtin_opt.optind;
	if (*wp == NULL) {
		while (j_waitfor(NULL, &sig) >= 0)
			;
		rv = sig;
	} else {
		for (; *wp; wp++)
			rv = j_waitfor(*wp, &sig);
		if (rv < 0)
			rv = sig ? sig : 127; /* magic exit code: bad job-id */
	}
	return rv;
}

int
c_read(char **wp)
{
	int c = 0;
	int expand = 1, savehist = 0;
	int expanding;
	int ecode = 0;
	char *cp;
	int fd = 0;
	struct shf *shf;
	int optc;
	const char *emsg;
	/* xs is only set up when savehist is set */
	XString cs, xs = { NULL, NULL, 0, NULL };
	struct tbl *vp;
	char *xp = NULL;

	while ((optc = ksh_getopt(wp, &builtin_opt, "prsu,")) != -1)
		switch (optc) {
		case 'p':
			if ((fd = coproc_getfd(R_OK, &emsg)) < 0) {
				bi_errorf("-p: %s", emsg);
				return 1;
			}
			break;
		case 'r':
			expand = 0;
			break;
		case 's':
			savehist = 1;
			break;
		case 'u':
			if (!*(cp = builtin_opt.optarg))
				fd = 0;
			else if ((fd = check_fd(cp, R_OK, &emsg)) < 0) {
				bi_errorf("-u: %s: %s", cp, emsg);
				return 1;
			}
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	if (*wp == NULL)
		*--wp = "REPLY";

	/* Since we can't necessarily seek backwards on non-regular files,
	 * don't buffer them so we can't read too much.
	 */
	shf = shf_reopen(fd, SHF_RD | SHF_INTERRUPT | can_seek(fd), shl_spare);

	if ((cp = strchr(*wp, '?')) != NULL) {
		*cp = 0;
		if (isatty(fd)) {
			/* at&t ksh says it prints prompt on fd if it's open
			 * for writing and is a tty, but it doesn't do it
			 * (it also doesn't check the interactive flag,
			 * as is indicated in the Kornshell book).
			 */
			shellf("%s", cp+1);
		}
	}

	/* If we are reading from the co-process for the first time,
	 * make sure the other side of the pipe is closed first.  This allows
	 * the detection of eof.
	 *
	 * This is not compatible with at&t ksh... the fd is kept so another
	 * coproc can be started with same output, however, this means eof
	 * can't be detected...  This is why it is closed here.
	 * If this call is removed, remove the eof check below, too.
	 * coproc_readw_close(fd);
	 */

	if (savehist)
		Xinit(xs, xp, 128, ATEMP);
	expanding = 0;
	Xinit(cs, cp, 128, ATEMP);
	for (; *wp != NULL; wp++) {
		for (cp = Xstring(cs, cp); ; ) {
			if (c == '\n' || c == EOF)
				break;
			while (1) {
				c = shf_getc(shf);
				if (c == '\0')
					continue;
				if (c == EOF && shf_error(shf) &&
				    shf->errno_ == EINTR) {
					/* Was the offending signal one that
					 * would normally kill a process?
					 * If so, pretend the read was killed.
					 */
					ecode = fatal_trap_check();

					/* non fatal (eg, CHLD), carry on */
					if (!ecode) {
						shf_clearerr(shf);
						continue;
					}
				}
				break;
			}
			if (savehist) {
				Xcheck(xs, xp);
				Xput(xs, xp, c);
			}
			Xcheck(cs, cp);
			if (expanding) {
				expanding = 0;
				if (c == '\n') {
					c = 0;
					if (Flag(FTALKING_I) && isatty(fd)) {
						/* set prompt in case this is
						 * called from .profile or $ENV
						 */
						set_prompt(PS2);
						pprompt(prompt, 0);
					}
				} else if (c != EOF)
					Xput(cs, cp, c);
				continue;
			}
			if (expand && c == '\\') {
				expanding = 1;
				continue;
			}
			if (c == '\n' || c == EOF)
				break;
			if (ctype(c, C_IFS)) {
				if (Xlength(cs, cp) == 0 && ctype(c, C_IFSWS))
					continue;
				if (wp[1])
					break;
			}
			Xput(cs, cp, c);
		}
		/* strip trailing IFS white space from last variable */
		if (!wp[1])
			while (Xlength(cs, cp) && ctype(cp[-1], C_IFS) &&
			    ctype(cp[-1], C_IFSWS))
				cp--;
		Xput(cs, cp, '\0');
		vp = global(*wp);
		/* Must be done before setting export. */
		if (vp->flag & RDONLY) {
			shf_flush(shf);
			bi_errorf("%s is read only", *wp);
			return 1;
		}
		if (Flag(FEXPORT))
			typeset(*wp, EXPORT, 0, 0, 0);
		if (!setstr(vp, Xstring(cs, cp), KSH_RETURN_ERROR)) {
		    shf_flush(shf);
		    return 1;
		}
	}

	shf_flush(shf);
	if (savehist) {
		Xput(xs, xp, '\0');
		source->line++;
		histsave(source->line, Xstring(xs, xp), 1);
		Xfree(xs, xp);
	}
	/* if this is the co-process fd, close the file descriptor
	 * (can get eof if and only if all processes are have died, ie,
	 * coproc.njobs is 0 and the pipe is closed).
	 */
	if (c == EOF && !ecode)
		coproc_read_close(fd);

	return ecode ? ecode : c == EOF;
}

int
c_eval(char **wp)
{
	struct source *s;
	struct source *saves = source;
	int savef;
	int rv;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	s = pushs(SWORDS, ATEMP);
	s->u.strv = wp + builtin_opt.optind;
	if (!Flag(FPOSIX)) {
		/*
		 * Handle case where the command is empty due to failed
		 * command substitution, eg, eval "$(false)".
		 * In this case, shell() will not set/change exstat (because
		 * compiled tree is empty), so will use this value.
		 * subst_exstat is cleared in execute(), so should be 0 if
		 * there were no substitutions.
		 *
		 * A strict reading of POSIX says we don't do this (though
		 * it is traditionally done). [from 1003.2-1992]
		 *    3.9.1: Simple Commands
		 *	... If there is a command name, execution shall
		 *	continue as described in 3.9.1.1.  If there
		 *	is no command name, but the command contained a command
		 *	substitution, the command shall complete with the exit
		 *	status of the last command substitution
		 *    3.9.1.1: Command Search and Execution
		 *	...(1)...(a) If the command name matches the name of
		 *	a special built-in utility, that special built-in
		 *	utility shall be invoked.
		 * 3.14.5: Eval
		 *	... If there are no arguments, or only null arguments,
		 *	eval shall return an exit status of zero.
		 */
		exstat = subst_exstat;
	}

	savef = Flag(FERREXIT);
	Flag(FERREXIT) = 0;
	rv = shell(s, false);
	Flag(FERREXIT) = savef;
	source = saves;
	afree(s, ATEMP);
	return (rv);
}

int
c_trap(char **wp)
{
	int i;
	char *s;
	Trap *p;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	wp += builtin_opt.optind;

	if (*wp == NULL) {
		for (p = sigtraps, i = NSIG+1; --i >= 0; p++) {
			if (p->trap != NULL) {
				shprintf("trap -- ");
				print_value_quoted(p->trap);
				shprintf(" %s\n", p->name);
			}
		}
		return 0;
	}

	/*
	 * Use case sensitive lookup for first arg so the
	 * command 'exit' isn't confused with the pseudo-signal
	 * 'EXIT'.
	 */
	s = (gettrap(*wp, false) == NULL) ? *wp++ : NULL; /* get command */
	if (s != NULL && s[0] == '-' && s[1] == '\0')
		s = NULL;

	/* set/clear traps */
	while (*wp != NULL) {
		p = gettrap(*wp++, true);
		if (p == NULL) {
			bi_errorf("bad signal %s", wp[-1]);
			return 1;
		}
		settrap(p, s);
	}
	return 0;
}

int
c_exitreturn(char **wp)
{
	int how = LEXIT;
	int n;
	char *arg;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	arg = wp[builtin_opt.optind];

	if (arg) {
		if (!getn(arg, &n)) {
			exstat = 1;
			warningf(true, "%s: bad number", arg);
		} else
			exstat = n;
	}
	if (wp[0][0] == 'r') { /* return */
		struct env *ep;

		/* need to tell if this is exit or return so trap exit will
		 * work right (POSIX)
		 */
		for (ep = genv; ep; ep = ep->oenv)
			if (STOP_RETURN(ep->type)) {
				how = LRETURN;
				break;
			}
	}

	if (how == LEXIT && !really_exit && j_stopped_running()) {
		really_exit = 1;
		how = LSHELL;
	}

	quitenv(NULL);	/* get rid of any i/o redirections */
	unwind(how);
	/* NOTREACHED */
	return 0;
}

int
c_brkcont(char **wp)
{
	int n, quit;
	struct env *ep, *last_ep = NULL;
	char *arg;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	arg = wp[builtin_opt.optind];

	if (!arg)
		n = 1;
	else if (!bi_getn(arg, &n))
		return 1;
	quit = n;
	if (quit <= 0) {
		/* at&t ksh does this for non-interactive shells only - weird */
		bi_errorf("%s: bad value", arg);
		return 1;
	}

	/* Stop at E_NONE, E_PARSE, E_FUNC, or E_INCL */
	for (ep = genv; ep && !STOP_BRKCONT(ep->type); ep = ep->oenv)
		if (ep->type == E_LOOP) {
			if (--quit == 0)
				break;
			ep->flags |= EF_BRKCONT_PASS;
			last_ep = ep;
		}

	if (quit) {
		/* at&t ksh doesn't print a message - just does what it
		 * can.  We print a message 'cause it helps in debugging
		 * scripts, but don't generate an error (ie, keep going).
		 */
		if (n == quit) {
			warningf(true, "%s: cannot %s", wp[0], wp[0]);
			return 0;
		}
		/* POSIX says if n is too big, the last enclosing loop
		 * shall be used.  Doesn't say to print an error but we
		 * do anyway 'cause the user messed up.
		 */
		if (last_ep)
			last_ep->flags &= ~EF_BRKCONT_PASS;
		warningf(true, "%s: can only %s %d level(s)",
		    wp[0], wp[0], n - quit);
	}

	unwind(*wp[0] == 'b' ? LBREAK : LCONTIN);
	/* NOTREACHED */
}

int
c_set(char **wp)
{
	int argi, setargs;
	struct block *l = genv->loc;
	char **owp = wp;

	if (wp[1] == NULL) {
		static const char *const args [] = { "set", "-", NULL };
		return c_typeset((char **) args);
	}

	argi = parse_args(wp, OF_SET, &setargs);
	if (argi < 0)
		return 1;
	/* set $# and $* */
	if (setargs) {
		owp = wp += argi - 1;
		wp[0] = l->argv[0]; /* save $0 */
		while (*++wp != NULL)
			*wp = str_save(*wp, &l->area);
		l->argc = wp - owp - 1;
		l->argv = areallocarray(NULL, l->argc+2, sizeof(char *), &l->area);
		for (wp = l->argv; (*wp++ = *owp++) != NULL; )
			;
	}
	/* POSIX says set exit status is 0, but old scripts that use
	 * getopt(1), use the construct: set -- `getopt ab:c "$@"`
	 * which assumes the exit value set will be that of the ``
	 * (subst_exstat is cleared in execute() so that it will be 0
	 * if there are no command substitutions).
	 */
	return Flag(FPOSIX) ? 0 : subst_exstat;
}

int
c_unset(char **wp)
{
	char *id;
	int optc, unset_var = 1;

	while ((optc = ksh_getopt(wp, &builtin_opt, "fv")) != -1)
		switch (optc) {
		case 'f':
			unset_var = 0;
			break;
		case 'v':
			unset_var = 1;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;
	for (; (id = *wp) != NULL; wp++)
		if (unset_var) {	/* unset variable */
			struct tbl *vp = global(id);

			if ((vp->flag&RDONLY)) {
				bi_errorf("%s is read only", vp->name);
				return 1;
			}
			unset(vp, strchr(id, '[') ? 1 : 0);
		} else {		/* unset function */
			define(id, NULL);
		}
	return 0;
}

#ifndef TIMEVAL_TO_TIMESPEC
#define TIMEVAL_TO_TIMESPEC(tv, ts) do {				\
	(ts)->tv_sec = (tv)->tv_sec;					\
	(ts)->tv_nsec = (tv)->tv_usec * 1000;				\
} while (0)
#endif

static void
p_tv(struct shf *shf, int posix, struct timeval *tv, int width, char *prefix,
    char *suffix)
{
	struct timespec ts;

	TIMEVAL_TO_TIMESPEC(tv, &ts);
	p_ts(shf, posix, &ts, width, prefix, suffix);
}

static void
p_ts(struct shf *shf, int posix, struct timespec *ts, int width, char *prefix,
    char *suffix)
{
	if (posix)
		shf_fprintf(shf, "%s%*lld.%02ld%s", prefix ? prefix : "",
		    width, (long long)ts->tv_sec, ts->tv_nsec / 10000000,
		    suffix);
	else
		shf_fprintf(shf, "%s%*lldm%02lld.%02lds%s", prefix ? prefix : "",
		    width, (long long)ts->tv_sec / 60,
		    (long long)ts->tv_sec % 60,
		    ts->tv_nsec / 10000000, suffix);
}


int
c_times(char **wp)
{
	struct rusage usage;

	(void) getrusage(RUSAGE_SELF, &usage);
	p_tv(shl_stdout, 0, &usage.ru_utime, 0, NULL, " ");
	p_tv(shl_stdout, 0, &usage.ru_stime, 0, NULL, "\n");

	(void) getrusage(RUSAGE_CHILDREN, &usage);
	p_tv(shl_stdout, 0, &usage.ru_utime, 0, NULL, " ");
	p_tv(shl_stdout, 0, &usage.ru_stime, 0, NULL, "\n");

	return 0;
}

/*
 * time pipeline (really a statement, not a built-in command)
 */
int
timex(struct op *t, int f, volatile int *xerrok)
{
#define TF_NOARGS	BIT(0)
#define TF_NOREAL	BIT(1)		/* don't report real time */
#define TF_POSIX	BIT(2)		/* report in posix format */
	int rv = 0;
	struct rusage ru0, ru1, cru0, cru1;
	struct timeval usrtime, systime;
	struct timespec ts0, ts1, ts2;
	int tf = 0;
	extern struct timeval j_usrtime, j_systime; /* computed by j_wait */

	clock_gettime(CLOCK_MONOTONIC, &ts0);
	getrusage(RUSAGE_SELF, &ru0);
	getrusage(RUSAGE_CHILDREN, &cru0);
	if (t->left) {
		/*
		 * Two ways of getting cpu usage of a command: just use t0
		 * and t1 (which will get cpu usage from other jobs that
		 * finish while we are executing t->left), or get the
		 * cpu usage of t->left. at&t ksh does the former, while
		 * pdksh tries to do the later (the j_usrtime hack doesn't
		 * really work as it only counts the last job).
		 */
		timerclear(&j_usrtime);
		timerclear(&j_systime);
		rv = execute(t->left, f | XTIME, xerrok);
		if (t->left->type == TCOM)
			tf |= t->left->str[0];
		clock_gettime(CLOCK_MONOTONIC, &ts1);
		getrusage(RUSAGE_SELF, &ru1);
		getrusage(RUSAGE_CHILDREN, &cru1);
	} else
		tf = TF_NOARGS;

	if (tf & TF_NOARGS) { /* ksh93 - report shell times (shell+kids) */
		tf |= TF_NOREAL;
		timeradd(&ru0.ru_utime, &cru0.ru_utime, &usrtime);
		timeradd(&ru0.ru_stime, &cru0.ru_stime, &systime);
	} else {
		timersub(&ru1.ru_utime, &ru0.ru_utime, &usrtime);
		timeradd(&usrtime, &j_usrtime, &usrtime);
		timersub(&ru1.ru_stime, &ru0.ru_stime, &systime);
		timeradd(&systime, &j_systime, &systime);
	}

	if (!(tf & TF_NOREAL)) {
		timespecsub(&ts1, &ts0, &ts2);
		if (tf & TF_POSIX)
			p_ts(shl_out, 1, &ts2, 5, "real ", "\n");
		else
			p_ts(shl_out, 0, &ts2, 5, NULL, " real ");
	}
	if (tf & TF_POSIX)
		p_tv(shl_out, 1, &usrtime, 5, "user ", "\n");
	else
		p_tv(shl_out, 0, &usrtime, 5, NULL, " user ");
	if (tf & TF_POSIX)
		p_tv(shl_out, 1, &systime, 5, "sys  ", "\n");
	else
		p_tv(shl_out, 0, &systime, 5, NULL, " system\n");
	shf_flush(shl_out);

	return rv;
}

void
timex_hook(struct op *t, char **volatile *app)
{
	char **wp = *app;
	int optc;
	int i, j;
	Getopt opt;

	ksh_getopt_reset(&opt, 0);
	opt.optind = 0;	/* start at the start */
	while ((optc = ksh_getopt(wp, &opt, ":p")) != -1)
		switch (optc) {
		case 'p':
			t->str[0] |= TF_POSIX;
			break;
		case '?':
			errorf("time: -%s unknown option", opt.optarg);
		case ':':
			errorf("time: -%s requires an argument",
			    opt.optarg);
		}
	/* Copy command words down over options. */
	if (opt.optind != 0) {
		for (i = 0; i < opt.optind; i++)
			afree(wp[i], ATEMP);
		for (i = 0, j = opt.optind; (wp[i] = wp[j]); i++, j++)
			;
	}
	if (!wp[0])
		t->str[0] |= TF_NOARGS;
	*app = wp;
}

/* exec with no args - args case is taken care of in comexec() */
int
c_exec(char **wp)
{
	int i;

	/* make sure redirects stay in place */
	if (genv->savefd != NULL) {
		for (i = 0; i < NUFILE; i++) {
			if (genv->savefd[i] > 0)
				close(genv->savefd[i]);
			/*
			 * Keep anything > 2 private.  POSIX leaves
			 * this unspecified; the Bourne shell left
			 * them open.
			 */
			if (i > 2 && genv->savefd[i])
				fcntl(i, F_SETFD, FD_CLOEXEC);
		}
		genv->savefd = NULL;
	}
	return 0;
}

static int
c_suspend(char **wp)
{
	if (wp[1] != NULL) {
		bi_errorf("too many arguments");
		return 1;
	}
	if (Flag(FLOGIN)) {
		/* Can't suspend an orphaned process group. */
		pid_t parent = getppid();
		if (getpgid(parent) == getpgid(0) ||
		    getsid(parent) != getsid(0)) {
			bi_errorf("can't suspend a login shell");
			return 1;
		}
	}
	j_suspend();
	return 0;
}

/* dummy function, special case in comexec() */
int
c_builtin(char **wp)
{
	return 0;
}

extern	int c_test(char **wp);			/* in c_test.c */
extern	int c_ulimit(char **wp);		/* in c_ulimit.c */

/* A leading = means assignments before command are kept;
 * a leading * means a POSIX special builtin;
 * a leading + means a POSIX regular builtin
 * (* and + should not be combined).
 */
const struct builtin shbuiltins [] = {
	{"*=.", c_dot},
	{"*=:", c_label},
	{"[", c_test},
	{"*=break", c_brkcont},
	{"=builtin", c_builtin},
	{"*=continue", c_brkcont},
	{"*=eval", c_eval},
	{"*=exec", c_exec},
	{"*=exit", c_exitreturn},
	{"+false", c_label},
	{"*=return", c_exitreturn},
	{"*=set", c_set},
	{"*=shift", c_shift},
	{"*=times", c_times},
	{"*=trap", c_trap},
	{"+=wait", c_wait},
	{"+read", c_read},
	{"test", c_test},
	{"+true", c_label},
	{"ulimit", c_ulimit},
	{"+umask", c_umask},
	{"*=unset", c_unset},
	{"suspend", c_suspend},
	{NULL, NULL}
};

/*
 * Korn shell builtins
 */

/*
 * built-in Korn commands: c_*
 */




int
c_cd(char **wp)
{
	int optc;
	int physical = Flag(FPHYSICAL);
	int cdnode;			/* was a node from cdpath added in? */
	int printpath = 0;		/* print where we cd'd? */
	int rval;
	struct tbl *pwd_s, *oldpwd_s;
	XString xs;
	char *dir, *try, *pwd;
	int phys_path;
	char *cdpath;
	char *fdir = NULL;

	while ((optc = ksh_getopt(wp, &builtin_opt, "LP")) != -1)
		switch (optc) {
		case 'L':
			physical = 0;
			break;
		case 'P':
			physical = 1;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	if (Flag(FRESTRICTED)) {
		bi_errorf("restricted shell - can't cd");
		return 1;
	}

	pwd_s = global("PWD");
	oldpwd_s = global("OLDPWD");

	if (!wp[0]) {
		/* No arguments - go home */
		if ((dir = str_val(global("HOME"))) == null) {
			bi_errorf("no home directory (HOME not set)");
			return 1;
		}
	} else if (!wp[1]) {
		/* One argument: - or dir */
		dir = wp[0];
		if (strcmp(dir, "-") == 0) {
			dir = str_val(oldpwd_s);
			if (dir == null) {
				bi_errorf("no OLDPWD");
				return 1;
			}
			printpath++;
		}
	} else if (!wp[2]) {
		/* Two arguments - substitute arg1 in PWD for arg2 */
		int ilen, olen, nlen, elen;
		char *cp;

		if (!current_wd[0]) {
			bi_errorf("don't know current directory");
			return 1;
		}
		/* substitute arg1 for arg2 in current path.
		 * if the first substitution fails because the cd fails
		 * we could try to find another substitution. For now
		 * we don't
		 */
		if ((cp = strstr(current_wd, wp[0])) == NULL) {
			bi_errorf("bad substitution");
			return 1;
		}
		ilen = cp - current_wd;
		olen = strlen(wp[0]);
		nlen = strlen(wp[1]);
		elen = strlen(current_wd + ilen + olen) + 1;
		fdir = dir = alloc(ilen + nlen + elen, ATEMP);
		memcpy(dir, current_wd, ilen);
		memcpy(dir + ilen, wp[1], nlen);
		memcpy(dir + ilen + nlen, current_wd + ilen + olen, elen);
		printpath++;
	} else {
		bi_errorf("too many arguments");
		return 1;
	}

	Xinitn(xs, PATH_MAX, ATEMP);

	cdpath = str_val(global("CDPATH"));
	do {
		cdnode = make_path(current_wd, dir, &cdpath, &xs, &phys_path);
		if (physical)
			rval = chdir(try = Xstr(xs) + phys_path);
		else {
			simplify_path(Xstr(xs));
			rval = chdir(try = Xstr(xs));
		}
	} while (rval == -1 && cdpath != NULL);

	if (rval == -1) {
		if (cdnode)
			bi_errorf("%s: bad directory", dir);
		else
			bi_errorf("%s - %s", try, strerror(errno));
		afree(fdir, ATEMP);
		return 1;
	}

	/* Clear out tracked aliases with relative paths */
	flushcom(0);

	/* Set OLDPWD (note: unsetting OLDPWD does not disable this
	 * setting in at&t ksh)
	 */
	if (current_wd[0])
		/* Ignore failure (happens if readonly or integer) */
		setstr(oldpwd_s, current_wd, KSH_RETURN_ERROR);

	if (Xstr(xs)[0] != '/') {
		pwd = NULL;
	} else
	if (!physical || !(pwd = get_phys_path(Xstr(xs))))
		pwd = Xstr(xs);

	/* Set PWD */
	if (pwd) {
		char *ptmp = pwd;
		set_current_wd(ptmp);
		/* Ignore failure (happens if readonly or integer) */
		setstr(pwd_s, ptmp, KSH_RETURN_ERROR);
	} else {
		set_current_wd(null);
		pwd = Xstr(xs);
		/* XXX unset $PWD? */
	}
	if (printpath || cdnode)
		shprintf("%s\n", pwd);

	afree(fdir, ATEMP);

	return 0;
}

int
c_pwd(char **wp)
{
	int optc;
	int physical = Flag(FPHYSICAL);
	char *p, *freep = NULL;

	while ((optc = ksh_getopt(wp, &builtin_opt, "LP")) != -1)
		switch (optc) {
		case 'L':
			physical = 0;
			break;
		case 'P':
			physical = 1;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	if (wp[0]) {
		bi_errorf("too many arguments");
		return 1;
	}
	p = current_wd[0] ? (physical ? get_phys_path(current_wd) : current_wd) :
	    NULL;
	if (p && access(p, R_OK) == -1)
		p = NULL;
	if (!p) {
		freep = p = ksh_get_wd(NULL, 0);
		if (!p) {
			bi_errorf("can't get current directory - %s",
			    strerror(errno));
			return 1;
		}
	}
	shprintf("%s\n", p);
	afree(freep, ATEMP);
	return 0;
}

int
c_print(char **wp)
{
#define PO_NL		BIT(0)	/* print newline */
#define PO_EXPAND	BIT(1)	/* expand backslash sequences */
#define PO_PMINUSMINUS	BIT(2)	/* print a -- argument */
#define PO_HIST		BIT(3)	/* print to history instead of stdout */
#define PO_COPROC	BIT(4)	/* printing to coprocess: block SIGPIPE */
	int fd = 1;
	int flags = PO_EXPAND|PO_NL;
	char *s;
	const char *emsg;
	XString xs;
	char *xp;

	if (wp[0][0] == 'e') {	/* echo command */
		int nflags = flags;

		/* A compromise between sysV and BSD echo commands:
		 * escape sequences are enabled by default, and
		 * -n, -e and -E are recognized if they appear
		 * in arguments with no illegal options (ie, echo -nq
		 * will print -nq).
		 * Different from sysV echo since options are recognized,
		 * different from BSD echo since escape sequences are enabled
		 * by default.
		 */
		wp += 1;
		if (Flag(FPOSIX)) {
			if (*wp && strcmp(*wp, "-n") == 0) {
				flags &= ~PO_NL;
				wp++;
			}
		} else {
			while ((s = *wp) && *s == '-' && s[1]) {
				while (*++s)
					if (*s == 'n')
						nflags &= ~PO_NL;
					else if (*s == 'e')
						nflags |= PO_EXPAND;
					else if (*s == 'E')
						nflags &= ~PO_EXPAND;
					else
						/* bad option: don't use
						 * nflags, print argument
						 */
						break;
				if (*s)
					break;
				wp++;
				flags = nflags;
			}
		}
	} else {
		int optc;
		const char *options = "Rnprsu,";
		while ((optc = ksh_getopt(wp, &builtin_opt, options)) != -1)
			switch (optc) {
			case 'R': /* fake BSD echo command */
				flags |= PO_PMINUSMINUS;
				flags &= ~PO_EXPAND;
				options = "ne";
				break;
			case 'e':
				flags |= PO_EXPAND;
				break;
			case 'n':
				flags &= ~PO_NL;
				break;
			case 'p':
				if ((fd = coproc_getfd(W_OK, &emsg)) < 0) {
					bi_errorf("-p: %s", emsg);
					return 1;
				}
				break;
			case 'r':
				flags &= ~PO_EXPAND;
				break;
			case 's':
				flags |= PO_HIST;
				break;
			case 'u':
				if (!*(s = builtin_opt.optarg))
					fd = 0;
				else if ((fd = check_fd(s, W_OK, &emsg)) < 0) {
					bi_errorf("-u: %s: %s", s, emsg);
					return 1;
				}
				break;
			case '?':
				return 1;
			}
		if (!(builtin_opt.info & GI_MINUSMINUS)) {
			/* treat a lone - like -- */
			if (wp[builtin_opt.optind] &&
			    strcmp(wp[builtin_opt.optind], "-") == 0)
				builtin_opt.optind++;
		} else if (flags & PO_PMINUSMINUS)
			builtin_opt.optind--;
		wp += builtin_opt.optind;
	}

	Xinit(xs, xp, 128, ATEMP);

	while (*wp != NULL) {
		int c;
		s = *wp;
		while ((c = *s++) != '\0') {
			Xcheck(xs, xp);
			if ((flags & PO_EXPAND) && c == '\\') {
				int i;

				switch ((c = *s++)) {
				/* Oddly enough, \007 seems more portable than
				 * \a (due to HP-UX cc, Ultrix cc, old pcc's,
				 * etc.).
				 */
				case 'a': c = '\007'; break;
				case 'b': c = '\b'; break;
				case 'c': flags &= ~PO_NL;
					  continue; /* AT&T brain damage */
				case 'f': c = '\f'; break;
				case 'n': c = '\n'; break;
				case 'r': c = '\r'; break;
				case 't': c = '\t'; break;
				case 'v': c = 0x0B; break;
				case '0':
					/* Look for an octal number: can have
					 * three digits (not counting the
					 * leading 0).  Truly burnt.
					 */
					c = 0;
					for (i = 0; i < 3; i++) {
						if (*s >= '0' && *s <= '7')
							c = c*8 + *s++ - '0';
						else
							break;
					}
					break;
				case '\0': s--; c = '\\'; break;
				case '\\': break;
				default:
					Xput(xs, xp, '\\');
				}
			}
			Xput(xs, xp, c);
		}
		if (*++wp != NULL)
			Xput(xs, xp, ' ');
	}
	if (flags & PO_NL)
		Xput(xs, xp, '\n');

	if (flags & PO_HIST) {
		Xput(xs, xp, '\0');
		source->line++;
		histsave(source->line, Xstring(xs, xp), 1);
		Xfree(xs, xp);
	} else {
		int n, len = Xlength(xs, xp);
		int opipe = 0;

		/* Ensure we aren't killed by a SIGPIPE while writing to
		 * a coprocess.  at&t ksh doesn't seem to do this (seems
		 * to just check that the co-process is alive, which is
		 * not enough).
		 */
		if (coproc.write >= 0 && coproc.write == fd) {
			flags |= PO_COPROC;
			opipe = block_pipe();
		}
		for (s = Xstring(xs, xp); len > 0; ) {
			n = write(fd, s, len);
			if (n == -1) {
				if (flags & PO_COPROC)
					restore_pipe(opipe);
				if (errno == EINTR) {
					/* allow user to ^C out */
					intrcheck();
					if (flags & PO_COPROC)
						opipe = block_pipe();
					continue;
				}
				/* This doesn't really make sense - could
				 * break scripts (print -p generates
				 * error message).
				*if (errno == EPIPE)
				*	coproc_write_close(fd);
				 */
				return 1;
			}
			s += n;
			len -= n;
		}
		if (flags & PO_COPROC)
			restore_pipe(opipe);
	}

	return 0;
}

int
c_whence(char **wp)
{
	struct tbl *tp;
	char *id;
	int pflag = 0, vflag = 0, Vflag = 0;
	int ret = 0;
	int optc;
	int iam_whence;
	int fcflags;
	const char *options;

	switch (wp[0][0]) {
	case 'c': /* command */
		iam_whence = 0;
		options = "pvV";
		break;
	case 't': /* type */
		vflag = 1;
		/* FALLTHROUGH */
	case 'w': /* whence */
		iam_whence = 1;
		options = "pv";
		break;
	default:
		bi_errorf("builtin not handled by %s", __func__);
		return 1;
	}

	while ((optc = ksh_getopt(wp, &builtin_opt, options)) != -1)
		switch (optc) {
		case 'p':
			pflag = 1;
			break;
		case 'v':
			vflag = 1;
			break;
		case 'V':
			Vflag = 1;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	fcflags = FC_BI | FC_PATH | FC_FUNC;
	if (!iam_whence) {
		/* Note that -p on its own is dealt with in comexec() */
		if (pflag)
			fcflags |= FC_DEFPATH;
		/* Convert command options to whence options.  Note that
		 * command -pV and command -pv use a different path search
		 * than whence -v or whence -pv.  This should be considered
		 * a feature.
		 */
		vflag = Vflag;
	} else if (pflag)
		fcflags &= ~(FC_BI | FC_FUNC);

	while ((vflag || ret == 0) && (id = *wp++) != NULL) {
		tp = NULL;
		if (!iam_whence || !pflag)
			tp = ktsearch(&keywords, id, hash(id));
		if (!tp && (!iam_whence || !pflag)) {
			tp = ktsearch(&aliases, id, hash(id));
			if (tp && !(tp->flag & ISSET))
				tp = NULL;
		}
		if (!tp)
			tp = findcom(id, fcflags);
		if (vflag || (tp->type != CALIAS && tp->type != CEXEC &&
		    tp->type != CTALIAS))
			shprintf("%s", id);
		switch (tp->type) {
		case CKEYWD:
			if (vflag)
				shprintf(" is a reserved word");
			break;
		case CALIAS:
			if (vflag)
				shprintf(" is an %salias for ",
				    (tp->flag & EXPORT) ? "exported " : "");
			if (!iam_whence && !vflag)
				shprintf("alias %s=", id);
			print_value_quoted(tp->val.s);
			break;
		case CFUNC:
			if (vflag) {
				shprintf(" is a");
				if (tp->flag & EXPORT)
					shprintf("n exported");
				if (tp->flag & TRACE)
					shprintf(" traced");
				if (!(tp->flag & ISSET)) {
					shprintf(" undefined");
					if (tp->u.fpath)
						shprintf(" (autoload from %s)",
						    tp->u.fpath);
				}
				shprintf(" function");
			}
			break;
		case CSHELL:
			if (vflag)
				shprintf(" is a%s shell builtin",
				    (tp->flag & SPEC_BI) ? " special" : "");
			break;
		case CTALIAS:
		case CEXEC:
			if (tp->flag & ISSET) {
				if (vflag) {
					shprintf(" is ");
					if (tp->type == CTALIAS)
						shprintf("a tracked %salias for ",
						    (tp->flag & EXPORT) ?
						    "exported " : "");
				}
				shprintf("%s", tp->val.s);
			} else {
				if (vflag)
					shprintf(" not found");
				ret = 1;
			}
			break;
		default:
			shprintf("%s is *GOK*", id);
			break;
		}
		if (vflag || !ret)
			shprintf("\n");
	}
	return ret;
}

/* Deal with command -vV - command -p dealt with in comexec() */
int
c_command(char **wp)
{
	/* Let c_whence do the work.  Note that c_command() must be
	 * a distinct function from c_whence() (tested in comexec()).
	 */
	return c_whence(wp);
}

int
c_type(char **wp)
{
	/* Let c_whence do the work. type = command -V = whence -v */
	return c_whence(wp);
}

/* typeset, export, and readonly */
int
c_typeset(char **wp)
{
	struct block *l;
	struct tbl *vp, **p;
	int fset = 0, fclr = 0, thing = 0, func = 0, local = 0, pflag = 0;
	const char *options = "L#R#UZ#fi#lprtux";	/* see comment below */
	char *fieldstr, *basestr;
	int field, base, optc, flag;

	switch (**wp) {
	case 'e':		/* export */
		fset |= EXPORT;
		options = "p";
		break;
	case 'r':		/* readonly */
		fset |= RDONLY;
		options = "p";
		break;
	case 's':		/* set */
		/* called with 'typeset -' */
		break;
	case 't':		/* typeset */
		local = 1;
		break;
	}

	fieldstr = basestr = NULL;
	builtin_opt.flags |= GF_PLUSOPT;
	/* at&t ksh seems to have 0-9 as options, which are multiplied
	 * to get a number that is used with -L, -R, -Z or -i (eg, -1R2
	 * sets right justify in a field of 12).  This allows options
	 * to be grouped in an order (eg, -Lu12), but disallows -i8 -L3 and
	 * does not allow the number to be specified as a separate argument
	 * Here, the number must follow the RLZi option, but is optional
	 * (see the # kludge in ksh_getopt()).
	 */
	while ((optc = ksh_getopt(wp, &builtin_opt, options)) != -1) {
		flag = 0;
		switch (optc) {
		case 'L':
			flag = LJUST;
			fieldstr = builtin_opt.optarg;
			break;
		case 'R':
			flag = RJUST;
			fieldstr = builtin_opt.optarg;
			break;
		case 'U':
			/* at&t ksh uses u, but this conflicts with
			 * upper/lower case.  If this option is changed,
			 * need to change the -U below as well
			 */
			flag = INT_U;
			break;
		case 'Z':
			flag = ZEROFIL;
			fieldstr = builtin_opt.optarg;
			break;
		case 'f':
			func = 1;
			break;
		case 'i':
			flag = INTEGER;
			basestr = builtin_opt.optarg;
			break;
		case 'l':
			flag = LCASEV;
			break;
		case 'p':
			/* posix export/readonly -p flag.
			 * typeset -p is the same as typeset (in pdksh);
			 * here for compatibility with ksh93.
			 */
			pflag = 1;
			break;
		case 'r':
			flag = RDONLY;
			break;
		case 't':
			flag = TRACE;
			break;
		case 'u':
			flag = UCASEV_AL;	/* upper case / autoload */
			break;
		case 'x':
			flag = EXPORT;
			break;
		case '?':
			return 1;
		}
		if (builtin_opt.info & GI_PLUS) {
			fclr |= flag;
			fset &= ~flag;
			thing = '+';
		} else {
			fset |= flag;
			fclr &= ~flag;
			thing = '-';
		}
	}

	field = 0;
	if (fieldstr && !bi_getn(fieldstr, &field))
		return 1;
	base = 0;
	if (basestr && !bi_getn(basestr, &base))
		return 1;

	if (!(builtin_opt.info & GI_MINUSMINUS) && wp[builtin_opt.optind] &&
	    (wp[builtin_opt.optind][0] == '-' ||
	    wp[builtin_opt.optind][0] == '+') &&
	    wp[builtin_opt.optind][1] == '\0') {
		thing = wp[builtin_opt.optind][0];
		builtin_opt.optind++;
	}

	if (func && ((fset|fclr) & ~(TRACE|UCASEV_AL|EXPORT))) {
		bi_errorf("only -t, -u and -x options may be used with -f");
		return 1;
	}
	if (wp[builtin_opt.optind]) {
		/* Take care of exclusions.
		 * At this point, flags in fset are cleared in fclr and vise
		 * versa.  This property should be preserved.
		 */
		if (fset & LCASEV)	/* LCASEV has priority over UCASEV_AL */
			fset &= ~UCASEV_AL;
		if (fset & LJUST)	/* LJUST has priority over RJUST */
			fset &= ~RJUST;
		if ((fset & (ZEROFIL|LJUST)) == ZEROFIL) { /* -Z implies -ZR */
			fset |= RJUST;
			fclr &= ~RJUST;
		}
		/* Setting these attributes clears the others, unless they
		 * are also set in this command
		 */
		if (fset & (LJUST | RJUST | ZEROFIL | UCASEV_AL | LCASEV |
		    INTEGER | INT_U | INT_L))
			fclr |= ~fset & (LJUST | RJUST | ZEROFIL | UCASEV_AL |
			    LCASEV | INTEGER | INT_U | INT_L);
	}

	/* set variables and attributes */
	if (wp[builtin_opt.optind]) {
		int i;
		int rval = 0;
		struct tbl *f;

		if (local && !func)
			fset |= LOCAL;
		for (i = builtin_opt.optind; wp[i]; i++) {
			if (func) {
				f = findfunc(wp[i], hash(wp[i]),
				    (fset&UCASEV_AL) ? true : false);
				if (!f) {
					/* at&t ksh does ++rval: bogus */
					rval = 1;
					continue;
				}
				if (fset | fclr) {
					f->flag |= fset;
					f->flag &= ~fclr;
				} else
					fptreef(shl_stdout, 0,
					    f->flag & FKSH ?
					    "function %s %T\n" :
					    "%s() %T\n", wp[i], f->val.t);
			} else if (!typeset(wp[i], fset, fclr, field, base)) {
				bi_errorf("%s: not identifier", wp[i]);
				return 1;
			}
		}
		return rval;
	}

	/* list variables and attributes */
	flag = fset | fclr; /* no difference at this point.. */
	if (func) {
		for (l = genv->loc; l; l = l->next) {
			for (p = ktsort(&l->funs); (vp = *p++); ) {
				if (flag && (vp->flag & flag) == 0)
					continue;
				if (thing == '-')
					fptreef(shl_stdout, 0, vp->flag & FKSH ?
					    "function %s %T\n" : "%s() %T\n",
					    vp->name, vp->val.t);
				else
					shprintf("%s\n", vp->name);
			}
		}
	} else {
		for (l = genv->loc; l; l = l->next) {
			for (p = ktsort(&l->vars); (vp = *p++); ) {
				struct tbl *tvp;
				int any_set = 0;
				/*
				 * See if the parameter is set (for arrays, if any
				 * element is set).
				 */
				for (tvp = vp; tvp; tvp = tvp->u.array)
					if (tvp->flag & ISSET) {
						any_set = 1;
						break;
					}

				/*
				 * Check attributes - note that all array elements
				 * have (should have?) the same attributes, so checking
				 * the first is sufficient.
				 *
				 * Report an unset param only if the user has
				 * explicitly given it some attribute (like export);
				 * otherwise, after "echo $FOO", we would report FOO...
				 */
				if (!any_set && !(vp->flag & USERATTRIB))
					continue;
				if (flag && (vp->flag & flag) == 0)
					continue;
				for (; vp; vp = vp->u.array) {
					/* Ignore array elements that aren't
					 * set unless there are no set elements,
					 * in which case the first is reported on */
					if ((vp->flag&ARRAY) && any_set &&
					    !(vp->flag & ISSET))
						continue;
					/* no arguments */
					if (thing == 0 && flag == 0) {
						/* at&t ksh prints things
						 * like export, integer,
						 * leftadj, zerofill, etc.,
						 * but POSIX says must
						 * be suitable for re-entry...
						 */
						shprintf("typeset ");
						if ((vp->flag&INTEGER))
							shprintf("-i ");
						if ((vp->flag&EXPORT))
							shprintf("-x ");
						if ((vp->flag&RDONLY))
							shprintf("-r ");
						if ((vp->flag&TRACE))
							shprintf("-t ");
						if ((vp->flag&LJUST))
							shprintf("-L%d ", vp->u2.field);
						if ((vp->flag&RJUST))
							shprintf("-R%d ", vp->u2.field);
						if ((vp->flag&ZEROFIL))
							shprintf("-Z ");
						if ((vp->flag&LCASEV))
							shprintf("-l ");
						if ((vp->flag&UCASEV_AL))
							shprintf("-u ");
						if ((vp->flag&INT_U))
							shprintf("-U ");
						shprintf("%s\n", vp->name);
						if (vp->flag&ARRAY)
							break;
					} else {
						if (pflag)
							shprintf("%s ",
							    (flag & EXPORT) ?
							    "export" : "readonly");
						if ((vp->flag&ARRAY) && any_set)
							shprintf("%s[%d]",
							    vp->name, vp->index);
						else
							shprintf("%s", vp->name);
						if (thing == '-' && (vp->flag&ISSET)) {
							char *s = str_val(vp);

							shprintf("=");
							/* at&t ksh can't have
							 * justified integers.. */
							if ((vp->flag &
							    (INTEGER|LJUST|RJUST)) ==
							    INTEGER)
								shprintf("%s", s);
							else
								print_value_quoted(s);
						}
						shprintf("\n");
					}
					/* Only report first `element' of an array with
					* no set elements.
					*/
					if (!any_set)
						break;
				}
			}
		}
	}
	return 0;
}

int
c_alias(char **wp)
{
	struct table *t = &aliases;
	int rv = 0, rflag = 0, tflag, Uflag = 0, pflag = 0, prefix = 0;
	int xflag = 0;
	int optc;

	builtin_opt.flags |= GF_PLUSOPT;
	while ((optc = ksh_getopt(wp, &builtin_opt, "dprtUx")) != -1) {
		prefix = builtin_opt.info & GI_PLUS ? '+' : '-';
		switch (optc) {
		case 'd':
			t = &homedirs;
			break;
		case 'p':
			pflag = 1;
			break;
		case 'r':
			rflag = 1;
			break;
		case 't':
			t = &taliases;
			break;
		case 'U':
			/*
			 * kludge for tracked alias initialization
			 * (don't do a path search, just make an entry)
			 */
			Uflag = 1;
			break;
		case 'x':
			xflag = EXPORT;
			break;
		case '?':
			return 1;
		}
	}
	wp += builtin_opt.optind;

	if (!(builtin_opt.info & GI_MINUSMINUS) && *wp &&
	    (wp[0][0] == '-' || wp[0][0] == '+') && wp[0][1] == '\0') {
		prefix = wp[0][0];
		wp++;
	}

	tflag = t == &taliases;

	/* "hash -r" means reset all the tracked aliases.. */
	if (rflag) {
		static const char *const args[] = {
			"unalias", "-ta", NULL
		};

		if (!tflag || *wp) {
			shprintf("alias: -r flag can only be used with -t"
			    " and without arguments\n");
			return 1;
		}
		ksh_getopt_reset(&builtin_opt, GF_ERROR);
		return c_unalias((char **) args);
	}

	if (*wp == NULL) {
		struct tbl *ap, **p;

		for (p = ktsort(t); (ap = *p++) != NULL; )
			if ((ap->flag & (ISSET|xflag)) == (ISSET|xflag)) {
				if (pflag)
					shf_puts("alias ", shl_stdout);
				shf_puts(ap->name, shl_stdout);
				if (prefix != '+') {
					shf_putc('=', shl_stdout);
					print_value_quoted(ap->val.s);
				}
				shprintf("\n");
			}
	}

	for (; *wp != NULL; wp++) {
		char *alias = *wp;
		char *val = strchr(alias, '=');
		char *newval;
		struct tbl *ap;
		int h;

		if (val)
			alias = str_nsave(alias, val++ - alias, ATEMP);
		h = hash(alias);
		if (val == NULL && !tflag && !xflag) {
			ap = ktsearch(t, alias, h);
			if (ap != NULL && (ap->flag&ISSET)) {
				if (pflag)
					shf_puts("alias ", shl_stdout);
				shf_puts(ap->name, shl_stdout);
				if (prefix != '+') {
					shf_putc('=', shl_stdout);
					print_value_quoted(ap->val.s);
				}
				shprintf("\n");
			} else {
				shprintf("%s alias not found\n", alias);
				rv = 1;
			}
			continue;
		}
		ap = ktenter(t, alias, h);
		ap->type = tflag ? CTALIAS : CALIAS;
		/* Are we setting the value or just some flags? */
		if ((val && !tflag) || (!val && tflag && !Uflag)) {
			if (ap->flag&ALLOC) {
				ap->flag &= ~(ALLOC|ISSET);
				afree(ap->val.s, APERM);
			}
			/* ignore values for -t (at&t ksh does this) */
			newval = tflag ? search(alias, search_path, X_OK, NULL)
			    : val;
			if (newval) {
				ap->val.s = str_save(newval, APERM);
				ap->flag |= ALLOC|ISSET;
			} else
				ap->flag &= ~ISSET;
		}
		ap->flag |= DEFINED;
		if (prefix == '+')
			ap->flag &= ~xflag;
		else
			ap->flag |= xflag;
		if (val)
			afree(alias, ATEMP);
	}

	return rv;
}

int
c_unalias(char **wp)
{
	struct table *t = &aliases;
	struct tbl *ap;
	int rv = 0, all = 0;
	int optc;

	while ((optc = ksh_getopt(wp, &builtin_opt, "adt")) != -1)
		switch (optc) {
		case 'a':
			all = 1;
			break;
		case 'd':
			t = &homedirs;
			break;
		case 't':
			t = &taliases;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	for (; *wp != NULL; wp++) {
		ap = ktsearch(t, *wp, hash(*wp));
		if (ap == NULL) {
			rv = 1;	/* POSIX */
			continue;
		}
		if (ap->flag&ALLOC) {
			ap->flag &= ~(ALLOC|ISSET);
			afree(ap->val.s, APERM);
		}
		ap->flag &= ~(DEFINED|ISSET|EXPORT);
	}

	if (all) {
		struct tstate ts;

		for (ktwalk(&ts, t); (ap = ktnext(&ts)); ) {
			if (ap->flag&ALLOC) {
				ap->flag &= ~(ALLOC|ISSET);
				afree(ap->val.s, APERM);
			}
			ap->flag &= ~(DEFINED|ISSET|EXPORT);
		}
	}

	return rv;
}

int
c_let(char **wp)
{
	int rv = 1;
	int64_t val;

	if (wp[1] == NULL) /* at&t ksh does this */
		bi_errorf("no arguments");
	else
		for (wp++; *wp; wp++)
			if (!evaluate(*wp, &val, KSH_RETURN_ERROR, true)) {
				rv = 2;	/* distinguish error from zero result */
				break;
			} else
				rv = val == 0;
	return rv;
}

int
c_jobs(char **wp)
{
	int optc;
	int flag = 0;
	int nflag = 0;
	int rv = 0;

	while ((optc = ksh_getopt(wp, &builtin_opt, "lpnz")) != -1)
		switch (optc) {
		case 'l':
			flag = 1;
			break;
		case 'p':
			flag = 2;
			break;
		case 'n':
			nflag = 1;
			break;
		case 'z':	/* debugging: print zombies */
			nflag = -1;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;
	if (!*wp) {
		if (j_jobs(NULL, flag, nflag))
			rv = 1;
	} else {
		for (; *wp; wp++)
			if (j_jobs(*wp, flag, nflag))
				rv = 1;
	}
	return rv;
}

int
c_fgbg(char **wp)
{
	int bg = strcmp(*wp, "bg") == 0;
	int rv = 0;

	if (!Flag(FMONITOR)) {
		bi_errorf("job control not enabled");
		return 1;
	}
	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	wp += builtin_opt.optind;
	if (*wp)
		for (; *wp; wp++)
			rv = j_resume(*wp, bg);
	else
		rv = j_resume("%%", bg);
	/* POSIX says fg shall return 0 (unless an error occurs).
	 * at&t ksh returns the exit value of the job...
	 */
	return (bg || Flag(FPOSIX)) ? 0 : rv;
}

struct kill_info {
	int num_width;
	int name_width;
};
static char *kill_fmt_entry(void *arg, int i, char *buf, int buflen);

/* format a single kill item */
static char *
kill_fmt_entry(void *arg, int i, char *buf, int buflen)
{
	struct kill_info *ki = (struct kill_info *) arg;

	i++;
	if (sigtraps[i].name)
		shf_snprintf(buf, buflen, "%*d %*s %s",
		    ki->num_width, i,
		    ki->name_width, sigtraps[i].name,
		    sigtraps[i].mess);
	else
		shf_snprintf(buf, buflen, "%*d %*d %s",
		    ki->num_width, i,
		    ki->name_width, sigtraps[i].signal,
		    sigtraps[i].mess);
	return buf;
}


int
c_kill(char **wp)
{
	Trap *t = NULL;
	char *p;
	int lflag = 0;
	int i, n, rv, sig;

	/* assume old style options if -digits or -UPPERCASE */
	if ((p = wp[1]) && *p == '-' &&
	    (digit(p[1]) || isupper((unsigned char)p[1]))) {
		if (!(t = gettrap(p + 1, true))) {
			bi_errorf("bad signal `%s'", p + 1);
			return 1;
		}
		i = (wp[2] && strcmp(wp[2], "--") == 0) ? 3 : 2;
	} else {
		int optc;

		while ((optc = ksh_getopt(wp, &builtin_opt, "ls:")) != -1)
			switch (optc) {
			case 'l':
				lflag = 1;
				break;
			case 's':
				if (!(t = gettrap(builtin_opt.optarg, true))) {
					bi_errorf("bad signal `%s'",
					    builtin_opt.optarg);
					return 1;
				}
				break;
			case '?':
				return 1;
			}
		i = builtin_opt.optind;
	}
	if ((lflag && t) || (!wp[i] && !lflag)) {
		shf_fprintf(shl_out,
		    "usage: kill [-s signame | -signum | -signame] { job | pid | pgrp } ...\n"
		    "       kill -l [exit_status ...]\n");
		bi_errorf(NULL);
		return 1;
	}

	if (lflag) {
		if (wp[i]) {
			for (; wp[i]; i++) {
				if (!bi_getn(wp[i], &n))
					return 1;
				if (n > 128 && n < 128 + NSIG)
					n -= 128;
				if (n > 0 && n < NSIG && sigtraps[n].name)
					shprintf("%s\n", sigtraps[n].name);
				else
					shprintf("%d\n", n);
			}
		} else if (Flag(FPOSIX)) {
			p = null;
			for (i = 1; i < NSIG; i++, p = " ")
				if (sigtraps[i].name)
					shprintf("%s%s", p, sigtraps[i].name);
			shprintf("\n");
		} else {
			int mess_width = 0, w;
			struct kill_info ki = {
				.num_width = 1,
				.name_width = 0,
			};

			for (i = NSIG; i >= 10; i /= 10)
				ki.num_width++;

			for (i = 0; i < NSIG; i++) {
				w = sigtraps[i].name ?
				    (int)strlen(sigtraps[i].name) :
				    ki.num_width;
				if (w > ki.name_width)
					ki.name_width = w;
				w = strlen(sigtraps[i].mess);
				if (w > mess_width)
					mess_width = w;
			}

			print_columns(shl_stdout, NSIG - 1,
			    kill_fmt_entry, (void *) &ki,
			    ki.num_width + ki.name_width + mess_width + 3, 1);
		}
		return 0;
	}
	rv = 0;
	sig = t ? t->signal : SIGTERM;
	for (; (p = wp[i]); i++) {
		if (*p == '%') {
			if (j_kill(p, sig))
				rv = 1;
		} else if (!getn(p, &n)) {
			bi_errorf("%s: arguments must be jobs or process IDs",
			    p);
			rv = 1;
		} else {
			/* use killpg if < -1 since -1 does special things for
			 * some non-killpg-endowed kills
			 */
			if ((n < -1 ? killpg(-n, sig) : kill(n, sig)) == -1) {
				bi_errorf("%s: %s", p, strerror(errno));
				rv = 1;
			}
		}
	}
	return rv;
}

void
getopts_reset(int val)
{
	if (val >= 1) {
		ksh_getopt_reset(&user_opt,
		    GF_NONAME | (Flag(FPOSIX) ? 0 : GF_PLUSOPT));
		user_opt.optind = user_opt.uoptind = val;
	}
}

int
c_getopts(char **wp)
{
	int	argc;
	const char *options;
	const char *var;
	int	optc;
	int	ret;
	char	buf[3];
	struct tbl *vq, *voptarg;

	if (ksh_getopt(wp, &builtin_opt, null) == '?')
		return 1;
	wp += builtin_opt.optind;

	options = *wp++;
	if (!options) {
		bi_errorf("missing options argument");
		return 1;
	}

	var = *wp++;
	if (!var) {
		bi_errorf("missing name argument");
		return 1;
	}
	if (!*var || *skip_varname(var, true)) {
		bi_errorf("%s: is not an identifier", var);
		return 1;
	}

	if (genv->loc->next == NULL) {
		internal_warningf("%s: no argv", __func__);
		return 1;
	}
	/* Which arguments are we parsing... */
	if (*wp == NULL)
		wp = genv->loc->next->argv;
	else
		*--wp = genv->loc->next->argv[0];

	/* Check that our saved state won't cause a core dump... */
	for (argc = 0; wp[argc]; argc++)
		;
	if (user_opt.optind > argc ||
	    (user_opt.p != 0 &&
	    user_opt.p > strlen(wp[user_opt.optind - 1]))) {
		bi_errorf("arguments changed since last call");
		return 1;
	}

	user_opt.optarg = NULL;
	optc = ksh_getopt(wp, &user_opt, options);

	if (optc >= 0 && optc != '?' && (user_opt.info & GI_PLUS)) {
		buf[0] = '+';
		buf[1] = optc;
		buf[2] = '\0';
	} else {
		/* POSIX says var is set to ? at end-of-options, at&t ksh
		 * sets it to null - we go with POSIX...
		 */
		buf[0] = optc < 0 ? '?' : optc;
		buf[1] = '\0';
	}

	/* at&t ksh does not change OPTIND if it was an unknown option.
	 * Scripts counting on this are prone to break... (ie, don't count
	 * on this staying).
	 */
	if (optc != '?') {
		user_opt.uoptind = user_opt.optind;
	}

	voptarg = global("OPTARG");
	voptarg->flag &= ~RDONLY;	/* at&t ksh clears ro and int */
	/* Paranoia: ensure no bizarre results. */
	if (voptarg->flag & INTEGER)
	    typeset("OPTARG", 0, INTEGER, 0, 0);
	if (user_opt.optarg == NULL)
		unset(voptarg, 0);
	else
		/* This can't fail (have cleared readonly/integer) */
		setstr(voptarg, user_opt.optarg, KSH_RETURN_ERROR);

	ret = 0;

	vq = global(var);
	/* Error message already printed (integer, readonly) */
	if (!setstr(vq, buf, KSH_RETURN_ERROR))
	    ret = 1;
	if (Flag(FEXPORT))
		typeset(var, EXPORT, 0, 0, 0);

	return optc < 0 ? 1 : ret;
}

int
c_bind(char **wp)
{
	int optc, rv = 0, macro = 0, list = 0;
	char *cp;

	while ((optc = ksh_getopt(wp, &builtin_opt, "lm")) != -1)
		switch (optc) {
		case 'l':
			list = 1;
			break;
		case 'm':
			macro = 1;
			break;
		case '?':
			return 1;
		}
	wp += builtin_opt.optind;

	if (*wp == NULL)	/* list all */
		rv = x_bind(NULL, NULL, 0, list);

	for (; *wp != NULL; wp++) {
		cp = strchr(*wp, '=');
		if (cp != NULL)
			*cp++ = '\0';
		if (x_bind(*wp, cp, macro, 0))
			rv = 1;
	}

	return rv;
}

/* A leading = means assignments before command are kept;
 * a leading * means a POSIX special builtin;
 * a leading + means a POSIX regular builtin
 * (* and + should not be combined).
 */
const struct builtin kshbuiltins [] = {
	{"+alias", c_alias},	/* no =: at&t manual wrong */
	{"+cd", c_cd},
	{"+command", c_command},
	{"echo", c_print},
	{"*=export", c_typeset},
	{"+fc", c_fc},
	{"+getopts", c_getopts},
	{"+jobs", c_jobs},
	{"+kill", c_kill},
	{"let", c_let},
	{"print", c_print},
	{"+printf", c_printf},
	{"pwd", c_pwd},
	{"*=readonly", c_typeset},
	{"type", c_type},
	{"=typeset", c_typeset},
	{"+unalias", c_unalias},
	{"whence", c_whence},
	{"+bg", c_fgbg},
	{"+fg", c_fgbg},
	{"bind", c_bind},
	{NULL, NULL}
};

/*
 * test(1) and [[ ... ]]
 */

/*
 * test(1); version 7-like  --  author Erik Baalbergen
 * modified by Eric Gisin to be used as built-in.
 * modified by Arnold Robbins to add SVR3 compatibility
 * (-x -c -b -p -u -g -k) plus Korn's -L -nt -ot -ef and new -S (socket).
 * modified by Michael Rendell to add Korn's [[ .. ]] expressions.
 * modified by J.T. Conklin to add POSIX compatibility.
 */




/* test(1) accepts the following grammar:
	oexpr	::= aexpr | aexpr "-o" oexpr ;
	aexpr	::= nexpr | nexpr "-a" aexpr ;
	nexpr	::= primary | "!" nexpr ;
	primary	::= unary-operator operand
		| operand binary-operator operand
		| operand
		| "(" oexpr ")"
		;

	unary-operator ::= "-a"|"-r"|"-w"|"-x"|"-e"|"-f"|"-d"|"-c"|"-b"|"-p"|
			   "-u"|"-g"|"-k"|"-s"|"-t"|"-z"|"-n"|"-o"|"-O"|"-G"|
			   "-L"|"-h"|"-S"|"-H";

	binary-operator ::= "="|"=="|"!="|"-eq"|"-ne"|"-ge"|"-gt"|"-le"|"-lt"|
			    "-nt"|"-ot"|"-ef"|"<"|">"
			    ;
	operand ::= <any thing>
*/

#define T_ERR_EXIT	2	/* POSIX says > 1 for errors */

struct t_op {
	char	op_text[4];
	Test_op	op_num;
};
static const struct t_op u_ops [] = {
	{"-a",	TO_FILAXST },
	{"-b",	TO_FILBDEV },
	{"-c",	TO_FILCDEV },
	{"-d",	TO_FILID },
	{"-e",	TO_FILEXST },
	{"-f",	TO_FILREG },
	{"-G",	TO_FILGID },
	{"-g",	TO_FILSETG },
	{"-h",	TO_FILSYM },
	{"-H",	TO_FILCDF },
	{"-k",	TO_FILSTCK },
	{"-L",	TO_FILSYM },
	{"-n",	TO_STNZE },
	{"-O",	TO_FILUID },
	{"-o",	TO_OPTION },
	{"-p",	TO_FILFIFO },
	{"-r",	TO_FILRD },
	{"-s",	TO_FILGZ },
	{"-S",	TO_FILSOCK },
	{"-t",	TO_FILTT },
	{"-u",	TO_FILSETU },
	{"-w",	TO_FILWR },
	{"-x",	TO_FILEX },
	{"-z",	TO_STZER },
	{"",	TO_NONOP }
};
static const struct t_op b_ops [] = {
	{"=",	TO_STEQL },
	{"==",	TO_STEQL },
	{"!=",	TO_STNEQ },
	{"<",	TO_STLT },
	{">",	TO_STGT },
	{"-eq",	TO_INTEQ },
	{"-ne",	TO_INTNE },
	{"-gt",	TO_INTGT },
	{"-ge",	TO_INTGE },
	{"-lt",	TO_INTLT },
	{"-le",	TO_INTLE },
	{"-ef",	TO_FILEQ },
	{"-nt",	TO_FILNT },
	{"-ot",	TO_FILOT },
	{"",	TO_NONOP }
};

static int	test_eaccess(const char *, int);
static int	test_oexpr(Test_env *, int);
static int	test_aexpr(Test_env *, int);
static int	test_nexpr(Test_env *, int);
static int	test_primary(Test_env *, int);
static int	ptest_isa(Test_env *, Test_meta);
static const char *ptest_getopnd(Test_env *, Test_op, int);
static int	ptest_eval(Test_env *, Test_op, const char *,
		    const char *, int);
static void	ptest_error(Test_env *, int, const char *);

int
c_test(char **wp)
{
	int argc;
	int res;
	Test_env te;

	te.flags = 0;
	te.isa = ptest_isa;
	te.getopnd = ptest_getopnd;
	te.eval = ptest_eval;
	te.error = ptest_error;

	for (argc = 0; wp[argc]; argc++)
		;

	if (strcmp(wp[0], "[") == 0) {
		if (strcmp(wp[--argc], "]") != 0) {
			bi_errorf("missing ]");
			return T_ERR_EXIT;
		}
	}

	te.pos.wp = wp + 1;
	te.wp_end = wp + argc;

	/*
	 * Handle the special cases from POSIX.2, section 4.62.4.
	 * Implementation of all the rules isn't necessary since
	 * our parser does the right thing for the omitted steps.
	 */
	if (argc <= 5) {
		char **owp = wp;
		int invert = 0;
		Test_op	op;
		const char *opnd1, *opnd2;

		while (--argc >= 0) {
			if ((*te.isa)(&te, TM_END))
				return !0;
			if (argc == 3) {
				opnd1 = (*te.getopnd)(&te, TO_NONOP, 1);
				if ((op = (Test_op) (*te.isa)(&te, TM_BINOP))) {
					opnd2 = (*te.getopnd)(&te, op, 1);
					res = (*te.eval)(&te, op, opnd1,
					    opnd2, 1);
					if (te.flags & TEF_ERROR)
						return T_ERR_EXIT;
					if (invert & 1)
						res = !res;
					return !res;
				}
				/* back up to opnd1 */
				te.pos.wp--;
			}
			if (argc == 1) {
				opnd1 = (*te.getopnd)(&te, TO_NONOP, 1);
				res = (*te.eval)(&te, TO_STNZE, opnd1,
				    NULL, 1);
				if (invert & 1)
					res = !res;
				return !res;
			}
			if ((*te.isa)(&te, TM_NOT)) {
				invert++;
			} else
				break;
		}
		te.pos.wp = owp + 1;
	}

	return test_parse(&te);
}

/*
 * Generic test routines.
 */

Test_op
test_isop(Test_env *te, Test_meta meta, const char *s)
{
	char sc1;
	const struct t_op *otab;

	otab = meta == TM_UNOP ? u_ops : b_ops;
	if (*s) {
		sc1 = s[1];
		for (; otab->op_text[0]; otab++)
			if (sc1 == otab->op_text[1] &&
			    strcmp(s, otab->op_text) == 0)
				return otab->op_num;
	}
	return TO_NONOP;
}

int
test_eval(Test_env *te, Test_op op, const char *opnd1, const char *opnd2,
    int do_eval)
{
	int res;
	int not;
	struct stat b1, b2;

	if (!do_eval)
		return 0;

	switch ((int) op) {
	/*
	 * Unary Operators
	 */
	case TO_STNZE: /* -n */
		return *opnd1 != '\0';
	case TO_STZER: /* -z */
		return *opnd1 == '\0';
	case TO_OPTION: /* -o */
		if ((not = *opnd1 == '!'))
			opnd1++;
		if ((res = option(opnd1)) < 0)
			res = 0;
		else {
			res = Flag(res);
			if (not)
				res = !res;
		}
		return res;
	case TO_FILRD: /* -r */
		return test_eaccess(opnd1, R_OK) == 0;
	case TO_FILWR: /* -w */
		return test_eaccess(opnd1, W_OK) == 0;
	case TO_FILEX: /* -x */
		return test_eaccess(opnd1, X_OK) == 0;
	case TO_FILAXST: /* -a */
		return stat(opnd1, &b1) == 0;
	case TO_FILEXST: /* -e */
		/* at&t ksh does not appear to do the /dev/fd/ thing for
		 * this (unless the os itself handles it)
		 */
		return stat(opnd1, &b1) == 0;
	case TO_FILREG: /* -r */
		return stat(opnd1, &b1) == 0 && S_ISREG(b1.st_mode);
	case TO_FILID: /* -d */
		return stat(opnd1, &b1) == 0 && S_ISDIR(b1.st_mode);
	case TO_FILCDEV: /* -c */
		return stat(opnd1, &b1) == 0 && S_ISCHR(b1.st_mode);
	case TO_FILBDEV: /* -b */
		return stat(opnd1, &b1) == 0 && S_ISBLK(b1.st_mode);
	case TO_FILFIFO: /* -p */
		return stat(opnd1, &b1) == 0 && S_ISFIFO(b1.st_mode);
	case TO_FILSYM: /* -h -L */
		return lstat(opnd1, &b1) == 0 && S_ISLNK(b1.st_mode);
	case TO_FILSOCK: /* -S */
		return stat(opnd1, &b1) == 0 && S_ISSOCK(b1.st_mode);
	case TO_FILCDF:/* -H HP context dependent files (directories) */
		return 0;
	case TO_FILSETU: /* -u */
		return stat(opnd1, &b1) == 0 &&
		    (b1.st_mode & S_ISUID) == S_ISUID;
	case TO_FILSETG: /* -g */
		return stat(opnd1, &b1) == 0 &&
		    (b1.st_mode & S_ISGID) == S_ISGID;
	case TO_FILSTCK: /* -k */
		return stat(opnd1, &b1) == 0 &&
		    (b1.st_mode & S_ISVTX) == S_ISVTX;
	case TO_FILGZ: /* -s */
		return stat(opnd1, &b1) == 0 && b1.st_size > 0L;
	case TO_FILTT: /* -t */
		if (!bi_getn(opnd1, &res)) {
			te->flags |= TEF_ERROR;
			return 0;
		}
		return isatty(res);
	case TO_FILUID: /* -O */
		return stat(opnd1, &b1) == 0 && b1.st_uid == ksheuid;
	case TO_FILGID: /* -G */
		return stat(opnd1, &b1) == 0 && b1.st_gid == getegid();
	/*
	 * Binary Operators
	 */
	case TO_STEQL: /* = */
		if (te->flags & TEF_DBRACKET)
			return gmatch_(opnd1, opnd2, false);
		return strcmp(opnd1, opnd2) == 0;
	case TO_STNEQ: /* != */
		if (te->flags & TEF_DBRACKET)
			return !gmatch_(opnd1, opnd2, false);
		return strcmp(opnd1, opnd2) != 0;
	case TO_STLT: /* < */
		return strcmp(opnd1, opnd2) < 0;
	case TO_STGT: /* > */
		return strcmp(opnd1, opnd2) > 0;
	case TO_INTEQ: /* -eq */
	case TO_INTNE: /* -ne */
	case TO_INTGE: /* -ge */
	case TO_INTGT: /* -gt */
	case TO_INTLE: /* -le */
	case TO_INTLT: /* -lt */
		{
			int64_t v1, v2;

			if (!evaluate(opnd1, &v1, KSH_RETURN_ERROR, false) ||
			    !evaluate(opnd2, &v2, KSH_RETURN_ERROR, false)) {
				/* error already printed.. */
				te->flags |= TEF_ERROR;
				return 1;
			}
			switch ((int) op) {
			case TO_INTEQ:
				return v1 == v2;
			case TO_INTNE:
				return v1 != v2;
			case TO_INTGE:
				return v1 >= v2;
			case TO_INTGT:
				return v1 > v2;
			case TO_INTLE:
				return v1 <= v2;
			case TO_INTLT:
				return v1 < v2;
			}
		}
	case TO_FILNT: /* -nt */
		{
			int s2;
			/* ksh88/ksh93 succeed if file2 can't be stated
			 * (subtly different from `does not exist').
			 */
			return stat(opnd1, &b1) == 0 &&
			    (((s2 = stat(opnd2, &b2)) == 0 &&
			    timespeccmp(&b1.st_mtim, &b2.st_mtim, >)) ||
			    s2 != 0);
		}
	case TO_FILOT: /* -ot */
		{
			int s1;
			/* ksh88/ksh93 succeed if file1 can't be stated
			 * (subtly different from `does not exist').
			 */
			return stat(opnd2, &b2) == 0 &&
			    (((s1 = stat(opnd1, &b1)) == 0 &&
			    timespeccmp(&b1.st_mtim, &b2.st_mtim, <)) ||
			    s1 != 0);
		}
	case TO_FILEQ: /* -ef */
		return stat (opnd1, &b1) == 0 && stat (opnd2, &b2) == 0 &&
		    b1.st_dev == b2.st_dev && b1.st_ino == b2.st_ino;
	}
	(*te->error)(te, 0, "internal error: unknown op");
	return 1;
}

/* Routine to deal with X_OK on non-directories when running as root.
 */
static int
test_eaccess(const char *path, int amode)
{
	int res;

	res = access(path, amode);
	/*
	 * On most (all?) unixes, access() says everything is executable for
	 * root - avoid this on files by using stat().
	 */
	if (res == 0 && ksheuid == 0 && (amode & X_OK)) {
		struct stat statb;

		if (stat(path, &statb) == -1)
			res = -1;
		else if (S_ISDIR(statb.st_mode))
			res = 0;
		else
			res = (statb.st_mode & (S_IXUSR|S_IXGRP|S_IXOTH)) ?
			    0 : -1;
	}

	return res;
}

int
test_parse(Test_env *te)
{
	int res;

	res = test_oexpr(te, 1);

	if (!(te->flags & TEF_ERROR) && !(*te->isa)(te, TM_END))
		(*te->error)(te, 0, "unexpected operator/operand");

	return (te->flags & TEF_ERROR) ? T_ERR_EXIT : !res;
}

static int
test_oexpr(Test_env *te, int do_eval)
{
	int res;

	res = test_aexpr(te, do_eval);
	if (res)
		do_eval = 0;
	if (!(te->flags & TEF_ERROR) && (*te->isa)(te, TM_OR))
		return test_oexpr(te, do_eval) || res;
	return res;
}

static int
test_aexpr(Test_env *te, int do_eval)
{
	int res;

	res = test_nexpr(te, do_eval);
	if (!res)
		do_eval = 0;
	if (!(te->flags & TEF_ERROR) && (*te->isa)(te, TM_AND))
		return test_aexpr(te, do_eval) && res;
	return res;
}

static int
test_nexpr(Test_env *te, int do_eval)
{
	if (!(te->flags & TEF_ERROR) && (*te->isa)(te, TM_NOT))
		return !test_nexpr(te, do_eval);
	return test_primary(te, do_eval);
}

static int
test_primary(Test_env *te, int do_eval)
{
	const char *opnd1, *opnd2;
	int res;
	Test_op op;

	if (te->flags & TEF_ERROR)
		return 0;
	if ((*te->isa)(te, TM_OPAREN)) {
		res = test_oexpr(te, do_eval);
		if (te->flags & TEF_ERROR)
			return 0;
		if (!(*te->isa)(te, TM_CPAREN)) {
			(*te->error)(te, 0, "missing closing paren");
			return 0;
		}
		return res;
	}
	/*
	 * Binary should have precedence over unary in this case
	 * so that something like test \( -f = -f \) is accepted
	 */
	if ((te->flags & TEF_DBRACKET) || (&te->pos.wp[1] < te->wp_end &&
	    !test_isop(te, TM_BINOP, te->pos.wp[1]))) {
		if ((op = (Test_op) (*te->isa)(te, TM_UNOP))) {
			/* unary expression */
			opnd1 = (*te->getopnd)(te, op, do_eval);
			if (!opnd1) {
				(*te->error)(te, -1, "missing argument");
				return 0;
			}

			return (*te->eval)(te, op, opnd1, NULL,
			    do_eval);
		}
	}
	opnd1 = (*te->getopnd)(te, TO_NONOP, do_eval);
	if (!opnd1) {
		(*te->error)(te, 0, "expression expected");
		return 0;
	}
	if ((op = (Test_op) (*te->isa)(te, TM_BINOP))) {
		/* binary expression */
		opnd2 = (*te->getopnd)(te, op, do_eval);
		if (!opnd2) {
			(*te->error)(te, -1, "missing second argument");
			return 0;
		}

		return (*te->eval)(te, op, opnd1, opnd2, do_eval);
	}
	if (te->flags & TEF_DBRACKET) {
		(*te->error)(te, -1, "missing expression operator");
		return 0;
	}
	return (*te->eval)(te, TO_STNZE, opnd1, NULL, do_eval);
}

/*
 * Plain test (test and [ .. ]) specific routines.
 */

/* Test if the current token is a whatever.  Accepts the current token if
 * it is.  Returns 0 if it is not, non-zero if it is (in the case of
 * TM_UNOP and TM_BINOP, the returned value is a Test_op).
 */
static int
ptest_isa(Test_env *te, Test_meta meta)
{
	/* Order important - indexed by Test_meta values */
	static const char *const tokens[] = {
		"-o", "-a", "!", "(", ")"
	};
	int ret;

	if (te->pos.wp >= te->wp_end)
		return meta == TM_END;

	if (meta == TM_UNOP || meta == TM_BINOP)
		ret = (int) test_isop(te, meta, *te->pos.wp);
	else if (meta == TM_END)
		ret = 0;
	else
		ret = strcmp(*te->pos.wp, tokens[(int) meta]) == 0;

	/* Accept the token? */
	if (ret)
		te->pos.wp++;

	return ret;
}

static const char *
ptest_getopnd(Test_env *te, Test_op op, int do_eval)
{
	if (te->pos.wp >= te->wp_end)
		return NULL;
	return *te->pos.wp++;
}

static int
ptest_eval(Test_env *te, Test_op op, const char *opnd1, const char *opnd2,
    int do_eval)
{
	return test_eval(te, op, opnd1, opnd2, do_eval);
}

static void
ptest_error(Test_env *te, int offset, const char *msg)
{
	const char *op = te->pos.wp + offset >= te->wp_end ?
	    NULL : te->pos.wp[offset];

	te->flags |= TEF_ERROR;
	if (op)
		bi_errorf("%s: %s", op, msg);
	else
		bi_errorf("%s", msg);
}

/*
 * printf(1)
 */

/*
 * printf(1) as a shell builtin.
 *
 * Having printf built in avoids the kernel's per-argument size limit
 * (MAX_ARG_STRLEN) that execve(2) imposes on the external utility, and
 * is what most other shells do.
 */



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

/*
 * ulimit
 */

/*
	ulimit -- handle "ulimit" builtin

	Reworked to use getrusage() and ulimit() at once (as needed on
	some schizophrenic systems, eg, HP-UX 9.01), made argument parsing
	conform to at&t ksh, added autoconf support.  Michael Rendell, May, '94

	Eric Gisin, September 1988
	Adapted to PD KornShell. Removed AT&T code.

	last edit:	06-Jun-1987	D A Gwyn

	This started out as the BRL UNIX System V system call emulation
	for 4.nBSD, and was later extended by Doug Kingston to handle
	the extended 4.nBSD resource limits.  It now includes the code
	that was originally under case SYSULIMIT in source file "xec.c".
*/




#define SOFT	0x1
#define HARD	0x2

struct limits {
	const char *name;
	int	resource;	/* resource to get/set */
	int	factor;		/* multiply by to get rlim_{cur,max} values */
	char	option;		/* option character (-d, -f, ...) */
};

static void print_ulimit(const struct limits *, int);
static int set_ulimit(const struct limits *, const char *, int);

int
c_ulimit(char **wp)
{
	static const struct limits limits[] = {
		/* Do not use options -H, -S or -a or change the order. */
		{ "time(cpu-seconds)", RLIMIT_CPU, 1, 't' },
		{ "file(blocks)", RLIMIT_FSIZE, 512, 'f' },
		{ "coredump(blocks)", RLIMIT_CORE, 512, 'c' },
		{ "data(kbytes)", RLIMIT_DATA, 1024, 'd' },
		{ "stack(kbytes)", RLIMIT_STACK, 1024, 's' },
		{ "lockedmem(kbytes)", RLIMIT_MEMLOCK, 1024, 'l' },
		{ "memory(kbytes)", RLIMIT_RSS, 1024, 'm' },
		{ "nofiles(descriptors)", RLIMIT_NOFILE, 1, 'n' },
		{ "processes", RLIMIT_NPROC, 1, 'p' },
		{ NULL }
	};
	const char	*options = "HSat#f#c#d#s#l#m#n#p#";
	int		how = SOFT | HARD;
	const struct limits	*l;
	int		optc, all = 0;

	/* First check for -a, -H and -S. */
	while ((optc = ksh_getopt(wp, &builtin_opt, options)) != -1)
		switch (optc) {
		case 'H':
			how = HARD;
			break;
		case 'S':
			how = SOFT;
			break;
		case 'a':
			all = 1;
			break;
		case '?':
			return 1;
		default:
			break;
		}

	if (wp[builtin_opt.optind] != NULL) {
		bi_errorf("usage: ulimit [-acdfHlmnpSst] [value]");
		return 1;
	}

	/* Then parse and act on the actual limits, one at a time */
	ksh_getopt_reset(&builtin_opt, GF_ERROR);
	while ((optc = ksh_getopt(wp, &builtin_opt, options)) != -1)
		switch (optc) {
		case 'a':
		case 'H':
		case 'S':
			break;
		case '?':
			return 1;
		default:
			for (l = limits; l->name && l->option != optc; l++)
				;
			if (!l->name) {
				internal_warningf("%s: %c", __func__, optc);
				return 1;
			}
			if (builtin_opt.optarg) {
				if (set_ulimit(l, builtin_opt.optarg, how))
					return 1;
			} else
				print_ulimit(l, how);
			break;
		}

	wp += builtin_opt.optind;

	if (all) {
		for (l = limits; l->name; l++) {
			shprintf("%-20s ", l->name);
			print_ulimit(l, how);
		}
	} else if (builtin_opt.optind == 1) {
		/* No limit specified, use file size */
		l = &limits[1];
		if (wp[0] != NULL) {
			if (set_ulimit(l, wp[0], how))
				return 1;
			wp++;
		} else {
			print_ulimit(l, how);
		}
	}

	return 0;
}

static int
set_ulimit(const struct limits *l, const char *v, int how)
{
	rlim_t		val = 0;
	struct rlimit	limit;

	if (strcmp(v, "unlimited") == 0)
		val = RLIM_INFINITY;
	else {
		int64_t rval;

		if (!evaluate(v, &rval, KSH_RETURN_ERROR, false))
			return 1;
		/*
		 * Avoid problems caused by typos that evaluate misses due
		 * to evaluating unset parameters to 0...
		 * If this causes problems, will have to add parameter to
		 * evaluate() to control if unset params are 0 or an error.
		 */
		if (!rval && !digit(v[0])) {
			bi_errorf("invalid limit: %s", v);
			return 1;
		}
		val = (rlim_t)rval * l->factor;
	}

	getrlimit(l->resource, &limit);
	if (how & SOFT)
		limit.rlim_cur = val;
	if (how & HARD)
		limit.rlim_max = val;
	if (setrlimit(l->resource, &limit) == -1) {
		if (errno == EPERM)
			bi_errorf("-%c exceeds allowable limit", l->option);
		else
			bi_errorf("bad -%c limit: %s", l->option,
			    strerror(errno));
		return 1;
	}
	return 0;
}

static void
print_ulimit(const struct limits *l, int how)
{
	rlim_t		val = 0;
	struct rlimit	limit;

	getrlimit(l->resource, &limit);
	if (how & SOFT)
		val = limit.rlim_cur;
	else if (how & HARD)
		val = limit.rlim_max;
	if (val == RLIM_INFINITY)
		shprintf("unlimited\n");
	else {
		val /= l->factor;
		shprintf("%" PRIi64 "\n", (int64_t) val);
	}
}
