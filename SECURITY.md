# Security Policy

## Administrator privileges

TNT uses administrator privileges only when an operation must change macOS
network configuration.

The password prompt is provided by macOS through `sudo`. TNT does not capture,
store, log or transmit the administrator password.

## Auditing privileged commands

```bash
grep -Rni "sudo" src/
```

Users are encouraged to inspect `src/main.sh` before running the application.

## Reporting a vulnerability

Please report security issues privately through:

https://marko.racic.rs

Include the affected TNT version, steps to reproduce, relevant output, and any
suggested fix. Please do not publish exploitable details before review.
