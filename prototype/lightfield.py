"""Prototype of the Lumen light-field pipeline (mirrors LumenCore).

Law: every splat is the same quantum of light. Splats are identical (size, shape, opacity);
only their positions (density) and colour carry information.

capture -> surface voxels (position, linear RGB radiance)
        -> rays from each light source to each lit surface voxel, energy constant along the ray
        -> ambient energy spread uniformly through the room volume
        -> volume grid of energy + colour
        -> hierarchical quantum sampling: cell gets  floor/prob(sum/q)  splats, one per finest cell
"""
import numpy as np
from dataclasses import dataclass, field


# ---------------------------------------------------------------- colour
def luminance(rgb):
    return rgb @ np.array([0.2126, 0.7152, 0.0722])


SRGB_TO_XYZ = np.array([[0.4124, 0.3576, 0.1805],
                        [0.2126, 0.7152, 0.0722],
                        [0.0193, 0.1192, 0.9505]])


def cct_from_rgb(rgb, wb_kelvin=5000.0):
    """McCamy CCT of linear camera RGB, corrected for the locked white balance."""
    xyz = rgb @ SRGB_TO_XYZ.T
    s = xyz.sum(-1, keepdims=True) + 1e-9
    x, y = xyz[..., 0] / s[..., 0], xyz[..., 1] / s[..., 0]
    n = (x - 0.3320) / (0.1858 - y)
    cct = 449 * n ** 3 + 3525 * n ** 2 + 6823.3 * n + 5520.33
    cct = np.clip(cct, 1500, 20000)
    # neutral camera RGB means "light = WB temperature": shift in mired space
    mired = 1e6 / cct - 1e6 / 6504.0 + 1e6 / wb_kelvin
    return 1e6 / np.clip(mired, 1e6 / 25000, 1e6 / 1200)


def blackbody_rgb(kelvin):
    """Tanner Helland approximation, returns linear-ish RGB in 0..1."""
    t = np.asarray(kelvin, float) / 100.0
    r = np.where(t <= 66, 255.0, 329.698727446 * np.power(np.maximum(t - 60, 1e-6), -0.1332047592))
    g = np.where(t <= 66, 99.4708025861 * np.log(np.maximum(t, 1e-6)) - 161.1195681661,
                 288.1221695283 * np.power(np.maximum(t - 60, 1e-6), -0.0755148492))
    b = np.where(t >= 66, 255.0, np.where(t <= 19, 0.0, 138.5177312231 * np.log(np.maximum(t - 10, 1e-6)) - 305.0447927307))
    rgb = np.stack([r, g, b], -1).clip(0, 255) / 255.0
    return rgb


PALETTE = np.array([   # mired-relative palette: warm amber -> neutral -> ice blue
    [1.00, 0.42, 0.12],
    [1.00, 0.66, 0.34],
    [1.00, 0.93, 0.84],
    [0.66, 0.82, 1.00],
    [0.35, 0.60, 1.00],
])


def display_color(kelvin, reference_kelvin=5000.0, span_mired=90.0):
    """Lawful colour scale: position = (mired - reference mired) / span, clamped to [-1, 1],
    mapped onto a fixed warm-neutral-cold palette."""
    m = 1e6 / np.asarray(kelvin, float)
    t = np.clip((m - 1e6 / reference_kelvin) / span_mired, -1, 1)   # warm light = higher mired = t > 0
    u = (1 - t) / 2 * (len(PALETTE) - 1)                              # t=+1 -> 0 (amber), t=-1 -> last (blue)
    i = np.clip(np.floor(u).astype(int), 0, len(PALETTE) - 2)
    f = (u - i)[..., None]
    return PALETTE[i] * (1 - f) + PALETTE[i + 1] * f


# ---------------------------------------------------------------- sources
@dataclass
class Source:
    kind: str                 # "point" or "window"
    points: np.ndarray        # sample points on the source (k, 3)
    center: np.ndarray
    area: float = 1.0


# ---------------------------------------------------------------- field
@dataclass
class Grid:
    origin: np.ndarray
    cell: float
    dims: tuple
    energy: np.ndarray = None
    color: np.ndarray = None   # energy-weighted RGB of display colour

    def __post_init__(self):
        self.energy = np.zeros(self.dims, np.float64)
        self.color = np.zeros(self.dims + (3,), np.float64)


def raster_segment(grid, a, b, energy_per_m, color):
    """Deposit energy_per_m * length_in_voxel along segment a->b (3D DDA, Amanatides-Woo)."""
    p = (a - grid.origin) / grid.cell
    q = (b - grid.origin) / grid.cell
    d = q - p
    length_cells = np.linalg.norm(d)
    if length_cells < 1e-9:
        return
    ijk = np.floor(p).astype(int)
    step = np.sign(d).astype(int)
    with np.errstate(divide="ignore", invalid="ignore"):
        tdelta = np.where(d != 0, np.abs(1.0 / d), np.inf)
        nxt = np.where(step > 0, ijk + 1 - p, p - ijk)
        tmax = np.where(d != 0, nxt * tdelta, np.inf)
    t = 0.0
    seg_len_m = length_cells * grid.cell
    dims = np.array(grid.dims)
    while t < 1.0:
        t_next = min(tmax.min(), 1.0)
        if np.all(ijk >= 0) and np.all(ijk < dims):
            e = energy_per_m * (t_next - t) * seg_len_m
            grid.energy[tuple(ijk)] += e
            grid.color[tuple(ijk)] += e * color
        if t_next >= 1.0:
            break
        axis = int(np.argmin(tmax))
        ijk[axis] += step[axis]
        t = tmax[axis]
        tmax[axis] += tdelta[axis]


def build_field(grid, voxel_pos, voxel_rgb, sources, source_brightness, ambient_gain=1.0, beam_gain=1.0,
                inside_mask=None):
    Y = luminance(voxel_rgb)
    kelvin = cct_from_rgb(voxel_rgb)
    col = display_color(kelvin)
    y_amb = np.median(Y)
    excess = np.maximum(0.0, Y - 1.5 * y_amb)
    # source weights: brightness * area / d^2
    for v in np.nonzero(excess > 0)[0]:
        P = voxel_pos[v]
        w = np.array([source_brightness[k] * s.area / max(np.sum((P - s.center) ** 2), 0.05)
                      for k, s in enumerate(sources)])
        if w.sum() <= 0:
            continue
        w /= w.sum()
        for k, s in enumerate(sources):
            if w[k] < 0.05:
                continue
            per_point = beam_gain * excess[v] * w[k] / len(s.points)
            for a in s.points:
                raster_segment(grid, a, P, per_point, col[v])
    # ambient: uniform energy density in the room volume, colour = mean colour of the capture
    amb_col = display_color(np.median(kelvin))
    amb = ambient_gain * y_amb * grid.cell ** 3 * 40.0   # ambient energy density ∝ ambient luminance
    mask = inside_mask if inside_mask is not None else np.ones(grid.dims, bool)
    grid.energy[mask] += amb
    grid.color[mask] += amb * amb_col
    return grid


# ---------------------------------------------------------------- quantum sampling
def hash01(i, j, k, layer):
    h = (i * 73856093) ^ (j * 19349663) ^ (k * 83492791) ^ (layer * 2654435761)
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def quantum_sample(grid, quantum, layer=0, jitter=0.0):
    """Hierarchical: a cell with expected count n=sum/q > 1 is split into 8; otherwise it emits one
    splat with probability n at its centre. At the finest level at most one splat per cell."""
    E = grid.energy
    nx, ny, nz = E.shape
    size = 1
    while size < max(nx, ny, nz):
        size *= 2
    P = np.zeros((size, size, size)); P[:nx, :ny, :nz] = E
    C = np.zeros((size, size, size, 3)); C[:nx, :ny, :nz] = grid.color
    levels = [(P, C)]
    while levels[-1][0].shape[0] > 1:
        p, c = levels[-1]
        s = p.shape[0] // 2
        p2 = p.reshape(s, 2, s, 2, s, 2).sum((1, 3, 5))
        c2 = c.reshape(s, 2, s, 2, s, 2, 3).sum((1, 3, 5))
        levels.append((p2, c2))
    out_pos, out_col = [], []
    stack = [(len(levels) - 1, 0, 0, 0)]
    while stack:
        lev, i, j, k = stack.pop()
        p, c = levels[lev]
        e = p[i, j, k]
        if e <= 0:
            continue
        n = e / quantum
        if n > 1.0 and lev > 0:
            for di in (0, 1):
                for dj in (0, 1):
                    for dk in (0, 1):
                        stack.append((lev - 1, 2 * i + di, 2 * j + dj, 2 * k + dk))
            continue
        if hash01(i, j, k, layer * 31 + lev) < min(n, 1.0):
            cs = grid.cell * (2 ** lev)
            pos = grid.origin + (np.array([i, j, k]) + 0.5) * cs
            out_pos.append(pos)
            out_col.append(c[i, j, k] / e)
    return np.array(out_pos), np.array(out_col)
