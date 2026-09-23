CC = cc
CFLAGS = -std=c11 -Wall -Wextra -Wpedantic -O2

PYTHON = python3

TARGET = Pix2Pos
SOURCE = src/c/Pix2Pos.c

.PHONY: all test clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) $(SOURCE) -o $(TARGET)

test: $(TARGET)
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

clean:
	rm -f $(TARGET)
