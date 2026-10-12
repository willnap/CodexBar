import json
import unittest
import tempfile
import pathlib
import urllib.error
from unittest.mock import patch

from patch_claude_swap_complications import codexbar_inventory_user_agent, codexbar_reset_credits, install


# Synthetic block with every field the live `cedar_ember` response carries (observed 2026-10): a used-up grant.
LIVE_SHAPE_USED_GRANT = {
    "eligible": True, "ineligible_reason": None, "at_limit": False, "exhausted": [], "next_grant_id": None,
    "weekly_resets_at": None, "cooldown_until": None, "event_props": {"surface": "claude_code_cli"},
    "grants": [{
        "id": "synthetic_grant", "label": "Synthetic", "arm": "synthetic", "blocking": [], "clears": ["five_hour"],
        "percent_used": {}, "paused": False, "usable_now": False, "use_requires_limit": False,
        "resets_left": 0, "resets_total": 1,
        "starts_at": "2026-01-01T00:00:00+00:00", "ends_at": "2026-12-01T00:00:00+00:00",
    }],
}


class ResetInventoryTests(unittest.TestCase):
    def test_live_shape_counts_a_used_grant_as_used_and_zero_available(self):
        result = codexbar_reset_credits({"cedar_ember": LIVE_SHAPE_USED_GRANT}, now=1791800000)
        self.assertEqual(result, {"availableExpirations": [], "usedExpirations": ["2026-12-01T00:00:00+00:00"]})
        self.assertNotIn("synthetic_grant", json.dumps(result))

    def test_other_client_surface_stays_unknown(self):
        # What the usage endpoint returns to a non-Claude-Code client identity: no inventory, not zero.
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {
            "eligible": False, "ineligible_reason": "surface", "grants": [],
        }}, now=1791800000))

    def test_display_projection_preserves_inventory_and_omits_redemption_handles(self):
        result = codexbar_reset_credits({"cedar_ember": {"eligible": True, "grants": [
            {"id": "secret-redemption-handle", "paused": False, "resets_left": 2,
             "resets_total": 3, "ends_at": "2026-10-13T00:00:00Z"},
        ]}}, now=1791800000)
        self.assertEqual(result, {
            "availableExpirations": ["2026-10-13T00:00:00Z"] * 2,
            "usedExpirations": ["2026-10-13T00:00:00Z"],
        })

    def test_missing_inventory_is_unknown_and_reported_empty_inventory_is_zero(self):
        empty = {"availableExpirations": [], "usedExpirations": []}
        self.assertIsNone(codexbar_reset_credits({}, now=1791800000))
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": None}))
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {"grants": []}}))
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {"eligible": "yes", "grants": []}}))
        # Ineligible accounts have no inventory, and a missing grants list was never received: both stay unknown.
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {"eligible": False, "grants": []}}))
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {"eligible": False}}))
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {"eligible": True}}))
        self.assertEqual(codexbar_reset_credits({"cedar_ember": {"eligible": True, "grants": []}}), empty)
        self.assertEqual(codexbar_reset_credits({"cedar_ember": {"eligible": True, "grants": [
            {"paused": True, "resets_left": 1},
        ]}}, now=1791800000), empty)

    def test_unavailable_or_malformed_grants_do_not_become_available_resets(self):
        grants = [
            {"paused": True, "resets_left": 2},
            {"paused": False, "resets_left": 2, "ends_at": "2026-10-11T00:00:00Z"},
            {"paused": False, "resets_left": 2, "starts_at": "2026-10-13T00:00:00Z"},
            {"paused": False, "resets_left": True},
            {"paused": False, "resets_left": 2, "ends_at": "malformed"},
            {"paused": False, "resets_left": 2, "resets_total": 1},
        ]
        result = codexbar_reset_credits({"cedar_ember": {"eligible": True, "grants": grants}}, now=1791800000)
        self.assertEqual(result, {"availableExpirations": [], "usedExpirations": []})
        self.assertIsNone(codexbar_reset_credits({"cedar_ember": {"eligible": True, "grants": [
            {"paused": False, "resets_left": 51},
        ]}}, now=1791800000))


class InventoryIdentityTests(unittest.TestCase):
    CLI_IDENTITY = r"^claude-cli/\d+\.\d+\.\d+\S* \(external, cli\)$"

    def test_native_installer_version_comes_from_the_install_layout_without_running_the_cli(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = pathlib.Path(temporary)
            versions = home / ".local" / "share" / "claude" / "versions"
            versions.mkdir(parents=True)
            (versions / "9.8.7").write_text("")
            (home / ".local" / "bin").mkdir(parents=True)
            (home / ".local" / "bin" / "claude").symlink_to(versions / "9.8.7")
            with patch("subprocess.run", side_effect=AssertionError("ran the CLI")), \
                    patch("subprocess.Popen", side_effect=AssertionError("ran the CLI")):
                self.assertEqual(codexbar_inventory_user_agent({"PATH": ""}, str(home)),
                                 "claude-cli/9.8.7 (external, cli)")

    def test_npm_installer_version_comes_from_the_claude_code_package_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            package = root / "lib" / "node_modules" / "@anthropic-ai" / "claude-code"
            package.mkdir(parents=True)
            (package / "package.json").write_text(json.dumps({"name": "@anthropic-ai/claude-code",
                                                              "version": "9.8.6"}))
            (package / "cli.js").write_text("")
            (package / "cli.js").chmod(0o755)
            (root / "bin").mkdir()
            (root / "bin" / "claude").symlink_to(package / "cli.js")
            self.assertEqual(codexbar_inventory_user_agent({"PATH": str(root / "bin")}, str(root / "home")),
                             "claude-cli/9.8.6 (external, cli)")

    def test_unrecognized_install_uses_the_verified_fallback_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "package.json").write_text(json.dumps({"name": "unrelated", "version": "1.0.0"}))
            (root / "claude").write_text("")
            environ = {"PATH": "", "CLAUDE_CLI_PATH": str(root / "claude")}
            self.assertEqual(codexbar_inventory_user_agent(environ, str(root / "home")),
                             "claude-cli/2.1.296 (external, cli)")
            self.assertEqual(codexbar_inventory_user_agent({"PATH": ""}, str(root / "missing")),
                             "claude-cli/2.1.296 (external, cli)")


class InstallationTests(unittest.TestCase):
    def test_pipeline_installation_is_idempotent_and_forwards_sanitized_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            oauth = root / "oauth.py"
            projection = root / "json_output.py"
            oauth.write_text('''import json
import urllib.request
import urllib.error

def normalize(data):
    result = {}
    # Per-model weekly limits live in the newer ``limits`` array as
    return result

def request_usage_data(token):
    url = "https://api.anthropic.com/api/oauth/usage"
    headers = {"Authorization": "fixture", "User-Agent": "claude-swap/1.0"}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode())

def unrelated():
    return None
''')
            projection.write_text('''def usage_to_json(usage):
    out = {}
    if "scoped" in usage:
        out["scoped"] = usage["scoped"]
    return out
''')
            original = oauth.read_bytes()
            install(root)
            first = oauth.read_bytes()
            install(root)
            self.assertEqual(oauth.read_bytes(), first)
            self.assertEqual(oauth.with_suffix(".py.before-reset-complications").read_bytes(), original)
            namespace, output = {}, {}
            exec(first, namespace)
            exec(projection.read_text(), output)
            normalized = namespace["normalize"]({"cedar_ember": {"eligible": True, "grants": [
                {"paused": False, "resets_left": 2, "id": "redemption-handle"},
            ]}})
            self.assertEqual(output["usage_to_json"](normalized), {"resetCredits": {
                "availableExpirations": [None, None], "usedExpirations": [],
            }})
            class Response:
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def read(self): return b'{}'
            with patch("urllib.request.urlopen", return_value=Response()) as request:
                namespace["request_usage_data"]("fixture")
                sent = request.call_args.args[0]
                self.assertEqual(sent.full_url, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
                # Claude serves the inventory only to Claude Code's identity; credentials are unchanged.
                self.assertRegex(sent.get_header("User-agent"), InventoryIdentityTests.CLI_IDENTITY)
                self.assertEqual(sent.get_header("Authorization"), "fixture")
            rejected = urllib.error.HTTPError("https://api.anthropic.com", 400, "Bad Request", {}, None)
            with patch("urllib.request.urlopen", side_effect=[rejected, Response()]) as request:
                namespace["request_usage_data"]("fixture")
                fallback = request.call_args_list[1].args[0]
                self.assertEqual(fallback.full_url, "https://api.anthropic.com/api/oauth/usage")
                self.assertEqual(fallback.get_header("User-agent"), "claude-swap/1.0")
            ineligible = namespace["normalize"]({"cedar_ember": {"eligible": False}})
            self.assertEqual(output["usage_to_json"](ineligible), {})
            empty = namespace["normalize"]({"cedar_ember": {"eligible": True, "grants": []}})
            self.assertEqual(output["usage_to_json"](empty), {"resetCredits": {
                "availableExpirations": [], "usedExpirations": [],
            }})
            self.assertEqual(output["usage_to_json"](namespace["normalize"]({})), {})

    # The request installed by the first version of this patch, which presented cswap's own identity.
    OLDER_REQUEST = '''import json
import urllib.request
import urllib.error

def request_usage_data(access_token):
    url = "https://api.anthropic.com/api/oauth/usage"
    # Request the optional inventory on the existing usage read.
    inventory_url = url + "?cedar_ember=1"
    headers = {"Authorization": "fixture", "User-Agent": "claude-swap/1.0"}
    req = urllib.request.Request(inventory_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as error:
        if error.code not in (400, 403):
            raise
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode())

'''

    def test_installed_older_request_and_normalizer_are_upgraded_in_place(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            marker = "# CodexBar display-safe reset complications"
            older = (self.OLDER_REQUEST + f"def normalize(data):\n    {marker}\n    return data\n\n\n"
                     "def codexbar_reset_credits(data, now=None):\n    return None\n")
            (root / "oauth.py").write_text(older)
            (root / "json_output.py").write_text(f"def usage_to_json(usage):\n    {marker}\n    return usage\n")
            install(root)
            upgraded = (root / "oauth.py").read_text()
            self.assertIn('grants = status.get("grants")', upgraded)
            self.assertEqual(upgraded.count("def codexbar_reset_credits("), 1)
            self.assertEqual(upgraded.count("def codexbar_inventory_user_agent("), 1)
            self.assertNotIn("Request(inventory_url, headers=headers)", upgraded)
            namespace = {}
            exec(upgraded, namespace)
            self.assertIsNone(namespace["codexbar_reset_credits"]({"cedar_ember": {"eligible": False}}))
            self.assertEqual(namespace["codexbar_reset_credits"]({"cedar_ember": {"eligible": True, "grants": []}}), {
                "availableExpirations": [], "usedExpirations": [],
            })
            class Response:
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def read(self): return b'{}'
            with patch("urllib.request.urlopen", return_value=Response()) as request:
                namespace["request_usage_data"]("fixture")
                self.assertRegex(request.call_args.args[0].get_header("User-agent"),
                                 InventoryIdentityTests.CLI_IDENTITY)
            install(root)
            self.assertEqual((root / "oauth.py").read_text(), upgraded)

    def test_upgrade_refuses_unfamiliar_code_after_the_installed_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            marker = "# CodexBar display-safe reset complications"
            source = (self.OLDER_REQUEST + f"def normalize(data):\n    {marker}\n    return data\n\n\n"
                      "def codexbar_reset_credits(data, now=None):\n    return None\n\n\n"
                      "def appended_later():\n    return None\n")
            (root / "oauth.py").write_text(source)
            (root / "json_output.py").write_text(f"def usage_to_json(usage):\n    {marker}\n    return usage\n")
            with self.assertRaises(RuntimeError):
                install(root)
            self.assertEqual((root / "oauth.py").read_text(), source)


if __name__ == "__main__":
    unittest.main()
