"""Parses units out of docs/roadmap.md.

A unit is a level-3 heading whose first word is the unit ID, followed by bullet fields:

  ### L1.calls — Calls and the SysV calling convention
  - deps: L1.basic
  - exit: tests/e2e/O0/calls/*::run, tests/function/O0/abi/*::run
  - exit-file: DESIGN.md          (optional; file that must exist in impl/<lang>/)
"""

import re
from dataclasses import dataclass, field

from . import config

HEAD = re.compile(r"^###\s+(L\d+\.[\w.-]+)\s*(?:[—-]+\s*(.*))?$")
FIELD = re.compile(r"^-\s*(deps|exit|exit-file):\s*(.*)$")


@dataclass
class Unit:
    id: str
    title: str
    deps: list[str] = field(default_factory=list)
    exit: list[str] = field(default_factory=list)
    exit_files: list[str] = field(default_factory=list)


def units() -> list[Unit]:
    out: list[Unit] = []
    for line in config.ROADMAP.read_text().splitlines():
        m = HEAD.match(line.strip())
        if m:
            out.append(Unit(m.group(1), m.group(2) or ""))
            continue
        m = FIELD.match(line.strip())
        if m and out:
            vals = [v.strip().strip("`") for v in m.group(2).split(",") if v.strip() and v.strip() != "none"]
            if m.group(1) == "deps":
                out[-1].deps += vals
            elif m.group(1) == "exit":
                out[-1].exit += vals
            else:
                out[-1].exit_files += vals
    return out


def get(unit_id: str) -> Unit:
    for u in units():
        if u.id == unit_id:
            return u
    raise SystemExit(f"unknown unit {unit_id!r}; see docs/roadmap.md")
