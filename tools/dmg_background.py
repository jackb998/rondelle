import sys
from PIL import Image, ImageDraw, ImageFont
# Background of the DMG window (640 x 680 points). Icon centres set by tools/dmg_layout.sh:
#   Rondelle.app (165,170)  Applications (475,170)
#   Open Terminal (165,395) Allow Opening (475,395)
#   READ ME.txt (250,595)   Licenses (390,595)   (bottom 30 points left free: Finder writes «N items» there)
W, H = 640, 760   # taller than the window (about 670 points): the band colour reaches the bottom edge, no white strip
ACC = (224, 112, 32)      # Rondelle orange
INK = (40, 40, 44)
SUB = (110, 110, 118)
BG = (246, 244, 240)
BAND = (236, 233, 227)
def make(scale, out):
    im = Image.new("RGB", (W*scale, H*scale), BG)
    d = ImageDraw.Draw(im)
    def f(size, bold=False):
        return ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf" if bold else "/System/Library/Fonts/SFNS.ttf", size*scale)
    def t(x, y, s, size, col=INK, bold=False, anchor="la"):
        d.text((x*scale, y*scale), s, font=f(size, bold), fill=col, anchor=anchor)
    def badge(x, y, n):
        r = 13
        d.ellipse(((x-r)*scale, (y-r)*scale, (x+r)*scale, (y+r)*scale), fill=ACC)
        t(x, y+1, str(n), 16, (255, 255, 255), True, "mm")
    def arrow(x1, x2, y, back=False):
        # back: the head points left (x1 < x2 always)
        if back:
            d.line(((x1+14)*scale, y*scale, x2*scale, y*scale), fill=ACC, width=5*scale)
            d.polygon([(x1*scale, y*scale), ((x1+18)*scale, (y-11)*scale), ((x1+18)*scale, (y+11)*scale)], fill=ACC)
        else:
            d.line((x1*scale, y*scale, (x2-14)*scale, y*scale), fill=ACC, width=5*scale)
            d.polygon([(x2*scale, y*scale), ((x2-18)*scale, (y-11)*scale), ((x2-18)*scale, (y+11)*scale)], fill=ACC)
    t(320, 20, "Install Rondelle  ·  Installa Rondelle", 20, INK, True, "ma")
    # Step 1: drag the app
    badge(48, 76, 1)
    t(72, 64, "Drag Rondelle onto Applications", 16)
    t(72, 86, "Trascina Rondelle su Applicazioni", 14, SUB)
    arrow(240, 400, 170)
    d.line((40*scale, 238*scale, 600*scale, 238*scale), fill=(226, 222, 214), width=1*scale)
    # Steps 2 and 3: open Terminal, drag the script into it
    badge(48, 268, 2)
    t(72, 256, "Double-click «Open Terminal»  (or ⌘ Space, type “Terminal”)", 15)
    t(72, 277, "Doppio clic su «Open Terminal»  (oppure ⌘ Spazio, scrivi “Terminale”)", 13, SUB)
    badge(48, 314, 3)
    # «sh» first: the script comes from the same download, so macOS blocks it if it runs on its own (seen on Tahoe)
    def keyed(x, y, before, after, size, col):
        # text with «sh» drawn as a small dark key, so it reads as something to type
        t(x, y, before, size, col)
        kx = x + f(size).getlength(before) / scale + 3
        kw = f(size, True).getlength("sh") / scale + 10
        d.rounded_rectangle((kx*scale, (y-2)*scale, (kx+kw)*scale, (y+size+3)*scale), radius=4*scale, fill=(30, 30, 34))
        t(kx + kw/2, y + size/2 + 1, "sh", size, (120, 230, 120), True, "mm")
        t(kx + kw + 3, y, after, size, col)
    keyed(72, 302, "In Terminal type", "and a space, drag «Allow Opening» in, press Return", 15, INK)
    keyed(72, 324, "Nel Terminale scrivi", "e uno spazio, trascina dentro «Allow Opening», premi Invio", 13, SUB)
    # Mini Terminal window between the two icons, with the script going into it
    x0, y0, x1, y1 = 262, 362, 372, 428
    d.rounded_rectangle((x0*scale, y0*scale, x1*scale, y1*scale), radius=9*scale, fill=(30, 30, 34))
    d.rounded_rectangle((x0*scale, y0*scale, x1*scale, (y0+18)*scale), radius=9*scale, fill=(70, 70, 76))
    d.rectangle((x0*scale, (y0+10)*scale, x1*scale, (y0+18)*scale), fill=(70, 70, 76))
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx = x0 + 12 + i*14
        d.ellipse(((cx-4)*scale, (y0+5)*scale, (cx+4)*scale, (y0+13)*scale), fill=c)
    t(x0+12, y0+28, "sh", 18, (120, 230, 120))
    d.rectangle(((x0+40)*scale, (y0+31)*scale, (x0+42)*scale, (y0+49)*scale), fill=(120, 230, 120))
    t(x1-12, y0+28, "⏎", 18, (220, 220, 220), False, "ra")
    arrow(380, 425, 395, back=True)
    t(317, 438, "Terminal window", 11, SUB, False, "ma")
    t(320, 470, "Only the first time, then open Rondelle as usual.  ·  Solo la prima volta, poi apri Rondelle come sempre.", 11, SUB, False, "ma")
    # Footer band: reading notes and licences, apart from the install steps
    d.rectangle((0, 505*scale, W*scale, H*scale), fill=BAND)
    d.line((0, 505*scale, W*scale, 505*scale), fill=(222, 218, 210), width=1*scale)
    t(320, 516, "Without Terminal:  System Settings ▸ Privacy & Security ▸ Open Anyway", 13, INK, False, "ma")
    t(320, 536, "Senza Terminale:  Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Apri comunque", 12, SUB, False, "ma")
    d.line((200*scale, 560*scale, 440*scale, 560*scale), fill=(222, 218, 210), width=1*scale)
    im.save(out, dpi=(72*scale, 72*scale))
make(1, sys.argv[1]); make(2, sys.argv[2])
