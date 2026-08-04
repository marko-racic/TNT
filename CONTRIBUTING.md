# Contributing to TNT

Bug reports, fixes and focused improvements are welcome.

## Before opening an issue

Include the macOS version, TNT version, adapter type, steps to reproduce, and
relevant Terminal output or screenshots.

## Development workflow

```bash
git checkout -b fix/short-description
bash -n src/main.sh
bash -n src/launcher.sh
bash -n src/launch-command.sh
```

Test changes in Terminal.app before opening a pull request.

TNT Console Edition is intentionally compact. Contributions should prioritize
reliability, macOS compatibility, minimal dependencies and clear privilege
boundaries.
