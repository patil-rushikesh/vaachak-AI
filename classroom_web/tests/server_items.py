import json
from pathlib import Path


def items_of(set_id):
    cat = json.loads((Path(__file__).resolve().parent.parent / "server" / "data" / "catalog.json").read_text(encoding="utf-8"))
    for lang in cat["languages"]:
        for s in lang["sets"]:
            if s["id"] == set_id:
                return [i["text"] for i in s["items"]]
