// v1.93: character surface shaders for RealityKit's CustomMaterial.
//   moonlightSkin  painted skins: base colour, roughness and detail normals from
//                  the textures; where the skin mask says skin, a subsurface
//                  approximation (light that went under the skin comes back
//                  warm, most at grazing angles) and a lower specular.
//   moonlightHair  hair: a Kajiya-Kay strand highlight (a bright primary band
//                  and a softer, hair-tinted secondary one) along the strands,
//                  which run down the surface.
// Approximations for a phone, not a full skin or hair BRDF. The app falls back
// to its standard PBR materials where CustomMaterial is unavailable.

#include <metal_stdlib>
#if __has_include(<RealityKit/RealityKit.h>)
#include <RealityKit/RealityKit.h>
using namespace metal;

// The direction from the surface towards the camera, whichever sign the
// renderer reports, taken on the side the normal faces.
static float3 moonlightToCamera(float3 n, float3 viewDirection) {
    float3 v = normalize(viewDirection);
    return dot(n, v) >= 0 ? v : -v;
}

[[visible]]
void moonlightSkin(realitykit::surface_parameters params)
{
    constexpr sampler s(address::repeat, filter::linear, mip_filter::linear);
    auto tex = params.textures();
    float2 uv = params.geometry().uv0();
    uv.y = 1.0 - uv.y;

    half3 base = tex.base_color().sample(s, uv).rgb * half3(params.material_constants().base_color_tint());
    half rough = tex.roughness().sample(s, uv).r * half(params.material_constants().roughness_scale());
    half skin = tex.custom().sample(s, uv).r;
    half3 detail = tex.normal().sample(s, uv).rgb * 2.0h - 1.0h;

    float3 n = normalize(params.geometry().normal());
    float3 v = moonlightToCamera(n, params.geometry().view_direction());
    half rim = half(pow(1.0 - saturate(dot(n, v)), 3.0));
    // Warm scattered light: a little everywhere on skin, more at the silhouette.
    half3 scatter = base * half3(1.0h, 0.38h, 0.26h) * (0.06h + 0.30h * rim) * skin;

    params.surface().set_base_color(base);
    params.surface().set_normal(float3(normalize(detail)));
    params.surface().set_roughness(clamp(rough, 0.05h, 1.0h));
    params.surface().set_metallic(0.0h);
    params.surface().set_specular(mix(0.5h, 0.35h, skin));
    params.surface().set_emissive_color(scatter);
    params.surface().set_ambient_occlusion(1.0h);
}

[[visible]]
void moonlightHair(realitykit::surface_parameters params)
{
    constexpr sampler s(address::repeat, filter::linear, mip_filter::linear);
    auto tex = params.textures();
    float2 uv = params.geometry().uv0();
    uv.y = 1.0 - uv.y;
    half3 base = tex.base_color().sample(s, uv).rgb * half3(params.material_constants().base_color_tint());

    float3 n = normalize(params.geometry().normal());
    float3 v = moonlightToCamera(n, params.geometry().view_direction());
    // Strands run down the surface.
    float3 down = float3(0.0, -1.0, 0.0);
    float3 t = down - n * dot(down, n);
    float tl = length(t);
    t = tl > 1e-3 ? t / tl : float3(1.0, 0.0, 0.0);
    // A key light above and in front of the viewer.
    float3 l = normalize(float3(0.0, 1.0, 0.0) + v);
    float3 h = normalize(l + v);
    float th = dot(t, h);
    float primary = pow(sqrt(max(0.0, 1.0 - th * th)), 80.0);
    float th2 = th + 0.12;
    float secondary = pow(sqrt(max(0.0, 1.0 - th2 * th2)), 16.0);
    half3 shine = half3(primary) * 0.22h + base * half(secondary) * 0.35h;

    params.surface().set_base_color(base);
    params.surface().set_roughness(0.6h);
    params.surface().set_metallic(0.0h);
    params.surface().set_specular(0.25h);
    params.surface().set_emissive_color(shine);
    params.surface().set_ambient_occlusion(1.0h);
}
#endif
