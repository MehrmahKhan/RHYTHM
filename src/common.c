#include "common.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *rh_filename = "<stdin>";
int rh_nerrors = 0;
int rh_nwarnings = 0;

static void report(const char *kind, int line, const char *fmt, va_list ap)
{
    fprintf(stderr, "%s:%d: %s: ", rh_filename, line, kind);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
}

void rh_error(int line, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    report("error", line, fmt, ap);
    va_end(ap);
    rh_nerrors++;
}

void rh_warn(int line, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    report("warning", line, fmt, ap);
    va_end(ap);
    rh_nwarnings++;
}

int rh_note_to_midi(const char *name, int line, int *midi)
{
    static const int semis[7] = { 9, 11, 0, 2, 4, 5, 7 };   /* A B C D E F G */
    const char *p = name;
    int letter = *p++;
    int acc = 0;

    if (letter < 'A' || letter > 'G') {
        rh_error(line, "invalid note name '%s': the letter must be between A and G", name);
        return 0;
    }
    if (*p == '#') { acc = 1; p++; }
    else if (*p == 'b') { acc = -1; p++; }

    long oct = strtol(p, NULL, 10);
    if (oct < 0 || oct > 8) {
        rh_error(line, "invalid note name '%s': the octave must be between 0 and 8", name);
        return 0;
    }
    *midi = 12 * ((int)oct + 1) + semis[letter - 'A'] + acc;
    return 1;
}

void sb_printf(Sbuf *b, const char *fmt, ...)
{
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need < 0) { va_end(ap2); return; }
    if (b->n + (size_t)need + 1 > b->cap) {
        size_t nc = b->cap ? b->cap : 256;
        while (nc < b->n + (size_t)need + 1)
            nc *= 2;
        b->s = realloc(b->s, nc);
        if (!b->s) { perror("realloc"); exit(2); }
        b->cap = nc;
    }
    vsnprintf(b->s + b->n, b->cap - b->n, fmt, ap2);
    va_end(ap2);
    b->n += (size_t)need;
}
