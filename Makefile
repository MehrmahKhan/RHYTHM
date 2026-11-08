# RHYTHM  --  a music based programming language
# Builds the interpreter (Phase 1), the LLVM IR compiler and its runtime (Phase 2).

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-function
FLEX    ?= flex
BISON   ?= bison

SRC     = src
BLD     = build
BIN     = bin

all: $(BIN)/rhythmi $(BIN)/rhythm_ir $(BIN)/librhythm_rt.a

$(BLD) $(BIN) $(BLD)/interp $(BLD)/comp:
	mkdir -p $@

# ---- lexer (generated once, compiled once per parser) ----------------------
$(BLD)/lex.yy.c: $(SRC)/rhythm.l | $(BLD)
	$(FLEX) -o $@ $<

# ---- Phase 1: interpreter ---------------------------------------------------
$(BLD)/interp/interp.tab.c $(BLD)/interp/parser.h: $(SRC)/interp.y | $(BLD)/interp
	$(BISON) -Wall -d --defines=$(BLD)/interp/parser.h -o $(BLD)/interp/interp.tab.c $<

$(BLD)/interp/lex.o: $(BLD)/lex.yy.c $(BLD)/interp/parser.h $(SRC)/ast.h
	$(CC) $(CFLAGS) -I$(SRC) -I$(BLD)/interp -c $< -o $@

$(BLD)/interp/interp.tab.o: $(BLD)/interp/interp.tab.c $(SRC)/ast.h $(SRC)/rtlib.h
	$(CC) $(CFLAGS) -I$(SRC) -I$(BLD)/interp -c $< -o $@

$(BIN)/rhythmi: $(BLD)/interp/interp.tab.o $(BLD)/interp/lex.o $(BLD)/common.o $(BLD)/ast.o $(BLD)/rtlib.o $(BLD)/engine.o | $(BIN)
	$(CC) $(CFLAGS) -o $@ $^ -lm

# ---- Phase 2: compiler (emits LLVM IR) --------------------------------------
$(BLD)/comp/compiler.tab.c $(BLD)/comp/parser.h: $(SRC)/compiler.y | $(BLD)/comp
	$(BISON) -Wall -d --defines=$(BLD)/comp/parser.h -o $(BLD)/comp/compiler.tab.c $<

$(BLD)/comp/lex.o: $(BLD)/lex.yy.c $(BLD)/comp/parser.h $(SRC)/ast.h
	$(CC) $(CFLAGS) -I$(SRC) -I$(BLD)/comp -c $< -o $@

$(BLD)/comp/compiler.tab.o: $(BLD)/comp/compiler.tab.c $(SRC)/ast.h
	$(CC) $(CFLAGS) -I$(SRC) -I$(BLD)/comp -c $< -o $@

$(BIN)/rhythm_ir: $(BLD)/comp/compiler.tab.o $(BLD)/comp/lex.o $(BLD)/common.o $(BLD)/ast.o | $(BIN)
	$(CC) $(CFLAGS) -o $@ $^ -lm

# ---- runtime library that compiled programs link against --------------------
$(BIN)/librhythm_rt.a: $(BLD)/rtlib.o $(BLD)/engine.o | $(BIN)
	ar rcs $@ $^

# ---- plain C files -----------------------------------------------------------
$(BLD)/%.o: $(SRC)/%.c $(SRC)/common.h $(SRC)/ast.h $(SRC)/checks.h $(SRC)/engine.h $(SRC)/rtlib.h | $(BLD)
	$(CC) $(CFLAGS) -I$(SRC) -c $< -o $@

test: all
	./tests/run_tests.sh

clean:
	rm -rf $(BLD) $(BIN) tests/out examples/*.ll

.PHONY: all test clean
