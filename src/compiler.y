/*
 * compiler.y  --  RHYTHM to LLVM IR compiler (Phase 2).
 *
 * The grammar and the syntax tree are the same as in the interpreter
 * (interp.y). What changed is everything after the parse: instead of
 * executing the tree, the code at the bottom of this file walks it and writes
 * LLVM IR text. The .ll file is then turned into a native executable by clang
 * and linked with the runtime library (librhythm_rt.a).
 *
 * What the generated IR looks like:
 *   - every fn becomes  define double @fn.NAME(...)
 *   - every track becomes  define void @track.NAME()
 *   - top level statements become the body of @main
 *   - variables are stack slots (alloca) or LLVM globals, numbers are
 *     double and lists are pointers to a runtime list
 *   - if, while, for and repeat become real basic blocks with conditional
 *     branches, and "and" / "or" short circuit with a phi node
 *   - things that can only be known at run time (list bounds, division by
 *     zero, note ranges ...) are calls into the runtime library
 */
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include "common.h"
#include "ast.h"

int yylex(void);
void yyerror(const char *msg);
extern FILE *yyin;
%}

%define parse.error verbose
%locations

%union {
    double num;
    int    ival;
    char  *str;
    Expr     *expr;
    Stmt     *stmt;
    Param    *param;
    PlayItem *pitem;
    SayItem  *sitem;
}

%token TEMPO TRACK NOTE REST CHORD FOR BEAT REPEAT TIMES PLAY TO INSTRUMENT VOLUME
%token FN RETURN LET IF ELSE WHILE IN BY STOP SKIP SAY LIST AND OR NOT DOTDOT
%token EQ NE LE GE PLUSEQ MINUSEQ STAREQ SLASHEQ
%token <ival> WAVE
%token <num>  NUMBER
%token <str>  NOTENAME IDENT STRING

%type <expr>  expr primary args arg_list by_part
%type <stmt>  stmt stmts block if_stmt else_part
%type <param> params param_list param
%type <pitem> play_items play_list play_item
%type <sitem> say_list say_item
%type <str>   dest
%type <ival>  assign_op

%left OR
%left AND
%precedence NOT
%left EQ NE
%left '<' '>' LE GE
%left '+' '-'
%left '*' '/' '%'
%precedence UMINUS

%%

program
    : stmts                         { prog.stmts = $1; }
    ;

stmts
    : %empty                        { $$ = NULL; }
    | stmts stmt                    { $$ = st_append($1, $2); }
    ;

block
    : '{' stmts '}'                 { $$ = $2; }
    ;

stmt
    : LET IDENT '=' expr ';'
        { Stmt *s = st_new(S_LET, @1.first_line); s->name = $2; s->e1 = $4; $$ = s; }
    | IDENT assign_op expr ';'
        {
            Stmt *s = st_new(S_ASSIGN, @1.first_line);
            s->target = ex_var($1, @1.first_line);
            s->compound = $2 != 0;
            s->op = (BinOp)($2 - 1);
            s->e1 = $3;
            $$ = s;
        }
    | IDENT '[' expr ']' assign_op expr ';'
        {
            Stmt *s = st_new(S_ASSIGN, @1.first_line);
            s->target = ex_index(ex_var($1, @1.first_line), $3, @1.first_line);
            s->compound = $5 != 0;
            s->op = (BinOp)($5 - 1);
            s->e1 = $6;
            $$ = s;
        }
    | TEMPO expr ';'
        { Stmt *s = st_new(S_TEMPO, @1.first_line); s->e1 = $2; $$ = s; }
    | NOTE expr FOR expr BEAT ';'
        { Stmt *s = st_new(S_NOTE, @1.first_line); s->e1 = $2; s->e2 = $4; $$ = s; }
    | REST FOR expr BEAT ';'
        { Stmt *s = st_new(S_REST, @1.first_line); s->e1 = $3; $$ = s; }
    | CHORD expr FOR expr BEAT ';'
        { Stmt *s = st_new(S_CHORD, @1.first_line); s->e1 = $2; s->e2 = $4; $$ = s; }
    | INSTRUMENT WAVE ';'
        { Stmt *s = st_new(S_WAVE, @1.first_line); s->ival = $2; $$ = s; }
    | VOLUME expr ';'
        { Stmt *s = st_new(S_VOLUME, @1.first_line); s->e1 = $2; $$ = s; }
    | SAY say_list ';'
        { Stmt *s = st_new(S_SAY, @1.first_line); s->say = $2; $$ = s; }
    | if_stmt
        { $$ = $1; }
    | WHILE expr block
        { Stmt *s = st_new(S_WHILE, @1.first_line); s->e1 = $2; s->body = $3; $$ = s; }
    | FOR IDENT IN expr DOTDOT expr by_part block
        {
            Stmt *s = st_new(S_FORRANGE, @1.first_line);
            s->name = $2; s->e1 = $4; s->e2 = $6; s->e3 = $7; s->body = $8;
            $$ = s;
        }
    | FOR IDENT IN expr block
        {
            Stmt *s = st_new(S_FOREACH, @1.first_line);
            s->name = $2; s->e1 = $4; s->body = $5;
            $$ = s;
        }
    | REPEAT expr TIMES block
        { Stmt *s = st_new(S_REPEAT, @1.first_line); s->e1 = $2; s->body = $4; $$ = s; }
    | STOP ';'
        { $$ = st_new(S_STOP, @1.first_line); }
    | SKIP ';'
        { $$ = st_new(S_SKIP, @1.first_line); }
    | RETURN ';'
        { $$ = st_new(S_RETURN, @1.first_line); }
    | RETURN expr ';'
        { Stmt *s = st_new(S_RETURN, @1.first_line); s->e1 = $2; $$ = s; }
    | FN IDENT '(' params ')' block
        { Stmt *s = st_new(S_FN, @1.first_line); s->name = $2; s->params = $4; s->body = $6; $$ = s; }
    | TRACK IDENT block
        { Stmt *s = st_new(S_TRACK, @1.first_line); s->name = $2; s->body = $3; $$ = s; }
    | PLAY play_items dest ';'
        { Stmt *s = st_new(S_PLAY, @1.first_line); s->items = $2; s->file = $3; $$ = s; }
    | expr ';'
        { Stmt *s = st_new(S_EXPR, @1.first_line); s->e1 = $1; $$ = s; }
    | error ';'
        { yyerrok; $$ = NULL; }
    ;

assign_op
    : '='                           { $$ = 0; }
    | PLUSEQ                        { $$ = OP_ADD + 1; }
    | MINUSEQ                       { $$ = OP_SUB + 1; }
    | STAREQ                        { $$ = OP_MUL + 1; }
    | SLASHEQ                       { $$ = OP_DIV + 1; }
    ;

if_stmt
    : IF expr block else_part
        { Stmt *s = st_new(S_IF, @1.first_line); s->e1 = $2; s->body = $3; s->els = $4; $$ = s; }
    ;

else_part
    : %empty                        { $$ = NULL; }
    | ELSE block                    { $$ = $2; }
    | ELSE if_stmt                  { $$ = $2; }
    ;

by_part
    : %empty                        { $$ = NULL; }
    | BY expr                       { $$ = $2; }
    ;

params
    : %empty                        { $$ = NULL; }
    | param_list                    { $$ = $1; }
    ;

param_list
    : param                         { $$ = $1; }
    | param_list ',' param          { $$ = par_append($1, $3); }
    ;

param
    : IDENT                         { $$ = par_new($1, T_NUM); }
    | LIST IDENT                    { $$ = par_new($2, T_LIST); }
    ;

say_list
    : say_item                      { $$ = $1; }
    | say_list ',' say_item         { $$ = si_append($1, $3); }
    ;

say_item
    : STRING                        { $$ = si_new($1, NULL); }
    | expr                          { $$ = si_new(NULL, $1); }
    ;

play_items
    : %empty                        { $$ = NULL; }
    | play_list                     { $$ = $1; }
    ;

play_list
    : play_item                     { $$ = $1; }
    | play_list ',' play_item       { $$ = pi_append($1, $3); }
    ;

play_item
    : IDENT                         { $$ = pi_new($1, NULL, @1.first_line); }
    | IDENT '*' expr                { $$ = pi_new($1, $3, @1.first_line); }
    ;

dest
    : %empty                        { $$ = NULL; }
    | TO STRING                     { $$ = $2; }
    ;

expr
    : expr OR expr                  { $$ = ex_bin(OP_OR,  $1, $3, @2.first_line); }
    | expr AND expr                 { $$ = ex_bin(OP_AND, $1, $3, @2.first_line); }
    | NOT expr                      { $$ = ex_unary(EX_NOT, $2, @1.first_line); }
    | expr EQ expr                  { $$ = ex_bin(OP_EQ,  $1, $3, @2.first_line); }
    | expr NE expr                  { $$ = ex_bin(OP_NE,  $1, $3, @2.first_line); }
    | expr '<' expr                 { $$ = ex_bin(OP_LT,  $1, $3, @2.first_line); }
    | expr '>' expr                 { $$ = ex_bin(OP_GT,  $1, $3, @2.first_line); }
    | expr LE expr                  { $$ = ex_bin(OP_LE,  $1, $3, @2.first_line); }
    | expr GE expr                  { $$ = ex_bin(OP_GE,  $1, $3, @2.first_line); }
    | expr '+' expr                 { $$ = ex_bin(OP_ADD, $1, $3, @2.first_line); }
    | expr '-' expr                 { $$ = ex_bin(OP_SUB, $1, $3, @2.first_line); }
    | expr '*' expr                 { $$ = ex_bin(OP_MUL, $1, $3, @2.first_line); }
    | expr '/' expr                 { $$ = ex_bin(OP_DIV, $1, $3, @2.first_line); }
    | expr '%' expr                 { $$ = ex_bin(OP_MOD, $1, $3, @2.first_line); }
    | '-' expr %prec UMINUS         { $$ = ex_unary(EX_NEG, $2, @1.first_line); }
    | primary                       { $$ = $1; }
    ;

primary
    : NUMBER                        { $$ = ex_num($1, @1.first_line); }
    | NOTENAME
        {
            int midi = 0;
            rh_note_to_midi($1, @1.first_line, &midi);
            free($1);
            $$ = ex_num(midi, @1.first_line);
        }
    | IDENT                         { $$ = ex_var($1, @1.first_line); }
    | IDENT '(' args ')'            { $$ = ex_call($1, $3, @1.first_line); }
    | IDENT '[' expr ']'            { $$ = ex_index(ex_var($1, @1.first_line), $3, @1.first_line); }
    | '[' args ']'                  { $$ = ex_list($2, @1.first_line); }
    | '(' expr ')'                  { $$ = $2; }
    ;

args
    : %empty                        { $$ = NULL; }
    | arg_list                      { $$ = $1; }
    ;

arg_list
    : expr                          { $$ = $1; }
    | arg_list ',' expr             { $$ = ex_append($1, $3); }
    ;

%%

/* ======================================================================== */
/* LLVM IR generation                                                        */
/* ======================================================================== */

/* State of the function that is being written. */
typedef struct {
    Sbuf body, allocas;
    int tmp, lab;
    char cur[64];           /* label of the block we are in */
    int term;               /* 1 when the current block already ended */
    int is_track;           /* writing a track (returns void) instead of a fn */
    int nloops;
    char brk[40][64];       /* where "stop" jumps, per open loop */
    char cont[40][64];      /* where "skip" jumps */
} Cg;

static Cg *C;
static Sbuf strs, globs, funcs;
static int nstr = 0;

#define EMIT(...) sb_printf(&C->body, __VA_ARGS__)

static const char *ty(Type t)
{
    return t == T_NUM ? "double" : "ptr";
}

static char *fmts(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    return strdup(buf);
}

/* LLVM reads doubles most reliably as the raw 64 bit pattern. */
static char *hexd(double d)
{
    union { double d; uint64_t u; } v;
    v.d = d;
    return fmts("0x%016llX", (unsigned long long)v.u);
}

static char *newtmp(void)
{
    return fmts("%%t%d", ++C->tmp);
}

static void newlabel(char *out, const char *base)
{
    snprintf(out, 64, "%s.%d", base, ++C->lab);
}

/* Begins a block. If the previous block is still open it falls through. */
static void start_label(const char *l)
{
    if (!C->term)
        EMIT("  br label %%%s\n", l);
    EMIT("%s:\n", l);
    C->term = 0;
    snprintf(C->cur, sizeof C->cur, "%s", l);
}

static void br(const char *l)
{
    EMIT("  br label %%%s\n", l);
    C->term = 1;
}

static void condbr(const char *c, const char *t, const char *f)
{
    EMIT("  br i1 %s, label %%%s, label %%%s\n", c, t, f);
    C->term = 1;
}

/* Statements after a return or stop are unreachable but must still be valid IR. */
static void ensure_live(void)
{
    if (C->term) {
        char l[64];
        newlabel(l, "dead");
        start_label(l);
    }
}

static char *hidden_alloca(const char *type)
{
    char *n = fmts("%%h%d", ++C->tmp);
    sb_printf(&C->allocas, "  %s = alloca %s\n", n, type);
    return n;
}

static void decl_local(Sym *s)
{
    sb_printf(&C->allocas, "  %%v%d = alloca %s\n", s->id, ty(s->type));
}

static char *symref(Sym *s)
{
    return s->global ? fmts("@g%d", s->id) : fmts("%%v%d", s->id);
}

/* A private string constant, returns its number. */
static int add_string(const char *s)
{
    int id = nstr++;
    sb_printf(&strs, "@.str.%d = private unnamed_addr constant [%zu x i8] c\"", id, strlen(s) + 1);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p >= 32 && *p < 127 && *p != '"' && *p != '\\')
            sb_printf(&strs, "%c", *p);
        else
            sb_printf(&strs, "\\%02X", *p);
    }
    sb_printf(&strs, "\\00\", align 1\n");
    return id;
}

static char *gen_expr(Expr *e);

/* number to i1: true when not zero (and not NaN) */
static char *truth_i1(char *v)
{
    char *t = newtmp();
    EMIT("  %s = fcmp one double %s, 0.0\n", t, v);
    return t;
}

static char *bool_to_double(char *i1)
{
    char *t = newtmp();
    EMIT("  %s = uitofp i1 %s to double\n", t, i1);
    return t;
}

static char *arith(BinOp op, char *a, char *b, int line)
{
    char *t = newtmp();
    switch (op) {
    case OP_ADD: EMIT("  %s = fadd double %s, %s\n", t, a, b); break;
    case OP_SUB: EMIT("  %s = fsub double %s, %s\n", t, a, b); break;
    case OP_MUL: EMIT("  %s = fmul double %s, %s\n", t, a, b); break;
    case OP_DIV: EMIT("  %s = call double @rt_div(double %s, double %s, i32 %d)\n", t, a, b, line); break;
    case OP_MOD: EMIT("  %s = call double @rt_mod(double %s, double %s, i32 %d)\n", t, a, b, line); break;
    default: break;
    }
    return t;
}

static char *gen_builtin(Expr *e)
{
    char *x = gen_expr(e->args);
    char *y = e->args->next ? gen_expr(e->args->next) : NULL;
    char *t = newtmp();
    int ln = e->line;

    switch (e->bi) {
    case B_LEN:   EMIT("  %s = call double @rt_list_len(ptr %s)\n", t, x); break;
    case B_FLOOR: EMIT("  %s = call double @rt_floor(double %s)\n", t, x); break;
    case B_ABS:   EMIT("  %s = call double @rt_abs(double %s)\n", t, x); break;
    case B_SQRT:  EMIT("  %s = call double @rt_sqrt(double %s, i32 %d)\n", t, x, ln); break;
    case B_MIN:   EMIT("  %s = call double @rt_min(double %s, double %s)\n", t, x, y); break;
    case B_MAX:   EMIT("  %s = call double @rt_max(double %s, double %s)\n", t, x, y); break;
    case B_POW:   EMIT("  %s = call double @rt_pow(double %s, double %s, i32 %d)\n", t, x, y, ln); break;
    case B_PUSH:  EMIT("  %s = call double @rt_list_push(ptr %s, double %s)\n", t, x, y); break;
    case B_POP:   EMIT("  %s = call double @rt_list_pop(ptr %s, i32 %d)\n", t, x, ln); break;
    case B_ZEROS: EMIT("  %s = call ptr @rt_list_new(double %s, i32 %d)\n", t, x, ln); break;
    case B_COPY:  EMIT("  %s = call ptr @rt_list_copy(ptr %s)\n", t, x); break;
    case B_RAND:  EMIT("  %s = call double @rt_rand(double %s, i32 %d)\n", t, x, ln); break;
    case B_SEED:  EMIT("  %s = call double @rt_seed(double %s)\n", t, x); break;
    }
    return t;
}

static char *gen_expr(Expr *e)
{
    switch (e->kind) {
    case EX_NUM:
        return hexd(e->num);

    case EX_VAR: {
        char *t = newtmp();
        EMIT("  %s = load %s, ptr %s\n", t, ty(e->sym->type), symref(e->sym));
        return t;
    }

    case EX_INDEX: {
        char *l = gen_expr(e->a);
        char *i = gen_expr(e->b);
        char *t = newtmp();
        EMIT("  %s = call double @rt_list_get(ptr %s, double %s, i32 %d)\n", t, l, i, e->line);
        return t;
    }

    case EX_LIST: {
        char *l = newtmp();
        EMIT("  %s = call ptr @rt_list_new(double %s, i32 %d)\n", l, hexd(0), e->line);
        for (Expr *a = e->args; a; a = a->next) {
            char *v = gen_expr(a);
            char *d = newtmp();
            EMIT("  %s = call double @rt_list_push(ptr %s, double %s)\n", d, l, v);
        }
        return l;
    }

    case EX_CALL: {
        char *vals[8];
        int n = 0;
        for (Expr *a = e->args; a; a = a->next)
            vals[n++] = gen_expr(a);
        EMIT("  call void @rt_enter(i32 %d)\n", e->line);
        char *t = newtmp();
        EMIT("  %s = call double @fn.%s(", t, e->fn->name);
        for (int i = 0; i < n; i++)
            EMIT("%s%s %s", i ? ", " : "", ty(e->fn->ptype[i]), vals[i]);
        EMIT(")\n");
        EMIT("  call void @rt_leave()\n");
        return t;
    }

    case EX_BUILTIN:
        return gen_builtin(e);

    case EX_NEG: {
        char *a = gen_expr(e->a);
        char *t = newtmp();
        EMIT("  %s = fneg double %s\n", t, a);
        return t;
    }

    case EX_NOT: {
        char *a = gen_expr(e->a);
        char *c = truth_i1(a);
        char *n = newtmp();
        EMIT("  %s = xor i1 %s, true\n", n, c);
        return bool_to_double(n);
    }

    case EX_BIN: {
        if (e->op == OP_AND || e->op == OP_OR) {
            /* short circuit: the right side only runs when it can change the answer */
            int is_and = (e->op == OP_AND);
            char *a = gen_expr(e->a);
            char *ca = truth_i1(a);
            char origin[64], rhs[64], end[64], last[64];
            snprintf(origin, sizeof origin, "%s", C->cur);
            newlabel(rhs, is_and ? "and.rhs" : "or.rhs");
            newlabel(end, is_and ? "and.end" : "or.end");
            if (is_and)
                condbr(ca, rhs, end);
            else
                condbr(ca, end, rhs);
            start_label(rhs);
            char *b = gen_expr(e->b);
            char *cb = truth_i1(b);
            char *bz = bool_to_double(cb);
            snprintf(last, sizeof last, "%s", C->cur);
            br(end);
            start_label(end);
            char *r = newtmp();
            EMIT("  %s = phi double [ %s, %%%s ], [ %s, %%%s ]\n",
                 r, is_and ? "0.0" : "1.0", origin, bz, last);
            return r;
        }

        char *a = gen_expr(e->a);
        char *b = gen_expr(e->b);
        switch (e->op) {
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
            return arith(e->op, a, b, e->line);
        default: {
            const char *cc = "oeq";
            switch (e->op) {
            case OP_LT: cc = "olt"; break;
            case OP_LE: cc = "ole"; break;
            case OP_GT: cc = "ogt"; break;
            case OP_GE: cc = "oge"; break;
            case OP_EQ: cc = "oeq"; break;
            case OP_NE: cc = "une"; break;
            default: break;
            }
            char *c = newtmp();
            EMIT("  %s = fcmp %s double %s, %s\n", c, cc, a, b);
            return bool_to_double(c);
        }
        }
    }
    }
    return hexd(0);
}

/* ---- statements --------------------------------------------------------- */

static void gen_list(Stmt *s);

static void push_loop(const char *brk, const char *cont)
{
    snprintf(C->brk[C->nloops], 64, "%s", brk);
    snprintf(C->cont[C->nloops], 64, "%s", cont);
    C->nloops++;
}

static void pop_loop(void)
{
    C->nloops--;
}

static void gen_assign(Stmt *s)
{
    Expr *t = s->target;
    if (t->kind == EX_VAR) {
        char *rhs = gen_expr(s->e1);
        if (s->compound) {
            char *cur = newtmp();
            EMIT("  %s = load double, ptr %s\n", cur, symref(t->sym));
            rhs = arith(s->op, cur, rhs, s->line);
        }
        EMIT("  store %s %s, ptr %s\n", ty(t->sym->type), rhs, symref(t->sym));
    } else {
        char *l = gen_expr(t->a);
        char *idx = gen_expr(t->b);
        char *rhs = gen_expr(s->e1);
        if (s->compound) {
            char *cur = newtmp();
            EMIT("  %s = call double @rt_list_get(ptr %s, double %s, i32 %d)\n", cur, l, idx, s->line);
            rhs = arith(s->op, cur, rhs, s->line);
        }
        EMIT("  call void @rt_list_set(ptr %s, double %s, double %s, i32 %d)\n", l, idx, rhs, s->line);
    }
}

/* runs a loop body counted by a hidden i32, used by repeat and play */
static void gen_counted_loop(const char *count_i32, Func *call_track, Stmt *body, int is_repeat)
{
    char *h = hidden_alloca("i32");
    char cond[64], bodyl[64], incr[64], end[64];
    newlabel(cond, "count.cond");
    newlabel(bodyl, "count.body");
    newlabel(incr, "count.incr");
    newlabel(end, "count.end");

    EMIT("  store i32 0, ptr %s\n", h);
    start_label(cond);
    char *i = newtmp();
    EMIT("  %s = load i32, ptr %s\n", i, h);
    char *c = newtmp();
    EMIT("  %s = icmp slt i32 %s, %s\n", c, i, count_i32);
    condbr(c, bodyl, end);

    start_label(bodyl);
    if (is_repeat) {
        push_loop(end, incr);
        gen_list(body);
        pop_loop();
    } else {
        EMIT("  call void @track.%s()\n", call_track->name);
    }
    start_label(incr);
    char *i2 = newtmp();
    EMIT("  %s = load i32, ptr %s\n", i2, h);
    char *n = newtmp();
    EMIT("  %s = add nsw i32 %s, 1\n", n, i2);
    EMIT("  store i32 %s, ptr %s\n", n, h);
    br(cond);
    start_label(end);
}

static void gen_stmt(Stmt *s)
{
    ensure_live();
    switch (s->kind) {
    case S_LET: {
        char *v = gen_expr(s->e1);
        if (s->sym->global)
            sb_printf(&globs, "@g%d = global %s %s\n", s->sym->id, ty(s->sym->type),
                      s->sym->type == T_NUM ? "0.0" : "null");
        else
            decl_local(s->sym);
        EMIT("  store %s %s, ptr %s\n", ty(s->sym->type), v, symref(s->sym));
        break;
    }
    case S_ASSIGN:
        gen_assign(s);
        break;
    case S_TEMPO: {
        char *v = gen_expr(s->e1);
        EMIT("  call void @rt_set_tempo(double %s, i32 %d)\n", v, s->line);
        break;
    }
    case S_NOTE: {
        char *m = gen_expr(s->e1);
        char *b = gen_expr(s->e2);
        EMIT("  call void @rt_note(double %s, double %s, i32 %d)\n", m, b, s->line);
        break;
    }
    case S_REST: {
        char *b = gen_expr(s->e1);
        EMIT("  call void @rt_rest(double %s, i32 %d)\n", b, s->line);
        break;
    }
    case S_CHORD: {
        char *l = gen_expr(s->e1);
        char *b = gen_expr(s->e2);
        EMIT("  call void @rt_chord(ptr %s, double %s, i32 %d)\n", l, b, s->line);
        break;
    }
    case S_WAVE:
        EMIT("  call void @rt_set_wave(i32 %d, i32 %d)\n", s->ival, s->line);
        break;
    case S_VOLUME: {
        char *v = gen_expr(s->e1);
        EMIT("  call void @rt_set_volume(double %s, i32 %d)\n", v, s->line);
        break;
    }
    case S_SAY:
        for (SayItem *it = s->say; it; it = it->next) {
            if (it->str) {
                int id = add_string(it->str);
                EMIT("  call void @rt_say_str(ptr @.str.%d)\n", id);
            } else {
                char *v = gen_expr(it->e);
                if (it->e->type == T_LIST)
                    EMIT("  call void @rt_say_list(ptr %s)\n", v);
                else
                    EMIT("  call void @rt_say_num(double %s)\n", v);
            }
        }
        EMIT("  call void @rt_say_end()\n");
        break;
    case S_IF: {
        char *c = truth_i1(gen_expr(s->e1));
        char thenl[64], elsel[64], end[64];
        newlabel(thenl, "if.then");
        newlabel(elsel, "if.else");
        newlabel(end, "if.end");
        condbr(c, thenl, s->els ? elsel : end);
        start_label(thenl);
        gen_list(s->body);
        if (!C->term)
            br(end);
        if (s->els) {
            start_label(elsel);
            gen_list(s->els);
        }
        start_label(end);
        break;
    }
    case S_WHILE: {
        char cond[64], body[64], end[64];
        newlabel(cond, "while.cond");
        newlabel(body, "while.body");
        newlabel(end, "while.end");
        start_label(cond);
        char *c = truth_i1(gen_expr(s->e1));
        condbr(c, body, end);
        start_label(body);
        push_loop(end, cond);
        gen_list(s->body);
        pop_loop();
        if (!C->term)
            br(cond);
        start_label(end);
        break;
    }
    case S_FORRANGE: {
        char *st = gen_expr(s->e1);
        char *en = gen_expr(s->e2);
        char *step;
        if (s->e3) {
            step = gen_expr(s->e3);
            EMIT("  call void @rt_check_step(double %s, i32 %d)\n", step, s->line);
        } else {
            step = hexd(1.0);
        }
        char *var = symref(s->sym);
        decl_local(s->sym);
        EMIT("  store double %s, ptr %s\n", st, var);

        char cond[64], body[64], incr[64], end[64];
        newlabel(cond, "for.cond");
        newlabel(body, "for.body");
        newlabel(incr, "for.incr");
        newlabel(end, "for.end");
        start_label(cond);
        char *i = newtmp();
        EMIT("  %s = load double, ptr %s\n", i, var);
        char *up = newtmp(), *lt = newtmp(), *a = newtmp();
        EMIT("  %s = fcmp ogt double %s, 0.0\n", up, step);
        EMIT("  %s = fcmp olt double %s, %s\n", lt, i, en);
        EMIT("  %s = and i1 %s, %s\n", a, up, lt);
        char *dn = newtmp(), *gt = newtmp(), *b = newtmp(), *c = newtmp();
        EMIT("  %s = fcmp olt double %s, 0.0\n", dn, step);
        EMIT("  %s = fcmp ogt double %s, %s\n", gt, i, en);
        EMIT("  %s = and i1 %s, %s\n", b, dn, gt);
        EMIT("  %s = or i1 %s, %s\n", c, a, b);
        condbr(c, body, end);

        start_label(body);
        push_loop(end, incr);
        gen_list(s->body);
        pop_loop();
        start_label(incr);
        char *i2 = newtmp(), *n = newtmp();
        EMIT("  %s = load double, ptr %s\n", i2, var);
        EMIT("  %s = fadd double %s, %s\n", n, i2, step);
        EMIT("  store double %s, ptr %s\n", n, var);
        br(cond);
        start_label(end);
        break;
    }
    case S_FOREACH: {
        char *l = gen_expr(s->e1);
        char *var = symref(s->sym);
        decl_local(s->sym);
        char *h = hidden_alloca("double");
        EMIT("  store double 0.0, ptr %s\n", h);

        char cond[64], body[64], incr[64], end[64];
        newlabel(cond, "each.cond");
        newlabel(body, "each.body");
        newlabel(incr, "each.incr");
        newlabel(end, "each.end");
        start_label(cond);
        char *idx = newtmp(), *len = newtmp(), *c = newtmp();
        EMIT("  %s = load double, ptr %s\n", idx, h);
        EMIT("  %s = call double @rt_list_len(ptr %s)\n", len, l);
        EMIT("  %s = fcmp olt double %s, %s\n", c, idx, len);
        condbr(c, body, end);

        start_label(body);
        char *el = newtmp();
        EMIT("  %s = call double @rt_list_get(ptr %s, double %s, i32 %d)\n", el, l, idx, s->line);
        EMIT("  store double %s, ptr %s\n", el, var);
        push_loop(end, incr);
        gen_list(s->body);
        pop_loop();
        start_label(incr);
        char *i2 = newtmp(), *n = newtmp();
        EMIT("  %s = load double, ptr %s\n", i2, h);
        EMIT("  %s = fadd double %s, 1.0\n", n, i2);
        EMIT("  store double %s, ptr %s\n", n, h);
        br(cond);
        start_label(end);
        break;
    }
    case S_REPEAT: {
        char *cnt = gen_expr(s->e1);
        char *n32 = newtmp();
        EMIT("  %s = call i32 @rt_loop_count(double %s, i32 %d)\n", n32, cnt, s->line);
        gen_counted_loop(n32, NULL, s->body, 1);
        break;
    }
    case S_STOP:
        br(C->brk[C->nloops - 1]);
        break;
    case S_SKIP:
        br(C->cont[C->nloops - 1]);
        break;
    case S_RETURN:
        if (C->is_track) {
            EMIT("  ret void\n");
        } else {
            char *v = s->e1 ? gen_expr(s->e1) : hexd(0);
            EMIT("  ret double %s\n", v);
        }
        C->term = 1;
        break;
    case S_FN:
    case S_TRACK:
        break;
    case S_PLAY: {
        EMIT("  call void @rt_session_begin(i32 %d)\n", s->line);
        for (PlayItem *it = s->items; it; it = it->next) {
            int id = add_string(it->name);
            EMIT("  call void @rt_track_begin(ptr @.str.%d)\n", id);
            char *cnt = gen_expr(it->count);
            char *n32 = newtmp();
            EMIT("  %s = call i32 @rt_play_count(double %s, i32 %d)\n", n32, cnt, it->line);
            gen_counted_loop(n32, it->track, NULL, 0);
        }
        if (s->file) {
            int id = add_string(s->file);
            EMIT("  call void @rt_session_end(ptr @.str.%d)\n", id);
        } else {
            EMIT("  call void @rt_session_end(ptr null)\n");
        }
        break;
    }
    case S_EXPR:
        gen_expr(s->e1);
        break;
    }
}

static void gen_list(Stmt *s)
{
    for (; s; s = s->next)
        gen_stmt(s);
}

/* ---- functions, tracks and main ------------------------------------------ */

static void gen_func(Func *f)
{
    Cg cg;
    memset(&cg, 0, sizeof cg);
    Cg *saved = C;
    C = &cg;
    snprintf(cg.cur, sizeof cg.cur, "entry");
    cg.is_track = f->is_track;

    Sbuf head = { 0 };
    if (f->is_track) {
        sb_printf(&head, "; track '%s' (line %d)\n", f->name, f->line);
        sb_printf(&head, "define internal void @track.%s() {\nentry:\n", f->name);
    } else {
        sb_printf(&head, "; function '%s' (line %d)\n", f->name, f->line);
        sb_printf(&head, "define internal double @fn.%s(", f->name);
        for (int i = 0; i < f->nparams; i++)
            sb_printf(&head, "%s%s %%p%d", i ? ", " : "", ty(f->psym[i]->type), f->psym[i]->id);
        sb_printf(&head, ") {\nentry:\n");
    }

    for (int i = 0; i < f->nparams; i++) {
        decl_local(f->psym[i]);
        EMIT("  store %s %%p%d, ptr %%v%d\n", ty(f->psym[i]->type), f->psym[i]->id, f->psym[i]->id);
    }
    gen_list(f->body);
    if (!C->term) {
        if (f->is_track)
            EMIT("  ret void\n");
        else
            EMIT("  ret double 0.0\n");
    }

    sb_printf(&funcs, "%s%s%s}\n\n", head.s, cg.allocas.s ? cg.allocas.s : "", cg.body.s ? cg.body.s : "");
    C = saved;
}

void yyerror(const char *msg)
{
    fprintf(stderr, "%s:%d: error: %s\n", rh_filename, yylloc.first_line, msg);
    rh_nerrors++;
}

static void usage(const char *prog_name)
{
    fprintf(stderr,
        "RHYTHM to LLVM IR compiler\n"
        "usage: %s program.rhy [-o output.ll]\n"
        "  -o output.ll  write the IR to this file (default is standard output)\n"
        "  -h            show this help\n", prog_name);
}

static const char *runtime_decls =
    "declare void @rt_init(i32, ptr, ptr)\n"
    "declare i32 @rt_finish()\n"
    "declare void @rt_set_tempo(double, i32)\n"
    "declare void @rt_session_begin(i32)\n"
    "declare void @rt_track_begin(ptr)\n"
    "declare void @rt_session_end(ptr)\n"
    "declare void @rt_note(double, double, i32)\n"
    "declare void @rt_rest(double, i32)\n"
    "declare void @rt_chord(ptr, double, i32)\n"
    "declare void @rt_set_wave(i32, i32)\n"
    "declare void @rt_set_volume(double, i32)\n"
    "declare i32 @rt_play_count(double, i32)\n"
    "declare i32 @rt_loop_count(double, i32)\n"
    "declare void @rt_check_step(double, i32)\n"
    "declare void @rt_enter(i32)\n"
    "declare void @rt_leave()\n"
    "declare double @rt_div(double, double, i32)\n"
    "declare double @rt_mod(double, double, i32)\n"
    "declare ptr @rt_list_new(double, i32)\n"
    "declare double @rt_list_get(ptr, double, i32)\n"
    "declare void @rt_list_set(ptr, double, double, i32)\n"
    "declare double @rt_list_len(ptr)\n"
    "declare double @rt_list_push(ptr, double)\n"
    "declare double @rt_list_pop(ptr, i32)\n"
    "declare ptr @rt_list_copy(ptr)\n"
    "declare double @rt_floor(double)\n"
    "declare double @rt_abs(double)\n"
    "declare double @rt_sqrt(double, i32)\n"
    "declare double @rt_pow(double, double, i32)\n"
    "declare double @rt_min(double, double)\n"
    "declare double @rt_max(double, double)\n"
    "declare double @rt_rand(double, i32)\n"
    "declare double @rt_seed(double)\n"
    "declare void @rt_say_num(double)\n"
    "declare void @rt_say_str(ptr)\n"
    "declare void @rt_say_list(ptr)\n"
    "declare void @rt_say_end()\n";

int main(int argc, char **argv)
{
    const char *input = NULL, *output = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            output = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
            fprintf(stderr, "unknown option '%s'\n", argv[i]);
            usage(argv[0]);
            return 2;
        } else {
            input = argv[i];
        }
    }
    if (!input) {
        usage(argv[0]);
        return 2;
    }
    yyin = fopen(input, "r");
    if (!yyin) {
        perror(input);
        return 2;
    }
    rh_filename = input;

    yyparse();
    fclose(yyin);
    if (rh_nerrors == 0)
        sem_analyze();

    if (rh_nerrors > 0) {
        fprintf(stderr, "%d error%s found, no code was generated\n",
                rh_nerrors, rh_nerrors == 1 ? "" : "s");
        return 1;
    }

    /* the functions and tracks first, then the top level code as @main */
    Cg maincg;
    memset(&maincg, 0, sizeof maincg);
    snprintf(maincg.cur, sizeof maincg.cur, "entry");
    int srcid = add_string(input);
    C = &maincg;
    EMIT("  call void @rt_init(i32 %%argc, ptr %%argv, ptr @.str.%d)\n", srcid);
    for (Stmt *s = prog.stmts; s; s = s->next) {
        if (s->kind == S_FN || s->kind == S_TRACK) {
            if (s->fn)
                gen_func(s->fn);
        } else {
            gen_stmt(s);
        }
    }
    ensure_live();
    EMIT("  %%rc = call i32 @rt_finish()\n  ret i32 %%rc\n");

    FILE *out = output ? fopen(output, "w") : stdout;
    if (!out) {
        perror(output);
        return 2;
    }
    fprintf(out, "; ModuleID = '%s'\n", input);
    fprintf(out, "; generated by the RHYTHM compiler, do not edit\n");
    fprintf(out, "source_filename = \"%s\"\n\n", input);
    fputs(runtime_decls, out);
    fputc('\n', out);
    if (strs.s)
        fprintf(out, "%s\n", strs.s);
    if (globs.s)
        fprintf(out, "%s\n", globs.s);
    if (funcs.s)
        fprintf(out, "%s", funcs.s);
    fprintf(out, "define i32 @main(i32 %%argc, ptr %%argv) {\nentry:\n%s%s}\n",
            maincg.allocas.s ? maincg.allocas.s : "", maincg.body.s ? maincg.body.s : "");
    if (output)
        fclose(out);
    return 0;
}
