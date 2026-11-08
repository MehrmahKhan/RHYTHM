/*
 * ast.h  --  syntax tree of a RHYTHM program.
 *
 * The Bison actions in interp.y and compiler.y build this tree while parsing.
 * ast.c then runs the semantic analysis over it (names, types, contexts), and
 * after that the interpreter executes it, or the compiler turns it into
 * LLVM IR. The tree is shared, the two phases only differ in what they do
 * with it afterwards.
 */
#ifndef RHYTHM_AST_H
#define RHYTHM_AST_H

#include "common.h"

typedef enum { T_NUM, T_LIST } Type;

typedef struct Sym Sym;
typedef struct Expr Expr;
typedef struct Stmt Stmt;
typedef struct Func Func;

/* a declared variable. Locals live in a numbered slot of their function's
 * frame, globals in a numbered slot of the global table. */
struct Sym {
    char *name;
    Type type;
    int global;
    int slot;
    int id;          /* unique number, used to name things in the LLVM IR */
    int line;
};

typedef enum {
    EX_NUM, EX_VAR, EX_INDEX, EX_LIST, EX_CALL, EX_BUILTIN, EX_NEG, EX_NOT, EX_BIN
} ExKind;

typedef enum {
    OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD,
    OP_LT, OP_LE, OP_GT, OP_GE, OP_EQ, OP_NE,
    OP_AND, OP_OR
} BinOp;

typedef enum {
    B_LEN, B_FLOOR, B_ABS, B_SQRT, B_MIN, B_MAX, B_POW,
    B_PUSH, B_POP, B_ZEROS, B_COPY, B_RAND, B_SEED
} Builtin;

typedef struct {
    const char *name;
    int bi;
    int nargs;
    Type argt[2];
    Type ret;
} BuiltinInfo;

struct Expr {
    ExKind kind;
    int line;
    BinOp op;
    double num;          /* EX_NUM */
    char *name;          /* EX_VAR, EX_CALL */
    Sym *sym;            /* EX_VAR, filled in by the analysis */
    Func *fn;            /* EX_CALL */
    int bi;              /* EX_BUILTIN */
    Type type;           /* result type, filled in by the analysis */
    Expr *a, *b;         /* operands, or list and index for EX_INDEX */
    Expr *args;          /* call arguments or list elements */
    Expr *next;          /* next argument in a list */
};

typedef enum {
    S_LET, S_ASSIGN, S_TEMPO, S_NOTE, S_REST, S_CHORD, S_WAVE, S_VOLUME, S_SAY,
    S_IF, S_WHILE, S_FORRANGE, S_FOREACH, S_REPEAT, S_STOP, S_SKIP, S_RETURN,
    S_FN, S_TRACK, S_PLAY, S_EXPR
} StKind;

typedef struct Param {
    char *name;
    Type type;
    struct Param *next;
} Param;

typedef struct PlayItem {
    char *name;
    Func *track;
    Expr *count;
    int line;
    struct PlayItem *next;
} PlayItem;

typedef struct SayItem {
    char *str;           /* a string, or NULL when e is used */
    Expr *e;
    struct SayItem *next;
} SayItem;

struct Stmt {
    StKind kind;
    int line;
    Stmt *next;
    Expr *e1, *e2, *e3;
    Expr *target;        /* S_ASSIGN: a variable or an element of a list */
    int compound;        /* S_ASSIGN: 1 for += -= *= /= */
    BinOp op;
    char *name;          /* S_LET, loop variable, function or track name */
    Sym *sym;            /* S_LET, S_FORRANGE, S_FOREACH */
    Stmt *body, *els;
    int ival;            /* S_WAVE: the instrument */
    char *file;          /* S_PLAY: output file or NULL */
    PlayItem *items;
    SayItem *say;
    Param *params;
    Func *fn;            /* S_FN, S_TRACK */
};

struct Func {
    char *name;
    int line;
    int is_track;
    int nparams;
    Type *ptype;
    Sym **psym;
    Stmt *body;
    int nslots;          /* size of the frame */
};

typedef struct {
    Stmt *stmts;
    Func **funcs;
    int nfuncs;
    Func **tracks;
    int ntracks;
    int main_slots;
    int nglobals;
} Program;

extern Program prog;

/* ---- constructors used by the parser ------------------------------------ */
Expr *ex_num(double v, int line);
Expr *ex_var(char *name, int line);
Expr *ex_index(Expr *list, Expr *index, int line);
Expr *ex_list(Expr *elems, int line);
Expr *ex_call(char *name, Expr *args, int line);
Expr *ex_unary(ExKind k, Expr *a, int line);
Expr *ex_bin(BinOp op, Expr *a, Expr *b, int line);
Expr *ex_append(Expr *list, Expr *e);

Stmt *st_new(StKind k, int line);
Stmt *st_append(Stmt *list, Stmt *s);

Param *par_new(char *name, Type t);
Param *par_append(Param *list, Param *p);
PlayItem *pi_new(char *name, Expr *count, int line);
PlayItem *pi_append(PlayItem *list, PlayItem *p);
SayItem *si_new(char *str, Expr *e);
SayItem *si_append(SayItem *list, SayItem *s);

/* ---- semantic analysis -------------------------------------------------- */
void sem_analyze(void);

#endif
