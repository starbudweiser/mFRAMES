#!/usr/bin/env python3
"""mFRAMES marketing brochure, English edition (A4 landscape, 6 pages) -> mFRAMES_Brochure_EN.pdf. Usage : python3 -W ignore build_plaquette.py"""
import fitz, os
from PIL import Image, ImageDraw, ImageFilter
W, H = 1191, 842
TEAL, TEAL2, ORG, INK, DIM, CREAM, CARD = "#27b39a", "#0f7f70", "#ff9a1a", "#12302c", "#5b6f6b", "#f4f8f6", "#ffffff"
here = os.path.dirname(os.path.abspath(__file__)); os.chdir(here)
arch = fitz.Archive("fonts")
def rgb(h): return tuple(int(h[i:i+2], 16) / 255 for i in (1, 3, 5))
CSS = f"""@font-face {{ font-family: R; src: url(Rounded.ttf); }} @font-face {{ font-family: B; src: url(Body.ttf); }} @font-face {{ font-family: B; font-weight: bold; src: url(BodyBold.ttf); }}
body {{ font-family: B; color:{INK}; }} h1,h2,h3,.r {{ font-family: R; font-weight: normal; margin:0; }} h1 {{ font-size:66px; line-height:1.05; }} h2 {{ font-size:40px; line-height:1.1; margin-bottom:12px; }} h3 {{ font-size:22px; margin-bottom:6px; }}
p {{ font-size:16px; line-height:1.45; color:{DIM}; margin:0 0 8px 0; }} .k {{ font-family:R; font-size:13px; letter-spacing:3px; color:{TEAL2}; margin-bottom:10px; }} .w {{ color:#fff; }} .w p {{ color:#d9f5ef; }} .o {{ color:{ORG}; }} .t {{ color:{TEAL}; }}"""
doc = fitz.open()
def html(p, r, body, extra=""): p.insert_htmlbox(fitz.Rect(*r), body, css=CSS + extra, archive=arch)
def new(bg=CREAM):
    p = doc.new_page(width=W, height=H); p.draw_rect(p.rect, fill=rgb(bg), color=None); return p

def gradient(path, w, h, c1, c2):
    a, b = [tuple(int(c[i:i+2], 16) for i in (1, 3, 5)) for c in (c1, c2)]
    im = Image.new("RGB", (w, h)); px = im.load()
    for y in range(h):
        for x in range(w):
            t = (x / w * 0.45 + y / h * 0.55); px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    im.save(path)
def window(src, dst, radius=34, shadow=True, crop=None):
    im = Image.open(src).convert("RGBA")
    if crop: im = im.crop(crop)
    m = Image.new("L", im.size, 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, im.width - 1, im.height - 1), radius, fill=255); im.putalpha(m)
    pad = 60; out = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
    if shadow:
        sh = Image.new("RGBA", out.size, (0, 0, 0, 0)); ImageDraw.Draw(sh).rounded_rectangle((pad, pad + 18, pad + im.width, pad + im.height + 18), radius, fill=(10, 50, 45, 120))
        out.alpha_composite(sh.filter(ImageFilter.GaussianBlur(26)))
    out.alpha_composite(im, (pad, pad)); sz = out.size
    if out.width > 1700: out = out.resize((1700, round(out.height * 1700 / out.width)), Image.LANCZOS)
    out.save(dst, optimize=True); return sz, pad
def place(p, src, x, y, w, name):                      # x,y = coin du cadre visible ; w = largeur visible
    (ow, oh), pad = window(src, f"work/{name}.png")
    k = w / (ow - 2 * pad); rect = fitz.Rect(x - pad * k, y - pad * k, x - pad * k + ow * k, y - pad * k + oh * k)
    p.insert_image(rect, filename=f"work/{name}.png"); return (oh - 2 * pad) * k
def card(p, r, fill=CARD, radius=0.07): p.draw_rect(fitz.Rect(*r), fill=rgb(fill), color=None, radius=radius)
def check(p, cx, cy, color=TEAL, s=1.0):
    p.draw_circle((cx, cy), 12 * s, fill=rgb(color), color=None)
    p.draw_polyline([(cx - 5.5 * s, cy + 0.5 * s), (cx - 1.5 * s, cy + 4.5 * s), (cx + 6 * s, cy - 4.5 * s)], color=rgb("#ffffff"), width=2.6 * s, closePath=False)
def cross(p, cx, cy):
    p.draw_circle((cx, cy), 12, fill=rgb("#e3e9e7"), color=None)
    p.draw_line((cx - 4.5, cy - 4.5), (cx + 4.5, cy + 4.5), color=rgb("#8a9b97"), width=2.4); p.draw_line((cx - 4.5, cy + 4.5), (cx + 4.5, cy - 4.5), color=rgb("#8a9b97"), width=2.4)
def brand(p, x, y, size=30, color=INK, m=TEAL):
    html(p, (x, y, x + 300, y + size * 1.6), f"<div class='r' style='font-size:{size}px;color:{color}'><span style='color:{m}'>m</span>FRAMES</div>")
def foot(p, n, dark=False):
    c = "#d9f5ef" if dark else DIM
    html(p, (60, H - 40, 700, H - 14), f"<p style='font-size:11px;color:{c}'>mFRAMES · DESKTOP MAC TOOLKIT · Live review and annotation</p>")
    html(p, (W - 120, H - 40, W - 60, H - 14), f"<p style='font-size:11px;color:{c};text-align:right'>{n} / 6</p>")

gradient("work/g1.png", 300, 210, TEAL, TEAL2); gradient("work/g2.png", 300, 210, "#143d38", "#0a1f1c")

# 1 — couverture
p = new(); p.insert_image(p.rect, filename="work/g1.png")
p.draw_circle((1000, 120), 260, fill=(1, 0.6, 0.1), color=None, fill_opacity=0.16); p.draw_circle((130, 760), 220, fill=(1, 1, 1), color=None, fill_opacity=0.08)
p.insert_image(fitz.Rect(60, 56, 124, 120), filename="icon.png")
html(p, (60, 150, 560, 480), "<div class='w'><p style='font-family:R;letter-spacing:3px;font-size:14px;color:#d9f5ef'>LIVE REVIEW AND ANNOTATION</p><h1 style='font-size:92px'><span class='o'>m</span>FRAMES</h1><p style='font-size:26px;line-height:1.3;color:#fff;margin-top:14px'>Client feedback, <b>frame by frame</b>. Nothing to upload.</p></div>")
html(p, (60, 540, 440, 760), "<div class='w'><p>Video, photo, PDF, PSD / AI mockups.<br>For you, your clients and your AI.</p><p style='margin-top:18px;font-family:R;font-size:15px;color:#fff'>Native macOS app</p></div>")
place(p, "en_cap-sombre.png", 470, 440, 820, "c1"); foot(p, 1, True)

# 2 — principe
p = new(); brand(p, 60, 44, 22)
html(p, (60, 100, 760, 270), "<div class='k'>HOW IT WORKS</div><h2>Review live.<br><span class='t'>No file ever leaves your Mac.</span></h2>")
steps = [("1", "You invite", "A link, a QR code. Your client joins from the app or a browser, no account needed."), ("2", "They annotate", "Pins and zones placed on the exact frame, arriving on your screen live."), ("3", "You act", "Reply, mark as resolved, export to your editing software.")]
for i, (n, t, d) in enumerate(steps):
    y = 250 + i * 128; card(p, (60, y, 560, y + 112), radius=0.18); p.draw_circle((108, y + 56), 26, fill=rgb(TEAL), color=None)
    html(p, (82, y + 32, 134, y + 80), f"<div class='r w' style='font-size:28px;text-align:center'>{n}</div>")
    html(p, (150, y + 12, 548, y + 108), f"<h3>{t}</h3><p style='margin:0'>{d}</p>")
place(p, "en_cap-invite.png", 600, 260, 531, "c2")
html(p, (60, 650, 1100, 750), f"<p style='font-size:18px'>Direct connection between the two computers, or a relay you host yourself: no third-party service ever stores your media.</p>"); foot(p, 2)

# 3 — précision
p = new(); brand(p, 60, 44, 22)
html(p, (60, 100, 560, 300), "<div class='k'>VIDEO</div><h2>The precision of <span class='t'>the exact frame</span></h2><p style='font-size:18px'>A pin belongs to one frame, and only one. It disappears on the very next frame.</p>")
feats = ["Step frame by frame with the keyboard", "Space bar: instant play / pause", "Click a comment to jump to its moment", "Speed, loop and markers on the bar", "Hardware video decoding on your Mac"]
for i, f in enumerate(feats):
    y = 330 + i * 62; card(p, (60, y, 520, y + 50), radius=0.5); check(p, 90, y + 25); html(p, (112, y + 12, 510, y + 46), f"<p style='font-size:16px;color:{INK};margin:0'>{f}</p>")
place(p, "en_cap-video.png", 590, 120, 540, "c3")
for i, (big, small) in enumerate([("1 = 1", "pin = frame"), ("4", "media formats"), ("0", "files uploaded")]):
    x = 590 + i * 185; card(p, (x, 460, x + 170, 600), fill=TEAL if i == 0 else CARD)
    c = "#ffffff" if i == 0 else TEAL2
    html(p, (x + 10, 482, x + 160, 560), f"<div class='r' style='font-size:44px;text-align:center;color:{c}'>{big}</div>")
    html(p, (x + 10, 548, x + 160, 596), f"<p style='text-align:center;font-size:14px;color:{'#d9f5ef' if i == 0 else DIM}'>{small}</p>")
place(p, "en_cap-clair.png", 590, 640, 280, "c3b"); html(p, (890, 640, 1130, 760), "<p style='margin-top:6px'>Photos, PDF and PSD / AI: same pins and zones, light, dark or automatic theme.</p>"); foot(p, 3)

# 4 — voix + IA
p = new("#0a1f1c"); p.insert_image(fitz.Rect(0, 0, W, H), filename="work/g2.png")
p.draw_circle((1050, 150, ), 230, fill=(1, 0.6, 0.1), color=None, fill_opacity=0.10)
brand(p, 60, 44, 22, "#ffffff", ORG)
html(p, (60, 100, 640, 300), "<div class='w'><p style='font-family:R;letter-spacing:3px;font-size:13px;color:#7fe0cf'>RESPONSIVE</p><h2>Say it.<br><span class='o'>Your AI agent handles it.</span></h2></div>")
html(p, (60, 300, 560, 470), "<div class='w'><h3>Voice dictation</h3><p>One microphone button: your words are typed into the comment, processed on your Mac. Pick the microphone in one click. A comment without a pin creates one at the playhead.</p></div>")
html(p, (60, 480, 560, 640), "<div class='w'><h3>Your contractor can be an AI</h3><p>A built-in MCP server lets Claude or any agent publish a media file, read your time-stamped feedback, reply and mark it resolved.</p></div>")
flow = [("Publish", "the render"), ("Feedback", "time-stamped"), ("Reply", "frame-accurate"), ("Resolve", "then a new version")]
for i, (a, b) in enumerate(flow):
    y = 120 + i * 150; p.draw_rect(fitz.Rect(700, y, 1131, y + 120), fill=(1, 1, 1), color=None, radius=0.2, fill_opacity=0.08)
    p.draw_circle((750, y + 60), 26, fill=rgb(ORG if i == 1 else TEAL), color=None)
    html(p, (724, y + 38, 776, y + 86), f"<div class='r w' style='font-size:24px;text-align:center'>{i+1}</div>")
    html(p, (796, y + 28, 1120, y + 112), f"<div class='w'><h3>{a}</h3><p style='margin:0'>{b}</p></div>")
foot(p, 4, True)

# 5 — comparatif
p = new(); brand(p, 60, 44, 22)
html(p, (60, 100, 1131, 230), "<div class='k'>WHY mFRAMES</div><h2>Compared with online review tools</h2>")
card(p, (60, 240, 560, 700), fill="#ffffff"); card(p, (590, 240, 1131, 700), fill=TEAL)
html(p, (84, 256, 540, 296), f"<h3 style='color:{DIM}'>Cloud review tools</h3>"); html(p, (614, 256, 1110, 296), "<h3 class='w'>mFRAMES</h3>")
rows = [("Your files", "Uploaded to a service", "Stay with you (direct or your own relay)"), ("Precision", "Comment at a timecode", "Pin on the exact frame"), ("Waiting", "Upload, then processing", "None: review right away"),
        ("Input", "Keyboard", "Keyboard or on-device voice dictation"), ("AI agents", "Depends on the tool", "Built-in MCP: publish, read, reply"), ("Editing", "Depends on the tool", "Premiere, After Effects, FCP, Resolve"), ("Formats", "Mostly video", "Video, photo, PDF, PSD / AI")]
for i, (k, a, b) in enumerate(rows):
    y = 312 + i * 54
    cross(p, 92, y + 14); html(p, (114, y - 2, 548, y + 52), f"<p style='margin:0;font-size:12px;color:#8a9b97'>{k.upper()}</p><p style='margin:0;font-size:15px;color:{INK}'>{a}</p>")
    check(p, 640, y + 14, "#ffffff"); p.draw_polyline([(634.5, y + 14.5), (638.5, y + 18.5), (646, y + 9.5)], color=rgb(TEAL), width=2.6)
    html(p, (662, y - 2, 1120, y + 52), f"<div class='w'><p style='margin:0;font-size:12px;color:#bff0e6'>{k.upper()}</p><p style='margin:0;font-size:15px;color:#fff'><b>{b}</b></p></div>")
html(p, (60, 712, 1131, 770), "<p style='font-size:11px'>Comparison by tool category (such as Frame.io, Vimeo Review…), on review features. Offerings vary: check each product.</p>"); foot(p, 5)

# 6 — fin
p = new(); p.insert_image(p.rect, filename="work/g1.png"); p.draw_circle((200, 700), 300, fill=(1, 1, 1), color=None, fill_opacity=0.07)
p.insert_image(fitz.Rect(60, 70, 150, 160), filename="icon.png")
html(p, (60, 190, 700, 430), "<div class='w'><h1 style='font-size:76px'><span class='o'>m</span>FRAMES</h1><p style='font-size:24px;color:#fff;margin-top:12px'>Live review and annotation with your clients.</p></div>")
facts = [("Ready to ship", "Nothing hard-coded: servers, ports, proxy, local-network or relay-only modes."), ("Open", "Documented, versioned session protocol; self-hostable relay."), ("Polished", "French, English, Spanish, Italian. Notarized, automatic updates.")]
for i, (t, d) in enumerate(facts):
    x = 60 + i * 380; p.draw_rect(fitz.Rect(x, 560, x + 350, 720), fill=(1, 1, 1), color=None, radius=0.08, fill_opacity=0.14)
    html(p, (x + 22, 580, x + 330, 712), f"<div class='w'><h3>{t}</h3><p>{d}</p></div>")
foot(p, 6, True)
doc.save("mFRAMES_Brochure_EN.pdf", garbage=4, deflate=True); print("OK", len(doc), "pages")
