PREFIX   ?= /usr
BIN_DIR   = $(DESTDIR)$(PREFIX)/bin
SBIN_DIR  = $(DESTDIR)$(PREFIX)/sbin
LIB_DIR   = $(DESTDIR)$(PREFIX)/lib/dw-iface
MAN8_DIR  = $(DESTDIR)$(PREFIX)/share/man/man8
ETC_DIR   = $(DESTDIR)/etc/dw-iface
SYS_DIR   = $(DESTDIR)/lib/systemd/system
UDEV_DIR  = $(DESTDIR)/lib/udev/rules.d

.PHONY: all install uninstall

all:
	@echo "Run 'sudo make install' to install dw-iface."
	@echo "Run 'dpkg-buildpackage -b -us -uc' to build a .deb package."

install:
	install -d $(BIN_DIR) $(SBIN_DIR) $(LIB_DIR) $(MAN8_DIR) \
	           $(ETC_DIR) $(SYS_DIR) $(UDEV_DIR)
	install -m 755 bin/dw-iface                  $(BIN_DIR)/dw-iface
	install -m 755 lib/dw-up.sh                  $(LIB_DIR)/dw-up.sh
	install -m 755 lib/dw-down.sh                $(LIB_DIR)/dw-down.sh
	install -m 755 lib/dw-status.sh              $(LIB_DIR)/dw-status.sh
	install -m 755 lib/dw-doctor.sh              $(LIB_DIR)/dw-doctor.sh
	install -m 644 config/dw-iface.conf.example  $(ETC_DIR)/dw-iface.conf.example
	install -m 644 systemd/dw-iface.service      $(SYS_DIR)/dw-iface.service
	install -m 644 udev/99-dw-iface.rules        $(UDEV_DIR)/99-dw-iface.rules
	install -m 755 vendor/tncattach/tncattach    $(SBIN_DIR)/tncattach
	gzip -9 -c vendor/tncattach/tncattach.8    > $(MAN8_DIR)/tncattach.8.gz

uninstall:
	systemctl stop dw-iface.service 2>/dev/null || true
	systemctl disable dw-iface.service 2>/dev/null || true
	rm -f  $(BIN_DIR)/dw-iface
	rm -rf $(LIB_DIR)
	rm -f  $(SYS_DIR)/dw-iface.service
	rm -f  $(UDEV_DIR)/99-dw-iface.rules
	rm -f  $(SBIN_DIR)/tncattach
	rm -f  $(MAN8_DIR)/tncattach.8.gz
	@echo "Uninstalled. Config preserved at $(ETC_DIR)/"
