#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys
import tempfile

errors = []

def is_safety_comment(text):
    stripped = text.strip()
    if stripped.startswith("///"):
        body = stripped[3:].strip()
    elif stripped.startswith("//"):
        body = stripped[2:].strip()
    elif stripped.startswith("/*"):
        body = stripped[2:]
        if body.endswith("*/"):
            body = body[:-2]
        body = body.strip()
    elif stripped.startswith("<!--"):
        body = stripped[4:]
        if body.endswith("-->"):
            body = body[:-3]
        body = body.strip()
    elif stripped.startswith("#"):
        body = stripped[1:].strip()
    else:
        body = stripped
    return body.startswith("SAFETY:")

def scan_swift(path, src):
    i, n = 0, len(src)
    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "#" or c == '"':
            j = i
            hashes = 0
            while j < n and src[j] == "#":
                hashes += 1
                j += 1
            if j < n and src[j] == '"':
                if src[j:j + 3] == '"""':
                    i = j + 3
                    close = '"""' + "#" * hashes
                    esc = "\\" + "#" * hashes
                    while i < n:
                        if src.startswith(esc, i) and i + len(esc) < n and src[i + len(esc)] == "(":
                            i += len(esc) + 1
                            depth = 1
                            while i < n and depth > 0:
                                if src[i] == "\n":
                                    line += 1
                                elif src[i] == "(":
                                    depth += 1
                                elif src[i] == ")":
                                    depth -= 1
                                elif src[i] == '"':
                                    i += 1
                                    while i < n and src[i] != '"':
                                        if src[i] == "\\":
                                            i += 2
                                            continue
                                        if src[i] == "\n":
                                            line += 1
                                        i += 1
                                i += 1
                            continue
                        if src.startswith(close, i):
                            i += len(close)
                            break
                        if src[i] == "\n":
                            line += 1
                        i += 1
                    continue
                else:
                    i = j + 1
                    close = '"' + "#" * hashes
                    esc = "\\" + "#" * hashes
                    while i < n:
                        if src.startswith(esc, i):
                            if i + len(esc) < n and src[i + len(esc)] == "(":
                                i += len(esc) + 1
                                depth = 1
                                while i < n and depth > 0:
                                    if src[i] == "\n":
                                        line += 1
                                    elif src[i] == "(":
                                        depth += 1
                                    elif src[i] == ")":
                                        depth -= 1
                                    elif src[i] == '"':
                                        i += 1
                                        while i < n and src[i] != '"':
                                            if src[i] == "\\":
                                                i += 2
                                                continue
                                            i += 1
                                    i += 1
                                continue
                            i += len(esc) + 1
                            continue
                        if src.startswith(close, i):
                            i += len(close)
                            break
                        if src[i] == "\n":
                            line += 1
                            break
                        i += 1
                    continue
            if c == "#":
                i += 1
                continue
        if src[i:i + 2] == "//":
            end = src.find("\n", i)
            if end == -1:
                end = n
            comment = src[i:end]
            if not (line == 1 and comment.startswith("// swift-tools-version:")) and not is_safety_comment(comment):
                errors.append(f"{path}:{line}: non-safety comment: {comment[:80]}")
            i = end
            continue
        if src[i:i + 2] == "/*":
            start = i
            start_line = line
            depth = 1
            i += 2
            while i < n and depth > 0:
                if src[i:i + 2] == "/*":
                    depth += 1
                    i += 2
                elif src[i:i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    if src[i] == "\n":
                        line += 1
                    i += 1
            comment = src[start:i]
            if not is_safety_comment(comment):
                errors.append(f"{path}:{start_line}: non-safety block comment")
            continue
        i += 1

def scan_c(path, src):
    i, n = 0, len(src)
    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in ('"', "'"):
            q = c
            i += 1
            while i < n:
                if src[i] == "\\":
                    if i + 1 < n and src[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                if src[i] == "\n":
                    line += 1
                i += 1
            continue
        if src[i:i + 2] == "//":
            end = src.find("\n", i)
            if end == -1:
                end = n
            comment = src[i:end]
            if not is_safety_comment(comment):
                errors.append(f"{path}:{line}: non-safety comment: {comment[:80]}")
            i = end
            continue
        if src[i:i + 2] == "/*":
            start = i
            start_line = line
            end = src.find("*/", i + 2)
            if end == -1:
                end = n
            else:
                end += 2
            comment = src[start:end]
            if not is_safety_comment(comment):
                errors.append(f"{path}:{start_line}: non-safety block comment")
            line += comment.count("\n")
            i = end
            continue
        i += 1

def scan_shell(path, src):
    lines = src.splitlines()
    heredoc = None
    in_single = False
    in_double = False
    for idx, text in enumerate(lines, 1):
        if heredoc is not None:
            delim, strip_tabs, is_py = heredoc
            check = text.lstrip("\t") if strip_tabs else text
            if check == delim:
                heredoc = None
                continue
            if is_py:
                s = text.lstrip()
                if s.startswith("#") and not is_safety_comment(s):
                    errors.append(f"{path}:{idx}: non-safety comment: {s[:80]}")
            continue
        if idx == 1 and text.startswith("#!"):
            continue
        i, n = 0, len(text)
        pending_hd = None
        while i < n:
            c = text[i]
            if in_single:
                if c == "'":
                    in_single = False
                i += 1
                continue
            if in_double:
                if c == "\\":
                    i += 2
                    continue
                if c == '"':
                    in_double = False
                i += 1
                continue
            if c == "\\":
                i += 2
                continue
            if c == "'":
                in_single = True
                i += 1
                continue
            if c == '"':
                in_double = True
                i += 1
                continue
            if c == "<" and i + 1 < n and text[i + 1] == "<" and (i + 2 >= n or text[i + 2] != "<"):
                m = re.match(r"<<(-)?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", text[i:])
                if m:
                    is_py = m.group(3) in ("PY", "PYTHON")
                    pending_hd = (m.group(3), bool(m.group(1)), is_py)
                    i += m.end()
                    continue
            if c == "#" and (i == 0 or text[i - 1] in " \t;&|()"):
                comment = text[i:]
                if not is_safety_comment(comment):
                    errors.append(f"{path}:{idx}: non-safety comment: {comment[:80]}")
                break
            i += 1
        if pending_hd is not None:
            heredoc = pending_hd

def scan_yaml(path, src):
    for idx, text in enumerate(src.splitlines(), 1):
        s = text.lstrip()
        if s.startswith("#") and not is_safety_comment(s):
            errors.append(f"{path}:{idx}: non-safety comment: {s[:80]}")

def scan_html(path, src):
    for m in re.finditer(r"<!--[\s\S]*?-->", src):
        if not is_safety_comment(m.group(0)):
            line = src.count("\n", 0, m.start()) + 1
            errors.append(f"{path}:{line}: non-safety HTML comment")
    for m in re.finditer(r"<style\b[^>]*>([\s\S]*?)</style>", src, re.I):
        base = src.count("\n", 0, m.start(1)) + 1
        css = m.group(1)
        for cm in re.finditer(r"/\*[\s\S]*?\*/", css):
            if not is_safety_comment(cm.group(0)):
                line = base + css.count("\n", 0, cm.start())
                errors.append(f"{path}:{line}: non-safety CSS comment")
    for m in re.finditer(r"<script(?![^>]*application/ld\+json)[^>]*>([\s\S]*?)</script>", src, re.I):
        base = src.count("\n", 0, m.start(1)) + 1
        js = m.group(1)
        i, n = 0, len(js)
        line = base
        prev_sig = ""
        while i < n:
            c = js[i]
            if c == "\n":
                line += 1
                i += 1
                continue
            if c in ('"', "'", "`"):
                q = c
                i += 1
                while i < n:
                    if js[i] == "\\":
                        if i + 1 < n and js[i + 1] == "\n":
                            line += 1
                        i += 2
                        continue
                    if js[i] == q:
                        i += 1
                        break
                    if js[i] == "\n":
                        line += 1
                    i += 1
                prev_sig = q
                continue
            if js[i:i + 2] == "//":
                end = js.find("\n", i)
                if end == -1:
                    end = n
                comment = js[i:end]
                if not is_safety_comment(comment):
                    errors.append(f"{path}:{line}: non-safety JS comment: {comment[:80]}")
                i = end
                continue
            if js[i:i + 2] == "/*":
                start = i
                start_line = line
                end = js.find("*/", i + 2)
                if end == -1:
                    end = n
                else:
                    end += 2
                comment = js[start:end]
                if not is_safety_comment(comment):
                    errors.append(f"{path}:{start_line}: non-safety JS block comment")
                line += comment.count("\n")
                i = end
                continue
            if c == "/" and prev_sig in ("", "(", ",", "=", ":", "[", "!", "&", "|", "?", "{", "}", ";", "\n"):
                i += 1
                in_class = False
                while i < n and js[i] != "\n":
                    if js[i] == "\\":
                        i += 2
                        continue
                    if js[i] == "[":
                        in_class = True
                    elif js[i] == "]":
                        in_class = False
                    elif js[i] == "/" and not in_class:
                        i += 1
                        break
                    i += 1
                prev_sig = "/"
                continue
            if not c.isspace():
                prev_sig = c
            i += 1
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as tf:
            tf.write(js)
            tmp_js = tf.name
        try:
            proc = subprocess.run(["node", "--check", tmp_js], capture_output=True, text=True)
            if proc.returncode != 0:
                errors.append(f"{path}: JS syntax error: {proc.stderr.strip()}")
        finally:
            os.unlink(tmp_js)

    html_no_script = re.sub(r"<script\b[^>]*>[\s\S]*?</script>", "", src, flags=re.I)
    for attr in re.findall(r'(?:src|href)="([^"]+)"', html_no_script):
        if attr.startswith(("http://", "https://", "#", "data:", "mailto:")):
            continue
        asset = os.path.join("site", attr)
        if not os.path.exists(asset):
            errors.append(f"{path}: missing local asset {asset}")
    for srcset in re.findall(r'srcset="([^"]+)"', html_no_script):
        for entry in srcset.split(","):
            ref = entry.strip().split()[0]
            asset = os.path.join("site", ref)
            if not os.path.exists(asset):
                errors.append(f"{path}: missing srcset asset {asset}")

for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in (".git", ".build", "build", "node_modules")]
    for name in sorted(files):
        path = os.path.join(root, name)
        rel = os.path.relpath(path, ".")
        if rel == "scripts/lint.sh":
            continue
        if name.endswith(".swift"):
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            scan_swift(rel, src)
        elif name.endswith((".c", ".h")):
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            scan_c(rel, src)
        elif name.endswith(".sh"):
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            scan_shell(rel, src)
        elif rel.startswith(".github/workflows/") and name.endswith((".yml", ".yaml")):
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            scan_yaml(rel, src)
        elif rel == "site/index.html":
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            scan_html(rel, src)

        if rel.startswith(("Sources/", "Tests/", "Tools/", "scripts/")) and not rel == "scripts/lint.sh":
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            if "System Events" in text:
                errors.append(f"{rel}: forbidden AppleScript System Events; use build/input")

interactive_tools = ("Fixture.app", "build/input", "build/ticker", "build/flicker", "build/bench")
for name in sorted(os.listdir("scripts")):
    if not name.endswith(".sh") or name in ("build-fixture.sh", "guard-host.sh", "lint.sh", "vm.sh"):
        continue
    rel = os.path.join("scripts", name)
    with open(rel, encoding="utf-8") as fh:
        text = fh.read()
    if any(tok in text for tok in interactive_tools) and "guard-host.sh" not in text:
        errors.append(f"{rel}: interactive script must source scripts/guard-host.sh")

pin = open("scripts/release-certificate.sha1", encoding="utf-8").read().strip()
if not re.fullmatch(r"[0-9A-F]{40}", pin):
    errors.append("scripts/release-certificate.sha1: expected 40 uppercase hex chars")

if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)
PY

for script in scripts/*.sh; do
  zsh -n "$script"
done
sh -n install.sh
plutil -lint -s Support/Info.plist
print -- "lint: ok"
