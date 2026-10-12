#!/usr/bin/env python3
"""Safe signing argument checks; opt in to a disposable-keychain integration test."""
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("native_signing.sh")


class NativeSigningTests(unittest.TestCase):
    def test_adhoc_identity_is_rejected_before_creating_signing_storage(self):
        with tempfile.TemporaryDirectory(prefix="native-signing-test-") as directory:
            storage = pathlib.Path(directory) / "signing"
            result = subprocess.run(
                ["bash", str(SCRIPT), "/missing.app"],
                env=dict(os.environ, NATIVE_SIGNING_IDENTITY="-", NATIVE_SIGNING_HOME=str(storage)),
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ad-hoc", result.stderr)
            self.assertFalse(storage.exists())

    def test_missing_app_is_rejected_before_creating_signing_storage(self):
        with tempfile.TemporaryDirectory(prefix="native-signing-test-") as directory:
            storage = pathlib.Path(directory) / "signing"
            environment = dict(os.environ, NATIVE_SIGNING_HOME=str(storage))
            environment.pop("NATIVE_SIGNING_IDENTITY", None)
            result = subprocess.run(
                ["bash", str(SCRIPT), "/missing.app"], env=environment,
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("app bundle", result.stderr)
            self.assertFalse(storage.exists())

    def test_incomplete_identity_is_not_silently_rotated(self):
        with tempfile.TemporaryDirectory(prefix="native-signing-test-") as directory:
            root = pathlib.Path(directory)
            app = root / "Fixture.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_text("fixture")
            storage = root / "signing"
            storage.mkdir()
            certificate = storage / "identity.pem"
            certificate.write_text("preserved existing identity")
            environment = dict(os.environ, NATIVE_SIGNING_HOME=str(storage))
            environment.pop("NATIVE_SIGNING_IDENTITY", None)
            result = subprocess.run(["bash", str(SCRIPT), str(app)], env=environment,
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("restore its existing identity", result.stderr)
            self.assertEqual(certificate.read_text(), "preserved existing identity")
            self.assertFalse((storage / "keychain-password").exists())

    def test_concurrent_signer_lock_is_not_removed(self):
        with tempfile.TemporaryDirectory(prefix="native-signing-test-") as directory:
            root = pathlib.Path(directory)
            app = root / "Fixture.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_text("fixture")
            storage = root / "signing"
            lock = storage / ".lock"
            lock.mkdir(parents=True)
            environment = dict(os.environ, NATIVE_SIGNING_HOME=str(storage))
            environment.pop("NATIVE_SIGNING_IDENTITY", None)
            result = subprocess.run(["bash", str(SCRIPT), str(app)], env=environment,
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("another signing process", result.stderr)
            self.assertTrue(lock.is_dir())

    @unittest.skipUnless(os.environ.get("NATIVE_SIGNING_INTEGRATION") == "1",
                         "Opt in explicitly; creates only a disposable signing keychain")
    def test_rebuilt_apps_keep_certificate_requirement_with_different_code_hashes(self):
        with tempfile.TemporaryDirectory(prefix="native-signing-test-") as directory:
            root = pathlib.Path(directory)
            storage = root / "signing"
            environment = dict(os.environ, NATIVE_SIGNING_HOME=str(storage))
            environment.pop("NATIVE_SIGNING_IDENTITY", None)
            requirements = []
            hashes = []
            keychain_search = subprocess.check_output(["/usr/bin/security", "list-keychains", "-d", "user"])
            default_keychain = subprocess.check_output(["/usr/bin/security", "default-keychain", "-d", "user"])
            try:
                for version in (1, 2):
                    app = root / f"Version{version}.app"
                    (app / "Contents/MacOS").mkdir(parents=True)
                    (app / "Contents/Resources").mkdir()
                    subprocess.run(["/bin/cp", "/usr/bin/true", str(app / "Contents/MacOS/Fixture")], check=True)
                    with (app / "Contents/Info.plist").open("wb") as output:
                        plistlib.dump({"CFBundleIdentifier": "com.will.codexbar.signing.fixture",
                                       "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
                                       "CFBundleVersion": str(version)}, output)
                    (app / "Contents/Resources/version.txt").write_text(str(version))
                    subprocess.run(["bash", str(SCRIPT), str(app)], env=environment, check=True)
                    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
                    details = subprocess.run(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(app)],
                                             capture_output=True, text=True, check=True)
                    lines = (details.stdout + details.stderr).splitlines()
                    requirements.append(next(line for line in lines if "designated =>" in line))
                    hashes.append(next(line for line in lines if line.startswith("CDHash=")))
                self.assertEqual(requirements[0], requirements[1])
                self.assertNotEqual(hashes[0], hashes[1])
                self.assertIn('identifier "com.will.codexbar.signing.fixture"', requirements[0])
                self.assertIn('certificate root = H"', requirements[0])
                self.assertNotIn("cdhash", requirements[0])
                self.assertEqual(subprocess.check_output(["/usr/bin/security", "list-keychains", "-d", "user"]),
                                 keychain_search)
                self.assertEqual(subprocess.check_output(["/usr/bin/security", "default-keychain", "-d", "user"]),
                                 default_keychain)
                self.assertEqual((storage / "keychain-password").stat().st_mode & 0o777, 0o600)
                self.assertFalse((storage / "identity.key").exists())
                # An impostor with the same bundle ID cannot meet this app's requirement.
                impostor = root / "Version2.app"
                subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(impostor)], check=True)
                requirement = requirements[0].split("designated => ", 1)[1]
                result = subprocess.run(["/usr/bin/codesign", "--verify", "-R", requirement, str(impostor)],
                                        capture_output=True, text=True, check=False)
                self.assertNotEqual(result.returncode, 0)
            finally:
                keychain = storage / "native-signing.keychain-db"
                if keychain.exists():
                    subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)], check=False)


if __name__ == "__main__":
    unittest.main()
