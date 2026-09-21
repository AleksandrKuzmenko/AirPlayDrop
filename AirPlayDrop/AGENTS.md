# Development rules

Use the README build and test commands. Preserve unrelated user changes.
Tests must use generated tiny fixtures or mocks and must never read or write a
user's Movies folder. Keep FFmpeg arguments structured; do not invoke a shell.
Validate generated media before publishing it or marking it ready. Do not add
signing credentials, bundled FFmpeg binaries, or private Apple APIs.
