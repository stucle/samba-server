#!/usr/bin/env python3
"""Validate to-copy/manifest.json and flatten it to TSV for install.sh / uninstall.sh.

Usage (from the kit root):  python3 -I manifest.py to-copy/manifest.json
Prints one tab-separated line per entry, fixed column order, defaults filled in, "-" for "not set".
Prints nothing and exits 1 (message on stderr) if anything is invalid, so the caller has changed nothing yet.
This script only reads; it copies nothing. The manifest is data: no value is ever executed - guard/verify are names looked up in a whitelist.
"""
import json
import os
import re
import sys

REQUIRED = ("fileName", "sourcePath", "destination")
DEFAULTS = {
    "mode": "0644",
    "owner": "root:root",
    "dirMode": "0755",
    "overwrite": "ifChanged",
    "backup": True,
    "guard": None,
    "verify": None,
    "group": None,
    "uninstall": "remove",
}
COLUMNS = REQUIRED + tuple(DEFAULTS)
GUARDS = {"samba-passdb-no-users"}
VERIFIES = {"samba-passdb-readable"}
OVERWRITE = {"ifChanged", "always", "ifAbsent"}
UNINSTALL = {"remove", "keep", "purge"}

NAME = re.compile(r"^[A-Za-z0-9._+-]+$")
MODE = re.compile(r"^[0-7]{3,4}$")
OWNER = re.compile(r"^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$")
GROUP = re.compile(r"^[a-z0-9-]+$")


def fail(msg):
    print("manifest: " + msg, file=sys.stderr)
    sys.exit(1)


def main(path):
    kit = os.path.realpath(os.getcwd())
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("cannot read %s: %s" % (path, exc))
    if not isinstance(data, list) or not data:
        fail("top level must be a non-empty array")

    rows, seen, by_group = [], set(), {}
    for i, e in enumerate(data):
        where = "entry %d" % i
        if not isinstance(e, dict):
            fail("%s: must be an object" % where)
        unknown = set(e) - set(COLUMNS)
        if unknown:
            fail("%s: unknown key(s): %s" % (where, ", ".join(sorted(unknown))))
        for k in REQUIRED:
            if not isinstance(e.get(k), str) or not e[k]:
                fail("%s: %s must be a non-empty string" % (where, k))
        v = {k: e.get(k, d) for k, d in DEFAULTS.items()}
        v.update({k: e[k] for k in REQUIRED})
        where = "entry %d (%s)" % (i, v["fileName"])

        if not NAME.match(v["fileName"]) or v["fileName"] in (".", ".."):
            fail("%s: fileName must match [A-Za-z0-9._+-]+ and not be . or .." % where)
        parts = v["destination"].split("/")
        if (v["destination"] == "/" or not v["destination"].startswith("/")
                or v["destination"].endswith("/") or "" in parts[1:] or ".." in parts
                or not all(NAME.match(p) for p in parts[1:])):
            fail("%s: destination must be an absolute directory path, no '..', no '//', "
                 "no trailing '/', chars [A-Za-z0-9._+-]" % where)
        sp = v["sourcePath"]
        if sp.startswith("/") or ".." in sp.split("/") or not all(NAME.match(p) for p in sp.split("/")):
            fail("%s: sourcePath must be relative to the kit, no '..', chars [A-Za-z0-9._+-/]" % where)
        if os.path.islink(sp) or not os.path.isfile(sp):
            fail("%s: sourcePath %s is not a regular file" % (where, sp))
        if not os.path.realpath(sp).startswith(kit + os.sep):
            fail("%s: sourcePath resolves outside the kit" % where)

        for k in ("mode", "dirMode"):
            if not isinstance(v[k], str) or not MODE.match(v[k]):
                fail("%s: %s must be an octal string like \"0644\"" % (where, k))
        if not isinstance(v["owner"], str) or not OWNER.match(v["owner"]):
            fail("%s: owner must be user:group" % where)
        if v["overwrite"] not in OVERWRITE:
            fail("%s: overwrite must be one of %s" % (where, "/".join(sorted(OVERWRITE))))
        if not isinstance(v["backup"], bool):
            fail("%s: backup must be true or false" % where)
        if v["uninstall"] not in UNINSTALL:
            fail("%s: uninstall must be one of %s" % (where, "/".join(sorted(UNINSTALL))))
        if v["guard"] is not None and v["guard"] not in GUARDS:
            fail("%s: unknown guard %r (allowed: %s)" % (where, v["guard"], ", ".join(sorted(GUARDS))))
        if v["verify"] is not None and v["verify"] not in VERIFIES:
            fail("%s: unknown verify %r (allowed: %s)" % (where, v["verify"], ", ".join(sorted(VERIFIES))))
        if v["group"] is not None and (not isinstance(v["group"], str) or not GROUP.match(v["group"])):
            fail("%s: group must match [a-z0-9-]+" % where)

        target = v["destination"] + "/" + v["fileName"]
        if target in seen:
            fail("%s: duplicate target %s" % (where, target))
        seen.add(target)
        if v["group"] is not None:
            by_group.setdefault(v["group"], []).append(v)
        rows.append(v)

    for g, members in by_group.items():
        if len({(m["guard"], m["verify"]) for m in members}) != 1:
            fail("group %s: entries must agree on guard and verify" % g)

    for v in rows:
        out = []
        for c in COLUMNS:
            x = v[c]
            out.append("-" if x is None else ("1" if x is True else "0" if x is False else x))
        print("\t".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: manifest.py <manifest.json>")
    main(sys.argv[1])
