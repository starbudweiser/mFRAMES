#!/usr/bin/env python3
"""DaVinci Resolve : importe les retours du client comme marqueurs de la timeline courante (rouge : ouvert, vert : résolu),
et répercute dans mFRAMES les marqueurs que vous avez passés en vert. À lancer par Espace de travail › Scripts.

Installation : copier ce dossier (avec mframes_bridge.py) dans
  ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mframes_bridge as mf

try:
    resolve  # fourni par Resolve quand le script est lancé depuis son menu
except NameError:
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")

project = resolve.GetProjectManager().GetCurrentProject()
timeline = project.GetCurrentTimeline()
if timeline is None:
    raise SystemExit("mFRAMES : ouvrez une timeline.")
fps = float(timeline.GetSetting("timelineFrameRate"))
start = timeline.GetStartFrame()
p = mf.find_project(timeline.GetName() or project.GetName())
if not p:
    raise SystemExit("mFRAMES : aucun projet.")
version = max(p["versions"], key=lambda v: v["number"])
existing = timeline.GetMarkers() or {}
by_id = {m.get("customData", ""): (frame, m) for frame, m in existing.items() if str(m.get("customData", "")).startswith("mframes:")}

added = updated = synced = 0
for a in mf.annotations(version["id"]):
    key = "mframes:" + a["id"]
    color = "Green" if a["status"] == "resolved" else "Red"
    note = " | ".join([a["text"]] + [f'[{r["author"]}] {r["text"]}' for r in a["replies"]])
    if key in by_id:
        frame, m = by_id[key]
        if m["color"] == "Green" and a["status"] == "open":      # passé en vert dans Resolve : on répercute dans mFRAMES
            mf.set_status(a["id"], "resolved"); synced += 1
        elif m["color"] != color:
            timeline.DeleteMarkerAtFrame(frame)
            timeline.AddMarker(frame, color, f'#{a["author"]}', note, 1, key); updated += 1
        continue
    frame = int(round((a["time"] or 0) * fps))
    if timeline.AddMarker(frame, color, a["author"], note, 1, key):
        added += 1
print(f"mFRAMES : {added} marqueur(s) ajouté(s), {updated} mis à jour, {synced} statut(s) renvoyé(s) à mFRAMES (version {version['number']}).")
