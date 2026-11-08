# RHYTHM

A music based programming language. You write loops, functions and lists, and the program plays a song.
Built for the Compiler Construction course with Flex, Bison and LLVM IR.

Authors: Esha Irfan (23L 0836) and Mehrmah Khan (23L 0623)

There are two phases that share one grammar:

* **Phase 1, interpreter** (`bin/rhythmi`): Flex and Bison parse the program, and C code in `src/interp.y` runs it directly.
* **Phase 2, compiler** (`rhythmc`): the Bison actions in `src/compiler.y` emit LLVM IR, and clang turns that into a native executable.

Both produce the same printed output and the same WAV files. The test suite checks this byte for byte.

## Install (Ubuntu or WSL)

    sudo apt update
    sudo apt install build-essential flex bison clang llvm

LLVM 15 or newer is needed (the IR uses opaque pointers). It was tested with LLVM and clang 18.

## Build and test

    make          # builds bin/rhythmi, bin/rhythm_ir and bin/librhythm_rt.a
    make test     # runs every example and test against both phases

## Run

Interpreter:

    ./bin/rhythmi examples/02_arpeggio.rhy -o song.wav

Compiler (makes a native executable and keeps the `.ll` file):

    ./rhythmc examples/02_arpeggio.rhy -o song
    ./song -o song.wav

Open the `.wav` in any audio player. In WSL you can copy it to Windows, for example
`cp song.wav /mnt/c/Users/YOURNAME/Desktop/`.

## The language

    tempo 120;                       // beats per minute (20 to 400)
    let scale = [0, 2, 4, 5, 7, 9, 11];

    fn arpeggio(root, list steps) {  // functions return a number
        for s in steps {
            note root + s for 0.5 beats;
        }
    }

    track melody {                   // a track is music that runs when played
        instrument triangle;         // sine, square, saw, triangle
        arpeggio(C4, scale);
        arpeggio(C5, scale);
        note C6 for 2 beats;
    }

    track bass {
        instrument square;
        repeat 8 times {
            note C2 for 1 beat;
            rest for 1 beat;
        }
    }

    play melody, bass;               // both tracks start together

Values are numbers and lists. Note names like `C4`, `F#3` and `Bb5` are numbers (C4 is 60), so `C4 + 7` is G4.

| Area | Syntax |
| --- | --- |
| Variables | `let x = 5;` then `x = 6;` `x += 1;` (also `-= *= /=`) `list[i] = v;` |
| Conditions | `if c { } else if c { } else { }` |
| Loops | `while c { }`, `for i in 0..8 { }`, `for i in 0..8 by 2 { }`, `for x in list { }`, `repeat 4 times { }`, `stop;`, `skip;` |
| Functions | `fn name(a, list b) { return a; }` |
| Operators | `+ - * / %`, `< <= > >= == !=`, `and or not` (short circuit) |
| Lists | `[1, 2, 3]`, `xs[i]`, `len`, `push`, `pop`, `zeros`, `copy` |
| Math | `floor abs sqrt min max pow rand seed` |
| Music | `tempo`, `track`, `note X for N beats;`, `rest for N beats;`, `chord [a, b] for N beats;`, `instrument`, `volume 0..100` |
| Playing | `play a, b * 2;` and `play a to "file.wav";`; `play;` plays every track |
| Output | `say "text", value;` |
| Comments | `//`, `#`, `/* */` |

Errors are reported as `file:line: message`. Names, types and constant ranges are checked before anything runs.
Things only known while running (list index, division by zero) stop the program with `runtime error` and exit status 1.

## Examples

| File | What it does |
| --- | --- |
| `01_hello.rhy` | smallest program |
| `02_arpeggio.rhy` | the proposal example: function, list, loops, two tracks |
| `03_twinkle.rhy` | a familiar tune |
| `04_fibonacci.rhy` | recursion turned into a melody |
| `05_sorting.rhy` | bubble sort, played before and after |
| `06_euclid_rhythm.rhy` | Euclid's algorithm as a rhythm |
| `07_primes.rhy` | sieve of Eratosthenes |
| `08_random_walk.rhy` | seeded random melody |
| `09_language_tour.rhy` | every language feature, printed with `say` |

## Files

| File | Purpose |
| --- | --- |
| `src/rhythm.l` | Flex lexer |
| `src/interp.y` | Bison grammar plus the interpreter (Phase 1) |
| `src/compiler.y` | same grammar plus the LLVM IR generator (Phase 2) |
| `src/ast.h`, `src/ast.c` | syntax tree and the semantic checks shared by both phases |
| `src/checks.h` | value range rules shared by compile time and run time checks |
| `src/rtlib.c`, `src/rtlib.h` | runtime library used by the interpreter and by compiled programs |
| `src/engine.c`, `src/engine.h` | sound synthesis and WAV writing |
| `src/common.c`, `src/common.h` | error reporting, note names, string buffer |
| `rhythmc` | script: source to IR to executable |
| `Makefile` | build and test |
| `tests/` | `run_tests.sh`, `programs/`, `errors/` (39 compile errors), `runtime/` (19 run time errors) |

## How it works

The Bison actions build a syntax tree. A semantic pass resolves names, checks types (number or list) and constants,
and numbers the variable slots. In Phase 1 a tree walking evaluator at the bottom of `interp.y` executes the tree.
In Phase 2 the code at the bottom of `compiler.y` writes LLVM IR: functions become `@fn.NAME`, tracks become
`@track.NAME`, control flow becomes basic blocks, and `and` / `or` use a phi node. Both phases call the same runtime library.

Limits: lists are shared by reference (use `copy`), recursion depth is limited to 2000, a track cannot be played from inside another track.
