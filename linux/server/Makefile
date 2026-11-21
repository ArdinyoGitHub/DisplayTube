PKGS = libavcodec libavfilter libavutil libswscale libpulse libpulse-simple wayland-client
APK_PATH ?= /usr/local/share/displaytube/DisplayTube.apk
CFLAGS ?= -O2 -Wall -Wextra
CFLAGS += $(shell pkg-config --cflags $(PKGS))
CPPFLAGS += -DDEFAULT_APK='"$(APK_PATH)"' -I.
LDLIBS = $(shell pkg-config --libs $(PKGS)) -levdi -lpthread
XDG_OUTPUT_XML = $(shell pkg-config --variable=pkgdatadir wayland-protocols)/unstable/xdg-output/xdg-output-unstable-v1.xml
OBJS = displaytube.o touch.o mouse.o layout.o audio.o xdg-output-protocol.o

displaytube: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

# Wayland xdg-output istemci kodu, sistemdeki wayland-protocols'ten uretilir
xdg-output-protocol.h:
	wayland-scanner client-header $(XDG_OUTPUT_XML) $@
xdg-output-protocol.c:
	wayland-scanner private-code $(XDG_OUTPUT_XML) $@

layout.o: xdg-output-protocol.h
$(OBJS): dt.h

clean:
	rm -f displaytube *.o xdg-output-protocol.h xdg-output-protocol.c
.PHONY: clean
