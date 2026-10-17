#!/usr/bin/env python3
"""Build local inference; --ios creates a static XCFramework on a Mac with Xcode."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    command = [str(arg) for arg in args]
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def verify_apple_archive(path, arch):
    """Check the archive slice and exported static GDExtension entry point."""
    run("/usr/bin/lipo", "-verify_arch", arch, path)
    command = ["xcrun", "nm", "-arch", arch, "-gU", str(path)]
    print("+", " ".join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT, check=True, text=True, capture_output=True)
    if not any(line.split() and line.split()[-1] == "_qwen_library_init"
               for line in result.stdout.splitlines()):
        raise SystemExit(f"Missing defined qwen_library_init entry point in {path} ({arch})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios", action="store_true", help="Mac/Xcode only: device + simulator XCFramework")
    parser.add_argument("--jobs", type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument("--cmake", default=os.environ.get("CMAKE", "cmake"))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    if args.ios and platform.system() != "Darwin":
        parser.error("iOS compilation requires macOS and full Xcode; Linux/Windows cannot validate an iOS build")
    for dependency in ("llama.cpp", "godot-cpp"):
        if not (ROOT / "vendor" / dependency / "CMakeLists.txt").exists():
            raise SystemExit("Missing native source dependencies. Run python scripts/fetch_dependencies.py first.")
    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build" / ".gdignore").touch()
    cmake = args.cmake
    if not shutil.which(cmake):
        raise SystemExit("CMake 3.24+ was not found. Install CMake or pass --cmake /path/to/cmake.")
    generator = ["-G", "Ninja"] if shutil.which("ninja") else []

    def build(directory, extra=()):
        run(cmake, "-S", ROOT / "native", "-B", directory, *generator,
            "-DCMAKE_BUILD_TYPE=Release", *extra)
        run(cmake, "--build", directory, "--config", "Release", "--parallel", args.jobs)

    if not args.ios:
        directory = ROOT / "build" / platform.system().lower()
        build(directory)
        ctest = Path(shutil.which(cmake) or cmake).resolve().with_name("ctest.exe" if os.name == "nt" else "ctest")
        run(ctest if ctest.exists() else "ctest", "--test-dir", directory, "-C", "Release", "--output-on-failure")
        print("Built desktop GDExtension in bin/. Open project.godot with Godot 4.7.2.")
        return

    # A command-line-tools-only installation has no iPhoneOS SDK.
    run("xcodebuild", "-version")
    # Nested CMake projects can reuse the cached sysroot verbatim. Pass an
    # absolute SDK path so Clang never receives the bare name "iphoneos".
    sdk_paths = {
        sdk: subprocess.check_output(
            ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True, cwd=ROOT
        ).strip()
        for sdk in ("iphoneos", "iphonesimulator")
    }
    merged = {}
    for label, sdk, arch in (("device", "iphoneos", "arm64"),
                             ("sim-arm64", "iphonesimulator", "arm64"),
                             ("sim-x86_64", "iphonesimulator", "x86_64")):
        directory = ROOT / "build" / f"ios-{label}"
        build(directory, ("-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk_paths[sdk]}",
                          f"-DCMAKE_OSX_ARCHITECTURES={arch}", f"-DCMAKE_SYSTEM_PROCESSOR={arch}",
                          "-DCMAKE_OSX_DEPLOYMENT_TARGET=16.4", "-DQWEN_IOS_STATIC=ON",
                          "-DQWEN_BUILD_TESTS=OFF", "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO"))
        archives = (directory / "qwen_archives_Release.txt").read_text().splitlines()
        if len(archives) != 7 or any(not Path(path).is_file() for path in archives):
            raise SystemExit(f"Incomplete static-library manifest: {directory}")
        output = directory / "libqwen_runner.a"
        run("/usr/bin/libtool", "-static", "-o", output, *archives)
        verify_apple_archive(output, arch)
        merged[label] = output
    simulator = ROOT / "build" / "libqwen_runner.simulator.a"
    run("/usr/bin/lipo", "-create", merged["sim-arm64"], merged["sim-x86_64"], "-output", simulator)
    for arch in ("arm64", "x86_64"):
        verify_apple_archive(simulator, arch)
    output = ROOT / "bin" / "libqwen_runner.ios.xcframework"
    temporary = ROOT / "build" / "libqwen_runner.ios.xcframework"
    if temporary.exists():
        shutil.rmtree(temporary)
    run("xcodebuild", "-create-xcframework", "-library", merged["device"], "-library", simulator, "-output", temporary)
    if output.exists():
        shutil.rmtree(output)
    shutil.move(temporary, output)
    (ROOT / "build" / "ios").mkdir(exist_ok=True)
    print("Built iOS XCFramework. Set your team ID and bundle ID in Godot's iOS export preset.")
    print("Export build/ios/QwenDemo.xcodeproj, then sign and test on a real iPhone.")
    print("This command only builds the native XCFramework; it does not export, sign, or test the app.")


if __name__ == "__main__":
    main()
