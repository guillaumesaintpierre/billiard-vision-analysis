CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Wpedantic -O2
TARGET := Pix2Pos
SOURCE := src/c/Pix2Pos.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) $(SOURCE) -o $(TARGET)

clean:
	rm -f $(TARGET)
