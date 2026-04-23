# ardop-ip Makefile
# Builds ardop-ip: ARDOP OFDM core + TUN network interface + Icom CI-V control
#
# Source layout:
#   src/ardopc/ardop2ofdm/  — upstream DigitalHERMES/ardopc (git submodule)
#   src/                    — new files: tun_interface, civ_control, stubs
#   tests/                  — Unity-based unit tests

CC      = gcc

# Flags for our new source files (strict)
CFLAGS  = -DLINBPQ -g -Wall -I src -I src/ardopc/ardop2ofdm -I tests

# Flags for upstream ardopc submodule — warnings suppressed (not our code)
ARDOPC_CFLAGS = -DLINBPQ -g -w -I src -I src/ardopc/ardop2ofdm

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
	src/civ_control.c

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

TEST_BINS = tests/test_tun

clean:
	rm -f ardop-ip $(TEST_BINS) $(OBJS) $(OBJS:.o=.d) tests/*.o tests/*.d

# ── Phase 2: TUN unit tests ───────────────────────────────────────────────
test_tun: tests/test_tun
	sudo tests/test_tun

UNITY_OBJS = tests/unity.o

tests/unity.o: tests/unity.c tests/unity.h tests/unity_internals.h
	$(CC) $(CFLAGS) -MMD -c $< -o $@

tests/test_tun: tests/test_tun.c src/tun_interface.o $(UNITY_OBJS)
	$(CC) $(CFLAGS) $^ -o $@

# ── Phase 3+: placeholder targets added as tests are written ─────────────
test: test_tun
