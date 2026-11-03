#!/usr/bin/env python3
"""Package original dependency notices for the bundled runtime, without local paths."""
import argparse
import json
from pathlib import Path
import shutil


def notice_files(directory: Path) -> list[Path]:
    return sorted(
        path for path in directory.iterdir()
        if path.is_file() and path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "AUTHORS"))
    )


def package(metadata: dict, runtime: Path, zig_cache: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    runtime = runtime.resolve()
    supplemental = Path(__file__).resolve().parent.parent / "licenses" / "runtime"
    inventory = []
    for item in sorted(metadata["packages"], key=lambda entry: (entry["name"], entry["version"])):
        directory = Path(item["manifest_path"]).parent
        files = notice_files(directory)
        if item.get("license_file"):
            declared = directory / item["license_file"]
            if declared not in files:
                files.append(declared)
        if not files and directory.is_relative_to(runtime):
            # The in-tree Rust VT binding shares the upstream repository license.
            files = notice_files(runtime)
        key = f"{item['name']}-{item['version']}"
        supplement = supplemental / key
        if not files and supplement.is_dir():
            files = notice_files(supplement)
        if not files:
            raise RuntimeError(f"Missing original license text: {item['name']} {item['version']}")
        target = destination / "rust" / key
        target.mkdir(parents=True, exist_ok=True)
        for source in files:
            shutil.copyfile(source, target / source.name)
        inventory.append({"package": key, "license": item.get("license"), "authors": item.get("authors", []),
                          "repository": item.get("repository"), "notices": [f"rust/{key}/{p.name}" for p in files]})

    # Include notices in the retained upstream source and all Zig packages fetched
    # into this build's dedicated cache, including nested third-party components.
    for label, directory in (("upstream", runtime), ("zig", zig_cache / "p")):
        if not directory.is_dir():
            raise RuntimeError(f"Missing {label} source directory for license collection")
        for source in sorted(directory.rglob("*")):
            if not source.is_file() or not source.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE")):
                continue
            relative = source.relative_to(directory)
            if any(part in ("target", ".zig-cache", "zig-pkg", "zig-out", ".git") for part in relative.parts):
                continue
            target = destination / label / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    (destination / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    shutil.copyfile(supplemental / "PROVENANCE.json", destination / "supplemental-provenance.json")
    shutil.copyfile(supplemental / "MIT-standard.txt", destination / "MIT-standard.txt")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("metadata", type=Path)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("zig_cache", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    package(json.loads(args.metadata.read_text()), args.runtime, args.zig_cache, args.destination)
