import json
import shutil
import subprocess
import sys
from pathlib import Path

evidence = Path(sys.argv[1])
derived = Path(sys.argv[2])
attachments = evidence / "attachments"
screens = evidence / "screens"
screens.mkdir(exist_ok=True)
markers = {}
for case in json.loads((attachments / "manifest.json").read_text()):
    for attachment in case["attachments"]:
        name = attachment["suggestedHumanReadableName"]
        if not attachment["isAssociatedWithFailure"] and name.endswith(".png"):
            name = name.split("_0_")[0]
            source = attachments / attachment["exportedFileName"]
            shutil.copyfile(source, screens / (name + ".png"))
            markers[name] = attachment["timestamp"]

recording = derived / "screen.mov"
if recording.exists() and "first-clean" in markers and "first-filed" in markers:
    origin = float((derived / "recording-start.txt").read_text())
    for name, first, last, lead in [
        ("first-expedition", "first-clean", "first-filed", 0.75),
        ("muted-expedition", "muted-comparison", "muted-filed", 3.5),
    ]:
        if first not in markers or last not in markers:
            continue
        start = max(0, markers[first] - origin - lead)
        duration = markers[last] - origin - start + 1
        subprocess.run([
            "avconvert", "--source", str(recording), "--preset", "PresetAppleM4V1080pHD",
            "--start", f"{start:.3f}", "--duration", f"{duration:.3f}",
            "--output", str(evidence / (name + ".m4v")), "--replace",
        ], check=True)
