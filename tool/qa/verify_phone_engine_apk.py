#!/usr/bin/env python3
"""Verify actual APK bytes, including AGP split outputs; no Android/device needed."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile


ENGINE_LIBRARIES = frozenset({
    "libaiteam_engine.so", "libaiteam_sandbox.so", "libaiteam_boundary_probe.so",
})
MANIFEST_ENTRY = "assets/aiteam-engine-manifest.json"


class VerificationError(ValueError):
    pass


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError("duplicate_json_key")
        result[key] = value
    return result


def read_json(data):
    return json.loads(data, object_pairs_hook=_unique_object)


def manifest_hashes(data):
    manifest = read_json(data)
    if manifest.get("schemaVersion") != 2:
        raise VerificationError("manifest_schema")
    abis = manifest.get("abis")
    if not isinstance(abis, dict) or not abis:
        raise VerificationError("manifest_abis")
    result = {}
    for abi, entry in abis.items():
        if not isinstance(abi, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", abi):
            raise VerificationError("manifest_abi")
        hashes = entry.get("sha256") if isinstance(entry, dict) else None
        if not isinstance(hashes, dict) or set(hashes) != ENGINE_LIBRARIES:
            raise VerificationError("manifest_libraries")
        if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
               for value in hashes.values()):
            raise VerificationError("manifest_hash")
        result[abi] = hashes
    return result


def verify_source(manifest_data, repo):
    """A consistent manifest plus stale ELFs must not pass a release build."""
    repo = Path(repo)
    inputs = [repo / "engine/phone/Cargo.toml", repo / "engine/phone/Cargo.lock",
              *sorted((repo / "engine/phone/src").rglob("*.rs"))]
    digest = hashlib.sha256()
    for path in inputs:
        digest.update(str(path.relative_to(repo)).encode() + b"\0" + path.read_bytes() + b"\0")
    if read_json(manifest_data).get("sourceSha256") != digest.hexdigest():
        raise VerificationError("stale_engine_sources_rebuild_and_stage")


def verify_apk(apk, manifest_data, selected_abis=None):
    expected = manifest_hashes(manifest_data)
    required_abis = set(expected) if selected_abis is None else set(selected_abis) & set(expected)
    if not required_abis:
        raise VerificationError("no_supported_abi")
    results = []
    with zipfile.ZipFile(apk) as archive:
        names = [entry.filename for entry in archive.infolist()]
        if len(names) != len(set(names)):
            raise VerificationError("duplicate_zip_entry")
        if MANIFEST_ENTRY not in names:
            raise VerificationError("missing_manifest")
        if archive.read(MANIFEST_ENTRY) != manifest_data:
            raise VerificationError("packaged_manifest_mismatch")
        engine_entries = {name for name in names if re.fullmatch(r"lib/[^/]+/libaiteam_[^/]+\.so", name)}
        required_entries = {
            f"lib/{abi}/{library}" for abi in required_abis for library in ENGINE_LIBRARIES
        }
        if engine_entries != required_entries:
            missing = sorted(required_entries - engine_entries)
            unexpected = sorted(engine_entries - required_entries)
            if missing:
                raise VerificationError("missing_library " + missing[0])
            raise VerificationError("unexpected_library " + unexpected[0])
        for abi in sorted(required_abis):
            for library in sorted(ENGINE_LIBRARIES):
                name = f"lib/{abi}/{library}"
                digest = hashlib.sha256()
                with archive.open(name) as stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
                actual = digest.hexdigest()
                if actual != expected[abi][library]:
                    raise VerificationError("hash_mismatch " + name)
                results.append((abi, library, actual))
    return results


def packaged_outputs(directory, selected_abis=None):
    """Use AGP's current output manifest, never stale APKs from a directory glob."""
    directory = Path(directory).resolve()
    metadata = read_json((directory / "output-metadata.json").read_bytes())
    elements = metadata.get("elements")
    if not isinstance(elements, list) or not elements:
        raise VerificationError("missing_apk_outputs")
    outputs = []
    seen = set()
    for element in elements:
        filename = element.get("outputFile")
        if not isinstance(filename, str) or Path(filename).is_absolute():
            raise VerificationError("invalid_apk_output")
        path = (directory / filename).resolve()
        if not path.is_relative_to(directory) or path in seen or not path.is_file():
            raise VerificationError("invalid_apk_output")
        seen.add(path)
        filters = element.get("filters", [])
        if not isinstance(filters, list):
            raise VerificationError("invalid_apk_filters")
        abi_filters = [entry.get("identifier") for entry in filters if entry.get("filterType") == "ABI"]
        if len(abi_filters) > 1 or any(not isinstance(abi, str) for abi in abi_filters):
            raise VerificationError("invalid_apk_filters")
        outputs.append((path, abi_filters or selected_abis))
    return outputs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, help="Require the staged native bundle to match current Rust sources.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--apk", type=Path)
    source.add_argument("--apk-dir", type=Path)
    parser.add_argument("--abi", action="append", help="Intended ABI filter; repeat for universal APKs.")
    args = parser.parse_args(argv)
    try:
        manifest_data = args.manifest.read_bytes()
        if args.source_root:
            verify_source(manifest_data, args.source_root)
        outputs = packaged_outputs(args.apk_dir, args.abi) if args.apk_dir else [(args.apk, args.abi)]
        for apk, abis in outputs:
            for abi, library, digest in verify_apk(apk, manifest_data, abis):
                print(f"PASS {apk.name} {abi}/{library} {digest}")
        print("PASS phone_engine_packaging")
        return 0
    except (VerificationError, OSError, zipfile.BadZipFile, KeyError, TypeError, AttributeError,
            json.JSONDecodeError, UnicodeDecodeError) as error:
        code = str(error) if isinstance(error, VerificationError) else "invalid_bundle_input"
        print("FAIL phone_engine_packaging " + code, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
