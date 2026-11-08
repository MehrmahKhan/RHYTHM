/*
 * rtlib.h  --  the RHYTHM runtime library.
 *
 * Everything that can only be decided while a program runs lives here:
 * the checks on values, lists, random numbers, the output of say, and the
 * hand over to the sound engine. The interpreter calls these functions
 * directly, and the LLVM IR that the compiler writes calls the very same
 * functions (they are linked in as librhythm_rt.a). Because both phases share
 * this code they always behave the same.
 */
#ifndef RHYTHM_RTLIB_H
#define RHYTHM_RTLIB_H

typedef struct List {
    double *a;
    int n, cap;
} List;

#define RH_MAX_CALL_DEPTH 2000

/* start up and shut down */
void rt_init(int argc, char **argv, const char *srcname);   /* for compiled programs */
void rt_set_source(const char *srcname);                    /* for the interpreter */
int  rt_finish(void);                                       /* returns the exit code */

void rt_fail(int line, const char *fmt, ...) __attribute__((noreturn, format(printf, 2, 3)));

/* music */
void rt_set_tempo(double bpm, int line);
void rt_session_begin(int line);
void rt_track_begin(const char *name);
void rt_session_end(const char *file);
void rt_note(double midi, double beats, int line);
void rt_rest(double beats, int line);
void rt_chord(List *notes, double beats, int line);
void rt_set_wave(int wave, int line);
void rt_set_volume(double v, int line);

/* loops and calls */
int  rt_play_count(double v, int line);
int  rt_loop_count(double v, int line);
void rt_check_step(double step, int line);
void rt_enter(int line);
void rt_leave(void);

/* arithmetic that can fail */
double rt_div(double a, double b, int line);
double rt_mod(double a, double b, int line);

/* lists */
List  *rt_list_new(double n, int line);
double rt_list_get(List *l, double i, int line);
void   rt_list_set(List *l, double i, double v, int line);
double rt_list_len(List *l);
double rt_list_push(List *l, double v);
double rt_list_pop(List *l, int line);
List  *rt_list_copy(List *l);

/* math builtins */
double rt_floor(double x);
double rt_abs(double x);
double rt_sqrt(double x, int line);
double rt_pow(double a, double b, int line);
double rt_min(double a, double b);
double rt_max(double a, double b);
double rt_rand(double n, int line);
double rt_seed(double v);

/* say */
void rt_say_num(double v);
void rt_say_str(const char *s);
void rt_say_list(List *l);
void rt_say_end(void);

#endif
