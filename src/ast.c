/*
 * ast.c  --  syntax tree constructors and the semantic analysis.
 *
 * The analysis walks the finished tree once for the whole program and
 *   - resolves every variable to a Sym and every call to a function or builtin
 *   - checks types (a value is either a number or a list)
 *   - checks where statements are allowed (note only inside a track or
 *     function, tempo and play only at the top level, stop only in a loop ...)
 *   - checks values it can already see in the source, such as tempo 5
 *   - gives every variable a slot number so the interpreter can use plain
 *     arrays and the compiler can name the storage
 * Errors are reported with the line number and the program is rejected.
 */
#include "ast.h"
#include "checks.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

Program prog;

/* ------------------------------------------------------------------------ */
/* constructors                                                             */
/* ------------------------------------------------------------------------ */

static void *zalloc(size_t n)
{
    void *p = calloc(1, n);
    if (!p) { perror("calloc"); exit(2); }
    return p;
}

static Expr *ex_new(ExKind k, int line)
{
    Expr *e = zalloc(sizeof *e);
    e->kind = k;
    e->line = line;
    e->type = T_NUM;
    return e;
}

Expr *ex_num(double v, int line)
{
    Expr *e = ex_new(EX_NUM, line);
    e->num = v;
    return e;
}

Expr *ex_var(char *name, int line)
{
    Expr *e = ex_new(EX_VAR, line);
    e->name = name;
    return e;
}

Expr *ex_index(Expr *list, Expr *index, int line)
{
    Expr *e = ex_new(EX_INDEX, line);
    e->a = list;
    e->b = index;
    return e;
}

Expr *ex_list(Expr *elems, int line)
{
    Expr *e = ex_new(EX_LIST, line);
    e->args = elems;
    e->type = T_LIST;
    return e;
}

Expr *ex_call(char *name, Expr *args, int line)
{
    Expr *e = ex_new(EX_CALL, line);
    e->name = name;
    e->args = args;
    return e;
}

Expr *ex_unary(ExKind k, Expr *a, int line)
{
    Expr *e = ex_new(k, line);
    e->a = a;
    return e;
}

Expr *ex_bin(BinOp op, Expr *a, Expr *b, int line)
{
    Expr *e = ex_new(EX_BIN, line);
    e->op = op;
    e->a = a;
    e->b = b;
    return e;
}

Expr *ex_append(Expr *list, Expr *e)
{
    if (!list)
        return e;
    Expr *p = list;
    while (p->next)
        p = p->next;
    p->next = e;
    return list;
}

Stmt *st_new(StKind k, int line)
{
    Stmt *s = zalloc(sizeof *s);
    s->kind = k;
    s->line = line;
    return s;
}

Stmt *st_append(Stmt *list, Stmt *s)
{
    if (!s)
        return list;
    if (!list)
        return s;
    Stmt *p = list;
    while (p->next)
        p = p->next;
    p->next = s;
    return list;
}

Param *par_new(char *name, Type t)
{
    Param *p = zalloc(sizeof *p);
    p->name = name;
    p->type = t;
    return p;
}

Param *par_append(Param *list, Param *p)
{
    if (!list)
        return p;
    Param *q = list;
    while (q->next)
        q = q->next;
    q->next = p;
    return list;
}

PlayItem *pi_new(char *name, Expr *count, int line)
{
    PlayItem *p = zalloc(sizeof *p);
    p->name = name;
    p->count = count;
    p->line = line;
    return p;
}

PlayItem *pi_append(PlayItem *list, PlayItem *p)
{
    if (!list)
        return p;
    PlayItem *q = list;
    while (q->next)
        q = q->next;
    q->next = p;
    return list;
}

SayItem *si_new(char *str, Expr *e)
{
    SayItem *s = zalloc(sizeof *s);
    s->str = str;
    s->e = e;
    return s;
}

SayItem *si_append(SayItem *list, SayItem *s)
{
    if (!list)
        return s;
    SayItem *q = list;
    while (q->next)
        q = q->next;
    q->next = s;
    return list;
}

/* ------------------------------------------------------------------------ */
/* builtin functions                                                        */
/* ------------------------------------------------------------------------ */

static const BuiltinInfo builtins[] = {
    { "len",   B_LEN,   1, { T_LIST, T_NUM  }, T_NUM  },
    { "floor", B_FLOOR, 1, { T_NUM,  T_NUM  }, T_NUM  },
    { "abs",   B_ABS,   1, { T_NUM,  T_NUM  }, T_NUM  },
    { "sqrt",  B_SQRT,  1, { T_NUM,  T_NUM  }, T_NUM  },
    { "min",   B_MIN,   2, { T_NUM,  T_NUM  }, T_NUM  },
    { "max",   B_MAX,   2, { T_NUM,  T_NUM  }, T_NUM  },
    { "pow",   B_POW,   2, { T_NUM,  T_NUM  }, T_NUM  },
    { "push",  B_PUSH,  2, { T_LIST, T_NUM  }, T_NUM  },
    { "pop",   B_POP,   1, { T_LIST, T_NUM  }, T_NUM  },
    { "zeros", B_ZEROS, 1, { T_NUM,  T_NUM  }, T_LIST },
    { "copy",  B_COPY,  1, { T_LIST, T_NUM  }, T_LIST },
    { "rand",  B_RAND,  1, { T_NUM,  T_NUM  }, T_NUM  },
    { "seed",  B_SEED,  1, { T_NUM,  T_NUM  }, T_NUM  },
};

static const BuiltinInfo *builtin_find(const char *name)
{
    for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; i++)
        if (strcmp(builtins[i].name, name) == 0)
            return &builtins[i];
    return NULL;
}

/* ------------------------------------------------------------------------ */
/* scopes                                                                   */
/* ------------------------------------------------------------------------ */

#define MAX_DEPTH 200
#define MAX_PARAMS 8

static Sym **syms;
static int nsyms, capsyms;
static int scope_start[MAX_DEPTH + 2];
static int depth;
static Func *cur_func;          /* function or track being checked, NULL at top level */
static int *slotctr;
static int loop_depth;
static int next_id = 1;

static const char *tname(Type t)
{
    return t == T_NUM ? "number" : "list";
}

static void push_scope(void)
{
    if (depth >= MAX_DEPTH) {
        fprintf(stderr, "%s: blocks are nested too deeply\n", rh_filename);
        exit(1);
    }
    scope_start[++depth] = nsyms;
}

static void pop_scope(void)
{
    nsyms = scope_start[depth--];
}

static Sym *lookup(const char *name)
{
    for (int i = nsyms - 1; i >= 0; i--)
        if (strcmp(syms[i]->name, name) == 0)
            return syms[i];
    return NULL;
}

static Sym *declare(const char *name, Type t, int line)
{
    for (int i = nsyms - 1; i >= scope_start[depth]; i--) {
        if (strcmp(syms[i]->name, name) == 0) {
            rh_error(line, "variable '%s' is already declared in this scope (line %d)",
                     name, syms[i]->line);
            return syms[i];
        }
    }
    Sym *s = zalloc(sizeof *s);
    s->name = strdup(name);
    s->type = t;
    s->line = line;
    s->id = next_id++;
    s->global = (cur_func == NULL && depth == 0);
    s->slot = s->global ? prog.nglobals++ : (*slotctr)++;
    if (nsyms == capsyms) {
        capsyms = capsyms ? capsyms * 2 : 32;
        syms = realloc(syms, capsyms * sizeof(Sym *));
        if (!syms) { perror("realloc"); exit(2); }
    }
    syms[nsyms++] = s;
    return s;
}

static Func *find_fn(const char *name)
{
    for (int i = 0; i < prog.nfuncs; i++)
        if (strcmp(prog.funcs[i]->name, name) == 0)
            return prog.funcs[i];
    return NULL;
}

static Func *find_track(const char *name)
{
    for (int i = 0; i < prog.ntracks; i++)
        if (strcmp(prog.tracks[i]->name, name) == 0)
            return prog.tracks[i];
    return NULL;
}

/* ------------------------------------------------------------------------ */
/* constants                                                                */
/* ------------------------------------------------------------------------ */

/* If the expression is built from number literals only, computes its value. */
static int const_eval(Expr *e, double *v)
{
    double a, b;
    switch (e->kind) {
    case EX_NUM:
        *v = e->num;
        return 1;
    case EX_NEG:
        if (!const_eval(e->a, &a))
            return 0;
        *v = -a;
        return 1;
    case EX_BIN:
        if (!const_eval(e->a, &a) || !const_eval(e->b, &b))
            return 0;
        switch (e->op) {
        case OP_ADD: *v = a + b; return 1;
        case OP_SUB: *v = a - b; return 1;
        case OP_MUL: *v = a * b; return 1;
        case OP_DIV: if (b == 0) return 0; *v = a / b; return 1;
        default: return 0;
        }
    default:
        return 0;
    }
}

typedef const char *(*Checker)(double, char *, size_t);

static void check_const(Expr *e, Checker chk)
{
    double v;
    char buf[200];
    if (const_eval(e, &v)) {
        const char *msg = chk(v, buf, sizeof buf);
        if (msg)
            rh_error(e->line, "%s", msg);
    }
}

/* ------------------------------------------------------------------------ */
/* expressions                                                              */
/* ------------------------------------------------------------------------ */

static Type check_expr(Expr *e);

static void need_type(Expr *e, Type want)
{
    Type t = check_expr(e);
    if (t != want)
        rh_error(e->line, "expected a %s here but found a %s", tname(want), tname(t));
}

static void check_call_args(Expr *e, const char *fname, int nparams, const Type *ptype)
{
    int n = 0;
    for (Expr *a = e->args; a; a = a->next)
        n++;
    if (n != nparams) {
        rh_error(e->line, "function '%s' expects %d argument%s but got %d",
                 fname, nparams, nparams == 1 ? "" : "s", n);
        for (Expr *a = e->args; a; a = a->next)
            check_expr(a);
        return;
    }
    int i = 0;
    for (Expr *a = e->args; a; a = a->next, i++) {
        Type t = check_expr(a);
        if (t != ptype[i])
            rh_error(a->line, "argument %d of '%s' must be a %s but got a %s",
                     i + 1, fname, tname(ptype[i]), tname(t));
    }
}

static Type check_expr(Expr *e)
{
    switch (e->kind) {
    case EX_NUM:
        e->type = T_NUM;
        break;
    case EX_VAR: {
        Sym *s = lookup(e->name);
        if (!s) {
            rh_error(e->line, "variable '%s' is not declared", e->name);
            e->type = T_NUM;
        } else {
            e->sym = s;
            e->type = s->type;
        }
        break;
    }
    case EX_INDEX: {
        Type lt = check_expr(e->a);
        if (e->a->sym && lt != T_LIST)
            rh_error(e->line, "'%s' is a number, only lists can be indexed", e->a->name);
        need_type(e->b, T_NUM);
        e->type = T_NUM;
        break;
    }
    case EX_LIST:
        for (Expr *a = e->args; a; a = a->next)
            need_type(a, T_NUM);
        e->type = T_LIST;
        break;
    case EX_CALL: {
        const BuiltinInfo *bi = builtin_find(e->name);
        if (bi) {
            e->kind = EX_BUILTIN;
            e->bi = bi->bi;
            check_call_args(e, bi->name, bi->nargs, bi->argt);
            e->type = bi->ret;
        } else {
            Func *f = find_fn(e->name);
            if (!f) {
                rh_error(e->line, "unknown function '%s'", e->name);
                for (Expr *a = e->args; a; a = a->next)
                    check_expr(a);
                e->type = T_NUM;
            } else {
                e->fn = f;
                check_call_args(e, f->name, f->nparams, f->ptype);
                e->type = T_NUM;
            }
        }
        break;
    }
    case EX_NEG:
    case EX_NOT:
        need_type(e->a, T_NUM);
        e->type = T_NUM;
        break;
    case EX_BIN:
        need_type(e->a, T_NUM);
        need_type(e->b, T_NUM);
        e->type = T_NUM;
        break;
    default:
        break;
    }
    return e->type;
}

/* ------------------------------------------------------------------------ */
/* statements                                                               */
/* ------------------------------------------------------------------------ */

static void check_list(Stmt *s);

static void check_block(Stmt *body)
{
    push_scope();
    check_list(body);
    pop_scope();
}

static void require_func_context(Stmt *s, const char *what)
{
    if (!cur_func)
        rh_error(s->line, "%s can only be used inside a track or a function", what);
}

static void check_stmt(Stmt *s)
{
    switch (s->kind) {
    case S_LET: {
        Type t = check_expr(s->e1);
        s->sym = declare(s->name, t, s->line);
        break;
    }
    case S_ASSIGN: {
        Expr *t = s->target;
        if (t->kind == EX_VAR) {
            Sym *v = lookup(t->name);
            Type rhs = check_expr(s->e1);
            if (!v) {
                rh_error(t->line, "variable '%s' is not declared", t->name);
            } else {
                t->sym = v;
                t->type = v->type;
                if (s->compound) {
                    if (v->type != T_NUM)
                        rh_error(s->line, "'%s' is a list, so += -= *= /= cannot be used on it", t->name);
                    else if (rhs != T_NUM)
                        rh_error(s->line, "expected a number here but found a list");
                } else if (rhs != v->type) {
                    rh_error(s->line, "cannot assign a %s to '%s' because it holds a %s",
                             tname(rhs), t->name, tname(v->type));
                }
            }
        } else {
            check_expr(t);
            need_type(s->e1, T_NUM);
        }
        break;
    }
    case S_TEMPO:
        if (cur_func)
            rh_error(s->line, "tempo can only be set at the top level of the program, not inside a track or function");
        need_type(s->e1, T_NUM);
        check_const(s->e1, chk_tempo);
        break;
    case S_NOTE:
        require_func_context(s, "note");
        need_type(s->e1, T_NUM);
        need_type(s->e2, T_NUM);
        check_const(s->e1, chk_note_number);
        check_const(s->e2, chk_duration);
        break;
    case S_REST:
        require_func_context(s, "rest");
        need_type(s->e1, T_NUM);
        check_const(s->e1, chk_duration);
        break;
    case S_CHORD:
        require_func_context(s, "chord");
        need_type(s->e1, T_LIST);
        need_type(s->e2, T_NUM);
        check_const(s->e2, chk_duration);
        break;
    case S_WAVE:
        require_func_context(s, "instrument");
        break;
    case S_VOLUME:
        require_func_context(s, "volume");
        need_type(s->e1, T_NUM);
        check_const(s->e1, chk_volume);
        break;
    case S_SAY:
        for (SayItem *it = s->say; it; it = it->next)
            if (it->e)
                check_expr(it->e);
        break;
    case S_IF:
        need_type(s->e1, T_NUM);
        check_block(s->body);
        check_block(s->els);
        break;
    case S_WHILE:
        need_type(s->e1, T_NUM);
        loop_depth++;
        check_block(s->body);
        loop_depth--;
        break;
    case S_FORRANGE:
        need_type(s->e1, T_NUM);
        need_type(s->e2, T_NUM);
        if (s->e3) {
            need_type(s->e3, T_NUM);
            double v;
            if (const_eval(s->e3, &v) && v == 0)
                rh_error(s->e3->line, "a for loop cannot have a step of 0");
        }
        push_scope();
        s->sym = declare(s->name, T_NUM, s->line);
        loop_depth++;
        check_list(s->body);
        loop_depth--;
        pop_scope();
        break;
    case S_FOREACH:
        need_type(s->e1, T_LIST);
        push_scope();
        s->sym = declare(s->name, T_NUM, s->line);
        loop_depth++;
        check_list(s->body);
        loop_depth--;
        pop_scope();
        break;
    case S_REPEAT:
        need_type(s->e1, T_NUM);
        check_const(s->e1, chk_loop_count);
        loop_depth++;
        check_block(s->body);
        loop_depth--;
        break;
    case S_STOP:
        if (loop_depth == 0)
            rh_error(s->line, "stop can only be used inside a loop");
        break;
    case S_SKIP:
        if (loop_depth == 0)
            rh_error(s->line, "skip can only be used inside a loop");
        break;
    case S_RETURN:
        if (!cur_func) {
            rh_error(s->line, "return can only be used inside a function or a track");
        } else if (cur_func->is_track && s->e1) {
            rh_error(s->line, "a track cannot return a value");
        } else if (s->e1) {
            need_type(s->e1, T_NUM);
        }
        break;
    case S_FN:
    case S_TRACK: {
        const char *what = s->kind == S_FN ? "function" : "track";
        if (depth != 0 || cur_func) {
            rh_error(s->line, "a %s can only be defined at the top level of the program", what);
            break;
        }
        Func *f = s->fn;
        if (!f)
            break;                      /* duplicate, already reported */
        cur_func = f;
        slotctr = &f->nslots;
        f->nslots = 0;
        push_scope();
        f->psym = zalloc((f->nparams + 1) * sizeof(Sym *));
        int i = 0;
        for (Param *p = s->params; p; p = p->next, i++)
            f->psym[i] = declare(p->name, p->type, s->line);
        int saved = loop_depth;
        loop_depth = 0;
        check_list(f->body);
        loop_depth = saved;
        if (f->is_track && !f->body)
            rh_warn(s->line, "track '%s' is empty", f->name);
        pop_scope();
        cur_func = NULL;
        slotctr = &prog.main_slots;
        break;
    }
    case S_PLAY: {
        if (cur_func) {
            rh_error(s->line, "play can only be used at the top level of the program, not inside a track or function");
            break;
        }
        if (!s->items) {
            if (prog.ntracks == 0) {
                rh_error(s->line, "play: there are no tracks to play");
                break;
            }
            for (int i = 0; i < prog.ntracks; i++)
                s->items = pi_append(s->items, pi_new(strdup(prog.tracks[i]->name), NULL, s->line));
        }
        for (PlayItem *it = s->items; it; it = it->next) {
            it->track = find_track(it->name);
            if (!it->track)
                rh_error(it->line, "play: track '%s' is not defined", it->name);
            if (!it->count) {
                it->count = ex_num(1, it->line);
            } else {
                need_type(it->count, T_NUM);
                check_const(it->count, chk_play_count);
            }
            for (PlayItem *o = s->items; o != it; o = o->next)
                if (strcmp(o->name, it->name) == 0) {
                    rh_warn(it->line, "track '%s' is listed twice in the same play statement", it->name);
                    break;
                }
        }
        break;
    }
    case S_EXPR:
        check_expr(s->e1);
        if (s->e1->kind != EX_CALL && s->e1->kind != EX_BUILTIN)
            rh_warn(s->line, "this statement has no effect");
        break;
    }
}

static void check_list(Stmt *s)
{
    for (; s; s = s->next)
        check_stmt(s);
}

/* ------------------------------------------------------------------------ */
/* entry point                                                              */
/* ------------------------------------------------------------------------ */

static void register_defs(void)
{
    for (Stmt *s = prog.stmts; s; s = s->next) {
        if (s->kind != S_FN && s->kind != S_TRACK)
            continue;
        int is_fn = (s->kind == S_FN);

        if (is_fn && builtin_find(s->name)) {
            rh_error(s->line, "'%s' is the name of a built in function and cannot be redefined", s->name);
            continue;
        }
        Func *old = is_fn ? find_fn(s->name) : find_track(s->name);
        if (old) {
            rh_error(s->line, "%s '%s' is already defined (first defined on line %d)",
                     is_fn ? "function" : "track", s->name, old->line);
            continue;
        }
        Func *f = zalloc(sizeof *f);
        f->name = s->name;
        f->line = s->line;
        f->is_track = !is_fn;
        f->body = s->body;
        for (Param *p = s->params; p; p = p->next)
            f->nparams++;
        if (f->nparams > MAX_PARAMS) {
            rh_error(s->line, "function '%s' has too many parameters (the limit is %d)", s->name, MAX_PARAMS);
            f->nparams = MAX_PARAMS;
        }
        f->ptype = zalloc((f->nparams + 1) * sizeof(Type));
        int i = 0;
        for (Param *p = s->params; p && i < f->nparams; p = p->next)
            f->ptype[i++] = p->type;
        s->fn = f;

        Func ***arr = is_fn ? &prog.funcs : &prog.tracks;
        int *cnt = is_fn ? &prog.nfuncs : &prog.ntracks;
        *arr = realloc(*arr, (*cnt + 1) * sizeof(Func *));
        if (!*arr) { perror("realloc"); exit(2); }
        (*arr)[(*cnt)++] = f;
    }
}

void sem_analyze(void)
{
    depth = 0;
    scope_start[0] = 0;
    cur_func = NULL;
    slotctr = &prog.main_slots;
    prog.main_slots = 0;
    prog.nglobals = 0;
    register_defs();
    check_list(prog.stmts);
}
