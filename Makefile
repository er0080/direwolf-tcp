# ardop-ip Makefile
# Builds ardop-ip: ARDOP OFDM core + TUN network interface + Icom CI-V control
#
# Source layout:
#   src/ardopc/ardop2ofdm/  — upstream DigitalHERMES/ardopc (git submodule)
#   src/                    — new files: tun_interface, civ_control, stubs
#   tests/                  — Unity-based unit tests

CC      = gcc

# Flags for our new source files (strict)
CFLAGS  = -DLINBPQ -DARDOP_IP -g -Wall -I src -I src/ardopc/ardop2ofdm -I tests

# Flags for upstream ardopc submodule — warnings suppressed (not our code)
ARDOPC_CFLAGS = -DLINBPQ -DARDOP_IP -g -w -I src -I src/ardopc/ardop2ofdm

ARDOPC  = src/ardopc/ardop2ofdm

# ── Core OFDM / signal processing (kept from ardop2ofdm) ─────────────────
ARDOPC_SRCS = \
	$(ARDOPC)/ARDOPC.c \
	$(ARDOPC)/ALSASound.c \
	$(ARDOPC)/ARQ.c \
	$(ARDOPC)/BusyDetect.c \
	$(ARDOPC)/CalcTemplates.c \
	$(ARDOPC)/FEC.c \
	$(ARDOPC)/FFT.c \
	$(ARDOPC)/HostInterface.c \
	$(ARDOPC)/KISSModule.c \
	$(ARDOPC)/LinSerial.c \
	$(ARDOPC)/Modulate.c \
	$(ARDOPC)/ardopSampleArrays.c \
	$(ARDOPC)/ofdm.c \
	$(ARDOPC)/rs.c \
	$(ARDOPC)/berlekamp.c \
	$(ARDOPC)/galois.c \
	$(ARDOPC)/SoundInput.c \
	$(ARDOPC)/TCPHostInterface.c

# ── New ardop-ip source files ─────────────────────────────────────────────
NEW_SRCS = \
	src/stubs.c \
	src/tun_interface.c \
	src/civ_control.c \
	src/tun_ardopc.c \
	src/main.c

SRCS   = $(ARDOPC_SRCS) $(NEW_SRCS)
OBJS   = $(SRCS:.c=.o)

LIBS   = -lrt -lm -lpthread -lasound

.PHONY: all clean test

all: ardop-ip

ardop-ip: $(OBJS)
	$(CC) $(OBJS) $(LIBS) -o $@

# Upstream ardopc files compiled with warnings suppressed
$(ARDOPC)/%.o: $(ARDOPC)/%.c
	$(CC) $(ARDOPC_CFLAGS) -MMD -c $< -o $@

# Our new files compiled with full warnings
src/%.o: src/%.c
	$(CC) $(CFLAGS) -MMD -c $< -o $@

-include $(OBJS:.o=.d)

TEST_BINS = tests/test_tun tests/test_civ tests/test_fec tests/test_arq

clean:
	rm -f ardop-ip $(TEST_BINS) $(OBJS) $(OBJS:.o=.d) tests/*.o tests/*.d

# ── Phase 2: TUN unit tests ───────────────────────────────────────────────
test_tun: tests/test_tun
	sudo tests/test_tun

UNITY_OBJS    = tests/unity.o
TEST_STUB_OBJ = tests/ardopc_test_stubs.o

tests/ardopc_test_stubs.o: tests/ardopc_test_stubs.c
	$(CC) $(CFLAGS) -MMD -c $< -o $@

tests/unity.o: tests/unity.c tests/unity.h tests/unity_internals.h
	$(CC) $(CFLAGS) -MMD -c $< -o $@

tests/test_tun: tests/test_tun.c src/tun_interface.o $(UNITY_OBJS)
	$(CC) $(CFLAGS) $^ -o $@

# ── Phase 3: CI-V unit tests ──────────────────────────────────────────────
test_civ: tests/test_civ
	tests/test_civ

tests/test_civ: tests/test_civ.c src/civ_control.o $(ARDOPC)/LinSerial.o \
                $(UNITY_OBJS) $(TEST_STUB_OBJ)
	$(CC) $(CFLAGS) $^ -lutil -o $@

# ── Phase 3: FEC unit tests ───────────────────────────────────────────────
test_fec: tests/test_fec
	tests/test_fec

# FEC test only needs the RSCODE library objects (rs, berlekamp, galois)
# plus unity.  No ardopc globals needed.
FEC_RS_OBJS = $(ARDOPC)/rs.o $(ARDOPC)/berlekamp.o $(ARDOPC)/galois.o

tests/test_fec: tests/test_fec.c $(FEC_RS_OBJS) $(UNITY_OBJS) $(TEST_STUB_OBJ)
	$(CC) $(CFLAGS) $^ -o $@

# ── Phase 3: ARQ unit tests ───────────────────────────────────────────────
test_arq: tests/test_arq
	tests/test_arq

ARQ_STUB_OBJ = tests/arq_test_stubs.o

tests/arq_test_stubs.o: tests/arq_test_stubs.c
	$(CC) $(CFLAGS) -MMD -c $< -o $@

# ARQ test links ARQ.o + the comprehensive arq_test_stubs + ardopc_test_stubs + unity
tests/test_arq: tests/test_arq.c $(ARDOPC)/ARQ.o $(UNITY_OBJS) \
                $(ARQ_STUB_OBJ) $(TEST_STUB_OBJ)
	$(CC) $(CFLAGS) $^ -o $@

test: test_tun test_civ test_fec test_arq
