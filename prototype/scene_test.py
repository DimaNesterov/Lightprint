"""Synthetic room to test the Lumen law and preview the look."""
import numpy as np
from PIL import Image
from lightfield import *

ROOM = np.array([4.0, 2.6, 3.0])          # x width, y height, z depth
WIN = dict(x0=1.2, x1=2.6, y0=0.9, y1=2.2)  # window on wall z = 0
LAMP = np.array([3.4, 1.5, 2.4])


def surface_points(step=0.05):
    pts, nrm = [], []
    xs = np.arange(step / 2, ROOM[0], step)
    ys = np.arange(step / 2, ROOM[1], step)
    zs = np.arange(step / 2, ROOM[2], step)
    for x in xs:
        for z in zs:
            pts.append((x, 0.0, z)); nrm.append((0, 1, 0))          # floor
            pts.append((x, ROOM[1], z)); nrm.append((0, -1, 0))     # ceiling
    for x in xs:
        for y in ys:
            pts.append((x, y, ROOM[2])); nrm.append((0, 0, -1))    # back wall
    for z in zs:
        for y in ys:
            pts.append((0.0, y, z)); nrm.append((1, 0, 0))          # left wall
            pts.append((ROOM[0], y, z)); nrm.append((-1, 0, 0))     # right wall
    return np.array(pts), np.array(nrm)


def kelvin_rgb(k):
    """Camera RGB (WB locked at 5000 K) of light with temperature k: ratio of blackbodies."""
    return blackbody_rgb(k) / blackbody_rgb(5000.0) * 0.8


def window_points(n=3):
    out = []
    for a in np.linspace(0.15, 0.85, n):
        for b in np.linspace(0.15, 0.85, n):
            out.append((WIN['x0'] + a * (WIN['x1'] - WIN['x0']), WIN['y0'] + b * (WIN['y1'] - WIN['y0']), 0.0))
    return np.array(out)


def capture_sunny(pts, nrm, sun_dir, sun_k=4300, sky_k=7500, sun=1.0, sky=0.05):
    rgb = np.zeros((len(pts), 3))
    # sky light: falls off with distance from window
    wc = np.array([(WIN['x0'] + WIN['x1']) / 2, (WIN['y0'] + WIN['y1']) / 2, 0.0])
    d2 = ((pts - wc) ** 2).sum(1)
    rgb += (sky * 1.5 / (0.5 + d2))[:, None] * kelvin_rgb(sky_k)
    # direct sun: point lit if the ray back towards the sun passes through the window
    d = -sun_dir / np.linalg.norm(sun_dir)
    t = -pts[:, 2] / d[2]
    hit = pts + t[:, None] * d
    inside = (t > 0) & (hit[:, 0] > WIN['x0']) & (hit[:, 0] < WIN['x1']) & (hit[:, 1] > WIN['y0']) & (hit[:, 1] < WIN['y1'])
    cos = np.clip((nrm * d).sum(1), 0, 1)
    rgb += (sun * cos * inside)[:, None] * kelvin_rgb(sun_k)
    return rgb


def capture_lamp(pts, nrm, k=2700, power=0.25):
    d = LAMP - pts
    d2 = (d ** 2).sum(1)
    cos = np.clip((nrm * d).sum(1) / np.sqrt(d2), 0, 1)
    return (power * cos / d2)[:, None] * kelvin_rgb(k) + 0.004 * kelvin_rgb(k)


def render(splats_list, size=(900, 700), sigma_m=0.007, opacity=0.14, near_fade=0.7, eye=np.array([3.0, 1.7, 3.6]),
           look=np.array([1.5, 0.8, 0.3]), fov=62, exposure=1.0, bg=0.03):
    W, H = size
    fwd = look - eye; fwd /= np.linalg.norm(fwd)
    right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    f = 0.5 * W / np.tan(np.radians(fov) / 2)
    acc = np.zeros((H, W, 3))
    for pos, col, weight in splats_list:
        rel = pos - eye
        z = rel @ fwd
        ok = z > 0.2
        rel, z, c = rel[ok], z[ok], col[ok]
        u = W / 2 + f * (rel @ right) / z
        v = H / 2 - f * (rel @ up) / z
        rad = np.maximum(f * sigma_m / z, 0.6)
        fade = np.clip((z - 0.35) / (near_fade - 0.35), 0, 1)   # same rule for every splat: fade close to the eye
        for ui, vi, ri, ci, fa in zip(u, v, rad, c, fade):
            r = int(np.ceil(3 * ri))
            x0, x1 = max(int(ui) - r, 0), min(int(ui) + r + 1, W)
            y0, y1 = max(int(vi) - r, 0), min(int(vi) + r + 1, H)
            if x0 >= x1 or y0 >= y1:
                continue
            xs = np.arange(x0, x1) - ui
            ys = np.arange(y0, y1) - vi
            g = np.exp(-(ys[:, None] ** 2 + xs[None, :] ** 2) / (2 * ri * ri))
            # identical splats: same world size and same peak opacity -> same energy on screen per solid angle
            acc[y0:y1, x0:x1] += weight * opacity * fa * g[..., None] * ci
    img = 1 - np.exp(-exposure * acc)
    img = img + bg * (1 - img)
    return Image.fromarray((np.clip(img, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8))


if __name__ == "__main__":
    import time
    pts, nrm = surface_points(0.1)
    sources = [Source("window", window_points(2),
                      np.array([(WIN['x0'] + WIN['x1']) / 2, (WIN['y0'] + WIN['y1']) / 2, 0.0]),
                      area=(WIN['x1'] - WIN['x0']) * (WIN['y1'] - WIN['y0'])),
               Source("point", LAMP[None, :], LAMP, area=0.05)]
    captures = {
        "11:00 sun": (capture_sunny(pts, nrm, np.array([0.35, -0.55, 0.75]), sun_k=5200), [1.0, 0.0]),
        "16:30 low sun": (capture_sunny(pts, nrm, np.array([-0.55, -0.25, 0.8]), sun_k=3000, sun=0.8), [1.0, 0.0]),
        "13:00 overcast": (capture_sunny(pts, nrm, np.array([0.3, -0.5, 0.8]), sun=0.0, sky=0.12, sky_k=6800), [1.0, 0.0]),
        "21:00 lamp": (capture_lamp(pts, nrm), [0.02, 1.0]),
    }
    cell = 0.04
    dims = tuple(int(np.ceil(r / cell)) for r in ROOM)
    t0 = time.time()
    grids = {}
    for name, (rgb, sb) in captures.items():
        g = Grid(np.zeros(3), cell, dims)
        build_field(g, pts, rgb, sources, sb, ambient_gain=1.0, beam_gain=1.0)
        grids[name] = g
    total = sum(g.energy.sum() for g in grids.values())
    budget = 60000
    q = total / budget
    print(f"fields built in {time.time()-t0:.1f}s, quantum {q:.3e}")
    layers = []
    for li, (name, g) in enumerate(grids.items()):
        pos, col = quantum_sample(g, q, layer=li)
        print(f"{name:16s} splats {len(pos):6d}   energy {g.energy.sum():.3e}")
        layers.append((name, pos, col))
        render([(pos, col, 1.0)]).save(f"layer_{li}.png")
    render([(p, c, 1.0) for _, p, c in layers]).save("accumulated.png")
    print("done", time.time() - t0)
