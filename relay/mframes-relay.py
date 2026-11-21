#!/usr/bin/env python3
"""mframes-relay : point de rencontre et relais aveugle de mFRAMES (à héberger soi-même : NAS, VPS, Docker).

Il met en relation un prestataire (hôte) et son client lorsque leurs réseaux interdisent la connexion directe (CGNAT, pare-feu).
Il ne voit passer que des trames chiffrées de bout en bout (AES-GCM) : ni média, ni texte, ni clé. Il ne stocke rien et ne journalise ni adresses ni contenu.

Protocole (texte, une ligne, puis octets relayés tels quels) :
  hôte   → « HOST <salle> » ; reste en attente ; reçoit « GO » quand un client arrive, puis la liaison devient transparente
  client → « JOIN <salle> » ; reçoit « OK » (ou « NOHOST »), puis la liaison devient transparente
La salle est une empreinte dérivée du secret d'invitation, jamais le secret lui-même.

Usage : python3 mframes-relay.py [--host 0.0.0.0] [--port 7766]
"""
import argparse, asyncio, collections, re, sys

SALLE = re.compile(rb"^[0-9a-f]{16,64}$")
MAX_SALLES, MAX_ATTENTE_PAR_SALLE, MAX_LIAISONS = 1000, 8, 500
salles = collections.defaultdict(collections.deque)   # salle -> hôtes en attente
liaisons = 0

async def pont(src, dst):
    try:
        while data := await src.read(65536):
            dst.write(data); await dst.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try: dst.close()
        except Exception: pass

async def client(reader, writer):
    global liaisons
    try:
        ligne = await asyncio.wait_for(reader.readline(), 10)
    except Exception:
        writer.close(); return
    parts = ligne.strip().split(b" ")
    if len(parts) != 2 or parts[0] not in (b"HOST", b"JOIN") or not SALLE.match(parts[1]):
        writer.close(); return
    cmd, salle = parts
    if cmd == b"HOST":
        file = salles[salle]
        if len(salles) > MAX_SALLES or len(file) >= MAX_ATTENTE_PAR_SALLE:
            writer.close(); return
        entree = {"r": reader, "w": writer}
        entree["veille"] = asyncio.ensure_future(reader.read(1))   # détecte la fermeture de l'hôte en attente
        file.append(entree)
        await asyncio.wait([entree["veille"]])                      # se réveille si l'hôte part ou quand un client le prend
        if entree in file:
            file.remove(entree)
            if not file: salles.pop(salle, None)
            writer.close()
        return
    # JOIN
    file = salles.get(salle)
    hote = None
    while file:
        e = file.popleft()
        if not e["w"].is_closing() and not e["veille"].done():
            hote = e; break
    if file is not None and not file: salles.pop(salle, None)
    if hote is None or liaisons >= MAX_LIAISONS:
        writer.write(b"NOHOST\n"); await writer.drain(); writer.close(); return
    hote["veille"].cancel()
    try:
        await hote["veille"]
    except BaseException:
        pass
    liaisons += 1
    try:
        writer.write(b"OK\n"); hote["w"].write(b"GO\n")
        await asyncio.gather(writer.drain(), hote["w"].drain())
        await asyncio.gather(pont(reader, hote["w"]), pont(hote["r"], writer))
    except Exception:
        pass
    finally:
        liaisons -= 1
        for w in (writer, hote["w"]):
            try: w.close()
            except Exception: pass

async def main(host, port):
    srv = await asyncio.start_server(client, host, port, limit=1 << 16)
    print(f"mframes-relay en écoute sur {host}:{srv.sockets[0].getsockname()[1]}", flush=True)
    async with srv:
        await srv.serve_forever()

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Relais aveugle mFRAMES")
    ap.add_argument("--host", default="0.0.0.0"); ap.add_argument("--port", type=int, default=7766)
    a = ap.parse_args()
    try: asyncio.run(main(a.host, a.port))
    except KeyboardInterrupt: sys.exit(0)
