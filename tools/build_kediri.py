"""Build assets/kediri.json from OpenStreetMap data (tools/osm_raw.json).

Map data (c) OpenStreetMap contributors, ODbL. https://www.openstreetmap.org/copyright

Pipeline:
  1. project lat/lon to metres (OSM frame: +x east, +z south) around LAT0/LON0
  2. crop to the play area
  3. rotate + translate so Texture Coffee's frontage road (Jl. Dr. Wahidin) lies on the
     game's z = 0 line with the cafe on the +z side, matching buildCafe() in main.js
  4. write roads, drivable graph, water, rails, parks, buildings, landmarks, spots

Run:  python tools/build_kediri.py
"""
import json, math, os, random

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, 'osm_raw.json')
OUT = os.path.join(HERE, '..', 'assets', 'kediri.json')

LAT0, LON0 = -7.81925, 112.01125
KX = 111320 * math.cos(math.radians(LAT0))
KZ = 110540
CROP = (-330, 630, -560, 210)  # x0, x1, z0, z1 in the OSM frame (metres). Client play area: N = Jl. Dhoho north crossroads,
# S = Sumur Bor crossroads, E = Stasiun Kediri, W = Warkop Sopo / Klenteng (was -620..1640 x -560..1000)
TEXTURE = (-7.8198536, 112.0120063)  # Texture Coffee, Jl. Dr. Wahidin No.01, Pakelan

CLS = {'trunk': 0, 'primary': 1, 'secondary': 2, 'tertiary': 3, 'unclassified': 4, 'residential': 5,
       'living_street': 6, 'service': 7, 'pedestrian': 8,
       'trunk_link': 0, 'primary_link': 1, 'secondary_link': 2, 'tertiary_link': 3}
WIDTH = [12, 11, 9, 7.5, 6, 5, 3.6, 3.5, 4]
DRIVE_MAX = 6  # classes 0..6 are in the agent graph


def proj(lat, lon):
    return ((lon - LON0) * KX, -(lat - LAT0) * KZ)


def inside(x, z, m=0):
    return CROP[0] - m <= x <= CROP[1] + m and CROP[2] - m <= z <= CROP[3] + m


def seg_closest(px, pz, ax, az, bx, bz):
    dx, dz = bx - ax, bz - az
    L2 = dx * dx + dz * dz
    t = 0 if L2 == 0 else max(0, min(1, ((px - ax) * dx + (pz - az) * dz) / L2))
    cx, cz = ax + dx * t, az + dz * t
    return math.hypot(px - cx, pz - cz), cx, cz, t


def area2(pts):
    s = 0
    for i in range(len(pts)):
        x1, z1 = pts[i]; x2, z2 = pts[(i + 1) % len(pts)]
        s += x1 * z2 - x2 * z1
    return s


def dp(pts, eps):
    if len(pts) < 3:
        return pts
    a, b = pts[0], pts[-1]
    dmax, idx = 0, 0
    for i in range(1, len(pts) - 1):
        d = seg_closest(pts[i][0], pts[i][1], a[0], a[1], b[0], b[1])[0]
        if d > dmax:
            dmax, idx = d, i
    if dmax > eps:
        return dp(pts[:idx + 1], eps)[:-1] + dp(pts[idx:], eps)
    return [a, b]


def pip(x, z, poly):
    c = False
    n = len(poly)
    for i in range(n):
        x1, z1 = poly[i]; x2, z2 = poly[(i + 1) % n]
        if (z1 > z) != (z2 > z) and x < (x2 - x1) * (z - z1) / (z2 - z1) + x1:
            c = not c
    return c


raw = json.load(open(RAW, encoding='utf8'))['elements']
ways = [e for e in raw if e['type'] == 'way']
rels = [e for e in raw if e['type'] == 'relation']

# ---------------- roads (OSM frame) ----------------
roads = []
for w in ways:
    t = w.get('tags', {})
    hw = t.get('highway')
    if hw not in CLS:
        continue
    pts = [proj(g['lat'], g['lon']) for g in w['geometry']]
    roads.append({'id': w['id'], 'cls': CLS[hw], 'name': t.get('name', ''), 'pts': pts, 'nodes': w['nodes'],
                  'bridge': t.get('bridge') == 'yes'})

# ---------------- anchor: Texture Coffee on Jl. Dr. Wahidin ----------------
tx, tz = proj(*TEXTURE)
best = None
for r in roads:
    if 'Wahidin' not in r['name']:
        continue
    for (ax, az), (bx, bz) in zip(r['pts'], r['pts'][1:]):
        d, cx, cz, _ = seg_closest(tx, tz, ax, az, bx, bz)
        if best is None or d < best[0]:
            best = (d, cx, cz, ax, az, bx, bz, r)
d, fx, fz, ax, az, bx, bz, wroad = best
ux, uz = bx - ax, bz - az
L = math.hypot(ux, uz); ux, uz = ux / L, uz / L
nx, nz = -uz, ux  # perpendicular; flip it toward the cafe pin
if (tx - fx) * nx + (tz - fz) * nz < 0:
    nx, nz = -nx, -nz
print(f'Texture pin {tx:.1f},{tz:.1f} -> {d:.1f} m from {wroad["name"]} (foot {fx:.1f},{fz:.1f}) normal {nx:.3f},{nz:.3f}')
WAHIDIN_W = WIDTH[wroad['cls']]


def G(p):  # OSM frame -> game frame
    x, z = p[0] - fx, p[1] - fz
    return (round(x * nz - z * nx + 20, 2), round(x * nx + z * nz, 2))


def flat(pts):
    out = []
    for p in pts:
        out += list(G(p))
    return out


# cafe lot in game coords (buildCafe uses x 8..32, z 10..27; keep a margin clear)
def in_cafe_lot(gx, gz):
    return 5 <= gx <= 35 and 3 <= gz <= 30


names = ['']
name_idx = {'': 0}


def nid(n):
    if n not in name_idx:
        name_idx[n] = len(names); names.append(n)
    return name_idx[n]


# clip roads to crop: keep runs of vertices inside crop (+margin)
out_roads = []
graph_v, graph_e, vid = [], [], {}
for r in roads:
    runs, cur = [], []
    for p, n in zip(r['pts'], r['nodes']):
        if inside(p[0], p[1], 30):
            cur.append((p, n))
        else:
            if len(cur) > 1: runs.append(cur)
            cur = []
    if len(cur) > 1: runs.append(cur)
    for run in runs:
        pts = [p for p, _ in run]
        w = WIDTH[r['cls']]
        if r is wroad: w = 8
        out_roads.append({'n': nid(r['name']), 'c': r['cls'], 'w': w, 'b': 1 if r['bridge'] else 0, 'p': flat(pts)})
        if r['cls'] <= DRIVE_MAX:
            prev = None
            for p, n in run:
                if n not in vid:
                    vid[n] = len(graph_v) // 2; graph_v += list(G(p))
                if prev is not None and prev != vid[n]:
                    graph_e += [prev, vid[n], r['cls']]
                prev = vid[n]

# ---------------- water ----------------
water = []
for rel in rels:
    t = rel.get('tags', {})
    if t.get('natural') != 'water':
        continue
    # stitch member ways into rings
    def stitch(role):
        segs = [[(g['lat'], g['lon']) for g in m['geometry']] for m in rel['members'] if m.get('role') == role and m['type'] == 'way']
        rings = []
        while segs:
            ring = segs.pop(0)
            changed = True
            while changed and ring[0] != ring[-1]:
                changed = False
                for i, s in enumerate(segs):
                    if s[0] == ring[-1]: ring += s[1:]
                    elif s[-1] == ring[-1]: ring += s[::-1][1:]
                    elif s[-1] == ring[0]: ring = s[:-1] + ring
                    elif s[0] == ring[0]: ring = s[::-1][:-1] + ring
                    else: continue
                    segs.pop(i); changed = True; break
            rings.append(ring)
        return rings
    outers = stitch('outer'); inners = stitch('inner')
    for o in outers:
        op = dp([proj(*q) for q in o], 1.0)
        holes = [dp([proj(*q) for q in i], 1.0) for i in inners]
        water.append({'o': op, 'h': [h for h in holes if pip(h[0][0], h[0][1], op)]})
for w in ways:
    t = w.get('tags', {})
    if t.get('natural') == 'water' and w['geometry'][0] == w['geometry'][-1]:
        water.append({'o': dp([proj(g['lat'], g['lon']) for g in w['geometry']], 1.0), 'h': []})


def clip_poly(poly):  # Sutherland-Hodgman against the crop rect (+40 m)
    m = 40
    def clip(pts, inside_f, inter):
        out = []
        for i in range(len(pts)):
            a, b = pts[i - 1], pts[i]
            ia, ib = inside_f(a), inside_f(b)
            if ib:
                if not ia: out.append(inter(a, b))
                out.append(b)
            elif ia:
                out.append(inter(a, b))
        return out
    def lx(v):
        return (lambda p: p[0] >= v, lambda a, b: (v, a[1] + (b[1] - a[1]) * (v - a[0]) / (b[0] - a[0])))
    def hx(v):
        return (lambda p: p[0] <= v, lambda a, b: (v, a[1] + (b[1] - a[1]) * (v - a[0]) / (b[0] - a[0])))
    def lz(v):
        return (lambda p: p[1] >= v, lambda a, b: (a[0] + (b[0] - a[0]) * (v - a[1]) / (b[1] - a[1]), v))
    def hz(v):
        return (lambda p: p[1] <= v, lambda a, b: (a[0] + (b[0] - a[0]) * (v - a[1]) / (b[1] - a[1]), v))
    pts = poly
    for f, g in (lx(CROP[0] - m), hx(CROP[1] + m), lz(CROP[2] - m), hz(CROP[3] + m)):
        if not pts: break
        pts = clip(pts, f, g)
    return pts


out_water = []
for wtr in water:
    o = clip_poly(wtr['o'])
    if len(o) < 3: continue
    holes = [h for h in wtr['h'] if any(inside(x, z, 40) for x, z in h)]
    out_water.append({'o': flat(o), 'h': [flat(h) for h in holes]})

# river centreline (for "west bank = Mojoroto"), OSM frame, sorted by z
river = []
for w in ways:
    t = w.get('tags', {})
    if t.get('waterway') == 'river':
        river += [proj(g['lat'], g['lon']) for g in w['geometry']]
river = sorted((round(z, 1), round(x, 1)) for x, z in river if CROP[2] - 200 < z < CROP[3] + 200)

# ---------------- rails, parks ----------------
rails, parks = [], []
main_rail = []  # main-line ways, stitched below into the train's track
for w in ways:
    t = w.get('tags', {})
    pts = [proj(g['lat'], g['lon']) for g in w['geometry']]
    if t.get('railway') == 'rail':
        keep = [p for p in pts if inside(p[0], p[1], 30)]
        if len(keep) > 1: rails.append(flat(keep))
        if t.get('usage') == 'main' and not t.get('service'):
            main_rail.append(pts)
    elif t.get('leisure') in ('park', 'pitch', 'garden') or t.get('landuse') in ('grass', 'recreation_ground', 'cemetery') or t.get('amenity') == 'grave_yard':
        if pts[0] == pts[-1] and any(inside(x, z) for x, z in pts):
            c = clip_poly(dp(pts[:-1], 0.5))
            if len(c) >= 3: parks.append({'k': 1 if t.get('leisure') == 'pitch' else 0, 'p': flat(c)})

# main line as one polyline (the moving train runs on it)
chain = main_rail.pop(0) if main_rail else []
while main_rail:
    for i, w in enumerate(main_rail):
        if w[0] == chain[-1]: chain += w[1:]
        elif w[-1] == chain[-1]: chain += w[::-1][1:]
        elif w[-1] == chain[0]: chain = w + chain[1:]
        elif w[0] == chain[0]: chain = w[::-1] + chain[1:]
        else: continue
        main_rail.pop(i); break
    else:
        break  # leftover pieces do not connect
train = flat([p for p in chain if inside(p[0], p[1], 120)])

# ---------------- buildings ----------------
major = [r for r in out_roads if r['c'] <= 3]
# spatial hash of major road segments (game frame) for shop-sign edges
seg_hash = {}
for r in major:
    p = r['p']
    for i in range(0, len(p) - 2, 2):
        ax_, az_, bx_, bz_ = p[i], p[i + 1], p[i + 2], p[i + 3]
        for cx in range(int(min(ax_, bx_) // 20) - 1, int(max(ax_, bx_) // 20) + 2):
            for cz in range(int(min(az_, bz_) // 20) - 1, int(max(az_, bz_) // 20) + 2):
                seg_hash.setdefault((cx, cz), []).append((ax_, az_, bx_, bz_, r['w'], r['n']))

LANDMARK_NAMES = {
    'Masjid Agung Kediri': 'masjid', 'Stasiun Kediri': 'stasiun', 'Kediri Mall': 'mall',
}
bld = []
rng = random.Random(7)
for w in ways:
    t = w.get('tags', {})
    if 'building' not in t or w['geometry'][0] != w['geometry'][-1]:
        continue
    if t['building'] in ('roof', 'canopy', 'carport'):  # open canopies (station platforms): not solid blocks
        continue
    pts = [proj(g['lat'], g['lon']) for g in w['geometry']][:-1]
    cx = sum(p[0] for p in pts) / len(pts); cz = sum(p[1] for p in pts) / len(pts)
    if not inside(cx, cz):
        continue
    pts = dp(pts + [pts[0]], 0.3)[:-1]
    if len(pts) < 3:
        continue
    gp = [G(p) for p in pts]
    a = area2(gp) / 2
    if abs(a) < 8:
        continue
    if a < 0:
        gp = gp[::-1]; a = -a
    gcx = sum(p[0] for p in gp) / len(gp); gcz = sum(p[1] for p in gp) / len(gp)
    if in_cafe_lot(gcx, gcz) or any(in_cafe_lot(x, z) for x, z in gp):
        continue
    r = random.Random(w['id'])
    lv = t.get('building:levels')
    try:
        lv = float(lv)
    except (TypeError, ValueError):
        lv = None
    # shop-sign edge: longest edge facing a major road within ~7 m
    sign, sign_road = -1, 0
    bestd = 1e9
    for i in range(len(gp)):
        (x1, z1), (x2, z2) = gp[i], gp[(i + 1) % len(gp)]
        el = math.hypot(x2 - x1, z2 - z1)
        if el < 4:
            continue
        mx, mz = (x1 + x2) / 2, (z1 + z2) / 2
        onx, onz = (z2 - z1) / el, -(x2 - x1) / el  # outward normal
        for s in seg_hash.get((int(mx // 20), int(mz // 20)), []):
            dd, qx, qz, _ = seg_closest(mx, mz, *s[:4])
            if dd - s[4] / 2 < 7 and ((qx - mx) * onx + (qz - mz) * onz) > 0 and dd < bestd:
                bestd, sign, sign_road = dd, i, s[5]
    if lv:
        h = lv * 3.3 + r.uniform(0.3, 1.2)
    elif sign >= 0:
        h = r.uniform(6.5, 10.5)  # ruko
    elif a < 80:
        h = r.uniform(3.3, 4.5)
    elif a < 300:
        h = r.uniform(3.8, 7.5)
    elif a < 1200:
        h = r.uniform(6, 11)
    else:
        h = r.uniform(8, 14)
    kind = 0 if (a < 220 and h < 5 and sign < 0 and len(gp) <= 8) else 1
    lm = LANDMARK_NAMES.get(t.get('name', ''), '')
    if t.get('building') in ('mosque',) and not lm:
        lm = 'mushola'
    b = {'p': [c for q in gp for c in q], 'h': round(h, 1), 'k': kind}
    if sign >= 0 and (r.random() < 0.6 or 'Dhoho' in names[sign_road]):
        b['s'] = sign
    if lm:
        b['l'] = lm
    bld.append(b)

# ---------------- landmarks (labels + model anchors), game frame ----------------
def named_centroid(key, tagfilter=None):
    for w in ways:
        t = w.get('tags', {})
        if t.get('name') == key and (tagfilter is None or tagfilter(t)):
            pts = [proj(g['lat'], g['lon']) for g in w['geometry']]
            return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
    return None


lm = []
def add_lm(key, label, osm_xy, r=40):
    if osm_xy and inside(*osm_xy):
        x, z = G(osm_xy); lm.append({'id': key, 'name': label, 'x': x, 'z': z, 'r': r})

add_lm('texture', 'TEXTURE COFFEE', (tx, tz), 22)
add_lm('alun', 'ALUN-ALUN KEDIRI', named_centroid('Alun-Alun Kediri'), 70)
add_lm('masjid', 'MASJID AGUNG KEDIRI', named_centroid('Masjid Agung Kediri', lambda t: 'building' in t), 45)
add_lm('klenteng', 'KLENTENG TJOE HWIE KIONG', proj(-7.8200945, 112.009487), 40)
add_lm('stasiun', 'STASIUN KEDIRI', named_centroid('Stasiun Kediri', lambda t: 'building' in t), 60)
add_lm('mall', 'MALL', named_centroid('Kediri Mall'), 60)
add_lm('plaza', 'PLAZA DHOHO', proj(-7.8277968, 112.0107079), 45)
# Brantas bridges: midpoint of bridge roads over the river
for r in roads:
    if r['bridge'] and r['cls'] <= 3 and r['name']:
        xs = r['pts']; mid = xs[len(xs) // 2]
        if inside(*mid) and mid[0] < -150:
            add_lm('jembatan', 'JEMBATAN BRANTAS', mid, 45)

# ---------------- spots (posters, parked bikes, copet marker) ----------------
bpolys = [list(zip(b['p'][::2], b['p'][1::2])) for b in bld]
bhash = {}
for i, bp in enumerate(bpolys):
    xs = [p[0] for p in bp]; zs = [p[1] for p in bp]
    for cx in range(int(min(xs) // 20), int(max(xs) // 20) + 1):
        for cz in range(int(min(zs) // 20), int(max(zs) // 20) + 1):
            bhash.setdefault((cx, cz), []).append(i)
gwater = [list(zip(w['o'][::2], w['o'][1::2])) for w in out_water]


def blocked(x, z, pad=1.2):
    for dx in (-pad, 0, pad):
        for dz in (-pad, 0, pad):
            px, pz = x + dx, z + dz
            for i in bhash.get((int(px // 20), int(pz // 20)), []):
                if pip(px, pz, bpolys[i]):
                    return True
    if any(pip(x, z, w) for w in gwater):
        return True
    return in_cafe_lot(x, z)


def roadside_near(x, z, classes=(0, 1, 2, 3, 4, 5), off_extra=1.6, maxd=120, avoid=()):
    best = None
    for r in out_roads:
        if r['c'] not in classes or r['b']:
            continue
        p = r['p']
        for i in range(0, len(p) - 2, 2):
            ax_, az_, bx_, bz_ = p[i:i + 4]
            dd, qx, qz, _ = seg_closest(x, z, ax_, az_, bx_, bz_)
            if dd > maxd or (best and dd >= best[0]):
                continue
            L_ = math.hypot(bx_ - ax_, bz_ - az_)
            if L_ < 3:
                continue
            sx, sz = -(bz_ - az_) / L_, (bx_ - ax_) / L_
            for sg in (1, -1):
                ox, oz = qx + sx * sg * (r['w'] / 2 + off_extra), qz + sz * sg * (r['w'] / 2 + off_extra)
                if blocked(ox, oz) or any(math.hypot(ox - a, oz - b) < 60 for a, b in avoid):
                    continue
                yaw = math.atan2(qx - ox, qz - oz)  # board faces the road
                best = (dd, round(ox, 2), round(oz, 2), round(yaw, 3), r)
                break
    return best


posters = [[12.4, 9.5, round(math.pi, 3)]]
used = [(12.4, 9.5)]
for l in lm:
    if l['id'] == 'texture':
        continue
    s = roadside_near(l['x'], l['z'], avoid=used)
    if s:
        posters.append([s[1], s[2], s[3]]); used.append((s[1], s[2]))
# fill up to 12 with points spread along named major roads
cands = []
for r in out_roads:
    if r['c'] <= 3 and r['n']:
        p = r['p']
        for i in range(0, len(p) - 2, 2):
            cands.append(((p[i] + p[i + 2]) / 2, (p[i + 1] + p[i + 3]) / 2))
rng.shuffle(cands)
for x, z in cands:
    if len(posters) >= 12:
        break
    if any(math.hypot(x - a, z - b) < 150 for a, b in used):
        continue
    s = roadside_near(x, z, classes=(0, 1, 2, 3), maxd=20, avoid=used)
    if s:
        posters.append([s[1], s[2], s[3]]); used.append((s[1], s[2]))

# copet marker on Jl. Dhoho closest to the cafe
dh = None
for r in out_roads:
    if 'Dhoho' in names[r['n']]:
        p = r['p']
        for i in range(0, len(p) - 2, 2):
            dd, qx, qz, _ = seg_closest(20, 10, *p[i:i + 4])
            if dh is None or dd < dh[0]:
                dh = (dd, qx, qz)
s = roadside_near(dh[1], dh[2], classes=(2, 3), off_extra=1.0, maxd=15)
copet = [s[1], s[2]] if s else [dh[1], dh[2]]

bikes = []
for x, z in cands[::max(1, len(cands) // 40)] + cands:  # second pass fills up when the sparse pass finds too few
    if len(bikes) >= 10:
        break
    if any(math.hypot(x - a, z - b) < 90 for a, b, _ in bikes) or math.hypot(x - 20, z) > 500:
        continue
    s = roadside_near(x, z, classes=(1, 2, 3, 4, 5), off_extra=0.6, maxd=20)
    if s:
        bikes.append([s[1], s[2], round(s[3] + math.pi / 2, 3)])

out = {
    'attribution': 'Map data (c) OpenStreetMap contributors, ODbL',
    'xf': {'nx': round(nx, 6), 'nz': round(nz, 6), 'fx': round(fx, 3), 'fz': round(fz, 3)},
    'crop': CROP,
    'names': names,
    'roads': out_roads,
    'graph': {'v': graph_v, 'e': graph_e},
    'water': out_water,
    'river': river,
    'rails': rails,
    'train': train,
    'parks': parks,
    'bld': bld,
    'lm': lm,
    'posters': posters,
    'bikes': bikes,
    'copet': copet,
}
json.dump(out, open(OUT, 'w', encoding='utf8'), separators=(',', ':'), ensure_ascii=False)
print(f'train pts {len(train)//2}  roads {len(out_roads)}  graph v {len(graph_v)//2} e {len(graph_e)//3}  water {len(out_water)}  rails {len(rails)}  parks {len(parks)}  bld {len(bld)}')
print('landmarks', [(l['id'], l['x'], l['z']) for l in lm])
print('posters', posters)
print('copet', copet, 'bikes', len(bikes))
print('size', os.path.getsize(OUT) // 1024, 'KB')
