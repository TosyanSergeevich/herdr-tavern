#include <metal_stdlib>
using namespace metal;

// Coordinates: X right, Y down, Z out; all data textures are premultiplied,
// linear UNORM. Only albedo is explicitly converted from sRGB.
struct CardUniforms {
    float4 geometry; // scene width/height; normal X/Y correction (point-space maps: 1)
    float4 lamp;     // scene-space XYZ; flicker
    float4 magicPosition; // XYZ + strength of the talisman's actual moving light
    float4 magicColour; // RGB: talisman light; W: steady selection illumination
};
struct CardVertex { float4 position [[position]]; float2 uv; };
vertex CardVertex tavernCardVertex(uint id [[vertex_id]]) {
    const float2 points[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    CardVertex out;
    out.position = float4(points[id], 0, 1);
    out.uv = float2((points[id].x + 1) * .5, (1 - points[id].y) * .5);
    return out;
}
constexpr sampler cardSampler(coord::normalized, address::clamp_to_edge, filter::linear);
float4 straightSample(texture2d<float> map, float2 uv) {
    float4 sample = map.sample(cardSampler, uv);
    return float4(sample.rgb / max(sample.a, .0001f), sample.a);
}
float heightAt(texture2d<float> map, float2 uv) {
    // Outside this card there is no invented clamp-to-edge blocker.
    if (any(uv < 0.0f) || any(uv > 1.0f)) return 0;
    return straightSample(map, uv).r * 32.0f;
}
float visibility(texture2d<float> heights, float3 p, float3 lamp, float2 size) {
    float2 travel = lamp.xy - p.xy;
    float result = 1;
    // Quadratic spacing resolves the bookmark and narrow nearby bronze rim.
    for (int i = 1; i <= 96; ++i) {
        float t = float(i) / 97.0f; t *= t;
        float rayZ = mix(p.z + .42f, lamp.z, t);
        if (rayZ > 32.5f || result < .01f) break;
        float2 q = (p.xy + travel * t) / size;
        float clearance = rayZ - heightAt(heights, q);
        float penumbra = .28f + .6f * min(length(travel) * t * .035f, 4.0f);
        result = min(result, smoothstep(-penumbra, penumbra, clearance));
    }
    return result;
}
// Локальная тень от кромки/ступеньки под общим верхним светом.
// Четыре близкие пробы не добавляют второй длинный проход трассировки.
float overheadVisibility(texture2d<float> heights, float3 p, float3 light, float2 size) {
    float result = 1;
    for (int i = 0; i < 4; ++i) {
        float reach = 1.5f * float(1 << i);
        float2 q = (p.xy + light.xy * reach) / size;
        float clearance = p.z + light.z * reach - heightAt(heights, q);
        result = min(result, smoothstep(-.35f, .75f, clearance));
    }
    return mix(.45f, 1.0f, result);
}
fragment float4 tavernCardFragment(CardVertex in [[stage_in]],
    constant CardUniforms &u [[buffer(0)]],
    texture2d<float> albedo [[texture(0)]], texture2d<float> heights [[texture(1)]],
    texture2d<float> normals [[texture(2)]], texture2d<float> materials [[texture(3)]]) {
    float4 source = straightSample(albedo, in.uv);
    if (source.a < .001f) return float4(0);
    float2 size = u.geometry.xy;
    float2 dx = float2(1.0f / size.x, 0), dy = float2(0, 1.0f / size.y);
    float z = heightAt(heights, in.uv);
    float3 geometric = normalize(float3(-(heightAt(heights, in.uv + dx) - heightAt(heights, in.uv - dx)) * .5f,
        -(heightAt(heights, in.uv + dy) - heightAt(heights, in.uv - dy)) * .5f, 1));
    float3 detail = straightSample(normals, in.uv).rgb * 2.0f - 1.0f;
    detail = normalize(float3(detail.xy * u.geometry.zw, max(.12f, detail.z)));
    float3 n = normalize(mix(geometric, detail, .72f));
    float3 p = float3(in.uv * size, z);
    float3 delta = u.lamp.xyz - p;
    float3 light = normalize(delta);
    float shadow = visibility(heights, p, u.lamp.xyz, size);
    float nearOccluder = max(max(heightAt(heights, in.uv + dx * 4), heightAt(heights, in.uv - dx * 4)),
        max(heightAt(heights, in.uv + dy * 4), heightAt(heights, in.uv - dy * 4))) - z;
    float ao = 1 - .2f * smoothstep(.4f, 7.0f, nearOccluder);
    float3 base = source.rgb;
    float3 linearBase = pow(base, float3(2.2f));
    float3 material = straightSample(materials, in.uv).rgb;
    float rough = clamp(material.r, .12f, .98f);
    float3 colour = linearBase * .30f * ao;
    // A broad, restrained ceiling source keeps remote bevels legible. Unlike a
    // uniform stroke it lights upward-facing chamfers, not the lower-facing lip.
    const float3 overhead = normalize(float3(-.24f, -.78f, .58f));
    float overheadDiffuse = max(dot(n, overhead), 0.0f);
    float3 overheadHalf = normalize(overhead + float3(0, 0, 1));
    float overheadSpecular = pow(max(dot(n, overheadHalf), 0.0f), mix(64.0f, 8.0f, rough));
    float overheadShadow = overheadVisibility(heights, p, overhead, size);
    colour += (linearBase * overheadDiffuse * .95f
        + overheadSpecular * (.008f + material.g * .22f))
        * float3(1, .86f, .67f) * ao * overheadShadow;
    float attenuation = 1 / (1 + dot(delta, delta) / (240.0f * 240.0f));
    float diffuse = max(dot(n, light), 0.0f);
    float3 halfVector = normalize(light + float3(0, 0, 1));
    float specular = pow(max(dot(n, halfVector), 0.0f), mix(95.0f, 6.0f, rough)) * (.03f + material.g * .35f) * .8f;
    colour += (linearBase * diffuse * float3(1, .48f, .14f)
        + specular * mix(float3(1, .66f, .28f), base, material.g * .5f)) * attenuation * 2.4f * u.lamp.w * shadow;
    float3 magicDelta = u.magicPosition.xyz - p;
    float magicFalloff = 1 / (1 + dot(magicDelta, magicDelta) / 700.0f);
    colour += linearBase * u.magicColour.rgb * .8f * u.magicPosition.w * magicFalloff
        * max(dot(n, normalize(magicDelta)), 0.0f) * 1.8f;
    float3 emissionColour = base / max(max(base.r, max(base.g, base.b)), .05f);
    float lampRegion = exp(-dot(p.xy - u.lamp.xy, p.xy - u.lamp.xy) / 2200.0f);
    colour += emissionColour * material.b * lampRegion * 2.4f * .32f * (u.lamp.w > 0 ? 1.0f : 0.0f);
    // Selection lights the existing bronze and wood, without changing card geometry.
    float metal = smoothstep(.35f, .65f, material.g);
    float2 edgeDistances = min(p.xy, size - p.xy);
    float edgeDistance = min(min(edgeDistances.x, edgeDistances.y),
        (edgeDistances.x + edgeDistances.y - 8.0f) * .7071f);
    float innerGlow = exp(-max(edgeDistance, 0.0f) / 12.0f);
    colour += u.magicColour.w * (float3(1, .56f, .18f)
        * ((.06f + .14f * overheadDiffuse) * metal + .04f * innerGlow)
        + linearBase * float3(.24f, .12f, .035f));
    colour = pow(max(colour, float3(0)), float3(1.0f / 2.2f));
    return float4(colour * source.a, source.a);
}
