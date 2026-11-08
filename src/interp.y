/*
 * interp.y  --  RHYTHM interpreter (Phase 1).
 *
 * Flex tokenises and Bison parses. The grammar actions below build a syntax
 * tree, ast.c checks it, and then the C code at the bottom of this file
 * (eval, exec_list and friends) executes the program directly: it does the
 * arithmetic, runs the loops, calls the functions and plays the tracks.
 * No intermediate code and no LLVM are involved in this phase.
 */
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "ast.h"
#include "rtlib.h"
#include "engine.h"

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
/* The interpreter: executes the checked syntax tree                         */
/* ======================================================================== */

/* A value is a number or a list, ast.c has already made sure which one. */
typedef struct {
    double n;
    List  *l;
} Value;

/* The variables of one running function, plus its return value. */
typedef struct {
    Value  *v;
    double  ret;
} Frame;

typedef enum { F_NORMAL, F_STOP, F_SKIP, F_RETURN } Flow;

static Value *gvars;            /* global variables */

static Value eval(Expr *e, Frame *f);
static Flow exec_list(Stmt *s, Frame *f);

static Value *slot_of(Sym *s, Frame *f)
{
    return s->global ? &gvars[s->slot] : &f->v[s->slot];
}

/* a number counts as true when it is not zero (and not NaN) */
static int truth(double d)
{
    return d < 0.0 || d > 0.0;
}

static Value num(double d)
{
    Value v;
    v.n = d;
    v.l = NULL;
    return v;
}

static double call_func(Func *fn, Value *args, int line)
{
    Frame nf;
    rt_enter(line);
    nf.v = calloc(fn->nslots ? fn->nslots : 1, sizeof(Value));
    nf.ret = 0.0;
    if (!nf.v) { fprintf(stderr, "out of memory\n"); exit(2); }
    for (int i = 0; i < fn->nparams; i++)
        nf.v[fn->psym[i]->slot] = args[i];
    exec_list(fn->body, &nf);
    free(nf.v);
    rt_leave();
    return nf.ret;
}

static Value eval_builtin(Expr *e, Frame *f)
{
    Value r = num(0);
    Value x = eval(e->args, f);
    Value y = num(0);
    if (e->args->next)
        y = eval(e->args->next, f);

    switch (e->bi) {
    case B_LEN:   r.n = rt_list_len(x.l); break;
    case B_FLOOR: r.n = rt_floor(x.n); break;
    case B_ABS:   r.n = rt_abs(x.n); break;
    case B_SQRT:  r.n = rt_sqrt(x.n, e->line); break;
    case B_MIN:   r.n = rt_min(x.n, y.n); break;
    case B_MAX:   r.n = rt_max(x.n, y.n); break;
    case B_POW:   r.n = rt_pow(x.n, y.n, e->line); break;
    case B_PUSH:  r.n = rt_list_push(x.l, y.n); break;
    case B_POP:   r.n = rt_list_pop(x.l, e->line); break;
    case B_ZEROS: r.l = rt_list_new(x.n, e->line); break;
    case B_COPY:  r.l = rt_list_copy(x.l); break;
    case B_RAND:  r.n = rt_rand(x.n, e->line); break;
    case B_SEED:  r.n = rt_seed(x.n); break;
    }
    return r;
}

static Value eval(Expr *e, Frame *f)
{
    switch (e->kind) {
    case EX_NUM:
        return num(e->num);
    case EX_VAR:
        return *slot_of(e->sym, f);
    case EX_INDEX: {
        List *l = slot_of(e->a->sym, f)->l;
        double i = eval(e->b, f).n;
        return num(rt_list_get(l, i, e->line));
    }
    case EX_LIST: {
        Value r = num(0);
        r.l = rt_list_new(0, e->line);
        for (Expr *a = e->args; a; a = a->next)
            rt_list_push(r.l, eval(a, f).n);
        return r;
    }
    case EX_CALL: {
        Value args[8];
        int i = 0;
        for (Expr *a = e->args; a; a = a->next)
            args[i++] = eval(a, f);
        return num(call_func(e->fn, args, e->line));
    }
    case EX_BUILTIN:
        return eval_builtin(e, f);
    case EX_NEG:
        return num(-eval(e->a, f).n);
    case EX_NOT:
        return num(truth(eval(e->a, f).n) ? 0.0 : 1.0);
    case EX_BIN: {
        if (e->op == OP_AND) {
            if (!truth(eval(e->a, f).n))
                return num(0.0);
            return num(truth(eval(e->b, f).n) ? 1.0 : 0.0);
        }
        if (e->op == OP_OR) {
            if (truth(eval(e->a, f).n))
                return num(1.0);
            return num(truth(eval(e->b, f).n) ? 1.0 : 0.0);
        }
        double a = eval(e->a, f).n;
        double b = eval(e->b, f).n;
        switch (e->op) {
        case OP_ADD: return num(a + b);
        case OP_SUB: return num(a - b);
        case OP_MUL: return num(a * b);
        case OP_DIV: return num(rt_div(a, b, e->line));
        case OP_MOD: return num(rt_mod(a, b, e->line));
        case OP_LT:  return num(a < b ? 1.0 : 0.0);
        case OP_LE:  return num(a <= b ? 1.0 : 0.0);
        case OP_GT:  return num(a > b ? 1.0 : 0.0);
        case OP_GE:  return num(a >= b ? 1.0 : 0.0);
        case OP_EQ:  return num(a == b ? 1.0 : 0.0);
        case OP_NE:  return num(a != b ? 1.0 : 0.0);
        default:     break;
        }
        break;
    }
    }
    return num(0);
}

static double apply_op(BinOp op, double a, double b, int line)
{
    switch (op) {
    case OP_ADD: return a + b;
    case OP_SUB: return a - b;
    case OP_MUL: return a * b;
    case OP_DIV: return rt_div(a, b, line);
    default:     return b;
    }
}

static void do_assign(Stmt *s, Frame *f)
{
    Expr *t = s->target;
    if (t->kind == EX_VAR) {
        Value rhs = eval(s->e1, f);
        Value *slot = slot_of(t->sym, f);
        if (s->compound)
            slot->n = apply_op(s->op, slot->n, rhs.n, s->line);
        else
            *slot = rhs;
    } else {
        List *l = slot_of(t->a->sym, f)->l;
        double idx = eval(t->b, f).n;
        double rhs = eval(s->e1, f).n;
        if (s->compound)
            rhs = apply_op(s->op, rt_list_get(l, idx, s->line), rhs, s->line);
        rt_list_set(l, idx, rhs, s->line);
    }
}

static void do_play(Stmt *s, Frame *f)
{
    rt_session_begin(s->line);
    for (PlayItem *it = s->items; it; it = it->next) {
        rt_track_begin(it->name);
        int n = rt_play_count(eval(it->count, f).n, it->line);
        Func *tr = it->track;
        for (int i = 0; i < n; i++) {
            Frame nf;
            nf.v = calloc(tr->nslots ? tr->nslots : 1, sizeof(Value));
            nf.ret = 0.0;
            if (!nf.v) { fprintf(stderr, "out of memory\n"); exit(2); }
            exec_list(tr->body, &nf);
            free(nf.v);
        }
    }
    rt_session_end(s->file);
}

static Flow exec(Stmt *s, Frame *f)
{
    switch (s->kind) {
    case S_LET:
        *slot_of(s->sym, f) = eval(s->e1, f);
        break;
    case S_ASSIGN:
        do_assign(s, f);
        break;
    case S_TEMPO:
        rt_set_tempo(eval(s->e1, f).n, s->line);
        break;
    case S_NOTE: {
        double midi = eval(s->e1, f).n;
        double beats = eval(s->e2, f).n;
        rt_note(midi, beats, s->line);
        break;
    }
    case S_REST:
        rt_rest(eval(s->e1, f).n, s->line);
        break;
    case S_CHORD: {
        List *l = eval(s->e1, f).l;
        double beats = eval(s->e2, f).n;
        rt_chord(l, beats, s->line);
        break;
    }
    case S_WAVE:
        rt_set_wave(s->ival, s->line);
        break;
    case S_VOLUME:
        rt_set_volume(eval(s->e1, f).n, s->line);
        break;
    case S_SAY:
        for (SayItem *it = s->say; it; it = it->next) {
            if (it->str) {
                rt_say_str(it->str);
            } else {
                Value v = eval(it->e, f);
                if (it->e->type == T_LIST)
                    rt_say_list(v.l);
                else
                    rt_say_num(v.n);
            }
        }
        rt_say_end();
        break;
    case S_IF:
        if (truth(eval(s->e1, f).n))
            return exec_list(s->body, f);
        return exec_list(s->els, f);
    case S_WHILE:
        while (truth(eval(s->e1, f).n)) {
            Flow fl = exec_list(s->body, f);
            if (fl == F_STOP)
                break;
            if (fl == F_RETURN)
                return fl;
        }
        break;
    case S_FORRANGE: {
        double start = eval(s->e1, f).n;
        double end = eval(s->e2, f).n;
        double step = 1.0;
        if (s->e3) {
            step = eval(s->e3, f).n;
            rt_check_step(step, s->line);
        }
        Value *var = slot_of(s->sym, f);
        var->n = start;
        for (;;) {
            double i = var->n;
            if (!((step > 0.0 && i < end) || (step < 0.0 && i > end)))
                break;
            Flow fl = exec_list(s->body, f);
            if (fl == F_STOP)
                break;
            if (fl == F_RETURN)
                return fl;
            var->n += step;
        }
        break;
    }
    case S_FOREACH: {
        List *l = eval(s->e1, f).l;
        Value *var = slot_of(s->sym, f);
        double idx = 0.0;
        while (idx < rt_list_len(l)) {
            var->n = rt_list_get(l, idx, s->line);
            Flow fl = exec_list(s->body, f);
            if (fl == F_STOP)
                break;
            if (fl == F_RETURN)
                return fl;
            idx += 1.0;
        }
        break;
    }
    case S_REPEAT: {
        int n = rt_loop_count(eval(s->e1, f).n, s->line);
        for (int i = 0; i < n; i++) {
            Flow fl = exec_list(s->body, f);
            if (fl == F_STOP)
                break;
            if (fl == F_RETURN)
                return fl;
        }
        break;
    }
    case S_STOP:
        return F_STOP;
    case S_SKIP:
        return F_SKIP;
    case S_RETURN:
        if (s->e1)
            f->ret = eval(s->e1, f).n;
        return F_RETURN;
    case S_FN:
    case S_TRACK:
        break;                  /* definitions do nothing when reached */
    case S_PLAY:
        do_play(s, f);
        break;
    case S_EXPR:
        eval(s->e1, f);
        break;
    }
    return F_NORMAL;
}

static Flow exec_list(Stmt *s, Frame *f)
{
    for (; s; s = s->next) {
        Flow fl = exec(s, f);
        if (fl != F_NORMAL)
            return fl;
    }
    return F_NORMAL;
}

/* ======================================================================== */
/* main                                                                      */
/* ======================================================================== */

void yyerror(const char *msg)
{
    fprintf(stderr, "%s:%d: error: %s\n", rh_filename, yylloc.first_line, msg);
    rh_nerrors++;
}

static void usage(const char *prog_name)
{
    fprintf(stderr,
        "RHYTHM interpreter\n"
        "usage: %s [-o file.wav] [-n] program.rhy\n"
        "  -o file.wav   where play statements write their audio (default rhythm.wav)\n"
        "  -n            do not write audio files, only print the timeline\n"
        "  -h            show this help\n", prog_name);
}

int main(int argc, char **argv)
{
    const char *input = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            eng_set_output(argv[++i]);
        } else if (strcmp(argv[i], "-n") == 0) {
            eng_set_audio(0);
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
        fprintf(stderr, "%d error%s found, the program was not run\n",
                rh_nerrors, rh_nerrors == 1 ? "" : "s");
        return 1;
    }

    rt_set_source(input);
    gvars = calloc(prog.nglobals ? prog.nglobals : 1, sizeof(Value));
    Frame mainf;
    mainf.v = calloc(prog.main_slots ? prog.main_slots : 1, sizeof(Value));
    mainf.ret = 0.0;
    if (!gvars || !mainf.v) {
        fprintf(stderr, "out of memory\n");
        return 2;
    }
    exec_list(prog.stmts, &mainf);
    return rt_finish();
}
