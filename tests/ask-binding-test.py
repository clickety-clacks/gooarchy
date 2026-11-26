"""Exercise the packaged config hook with Scottland's base/override inputs."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

GENERATOR = Path(__file__).resolve().parents[1] / "session/45-gooarchy-ask"
DEFAULT = "[command]\nbinding_gooarchy_ask = <super> KEY_SPACE\ncommand_gooarchy_ask = gooarchy-ask\n"


class AskBindingTest(unittest.TestCase):
    def generate(self, base="", overrides="", adapter=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "scottland").mkdir()
            (root / "scottland/overrides.ini").write_text(overrides)
            (root / "base.ini").write_text(base)
            hooks = root / "hooks"
            if adapter:
                importer = hooks / "config.d/50-omarchy-shortcuts"
                importer.parent.mkdir(parents=True)
                importer.touch(mode=0o755)
            return subprocess.check_output(
                [GENERATOR, root / "base.ini"],
                env={**os.environ, "SCOTTLAND_HOOKS": str(hooks), "XDG_CONFIG_HOME": temp},
                text=True,
            )

    def test_default_and_adapter(self):
        self.assertEqual(self.generate(), DEFAULT)
        self.assertEqual(self.generate(adapter=True), "")

    def test_explicit_ask_binding(self):
        for value in ("none", "<super> KEY_A", "<super> KEY_SPACE"):
            for file in ("base", "overrides"):
                with self.subTest(value=value, file=file):
                    self.assertEqual(
                        self.generate(**{file: f"[command]\nbinding_gooarchy_ask = {value}\n"}),
                        "[command]\ncommand_gooarchy_ask = gooarchy-ask\n",
                    )
        self.assertEqual(self.generate(
            "[command]\nrepeatable_binding_gooarchy_ask = <super> KEY_A\ncommand_gooarchy_ask = custom\n"
        ), "")

    def test_existing_owners_and_override_precedence(self):
        other = "[command]\nbinding_custom = <shift> KEY_F | <Super> KEY_SPACE\n"
        self.assertEqual(self.generate(base=other), "")
        self.assertEqual(self.generate(overrides=other), "")
        self.assertEqual(self.generate(base=other, overrides="[command]\nbinding_custom = none\n"),
                         DEFAULT)
        self.assertEqual(self.generate(overrides="[scottland]\nremap_from_launcher = Super+space\n"), "")

    def test_commented_and_continued_bindings_keep_their_action(self):
        binding = (
            "[command] # existing launcher\n"
            "binding_custom = <shift> KEY_F | \\\n"
            "    <Super> KEY_SPACE # my launcher\n"
            "command_custom = my-launcher \\#literal # comment\n"
        )
        for file in ("base", "overrides"):
            with self.subTest(file=file):
                self.assertEqual(self.generate(**{file: binding}), "")
        self.assertEqual(self.generate(base=binding,
            overrides="[command] # user section\nbinding_custom = none # disabled\n"),
            DEFAULT)

    def test_alternate_command_binding_variants_are_explicit(self):
        for variant in ("always_binding", "release_binding"):
            for value in ("<super> KEY_A", "none"):
                with self.subTest(variant=variant, value=value):
                    self.assertEqual(self.generate(
                        overrides=f"[command]\n{variant}_gooarchy_ask = {value} # user choice\n"),
                        "[command]\ncommand_gooarchy_ask = gooarchy-ask\n")


if __name__ == "__main__":
    unittest.main()
