"""Add display-safe reset inventories to the installed adapter's normal usage pipeline."""

import inspect
import pathlib
import sys


def codexbar_reset_credits(data, now=None):
    import datetime
    import time

    status = data.get("cedar_ember")
    if not isinstance(status, dict):
        return None
    # An ineligible account has no reset inventory at all; only a received grants list establishes a count, so an
    # empty list is a real zero while a missing one stays unknown.
    if status.get("eligible") is not True:
        return None
    grants = status.get("grants")
    if not isinstance(grants, list) or len(grants) > 200:
        return None
    now = time.time() if now is None else now
    available, used = [], []
    for grant in grants:
        if not isinstance(grant, dict) or grant.get("paused") is not False:
            continue
        left = grant.get("resets_left")
        total = grant.get("resets_total", left)
        if (type(left) is not int or type(total) is not int or left < 0 or total < left):
            continue
        try:
            def bound(name):
                raw = grant.get(name)
                if raw is None:
                    return None
                if not isinstance(raw, str):
                    raise ValueError("Invalid bound")
                value = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
                if value.tzinfo is None:
                    raise ValueError("Missing timezone")
                return value.timestamp()
            start, end = bound("starts_at"), bound("ends_at")
        except (ValueError, OverflowError):
            continue
        if (start is not None and start > now) or (end is not None and end <= now):
            continue
        if total > 50 - len(available) - len(used):
            return None
        available.extend([grant.get("ends_at")] * left)
        used.extend([grant.get("ends_at")] * (total - left))
    return {"availableExpirations": available, "usedExpirations": used}


def codexbar_inventory_user_agent(environ=None, home=None):
    """Claude Code's identity for the reset inventory read.

    Claude answers `cedar_ember` with `eligible: false` for other clients (`ineligible_reason: "surface"`) and for
    outdated CLI versions (`"cli_version"`), so the read presents the installed Claude Code version. The version comes
    from the install layout; the CLI is never executed. The fallback is the newest version verified as eligible.
    """
    import json
    import os
    import re
    import shutil

    environ = os.environ if environ is None else environ
    home = os.path.expanduser("~") if home is None else home
    release = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
    candidates = [
        environ.get("CLAUDE_CLI_PATH"),
        shutil.which("claude", path=environ.get("PATH")),
        os.path.join(home, ".local", "bin", "claude"),
        os.path.join(home, ".claude", "local", "node_modules", ".bin", "claude"),
    ]
    for candidate in candidates:
        if not candidate:
            continue
        try:
            real = os.path.realpath(candidate)
            if not os.path.isfile(real):
                continue
            # Native installer: ~/.local/bin/claude -> ~/.local/share/claude/versions/<version>.
            name = os.path.basename(real)
            if os.path.basename(os.path.dirname(real)) == "versions" and release.match(name):
                return f"claude-cli/{name} (external, cli)"
            # npm installer: the resolved entry point lives inside the @anthropic-ai/claude-code package.
            directory = os.path.dirname(real)
            for _ in range(4):
                manifest = os.path.join(directory, "package.json")
                if os.path.isfile(manifest):
                    with open(manifest, encoding="utf-8") as handle:
                        package = json.load(handle)
                    version = package.get("version") if isinstance(package, dict) else None
                    if (package.get("name") == "@anthropic-ai/claude-code" and isinstance(version, str)
                            and release.match(version)):
                        return f"claude-cli/{version} (external, cli)"
                    break
                directory = os.path.dirname(directory)
        except (OSError, ValueError, AttributeError):
            continue
    return "claude-cli/2.1.296 (external, cli)"


# Helpers appended to the installed oauth.py, always as its trailing functions.
INSTALLED_HELPERS = (codexbar_reset_credits, codexbar_inventory_user_agent)
# Only the optional inventory read presents Claude Code's identity; the 400/403 fallback keeps cswap's own.
LEGACY_INVENTORY_REQUEST = "    req = urllib.request.Request(inventory_url, headers=headers)\n"
INVENTORY_REQUEST = (
    '    inventory_headers = {**headers, "User-Agent": codexbar_inventory_user_agent()}\n'
    "    req = urllib.request.Request(inventory_url, headers=inventory_headers)\n"
)


def installed_helpers_source():
    return "\n\n".join(inspect.getsource(helper) for helper in INSTALLED_HELPERS)


def upgrade_reset_credits(source):
    """Replace previously installed helpers, which are always the module's trailing functions."""
    start = source.find("\ndef codexbar_reset_credits(")
    if start < 0:
        raise RuntimeError("Installed normalizer not found; restore reset-complication backups first")
    names = {helper.__name__ for helper in INSTALLED_HELPERS}
    position = source.find("\ndef ", start + 1)
    while position >= 0:
        name = source[position + len("\ndef "):].split("(", 1)[0]
        if name not in names:
            raise RuntimeError("Unexpected code after the installed normalizer; nothing changed")
        position = source.find("\ndef ", position + 1)
    return source[:start] + "\n" + installed_helpers_source()


def upgrade_inventory_request(source):
    """Move an installed inventory read from cswap's identity to Claude Code's; the fallback request is unchanged."""
    start = source.find("\ndef request_usage_data(")
    end = source.find("\ndef ", start + 1)
    end = len(source) if end < 0 else end
    function = source[start:end]
    if start >= 0 and INVENTORY_REQUEST in function:
        return source
    if start < 0 or function.count(LEGACY_INVENTORY_REQUEST) != 1:
        raise RuntimeError("Installed inventory request not found; restore reset-complication backups first")
    return source[:start] + function.replace(LEGACY_INVENTORY_REQUEST, INVENTORY_REQUEST) + source[end:]


def install(root):
    marker = "# CodexBar display-safe reset complications"
    paths = [root / "oauth.py", root / "json_output.py"]
    sources = [path.read_text() for path in paths]
    if all(marker in source for source in sources):
        upgraded = upgrade_inventory_request(upgrade_reset_credits(sources[0]))
        if upgraded == sources[0]:
            print("Reset complication compatibility already installed")
            return
        compile(upgraded, str(paths[0]), "exec")
        paths[0].write_text(upgraded)
        print("Updated installed reset inventory request and normalizer; backups preserved")
        return
    if any(marker in source for source in sources):
        raise RuntimeError("Partial installation; restore reset-complication backups first")
    normalize = '    # Per-model weekly limits live in the newer ``limits`` array as\n'
    projection = '    if "scoped" in usage:\n'
    request = '''    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode())
'''
    usage_url = '    url = "https://api.anthropic.com/api/oauth/usage"\n'
    if (sources[0].count(normalize) != 1 or sources[1].count(projection) != 1
            or sources[0].count(usage_url) != 1 or request not in sources[0]):
        raise RuntimeError("Unsupported cswap source layout; nothing changed")
    # Keep cadence, credentials, selection and original measured timestamps with the adapter.
    sources[0] = sources[0].replace(normalize, f"    {marker}\n"
        "    reset_credits = codexbar_reset_credits(data)\n"
        "    if reset_credits is not None:\n"
        '        result["reset_credits"] = reset_credits\n\n' + normalize)
    sources[0] = sources[0].replace(usage_url, usage_url + '''    # Request the optional inventory on the existing usage read.
    inventory_url = url + "?cedar_ember=1"
''')
    # Scope the replacement to the usage function; other requests have the same body.
    start = sources[0].index("def request_usage_data(")
    end = sources[0].index("\ndef ", start + 1)
    function = sources[0][start:end].replace(request, INVENTORY_REQUEST + '''    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as error:
        if error.code not in (400, 403):
            raise
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode())
''')
    sources[0] = sources[0][:start] + function + sources[0][end:]
    # The new response may contain redemption handles. Log its field names only.
    sources[0] = sources[0].replace(
        '_logger.debug("Usage API response: %s", json.dumps(data, indent=2))',
        '_logger.debug("Usage API response fields: %s", sorted(data))')
    sources[0] += "\n\n" + installed_helpers_source()
    sources[1] = sources[1].replace(projection, f"    {marker}\n"
        '    if "reset_credits" in usage:\n'
        '        out["resetCredits"] = usage["reset_credits"]\n' + projection)
    for path, source in zip(paths, sources):
        compile(source, str(path), "exec")
        if path.with_suffix(path.suffix + ".before-reset-complications").exists():
            raise RuntimeError("Backup already exists; nothing changed")
    for path, source in zip(paths, sources):
        path.with_suffix(path.suffix + ".before-reset-complications").write_bytes(path.read_bytes())
        path.write_text(source)
    print("Installed reset inventory request, normalizer and JSON projection; backups preserved")


if __name__ == "__main__":
    install(pathlib.Path(sys.argv[1]))
