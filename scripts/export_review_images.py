import json
from pathlib import Path
import shutil

root = Path("build/ui-attachments")
destination = Path("build/ui-review")
destination.mkdir(parents=True, exist_ok=True)


def visit(value, folder):
    if isinstance(value, dict):
        name = value.get("suggestedHumanReadableName", value.get("name", ""))
        filename = value.get("exportedFileName", value.get("fileName", ""))
        if "review-" in str(name) and filename:
            source = folder / Path(filename).name
            if source.exists():
                target = str(name).split("review-", 1)[1].replace("/", "-")
                shutil.copyfile(source, destination / ("review-" + target + source.suffix))
        for child in value.values():
            visit(child, folder)
    elif isinstance(value, list):
        for child in value:
            visit(child, folder)


for manifest in root.rglob("*.json"):
    visit(json.loads(manifest.read_text()), manifest.parent)
for crash in root.rglob("*.ips"):
    shutil.copyfile(crash, destination / crash.name)
print("Review screenshots:", [path.name for path in destination.iterdir()])

