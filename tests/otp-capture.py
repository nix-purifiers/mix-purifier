"""Select the compiled applications from a fresh native Mix capture."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
sdk = Path(subprocess.check_output(["nix", "build", str(repo) + "#cli", "--no-link", "--print-out-paths"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="compiled OTP native capture ") as temporary:
    root = Path(temporary) / "umbrella"
    shutil.copytree(repo / "tests/fixtures/umbrella", root, ignore=shutil.ignore_patterns("_build", ".mix-purifier-gcroots"))
    (root / "mix-purifier.lock.json").unlink()
    env = dict(os.environ, HEX_HOME=str(Path(temporary) / "hex"), MIX_HOME=str(Path(temporary) / "mix"))
    Path(env["HEX_HOME"]).mkdir(); Path(env["MIX_HOME"]).mkdir()
    subprocess.run([sdk / "bin/mix-purifier", "lock"], cwd=root, env=env, check=True, timeout=600)
    second = Path(temporary) / "umbrella-hola"
    shutil.copytree(root, second, ignore=shutil.ignore_patterns("_build", ".mix-purifier-gcroots"))
    module = second / "apps/greeter/lib/greeter.ex"
    original = module.read_text()
    assert "Hello, #{name}" in original
    module.write_text(original.replace("Hello, #{name}", "Hola, #{name}"))
    output = subprocess.check_output(["nix", "build", "--impure", "--no-link", "--print-out-paths", "--file",
        str(repo / "tests/otp-consumer-build.nix"), "--argstr", "projectRoot", str(repo), "--argstr", "src1", str(root), "--argstr", "src2", str(second)], text=True).strip()
    assert (Path(output) / "0-native-erlang.json").exists()
print("Fresh native Mix capture replayed through both languages and all resource carriers")
