"""``python3 -m bfos`` — module entry point for the operator console."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
