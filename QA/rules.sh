#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/rules QA/audio
swiftc -module-cache-path "$PWD/.build/rules/module-cache" App/UnderIce.swift QA/Rules.swift -o .build/rules/validate
.build/rules/validate App/Resources/Campaign.json QA/audio | tee QA/rules.log
python3 - <<'PY'
from pathlib import Path
import wave
root = Path("QA/audio")
with wave.open(str(root / "receiver-comparison.wav"), "wb") as output:
    output.setparams((1, 2, 22050, 0, "NONE", "not compressed"))
    for name in ["01-hole-A", "02-hole-B", "03-third-voice"]:
        with wave.open(str(root / (name + ".wav")), "rb") as motif:
            data = motif.readframes(motif.getnframes())
        output.writeframes(data * 2)
        output.writeframes(b"\0" * 22050)
PY
