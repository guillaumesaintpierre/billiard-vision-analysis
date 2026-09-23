# Tests

Planned automated tests for the C component:

- valid image and valid arguments -> exit code 0;
- invalid width/height -> error;
- insufficient pixel data -> error;
- extra pixel data -> warning, continue;
- invalid BallSize -> error;
- missing ball -> `-1, -1, 0` for that ball.

The test suite will use generated synthetic pixmaps so no course-provided image data needs to be committed.
