#include <metal_stdlib>
using namespace metal;

// MARK: - Camera background

struct CameraUniforms {
    float2 uv[4];      // captured-image texture coordinates of the 4 screen corners (strip order)
    float dim;         // camera brightness, 0…1
    float pad;
};

struct CameraOut {
    float4 position [[position]];
    float2 uv;
};

vertex CameraOut cameraVertex(uint vid [[vertex_id]], constant CameraUniforms& u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    CameraOut o;
    o.position = float4(corners[vid], 0, 1);
    o.uv = u.uv[vid];
    return o;
}

fragment float4 cameraFragment(CameraOut in [[stage_in]],
                               constant CameraUniforms& u [[buffer(0)]],
                               texture2d<float> texY [[texture(0)]],
                               texture2d<float> texCbCr [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Full-range BT.601, as delivered by ARKit.
    const float4x4 ycbcrToRGB = float4x4(float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
                                         float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
                                         float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
                                         float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
    float4 ycbcr = float4(texY.sample(s, in.uv).r, texCbCr.sample(s, in.uv).rg, 1.0);
    float3 rgb = (ycbcrToRGB * ycbcr).rgb;
    return float4(saturate(rgb) * u.dim, 1);
}

// MARK: - Splats: every splat is the same gaussian; only its colour (light temperature) differs.

struct GPUSplat {
    float4 positionLayer;   // xyz world position, w = layer (capture index)
    float4 color;           // rgb display colour
};

struct SplatUniforms {
    float4x4 viewProjection;
    float4x4 view;
    float4x4 worldToCamera;     // ARKit camera space of the captured image (for LiDAR occlusion)
    float4 intrinsics;          // fx, fy, cx, cy (captured-image pixels)
    float2 imageSize;
    float2 viewport;            // render target size, pixels
    float focalPixels;          // projection[1][1] · viewport.y / 2
    float sigma;                // gaussian sigma, metres (identical for all splats)
    float opacity;              // peak opacity (identical for all splats)
    float minPixels;            // far splats never get smaller than this (pixels)
    float nearStart;            // splats closer than this to the eye are hidden…
    float nearEnd;              // …and fade in up to this distance
    float occlusion;            // 1 = hide splats behind real surfaces (LiDAR), 0 = off
    uint layerCount;
    float4 cameraPush;          // camera position, w = push strength 0…1 (how fast the phone moves)
    float revealTime;           // seconds since the light started to be drawn in; huge = fully drawn
    float revealSpeed;          // metres per second of the drawing front along the rays
    float pushRadius;           // metres around the phone
    float pushAmount;           // largest displacement, metres
};

struct SplatOut {
    float4 position [[position]];
    float2 local;       // offset from the centre, in sigmas
    float3 color;       // colour × weight
};

vertex SplatOut splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device GPUSplat* splats [[buffer(0)]],
                            constant SplatUniforms& u [[buffer(1)]],
                            constant float* layerWeights [[buffer(2)]],
                            texture2d<float> sceneDepth [[texture(0)]]) {
    SplatOut o;
    o.position = float4(0, 0, 2, 1);   // outside the clip volume: culled
    o.local = float2(0);
    o.color = float3(0);

    GPUSplat s = splats[iid];
    uint layer = uint(s.positionLayer.w + 0.5);
    float w = layer < u.layerCount ? layerWeights[layer] : 0.0;
    if (w < 0.002) { return o; }

    // Splats near a moving phone move slightly aside (straight away from it), and drift back when it stops.
    float3 position = s.positionLayer.xyz;
    if (u.cameraPush.w > 0.001) {
        float3 away = position - u.cameraPush.xyz;
        float d = length(away);
        if (d < u.pushRadius && d > 1e-4) {
            position += away / d * (u.pushAmount * u.cameraPush.w * (1.0 - d / u.pushRadius));
        }
    }

    // Drawing the light in: a front runs out of every source along its rays; ambient light follows.
    float reveal = 1.0;
    if (u.revealTime < 1e5) {
        float key = s.color.w;
        if (key >= 0.0) {
            reveal = saturate((u.revealTime * u.revealSpeed - key) / 0.25);
        } else {
            float start = 0.6 + (-key) * 2.4;
            reveal = saturate((u.revealTime - start) / 0.4);
        }
    }
    if (reveal < 0.002) { return o; }

    float4 world = float4(position, 1);
    float z = -(u.view * world).z;
    if (z < u.nearStart) { return o; }
    float fade = saturate((z - u.nearStart) / max(u.nearEnd - u.nearStart, 1e-3));

    // Occlusion by real geometry: compare with the LiDAR depth under the splat centre.
    float visibility = 1.0;
    if (u.occlusion > 0.5) {
        float4 c = u.worldToCamera * world;
        float d = -c.z;
        if (d > 0.05) {
            float2 px = float2(u.intrinsics.z + u.intrinsics.x * c.x / d, u.intrinsics.w - u.intrinsics.y * c.y / d);
            float2 uv = px / u.imageSize;
            if (all(uv >= 0.0) && all(uv <= 1.0)) {
                constexpr sampler ds(filter::nearest, address::clamp_to_edge);
                float surface = sceneDepth.sample(ds, uv, level(0)).r;
                if (surface > 0.05) {
                    visibility = 1.0 - smoothstep(0.06, 0.25, d - surface);
                }
            }
        }
    }
    float weight = u.opacity * w * fade * visibility * reveal;
    if (weight < 1e-4) { return o; }

    float radius = max(u.focalPixels * u.sigma / z, u.minPixels);
    const float extent = 3.0;   // quad covers ±3 sigma
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float4 clip = u.viewProjection * world;
    clip.xy += corner * extent * radius * 2.0 / u.viewport * clip.w;
    o.position = clip;
    o.local = corner * extent;
    o.color = s.color.rgb * weight;
    return o;
}

fragment half4 splatFragment(SplatOut in [[stage_in]]) {
    float g = exp(-0.5 * dot(in.local, in.local));
    return half4(half3(in.color * g), 0);
}

// MARK: - Composite: tonemap the accumulated light, screen-blend it over the camera.

struct CompositeUniforms {
    float exposure;
    float pad0;
    float pad1;
    float pad2;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    FullscreenOut o;
    o.position = float4(corners[vid], 0, 1);
    o.uv = float2(corners[vid].x * 0.5 + 0.5, 0.5 - corners[vid].y * 0.5);
    return o;
}

fragment float4 compositeFragment(FullscreenOut in [[stage_in]],
                                  constant CompositeUniforms& u [[buffer(0)]],
                                  texture2d<half> light [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 a = float3(light.sample(s, in.uv).rgb);
    float3 t = 1.0 - exp(-u.exposure * a);
    t = pow(max(t, 0.0), float3(1.0 / 2.2));
    return float4(t, 1);   // blend: result = t + camera · (1 − t)
}

// MARK: - Markers (UI only: marked lamps and windows)

struct MarkerPoint {
    float4 positionSize;   // xyz world, w = point size in pixels
    float4 color;
};

struct MarkerOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex MarkerOut markerVertex(uint vid [[vertex_id]],
                              const device MarkerPoint* points [[buffer(0)]],
                              constant float4x4& viewProjection [[buffer(1)]]) {
    MarkerPoint p = points[vid];
    MarkerOut o;
    o.position = viewProjection * float4(p.positionSize.xyz, 1);
    o.pointSize = p.positionSize.w;
    o.color = p.color;
    return o;
}

fragment float4 markerFragment(MarkerOut in [[stage_in]], float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;           // 0 at centre, 1 at the edge
    float ring = (1.0 - smoothstep(0.85, 1.0, r)) * smoothstep(0.45, 0.6, r);
    float centre = 1.0 - smoothstep(0.15, 0.25, r);
    float a = max(ring, centre);
    if (a < 0.01) { discard_fragment(); }
    return float4(in.color.rgb, in.color.a * a);
}

// MARK: - Scan preview (UI only: surfaces scanned so far, coloured by the light falling on them)

fragment float4 scanFragment(MarkerOut in [[stage_in]], float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;
    float a = 1.0 - smoothstep(0.4, 1.0, r);
    if (a < 0.01) { discard_fragment(); }
    return float4(in.color.rgb, in.color.a * a);
}
