# ardop-ip Makefile
# Builds ardop-ip: ARDOP OFDM core + TUN network interface + Icom CI-V control
#
# Source layout:
#   src/ardopc/ardop2ofdm/  — upstream DigitalHERMES/ardopc (git submodule)
#   src/                    — new files: tun_interface, civ_control, stubs
#   tests/                  — Unity-based unit tests

CC      = gcc

# Flags for our new source files (strict)
CFLAGS  = -DLINBPQ -g -Wall -I src -I src/ardopc/ardop2ofdm

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

clean:
	rm -f ardop-ip $(OBJS) $(OBJS:.o=.d)

# ── Test targets (Phase 2+) ───────────────────────────────────────────────
test: tests/test_tun tests/test_civ tests/test_fec tests/test_arq
	@echo "Running unit tests..."
	@sudo tests/test_tun    && echo "  test_tun:  PASS"
	@       tests/test_civ  && echo "  test_civ:  PASS"
	@       tests/test_fec  && echo "  test_fec:  PASS"
	@       tests/test_arq  && echo "  test_arq:  PASS"

tests/test_tun: tests/test_tun.c src/tun_interface.o
	$(CC) $(CFLAGS) $^ -o $@

tests/test_civ: tests/test_civ.c src/civ_control.o $(ARDOPC)/LinSerial.o
	$(CC) $(CFLAGS) $^ -o $@

tests/test_fec: tests/test_fec.c \
	$(ARDOPC)/FEC.o $(ARDOPC)/rs.o $(ARDOPC)/berlekamp.o $(ARDOPC)/galois.o \
	$(ARDOPC)/ARDOPC.o $(ARDOPC)/ALSASound.o $(ARDOPC)/ardopSampleArrays.o \
	$(ARDOPC)/Modulate.o $(ARDOPC)/CalcTemplates.o $(ARDOPC)/FFT.o \
	$(ARDOPC)/ofdm.o $(ARDOPC)/SoundInput.o $(ARDOPC)/ARQ.o \
	$(ARDOPC)/BusyDetect.o $(ARDOPC)/LinSerial.o \
	$(ARDOPC)/HostInterface.o $(ARDOPC)/KISSModule.o \
	$(ARDOPC)/TCPHostInterface.o \
	src/stubs.o src/tun_interface.o src/civ_control.o
	$(CC) $(CFLAGS) $^ $(LIBS) -o $@

tests/test_arq: tests/test_arq.c \
	$(ARDOPC)/ARQ.o $(ARDOPC)/FEC.o $(ARDOPC)/rs.o \
	$(ARDOPC)/berlekamp.o $(ARDOPC)/galois.o \
	$(ARDOPC)/ARDOPC.o $(ARDOPC)/ALSASound.o $(ARDOPC)/ardopSampleArrays.o \
	$(ARDOPC)/Modulate.o $(ARDOPC)/CalcTemplates.o $(ARDOPC)/FFT.o \
	$(ARDOPC)/ofdm.o $(ARDOPC)/SoundInput.o \
	$(ARDOPC)/BusyDetect.o $(ARDOPC)/LinSerial.o \
	$(ARDOPC)/HostInterface.o $(ARDOPC)/KISSModule.o \
	$(ARDOPC)/TCPHostInterface.o \
	src/stubs.o src/tun_interface.o src/civ_control.o
	$(CC) $(CFLAGS) $^ $(LIBS) -o $@
