/*
 * engine.h  --  the sound engine.
 *
 * A "session" is one play statement: eng_begin, then for every track
 * eng_track followed by its notes and rests, then eng_end which prints the
 * timeline and writes the WAV file.
 */
#ifndef RHYTHM_ENGINE_H
#define RHYTHM_ENGINE_H

void eng_set_audio(int on);                 /* 0 disables WAV output */
void eng_set_output(const char *path);      /* default file for plays without "to" */
void eng_begin(int tempo);
void eng_track(const char *name);           /* starts a track: sine, volume 80 */
void eng_set_wave(int wave);                /* applies to the track just started */
void eng_set_volume(int volume);
/* A note. When simul is 1 the next event starts at the same moment (chords). */
void eng_note(int midi, double beats, int simul);
void eng_rest(double beats);
int  eng_end(const char *outfile);          /* outfile may be NULL */
int  eng_status(void);                      /* 0 fine, 1 if a file could not be written */
const char *eng_note_name(int midi, char *buf);

#endif
