/*
 * nextsh: the front end - lexer, parser and command tree.
 */

/*
 * Lexical analysis: tokens, aliases and here documents
 */

/*
 * lexical analysis and source input
 */



/*
 * states while lexing word
 */
#define	SINVALID	-1	/* invalid state */
#define	SBASE	0		/* outside any lexical constructs */
#define	SWORD	1		/* implicit quoting for substitute() */
#define	SLETPAREN 2		/* inside (( )), implicit quoting */
#define	SSQUOTE	3		/* inside '' */
#define	SDQUOTE	4		/* inside "" */
#define	SBRACE	5		/* inside ${} */
#define	SCSPAREN 6		/* inside $() */
#define	SBQUOTE	7		/* inside `` */
#define	SASPAREN 8		/* inside $(( )) */
#define SHEREDELIM 9		/* parsing <<,<<- delimiter */
#define SHEREDQUOTE 10		/* parsing " in <<,<<- delimiter */
#define SPATTERN 11		/* parsing *(...|...) pattern (*+?@!) */
#define STBRACE 12		/* parsing ${..[#%]..} */
#define	SBRACEQ	13		/* inside "${}" */

/* Structure to keep track of the lexing state and the various pieces of info
 * needed for each particular state.
 */
typedef struct lex_state Lex_state;
struct lex_state {
	int ls_state;
	union {
		/* $(...) */
		struct scsparen_info {
			int nparen;	/* count open parenthesis */
			int csstate;	/* XXX remove */
#define ls_scsparen ls_info.u_scsparen
		} u_scsparen;

		/* $((...)) */
		struct sasparen_info {
			int nparen;	/* count open parenthesis */
			int start;	/* marks start of $(( in output str */
#define ls_sasparen ls_info.u_sasparen
		} u_sasparen;

		/* ((...)) */
		struct sletparen_info {
			int nparen;	/* count open parenthesis */
#define ls_sletparen ls_info.u_sletparen
		} u_sletparen;

		/* `...` */
		struct sbquote_info {
			int indquotes;	/* true if in double quotes: "`...`" */
#define ls_sbquote ls_info.u_sbquote
		} u_sbquote;

		Lex_state *base;	/* used to point to next state block */
	} ls_info;
};

typedef struct State_info State_info;
struct State_info {
	Lex_state	*base;
	Lex_state	*end;
};


static void	readhere(struct ioword *);
static int	getsc__(void);
static void	getsc_line(Source *);
static int	getsc_bn(void);
static char	*get_brace_var(XString *, char *);
static int	arraysub(char **);
static const char *ungetsc(int);
static void	gethere(void);
static Lex_state *push_state_(State_info *, Lex_state *);
static Lex_state *pop_state_(State_info *, Lex_state *);
static char	*special_prompt_expand(char *);
static int	dopprompt(const char *, int, const char **, int);
int		promptlen(const char *cp, const char **spp);

static int backslash_skip;
static int ignore_backslash_newline;

Source *source;		/* yyparse/yylex source */
YYSTYPE	yylval;		/* result from yylex */
struct ioword *heres[HERES], **herep;
char	ident[IDENT+1];

char   **history;	/* saved commands */
char   **histptr;	/* last history item */
uint32_t histsize;	/* history size */

/* optimized getsc_bn() */
#define getsc()		(*source->str != '\0' && *source->str != '\\' \
			 && !backslash_skip ? *source->str++ : getsc_bn())
/* optimized getsc__() */
#define	getsc_()	((*source->str != '\0') ? *source->str++ : getsc__())

#define STATE_BSIZE	32

#define PUSH_STATE(s)	do { \
			    if (++statep == state_info.end) \
				statep = push_state_(&state_info, statep); \
			    state = statep->ls_state = (s); \
			} while (0)

#define POP_STATE()	do { \
			    if (--statep == state_info.base) \
				statep = pop_state_(&state_info, statep); \
			    state = statep->ls_state; \
			} while (0)



/*
 * Lexical analyzer
 *
 * tokens are not regular expressions, they are LL(1).
 * for example, "${var:-${PWD}}", and "$(size $(whence ksh))".
 * hence the state stack.
 */

int
yylex(int cf)
{
	Lex_state states[STATE_BSIZE], *statep;
	State_info state_info;
	int c, state;
	XString ws;		/* expandable output word */
	char *wp;		/* output word pointer */
	char *sp, *dp;
	int c2;


  Again:
	states[0].ls_state = SINVALID;
	states[0].ls_info.base = NULL;
	statep = &states[1];
	state_info.base = states;
	state_info.end = &states[STATE_BSIZE];

	Xinit(ws, wp, 64, ATEMP);

	backslash_skip = 0;
	ignore_backslash_newline = 0;

	if (cf&ONEWORD)
		state = SWORD;
	else if (cf&LETEXPR) {
		*wp++ = OQUOTE;	 /* enclose arguments in (double) quotes */
		state = SLETPAREN;
		statep->ls_sletparen.nparen = 0;
	} else {		/* normal lexing */
		state = (cf & HEREDELIM) ? SHEREDELIM : SBASE;
		while ((c = getsc()) == ' ' || c == '\t')
			;
		if (c == '#') {
			ignore_backslash_newline++;
			while ((c = getsc()) != '\0' && c != '\n')
				;
			ignore_backslash_newline--;
		}
		ungetsc(c);
	}
	if (source->flags & SF_ALIAS) {	/* trailing ' ' in alias definition */
		source->flags &= ~SF_ALIAS;
		/* In POSIX mode, a trailing space only counts if we are
		 * parsing a simple command
		 */
		if (!Flag(FPOSIX) || (cf & CMDWORD))
			cf |= ALIAS;
	}

	/* Initial state: one of SBASE SHEREDELIM SWORD SASPAREN */
	statep->ls_state = state;

	/* collect non-special or quoted characters to form word */
	while (!((c = getsc()) == 0 ||
	    ((state == SBASE || state == SHEREDELIM) && ctype(c, C_LEX1)))) {
		Xcheck(ws, wp);
		switch (state) {
		case SBASE:
			if (Flag(FCSHHISTORY) && (source->flags & SF_TTY) &&
			    c == '!') {
				char **replace = NULL;
				int get, i;
				char match[200] = { 0 }, *str = match;
				size_t mlen;

				c2 = getsc();
				if (c2 == '\0' || c2 == ' ' || c2 == '\t')
					;
				else if (c2 == '!')
					replace = hist_get_newest(0);
				else if (isdigit(c2) || c2 == '-' ||
				    isalpha(c2)) {
					get = !isalpha(c2);

					*str++ = c2;
					do {
						if ((c2 = getsc()) == '\0')
							break;
						if (c2 == '\t' || c2 == ' ' ||
						    c2 == '\n') {
							ungetsc(c2);
							break;
						}
						*str++ = c2;
					} while (str < &match[sizeof(match)-1]);
					*str = '\0';

					if (get) {
						int h = findhistrel(match);
						if (h >= 0)
							replace = &history[h];
					} else {
						int h = findhist(-1, 0, match, true);
						if (h >= 0)
							replace = &history[h];
					}
				}

				/*
				 * XXX ksh history buffer saves un-expanded
				 * commands. Until the history buffer code is
				 * changed to contain expanded commands, we
				 * ignore the bad commands (spinning sucks)
				 */
				if (replace && **replace == '!')
					ungetsc(c2);
				else if (replace) {
					Source *s;

					/* do not strdup replacement via alloc */
					s = pushs(SREREAD, source->areap);
					s->start = s->str = *replace;
					s->next = source;
					s->u.freeme = NULL;
					source = s;
					continue;
				} else if (*match != '\0') {
					/* restore what followed the '!' */
					mlen = strlen(match);
					for (i = mlen-1; i >= 0; i--)
						ungetsc(match[i]);
				} else
					ungetsc(c2);
			}
			if (c == '[' && (cf & (VARASN|ARRAYVAR))) {
				*wp = EOS; /* temporary */
				if (is_wdvarname(Xstring(ws, wp), false)) {
					char *p, *tmp;

					if (arraysub(&tmp)) {
						*wp++ = CHAR;
						*wp++ = c;
						for (p = tmp; *p; ) {
							Xcheck(ws, wp);
							*wp++ = CHAR;
							*wp++ = *p++;
						}
						afree(tmp, ATEMP);
						break;
					} else {
						Source *s;

						s = pushs(SREREAD,
							  source->areap);
						s->start = s->str
							= s->u.freeme = tmp;
						s->next = source;
						source = s;
					}
				}
				*wp++ = CHAR;
				*wp++ = c;
				break;
			}
			/* FALLTHROUGH */
		  Sbase1:	/* includes *(...|...) pattern (*+?@!) */
			if (c == '*' || c == '@' || c == '+' || c == '?' ||
			    c == '!') {
				c2 = getsc();
				if (c2 == '(' /*)*/ ) {
					*wp++ = OPAT;
					*wp++ = c;
					PUSH_STATE(SPATTERN);
					break;
				}
				ungetsc(c2);
			}
			/* FALLTHROUGH */
		  Sbase2:	/* doesn't include *(...|...) pattern (*+?@!) */
			switch (c) {
			case '\\':
				c = getsc();
				if (c) /* trailing \ is lost */
					*wp++ = QCHAR, *wp++ = c;
				break;
			case '\'':
				if ((cf & HEREDOC) || state == SBRACEQ) {
					*wp++ = CHAR, *wp++ = c;
					break;
				}
				*wp++ = OQUOTE;
				ignore_backslash_newline++;
				PUSH_STATE(SSQUOTE);
				break;
			case '"':
				*wp++ = OQUOTE;
				PUSH_STATE(SDQUOTE);
				break;
			default:
				goto Subst;
			}
			break;

		  Subst:
			switch (c) {
			case '\\':
				c = getsc();
				switch (c) {
				case '\\':
				case '$': case '`':
					*wp++ = QCHAR, *wp++ = c;
					break;
				case '"':
					if ((cf & HEREDOC) == 0) {
						*wp++ = QCHAR, *wp++ = c;
						break;
					}
					/* FALLTHROUGH */
				default:
					if (cf & UNESCAPE) {
						*wp++ = QCHAR, *wp++ = c;
						break;
					}
					Xcheck(ws, wp);
					if (c) { /* trailing \ is lost */
						*wp++ = CHAR, *wp++ = '\\';
						*wp++ = CHAR, *wp++ = c;
					}
					break;
				}
				break;
			case '$':
				c = getsc();
				if (c == '(') /*)*/ {
					c = getsc();
					if (c == '(') /*)*/ {
						PUSH_STATE(SASPAREN);
						statep->ls_sasparen.nparen = 2;
						statep->ls_sasparen.start =
						    Xsavepos(ws, wp);
						*wp++ = EXPRSUB;
					} else {
						ungetsc(c);
						PUSH_STATE(SCSPAREN);
						statep->ls_scsparen.nparen = 1;
						statep->ls_scsparen.csstate = 0;
						*wp++ = COMSUB;
					}
				} else if (c == '{') /*}*/ {
					*wp++ = OSUBST;
					*wp++ = '{'; /*}*/
					wp = get_brace_var(&ws, wp);
					c = getsc();
					/* allow :# and :% (ksh88 compat) */
					if (c == ':') {
						*wp++ = CHAR, *wp++ = c;
						c = getsc();
					}
					/* If this is a trim operation,
					 * treat (,|,) specially in STBRACE.
					 */
					if (c == '#' || c == '%') {
						ungetsc(c);
						PUSH_STATE(STBRACE);
					} else {
						ungetsc(c);
						if (state == SDQUOTE ||
						    state == SBRACEQ)
							PUSH_STATE(SBRACEQ);
						else
							PUSH_STATE(SBRACE);
					}
				} else if (ctype(c, C_ALPHA)) {
					*wp++ = OSUBST;
					*wp++ = 'X';
					do {
						Xcheck(ws, wp);
						*wp++ = c;
						c = getsc();
					} while (ctype(c, C_ALPHA) || digit(c));
					*wp++ = '\0';
					*wp++ = CSUBST;
					*wp++ = 'X';
					ungetsc(c);
				} else if (ctype(c, C_VAR1) || digit(c)) {
					Xcheck(ws, wp);
					*wp++ = OSUBST;
					*wp++ = 'X';
					*wp++ = c;
					*wp++ = '\0';
					*wp++ = CSUBST;
					*wp++ = 'X';
				} else {
					*wp++ = CHAR, *wp++ = '$';
					ungetsc(c);
				}
				break;
			case '`':
				PUSH_STATE(SBQUOTE);
				*wp++ = COMSUB;
				/* Need to know if we are inside double quotes
				 * since sh/at&t-ksh translate the \" to " in
				 * "`..\"..`".
				 */
				statep->ls_sbquote.indquotes = 0;
				Lex_state *s = statep;
				Lex_state *base = state_info.base;
				while (1) {
					for (; s != base; s--) {
						if (s->ls_state == SDQUOTE) {
							statep->ls_sbquote.indquotes = 1;
							break;
						}
					}
					if (s != base)
						break;
					if (!(s = s->ls_info.base))
						break;
					base = s-- - STATE_BSIZE;
				}
				break;
			default:
				*wp++ = CHAR, *wp++ = c;
			}
			break;

		case SSQUOTE:
			if (c == '\'') {
				POP_STATE();
				if (state == SBRACEQ) {
					*wp++ = CHAR, *wp++ = c;
					break;
				}
				*wp++ = CQUOTE;
				ignore_backslash_newline--;
			} else
				*wp++ = QCHAR, *wp++ = c;
			break;

		case SDQUOTE:
			if (c == '"') {
				POP_STATE();
				*wp++ = CQUOTE;
			} else
				goto Subst;
			break;

		case SCSPAREN: /* $( .. ) */
			/* todo: deal with $(...) quoting properly
			 * kludge to partly fake quoting inside $(..): doesn't
			 * really work because nested $(..) or ${..} inside
			 * double quotes aren't dealt with.
			 */
			switch (statep->ls_scsparen.csstate) {
			case 0: /* normal */
				switch (c) {
				case '(':
					statep->ls_scsparen.nparen++;
					break;
				case ')':
					statep->ls_scsparen.nparen--;
					break;
				case '\\':
					statep->ls_scsparen.csstate = 1;
					break;
				case '"':
					statep->ls_scsparen.csstate = 2;
					break;
				case '\'':
					statep->ls_scsparen.csstate = 4;
					ignore_backslash_newline++;
					break;
				}
				break;

			case 1: /* backslash in normal mode */
			case 3: /* backslash in double quotes */
				--statep->ls_scsparen.csstate;
				break;

			case 2: /* double quotes */
				if (c == '"')
					statep->ls_scsparen.csstate = 0;
				else if (c == '\\')
					statep->ls_scsparen.csstate = 3;
				break;

			case 4: /* single quotes */
				if (c == '\'') {
					statep->ls_scsparen.csstate = 0;
					ignore_backslash_newline--;
				}
				break;
			}
			if (statep->ls_scsparen.nparen == 0) {
				POP_STATE();
				*wp++ = 0; /* end of COMSUB */
			} else
				*wp++ = c;
			break;

		case SASPAREN: /* $(( .. )) */
			/* todo: deal with $((...); (...)) properly */
			/* XXX should nest using existing state machine
			 * (embed "..", $(...), etc.) */
			if (c == '(')
				statep->ls_sasparen.nparen++;
			else if (c == ')') {
				statep->ls_sasparen.nparen--;
				if (statep->ls_sasparen.nparen == 1) {
					/*(*/
					if ((c2 = getsc()) == ')') {
						POP_STATE();
						*wp++ = 0; /* end of EXPRSUB */
						break;
					} else {
						char *s;

						ungetsc(c2);
						/* mismatched parenthesis -
						 * assume we were really
						 * parsing a $(..) expression
						 */
						s = Xrestpos(ws, wp,
						    statep->ls_sasparen.start);
						memmove(s + 1, s, wp - s);
						*s++ = COMSUB;
						*s = '('; /*)*/
						wp++;
						statep->ls_scsparen.nparen = 1;
						statep->ls_scsparen.csstate = 0;
						state = statep->ls_state =
						    SCSPAREN;
					}
				}
			}
			*wp++ = c;
			break;

		case SBRACEQ:
			/*{*/
			if (c == '}') {
				POP_STATE();
				*wp++ = CSUBST;
				*wp++ = /*{*/ '}';
			} else
				goto Sbase2;
			break;

		case SBRACE:
			/*{*/
			if (c == '}') {
				POP_STATE();
				*wp++ = CSUBST;
				*wp++ = /*{*/ '}';
			} else
				goto Sbase1;
			break;

		case STBRACE:
			/* Same as SBRACE, except (,|,) treated specially */
			/*{*/
			if (c == '}') {
				POP_STATE();
				*wp++ = CSUBST;
				*wp++ = /*{*/ '}';
			} else if (c == '|') {
				*wp++ = SPAT;
			} else if (c == '(') {
				*wp++ = OPAT;
				*wp++ = ' ';	/* simile for @ */
				PUSH_STATE(SPATTERN);
			} else
				goto Sbase1;
			break;

		case SBQUOTE:
			if (c == '`') {
				*wp++ = 0;
				POP_STATE();
			} else if (c == '\\') {
				switch (c = getsc()) {
				case '\\':
				case '$': case '`':
					*wp++ = c;
					break;
				case '"':
					if (statep->ls_sbquote.indquotes) {
						*wp++ = c;
						break;
					}
					/* FALLTHROUGH */
				default:
					if (c) { /* trailing \ is lost */
						*wp++ = '\\';
						*wp++ = c;
					}
					break;
				}
			} else
				*wp++ = c;
			break;

		case SWORD:	/* ONEWORD */
			goto Subst;

		case SLETPAREN:	/* LETEXPR: (( ... )) */
			/*(*/
			if (c == ')') {
				if (statep->ls_sletparen.nparen > 0)
				    --statep->ls_sletparen.nparen;
				/*(*/
				else if ((c2 = getsc()) == ')') {
					c = 0;
					*wp++ = CQUOTE;
					goto Done;
				} else
					ungetsc(c2);
			} else if (c == '(')
				/* parenthesis inside quotes and backslashes
				 * are lost, but at&t ksh doesn't count them
				 * either
				 */
				++statep->ls_sletparen.nparen;
			goto Sbase2;

		case SHEREDELIM:	/* <<,<<- delimiter */
			/* XXX chuck this state (and the next) - use
			 * the existing states ($ and \`..` should be
			 * stripped of their specialness after the
			 * fact).
			 */
			/* here delimiters need a special case since
			 * $ and `..` are not to be treated specially
			 */
			if (c == '\\') {
				c = getsc();
				if (c) { /* trailing \ is lost */
					*wp++ = QCHAR;
					*wp++ = c;
				}
			} else if (c == '\'') {
				PUSH_STATE(SSQUOTE);
				*wp++ = OQUOTE;
				ignore_backslash_newline++;
			} else if (c == '"') {
				state = statep->ls_state = SHEREDQUOTE;
				*wp++ = OQUOTE;
			} else {
				*wp++ = CHAR;
				*wp++ = c;
			}
			break;

		case SHEREDQUOTE:	/* " in <<,<<- delimiter */
			if (c == '"') {
				*wp++ = CQUOTE;
				state = statep->ls_state = SHEREDELIM;
			} else {
				if (c == '\\') {
					switch (c = getsc()) {
					case '\\': case '"':
					case '$': case '`':
						break;
					default:
						if (c) { /* trailing \ lost */
							*wp++ = CHAR;
							*wp++ = '\\';
						}
						break;
					}
				}
				*wp++ = CHAR;
				*wp++ = c;
			}
			break;

		case SPATTERN:	/* in *(...|...) pattern (*+?@!) */
			if ( /*(*/ c == ')') {
				*wp++ = CPAT;
				POP_STATE();
			} else if (c == '|') {
				*wp++ = SPAT;
			} else if (c == '(') {
				*wp++ = OPAT;
				*wp++ = ' ';	/* simile for @ */
				PUSH_STATE(SPATTERN);
			} else
				goto Sbase1;
			break;
		}
	}
Done:
	Xcheck(ws, wp);
	if (statep != &states[1])
		/* XXX figure out what is missing */
		yyerror("no closing quote\n");

	/* This done to avoid tests for SHEREDELIM wherever SBASE tested */
	if (state == SHEREDELIM)
		state = SBASE;

	dp = Xstring(ws, wp);
	if ((c == '<' || c == '>') && state == SBASE &&
	    ((c2 = Xlength(ws, wp)) == 0 ||
	    (c2 == 2 && dp[0] == CHAR && digit(dp[1])))) {
		struct ioword *iop = alloc(sizeof(*iop), ATEMP);

		if (c2 == 2)
			iop->unit = dp[1] - '0';
		else
			iop->unit = c == '>'; /* 0 for <, 1 for > */

		c2 = getsc();
		/* <<, >>, <> are ok, >< is not */
		if (c == c2 || (c == '<' && c2 == '>')) {
			iop->flag = c == c2 ?
			    (c == '>' ? IOCAT : IOHERE) : IORDWR;
			if (iop->flag == IOHERE) {
				if ((c2 = getsc()) == '-')
					iop->flag |= IOSKIP;
				else
					ungetsc(c2);
			}
		} else if (c2 == '&')
			iop->flag = IODUP | (c == '<' ? IORDUP : 0);
		else {
			iop->flag = c == '>' ? IOWRITE : IOREAD;
			if (c == '>' && c2 == '|')
				iop->flag |= IOCLOB;
			else
				ungetsc(c2);
		}

		iop->name = NULL;
		iop->delim = NULL;
		iop->heredoc = NULL;
		Xfree(ws, wp);	/* free word */
		yylval.iop = iop;
		return REDIR;
	}

	if (wp == dp && state == SBASE) {
		Xfree(ws, wp);	/* free word */
		/* no word, process LEX1 character */
		switch (c) {
		default:
			return c;

		case '|':
		case '&':
		case ';':
			if ((c2 = getsc()) == c)
				c = (c == ';') ? BREAK :
				    (c == '|') ? LOGOR :
				    (c == '&') ? LOGAND :
				    YYERRCODE;
			else if (c == '|' && c2 == '&')
				c = COPROC;
			else
				ungetsc(c2);
			return c;

		case '\n':
			gethere();
			if (cf & CONTIN)
				goto Again;
			return c;

		case '(':  /*)*/
			if ((c2 = getsc()) == '(') /*)*/
				/* XXX need to handle ((...); (...)) */
				c = MDPAREN;
			else
				ungetsc(c2);
			return c;
		  /*(*/
		case ')':
			return c;
		}
	}

	*wp++ = EOS;		/* terminate word */
	yylval.cp = Xclose(ws, wp);
	if (state == SWORD || state == SLETPAREN)	/* ONEWORD? */
		return LWORD;
	ungetsc(c);		/* unget terminator */

	/* copy word to unprefixed string ident */
	for (sp = yylval.cp, dp = ident; dp < ident+IDENT && (c = *sp++) == CHAR; )
		*dp++ = *sp++;
	/* Make sure the ident array stays '\0' padded */
	memset(dp, 0, (ident+IDENT) - dp + 1);
	if (c != EOS)
		*ident = '\0';	/* word is not unquoted */

	if (*ident != '\0' && (cf&(KEYWORD|ALIAS))) {
		struct tbl *p;
		int h = hash(ident);

		/* { */
		if ((cf & KEYWORD) && (p = ktsearch(&keywords, ident, h)) &&
		    (!(cf & ESACONLY) || p->val.i == ESAC || p->val.i == '}')) {
			afree(yylval.cp, ATEMP);
			return p->val.i;
		}
		if ((cf & ALIAS) && (p = ktsearch(&aliases, ident, h)) &&
		    (p->flag & ISSET)) {
			Source *s;

			for (s = source; s->type == SALIAS; s = s->next)
				if (s->u.tblp == p)
					return LWORD;
			/* push alias expansion */
			s = pushs(SALIAS, source->areap);
			s->start = s->str = p->val.s;
			s->u.tblp = p;
			s->next = source;
			source = s;
			afree(yylval.cp, ATEMP);
			goto Again;
		}
	}

	return LWORD;
}

static void
gethere(void)
{
	struct ioword **p;

	for (p = heres; p < herep; p++)
		readhere(*p);
	herep = heres;
}

/*
 * read "<<word" text into temp file
 */

static void
readhere(struct ioword *iop)
{
	int c;
	char *volatile eof;
	char *eofp;
	int skiptabs;
	XString xs;
	char *xp;
	int xpos;

	eof = evalstr(iop->delim, 0);

	if (!(iop->flag & IOEVAL))
		ignore_backslash_newline++;

	Xinit(xs, xp, 256, ATEMP);

	for (;;) {
		eofp = eof;
		skiptabs = iop->flag & IOSKIP;
		xpos = Xsavepos(xs, xp);
		while ((c = getsc()) != 0) {
			if (skiptabs) {
				if (c == '\t')
					continue;
				skiptabs = 0;
			}
			if (c != *eofp)
				break;
			Xcheck(xs, xp);
			Xput(xs, xp, c);
			eofp++;
		}
		/* Allow EOF here so commands with out trailing newlines
		 * will work (eg, ksh -c '...', $(...), etc).
		 */
		if (*eofp == '\0' && (c == 0 || c == '\n')) {
			xp = Xrestpos(xs, xp, xpos);
			break;
		}
		ungetsc(c);
		while ((c = getsc()) != '\n') {
			if (c == 0)
				yyerror("here document `%s' unclosed\n", eof);
			Xcheck(xs, xp);
			Xput(xs, xp, c);
		}
		Xcheck(xs, xp);
		Xput(xs, xp, c);
	}
	Xput(xs, xp, '\0');
	iop->heredoc = Xclose(xs, xp);

	if (!(iop->flag & IOEVAL))
		ignore_backslash_newline--;
}

void
yyerror(const char *fmt, ...)
{
	va_list va;

	/* pop aliases and re-reads */
	while (source->type == SALIAS || source->type == SREREAD)
		source = source->next;
	source->str = null;	/* zap pending input */

	error_prefix(true);
	va_start(va, fmt);
	shf_vfprintf(shl_out, fmt, va);
	va_end(va);
	errorf(NULL);
}

/*
 * input for yylex with alias expansion
 */

Source *
pushs(int type, Area *areap)
{
	Source *s;

	s = alloc(sizeof(Source), areap);
	s->type = type;
	s->str = null;
	s->start = NULL;
	s->line = 0;
	s->cmd_offset = 0;
	s->errline = 0;
	s->file = NULL;
	s->flags = 0;
	s->next = NULL;
	s->areap = areap;
	if (type == SFILE || type == SSTDIN)
		Xinitn(s->xs, 256, s->areap);
	else
		memset(&s->xs, 0, sizeof(s->xs));
	return s;
}

static int
getsc__(void)
{
	Source *s = source;
	int c;

	while ((c = *s->str++) == 0) {
		s->str = NULL;		/* return 0 for EOF by default */
		switch (s->type) {
		case SEOF:
			s->str = null;
			return 0;

		case SSTDIN:
		case SFILE:
			getsc_line(s);
			break;

		case SWSTR:
			break;

		case SSTRING:
			break;

		case SWORDS:
			s->start = s->str = *s->u.strv++;
			s->type = SWORDSEP;
			break;

		case SWORDSEP:
			if (*s->u.strv == NULL) {
				s->start = s->str = "\n";
				s->type = SEOF;
			} else {
				s->start = s->str = " ";
				s->type = SWORDS;
			}
			break;

		case SALIAS:
			if (s->flags & SF_ALIASEND) {
				/* pass on an unused SF_ALIAS flag */
				source = s->next;
				source->flags |= s->flags & SF_ALIAS;
				s = source;
			} else if (*s->u.tblp->val.s &&
			    isspace((unsigned char)strchr(s->u.tblp->val.s, 0)[-1])) {
				source = s = s->next;	/* pop source stack */
				/* Note that this alias ended with a space,
				 * enabling alias expansion on the following
				 * word.
				 */
				s->flags |= SF_ALIAS;
			} else {
				/* At this point, we need to keep the current
				 * alias in the source list so recursive
				 * aliases can be detected and we also need
				 * to return the next character.  Do this
				 * by temporarily popping the alias to get
				 * the next character and then put it back
				 * in the source list with the SF_ALIASEND
				 * flag set.
				 */
				source = s->next;	/* pop source stack */
				source->flags |= s->flags & SF_ALIAS;
				c = getsc__();
				if (c) {
					s->flags |= SF_ALIASEND;
					s->ugbuf[0] = c; s->ugbuf[1] = '\0';
					s->start = s->str = s->ugbuf;
					s->next = source;
					source = s;
				} else {
					s = source;
					/* avoid reading eof twice */
					s->str = NULL;
					break;
				}
			}
			continue;

		case SREREAD:
			if (s->start != s->ugbuf) /* yuck */
				afree(s->u.freeme, ATEMP);
			source = s = s->next;
			continue;
		}
		if (s->str == NULL) {
			s->type = SEOF;
			s->start = s->str = null;
			return '\0';
		}
		if (s->flags & SF_ECHO) {
			shf_puts(s->str, shl_out);
			shf_flush(shl_out);
		}
	}
	return c;
}

static void
getsc_line(Source *s)
{
	char *xp = Xstring(s->xs, xp);
	int interactive = Flag(FTALKING) && s->type == SSTDIN;
	int have_tty = interactive && (s->flags & SF_TTY);

	/* Done here to ensure nothing odd happens when a timeout occurs */
	XcheckN(s->xs, xp, LINE);
	*xp = '\0';
	s->start = s->str = xp;

	if (have_tty && ksh_tmout) {
		ksh_tmout_state = TMOUT_READING;
		alarm(ksh_tmout);
	}
	if (have_tty && (0
	    || Flag(FVI)
	    || Flag(FEMACS) || Flag(FGMACS)
	    )) {
		int nread;

		nread = x_read(xp, LINE);
		if (nread < 0)	/* read error */
			nread = 0;
		xp[nread] = '\0';
		xp += nread;
	} else {
		if (interactive) {
			pprompt(prompt, 0);
		} else
			s->line++;

		while (1) {
			char *p = shf_getse(xp, Xnleft(s->xs, xp), s->u.shf);

			if (!p && shf_error(s->u.shf) &&
			    s->u.shf->errno_ == EINTR) {
				shf_clearerr(s->u.shf);
				if (trap)
					runtraps(0);
				continue;
			}
			if (!p || (xp = p, xp[-1] == '\n'))
				break;
			/* double buffer size */
			xp++; /* move past null so doubling works... */
			XcheckN(s->xs, xp, Xlength(s->xs, xp));
			xp--; /* ...and move back again */
		}
		/* flush any unwanted input so other programs/builtins
		 * can read it.  Not very optimal, but less error prone
		 * than flushing else where, dealing with redirections,
		 * etc..
		 * todo: reduce size of shf buffer (~128?) if SSTDIN
		 */
		if (s->type == SSTDIN)
			shf_flush(s->u.shf);
	}
	/* XXX: temporary kludge to restore source after a
	 * trap may have been executed.
	 */
	source = s;
	if (have_tty && ksh_tmout) {
		ksh_tmout_state = TMOUT_EXECUTING;
		alarm(0);
	}
	s->start = s->str = Xstring(s->xs, xp);
	strip_nuls(Xstring(s->xs, xp), Xlength(s->xs, xp));
	/* Note: if input is all nulls, this is not eof */
	if (Xlength(s->xs, xp) == 0) { /* EOF */
		if (s->type == SFILE)
			shf_fdclose(s->u.shf);
		s->str = NULL;
	} else if (interactive) {
		char *p = Xstring(s->xs, xp);
		if (cur_prompt == PS1)
			while (*p && ctype(*p, C_IFS) && ctype(*p, C_IFSWS))
				p++;
		if (*p) {
			s->line++;
			histsave(s->line, s->str, 1);
		}
	}
	if (interactive)
		set_prompt(PS2);
}

static char *
special_prompt_expand(char *str)
{
	char *p = str;

	while ((p = strstr(p, "\\$")) != NULL) {
		*(p+1) = 'p';
	}
	return str;
}

void
set_prompt(int to)
{
	char *ps1;
	Area *saved_atemp;

	cur_prompt = to;

	switch (to) {
	case PS1: /* command */
		ps1 = str_save(str_val(global("PS1")), ATEMP);
		saved_atemp = ATEMP;	/* ps1 is freed by substitute() */
		newenv(E_ERRH);
		if (sigsetjmp(genv->jbuf, 0)) {
			prompt = safe_prompt;
			/* Don't print an error - assume it has already
			 * been printed.  Reason is we may have forked
			 * to run a command and the child may be
			 * unwinding its stack through this code as it
			 * exits.
			 */
		} else {
			/* expand \$ before other substitutions are done */
			char *tmp = special_prompt_expand(ps1);
			prompt = str_save(substitute(tmp, 0), saved_atemp);
		}
		quitenv(NULL);
		break;
	case PS2: /* command continuation */
		prompt = str_val(global("PS2"));
		break;
	}
}

static int
dopprompt(const char *sp, int ntruncate, const char **spp, int doprint)
{
	char strbuf[1024], tmpbuf[1024], *p, *str, nbuf[32], delimiter = '\0';
	int len, c, n, totlen = 0, indelimit = 0, counting = 1, delimitthis;
	const char *cp = sp, *cq;
	struct tm *tm;
	time_t t;

	if (*cp && cp[1] == '\r') {
		delimiter = *cp;
		cp += 2;
	}

	while (*cp != 0) {
		delimitthis = 0;
		if (indelimit && *cp != delimiter)
			;
		else if (*cp == '\n' || *cp == '\r') {
			totlen = 0;
			sp = cp + 1;
		} else if (*cp == '\t') {
			if (counting)
				totlen = (totlen | 7) + 1;
		} else if (*cp == delimiter) {
			indelimit = !indelimit;
			delimitthis = 1;
		}

		if (*cp == '\\') {
			cp++;
			if (!*cp)
				break;
			switch (*cp) {
			case 'a':	/* '\' 'a' bell */
				strbuf[0] = '\007';
				strbuf[1] = '\0';
				break;
			case 'd':	/* '\' 'd' Dow Mon DD */
				time(&t);
				tm = localtime(&t);
				if (tm)
					strftime(strbuf, sizeof strbuf,
					    "%a %b %d", tm);
				else
					strbuf[0] = '\0';
				break;
			case 'D': /* '\' 'D' '{' strftime format '}' */
				cq = strchr(cp + 2, '}');
				if (cp[1] != '{' || cq == NULL) {
					snprintf(strbuf, sizeof strbuf,
					    "\\%c", *cp);
					break;
				}
				strlcpy(tmpbuf, cp + 2, sizeof tmpbuf);
				p = strchr(tmpbuf, '}');
				if (p)
					*p = '\0';
				time(&t);
				tm = localtime(&t);
				if (tm)
					strftime(strbuf, sizeof strbuf, tmpbuf,
					    tm);
				else
					strbuf[0] = '\0';
				cp = strchr(cp + 2, '}');
				break;
			case 'e':	/* '\' 'e' escape */
				strbuf[0] = '\033';
				strbuf[1] = '\0';
				break;
			case 'h':	/* '\' 'h' shortened hostname */
				gethostname(strbuf, sizeof strbuf);
				p = strchr(strbuf, '.');
				if (p)
					*p = '\0';
				break;
			case 'H':	/* '\' 'H' full hostname */
				gethostname(strbuf, sizeof strbuf);
				break;
			case 'j':	/* '\' 'j' number of jobs */
				snprintf(strbuf, sizeof strbuf, "%d",
				    j_njobs());
				break;
			case 'l':	/* '\' 'l' basename of tty */
				p = ttyname(0);
				if (p)
					strlcpy(strbuf, sh_basename(p),
					    sizeof strbuf);
				break;
			case 'n':	/* '\' 'n' newline */
				strbuf[0] = '\n';
				strbuf[1] = '\0';
				totlen = 0;	/* reset for prompt re-print */
				sp = cp + 1;
				break;
			case 'p':	/* '\' '$' $ or # */
				strbuf[0] = ksheuid ? '$' : '#';
				strbuf[1] = '\0';
				break;
			case 'r':	/* '\' 'r' return */
				strbuf[0] = '\r';
				strbuf[1] = '\0';
				totlen = 0;	/* reset for prompt re-print */
				sp = cp + 1;
				break;
			case 's':	/* '\' 's' basename $0 */
				strlcpy(strbuf, kshname, sizeof strbuf);
				break;
			case 't':	/* '\' 't' 24 hour HH:MM:SS */
				time(&t);
				tm = localtime(&t);
				if (tm)
					strftime(strbuf, sizeof strbuf, "%T",
					    tm);
				else
					strbuf[0] = '\0';
				break;
			case 'T':	/* '\' 'T' 12 hour HH:MM:SS */
				time(&t);
				tm = localtime(&t);
				if (tm)
					strftime(strbuf, sizeof strbuf,
					    "%l:%M:%S", tm);
				else
					strbuf[0] = '\0';
				break;
			case '@':	/* '\' '@' 12 hour am/pm format */
				time(&t);
				tm = localtime(&t);
				if (tm)
					strftime(strbuf, sizeof strbuf, "%r",
					    tm);
				else
					strbuf[0] = '\0';
				break;
			case 'A':	/* '\' 'A' 24 hour HH:MM */
				time(&t);
				tm = localtime(&t);
				if (tm)
					strftime(strbuf, sizeof strbuf, "%R",
					    tm);
				else
					strbuf[0] = '\0';
				break;
			case 'u':	/* '\' 'u' username */
				strlcpy(strbuf, username, sizeof strbuf);
				break;
			case 'v':	/* '\' 'v' version (short) */
				cq = strchr(ksh_version, ' ');
				if (cq)
					cq = strchr(cq + 1, ' ');
				if (cq) {
					cq++;
					strlcpy(strbuf, cq, sizeof strbuf);
					p = strchr(strbuf, ' ');
					if (p)
						*p = '\0';
				}
				break;
			case 'V':	/* '\' 'V' version (long) */
				strlcpy(strbuf, ksh_version, sizeof strbuf);
				break;
			case 'w':	/* '\' 'w' cwd */
				p = str_val(global("PWD"));
				n = strlen(str_val(global("HOME")));
				if (strcmp(p, "/") == 0) {
					strlcpy(strbuf, p, sizeof strbuf);
				} else if (strcmp(p, str_val(global("HOME"))) == 0) {
					strbuf[0] = '~';
					strbuf[1] = '\0';
				} else if (strncmp(p, str_val(global("HOME")), n)
				    == 0 && p[n] == '/') {
					snprintf(strbuf, sizeof strbuf, "~/%s",
					    str_val(global("PWD")) + n + 1);
				} else
					strlcpy(strbuf, p, sizeof strbuf);
				break;
			case 'W':	/* '\' 'W' basename(cwd) */
				p = str_val(global("PWD"));
				if (strcmp(p, str_val(global("HOME"))) == 0) {
					strbuf[0] = '~';
					strbuf[1] = '\0';
				} else
					strlcpy(strbuf, sh_basename(p), sizeof strbuf);
				break;
			case '!':	/* '\' '!' history line number */
				snprintf(strbuf, sizeof strbuf, "%d",
				    source->line + 1);
				break;
			case '#':	/* '\' '#' command line number */
				snprintf(strbuf, sizeof strbuf, "%d",
				    source->line - source->cmd_offset + 1);
				break;
			case '0':	/* '\' '#' '#' ' #' octal numeric handling */
			case '1':
			case '2':
			case '3':
			case '4':
			case '5':
			case '6':
			case '7':
				if ((cp[1] > '7' || cp[1] < '0') ||
				    (cp[2] > '7' || cp[2] < '0')) {
					snprintf(strbuf, sizeof strbuf,
					    "\\%c", *cp);
					break;
				}
				n = (cp[0] - '0') * 8 * 8 + (cp[1] - '0') * 8 +
				    (cp[2] - '0');
				snprintf(strbuf, sizeof strbuf, "%c", n);
				cp += 2;
				break;
			case '\\':	/* '\' '\' */
				strbuf[0] = '\\';
				strbuf[1] = '\0';
				break;
			case '[': /* '\' '[' .... stop counting */
				strbuf[0] = '\0';
				counting = 0;
				break;
			case ']': /* '\' ']' restart counting */
				strbuf[0] = '\0';
				counting = 1;
				break;

			default:
				snprintf(strbuf, sizeof strbuf, "\\%c", *cp);
				break;
			}
			cp++;

			str = strbuf;
			len = strlen(str);
			if (ntruncate) {
				if (ntruncate >= len) {
					ntruncate -= len;
					continue;
				}
				str += ntruncate;
				len -= ntruncate;
				ntruncate = 0;
			}
			if (doprint)
				shf_write(str, len, shl_out);
			if (counting && !indelimit && !delimitthis)
				totlen += len;
			continue;
		} else if (*cp != '!')
			c = *cp++;
		else if (*++cp == '!')
			c = *cp++;
		else {
			shf_snprintf(p = nbuf, sizeof(nbuf), "%d",
			    source->line + 1);
			len = strlen(nbuf);
			if (ntruncate) {
				if (ntruncate >= len) {
					ntruncate -= len;
					continue;
				}
				p += ntruncate;
				len -= ntruncate;
				ntruncate = 0;
			}
			if (doprint)
				shf_write(p, len, shl_out);
			if (counting && !indelimit && !delimitthis)
				totlen += len;
			continue;
		}
		if (counting && ntruncate)
			--ntruncate;
		else if (doprint) {
			shf_putc(c, shl_out);
		}
		if (counting && !indelimit && !delimitthis)
			totlen++;
	}
	if (doprint)
		shf_flush(shl_out);
	if (spp)
		*spp = sp;
	return (totlen);
}

void
pprompt(const char *cp, int ntruncate)
{
	dopprompt(cp, ntruncate, NULL, 1);
}

int
promptlen(const char *cp, const char **spp)
{
	return dopprompt(cp, 0, spp, 0);
}

/* Read the variable part of a ${...} expression (ie, up to but not including
 * the :[-+?=#%] or close-brace.
 */
static char *
get_brace_var(XString *wsp, char *wp)
{
	enum parse_state {
			   PS_INITIAL, PS_SAW_HASH, PS_IDENT,
			   PS_NUMBER, PS_VAR1, PS_END
			 }
		state;
	char c;

	state = PS_INITIAL;
	while (1) {
		c = getsc();
		/* State machine to figure out where the variable part ends. */
		switch (state) {
		case PS_INITIAL:
			if (c == '#') {
				state = PS_SAW_HASH;
				break;
			}
			/* FALLTHROUGH */
		case PS_SAW_HASH:
			if (letter(c))
				state = PS_IDENT;
			else if (digit(c))
				state = PS_NUMBER;
			else if (ctype(c, C_VAR1))
				state = PS_VAR1;
			else
				state = PS_END;
			break;
		case PS_IDENT:
			if (!letnum(c)) {
				state = PS_END;
				if (c == '[') {
					char *tmp, *p;

					if (!arraysub(&tmp))
						yyerror("missing ]\n");
					*wp++ = c;
					for (p = tmp; *p; ) {
						Xcheck(*wsp, wp);
						*wp++ = *p++;
					}
					afree(tmp, ATEMP);
					c = getsc(); /* the ] */
				}
			}
			break;
		case PS_NUMBER:
			if (!digit(c))
				state = PS_END;
			break;
		case PS_VAR1:
			state = PS_END;
			break;
		case PS_END: /* keep gcc happy */
			break;
		}
		if (state == PS_END) {
			*wp++ = '\0';	/* end of variable part */
			ungetsc(c);
			break;
		}
		Xcheck(*wsp, wp);
		*wp++ = c;
	}
	return wp;
}

/*
 * Save an array subscript - returns true if matching bracket found, false
 * if eof or newline was found.
 * (Returned string double null terminated)
 */
static int
arraysub(char **strp)
{
	XString ws;
	char	*wp;
	char	c;
	int	depth = 1;	/* we are just past the initial [ */

	Xinit(ws, wp, 32, ATEMP);

	do {
		c = getsc();
		Xcheck(ws, wp);
		*wp++ = c;
		if (c == '[')
			depth++;
		else if (c == ']')
			depth--;
	} while (depth > 0 && c && c != '\n');

	*wp++ = '\0';
	*strp = Xclose(ws, wp);

	return depth == 0 ? 1 : 0;
}

/* Unget a char: handles case when we are already at the start of the buffer */
static const char *
ungetsc(int c)
{
	if (backslash_skip)
		backslash_skip--;
	/* Don't unget eof... */
	if (source->str == null && c == '\0')
		return source->str;
	if (source->str > source->start)
		source->str--;
	else {
		Source *s;

		s = pushs(SREREAD, source->areap);
		s->ugbuf[0] = c; s->ugbuf[1] = '\0';
		s->start = s->str = s->ugbuf;
		s->next = source;
		source = s;
	}
	return source->str;
}


/* Called to get a char that isn't a \newline sequence. */
static int
getsc_bn(void)
{
	int c, c2;

	if (ignore_backslash_newline)
		return getsc_();

	if (backslash_skip == 1) {
		backslash_skip = 2;
		return getsc_();
	}

	backslash_skip = 0;

	while (1) {
		c = getsc_();
		if (c == '\\') {
			if ((c2 = getsc_()) == '\n')
				/* ignore the \newline; get the next char... */
				continue;
			ungetsc(c2);
			backslash_skip = 1;
		}
		return c;
	}
}

static Lex_state *
push_state_(State_info *si, Lex_state *old_end)
{
	Lex_state *new = areallocarray(NULL, STATE_BSIZE,
	    sizeof(Lex_state), ATEMP);

	new[0].ls_info.base = old_end;
	si->base = &new[0];
	si->end = &new[STATE_BSIZE];
	return &new[1];
}

static Lex_state *
pop_state_(State_info *si, Lex_state *old_end)
{
	Lex_state *old_base = si->base;

	si->base = old_end->ls_info.base - STATE_BSIZE;
	si->end = old_end->ls_info.base;

	afree(old_base, ATEMP);

	return si->base + STATE_BSIZE - 1;
}

/*
 * Syntax analysis: build the command tree
 */

/*
 * shell parser (C version)
 */



struct nesting_state {
	int	start_token;	/* token than began nesting (eg, FOR) */
	int	start_line;	/* line nesting began on */
};

static void	yyparse(void);
static struct op *pipeline(int);
static struct op *andor(void);
static struct op *c_list(int);
static struct ioword *synio(int);
static void	musthave(int, int);
static struct op *nested(int, int, int);
static struct op *get_command(int);
static struct op *dogroup(void);
static struct op *thenpart(void);
static struct op *elsepart(void);
static struct op *caselist(void);
static struct op *casepart(int);
static struct op *function_body(char *, int);
static char **	wordlist(void);
static struct op *block(int, struct op *, struct op *, char **);
static struct op *newtp(int);
static void	syntaxerr(const char *) __attribute__((__noreturn__));
static void	nesting_push(struct nesting_state *, int);
static void	nesting_pop(struct nesting_state *);
static int	assign_command(char *);
static int	inalias(struct source *);
static int	dbtestp_isa(Test_env *, Test_meta);
static const char *dbtestp_getopnd(Test_env *, Test_op, int);
static int	dbtestp_eval(Test_env *, Test_op, const char *, const char *,
		    int);
static void	dbtestp_error(Test_env *, int, const char *);

static	struct	op	*outtree; /* yyparse output */

static struct nesting_state nesting;	/* \n changed to ; */

static	int	reject;		/* token(cf) gets symbol again */
static	int	symbol;		/* yylex value */

#define	token(cf) \
	((reject) ? (reject = false, symbol) : (symbol = yylex(cf)))
#define	tpeek(cf) \
	((reject) ? (symbol) : (reject = true, symbol = yylex(cf)))

static void
yyparse(void)
{
	int c;

	reject = false;

	outtree = c_list(source->type == SSTRING);
	c = tpeek(0);
	if (c == 0 && !outtree)
		outtree = newtp(TEOF);
	else if (c != '\n' && c != 0)
		syntaxerr(NULL);
}

static struct op *
pipeline(int cf)
{
	struct op *t, *p, *tl = NULL;

	t = get_command(cf);
	if (t != NULL) {
		while (token(0) == '|') {
			if ((p = get_command(CONTIN)) == NULL)
				syntaxerr(NULL);
			if (tl == NULL)
				t = tl = block(TPIPE, t, p, NULL);
			else
				tl = tl->right = block(TPIPE, tl->right, p, NULL);
		}
		reject = true;
	}
	return (t);
}

static struct op *
andor(void)
{
	struct op *t, *p;
	int c;

	t = pipeline(0);
	if (t != NULL) {
		while ((c = token(0)) == LOGAND || c == LOGOR) {
			if ((p = pipeline(CONTIN)) == NULL)
				syntaxerr(NULL);
			t = block(c == LOGAND? TAND: TOR, t, p, NULL);
		}
		reject = true;
	}
	return (t);
}

static struct op *
c_list(int multi)
{
	struct op *t = NULL, *p, *tl = NULL;
	int c;
	int have_sep;

	while (1) {
		p = andor();
		/* Token has always been read/rejected at this point, so
		 * we don't worry about what flags to pass token()
		 */
		c = token(0);
		have_sep = 1;
		if (c == '\n' && (multi || inalias(source))) {
			if (!p) /* ignore blank lines */
				continue;
		} else if (!p)
			break;
		else if (c == '&' || c == COPROC)
			p = block(c == '&' ? TASYNC : TCOPROC,
				  p, NULL, NULL);
		else if (c != ';')
			have_sep = 0;
		if (!t)
			t = p;
		else if (!tl)
			t = tl = block(TLIST, t, p, NULL);
		else
			tl = tl->right = block(TLIST, tl->right, p, NULL);
		if (!have_sep)
			break;
	}
	reject = true;
	return t;
}

static struct ioword *
synio(int cf)
{
	struct ioword *iop;
	int ishere;

	if (tpeek(cf) != REDIR)
		return NULL;
	reject = false;
	iop = yylval.iop;
	ishere = (iop->flag&IOTYPE) == IOHERE;
	musthave(LWORD, ishere ? HEREDELIM : 0);
	if (ishere) {
		iop->delim = yylval.cp;
		if (*ident != 0) /* unquoted */
			iop->flag |= IOEVAL;
		if (herep >= &heres[HERES])
			yyerror("too many <<'s\n");
		*herep++ = iop;
	} else
		iop->name = yylval.cp;
	return iop;
}

static void
musthave(int c, int cf)
{
	if ((token(cf)) != c)
		syntaxerr(NULL);
}

static struct op *
nested(int type, int smark, int emark)
{
	struct op *t;
	struct nesting_state old_nesting;

	nesting_push(&old_nesting, smark);
	t = c_list(true);
	musthave(emark, KEYWORD|ALIAS);
	nesting_pop(&old_nesting);
	return (block(type, t, NULL, NULL));
}

static struct op *
get_command(int cf)
{
	struct op *t;
	int c, iopn = 0, syniocf;
	struct ioword *iop, **iops;
	XPtrV args, vars;
	struct nesting_state old_nesting;

	iops = areallocarray(NULL, NUFILE + 1,
	    sizeof(struct ioword *), ATEMP);
	XPinit(args, 16);
	XPinit(vars, 16);

	syniocf = KEYWORD|ALIAS;
	switch (c = token(cf|KEYWORD|ALIAS|VARASN)) {
	default:
		reject = true;
		afree(iops, ATEMP);
		XPfree(args);
		XPfree(vars);
		return NULL; /* empty line */

	case LWORD:
	case REDIR:
		reject = true;
		syniocf &= ~(KEYWORD|ALIAS);
		t = newtp(TCOM);
		t->lineno = source->line;
		while (1) {
			cf = (t->u.evalflags ? ARRAYVAR : 0) |
			    (XPsize(args) == 0 ? ALIAS|VARASN : CMDWORD);
			switch (tpeek(cf)) {
			case REDIR:
				if (iopn >= NUFILE)
					yyerror("too many redirections\n");
				iops[iopn++] = synio(cf);
				break;

			case LWORD:
				reject = false;
				/* the iopn == 0 and XPsize(vars) == 0 are
				 * dubious but at&t ksh acts this way
				 */
				if (iopn == 0 && XPsize(vars) == 0 &&
				    XPsize(args) == 0 &&
				    assign_command(ident))
					t->u.evalflags = DOVACHECK;
				if ((XPsize(args) == 0 || Flag(FKEYWORD)) &&
				    is_wdvarassign(yylval.cp))
					XPput(vars, yylval.cp);
				else
					XPput(args, yylval.cp);
				break;

			case '(':
				/* Check for "> foo (echo hi)", which at&t ksh
				 * allows (not POSIX, but not disallowed)
				 */
				afree(t, ATEMP);
				if (XPsize(args) == 0 && XPsize(vars) == 0) {
					reject = false;
					goto Subshell;
				}
				/* Must be a function */
				if (iopn != 0 || XPsize(args) != 1 ||
				    XPsize(vars) != 0)
					syntaxerr(NULL);
				reject = false;
				/*(*/
				musthave(')', 0);
				t = function_body(XPptrv(args)[0], false);
				goto Leave;

			default:
				goto Leave;
			}
		}
	  Leave:
		break;

	  Subshell:
	case '(':
		t = nested(TPAREN, '(', ')');
		break;

	case '{': /*}*/
		t = nested(TBRACE, '{', '}');
		break;

	case MDPAREN:
	  {
		static const char let_cmd[] = {
			CHAR, 'l', CHAR, 'e',
			CHAR, 't', EOS
		};
		/* Leave KEYWORD in syniocf (allow if (( 1 )) then ...) */
		t = newtp(TCOM);
		t->lineno = source->line;
		reject = false;
		XPput(args, wdcopy(let_cmd, ATEMP));
		musthave(LWORD,LETEXPR);
		XPput(args, yylval.cp);
		break;
	  }

	case DBRACKET: /* [[ .. ]] */
		/* Leave KEYWORD in syniocf (allow if [[ -n 1 ]] then ...) */
		t = newtp(TDBRACKET);
		reject = false;
		{
			Test_env te;

			te.flags = TEF_DBRACKET;
			te.pos.av = &args;
			te.isa = dbtestp_isa;
			te.getopnd = dbtestp_getopnd;
			te.eval = dbtestp_eval;
			te.error = dbtestp_error;

			test_parse(&te);
		}
		break;

	case FOR:
	case SELECT:
		t = newtp((c == FOR) ? TFOR : TSELECT);
		musthave(LWORD, ARRAYVAR);
		if (!is_wdvarname(yylval.cp, true))
			yyerror("%s: bad identifier\n",
			    c == FOR ? "for" : "select");
		t->str = str_save(ident, ATEMP);
		nesting_push(&old_nesting, c);
		t->vars = wordlist();
		t->left = dogroup();
		nesting_pop(&old_nesting);
		break;

	case WHILE:
	case UNTIL:
		nesting_push(&old_nesting, c);
		t = newtp((c == WHILE) ? TWHILE : TUNTIL);
		t->left = c_list(true);
		if (t->left == NULL)
			syntaxerr(NULL);
		t->right = dogroup();
		nesting_pop(&old_nesting);
		break;

	case CASE:
		t = newtp(TCASE);
		musthave(LWORD, 0);
		t->str = yylval.cp;
		nesting_push(&old_nesting, c);
		t->left = caselist();
		nesting_pop(&old_nesting);
		break;

	case IF:
		nesting_push(&old_nesting, c);
		t = newtp(TIF);
		t->left = c_list(true);
		t->right = thenpart();
		musthave(FI, KEYWORD|ALIAS);
		nesting_pop(&old_nesting);
		break;

	case BANG:
		syniocf &= ~(KEYWORD|ALIAS);
		t = pipeline(0);
		if (t == NULL)
			syntaxerr(NULL);
		t = block(TBANG, NULL, t, NULL);
		break;

	case TIME:
		syniocf &= ~(KEYWORD|ALIAS);
		t = pipeline(0);
		if (t) {
			if (t->str) {
				t->str = str_save(t->str, ATEMP);
			} else {
				t->str = alloc(2, ATEMP);
				t->str[0] = '\0'; /* TF_* flags */
				t->str[1] = '\0';
			}
		}
		t = block(TTIME, t, NULL, NULL);
		break;

	case FUNCTION:
		musthave(LWORD, 0);
		t = function_body(yylval.cp, true);
		break;
	}

	while ((iop = synio(syniocf)) != NULL) {
		if (iopn >= NUFILE)
			yyerror("too many redirections\n");
		iops[iopn++] = iop;
	}

	if (iopn == 0) {
		afree(iops, ATEMP);
		t->ioact = NULL;
	} else {
		iops[iopn++] = NULL;
		iops = areallocarray(iops, iopn,
		    sizeof(struct ioword *), ATEMP);
		t->ioact = iops;
	}

	if (t->type == TCOM || t->type == TDBRACKET) {
		XPput(args, NULL);
		t->args = (char **) XPclose(args);
		XPput(vars, NULL);
		t->vars = (char **) XPclose(vars);
	} else {
		XPfree(args);
		XPfree(vars);
	}

	return t;
}

static struct op *
dogroup(void)
{
	int c;
	struct op *list;

	c = token(CONTIN|KEYWORD|ALIAS);
	/* A {...} can be used instead of do...done for for/select loops
	 * but not for while/until loops - we don't need to check if it
	 * is a while loop because it would have been parsed as part of
	 * the conditional command list...
	 */
	if (c == DO)
		c = DONE;
	else if (c == '{')
		c = '}';
	else
		syntaxerr(NULL);
	list = c_list(true);
	musthave(c, KEYWORD|ALIAS);
	return list;
}

static struct op *
thenpart(void)
{
	struct op *t;

	musthave(THEN, KEYWORD|ALIAS);
	t = newtp(0);
	t->left = c_list(true);
	if (t->left == NULL)
		syntaxerr(NULL);
	t->right = elsepart();
	return (t);
}

static struct op *
elsepart(void)
{
	struct op *t;

	switch (token(KEYWORD|ALIAS|VARASN)) {
	case ELSE:
		if ((t = c_list(true)) == NULL)
			syntaxerr(NULL);
		return (t);

	case ELIF:
		t = newtp(TELIF);
		t->left = c_list(true);
		t->right = thenpart();
		return (t);

	default:
		reject = true;
	}
	return NULL;
}

static struct op *
caselist(void)
{
	struct op *t, *tl;
	int c;

	c = token(CONTIN|KEYWORD|ALIAS);
	/* A {...} can be used instead of in...esac for case statements */
	if (c == IN)
		c = ESAC;
	else if (c == '{')
		c = '}';
	else
		syntaxerr(NULL);
	t = tl = NULL;
	while ((tpeek(CONTIN|KEYWORD|ESACONLY)) != c) { /* no ALIAS here */
		struct op *tc = casepart(c);
		if (tl == NULL)
			t = tl = tc, tl->right = NULL;
		else
			tl->right = tc, tl = tc;
	}
	musthave(c, KEYWORD|ALIAS);
	return (t);
}

static struct op *
casepart(int endtok)
{
	struct op *t;
	int c;
	XPtrV ptns;

	XPinit(ptns, 16);
	t = newtp(TPAT);
	c = token(CONTIN|KEYWORD); /* no ALIAS here */
	if (c != '(')
		reject = true;
	do {
		musthave(LWORD, 0);
		XPput(ptns, yylval.cp);
	} while ((c = token(0)) == '|');
	reject = true;
	XPput(ptns, NULL);
	t->vars = (char **) XPclose(ptns);
	musthave(')', 0);

	t->left = c_list(true);
	/* Note: Posix requires the ;; */
	if ((tpeek(CONTIN|KEYWORD|ALIAS)) != endtok)
		musthave(BREAK, CONTIN|KEYWORD|ALIAS);
	return (t);
}

static struct op *
function_body(char *name,
    int ksh_func)		/* function foo { ... } vs foo() { .. } */
{
	char *sname, *p;
	struct op *t;
	int old_func_parse;

	sname = wdstrip(name);
	/* Check for valid characters in name.  posix and ksh93 say only
	 * allow [a-zA-Z_0-9] but this allows more as old pdksh's have
	 * allowed more (the following were never allowed:
	 *	nul space nl tab $ ' " \ ` ( ) & | ; = < >
	 *  C_QUOTE covers all but = and adds # [ ? *)
	 */
	for (p = sname; *p; p++)
		if (ctype(*p, C_QUOTE) || *p == '=')
			yyerror("%s: invalid function name\n", sname);

	t = newtp(TFUNCT);
	t->str = sname;
	t->u.ksh_func = ksh_func;
	t->lineno = source->line;

	/* Note that POSIX allows only compound statements after foo(), sh and
	 * at&t ksh allow any command, go with the later since it shouldn't
	 * break anything.  However, for function foo, at&t ksh only accepts
	 * an open-brace.
	 */
	if (ksh_func) {
		musthave('{', CONTIN|KEYWORD|ALIAS); /* } */
		reject = true;
	}

	old_func_parse = genv->flags & EF_FUNC_PARSE;
	genv->flags |= EF_FUNC_PARSE;
	if ((t->left = get_command(CONTIN)) == NULL) {
		/*
		 * Probably something like foo() followed by eof or ;.
		 * This is accepted by sh and ksh88.
		 * To make "typeset -f foo" work reliably (so its output can
		 * be used as input), we pretend there is a colon here.
		 */
		t->left = newtp(TCOM);
		t->left->args = areallocarray(NULL, 2, sizeof(char *), ATEMP);
		t->left->args[0] = alloc(3, ATEMP);
		t->left->args[0][0] = CHAR;
		t->left->args[0][1] = ':';
		t->left->args[0][2] = EOS;
		t->left->args[1] = NULL;
		t->left->vars = alloc(sizeof(char *), ATEMP);
		t->left->vars[0] = NULL;
		t->left->lineno = 1;
	}
	if (!old_func_parse)
		genv->flags &= ~EF_FUNC_PARSE;

	return t;
}

static char **
wordlist(void)
{
	int c;
	XPtrV args;

	XPinit(args, 16);
	/* Posix does not do alias expansion here... */
	if ((c = token(CONTIN|KEYWORD|ALIAS)) != IN) {
		if (c != ';') /* non-POSIX, but at&t ksh accepts a ; here */
			reject = true;
		return NULL;
	}
	while ((c = token(0)) == LWORD)
		XPput(args, yylval.cp);
	if (c != '\n' && c != ';')
		syntaxerr(NULL);
	XPput(args, NULL);
	return (char **) XPclose(args);
}

/*
 * supporting functions
 */

static struct op *
block(int type, struct op *t1, struct op *t2, char **wp)
{
	struct op *t;

	t = newtp(type);
	t->left = t1;
	t->right = t2;
	t->vars = wp;
	return (t);
}

const	struct tokeninfo {
	const char *name;
	short	val;
	short	reserved;
} tokentab[] = {
	/* Reserved words */
	{ "if",		IF,	true },
	{ "then",	THEN,	true },
	{ "else",	ELSE,	true },
	{ "elif",	ELIF,	true },
	{ "fi",		FI,	true },
	{ "case",	CASE,	true },
	{ "esac",	ESAC,	true },
	{ "for",	FOR,	true },
	{ "select",	SELECT,	true },
	{ "while",	WHILE,	true },
	{ "until",	UNTIL,	true },
	{ "do",		DO,	true },
	{ "done",	DONE,	true },
	{ "in",		IN,	true },
	{ "function",	FUNCTION, true },
	{ "time",	TIME,	true },
	{ "{",		'{',	true },
	{ "}",		'}',	true },
	{ "!",		BANG,	true },
	{ "[[",		DBRACKET, true },
	/* Lexical tokens (0[EOF], LWORD and REDIR handled specially) */
	{ "&&",		LOGAND,	false },
	{ "||",		LOGOR,	false },
	{ ";;",		BREAK,	false },
	{ "((",		MDPAREN, false },
	{ "|&",		COPROC,	false },
	/* and some special cases... */
	{ "newline",	'\n',	false },
	{ 0 }
};

void
initkeywords(void)
{
	struct tokeninfo const *tt;
	struct tbl *p;

	ktinit(&keywords, APERM, 32); /* must be 2^n (currently 20 keywords) */
	for (tt = tokentab; tt->name; tt++) {
		if (tt->reserved) {
			p = ktenter(&keywords, tt->name, hash(tt->name));
			p->flag |= DEFINED|ISSET;
			p->type = CKEYWD;
			p->val.i = tt->val;
		}
	}
}

static void
syntaxerr(const char *what)
{
	char redir[6];	/* 2<<- is the longest redirection, I think */
	const char *s;
	struct tokeninfo const *tt;
	int c;

	if (!what)
		what = "unexpected";
	reject = true;
	c = token(0);
    Again:
	switch (c) {
	case 0:
		if (nesting.start_token) {
			c = nesting.start_token;
			source->errline = nesting.start_line;
			what = "unmatched";
			goto Again;
		}
		/* don't quote the EOF */
		yyerror("syntax error: unexpected EOF\n");
		/* NOTREACHED */

	case LWORD:
		s = snptreef(NULL, 32, "%S", yylval.cp);
		break;

	case REDIR:
		s = snptreef(redir, sizeof(redir), "%R", yylval.iop);
		break;

	default:
		for (tt = tokentab; tt->name; tt++)
			if (tt->val == c)
			    break;
		if (tt->name)
			s = tt->name;
		else {
			if (c > 0 && c < 256) {
				redir[0] = c;
				redir[1] = '\0';
			} else
				shf_snprintf(redir, sizeof(redir),
					"?%d", c);
			s = redir;
		}
	}
	yyerror("syntax error: `%s' %s\n", s, what);
}

static void
nesting_push(struct nesting_state *save, int tok)
{
	*save = nesting;
	nesting.start_token = tok;
	nesting.start_line = source->line;
}

static void
nesting_pop(struct nesting_state *saved)
{
	nesting = *saved;
}

static struct op *
newtp(int type)
{
	struct op *t;

	t = alloc(sizeof(*t), ATEMP);
	t->type = type;
	t->u.evalflags = 0;
	t->args = t->vars = NULL;
	t->ioact = NULL;
	t->left = t->right = NULL;
	t->str = NULL;
	return (t);
}

struct op *
compile(Source *s)
{
	nesting.start_token = 0;
	nesting.start_line = 0;
	herep = heres;
	source = s;
	yyparse();
	return outtree;
}

/* This kludge exists to take care of sh/at&t ksh oddity in which
 * the arguments of alias/export/readonly/typeset have no field
 * splitting, file globbing, or (normal) tilde expansion done.
 * at&t ksh seems to do something similar to this since
 *	$ touch a=a; typeset a=[ab]; echo "$a"
 *	a=[ab]
 *	$ x=typeset; $x a=[ab]; echo "$a"
 *	a=a
 *	$
 */
static int
assign_command(char *s)
{
	if (Flag(FPOSIX) || !*s)
		return 0;
	return (strcmp(s, "alias") == 0) ||
	    (strcmp(s, "export") == 0) ||
	    (strcmp(s, "readonly") == 0) ||
	    (strcmp(s, "typeset") == 0);
}

/* Check if we are in the middle of reading an alias */
static int
inalias(struct source *s)
{
	for (; s && s->type == SALIAS; s = s->next)
		if (!(s->flags & SF_ALIASEND))
			return 1;
	return 0;
}


/* Order important - indexed by Test_meta values
 * Note that ||, &&, ( and ) can't appear in as unquoted strings
 * in normal shell input, so these can be interpreted unambiguously
 * in the evaluation pass.
 */
static const char dbtest_or[] = { CHAR, '|', CHAR, '|', EOS };
static const char dbtest_and[] = { CHAR, '&', CHAR, '&', EOS };
static const char dbtest_not[] = { CHAR, '!', EOS };
static const char dbtest_oparen[] = { CHAR, '(', EOS };
static const char dbtest_cparen[] = { CHAR, ')', EOS };
const char *const dbtest_tokens[] = {
	dbtest_or, dbtest_and, dbtest_not,
	dbtest_oparen, dbtest_cparen
};
const char db_close[] = { CHAR, ']', CHAR, ']', EOS };
const char db_lthan[] = { CHAR, '<', EOS };
const char db_gthan[] = { CHAR, '>', EOS };

/* Test if the current token is a whatever.  Accepts the current token if
 * it is.  Returns 0 if it is not, non-zero if it is (in the case of
 * TM_UNOP and TM_BINOP, the returned value is a Test_op).
 */
static int
dbtestp_isa(Test_env *te, Test_meta meta)
{
	int c = tpeek(ARRAYVAR | (meta == TM_BINOP ? 0 : CONTIN));
	int uqword = 0;
	char *save = NULL;
	int ret = 0;

	/* unquoted word? */
	uqword = c == LWORD && *ident;

	if (meta == TM_OR)
		ret = c == LOGOR;
	else if (meta == TM_AND)
		ret = c == LOGAND;
	else if (meta == TM_NOT)
		ret = uqword && strcmp(yylval.cp, dbtest_tokens[(int) TM_NOT]) == 0;
	else if (meta == TM_OPAREN)
		ret = c == '(' /*)*/;
	else if (meta == TM_CPAREN)
		ret = c == /*(*/ ')';
	else if (meta == TM_UNOP || meta == TM_BINOP) {
		if (meta == TM_BINOP && c == REDIR &&
		    (yylval.iop->flag == IOREAD || yylval.iop->flag == IOWRITE)) {
			ret = 1;
			save = wdcopy(yylval.iop->flag == IOREAD ?
			    db_lthan : db_gthan, ATEMP);
		} else if (uqword && (ret = (int) test_isop(te, meta, ident)))
			save = yylval.cp;
	} else /* meta == TM_END */
		ret = uqword && strcmp(yylval.cp, db_close) == 0;
	if (ret) {
		reject = false;
		if (meta != TM_END) {
			if (!save)
				save = wdcopy(dbtest_tokens[(int) meta], ATEMP);
			XPput(*te->pos.av, save);
		}
	}
	return ret;
}

static const char *
dbtestp_getopnd(Test_env *te, Test_op op, int do_eval)
{
	int c = tpeek(ARRAYVAR);

	if (c != LWORD)
		return NULL;

	reject = false;
	XPput(*te->pos.av, yylval.cp);

	return null;
}

static int
dbtestp_eval(Test_env *te, Test_op op, const char *opnd1, const char *opnd2,
    int do_eval)
{
	return 1;
}

static void
dbtestp_error(Test_env *te, int offset, const char *msg)
{
	te->flags |= TEF_ERROR;

	if (offset < 0) {
		reject = true;
		/* Kludgy to say the least... */
		symbol = LWORD;
		yylval.cp = *(XPptrv(*te->pos.av) + XPsize(*te->pos.av) +
		    offset);
	}
	syntaxerr(msg);
}

#undef token
#undef tpeek

/*
 * Command trees: print, copy and free
 */

/*
 * command tree climbing
 */



#define INDENT	4

#define tputc(c, shf)	shf_putchar(c, shf);
static void	ptree(struct op *, int, struct shf *);
static void	pioact(struct shf *, int, struct ioword *);
static void	tputC(int, struct shf *);
static void	tputS(char *, struct shf *);
static void	vfptreef(struct shf *, int, const char *, va_list);
static struct ioword **iocopy(struct ioword **, Area *);
static void     iofree(struct ioword **, Area *);

/*
 * print a command tree
 */

static void
ptree(struct op *t, int indent, struct shf *shf)
{
	char **w;
	struct ioword **ioact;
	struct op *t1;

 Chain:
	if (t == NULL)
		return;
	switch (t->type) {
	case TCOM:
		if (t->vars)
			for (w = t->vars; *w != NULL; )
				fptreef(shf, indent, "%S ", *w++);
		else
			fptreef(shf, indent, "#no-vars# ");
		if (t->args)
			for (w = t->args; *w != NULL; )
				fptreef(shf, indent, "%S ", *w++);
		else
			fptreef(shf, indent, "#no-args# ");
		break;
	case TEXEC:
		t = t->left;
		goto Chain;
	case TPAREN:
		fptreef(shf, indent + 2, "( %T) ", t->left);
		break;
	case TPIPE:
		fptreef(shf, indent, "%T| ", t->left);
		t = t->right;
		goto Chain;
	case TLIST:
		fptreef(shf, indent, "%T%;", t->left);
		t = t->right;
		goto Chain;
	case TOR:
	case TAND:
		fptreef(shf, indent, "%T%s %T",
		    t->left, (t->type==TOR) ? "||" : "&&", t->right);
		break;
	case TBANG:
		fptreef(shf, indent, "! ");
		t = t->right;
		goto Chain;
	case TDBRACKET:
	  {
		int i;

		fptreef(shf, indent, "[[");
		for (i = 0; t->args[i]; i++)
			fptreef(shf, indent, " %S", t->args[i]);
		fptreef(shf, indent, " ]] ");
		break;
	  }
	case TSELECT:
		fptreef(shf, indent, "select %s ", t->str);
		/* FALLTHROUGH */
	case TFOR:
		if (t->type == TFOR)
			fptreef(shf, indent, "for %s ", t->str);
		if (t->vars != NULL) {
			fptreef(shf, indent, "in ");
			for (w = t->vars; *w; )
				fptreef(shf, indent, "%S ", *w++);
			fptreef(shf, indent, "%;");
		}
		fptreef(shf, indent + INDENT, "do%N%T", t->left);
		fptreef(shf, indent, "%;done ");
		break;
	case TCASE:
		fptreef(shf, indent, "case %S in", t->str);
		for (t1 = t->left; t1 != NULL; t1 = t1->right) {
			fptreef(shf, indent, "%N(");
			for (w = t1->vars; *w != NULL; w++)
				fptreef(shf, indent, "%S%c", *w,
				    (w[1] != NULL) ? '|' : ')');
			fptreef(shf, indent + INDENT, "%;%T%N;;", t1->left);
		}
		fptreef(shf, indent, "%Nesac ");
		break;
	case TIF:
	case TELIF:
		/* 3 == strlen("if ") */
		fptreef(shf, indent + 3, "if %T", t->left);
		for (;;) {
			t = t->right;
			if (t->left != NULL) {
				fptreef(shf, indent, "%;");
				fptreef(shf, indent + INDENT, "then%N%T",
				    t->left);
			}
			if (t->right == NULL || t->right->type != TELIF)
				break;
			t = t->right;
			fptreef(shf, indent, "%;");
			/* 5 == strlen("elif ") */
			fptreef(shf, indent + 5, "elif %T", t->left);
		}
		if (t->right != NULL) {
			fptreef(shf, indent, "%;");
			fptreef(shf, indent + INDENT, "else%;%T", t->right);
		}
		fptreef(shf, indent, "%;fi ");
		break;
	case TWHILE:
	case TUNTIL:
		/* 6 == strlen("while"/"until") */
		fptreef(shf, indent + 6, "%s %T",
		    (t->type==TWHILE) ? "while" : "until",
		    t->left);
		fptreef(shf, indent, "%;do");
		fptreef(shf, indent + INDENT, "%;%T", t->right);
		fptreef(shf, indent, "%;done ");
		break;
	case TBRACE:
		fptreef(shf, indent + INDENT, "{%;%T", t->left);
		fptreef(shf, indent, "%;} ");
		break;
	case TCOPROC:
		fptreef(shf, indent, "%T|& ", t->left);
		break;
	case TASYNC:
		fptreef(shf, indent, "%T& ", t->left);
		break;
	case TFUNCT:
		fptreef(shf, indent,
		    t->u.ksh_func ? "function %s %T" : "%s() %T",
		    t->str, t->left);
		break;
	case TTIME:
		fptreef(shf, indent, "time %T", t->left);
		break;
	default:
		fptreef(shf, indent, "<botch>");
		break;
	}
	if ((ioact = t->ioact) != NULL) {
		int	need_nl = 0;

		while (*ioact != NULL)
			pioact(shf, indent, *ioact++);
		/* Print here documents after everything else... */
		for (ioact = t->ioact; *ioact != NULL; ) {
			struct ioword *iop = *ioact++;

			/* heredoc is 0 when tracing (set -x) */
			if ((iop->flag & IOTYPE) == IOHERE && iop->heredoc) {
				tputc('\n', shf);
				shf_puts(iop->heredoc, shf);
				fptreef(shf, indent, "%s",
				    evalstr(iop->delim, 0));
				need_nl = 1;
			}
		}
		/* Last delimiter must be followed by a newline (this often
		 * leads to an extra blank line, but its not worth worrying
		 * about)
		 */
		if (need_nl)
			tputc('\n', shf);
	}
}

static void
pioact(struct shf *shf, int indent, struct ioword *iop)
{
	int flag = iop->flag;
	int type = flag & IOTYPE;
	int expected;

	expected = (type == IOREAD || type == IORDWR || type == IOHERE) ? 0 :
	    (type == IOCAT || type == IOWRITE) ? 1 :
	    (type == IODUP && (iop->unit == !(flag & IORDUP))) ? iop->unit :
	    iop->unit + 1;
	if (iop->unit != expected)
		tputc('0' + iop->unit, shf);

	switch (type) {
	case IOREAD:
		fptreef(shf, indent, "< ");
		break;
	case IOHERE:
		if (flag&IOSKIP)
			fptreef(shf, indent, "<<- ");
		else
			fptreef(shf, indent, "<< ");
		break;
	case IOCAT:
		fptreef(shf, indent, ">> ");
		break;
	case IOWRITE:
		if (flag&IOCLOB)
			fptreef(shf, indent, ">| ");
		else
			fptreef(shf, indent, "> ");
		break;
	case IORDWR:
		fptreef(shf, indent, "<> ");
		break;
	case IODUP:
		if (flag & IORDUP)
			fptreef(shf, indent, "<&");
		else
			fptreef(shf, indent, ">&");
		break;
	}
	/* name/delim are 0 when printing syntax errors */
	if (type == IOHERE) {
		if (iop->delim)
			fptreef(shf, indent, "%S ", iop->delim);
	} else if (iop->name)
		fptreef(shf, indent, (iop->flag & IONAMEXP) ? "%s " : "%S ",
		    iop->name);
}


/*
 * variants of fputc, fputs for ptreef and snptreef
 */

static void
tputC(int c, struct shf *shf)
{
	if ((c&0x60) == 0) {		/* C0|C1 */
		tputc((c&0x80) ? '$' : '^', shf);
		tputc(((c&0x7F)|0x40), shf);
	} else if ((c&0x7F) == 0x7F) {	/* DEL */
		tputc((c&0x80) ? '$' : '^', shf);
		tputc('?', shf);
	} else
		tputc(c, shf);
}

static void
tputS(char *wp, struct shf *shf)
{
	int c, quoted=0;

	/* problems:
	 *	`...` -> $(...)
	 *	'foo' -> "foo"
	 * could change encoding to:
	 *	OQUOTE ["'] ... CQUOTE ["']
	 *	COMSUB [(`] ...\0	(handle $ ` \ and maybe " in `...` case)
	 */
	while (1)
		switch ((c = *wp++)) {
		case EOS:
			return;
		case CHAR:
			tputC(*wp++, shf);
			break;
		case QCHAR:
			c = *wp++;
			if (!quoted || (c == '"' || c == '`' || c == '$'))
				tputc('\\', shf);
			tputC(c, shf);
			break;
		case COMSUB:
			tputc('$', shf);
			tputc('(', shf);
			while (*wp != 0)
				tputC(*wp++, shf);
			tputc(')', shf);
			wp++;
			break;
		case EXPRSUB:
			tputc('$', shf);
			tputc('(', shf);
			tputc('(', shf);
			while (*wp != 0)
				tputC(*wp++, shf);
			tputc(')', shf);
			tputc(')', shf);
			wp++;
			break;
		case OQUOTE:
			quoted = 1;
			tputc('"', shf);
			break;
		case CQUOTE:
			quoted = 0;
			tputc('"', shf);
			break;
		case OSUBST:
			tputc('$', shf);
			if (*wp++ == '{')
				tputc('{', shf);
			while ((c = *wp++) != 0)
				tputC(c, shf);
			break;
		case CSUBST:
			if (*wp++ == '}')
				tputc('}', shf);
			break;
		case OPAT:
			tputc(*wp++, shf);
			tputc('(', shf);
			break;
		case SPAT:
			tputc('|', shf);
			break;
		case CPAT:
			tputc(')', shf);
			break;
		}
}

void
fptreef(struct shf *shf, int indent, const char *fmt, ...)
{
  va_list	va;

  va_start(va, fmt);
  vfptreef(shf, indent, fmt, va);
  va_end(va);
}

char *
snptreef(char *s, int n, const char *fmt, ...)
{
  va_list va;
  struct shf shf;

  shf_sopen(s, n, SHF_WR | (s ? 0 : SHF_DYNAMIC), &shf);

  va_start(va, fmt);
  vfptreef(&shf, 0, fmt, va);
  va_end(va);

  return shf_sclose(&shf); /* null terminates */
}

static void
vfptreef(struct shf *shf, int indent, const char *fmt, va_list va)
{
	int c;

	while ((c = *fmt++)) {
		if (c == '%') {
			int64_t n;
			char *p;
			int neg;

			switch ((c = *fmt++)) {
			case 'c':
				tputc(va_arg(va, int), shf);
				break;
			case 'd': /* decimal */
				n = va_arg(va, int);
				neg = n < 0;
				p = u64ton(neg ? -n : n, 10);
				if (neg)
					*--p = '-';
				while (*p)
					tputc(*p++, shf);
				break;
			case 's':
				p = va_arg(va, char *);
				while (*p)
					tputc(*p++, shf);
				break;
			case 'S':	/* word */
				p = va_arg(va, char *);
				tputS(p, shf);
				break;
			case 'u': /* unsigned decimal */
				p = u64ton(va_arg(va, unsigned int), 10);
				while (*p)
					tputc(*p++, shf);
				break;
			case 'T':	/* format tree */
				ptree(va_arg(va, struct op *), indent, shf);
				break;
			case ';':	/* newline or ; */
			case 'N':	/* newline or space */
				if (shf->flags & SHF_STRING) {
					if (c == ';')
						tputc(';', shf);
					tputc(' ', shf);
				} else {
					int i;

					tputc('\n', shf);
					for (i = indent; i >= 8; i -= 8)
						tputc('\t', shf);
					for (; i > 0; --i)
						tputc(' ', shf);
				}
				break;
			case 'R':
				pioact(shf, indent, va_arg(va, struct ioword *));
				break;
			default:
				tputc(c, shf);
				break;
			}
		} else
			tputc(c, shf);
	}
}

/*
 * copy tree (for function definition)
 */

struct op *
tcopy(struct op *t, Area *ap)
{
	struct op *r;
	char **tw, **rw;

	if (t == NULL)
		return NULL;

	r = alloc(sizeof(struct op), ap);

	r->type = t->type;
	r->u.evalflags = t->u.evalflags;

	r->str = t->type == TCASE ? wdcopy(t->str, ap) : str_save(t->str, ap);

	if (t->vars == NULL)
		r->vars = NULL;
	else {
		for (tw = t->vars; *tw++ != NULL; )
			;
		rw = r->vars = areallocarray(NULL, tw - t->vars + 1,
		    sizeof(*tw), ap);
		for (tw = t->vars; *tw != NULL; )
			*rw++ = wdcopy(*tw++, ap);
		*rw = NULL;
	}

	if (t->args == NULL)
		r->args = NULL;
	else {
		for (tw = t->args; *tw++ != NULL; )
			;
		rw = r->args = areallocarray(NULL, tw - t->args + 1,
		    sizeof(*tw), ap);
		for (tw = t->args; *tw != NULL; )
			*rw++ = wdcopy(*tw++, ap);
		*rw = NULL;
	}

	r->ioact = (t->ioact == NULL) ? NULL : iocopy(t->ioact, ap);

	r->left = tcopy(t->left, ap);
	r->right = tcopy(t->right, ap);
	r->lineno = t->lineno;

	return r;
}

char *
wdcopy(const char *wp, Area *ap)
{
	size_t len = wdscan(wp, EOS) - wp;
	return memcpy(alloc(len, ap), wp, len);
}

/* return the position of prefix c in wp plus 1 */
char *
wdscan(const char *wp, int c)
{
	int nest = 0;

	while (1)
		switch (*wp++) {
		case EOS:
			return (char *) wp;
		case CHAR:
		case QCHAR:
			wp++;
			break;
		case COMSUB:
		case EXPRSUB:
			while (*wp++ != 0)
				;
			break;
		case OQUOTE:
		case CQUOTE:
			break;
		case OSUBST:
			nest++;
			while (*wp++ != '\0')
				;
			break;
		case CSUBST:
			wp++;
			if (c == CSUBST && nest == 0)
				return (char *) wp;
			nest--;
			break;
		case OPAT:
			nest++;
			wp++;
			break;
		case SPAT:
		case CPAT:
			if (c == wp[-1] && nest == 0)
				return (char *) wp;
			if (wp[-1] == CPAT)
				nest--;
			break;
		default:
			internal_warningf(
			    "%s: unknown char 0x%x (carrying on)",
			    __func__, wp[-1]);
		}
}

/* return a copy of wp without any of the mark up characters and
 * with quote characters (" ' \) stripped.
 * (string is allocated from ATEMP)
 */
char *
wdstrip(const char *wp)
{
	struct shf shf;
	int c;

	shf_sopen(NULL, 32, SHF_WR | SHF_DYNAMIC, &shf);

	/* problems:
	 *	`...` -> $(...)
	 *	x${foo:-"hi"} -> x${foo:-hi}
	 *	x${foo:-'hi'} -> x${foo:-hi}
	 */
	while (1)
		switch ((c = *wp++)) {
		case EOS:
			return shf_sclose(&shf); /* null terminates */
		case CHAR:
		case QCHAR:
			shf_putchar(*wp++, &shf);
			break;
		case COMSUB:
			shf_putchar('$', &shf);
			shf_putchar('(', &shf);
			while (*wp != 0)
				shf_putchar(*wp++, &shf);
			shf_putchar(')', &shf);
			break;
		case EXPRSUB:
			shf_putchar('$', &shf);
			shf_putchar('(', &shf);
			shf_putchar('(', &shf);
			while (*wp != 0)
				shf_putchar(*wp++, &shf);
			shf_putchar(')', &shf);
			shf_putchar(')', &shf);
			break;
		case OQUOTE:
			break;
		case CQUOTE:
			break;
		case OSUBST:
			shf_putchar('$', &shf);
			if (*wp++ == '{')
			    shf_putchar('{', &shf);
			while ((c = *wp++) != 0)
				shf_putchar(c, &shf);
			break;
		case CSUBST:
			if (*wp++ == '}')
				shf_putchar('}', &shf);
			break;
		case OPAT:
			shf_putchar(*wp++, &shf);
			shf_putchar('(', &shf);
			break;
		case SPAT:
			shf_putchar('|', &shf);
			break;
		case CPAT:
			shf_putchar(')', &shf);
			break;
		}
}

static	struct ioword **
iocopy(struct ioword **iow, Area *ap)
{
	struct ioword **ior;
	int i;

	for (ior = iow; *ior++ != NULL; )
		;
	ior = areallocarray(NULL, ior - iow + 1, sizeof(*ior), ap);

	for (i = 0; iow[i] != NULL; i++) {
		struct ioword *p, *q;

		p = iow[i];
		q = alloc(sizeof(*p), ap);
		ior[i] = q;
		*q = *p;
		if (p->name != NULL)
			q->name = wdcopy(p->name, ap);
		if (p->delim != NULL)
			q->delim = wdcopy(p->delim, ap);
		if (p->heredoc != NULL)
			q->heredoc = str_save(p->heredoc, ap);
	}
	ior[i] = NULL;

	return ior;
}

/*
 * free tree (for function definition)
 */

void
tfree(struct op *t, Area *ap)
{
	char **w;

	if (t == NULL)
		return;

	afree(t->str, ap);

	if (t->vars != NULL) {
		for (w = t->vars; *w != NULL; w++)
			afree(*w, ap);
		afree(t->vars, ap);
	}

	if (t->args != NULL) {
		for (w = t->args; *w != NULL; w++)
			afree(*w, ap);
		afree(t->args, ap);
	}

	if (t->ioact != NULL)
		iofree(t->ioact, ap);

	tfree(t->left, ap);
	tfree(t->right, ap);

	afree(t, ap);
}

static	void
iofree(struct ioword **iow, Area *ap)
{
	struct ioword **iop;
	struct ioword *p;

	for (iop = iow; (p = *iop++) != NULL; ) {
		afree(p->name, ap);
		afree(p->delim, ap);
		afree(p->heredoc, ap);
		afree(p, ap);
	}
	afree(iow, ap);
}
