#!/usr/bin/env python3
"""Génère mFRAMES_Presentation.pdf (16:9) à partir des captures du dossier. Usage : python3 build_pdf.py"""
import fitz
W, H = 1280, 720
BG, CARD, TXT, DIM, ACC, GRN, RED = "#0f1115", "#1b1e24", "#f2f4f8", "#9aa3b2", "#2f7bff", "#34c759", "#ff6b5e"
doc = fitz.open()
def rgb(h): return tuple(int(h[i:i+2], 16) / 255 for i in (1, 3, 5))
CSS = f"""* {{ font-family: sans-serif; }} body {{ color:{TXT}; }} h1 {{ font-size:46px; margin:0 0 10px 0; }} h2 {{ font-size:34px; margin:0 0 14px 0; }}
p {{ font-size:19px; color:{DIM}; margin:0 0 10px 0; }} li {{ font-size:20px; margin:0 0 12px 0; color:{TXT}; }} b {{ color:{TXT}; }} .a {{ color:{ACC}; }} .k {{ font-size:15px; color:{ACC}; letter-spacing:2px; }}
td, th {{ font-size:17px; padding:9px 12px; }} th {{ color:{DIM}; text-align:left; }} .y {{ color:{GRN}; }} .n {{ color:{RED}; }}"""
def page():
    p = doc.new_page(width=W, height=H); p.draw_rect(p.rect, fill=rgb(BG), color=None); return p
def html(p, rect, body): p.insert_htmlbox(fitz.Rect(*rect), body, css=CSS)
def shot(p, rect, img):
    r = fitz.Rect(*rect); pm = fitz.Pixmap(img); ar = pm.width / pm.height
    w = r.width; h = w / ar
    if h > r.height: h = r.height; w = h * ar
    t = fitz.Rect(r.x0, r.y0, r.x0 + w, r.y0 + h)
    p.draw_rect(t + (-4, -4, 4, 4), fill=rgb(CARD), color=None, radius=0.02)
    p.insert_image(t, filename=img)
def foot(p, n): p.insert_text((60, H - 24), "mFRAMES  ·  DESKTOP MAC TOOLKIT", fontsize=11, color=rgb(DIM)); p.insert_text((W - 90, H - 24), f"{n} / 8", fontsize=11, color=rgb(DIM))

# 1 couverture
p = page(); html(p, (60, 70, 560, 330), f"<p class='k'>REVIEW ET ANNOTATION EN DIRECT</p><h1 style='font-size:84px'><span class='a'>m</span>FRAMES</h1><p style='font-size:24px'>Faites relire vos vidéos, images, PDF et maquettes par vos clients, et par votre IA, image par image.</p>")
html(p, (60, 440, 520, 640), "<p>Application macOS native · réseau direct ou relais auto-hébergé · aucun hébergement imposé</p>")
shot(p, (610, 150, 1240, 560), "cap-sombre.png"); foot(p, 1)

# 2 principe
p = page(); html(p, (60, 50, 1220, 200), "<p class='k'>LE PRINCIPE</p><h2>Une session de review en direct, pas un dépôt de fichiers</h2>")
cards = [("Vous invitez", "Un lien ou un QR code. Le client rejoint depuis l'appli ou depuis un navigateur, sans compte à créer."), ("Il annote en direct", "Épingles et zones posées sur l'image exacte. Vous voyez ses retours arriver pendant qu'il les écrit."), ("Vous traitez", "Répondre, marquer résolu, exporter vers votre logiciel de montage. Chaque version garde son historique.")]
for i, (t, d) in enumerate(cards):
    x = 60 + i * 395; p.draw_rect(fitz.Rect(x, 230, x + 370, 560), fill=rgb(CARD), color=None, radius=0.05)
    html(p, (x + 22, 250, x + 350, 550), f"<p class='k'>0{i+1}</p><h2 style='font-size:28px'>{t}</h2><p>{d}</p>")
html(p, (60, 590, 1220, 680), "<p>Les fichiers ne transitent par aucun service tiers : la connexion est directe entre les deux postes, ou passe par un relais que vous hébergez vous-même.</p>"); foot(p, 2)

# 3 précision
p = page(); html(p, (60, 50, 600, 330), "<p class='k'>VIDÉO</p><h2>La précision de l'image exacte</h2><ul><li>Épingle liée à <b>l'image précise</b> : elle n'apparaît que sur cette image</li><li>Avance <b>image par image</b> au clavier, barre espace pour lire / pauser</li><li>Un clic sur un retour saute à son instant</li><li>Vitesse, boucle, marqueurs sur la barre de lecture</li><li>Décodage matériel du Mac, lecture réactive</li></ul>")
shot(p, (620, 120, 1240, 560), "cap-video.png"); foot(p, 3)

# 4 formats
p = page(); html(p, (60, 50, 540, 450), "<p class='k'>TOUS VOS FORMATS</p><h2>Un seul outil pour tout ce que vous livrez</h2><ul><li><b>Vidéo</b> avec épingles datées</li><li><b>Photo</b> et visuels, zones et épingles</li><li><b>PDF</b> et mises en page, page par page</li><li><b>Maquettes PSD / AI</b></li><li>Versions rangées sous chaque projet, clients regroupés</li></ul><p>Thème clair, sombre ou automatique.</p>")
shot(p, (570, 90, 1240, 520), "cap-clair.png"); foot(p, 4)

# 5 voix + IA
p = page(); html(p, (60, 50, 620, 400), "<p class='k'>RÉACTIF</p><h2>Commentez à la voix</h2><ul><li>Bouton micro : la dictée s'écrit dans le commentaire, <b>sur votre Mac</b></li><li>Choix de la source du micro d'un clic</li><li>Un commentaire sans épingle en crée une <b>à la tête de lecture</b></li><li>Clic droit pour supprimer un commentaire et son épingle</li></ul>")
html(p, (60, 420, 620, 690), f"<p class='k'>POUR VOS AGENTS IA</p><h2 style='font-size:28px'>Le prestataire peut être une IA</h2><p>Un serveur MCP intégré permet à Claude ou à tout agent de publier un média, de lire vos retours horodatés, de répondre et de marquer résolu, puis de recevoir votre « Envoyer ».</p>")
shot(p, (660, 90, 1240, 560), "cap-sombre.png"); foot(p, 5)

# 6 intégrations
p = page(); html(p, (60, 50, 600, 460), "<p class='k'>DANS VOTRE FLUX</p><h2>Du retour client au montage</h2><ul><li>Pont local sécurisé (127.0.0.1, jeton) et modules pour <b>Premiere Pro, After Effects, Final Cut Pro, DaVinci Resolve</b></li><li>Retours importés comme marqueurs, résolus depuis le logiciel, retour au timecode</li><li>Sans module : export FCPXML, EDL / CSV, XML Premiere, JSON After Effects</li><li>Invitation par lien, QR code ou navigateur</li></ul>")
shot(p, (630, 100, 1240, 540), "cap-invite.png"); foot(p, 6)

# 7 comparatif
p = page(); html(p, (60, 40, 1220, 130), "<p class='k'>POURQUOI mFRAMES</p><h2>Face aux outils de review en ligne</h2>")
rows = [("", "Outils de review cloud (type Frame.io, Vimeo Review…)", "mFRAMES"),
 ("Où vont vos fichiers", "Téléversés sur le service", "Restent chez vous : connexion directe ou relais auto-hébergé"),
 ("Précision", "Commentaire au timecode", "Épingle visible sur l'image exacte, avance image par image"),
 ("Attente", "Envoi puis traitement avant la relecture", "Aucun téléversement : on relit tout de suite"),
 ("Saisie", "Clavier", "Dictée vocale sur l'appareil"),
 ("Agents IA", "Selon l'outil", "MCP intégré : publier, lire, répondre, résoudre"),
 ("Montage", "Modules selon l'outil", "Pont local + Premiere, AE, FCP, Resolve, export de marqueurs"),
 ("Formats", "Surtout vidéo", "Vidéo, photo, PDF, PSD / AI"),
 ("Distribution", "Compte et abonnement du service", "Appli native, protocole ouvert et documenté, 4 langues, mise à jour automatique")]
t = "<table width='1160'><tr>" + "".join(f"<th>{c}</th>" for c in rows[0]) + "</tr>" + "".join(f"<tr><th>{r[0]}</th><td>{r[1]}</td><td class='y'><b>{r[2]}</b></td></tr>" for r in rows[1:]) + "</table>"
html(p, (60, 130, 1220, 650), t)
html(p, (60, 655, 1220, 700), "<p style='font-size:12px'>Comparaison par catégories d'outils, sur les fonctions de relecture ; les offres des services cloud varient, à vérifier produit par produit.</p>"); foot(p, 7)

# 8 distribution
p = page(); html(p, (60, 60, 1220, 330), "<p class='k'>CONÇU POUR ÊTRE DIFFUSÉ</p><h2>Rien de codé en dur, tout se règle</h2><ul><li>Point de rencontre, serveurs STUN / TURN, ports, proxy : modes « réseau local seulement » ou « relais seulement »</li><li>Relais : un petit exécutable ou conteneur que chacun peut héberger</li><li>Protocole de session ouvert et versionné : base d'un client web, d'une app cliente, d'un futur portage Windows</li><li>Français, anglais, espagnol, italien, selon la langue du Mac</li><li>Notarisée par Apple, mise à jour automatique</li></ul>")
html(p, (60, 460, 1220, 600), "<h1 style='font-size:64px'><span class='a'>m</span>FRAMES</h1><p>Review et annotation en direct avec vos clients.</p>"); foot(p, 8)
doc.save("mFRAMES_Presentation.pdf"); print("OK", len(doc), "pages")
