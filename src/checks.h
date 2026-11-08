/*
 * checks.h  --  the value rules of the language, in one place.
 *
 * Every function returns NULL when the value is fine, otherwise it writes a
 * message into the buffer and returns it. The compiler front end uses these
 * for constants it can see in the source (so the mistake is caught before the
 * program runs) and the runtime library uses the very same functions for
 * values that are only known while the program runs. That keeps the messages
 * identical in both phases.
 */
#ifndef RHYTHM_CHECKS_H
#define RHYTHM_CHECKS_H

#include <math.h>
#include <stdio.h>

#define RH_MIN_TEMPO 20
#define RH_MAX_TEMPO 400
#define RH_MAX_PLAY_COUNT 1000
#define RH_MAX_LOOP_COUNT 1000000
#define RH_MAX_BEATS 64

static inline const char *chk_tempo(double v, char *b, size_t n)
{
    if (v != floor(v) || v < RH_MIN_TEMPO || v > RH_MAX_TEMPO) {
        snprintf(b, n, "invalid tempo %g: tempo must be a whole number between %d and %d BPM",
                 v, RH_MIN_TEMPO, RH_MAX_TEMPO);
        return b;
    }
    return NULL;
}

static inline const char *chk_duration(double v, char *b, size_t n)
{
    if (!(v > 0.0)) {
        snprintf(b, n, "invalid duration %g: a duration must be greater than zero beats", v);
        return b;
    }
    if (v > RH_MAX_BEATS) {
        snprintf(b, n, "invalid duration %g: a single event can be at most %d beats long",
                 v, RH_MAX_BEATS);
        return b;
    }
    return NULL;
}

static inline const char *chk_volume(double v, char *b, size_t n)
{
    if (v != floor(v) || v < 0 || v > 100) {
        snprintf(b, n, "invalid volume %g: volume must be a whole number between 0 and 100", v);
        return b;
    }
    return NULL;
}

static inline const char *chk_note_number(double v, char *b, size_t n)
{
    if (v != floor(v) || v < 0 || v > 127) {
        snprintf(b, n, "invalid note number %g: notes must be whole numbers between 0 and 127", v);
        return b;
    }
    return NULL;
}

static inline const char *chk_play_count(double v, char *b, size_t n)
{
    if (v != floor(v) || v < 1 || v > RH_MAX_PLAY_COUNT) {
        snprintf(b, n, "invalid repeat count %g: it must be a whole number between 1 and %d",
                 v, RH_MAX_PLAY_COUNT);
        return b;
    }
    return NULL;
}

static inline const char *chk_loop_count(double v, char *b, size_t n)
{
    if (v != floor(v) || v < 0 || v > RH_MAX_LOOP_COUNT) {
        snprintf(b, n, "invalid repeat count %g: it must be a whole number between 0 and %d",
                 v, RH_MAX_LOOP_COUNT);
        return b;
    }
    return NULL;
}

#endif
