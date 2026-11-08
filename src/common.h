/*
 * common.h  --  small helpers shared by the RHYTHM interpreter and compiler:
 * error reporting, note name conversion and a growable text buffer.
 */
#ifndef RHYTHM_COMMON_H
#define RHYTHM_COMMON_H

#include <stddef.h>

extern const char *rh_filename;     /* name of the source file, used in messages */
extern int rh_nerrors;
extern int rh_nwarnings;

void rh_error(int line, const char *fmt, ...);
void rh_warn(int line, const char *fmt, ...);

/* Turns a note name such as C4, F#3 or Bb5 into a MIDI number.
 * Returns 0 (after reporting an error) when the name is not valid. */
int rh_note_to_midi(const char *name, int line, int *midi);

/* tiny growable string buffer, used by the code generator */
typedef struct {
    char *s;
    size_t n, cap;
} Sbuf;

void sb_printf(Sbuf *b, const char *fmt, ...);

#endif
