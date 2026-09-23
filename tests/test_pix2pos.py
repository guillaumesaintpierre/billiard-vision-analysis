import re
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = ROOT / "Pix2Pos"

WIDTH = 100
HEIGHT = 100
BALL_SIZE = 11

# Command-line interface:
# 4 billiard bounds
# + 6 Red
# + 6 Yellow
# + 6 White
# + 6 Blue background
# + BallSize
BASE_ARGS = [
    "0", "99", "0", "99",

    # Red
    "200", "255", "0", "50", "0", "50",

    # Yellow
    "200", "255", "200", "255", "0", "50",

    # White
    "200", "255", "200", "255", "200", "255",

    # Blue background
    "0", "80", "80", "150", "150", "255",

    str(BALL_SIZE),
]


RED = 0x00FF0000
YELLOW = 0x00FFFF00
WHITE = 0x00FFFFFF
BACKGROUND = 0x002864C8


def write_pixmap(path, width, height, pixels):
    """Write Pixmap.bin using the format expected by Pix2Pos."""
    with open(path, "wb") as f:
        f.write(struct.pack("<I", width))
        f.write(struct.pack("<I", height))

        for pixel in pixels:
            f.write(struct.pack("<I", pixel))


def make_test_image(include_red=True,
                    include_yellow=True,
                    include_white=True):
    """Generate a deterministic synthetic billiard image."""
    pixels = [BACKGROUND] * (WIDTH * HEIGHT)

    balls = []

    if include_red:
        balls.append((20, 20, RED))

    if include_yellow:
        balls.append((50, 40, YELLOW))

    if include_white:
        balls.append((70, 70, WHITE))

    for x0, y0, color in balls:
        for y in range(y0, y0 + BALL_SIZE):
            for x in range(x0, x0 + BALL_SIZE):
                pixels[y * WIDTH + x] = color

    return pixels


def run_pix2pos(directory, args=None):
    """Execute Pix2Pos inside a temporary working directory."""
    if args is None:
        args = BASE_ARGS

    return subprocess.run(
        [str(EXECUTABLE), *args],
        cwd=directory,
        text=True,
        capture_output=True,
    )


def read_positions(path):
    """Parse the generated pos.txt file."""
    pattern = re.compile(
        r"^(Red|Yellow|White):\s*(-?\d+),\s*(-?\d+),\s*(\d+)$"
    )

    positions = {}

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            match = pattern.match(line.strip())

            if match:
                color = match.group(1)
                positions[color] = tuple(
                    map(int, match.groups()[1:])
                )

    return positions


class TestPix2Pos(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not EXECUTABLE.exists():
            raise RuntimeError(
                "Pix2Pos executable not found. Run 'make' first."
            )

    def test_valid_detection(self):
        """All three balls should be detected at known positions."""

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)

            pixels = make_test_image()
            write_pixmap(
                tmp / "pixmap.bin",
                WIDTH,
                HEIGHT,
                pixels,
            )

            result = run_pix2pos(tmp)

            self.assertEqual(result.returncode, 0)

            positions = read_positions(tmp / "pos.txt")

            self.assertEqual(
                positions["Red"],
                (20, 20, BALL_SIZE * BALL_SIZE),
            )

            self.assertEqual(
                positions["Yellow"],
                (50, 40, BALL_SIZE * BALL_SIZE),
            )

            self.assertEqual(
                positions["White"],
                (70, 70, BALL_SIZE * BALL_SIZE),
            )

    def test_missing_pixels_is_error(self):
        """A truncated pixmap must produce an error."""

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)

            pixels = make_test_image()

            # Remove one required pixel.
            pixels = pixels[:-1]

            write_pixmap(
                tmp / "pixmap.bin",
                WIDTH,
                HEIGHT,
                pixels,
            )

            result = run_pix2pos(tmp)

            self.assertNotEqual(result.returncode, 0)

            self.assertIn(
                "Pas assez de pixels",
                result.stderr,
            )

    def test_extra_pixels_produce_warning(self):
        """Extra pixels should be ignored with a warning."""

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)

            pixels = make_test_image()

            # Add one unnecessary pixel.
            pixels.append(BACKGROUND)

            write_pixmap(
                tmp / "pixmap.bin",
                WIDTH,
                HEIGHT,
                pixels,
            )

            result = run_pix2pos(tmp)

            self.assertEqual(result.returncode, 0)

            self.assertIn(
                "Trop de pixels",
                result.stderr,
            )

    def test_invalid_dimensions_is_error(self):
        """Width outside [100,1000] must be rejected."""

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)

            with open(tmp / "pixmap.bin", "wb") as f:
                f.write(struct.pack("<I", 99))
                f.write(struct.pack("<I", 100))

            result = run_pix2pos(tmp)

            self.assertNotEqual(result.returncode, 0)

            self.assertIn(
                "Largeur/hauteur hors bornes",
                result.stderr,
            )

    def test_invalid_ball_size_is_error(self):
        """BallSize below the allowed range must be rejected."""

        with tempfile.TemporaryDirectory() as tmp:
            args = BASE_ARGS.copy()
            args[-1] = "9"

            result = run_pix2pos(tmp, args)

            self.assertNotEqual(result.returncode, 0)

            self.assertIn(
                "BallSize",
                result.stderr,
            )

    def test_missing_ball_returns_default_values(self):
        """A missing ball should return -1,-1,0 without aborting."""

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)

            pixels = make_test_image(include_white=False)

            write_pixmap(
                tmp / "pixmap.bin",
                WIDTH,
                HEIGHT,
                pixels,
            )

            result = run_pix2pos(tmp)

            self.assertEqual(result.returncode, 0)

            positions = read_positions(tmp / "pos.txt")

            self.assertEqual(
                positions["White"],
                (-1, -1, 0),
            )

            self.assertIn(
                "Moins que 3 boules",
                result.stderr,
            )


if __name__ == "__main__":
    unittest.main()
