#!/usr/bin/env python3
"""Every external command the 99shanios dracut hooks run must be declared in
module-setup.sh's inst_multiple.

WHY THIS EXISTS. A binary missing from inst_multiple is not a build error and not
a boot error. The hook runs, the shell prints nothing useful, and the logic
silently does nothing - from a console that is indistinguishable from a hook that
never ran. That is how `cat`, `cp`, `ls`, `readlink`, `tr`, `head` and `basename`
stayed off the list for the length of a boot-failover investigation, and how
`sync` stayed off it afterwards: the initramfs printed `sync: command not found`
and the flush before the hook gave up simply never happened.

A check that only inspects the source list cannot catch this, because the failure
is a command that is never in the list. So this reads the hooks, and treats the
union of the two as the question.

    tests/dracut-hook-deps.sh      (host-only, no root, no disks)
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent   # the shani-install-media checkout
MOD = HERE / "image_profiles/shared/overlay/rootfs/usr/lib/dracut/modules.d/99shanios"

KEYWORDS = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
            "case", "esac", "in", "function", "return", "break", "continue", "local",
            "exit", "shift", "source", "export", "readonly", "declare", "typeset"}
BUILTINS = {"echo", "printf", "read", "test", "true", "false", ":", "wait", "exec",
            "eval", "set", "unset", "alias", "trap", "getopts", "hash", "umask",
            "command", "type", "pwd", "cd", "let", "times", "ulimit", "readarray",
            "mapfile", "shopt", "jobs", "kill", "disown", "help", "history", "fc"}
# Provided by dracut itself, not by inst_multiple.
DRACUT_HELPERS = {"getarg", "warn", "info", "display-message", "display_message",
                  "emergency", "die", "inst_multiple", "instmods", "inst_dir"}


def strip_comments(text):
    out, quote = [], None
    for line in text.splitlines():
        res, i = [], 0
        while i < len(line):
            c = line[i]
            if quote:
                res.append(c)
                if c == "\\" and i + 1 < len(line):
                    res.append(line[i + 1]); i += 2; continue
                if c == quote:
                    quote = None
            elif c in "'\"":
                quote = c; res.append(c)
            elif c == "#":
                break
            else:
                res.append(c)
            i += 1
        out.append("".join(res))
    return "\n".join(out)


def strip_strings(text):
    out, i, quote = [], 0, None
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and i + 1 < len(text):
                out.append("  "); i += 2; continue
            out.append(c if c == quote else " ")
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c; out.append(" "); i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def strip_for_wordlists(text):
    """Blank the WORD LIST of a `for NAME in a b c; do` header.

    Without this the word list reads as commands. It produced four phantom
    misses the moment the failover hook grew its EFI-variable loop:

        LoaderEntrySysFail  LoaderEntryOneShot  LoaderEntryPreferred
        LoaderEntryDefault  _f  _v

    `_f` and `_v` are the loop VARIABLES and the rest are the four variable
    names being iterated - none of them is executed. Worse than a false
    positive: the check went RED and stayed red, so the next real missing
    binary would have arrived inside an already-failing run where nobody
    distinguishes a new failure from the standing one.

    The variable and the `in` keyword are kept, so a loop over a COMMAND
    (`for c in cat cp`) still reports - which is the case the check exists for.
    """
    out = []
    # The header is matched over the WHOLE remaining text, not line by line: a
    # word list continued with a trailing `\` onto the next line - which is how
    # both loops here are written - never matches a per-line pattern at all.
    # That is why the first version of this function changed nothing.
    for m in re.finditer(r"(^[ \t]*for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+)"
                         r"((?:[^\n\\]|\\\n)*?)(;.*?\bdo\b)", text, re.M):
        head, words, tail = m.group(1), m.group(2), m.group(3)
        # Blank the word list AND the loop variable itself. Both are matched
        # as commands: the variable because COMMAND_POS anchors on `^` with
        # re.M and a header line begins with `for _v in ...` after indentation,
        # and the word list because it is just words on a line. Neither is ever
        # executed, and both are precisely what this loop is iterating over.
        # `for NAME` is kept only so the header still parses as a loop.
        name = re.match(r"[ \t]*for[ \t]+([A-Za-z_][A-Za-z0-9_]*)", head)
        blank = "".join(ch if ch.isspace() else " " for ch in words)
        blank = blank.replace("\\\n", "\n" if "\\\n" in words else "\\\n")
        text = text[:m.start(2)] + blank + text[m.end(2):]
        if name:
            i = m.start(1) + name.group(0).index(name.group(1))
            text = text[:i] + " " * len(name.group(1)) + text[i + len(name.group(1)):]
        del tail
    out.append(text)
    return "".join(out)


def strip_case_labels(text):
    """Blank a `case` label at the start of a line - `passwd|shadow|crypttab)` or
    `""|/*|..)` - which is a list of patterns, not commands. A label has no
    spaces, `(`, `$`, `=` or `;` before its `)`, which no command line starts
    with; anything after the `)` on the same line is still scanned (2026-11-19:
    the protected-name label in shanios-overlay-etc.sh read as ten commands)."""
    return re.sub(r"^([ \t]*)([^\s()$`;&=]+)\)",
                  lambda m: m.group(1) + " " * (len(m.group(2)) + 1), text, flags=re.M)


# re.M matters: `^` must match the start of each LINE, or a command that sits on
# its own indented line - which is how `sync` is written - is invisible to this.
# The trailing (?![a-zA-Z0-9_.-]) forces the WHOLE token to be consumed: without
# it the engine backtracks and reports `subvo` for `subvol=@blue`.
COMMAND_POS = re.compile(
    r"(?:^|[|;&(]|\$\(|`|\bthen\b|\bdo\b|\belse\b|&&|\|\||\{|\s)\s*"
    r"([a-zA-Z_][a-zA-Z0-9_.-]*)(?![a-zA-Z0-9_.-])", re.M)

VARS = {"FALLBACK", "LOADER", "N", "OVERLAY_UPPER", "OVERLAY_WORK", "PRIOR_FAILURE",
        "ROOT_LABEL", "TARGET_ETC", "ESP_MNT", "DATAMNT", "CUR", "KV", "CMD", "UKI"}

hooks = sorted(p for p in MOD.glob("*.sh") if p.name != "module-setup.sh")
if not hooks:
    print(f"FAIL no hook scripts found under {MOD}")
    sys.exit(1)

used = set()
for s in hooks:
    body = strip_case_labels(strip_for_wordlists(strip_strings(strip_comments(s.read_text()))))
    funcs = set(re.findall(r"^\s*([a-zA-Z_][a-zA-Z0-9_.-]*)\s*\(\)\s*\{", body, re.M))
    for m in COMMAND_POS.finditer(body):
        tok = m.group(1)
        # `tries_left=3` is an assignment, not a command. Checked here rather
        # than in the pattern: a negative lookahead for '=' makes the engine
        # backtrack into a shorter, meaningless token.
        if body[m.end():].lstrip()[:1] == "=":
            continue
        if tok in KEYWORDS or tok in BUILTINS or tok in funcs or tok in DRACUT_HELPERS:
            continue
        if tok in VARS or tok.isupper():
            continue
        used.add(tok)

ms = strip_comments((MOD / "module-setup.sh").read_text())
dm = re.search(r"inst_multiple\s+((?:[^\n]*\\\n)*[^\n]*)", ms)
declared = set((dm.group(1) if dm else "").replace("\\", " ").split())

# Values that appear only as arguments to another command, never executed. Kept
# as an explicit list so a new one has to be classified deliberately rather than
# disappearing into a heuristic.
ARGUMENTS = {"blue", "green", "btrfs", "overlay", "vfat", "plymouth", "rw", "ro",
             "subvol", "rootflags", "shani_boot", "sleep", "mktemp", "killall",
             # `systemctl enable <unit>` inside $(...), `mv -f`, and words of an
             # error message the hooks print
             "enable", "shanios-recover-default.service", "f", "or", "unknown"}

missing = sorted(t for t in used if t not in declared and t not in ARGUMENTS)

print(f"hooks: {', '.join(p.name for p in hooks)}")
print(f"declared in inst_multiple: {' '.join(sorted(declared))}")
print()
if missing:
    print("FAIL referenced in command position but NOT in inst_multiple:")
    for t in missing:
        print(f"    {t}")
    print()
    print("  A missing binary is not a build error and not a boot error: the hook")
    print("  runs, the shell says 'command not found' at most, and the logic silently")
    print("  does nothing. From a console that reads as a hook that never ran.")
    sys.exit(1)

print("PASS every external command the hooks run is declared in inst_multiple")
sys.exit(0)