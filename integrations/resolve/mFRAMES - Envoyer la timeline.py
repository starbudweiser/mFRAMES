#!/usr/bin/env python3
"""DaVinci Resolve : rend la timeline courante en H.264 720p et l'envoie à mFRAMES comme nouvelle version du projet.
À lancer par Espace de travail › Scripts (même installation que l'import des retours)."""
import os, sys, time, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mframes_bridge as mf

try:
    resolve
except NameError:
    import DaVinciResolveScript as dvr
    resolve = dvr.scriptapp("Resolve")

project = resolve.GetProjectManager().GetCurrentProject()
timeline = project.GetCurrentTimeline()
if timeline is None:
    raise SystemExit("mFRAMES : ouvrez une timeline.")
p = mf.find_project(timeline.GetName() or project.GetName())
if not p:
    raise SystemExit("mFRAMES : aucun projet.")
out = tempfile.mkdtemp(prefix="mframes-")
name = f'{p["name"]}-V{max(v["number"] for v in p["versions"]) + 1}'
project.SetCurrentRenderFormatAndCodec("mp4", "H264")
project.SetRenderSettings({"SelectAllFrames": True, "TargetDir": out, "CustomName": name, "FormatWidth": 1280, "FormatHeight": 720})
job = project.AddRenderJob()
project.StartRendering(job)
while project.IsRenderingInProgress():
    time.sleep(1)
path = os.path.join(out, name + ".mp4")
if not os.path.exists(path):
    raise SystemExit("mFRAMES : le rendu n'a pas produit de fichier.")
v = mf.add_version(p["id"], path)
print(f'mFRAMES : version {v["number"]} envoyée au projet « {p["name"]} ».')
