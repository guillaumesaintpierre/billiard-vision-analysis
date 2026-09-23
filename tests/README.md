# Automated Tests

This directory contains automated validation tests for the C ball-detection program `Pix2Pos`.

The tests use synthetic binary pixmaps generated at runtime, so no external image dataset is required.

## Test Coverage

The current suite validates:

1. Correct detection of red, yellow and white balls at known positions.
2. Rejection of truncated pixmap files with missing pixels.
3. Warning behavior when extra pixels are present.
4. Rejection of image dimensions outside the allowed range.
5. Rejection of invalid ball sizes.
6. Graceful handling of a missing ball using `-1, -1, 0`.

## Running the Tests

From the repository root:

```bash
make test

**Important :** la dernière ligne doit être uniquement :

```text
