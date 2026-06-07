#!/usr/bin/env python3
"""Estampa la versión del cache del service worker (sw.js).

Reescribe la línea `const CACHE = '...';` con `<name>-<timestamp UTC>`
para que cada release invalide el cache anterior y los usuarios reciban
la última versión de la PWA. El `<name>` sale de wrangler.jsonc.

Es idempotente salvo por el timestamp: correrlo siempre deja un valor
nuevo. Lo corre solo el workflow .github/workflows/stamp-sw.yml en cada
push a main; también podés correrlo a mano: `python build.py`.
"""
import datetime
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SW = ROOT / "sw.js"
WRANGLER = ROOT / "wrangler.jsonc"


def app_name() -> str:
    m = re.search(r'"name"\s*:\s*"([^"]+)"', WRANGLER.read_text(encoding="utf-8"))
    return m.group(1) if m else "app"


def main() -> int:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
    new_cache = f"{app_name()}-{stamp}"

    text = SW.read_text(encoding="utf-8")
    new_text, n = re.subn(r"(const CACHE = ')[^']*(';)",
                          rf"\g<1>{new_cache}\g<2>", text)
    if n != 1:
        print(f"build.py: esperaba 1 línea `const CACHE = '...';` en sw.js, "
              f"encontré {n}.", file=sys.stderr)
        return 1

    SW.write_text(new_text, encoding="utf-8")
    print(f"sw.js → CACHE = '{new_cache}'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
