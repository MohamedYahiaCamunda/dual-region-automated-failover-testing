#!/usr/bin/env python3
"""Renders TSV (or programmatic rows) as a colorized unicode box table.

CLI usage: printf 'Col1\\tCol2\\nval1\\tval2\\n' | python3 table.py
Library usage: from table import render; render([["Col1","Col2"],["v1","v2"]], title="...")
"""
import sys
import re
import os

# Respect the same DR_NO_COLOR / NO_COLOR (see no-color.org) convention as
# lib/common.sh, and deliberately avoid the ANSI "dim" attribute - terminals
# render it inconsistently (often shifting hue toward brown/red instead of
# just darkening), which clashes badly with light-background themes.
if os.environ.get("DR_NO_COLOR") or os.environ.get("NO_COLOR"):
    RESET = BOLD = GREEN = RED = YELLOW = CYAN = ""
else:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    GREEN = "\033[32m"
    RED = "\033[31m"
    YELLOW = "\033[33m"
    CYAN = "\033[36m"

GOOD = {"UP", "ENABLED", "EXPORTING", "LEADER", "OK", "HEALTHY", "SUCCESS",
        "PASS", "COMPLETED", "READY", "TRUE"}
BAD = {"DOWN", "DISABLED", "CLOSED", "MISMATCH", "FAIL", "FAILED", "ERROR", "FALSE"}
NEUTRAL = {"FOLLOWER", "ENABLING", "DISABLING", "IN_PROGRESS"}


def _colorize(cell):
    token = cell.strip().upper()
    if token in GOOD:
        return f"{GREEN}{cell}{RESET}"
    if token in BAD:
        return f"{RED}{cell}{RESET}"
    if token in NEUTRAL:
        return f"{YELLOW}{cell}{RESET}"
    return cell


def _vlen(s):
    return len(re.sub(r'\033\[[0-9;]*m', '', s))


def render(rows, title=None):
    if not rows:
        print("(no data)")
        return
    ncols = max(len(r) for r in rows)
    rows = [list(r) + [''] * (ncols - len(r)) for r in rows]
    widths = [0] * ncols
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(str(c)))

    def hline(l, m, r_, f):
        return l + m.join(f * (w + 2) for w in widths) + r_

    if title:
        print(f"{BOLD}{CYAN}{title}{RESET}")
    print(hline('┌', '┬', '┐', '─'))
    header = rows[0]
    cells = [' ' + BOLD + CYAN + str(c).ljust(widths[i]) + RESET + ' ' for i, c in enumerate(header)]
    print('│' + '│'.join(cells) + '│')
    print(hline('├', '┼', '┤', '─'))
    for r in rows[1:]:
        cells = []
        for i, c in enumerate(r):
            colored = _colorize(str(c))
            pad = widths[i] - _vlen(colored)
            cells.append(' ' + colored + ' ' * pad + ' ')
        print('│' + '│'.join(cells) + '│')
    print(hline('└', '┴', '┘', '─'))


if __name__ == '__main__':
    lines = [l.rstrip('\n') for l in sys.stdin if l.strip() != '']
    rows = [l.split('\t') for l in lines]
    render(rows)
