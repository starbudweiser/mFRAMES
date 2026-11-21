"""Client du pont local mFRAMES (API /v1) pour les scripts DaVinci Resolve. Bibliothèque standard seulement."""
import json, os, urllib.request, urllib.error

SUPPORT = os.path.expanduser("~/Library/Application Support")
API_VERSION = 1


def _info():
    override = os.environ.get("MFRAMES_BRIDGE_JSON")        # essais : fichier bridge.json à utiliser
    if override and os.path.exists(override):
        with open(override) as f:
            return json.load(f)
    for name in ("mFRAMES", "mFRAMES DEV"):
        path = os.path.join(SUPPORT, name, "bridge.json")
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
    raise RuntimeError("mFRAMES : pont local introuvable. Ouvrez mFRAMES, puis Réglages › Intégrations › activer le pont local.")


def request(method, path, body=None):
    info = _info()
    req = urllib.request.Request(f"http://127.0.0.1:{info['port']}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {info['token']}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read().decode()
            return json.loads(raw) if r.headers.get("Content-Type", "").startswith("application/json") else raw
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"mFRAMES : {e.code} {e.read().decode()}")


def projects():
    return request("GET", "/v1/projects")


def annotations(version_id, since=0):
    return request("GET", f"/v1/annotations?versionID={version_id}&since={since}")


def set_status(annotation_id, status):
    return request("POST", f"/v1/annotations/{annotation_id}/status", {"status": status})


def add_version(project_id, path):
    return request("POST", f"/v1/projects/{project_id}/versions", {"path": path})


def current():
    """Le projet et la version ouverts dans mFRAMES."""
    try:
        return request("GET", "/v1/current")
    except RuntimeError:
        return None


def find_project(name_hint):
    """Le projet mFRAMES dont le nom ressemble à celui de la timeline ou du projet Resolve ; sinon celui qui est ouvert dans mFRAMES."""
    ps = projects()
    hint = (name_hint or "").lower()
    for p in ps:
        if hint and (p["name"].lower() in hint or hint in p["name"].lower()):
            return p
    cur = current()
    if cur:
        for p in ps:
            if p["id"] == cur["projectID"]:
                return p
    return ps[-1] if ps else None
