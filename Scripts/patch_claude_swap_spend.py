"""Reversible compatibility fix for claude-swap 0.26's typed spend response.

Only the usage normalizer and JSON projection change. Credential access,
refreshing, account selection, and fetch timestamps remain owned by cswap.
Run with its site-packages/claude_swap directory; pristine .before-monthly-spend
copies are retained beside both files. Refuse unknown source layouts.
"""

import inspect
import pathlib
import sys


def codexbar_monthly_spend(data):
    import math

    def money(raw):
        if not isinstance(raw, dict):
            return None
        minor, exponent, currency = (
            raw.get("amount_minor"), raw.get("exponent"), raw.get("currency")
        )
        if (
            isinstance(minor, bool) or not isinstance(minor, (int, float))
            or not math.isfinite(minor) or minor < 0
            or isinstance(exponent, bool) or not isinstance(exponent, int)
            or not 0 <= exponent <= 9
            or not isinstance(currency, str) or len(currency) != 3
            or not currency.isascii() or not currency.isalpha()
        ):
            return None
        return minor / (10 ** exponent), currency.upper()

    source = data.get("spend")
    if not isinstance(source, dict) or not isinstance(source.get("enabled"), bool):
        return None
    used = money(source.get("used"))
    if used is None:
        return None
    limit = money(source.get("limit"))
    if source["enabled"] and (limit is None or limit[1] != used[1] or limit[0] <= 0):
        return None
    active_limit = limit[0] if source["enabled"] else 0
    return {
        "used": used[0], "limit": active_limit,
        "pct": 100 * used[0] / active_limit if active_limit else 0,
        "currency": used[1], "enabled": source["enabled"], "period": "Monthly",
    }


def install(root):
    marker = "# CodexBar typed monthly spend compatibility"
    paths = [root / "oauth.py", root / "json_output.py"]
    sources = [path.read_text() for path in paths]
    if all(marker in source for source in sources):
        print("Typed monthly spend compatibility already installed")
        return
    if any(marker in source for source in sources):
        raise RuntimeError("Partial installation; restore the pristine backups first")
    normalize_anchor = '    # Per-model weekly limits live in the newer ``limits`` array as\n'
    json_anchor = '        if "resets_at" in spend:\n'
    if sources[0].count(normalize_anchor) != 1 or sources[1].count(json_anchor) != 1:
        raise RuntimeError("Unsupported cswap source layout; nothing changed")
    sources[0] = sources[0].replace(
        normalize_anchor,
        f"    {marker}\n"
        "    measured_spend = codexbar_monthly_spend(data)\n"
        "    if measured_spend is not None:\n"
        '        result["spend"] = measured_spend\n\n' + normalize_anchor,
    ) + "\n\n" + inspect.getsource(codexbar_monthly_spend)
    sources[1] = sources[1].replace(
        json_anchor,
        f"        {marker}\n"
        '        for field in ("enabled", "period"):\n'
        "            if field in spend:\n"
        "                spend_out[field] = spend[field]\n" + json_anchor,
    )
    for path, source in zip(paths, sources):
        compile(source, str(path), "exec")
        backup = path.with_suffix(path.suffix + ".before-monthly-spend")
        if backup.exists():
            raise RuntimeError(f"Backup already exists at {backup}; nothing changed")
    for path, source in zip(paths, sources):
        backup = path.with_suffix(path.suffix + ".before-monthly-spend")
        backup.write_bytes(path.read_bytes())
        path.write_text(source)
    print("Installed typed monthly spend normalizer and JSON projection; backups preserved")


if __name__ == "__main__":
    install(pathlib.Path(sys.argv[1]))
