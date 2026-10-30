#!/usr/bin/env python3
"""A Slashlight extension in plain Python: type `/uuid` to generate UUIDs.

Speaks the JSON-lines protocol from docs/extension-protocol.md on stdin/stdout. No dependencies.
"""
import json
import subprocess
import sys
import uuid


def reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def search(query):
    count = int(query) if query.isdigit() and 0 < int(query) <= 20 else 3
    items = []
    for i in range(count):
        value = str(uuid.uuid4())
        items.append({
            "id": value,
            "title": value,
            "subtitle": "↵ copy · ⌘↵ paste",
            "icon": "sf:number",
            "actions": [{"id": "copy", "title": "Copy"}, {"id": "paste", "title": "Paste"}],
        })
    return [{"title": "UUIDs", "items": items}]


for line in sys.stdin:
    request = json.loads(line)
    kind, rid = request["type"], request.get("id")
    if kind == "hello":
        reply({"type": "hello", "id": rid, "version": 2})
    elif kind == "search":
        reply({"type": "results", "id": rid, "sections": search(request.get("query", "").strip())})
    elif kind == "run":
        # Item ids are the UUIDs themselves, so there is nothing to look up.
        outcome = "paste" if request["actionId"] == "paste" else "hud"
        value = request["itemId"] if outcome == "paste" else f"Copied {request['itemId'][:8]}…"
        if outcome == "hud":
            subprocess.run(["pbcopy"], input=request["itemId"].encode())
        reply({"type": "outcome", "id": rid, "outcome": {"type": outcome, "value": value}})
    elif kind == "shutdown":
        break
    # Unknown types (dispose, future additions) are ignored.
