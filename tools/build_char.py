"""Builds assets/oot_char.glb — a skinned low-poly (PS2-era) street character for OOT Street.

Original character: outfit taken from the OOT merch refs (striped jersey, grey denim shorts,
white socks, black/white sneakers, sunglasses). Run:  python tools/build_char.py
Bone names used by the game: root, pelvis, spine, neck, head, shoulder_L/R, elbow_L/R, hip_L/R, knee_L/R.
"L" is on -x, the character faces +z.
"""
import io, json, math, os, random, struct
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, '..', 'assets')
random.seed(7)

# ---------------------------------------------------------------- skeleton
BONES = [  # name, parent, world rest position
    ('root', None, (0, 0, 0)),
    ('pelvis', 'root', (0, 0.95, 0)),
    ('spine', 'pelvis', (0, 1.08, 0)),
    ('neck', 'spine', (0, 1.64, 0)),
    ('head', 'neck', (0, 1.74, 0)),
    ('shoulder_L', 'spine', (-0.2, 1.55, 0)),
    ('elbow_L', 'shoulder_L', (-0.225, 1.26, 0)),
    ('shoulder_R', 'spine', (0.2, 1.55, 0)),
    ('elbow_R', 'shoulder_R', (0.225, 1.26, 0)),
    ('hip_L', 'pelvis', (-0.105, 0.94, 0)),
    ('knee_L', 'hip_L', (-0.11, 0.52, 0)),
    ('hip_R', 'pelvis', (0.105, 0.94, 0)),
    ('knee_R', 'hip_R', (0.11, 0.52, 0)),
]
BI = {b[0]: i for i, b in enumerate(BONES)}
BPOS = {b[0]: np.array(b[2], float) for b in BONES}

# ---------------------------------------------------------------- geometry
class Prim:
    def __init__(self, tex_w, tex_h):
        self.tw, self.th = tex_w, tex_h
        self.P, self.N, self.UV, self.J, self.W, self.I = [], [], [], [], [], []

    def add_vert(self, p, uvpx, w):
        self.P.append(p); self.UV.append((uvpx[0] / self.tw, uvpx[1] / self.th))
        items = sorted(w.items(), key=lambda kv: -kv[1])[:4]
        s = sum(v for _, v in items)
        j = [BI[k] for k, _ in items] + [0] * (4 - len(items))
        ww = [v / s for _, v in items] + [0.0] * (4 - len(items))
        self.J.append(j); self.W.append(ww); self.N.append(None)
        return len(self.P) - 1


def sgnpow(v, e):
    return math.copysign(abs(v) ** e, v)


def ring_point(sec, a, axis):
    cx, cy, cz = sec['c']
    if axis == 'y':
        rx = sec['rx']; zf = sec.get('zf', sec.get('rz', rx)); zb = sec.get('zb', zf)
        ex = sec.get('ex', 1.0)
        x = cx + rx * sgnpow(math.sin(a), ex)
        cz_ = math.cos(a)
        z = cz + (zf if cz_ > 0 else zb) * sgnpow(cz_, ex)
        y = cy + (sec['dy'](a) if 'dy' in sec else 0)
        return (x, y, z)
    # axis z: ring in xy plane, a=0 at top
    rx, ry = sec['rx'], sec['ry']
    x = cx + rx * math.sin(a)
    y = max(sec.get('floor', -9), cy + ry * math.cos(a))
    return (x, y, cz)


def loft(pr, secs, n, u0, uw, axis='y', cap0=False, cap1=False, uflip=False):
    """secs: list of dict(c, rx, rz|zf/zb | ry, w={bone:wt}, v=px). Smooth normals within the loft."""
    start = len(pr.P)
    rings = []
    for s in secs:
        idx = []
        for k in range(n + 1):
            a = -math.pi + 2 * math.pi * k / n
            p = ring_point(s, a, axis)
            u = u0 + (k / n) * uw
            if uflip: u = u0 + uw - (k / n) * uw
            idx.append(pr.add_vert(p, (u, s['v']), s['w']))
        rings.append(idx)
    tris = []
    for i in range(len(rings) - 1):
        for k in range(n):
            a, b, c, d = rings[i][k], rings[i][k + 1], rings[i + 1][k + 1], rings[i + 1][k]
            tris += [(a, b, c), (a, c, d)]
    centers = [np.array(s['c'], float) for s in secs]

    def orient(tri, outward_ref):
        A, B, C = (np.array(pr.P[t]) for t in tri)
        nrm = np.cross(B - A, C - A)
        cen = (A + B + C) / 3
        return tri if np.dot(nrm, cen - outward_ref(cen)) >= 0 else (tri[0], tri[2], tri[1])

    def axis_ref(cen):  # nearest point on the loft spine
        best, bd = centers[0], 9
        for i in range(len(centers) - 1):
            p0, p1 = centers[i], centers[i + 1]
            d = p1 - p0; L = np.dot(d, d)
            t = 0 if L == 0 else max(0, min(1, np.dot(cen - p0, d) / L))
            q = p0 + t * d; dist = np.linalg.norm(cen - q)
            if dist < bd: best, bd = q, dist
        return best
    out = [orient(t, axis_ref) for t in tris]
    # caps
    for which, flag in ((0, cap0), (-1, cap1)):
        if not flag: continue
        s = secs[which]; nb = centers[1 if which == 0 else -2]
        tip = np.array(s['c'], float) + (np.array(s['c'], float) - nb) / max(1e-6, np.linalg.norm(np.array(s['c']) - nb)) * flag
        ci = pr.add_vert(tuple(tip), (u0 + uw / 2, s['v']), s['w'])
        ring = rings[which]
        for k in range(n):
            t = (ci, ring[k], ring[k + 1])
            out.append(orient(t, lambda cen, c0=np.array(s['c'], float), nb=nb: c0 - (c0 - nb) * 0.5))
    # smooth normals (merge seam duplicates by position)
    acc = {}
    for t in out:
        A, B, C = (np.array(pr.P[i]) for i in t)
        fn = np.cross(B - A, C - A)
        for i in t:
            key = tuple(np.round(pr.P[i], 5))
            acc[key] = acc.get(key, 0) + fn
    for i in range(start, len(pr.P)):
        v = acc.get(tuple(np.round(pr.P[i], 5)), np.array([0, 1, 0.0]))
        L = np.linalg.norm(v); pr.N[i] = tuple(v / L) if L > 0 else (0, 1, 0)
    pr.I += out


def flat_tris(pr, verts, tris, uvpx, w):
    """Flat-shaded triangles (nose, ears, glasses)."""
    for t in tris:
        A, B, C = (np.array(verts[i], float) for i in t)
        n = np.cross(B - A, C - A); n = n / (np.linalg.norm(n) or 1)
        ids = []
        for i in t:
            ids.append(pr.add_vert(tuple(verts[i]), uvpx, w)); pr.N[ids[-1]] = tuple(n)
        pr.I.append(tuple(ids))


def box(pr, c, size, uvpx, w):
    cx, cy, cz = c; hx, hy, hz = (s / 2 for s in size)
    V = [(cx + sx * hx, cy + sy * hy, cz + sz * hz) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    # index = (sx>0)*4 + (sy>0)*2 + (sz>0)
    F = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    tris = []
    for a, b, c_, d in F: tris += [(a, b, c_), (a, c_, d)]
    # ensure outward winding
    cen = np.array(c, float); fixed = []
    for t in tris:
        A, B, C = (np.array(V[i]) for i in t)
        fixed.append(t if np.dot(np.cross(B - A, C - A), (A + B + C) / 3 - cen) > 0 else (t[0], t[2], t[1]))
    flat_tris(pr, V, fixed, uvpx, w)


# ---------------------------------------------------------------- textures
def noise(img, amt, step=1):
    px = img.load(); W, H = img.size
    for y in range(0, H, step):
        for x in range(0, W, step):
            d = int((random.random() - 0.5) * amt)
            for yy in range(y, min(H, y + step)):
                for xx in range(x, min(W, x + step)):
                    r, g, b = px[xx, yy][:3]
                    px[xx, yy] = (max(0, min(255, r + d)), max(0, min(255, g + d)), max(0, min(255, b + d)))


SKIN = (110, 66, 40)
HEAD_TOP, HEAD_BOT = 1.995, 1.70
def HY(y):  # head texture row for world height
    return (HEAD_TOP - y) / (HEAD_TOP - HEAD_BOT) * 128
def HX(a):  # head texture column for angle (0 = front)
    return 64 + a / (2 * math.pi) * 128


def tex_skin():
    im = Image.new('RGB', (256, 128), SKIN); noise(im, 10, 2)
    d = ImageDraw.Draw(im)
    # body region (x 128..256): subtle vertical shading
    for x in range(128, 256):
        f = 0.92 + 0.08 * math.cos((x - 192) / 64 * math.pi)
        for y in range(128):
            r, g, b = im.getpixel((x, y)); im.putpixel((x, y), (int(r * f), int(g * f), int(b * f)))
    # head region: jaw shade, hair, face
    for x in range(128):
        a = (x - 64) / 128 * 2 * math.pi
        hair_y = 40 + (92 - 40) * (1 - math.cos(a)) / 2
        for y in range(128):
            r, g, b = im.getpixel((x, y))
            if y < hair_y:
                v = 22 + int(random.random() * 10); im.putpixel((x, y), (v, int(v * 0.75), int(v * 0.55)))
            elif y < hair_y + 2:
                im.putpixel((x, y), ((r + 30) // 2, (g + 22) // 2, (b + 16) // 2))
            elif y > HY(1.77):
                f = 0.86; im.putpixel((x, y), (int(r * f), int(g * f), int(b * f)))
    ey, by, my, ny = HY(1.815), HY(1.838), HY(1.757), HY(1.778)
    ex = (HX(0.22), HX(0.5))
    for s in (-1, 1):
        x0, x1 = sorted((64 + s * (ex[0] - 64), 64 + s * (ex[1] - 64)))
        d.rectangle([x0 - 1, by - 1, x1 + 1, by], fill=(24, 15, 10))            # brow
        d.rectangle([x0, ey - 1, x1, ey + 1], fill=(225, 215, 200))             # eye white
        px0 = x0 + 2 if s < 0 else x0 + 1
        d.rectangle([px0, ey - 1, px0 + 2, ey + 1], fill=(30, 18, 10))          # iris
        d.line([x0, ey - 2, x1, ey - 2], fill=(40, 24, 16))                    # lid
    d.rectangle([60, ny - 1, 68, ny], fill=(80, 46, 30))                       # nostril shade
    d.rectangle([58, my, 70, my + 1], fill=(70, 34, 26))                       # lips
    d.line([59, my - 1, 69, my - 1], fill=(55, 28, 20))
    for s in (-1, 1):                                                          # ear shading
        xe = HX(s * math.pi / 2)
        d.rectangle([xe - 2, HY(1.835), xe + 2, HY(1.785)], fill=(88, 52, 32))
    return im


def tex_shirt():
    W, H = 256, 160
    im = Image.new('RGB', (W, H), (235, 226, 207))
    d = ImageDraw.Draw(im)
    x = 0
    widths = [3, 6, 2, 5, 4, 7, 3]
    i = 0
    while x < W:
        w = widths[i % len(widths)]; i += 1
        d.rectangle([x, 0, x + w - 1, H], fill=(184, 165, 140) if i % 2 else (206, 190, 166)); x += w + 5
    d.rectangle([0, 52, W, 74], fill=(235, 226, 207))                         # chest band round the back
    jer = Image.open(os.path.join(ASSETS, 'jersey_tex.jpg')).convert('RGB').resize((100, 128), Image.LANCZOS)
    im.paste(jer, (78, 0))
    d.rectangle([0, 0, W, 3], fill=(96, 92, 86))                                # collar band
    # sleeve strip (y 128..160)
    for x in range(0, W, 8): d.rectangle([x, 128, x + 2, 160], fill=(170, 150, 124))
    d.rectangle([0, 154, W, 160], fill=(96, 92, 86))                            # sleeve cuff
    noise(im, 10, 2)
    return im


def tex_shorts():
    im = Image.new('RGB', (128, 128), (160, 168, 178)); noise(im, 30, 1)
    d = ImageDraw.Draw(im)
    for y in range(0, 128, 3): d.line([0, y, 128, y + 6], fill=(150, 158, 168))   # twill
    for x in (0, 32, 64, 96, 127): d.line([x, 0, x, 128], fill=(118, 124, 134), width=2)  # side/front/back seams
    d.rectangle([0, 0, 128, 6], fill=(132, 138, 148))                           # waistband
    d.line([0, 124, 128, 124], fill=(190, 196, 204), width=2)                  # rolled hem
    for x0 in (44, 72): d.arc([x0, 6, x0 + 18, 30], 0, 180, fill=(110, 116, 126))   # pockets
    return im


def tex_gear():
    im = Image.new('RGB', (128, 64), (238, 236, 230)); noise(im, 8, 1)
    d = ImageDraw.Draw(im)
    for x in range(0, 32, 3): d.line([x, 0, x, 64], fill=(218, 216, 210))     # sock rib
    # shoe region x 32..128: black/white blocky camo, white sole band at the edges (bottom of ring)
    for y in range(0, 64, 4):
        for x in range(32, 128, 4):
            c = random.choice([(20, 20, 20), (235, 235, 230), (120, 120, 118), (235, 235, 230)])
            d.rectangle([x, y, x + 3, y + 3], fill=c)
    d.rectangle([32, 0, 44, 64], fill=(240, 238, 232)); d.rectangle([116, 0, 128, 64], fill=(240, 238, 232))
    d.rectangle([44, 0, 46, 64], fill=(40, 40, 40)); d.rectangle([114, 0, 116, 64], fill=(40, 40, 40))
    return im


def png_bytes(im):
    b = io.BytesIO(); im.save(b, 'PNG', optimize=True); return b.getvalue()

# ---------------------------------------------------------------- build parts
skin = Prim(256, 128); shirt = Prim(256, 160); shorts = Prim(128, 128); gear = Prim(128, 64); hair = Prim(8, 8)
glass_frame = Prim(8, 8); glass_lens = Prim(8, 8)

def V(y0, y1, py0, py1):
    return lambda y: py0 + (y0 - y) / (y0 - y1) * (py1 - py0)

# torso / shirt
sv = V(1.68, 0.96, 0, 128)
T = [  # y, rx, zf, zb, weights
    (0.96, 0.205, 0.135, 0.13, {'pelvis': .5, 'spine': .5}),
    (1.06, 0.19, 0.125, 0.12, {'pelvis': .3, 'spine': .7}),
    (1.20, 0.195, 0.13, 0.125, {'spine': 1}),
    (1.36, 0.21, 0.145, 0.13, {'spine': 1}),
    (1.48, 0.22, 0.14, 0.125, {'spine': 1}),
    (1.56, 0.205, 0.12, 0.11, {'spine': 1}),
    (1.62, 0.15, 0.095, 0.095, {'spine': 1}),
    (1.67, 0.075, 0.075, 0.07, {'spine': .7, 'neck': .3}),
]
loft(shirt, [dict(c=(0, y, 0), rx=rx, zf=zf, zb=zb, ex=0.85, w=w, v=sv(y)) for y, rx, zf, zb, w in T], 14, 0, 256)

for s in (-1, 1):
    side = 'L' if s < 0 else 'R'; sh, el = 'shoulder_' + side, 'elbow_' + side
    # sleeve
    slv = V(1.62, 1.38, 128, 158)
    S = [(1.625, 0.19, 0.05, 0.05, {'spine': .5, sh: .5}), (1.585, 0.205, 0.085, 0.08, {'spine': .2, sh: .8}),
         (1.48, 0.215, 0.09, 0.088, {sh: 1}), (1.38, 0.22, 0.086, 0.084, {sh: 1})]
    loft(shirt, [dict(c=(s * x, y, 0), rx=r, rz=rz, w=w, v=slv(y)) for y, x, r, rz, w in S], 10, 0, 256, cap0=0.02)
    # arm skin
    av = V(1.45, 0.86, 0, 128)
    A = [(1.45, .215, .056, .056, {sh: 1}), (1.30, .222, .05, .052, {sh: .7, el: .3}), (1.25, .225, .046, .047, {sh: .5, el: .5}),
         (1.20, .228, .047, .05, {sh: .2, el: .8}), (1.08, .232, .042, .045, {el: 1}), (0.995, .235, .032, .036, {el: 1})]
    loft(skin, [dict(c=(s * x, y, 0), rx=r, rz=rz, w=w, v=av(y)) for y, x, r, rz, w in A], 8, 128, 128)
    # hand
    H = [(0.995, .236, .03, .034, .03), (0.95, .238, .024, .048, .035), (0.90, .238, .02, .045, .03), (0.86, .236, .015, .03, .02)]
    loft(skin, [dict(c=(s * x, y, 0.004), rx=rx, zf=zf, zb=zb, w={el: 1}, v=av(y)) for y, x, rx, zf, zb in H], 8, 128, 128, cap1=0.012)
    # shorts leg
    hp, kn = 'hip_' + side, 'knee_' + side
    lv = V(0.98, 0.5, 30, 126)
    L = [(0.98, .105, .118, .12, {hp: 1}), (0.85, .11, .118, .12, {hp: 1}), (0.70, .112, .112, .115, {hp: 1}),
         (0.58, .112, .108, .11, {hp: .7, kn: .3}), (0.50, .113, .11, .112, {hp: .4, kn: .6})]
    loft(shorts, [dict(c=(s * x, y, 0), rx=r, rz=rz, w=w, v=lv(y)) for y, x, r, rz, w in L], 10, 0, 128)
    # leg skin
    kv = V(0.6, 0.17, 0, 128)
    K = [(0.60, .058, .058, .058, {hp: .6, kn: .4}), (0.52, .055, .055, .055, {hp: .4, kn: .6}), (0.45, .056, .055, .065, {kn: 1}),
         (0.36, .055, .05, .068, {kn: 1}), (0.26, .045, .045, .05, {kn: 1}), (0.17, .036, .036, .036, {kn: 1})]
    loft(skin, [dict(c=(s * .11, y, 0), rx=rx, zf=zf, zb=zb, w=w, v=kv(y)) for y, rx, zf, zb, w in K], 8, 128, 128)
    # sock
    loft(gear, [dict(c=(s * .11, .21, 0), rx=.044, zf=.044, zb=.048, w={kn: 1}, v=0),
                dict(c=(s * .11, .10, 0), rx=.042, zf=.042, zb=.042, w={kn: 1}, v=64)], 8, 0, 32)
    # shoe (ring in xy, lofted along z)
    zv = lambda z: (z + .07) / .25 * 64
    SH = [(-.07, .055, .045, .045), (-.05, .062, .058, .06), (.02, .062, .062, .06), (.09, .052, .06, .05), (.15, .04, .052, .04), (.18, .034, .035, .03)]
    loft(gear, [dict(c=(s * .11, cy, z), rx=rx, ry=ry, floor=0.004, w={kn: 1}, v=zv(z)) for z, cy, rx, ry in SH],
         10, 32, 96, axis='z', cap0=0.01, cap1=0.01)

# pelvis / shorts top
pv = V(1.03, 0.84, 0, 30)
loft(shorts, [dict(c=(0, y, 0), rx=rx, zf=zf, zb=zb, ex=0.85, w={'pelvis': 1}, v=pv(y))
              for y, rx, zf, zb in [(1.03, .19, .125, .125), (0.95, .2, .13, .135), (0.87, .19, .12, .13)]], 14, 0, 128, cap1=0.03)

# neck
nv = V(1.6, 1.77, 0, 128)
loft(skin, [dict(c=(0, y, z), rx=rx, zf=zf, zb=zb, w=w, v=nv(y)) for y, z, rx, zf, zb, w in [
    (1.60, -.005, .06, .06, .055, {'spine': 1}), (1.67, -.005, .056, .056, .055, {'spine': .4, 'neck': .6}),
    (1.74, -.01, .052, .05, .055, {'neck': .5, 'head': .5}), (1.77, -.01, .05, .045, .05, {'head': 1})]], 10, 128, 128)

# head
HEAD = [  # y, rx, zf, zb
    (1.700, .050, .060, .045), (1.715, .062, .088, .050), (1.735, .072, .100, .060), (1.760, .082, .102, .078),
    (1.790, .088, .106, .092), (1.815, .092, .099, .100), (1.840, .094, .104, .104), (1.875, .092, .100, .104),
    (1.910, .084, .088, .095), (1.945, .066, .066, .074), (1.975, .038, .036, .042)]
HC = (0, 0.005)
def head_w(y): return {'head': .6, 'neck': .4} if y < 1.705 else {'head': 1}
loft(skin, [dict(c=(HC[0], y, HC[1]), rx=rx, zf=zf, zb=zb, ex=0.85, w=head_w(y), v=HY(y)) for y, rx, zf, zb in HEAD],
     16, 0, 128, cap0=0.004, cap1=0.018)
# nose
nz = HC[1]
nose = [(-.02, 1.776, nz + .097), (.02, 1.776, nz + .097), (0, 1.83, nz + .099), (0, 1.784, nz + .128)]
flat_tris(skin, nose, [(3, 0, 1), (3, 2, 0), (3, 1, 2)], (64, HY(1.79)), {'head': 1})
# ears
for s in (-1, 1):
    box(skin, (s * .094, 1.81, .0), (.022, .055, .036), (HX(s * math.pi / 2), HY(1.81)), {'head': 1})

# hair shell (front edge higher than back)
def head_r(y):
    ys = [h[0] for h in HEAD]
    return [float(np.interp(y, ys, [h[i] for h in HEAD])) for i in (1, 2, 3)]
hair_secs = []
# short fade: a thin shell hugging the skull (fixed offset, not a scaled cap), hairline follows the painted one
for y in (1.885, 1.915, 1.948, 1.975):
    rx, zf, zb = head_r(y); o = .006
    sec = dict(c=(0, y + .001, HC[1]), rx=rx + o, zf=zf + o * .8, zb=zb + o * 1.3, ex=0.85, w={'head': 1}, v=4)
    if y == 1.885: sec['dy'] = lambda a: .02 * max(0.0, math.cos(a)) ** 2
    hair_secs.append(sec)
loft(hair, hair_secs, 16, 0, 8, cap1=0.008)

# sunglasses (head-local coordinates; head bone at y 1.74)
gy = 1.815 - 1.74
for s in (-1, 1):
    box(glass_lens, (s * .043, gy, .112), (.07, .038, .012), (4, 4), {'head': 1})
    box(glass_frame, (s * .097, gy + .013, .05), (.008, .008, .12), (4, 4), {'head': 1})
box(glass_frame, (0, gy + .022, .112), (.19, .01, .014), (4, 4), {'head': 1})
box(glass_frame, (0, gy + .008, .113), (.02, .008, .01), (4, 4), {'head': 1})

# ---------------------------------------------------------------- glTF writer
bin_ = bytearray(); views = []; accessors = []

def push(data, target=None):
    while len(bin_) % 4: bin_.append(0)
    off = len(bin_); bin_.extend(data)
    v = {'buffer': 0, 'byteOffset': off, 'byteLength': len(data)}
    if target: v['target'] = target
    views.append(v); return len(views) - 1

def acc(arr, ctype, typ, target=None, minmax=False):
    a = np.ascontiguousarray(arr)
    vi = push(a.tobytes(), target)
    d = {'bufferView': vi, 'componentType': ctype, 'count': int(a.shape[0]), 'type': typ}
    if minmax: d['min'] = a.min(0).tolist(); d['max'] = a.max(0).tolist()
    accessors.append(d); return len(accessors) - 1

images, textures, materials = [], [], []
def add_tex(im):
    vi = push(png_bytes(im)); images.append({'bufferView': vi, 'mimeType': 'image/png'})
    textures.append({'source': len(images) - 1, 'sampler': 0}); return len(textures) - 1

def add_mat(name, tex=None, color=(1, 1, 1, 1), blend=False, double=False):
    m = {'name': name, 'pbrMetallicRoughness': {'baseColorFactor': list(color), 'metallicFactor': 0, 'roughnessFactor': 1}}
    if tex is not None: m['pbrMetallicRoughness']['baseColorTexture'] = {'index': tex}
    if blend: m['alphaMode'] = 'BLEND'
    if double: m['doubleSided'] = True
    materials.append(m); return len(materials) - 1

M = {
    'skin': add_mat('skin', add_tex(tex_skin())),
    'shirt': add_mat('shirt', add_tex(tex_shirt()), double=True),
    'shorts': add_mat('shorts', add_tex(tex_shorts()), double=True),
    'gear': add_mat('gear', add_tex(tex_gear())),
    'hair': add_mat('hair', color=(0.055, 0.04, 0.03, 1)),
    'frame': add_mat('glasses_frame', color=(0.72, 0.72, 0.72, 1)),
    'lens': add_mat('glasses_lens', color=(0.1, 0.1, 0.12, 0.88), blend=True),
}

def prim_json(pr, mat, skinned=True):
    P = np.array(pr.P, np.float32); N = np.array(pr.N, np.float32); UV = np.array(pr.UV, np.float32)
    I = np.array(pr.I, np.uint16).reshape(-1)
    attrs = {'POSITION': acc(P, 5126, 'VEC3', 34962, True), 'NORMAL': acc(N, 5126, 'VEC3', 34962),
             'TEXCOORD_0': acc(UV, 5126, 'VEC2', 34962)}
    if skinned:
        attrs['JOINTS_0'] = acc(np.array(pr.J, np.uint8), 5121, 'VEC4', 34962)
        attrs['WEIGHTS_0'] = acc(np.array(pr.W, np.float32), 5126, 'VEC4', 34962)
    return {'attributes': attrs, 'indices': acc(I, 5123, 'SCALAR', 34963), 'material': mat}

nodes = []
for name, parent, pos in BONES:
    t = np.array(pos) - (BPOS[parent] if parent else 0)
    nodes.append({'name': name, 'translation': [float(x) for x in t]})
for i, (name, parent, _) in enumerate(BONES):
    kids = [j for j, b in enumerate(BONES) if b[1] == name]
    if kids: nodes[i]['children'] = kids

ibm = np.zeros((len(BONES), 16), np.float32)
for i, (name, _, pos) in enumerate(BONES):
    m = np.eye(4, dtype=np.float32); m[0:3, 3] = -np.array(pos)
    ibm[i] = m.T.reshape(-1)  # column-major
skins = [{'name': 'rig', 'joints': list(range(len(BONES))), 'skeleton': 0,
          'inverseBindMatrices': acc(ibm, 5126, 'MAT4')}]

meshes = []
scene_nodes = [0]
for nm, pr, mk in [('body_skin', skin, 'skin'), ('shirt', shirt, 'shirt'), ('shorts', shorts, 'shorts'),
                   ('gear', gear, 'gear'), ('hair', hair, 'hair')]:
    meshes.append({'name': nm, 'primitives': [prim_json(pr, M[mk])]})
    nodes.append({'name': nm, 'mesh': len(meshes) - 1, 'skin': 0}); scene_nodes.append(len(nodes) - 1)
meshes.append({'name': 'glasses', 'primitives': [prim_json(glass_frame, M['frame'], False), prim_json(glass_lens, M['lens'], False)]})
nodes.append({'name': 'glasses', 'mesh': len(meshes) - 1})
nodes[BI['head']].setdefault('children', []).append(len(nodes) - 1)

gltf = {
    'asset': {'version': '2.0', 'generator': 'oot-street build_char.py'},
    'scene': 0, 'scenes': [{'name': 'oot_char', 'nodes': scene_nodes}],
    'nodes': nodes, 'meshes': meshes, 'skins': skins, 'materials': materials,
    'textures': textures, 'images': images,
    'samplers': [{'magFilter': 9728, 'minFilter': 9729, 'wrapS': 33071, 'wrapT': 33071}],
    'accessors': accessors, 'bufferViews': views, 'buffers': [{'byteLength': 0}],
}
while len(bin_) % 4: bin_.append(0)
gltf['buffers'][0]['byteLength'] = len(bin_)
js = json.dumps(gltf, separators=(',', ':')).encode()
while len(js) % 4: js += b' '
out = os.path.join(ASSETS, 'oot_char.glb')
with open(out, 'wb') as f:
    f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(bin_)))
    f.write(struct.pack('<II', len(js), 0x4E4F534A)); f.write(js)
    f.write(struct.pack('<II', len(bin_), 0x004E4942)); f.write(bin_)
tri = sum(len(p.I) for p in (skin, shirt, shorts, gear, hair, glass_frame, glass_lens))
print('wrote', out, os.path.getsize(out), 'bytes,', tri, 'tris')
