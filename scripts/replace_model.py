#!/usr/bin/env python3
"""Puts a model folder into the package: Sources/Gapiring/Model, the files the engine reads, under their own names.

    python3 scripts/replace_model.py gapiring-edge-v2-model.zip [--sha256 HEX]
    python3 scripts/replace_model.py path/to/Model

A zip (with a Model/ folder inside) or a folder. Every file it carries replaces the package's file of the same name, so
a new take of the graphs alone is one step too; files it does not carry stay. Prints each file's SHA-256 and the
tokens_per_second_estimate of bundle.json (1.5 for Edge v2: lower values cut slowly spoken lines short). Then run
`swift test`.
"""
import hashlib
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "Sources" / "Gapiring" / "Model"
FILES = ["bundle.json", "tokenizer.json", "init_states.onnx", "text_conditioner_int8.onnx", "flow_lm_main_int8.onnx",
         "flow_lm_flow_int8.onnx", "mimi_decoder_int8.onnx", "voices/f1.bin", "voices/m1.bin"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    args = sys.argv[1:]
    want = None
    if "--sha256" in args:
        i = args.index("--sha256")
        want = args[i + 1].lower()
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    source = Path(args[0])
    with tempfile.TemporaryDirectory() as t:
        if source.is_file():
            if want and sha256(source) != want:
                sys.exit(f"{source.name}: SHA-256 is {sha256(source)}, not {want}")
            with zipfile.ZipFile(source) as z:
                for name in z.namelist():
                    if name.startswith("/") or ".." in Path(name).parts:
                        sys.exit(f"{source.name}: unsafe path {name}")
                z.extractall(t)
            folder = Path(t) / "Model"
        else:
            folder = source
        found = [f for f in FILES if (folder / f).is_file()]
        if not found:
            sys.exit(f"{folder}: none of {', '.join(FILES)}")
        for f in found:
            (MODEL / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(folder / f, MODEL / f)
            print(f"  {sha256(MODEL / f)}  {f}")
    estimate = json.loads((MODEL / "bundle.json").read_text())["tokens_per_second_estimate"]
    print(f"replaced {len(found)} of {len(FILES)} files in {MODEL.relative_to(ROOT)}; tokens_per_second_estimate = {estimate}")


if __name__ == "__main__":
    main()
