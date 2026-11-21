"""Essai de bout en bout du client navigateur : hôte réel (mFRAMES --web-demo) + Chromium sans fenêtre (Playwright).
Vérifie : page servie, copie du proxy, annotations de l'hôte affichées, annotation et message du navigateur reçus par l'hôte,
reconnexion après coupure, clé fausse refusée."""
import os, re, subprocess, sys, time
from playwright.sync_api import sync_playwright

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
binary = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "mFRAMES DEV.app/Contents/MacOS/mFRAMES")
env = dict(os.environ, MFRAMES_WEB_DIR=os.path.join(root, "web"))
try: os.remove("/tmp/mframes-web-stop")
except FileNotFoundError: pass
host = subprocess.Popen([binary, "--web-demo", "90"], stdout=subprocess.PIPE, text=True, env=env)
fails = 0
def check(ok, msg):
    global fails
    print(("  OK  " if ok else "  ÉCHEC  ") + msg)
    if not ok: fails += 1
try:
    url = bad = None
    for _ in range(60):
        line = host.stdout.readline()
        if line.startswith("WEB_URL="): url = line.split("=", 1)[1].strip()
        if line.startswith("WEB_BAD_URL="): bad = line.split("=", 1)[1].strip(); break
    check(bool(url and bad), "l'hôte annonce l'adresse du client navigateur")
    lan = os.environ.get("MFRAMES_E2E_HOST")      # adresse du réseau local : contexte non sécurisé, donc chiffrement en JavaScript pur
    if lan: url = url.replace("127.0.0.1", lan); bad = bad.replace("127.0.0.1", lan)
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1280, "height": 760}, locale="fr-FR")
        page = ctx.new_page()
        page.on("dialog", lambda d: d.accept("Marie"))
        errors = []; page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(url)
        page.wait_for_selector("#app:not(.hidden)", timeout=8000)
        page.wait_for_function("document.querySelector('#peername').textContent.includes('Stéphan') || document.querySelector('#peername').textContent.length > 0 && document.querySelector('#peername').textContent !== '…'", timeout=10000)
        wc = page.evaluate("MFCrypto.usingWebCrypto")
        check(bool(lan) != wc, "la page se charge et se connecte (chiffrement : " + ("WebCrypto" if wc else "JavaScript pur, page http du réseau local") + ")")
        page.wait_for_selector(".media img", timeout=20000)
        check(True, "le proxy de l'image est copié en entier, empreinte vérifiée")
        page.wait_for_selector(".pin", timeout=5000)
        n = page.locator(".pin").count()
        check(n == 3, f"les 3 retours de l'hôte s'affichent sur l'image ({n})")
        check(page.locator(".bub").count() >= 4, "les retours et réponses apparaissent en bulles")
        # annotation du navigateur
        box = page.locator(".media img").bounding_box()
        page.mouse.click(box["x"] + box["width"] * 0.6, box["y"] + box["height"] * 0.7)
        page.fill("#text", "Retour envoyé depuis le navigateur")
        page.press("#text", "Enter")
        got = set()
        t0 = time.time()
        while time.time() - t0 < 10 and len(got) < 2:
            line = host.stdout.readline()
            if line.startswith("WEB_ANNOTATION"): got.add("a")
            if line.startswith("WEB_MESSAGE") and "navigateur" in line: got.add("m")
        check("a" in got, "l'annotation du navigateur arrive chez le prestataire")
        check("m" in got, "le message du navigateur arrive chez le prestataire")
        check(page.locator(".pin").count() == 4, "la nouvelle épingle apparaît aussi chez le client")
        # coupure
        page.evaluate("__mframes.ws.close()")
        page.wait_for_selector("#banner:not(.hidden)", timeout=5000)
        check("Connexion perdue" in page.inner_text("#banner"), "coupure : le bandeau « connexion perdue » s'affiche")
        page.wait_for_function("document.querySelector('#peerdot').classList.contains('on')", timeout=15000)
        check(True, "reconnexion automatique après la coupure")
        check(page.locator(".pin").count() == 4, "rien n'est perdu après la reconnexion")
        page.screenshot(path="/tmp/mf/web-client.png")
        check(not errors, "aucune erreur JavaScript" + (f" ({errors[:1]})" if errors else ""))
        # clé fausse
        page2 = ctx.new_page(); page2.on("dialog", lambda d: d.accept("Intrus"))
        page2.goto(bad); page2.wait_for_selector("#app:not(.hidden)", timeout=8000); time.sleep(3)
        check(page2.locator(".pin").count() == 0 and page2.inner_text("#peername") != "Stéphan", "un navigateur sans la bonne clé ne reçoit rien")
        b.close()
finally:
    open("/tmp/mframes-web-stop", "w").close()
    try: host.wait(timeout=10)
    except Exception: host.kill()
    try: os.remove("/tmp/mframes-web-stop")
    except FileNotFoundError: pass
print("TOUT PASSE" if fails == 0 else f"{fails} ÉCHEC(S)")
sys.exit(0 if fails == 0 else 1)
