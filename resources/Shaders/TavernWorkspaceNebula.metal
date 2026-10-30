struct NebulaParticle { float4 origin; float4 motion; float4 colour; };
constant NebulaParticle nebulaParticles[30] = {
    {float4(420.00000000f, 205.84514597f, 0.38869205f, 3.99754532f), float4(6.95523991f, -22.18039352f, 0.64640004f, 4.57868430f), float4(1.00000000f, 0.82352941f, 0.57647059f, 0.00000000f)},
    {float4(230.67307771f, 134.01747332f, 4.88683109f, 2.71993606f), float4(6.59449168f, -11.11933705f, 0.76777717f, 1.42944911f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(121.65331432f, 127.85547563f, 1.96921832f, 2.86992674f), float4(-6.11659632f, -23.78611434f, 0.42071405f, 1.98711466f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(204.20131759f, 134.42935157f, 0.93335815f, 1.58579346f), float4(-2.19358424f, -9.28390530f, 0.68484906f, 1.75016062f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(174.89187085f, 128.72065138f, 9.84689663f, 3.49314752f), float4(5.10004297f, -10.01764768f, 0.86949893f, 0.53341680f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(145.69282384f, 127.99553219f, 6.19215262f, 2.79966199f), float4(-5.68071821f, -11.35028705f, 0.36336576f, 2.43126620f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(256.54321768f, 136.91217996f, 8.13564910f, 2.42104828f), float4(-1.97098359f, -20.25902677f, 0.52486908f, 2.04334818f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(420.00000000f, 170.08148854f, 1.87793759f, 3.10566110f), float4(-0.80436469f, -11.66259997f, 0.87778286f, 3.99120890f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(92.89716044f, 135.89084776f, 3.60972322f, 3.22416587f), float4(-6.94020276f, -10.00212069f, 0.66372290f, 1.54021771f), float4(1.00000000f, 0.82352941f, 0.57647059f, 0.00000000f)},
    {float4(19.00000000f, 196.38538394f, 0.62472088f, 2.97292640f), float4(-2.44074763f, -23.82486304f, 0.50953469f, 5.57703206f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(167.17793210f, 131.04616790f, 2.01629788f, 1.64699845f), float4(-4.02589235f, -22.91563987f, 0.48127891f, 1.74587138f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(221.01931981f, 135.19769089f, 5.47862189f, 2.86604653f), float4(3.16848212f, -19.51479091f, 0.55819497f, 3.27026894f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(308.57124685f, 136.76716350f, 8.56465999f, 2.25875658f), float4(8.21980271f, -17.20279103f, 0.65519576f, 5.61449484f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(373.72722215f, 130.34381722f, 1.77232554f, 2.13426500f), float4(-5.06684255f, -16.13531037f, 0.64565670f, 1.18446224f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(420.00000000f, 154.88379640f, 3.86117386f, 2.19568986f), float4(0.04732334f, -22.33462380f, 0.65263449f, 6.10818408f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(84.73088861f, 133.33538595f, 7.18243581f, 3.08090285f), float4(-6.11849459f, -15.14716865f, 0.53972135f, 0.80386883f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(68.17276813f, 128.27898082f, 1.94643355f, 3.91433027f), float4(-0.45254675f, -9.66622690f, 0.67970702f, 3.23356056f), float4(1.00000000f, 0.82352941f, 0.57647059f, 0.00000000f)},
    {float4(85.52920654f, 135.17383690f, 9.51602489f, 2.42359989f), float4(-3.92426596f, -19.06272752f, 0.93117391f, 5.39251355f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(19.00000000f, 179.98227500f, 6.96321098f, 1.77887947f), float4(8.51707873f, -20.20005719f, 0.67407887f, 5.63838939f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(119.63104171f, 135.08752384f, 0.19739628f, 2.34926923f), float4(-5.73164835f, -16.25163682f, 0.49428596f, 5.27224410f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(316.60938789f, 134.52779952f, 2.81540366f, 2.03303230f), float4(-0.48431971f, -23.10415505f, 0.97804509f, 5.91273536f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(420.00000000f, 159.81499443f, 7.74337497f, 2.39402557f), float4(-1.75001249f, -20.18058691f, 0.96750598f, 1.93832686f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(99.46818864f, 128.57911164f, 1.26522606f, 2.19304371f), float4(3.00271158f, -13.09861935f, 0.96519582f, 2.67694373f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(350.10303451f, 133.67632896f, 3.69358763f, 1.82803716f), float4(2.84577972f, -12.20814291f, 0.46596851f, 1.79101249f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(124.00704971f, 137.98154665f, 8.66960729f, 1.60685677f), float4(0.77176472f, -17.69937367f, 0.58273308f, 5.60577460f), float4(1.00000000f, 0.82352941f, 0.57647059f, 0.00000000f)},
    {float4(260.32490281f, 129.25624503f, 2.60115627f, 2.00108018f), float4(-1.21443155f, -21.84944174f, 0.74773755f, 3.83919858f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(235.83065694f, 134.00427505f, 3.19798572f, 3.88526966f), float4(2.29895317f, -11.80364132f, 0.83141659f, 3.36924563f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(19.00000000f, 200.04625234f, 9.29792510f, 1.78297072f), float4(8.51385524f, -18.80006463f, 0.56761515f, 4.96954912f), float4(0.59215686f, 0.84313725f, 1.00000000f, 0.00000000f)},
    {float4(420.00000000f, 216.59987213f, 5.47202343f, 2.03869159f), float4(-0.32071063f, -15.46250131f, 0.50340014f, 3.03556834f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)},
    {float4(379.19266131f, 135.23618144f, 9.55861110f, 3.87453868f), float4(6.01946571f, -15.47161895f, 0.84986001f, 3.67877767f), float4(0.88235294f, 0.72549020f, 1.00000000f, 0.00000000f)}
};

struct WorkspaceNebulaUniforms { float4 geometry; float4 timing; float4 clip; float4 tint; };
float nebulaGlow(float d) {
    if (d >= 1.0f) return 0.0f;
    return d < .28f ? mix(1.0f, .54f, d / .28f) : .54f * (1.0f - (d - .28f) / .72f);
}
fragment float4 tavernWorkspaceNebulaFragment(CardVertex in [[stage_in]],
    constant WorkspaceNebulaUniforms &u [[buffer(0)]],
    constant NebulaLighting &lights [[buffer(1)]], texture2d<float> atlas [[texture(0)]]) {
    float2 point = in.uv * u.geometry.xy - u.timing.z;
    float2 size = u.geometry.zw;
    float2 edges = min(point, size - point);
    float distance = min(min(edges.x, edges.y), (edges.x + edges.y - 4.5f) * .7071068f) - .7f;
    float exterior = 1.0f - smoothstep(-1.0f, 1.0f, distance);
    if (exterior <= 0.0f) return float4(0);
    float2 reference = float2(22.5f, 138.5f) + point / size * float2(394.5f, 90.5f);
    float2 frameUV = (reference - float2(0, 85)) / float2(444, 180);
    float frame = u.timing.y;
    float2 cell = float2(fmod(frame, 16.0f), floor(frame / 16.0f));
    float2 safeUV = clamp(frameUV, .5f / float2(444, 180), 1.0f - .5f / float2(444, 180));
    float4 cloud = atlas.sample(cardSampler, (cell + safeUV) / float2(16, 15));
    cloud *= float(all(frameUV >= 0.0f) && all(frameUV <= 1.0f));
    // The atlas deliberately omits the old screenshot contour. Restore only its
    // soft density envelope around the native point-space bevel, never a box.
    float pointScale = min(size.x / 394.5f, size.y / 90.5f);
    float outsideDistance = max(-distance, 0.0f) / max(pointScale, .001f);
    float falloff = 18.0f + 24.0f * (1.0f - smoothstep(130.0f, 154.0f, reference.y))
        + 5.0f * smoothstep(218.0f, 236.0f, reference.y);
    float densityFade = 1.0f - smoothstep(2.0f, falloff, outsideDistance);
    float densityEdge = smoothstep(3.0f, 13.0f, reference.x)
        * (1.0f - smoothstep(431.0f, 441.0f, reference.x))
        * smoothstep(88.0f, 100.0f, reference.y)
        * (1.0f - smoothstep(245.0f, 255.0f, reference.y));
    cloud *= densityFade * densityEdge;
    if (u.tint.w > 0.0f) {
        // Тихая завеса у плеч карточки вместо яркого полного венца пространства.
        float shoulder = .35f + .65f * (1.0f - smoothstep(138.5f, 208.0f, reference.y));
        float reach = 1.0f - smoothstep(3.0f, 21.0f, outsideDistance);
        float luminance = dot(cloud.rgb, float3(.2126f, .7152f, .0722f));
        float3 colour = mix(u.tint.rgb, float3(1), .18f) * luminance;
        float2 viewPoint = in.uv * u.geometry.xy;
        float2 viewEdges = min(viewPoint - u.clip.xy, u.clip.zw - viewPoint);
        float coverage = exterior * smoothstep(0.0f, 3.0f, min(viewEdges.x, viewEdges.y))
            * shoulder * reach * u.tint.w;
        return float4(colour, cloud.a) * coverage;
    }
    // Atlas is premultiplied. Screen-composite the approved accents, retaining cloud density.
    float3 accent = float3(0);
    float accentAlpha = 0;
    float mask = smoothstep(5.0f, 14.0f, reference.x) * (1.0f - smoothstep(430.0f, 439.0f, reference.x))
        * smoothstep(89.0f, 102.0f, reference.y) * (1.0f - smoothstep(242.0f, 254.0f, reference.y));
    for (int i = 0; i < 7; ++i) {
        NebulaLight s = lights.lights[i];
        float glow = nebulaGlow(length(point - s.position.xy) / max(s.colour.w, .001f)) * s.position.w;
        float3 lightColour = pow(s.colour.rgb, float3(1.0f / 2.2f));
        accent = lightColour * glow + accent * (1.0f - glow);
        accentAlpha = glow + accentAlpha * (1.0f - glow);
    }
    accent *= cloud.a;
    accentAlpha *= cloud.a;
    for (int i = 0; i < 30; ++i) {
        NebulaParticle p = nebulaParticles[i];
        float age = fmod(u.timing.x - p.origin.z + 10.0f, 10.0f);
        if (age >= p.origin.w) continue;
        float t = age / p.origin.w;
        float opacity = pow(sin(M_PI_F * t), 1.4f) * (.65f + .35f * pow(sin(age * 9.0f + p.motion.w), 2.0f));
        float2 center = p.origin.xy + p.motion.xy * t + float2(2.0f * sin(t * 3.0f + p.motion.w), 0);
        float2 delta = reference - center;
        float glow = nebulaGlow(length(delta) / (p.motion.z * 4.0f)) * opacity * .45f;
        float2 ellipse = float2(delta.x * .968912f - delta.y * .247404f, delta.x * .247404f + delta.y * .968912f);
        float core = (1.0f - smoothstep(.7f, 1.2f, length(ellipse / (p.motion.z * float2(1, 1.25f))))) * opacity * .9f;
        float a = 1.0f - (1.0f - glow) * (1.0f - core);
        accent = p.colour.rgb * a + accent * (1.0f - a);
        accentAlpha = a + accentAlpha * (1.0f - a);
    }
    accent *= mask;
    accentAlpha *= mask;
    float3 colour = cloud.rgb + accent - cloud.rgb * accent;
    float alpha = cloud.a + accentAlpha - cloud.a * accentAlpha;
    // Затухание учитывает реальный viewport, а не только собственные bounds декора.
    float2 viewPoint = in.uv * u.geometry.xy;
    float2 viewEdges = min(viewPoint - u.clip.xy, u.clip.zw - viewPoint);
    float envelope = smoothstep(0.0f, 3.0f, min(viewEdges.x, viewEdges.y));
    float coverage = exterior * envelope;
    return float4(colour * coverage, alpha * coverage);
}
