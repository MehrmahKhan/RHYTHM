#include "rtlib.h"

#include "checks.h"
#include "engine.h"

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *src_name = "<stdin>";
static int in_track = 0;
static int tempo = 120;
static int tempo_set = 0;
static int tempo_warned = 0;
static int depth = 0;
static int say_first = 1;
static uint64_t rng = 88172645463325252ULL;

/* ------------------------------------------------------------------------ */
/* start up, shut down, failures                                            */
/* ------------------------------------------------------------------------ */

void rt_set_source(const char *srcname)
{
    src_name = srcname;
}

void rt_init(int argc, char **argv, const char *srcname)
{
    src_name = srcname;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            eng_set_output(argv[++i]);
        } else if (strcmp(argv[i], "-n") == 0) {
            eng_set_audio(0);
        } else if (strcmp(argv[i], "-h") == 0) {
            printf("compiled RHYTHM program (%s)\n"
                   "usage: %s [-o file.wav] [-n]\n"
                   "  -o file.wav   where play statements write their audio (default rhythm.wav)\n"
                   "  -n            do not write audio files, only print the timeline\n",
                   srcname, argv[0]);
            exit(0);
        } else {
            fprintf(stderr, "unknown option '%s' (try -h)\n", argv[i]);
            exit(2);
        }
    }
}

int rt_finish(void)
{
    fflush(stdout);
    return eng_status();
}

void rt_fail(int line, const char *fmt, ...)
{
    va_list ap;
    fflush(stdout);
    fprintf(stderr, "%s:%d: runtime error: ", src_name, line);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

/* ------------------------------------------------------------------------ */
/* music                                                                    */
/* ------------------------------------------------------------------------ */

void rt_set_tempo(double bpm, int line)
{
    char buf[200];
    const char *msg = chk_tempo(bpm, buf, sizeof buf);
    if (msg)
        rt_fail(line, "%s", msg);
    tempo = (int)bpm;
    tempo_set = 1;
}

void rt_session_begin(int line)
{
    if (!tempo_set && !tempo_warned) {
        fprintf(stderr, "%s:%d: warning: no tempo was set before play, using the default of %d BPM\n",
                src_name, line, tempo);
        tempo_warned = 1;
    }
    eng_begin(tempo);
    in_track = 0;
}

void rt_track_begin(const char *name)
{
    eng_track(name);
    in_track = 1;
}

void rt_session_end(const char *file)
{
    eng_end(file);
    in_track = 0;
}

static void need_track(int line, const char *what)
{
    if (!in_track)
        rt_fail(line, "%s can only happen while a track is playing", what);
}

void rt_note(double midi, double beats, int line)
{
    char buf[200];
    const char *msg;
    need_track(line, "a note");
    if ((msg = chk_note_number(midi, buf, sizeof buf)) != NULL)
        rt_fail(line, "%s", msg);
    if ((msg = chk_duration(beats, buf, sizeof buf)) != NULL)
        rt_fail(line, "%s", msg);
    eng_note((int)midi, beats, 0);
}

void rt_rest(double beats, int line)
{
    char buf[200];
    const char *msg;
    need_track(line, "a rest");
    if ((msg = chk_duration(beats, buf, sizeof buf)) != NULL)
        rt_fail(line, "%s", msg);
    eng_rest(beats);
}

void rt_chord(List *notes, double beats, int line)
{
    char buf[200];
    const char *msg;
    need_track(line, "a chord");
    if (notes->n == 0)
        rt_fail(line, "a chord needs at least one note");
    for (int i = 0; i < notes->n; i++)
        if ((msg = chk_note_number(notes->a[i], buf, sizeof buf)) != NULL)
            rt_fail(line, "%s", msg);
    if ((msg = chk_duration(beats, buf, sizeof buf)) != NULL)
        rt_fail(line, "%s", msg);
    for (int i = 0; i < notes->n; i++)
        eng_note((int)notes->a[i], beats, i < notes->n - 1);
}

void rt_set_wave(int wave, int line)
{
    need_track(line, "setting the instrument");
    eng_set_wave(wave);
}

void rt_set_volume(double v, int line)
{
    char buf[200];
    const char *msg;
    need_track(line, "setting the volume");
    if ((msg = chk_volume(v, buf, sizeof buf)) != NULL)
        rt_fail(line, "%s", msg);
    eng_set_volume((int)v);
}

/* ------------------------------------------------------------------------ */
/* loops and calls                                                          */
/* ------------------------------------------------------------------------ */

int rt_play_count(double v, int line)
{
    char buf[200];
    const char *msg = chk_play_count(v, buf, sizeof buf);
    if (msg)
        rt_fail(line, "%s", msg);
    return (int)v;
}

int rt_loop_count(double v, int line)
{
    char buf[200];
    const char *msg = chk_loop_count(v, buf, sizeof buf);
    if (msg)
        rt_fail(line, "%s", msg);
    return (int)v;
}

void rt_check_step(double step, int line)
{
    if (!(step > 0.0 || step < 0.0))
        rt_fail(line, "a for loop cannot have a step of 0");
}

void rt_enter(int line)
{
    if (++depth > RH_MAX_CALL_DEPTH)
        rt_fail(line, "recursion is too deep (the limit is %d nested calls)", RH_MAX_CALL_DEPTH);
}

void rt_leave(void)
{
    depth--;
}

/* ------------------------------------------------------------------------ */
/* arithmetic                                                               */
/* ------------------------------------------------------------------------ */

double rt_div(double a, double b, int line)
{
    if (b == 0.0)
        rt_fail(line, "division by zero");
    return a / b;
}

double rt_mod(double a, double b, int line)
{
    if (b == 0.0)
        rt_fail(line, "modulo by zero");
    return fmod(a, b);
}

/* ------------------------------------------------------------------------ */
/* lists                                                                    */
/* ------------------------------------------------------------------------ */

static void *xalloc(size_t n)
{
    void *p = calloc(1, n ? n : 1);
    if (!p) {
        fprintf(stderr, "out of memory\n");
        exit(2);
    }
    return p;
}

List *rt_list_new(double n, int line)
{
    if (n != floor(n) || n < 0 || n > RH_MAX_LOOP_COUNT)
        rt_fail(line, "invalid list size %g: it must be a whole number between 0 and %d",
                n, RH_MAX_LOOP_COUNT);
    List *l = xalloc(sizeof *l);
    l->n = (int)n;
    l->cap = l->n < 4 ? 4 : l->n;
    l->a = xalloc((size_t)l->cap * sizeof(double));
    return l;
}

static int check_index(List *l, double i, int line)
{
    if (i != floor(i))
        rt_fail(line, "list index %g is not a whole number", i);
    if (i < 0 || i >= l->n)
        rt_fail(line, "index %g is out of range for a list of length %d", i, l->n);
    return (int)i;
}

double rt_list_get(List *l, double i, int line)
{
    return l->a[check_index(l, i, line)];
}

void rt_list_set(List *l, double i, double v, int line)
{
    l->a[check_index(l, i, line)] = v;
}

double rt_list_len(List *l)
{
    return l->n;
}

double rt_list_push(List *l, double v)
{
    if (l->n == l->cap) {
        l->cap *= 2;
        l->a = realloc(l->a, (size_t)l->cap * sizeof(double));
        if (!l->a) {
            fprintf(stderr, "out of memory\n");
            exit(2);
        }
    }
    l->a[l->n++] = v;
    return l->n;
}

double rt_list_pop(List *l, int line)
{
    if (l->n == 0)
        rt_fail(line, "pop on an empty list");
    return l->a[--l->n];
}

List *rt_list_copy(List *l)
{
    List *c = xalloc(sizeof *c);
    c->n = l->n;
    c->cap = l->n < 4 ? 4 : l->n;
    c->a = xalloc((size_t)c->cap * sizeof(double));
    memcpy(c->a, l->a, (size_t)l->n * sizeof(double));
    return c;
}

/* ------------------------------------------------------------------------ */
/* math builtins                                                            */
/* ------------------------------------------------------------------------ */

double rt_floor(double x) { return floor(x); }
double rt_abs(double x) { return fabs(x); }
double rt_min(double a, double b) { return a < b ? a : b; }
double rt_max(double a, double b) { return a > b ? a : b; }

double rt_sqrt(double x, int line)
{
    if (x < 0)
        rt_fail(line, "sqrt of a negative number (%g)", x);
    return sqrt(x);
}

double rt_pow(double a, double b, int line)
{
    double r = pow(a, b);
    if (!isfinite(r))
        rt_fail(line, "pow(%g, %g) is not a finite number", a, b);
    return r;
}

/* xorshift generator with a fixed start, so a program always plays the same
 * music unless it calls seed(). */
double rt_rand(double n, int line)
{
    if (n != floor(n) || n < 1 || n > 1e9)
        rt_fail(line, "rand needs a whole number between 1 and 1000000000, not %g", n);
    rng ^= rng >> 12;
    rng ^= rng << 25;
    rng ^= rng >> 27;
    uint64_t r = rng * 2685821657736338717ULL;
    return (double)(r % (uint64_t)n);
}

double rt_seed(double v)
{
    uint64_t s = (uint64_t)(int64_t)v * 2654435761ULL + 88172645463325252ULL;
    rng = s ? s : 88172645463325252ULL;
    return 0;
}

/* ------------------------------------------------------------------------ */
/* say                                                                      */
/* ------------------------------------------------------------------------ */

static void sep(void)
{
    if (!say_first)
        putchar(' ');
    say_first = 0;
}

void rt_say_num(double v)
{
    sep();
    printf("%.10g", v);
}

void rt_say_str(const char *s)
{
    sep();
    fputs(s, stdout);
}

void rt_say_list(List *l)
{
    sep();
    putchar('[');
    for (int i = 0; i < l->n; i++) {
        if (i)
            fputs(", ", stdout);
        printf("%.10g", l->a[i]);
    }
    putchar(']');
}

void rt_say_end(void)
{
    putchar('\n');
    say_first = 1;
}
