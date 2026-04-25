PREFIX   ?= /usr
LIB_DIR   = $(DESTDIR)$(PREFIX)/lib/dw-iface
BIN_DIR   = $(DESTDIR)$(PREFIX)/bin
ETC_DIR   = $(DESTDIR)/etc/dw-iface
SYS_DIR   = $(DESTDIR)/lib/systemd/system
UDEV_DIR  = $(DESTDIR)/lib/udev/rules.d

.PHONY: all install uninstall

all:
	@echo "Run 'sudo make install' to install dw-iface."
	@echo "Run 'sudo make uninstall' to remove it."
	@echo "Run 'dpkg-buildpackage -b -us -uc' to build a .deb package."

install:
	install -d $(BIN_DIR) $(LIB_DIR) $(ETC_DIR) $(SYS_DIR) $(UDEV_DIR)
	install -m 755 bin/dw-iface             $(BIN_DIR)/dw-iface
	install -m 755 lib/dw-up.sh             $(LIB_DIR)/dw-up.sh
	install -m 755 lib/dw-down.sh           $(LIB_DIR)/dw-down.sh
	install -m 755 lib/dw-status.sh         $(LIB_DIR)/dw-status.sh
	install -m 755 lib/dw-doctor.sh         $(LIB_DIR)/dw-doctor.sh
	install -m 644 config/dw-iface.conf.example  $(ETC_DIR)/dw-iface.conf.example
	install -m 644 systemd/dw-iface.service $(SYS_DIR)/dw-iface.service
	install -m 644 udev/99-dw-iface.rules   $(UDEV_DIR)/99-dw-iface.rules
	@if [ ! -f $(ETC_DIR)/dw-iface.conf ]; then \
	    cp $(ETC_DIR)/dw-iface.conf.example $(ETC_DIR)/dw-iface.conf; \
	    echo "Created $(ETC_DIR)/dw-iface.conf — edit before running 'dw-iface up'"; \
	fi
	udevadm control --reload-rules 2>/dev/null || true
	systemctl daemon-reload 2>/dev/null || true
	@echo "Installed. Next steps:"
	@echo "  1. Edit /etc/dw-iface/dw-iface.conf"
	@echo "  2. sudo dw-iface doctor"
	@echo "  3. sudo dw-iface up"

uninstall:
	systemctl stop dw-iface.service 2>/dev/null || true
	systemctl disable dw-iface.service 2>/dev/null || true
	rm -f $(BIN_DIR)/dw-iface
	rm -rf $(LIB_DIR)
	rm -f $(SYS_DIR)/dw-iface.service
	rm -f $(UDEV_DIR)/99-dw-iface.rules
	@echo "Uninstalled. Config preserved at $(ETC_DIR)/dw-iface.conf"
