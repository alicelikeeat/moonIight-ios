import json
from pathlib import Path
import shutil

root = Path("build/ui-attachments")
destination = Path("build/ui-review")
destination.mkdir(parents=True, exist_ok=True)


def visit(value):
    if isinstance(value, dict):
        name = value.get("suggestedHumanReadableName", value.get("name", ""))
        filename = value.get("exportedFileName", value.get("fileName", ""))
        if "review-" in str(name) and filename:
            source = root / Path(filename).name
            if source.exists():
                target = str(name).split("review-", 1)[1].replace("/", "-")
                shutil.copyfile(source, destination / ("review-" + target + source.suffix))
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)


for manifest in root.glob("*.json"):
    visit(json.loads(manifest.read_text()))
print("Review screenshots:", [path.name for path in destination.iterdir()])
