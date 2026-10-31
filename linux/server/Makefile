PKGS = libavcodec libavfilter libavutil libswscale
APK_PATH ?= /usr/local/share/displaytube/DisplayTube.apk
CFLAGS ?= -O2 -Wall -Wextra
CFLAGS += $(shell pkg-config --cflags $(PKGS))
CPPFLAGS += -DDEFAULT_APK='"$(APK_PATH)"'
LDLIBS = $(shell pkg-config --libs $(PKGS)) -levdi -lpthread

displaytube: displaytube.c

clean:
	rm -f displaytube
.PHONY: clean
