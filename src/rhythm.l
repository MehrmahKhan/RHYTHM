/*
 * rhythm.l  --  Flex lexer for RHYTHM.
 * The same scanner is linked into both the interpreter and the compiler.
 * "parser.h" is the header Bison generates, and the Makefile points the
 * include path at the right copy for each build.
 */
%option noyywrap yylineno nounput noinput

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "common.h"
#include "ast.h"
#include "parser.h"

#define YY_USER_ACTION \
    yylloc.first_line = yylloc.last_line = yylineno; \
    yylloc.first_column = yylloc.last_column = 0;

static int comment_start = 0;
%}

%x COMMENT
DIGIT [0-9]

%%

[ \t\r\n]+                 { /* whitespace */ }
"//".*                     { /* line comment */ }
"#".*                      { /* line comment */ }

"/*"                       { comment_start = yylineno; BEGIN(COMMENT); }
<COMMENT>"*/"              { BEGIN(INITIAL); }
<COMMENT>(.|\n)            { }
<COMMENT><<EOF>>           { rh_error(comment_start, "unterminated /* comment"); BEGIN(INITIAL); return 0; }

"tempo"                    { return TEMPO; }
"track"                    { return TRACK; }
"note"                     { return NOTE; }
"rest"                     { return REST; }
"chord"                    { return CHORD; }
"for"                      { return FOR; }
"beats"|"beat"             { return BEAT; }
"repeat"                   { return REPEAT; }
"times"|"time"             { return TIMES; }
"play"                     { return PLAY; }
"to"                       { return TO; }
"instrument"               { return INSTRUMENT; }
"volume"                   { return VOLUME; }
"fn"                       { return FN; }
"return"                   { return RETURN; }
"let"                      { return LET; }
"if"                       { return IF; }
"else"                     { return ELSE; }
"while"                    { return WHILE; }
"in"                       { return IN; }
"by"                       { return BY; }
"stop"                     { return STOP; }
"skip"                     { return SKIP; }
"say"                      { return SAY; }
"list"                     { return LIST; }
"and"                      { return AND; }
"or"                       { return OR; }
"not"                      { return NOT; }

"sine"                     { yylval.ival = 0; return WAVE; }
"square"                   { yylval.ival = 1; return WAVE; }
"saw"                      { yylval.ival = 2; return WAVE; }
"triangle"                 { yylval.ival = 3; return WAVE; }

{DIGIT}+("."{DIGIT}+)?     { yylval.num = atof(yytext); return NUMBER; }
"."{DIGIT}+                { yylval.num = atof(yytext); return NUMBER; }

[A-Z][#b]?{DIGIT}+         { yylval.str = strdup(yytext); return NOTENAME; }
[A-Za-z_][A-Za-z0-9_]*     { yylval.str = strdup(yytext); return IDENT; }

\"[^"\n]*\"                { yytext[yyleng - 1] = '\0'; yylval.str = strdup(yytext + 1); return STRING; }

".."                       { return DOTDOT; }
"=="                       { return EQ; }
"!="                       { return NE; }
"<="                       { return LE; }
">="                       { return GE; }
"+="                       { return PLUSEQ; }
"-="                       { return MINUSEQ; }
"*="                       { return STAREQ; }
"/="                       { return SLASHEQ; }
[-+*/%<>=(){}\[\];,]       { return yytext[0]; }

.                          { rh_error(yylineno, "unexpected character '%c'", yytext[0]); }

%%
