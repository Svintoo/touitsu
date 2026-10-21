"""Build both injected hook DLLs from the pinned Textractor source plus our search fixes."""
import argparse
from pathlib import Path
import subprocess
import os

p = argparse.ArgumentParser()
p.add_argument("arch", choices=("x86", "x64"))
p.add_argument("output", type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parent.parent
vswhere = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe")
vs = Path(subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"], text=True).strip())
cmake = vs / "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe"
ninja = vs / "Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe"
vcvars = vs / "VC/Auxiliary/Build/vcvarsall.bat"
env = os.environ.copy()
setup = subprocess.check_output(f'"{vcvars}" {"x64" if a.arch == "x64" else "x64_x86"} >nul && set', shell=True, text=True)
for line in setup.splitlines():
    if "=" in line and not line.startswith("="):
        key, value = line.split("=", 1)
        env[key] = value
output = a.output.resolve()
build = output / "ninja"
subprocess.run([str(cmake), "-S", str(root / "src/native/hook_backend"), "-B", str(build), "-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja.as_posix(), "-DCMAKE_BUILD_TYPE=Release", "-DTOUITSU_OUTPUT=" + output.as_posix()], check=True, env=env)
subprocess.run([str(cmake), "--build", str(build), "--config", "Release", "--target", "texthook", "--parallel", "4"], check=True, env=env)
