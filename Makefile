.POSIX:

# Binary name and source file
TARGET  := mac-screen-search
SRC     := mac-screen-search.swift

# Compiler and flags
SWIFTC  := swiftc
CFLAGS  := -O -whole-module-optimization
LDFLAGS := -Xlinker -dead_strip

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(SWIFTC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	strip -rSTx $@

clean:
	rm -f $(TARGET)
