DMD    ?= dmd
LDC    ?= ldc2
TARGET := petitbootusb
SRCS   := source/app.d source/iso.d source/config.d source/distro.d source/usb.d source/editor.d \
          source/tui/term.d source/tui/input.d source/tui/draw.d source/tui/ui.d

all: $(TARGET)

$(TARGET): $(SRCS)
	$(DMD) -of=$(TARGET) $(SRCS)

debug: $(SRCS)
	$(DMD) -g -of=$(TARGET) $(SRCS)

# Cross-compile to ppc64le using LDC
cross: $(SRCS)
	$(LDC) --mtriple=powerpc64le-linux-gnu -static -of=$(TARGET)-ppc64le $(SRCS)

install: $(TARGET)
	install -Dm755 $(TARGET) $(DESTDIR)/usr/local/bin/$(TARGET)
	install -Dm644 $(TARGET).1 $(DESTDIR)/usr/local/share/man/man1/$(TARGET).1

clean:
	rm -f $(TARGET) $(TARGET)-ppc64le $(TARGET).o

.PHONY: all debug cross install clean
