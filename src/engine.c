#include "engine.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAMPLE_RATE 44100
#define PI 3.14159265358979323846

typedef struct {
    int midi;           /* negative for a rest */
    double beats;
    int simul;          /* 1: the next event starts together with this one */
} EEvent;

typedef struct {
    char name[64];
    int wave;
    int vol;
    EEvent *ev;
    int n, cap;
    double beats;       /* length of the track */
} ETrack;

static ETrack *trk = NULL;
static int nt = 0, cap_t = 0;
static int cur_tempo = 120;
static int audio_on = 1;
static char out_base[512] = "rhythm.wav";
static int play_count = 0;
static int failed = 0;

static const char *wave_names[4] = { "sine", "square", "saw", "triangle" };

void eng_set_audio(int on) { audio_on = on; }

void eng_set_output(const char *path)
{
    snprintf(out_base, sizeof out_base, "%s", path);
}

int eng_status(void) { return failed; }

const char *eng_note_name(int midi, char *buf)
{
    static const char *names[12] = { "C", "C#", "D", "D#", "E", "F",
                                     "F#", "G", "G#", "A", "A#", "B" };
    sprintf(buf, "%s%d", names[midi % 12], midi / 12 - 1);
    return buf;
}

static void free_tracks(void)
{
    for (int i = 0; i < nt; i++)
        free(trk[i].ev);
    nt = 0;
}

void eng_begin(int tempo)
{
    free_tracks();
    cur_tempo = tempo;
}

void eng_track(const char *name)
{
    if (nt == cap_t) {
        cap_t = cap_t ? cap_t * 2 : 8;
        trk = realloc(trk, cap_t * sizeof(ETrack));
        if (!trk) { perror("realloc"); exit(2); }
    }
    ETrack *t = &trk[nt++];
    memset(t, 0, sizeof *t);
    snprintf(t->name, sizeof t->name, "%s", name);
    t->wave = 0;
    t->vol = 80;
}

void eng_set_wave(int wave)
{
    if (nt > 0)
        trk[nt - 1].wave = wave;
}

void eng_set_volume(int volume)
{
    if (nt > 0)
        trk[nt - 1].vol = volume;
}

static void add(int midi, double beats, int simul)
{
    if (nt == 0)
        return;
    ETrack *t = &trk[nt - 1];
    if (t->n == t->cap) {
        t->cap = t->cap ? t->cap * 2 : 32;
        t->ev = realloc(t->ev, t->cap * sizeof(EEvent));
        if (!t->ev) { perror("realloc"); exit(2); }
    }
    t->ev[t->n].midi = midi;
    t->ev[t->n].beats = beats;
    t->ev[t->n].simul = simul;
    t->n++;
    if (!simul)
        t->beats += beats;
}

void eng_note(int midi, double beats, int simul) { add(midi, beats, simul); }
void eng_rest(double beats) { add(-1, beats, 0); }

/* ------------------------------------------------------------------------ */
/* synthesis                                                                */
/* ------------------------------------------------------------------------ */

static double osc(int wave, double ph)
{
    switch (wave) {
    case 1:  return ph < 0.5 ? 0.6 : -0.6;              /* square */
    case 2:  return (2.0 * ph - 1.0) * 0.7;             /* saw */
    case 3:  return 1.0 - 4.0 * fabs(ph - 0.5);         /* triangle */
    default: return sin(2.0 * PI * ph);                 /* sine */
    }
}

static void put16(FILE *f, unsigned v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); }
static void put32(FILE *f, unsigned v) { put16(f, v & 0xFFFF); put16(f, (v >> 16) & 0xFFFF); }

static int write_wav(const char *path, const int16_t *pcm, long n)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return -1;
    unsigned bytes = (unsigned)(n * 2);
    fwrite("RIFF", 1, 4, f);
    put32(f, 36 + bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16);
    put16(f, 1);                  /* PCM */
    put16(f, 1);                  /* mono */
    put32(f, SAMPLE_RATE);
    put32(f, SAMPLE_RATE * 2);
    put16(f, 2);
    put16(f, 16);
    fwrite("data", 1, 4, f);
    put32(f, bytes);
    for (long i = 0; i < n; i++)
        put16(f, (unsigned)(uint16_t)pcm[i]);
    return fclose(f);
}

static void print_timeline(int index, double total_beats, double spb)
{
    printf("[play %d] %d track%s, %d BPM, %g beats (%.2f seconds)\n",
           index, nt, nt == 1 ? "" : "s", cur_tempo, total_beats, total_beats * spb);
    for (int i = 0; i < nt; i++) {
        ETrack *t = &trk[i];
        printf("  %-10s [%s, volume %d] %g beats:", t->name, wave_names[t->wave], t->vol, t->beats);
        int shown = t->n < 10 ? t->n : 10;
        for (int k = 0; k < shown; k++) {
            char nb[16];
            if (t->ev[k].midi < 0)
                printf(" rest/%g", t->ev[k].beats);
            else
                printf(" %s/%g%s", eng_note_name(t->ev[k].midi, nb), t->ev[k].beats,
                       t->ev[k].simul ? "&" : "");
        }
        if (t->n > shown)
            printf(" ... (%d more)", t->n - shown);
        printf("\n");
    }
}

static void output_name(const char *given, char *buf, size_t sz)
{
    if (given) {
        snprintf(buf, sz, "%s", given);
        return;
    }
    if (play_count == 1) {
        snprintf(buf, sz, "%s", out_base);
        return;
    }
    const char *dot = strrchr(out_base, '.');
    const char *slash = strrchr(out_base, '/');
    if (dot && (!slash || dot > slash))
        snprintf(buf, sz, "%.*s_%d%s", (int)(dot - out_base), out_base, play_count, dot);
    else
        snprintf(buf, sz, "%s_%d", out_base, play_count);
}

int eng_end(const char *outfile)
{
    play_count++;
    if (nt == 0)
        return 0;

    double spb = 60.0 / cur_tempo;
    double total = 0.0;
    for (int i = 0; i < nt; i++)
        if (trk[i].beats > total)
            total = trk[i].beats;

    print_timeline(play_count, total, spb);

    if (!audio_on) {
        printf("  audio output is switched off, nothing written\n");
        return 0;
    }

    long n = (long)ceil(total * spb * SAMPLE_RATE) + 1;
    float *mix = calloc((size_t)n, sizeof(float));
    int16_t *pcm = malloc((size_t)n * sizeof(int16_t));
    if (!mix || !pcm) { fprintf(stderr, "out of memory\n"); exit(2); }

    for (int i = 0; i < nt; i++) {
        ETrack *t = &trk[i];
        double gain = (t->vol / 100.0) * 0.5;
        double pos = 0.0;
        for (int k = 0; k < t->n; k++) {
            double beats = t->ev[k].beats;
            if (t->ev[k].midi >= 0) {
                long start = (long)llround(pos * spb * SAMPLE_RATE);
                long len = (long)llround(beats * spb * SAMPLE_RATE);
                double freq = 440.0 * pow(2.0, (t->ev[k].midi - 69) / 12.0);
                double dur = len / (double)SAMPLE_RATE;
                double att = dur * 0.25 < 0.01 ? dur * 0.25 : 0.01;
                double rel = dur * 0.25 < 0.03 ? dur * 0.25 : 0.03;
                for (long s = 0; s < len && start + s < n; s++) {
                    double tt = s / (double)SAMPLE_RATE;
                    double env = 1.0;
                    if (att > 0 && tt < att)
                        env = tt / att;
                    if (rel > 0 && tt > dur - rel)
                        env = (dur - tt) / rel;
                    if (env < 0) env = 0;
                    double ph = fmod(freq * tt, 1.0);
                    mix[start + s] += (float)(osc(t->wave, ph) * env * gain);
                }
            }
            if (!t->ev[k].simul)
                pos += beats;
        }
    }

    float peak = 0.0f;
    for (long i = 0; i < n; i++)
        if (fabsf(mix[i]) > peak)
            peak = fabsf(mix[i]);
    float scale = peak > 0.95f ? 0.95f / peak : 1.0f;
    for (long i = 0; i < n; i++)
        pcm[i] = (int16_t)lrintf(mix[i] * scale * 32767.0f);

    char name[600];
    output_name(outfile, name, sizeof name);
    if (write_wav(name, pcm, n) != 0) {
        fprintf(stderr, "error: could not write '%s'\n", name);
        failed = 1;
    } else {
        printf("  wrote %s\n", name);
    }
    free(mix);
    free(pcm);
    return failed;
}
