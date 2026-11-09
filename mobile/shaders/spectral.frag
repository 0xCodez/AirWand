// Prism spectral light field (Orbit). Rendered under black glass.
//
// Uniform layout (float index = FragmentShader.setFloat index):
//   0..1   uSize    : vec2  paint size in logical px
//   2      uTime    : float seconds (slows to 0 with reduced motion)
//   3      uIdle    : float 0..1 sleeping glow at the bottom edge
//   4..15  uC0..uC3 : vec3  active computer spectrum (0..1 rgb)
//   16..35 uL0..uL4 : vec4  light  (x, y, radius, intensity)
//   36..55 uV0..uV4 : vec4  motion (vx, vy, colour seed, 0)   px/s
//   56..71 uR0..uR3 : vec4  ripple (x, y, progress 0..1+, fade 0..1)
//   72..75 uSweep   : vec4  prism sweep (progress, dir +-1, envelope, 0)
//   76..79 uEdge    : vec4  edge bleed (focus x, focus y, strength, edge id)
//                           edge id: 0 left, 1 top, 2 right, 3 bottom
#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uIdle;
uniform vec3 uC0;
uniform vec3 uC1;
uniform vec3 uC2;
uniform vec3 uC3;
uniform vec4 uL0;
uniform vec4 uL1;
uniform vec4 uL2;
uniform vec4 uL3;
uniform vec4 uL4;
uniform vec4 uV0;
uniform vec4 uV1;
uniform vec4 uV2;
uniform vec4 uV3;
uniform vec4 uV4;
uniform vec4 uR0;
uniform vec4 uR1;
uniform vec4 uR2;
uniform vec4 uR3;
uniform vec4 uSweep;
uniform vec4 uEdge;

out vec4 fragColor;

const float TAU = 6.2831853;

// x*x. GLSL pow() is undefined for a negative base (NaN on Metal/Vulkan).
float sq(float x) {
  return x * x;
}

vec3 spec(float u) {
  float x = fract(u) * 4.0;
  float f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  if (x < 1.0) return mix(uC0, uC1, f);
  if (x < 2.0) return mix(uC1, uC2, f);
  if (x < 3.0) return mix(uC2, uC3, f);
  return mix(uC3, uC0, f);
}

vec3 hue(float h) {
  return clamp(abs(mod(h * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
}

// One finger light: an anisotropic gaussian stretched along its velocity,
// coloured by a slowly swirling slice of the spectrum.
void addLight(vec2 p, vec4 L, vec4 V, inout float field, inout vec3 col) {
  if (L.w <= 0.002) return;
  vec2 d = p - L.xy;
  float sp = length(V.xy);
  float st = 1.0 + clamp(sp / 700.0, 0.0, 1.0) * 1.3;
  vec2 dir = sp > 1.0 ? V.xy / sp : vec2(1.0, 0.0);
  float along = dot(d, dir);
  float perp = length(d - along * dir);
  float r = max(L.z, 1.0);
  float d2 = (along / st) * (along / st) + (perp * st) * (perp * st);
  float f = L.w * exp(-d2 / (r * r * 0.9));
  float ang = atan(d.y, d.x) / TAU;
  vec3 c = spec(ang + uTime * 0.18 + V.z * 0.27);
  c = mix(c, vec3(1.0), exp(-d2 / (r * r * 0.07)) * 0.45);
  field += f;
  col += c * f;
}

vec3 ripple(vec2 p, vec4 R) {
  if (R.w <= 0.002) return vec3(0.0);
  vec2 d = p - R.xy;
  float dist = length(d);
  float q = clamp(R.z, 0.0, 1.15);
  float rad = 9.0 + q * 70.0;
  float w = 3.0 + 9.0 * (1.0 - min(q, 1.0));
  float ring = exp(-sq((dist - rad) / w)) * R.w * 0.55;
  vec3 c = spec(atan(d.y, d.x) / TAU + uTime * 0.35);
  float flash = exp(-dist * dist / (26.0 * 26.0)) * R.w * R.w * R.w * 0.45;
  return c * ring + mix(c, vec3(1.0), 0.45) * flash;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float w = uSize.x;
  float h = uSize.y;

  float field = 0.0;
  vec3 col = vec3(0.0);
  addLight(p, uL0, uV0, field, col);
  addLight(p, uL1, uV1, field, col);
  addLight(p, uL2, uV2, field, col);
  addLight(p, uL3, uV3, field, col);
  addLight(p, uL4, uV4, field, col);

  vec3 rgb = vec3(0.0);
  if (field > 0.0005) {
    // Metaball merge: overlapping fields lift into one gooey plateau.
    float shaped = field + 0.55 * smoothstep(0.32, 0.95, field);
    rgb += (col / field) * shaped * 0.85;
  }

  // Edge bleed toward the nearest border of the light's centre of mass.
  if (uEdge.z > 0.002) {
    float e;
    float a;
    if (uEdge.w < 0.5) { e = p.x; a = p.y - uEdge.y; }
    else if (uEdge.w < 1.5) { e = p.y; a = p.x - uEdge.x; }
    else if (uEdge.w < 2.5) { e = w - p.x; a = p.y - uEdge.y; }
    else { e = h - p.y; a = p.x - uEdge.x; }
    float g = uEdge.z * exp(-e / 20.0) * exp(-(a * a) / (170.0 * 170.0));
    rgb += spec(a / 420.0 + uTime * 0.1) * g * 0.7;
  }

  // Sleeping glow: three spectral pools breathing at the bottom edge.
  if (uIdle > 0.002) {
    float breath = 0.78 + 0.22 * sin(uTime * 0.9);
    float db = h - p.y;
    float fall = exp(-db / (h * 0.11));
    for (int i = 0; i < 3; i++) {
      float fi = float(i);
      float x = w * (0.3 + 0.2 * fi) + sin(uTime * 0.37 + fi * 2.1) * w * 0.12;
      float g = exp(-sq(p.x - x) / (w * w * 0.05)) * fall;
      vec3 c = i == 0 ? uC0 : (i == 1 ? uC2 : uC3);
      rgb += c * g * uIdle * breath * 0.5;
    }
  }

  rgb += ripple(p, uR0);
  rgb += ripple(p, uR1);
  rgb += ripple(p, uR2);
  rgb += ripple(p, uR3);

  // Prism sweep: seven dispersed bands crossing the pad.
  if (uSweep.z > 0.002) {
    float dir = uSweep.y;
    float u = clamp(uSweep.x, 0.0, 1.0);
    float x = dir > 0.0 ? mix(w * 1.3, -w * 0.3, u) : mix(-w * 0.3, w * 1.3, u);
    x += (p.y / h - 0.5) * h * 0.1 * dir;
    float disp = 8.0 + 30.0 * uSweep.z;
    for (int i = 0; i < 7; i++) {
      float fi = float(i);
      float bx = x + (fi - 3.0) * disp * -dir;
      float band = exp(-sq((p.x - bx) / (w * 0.045)));
      rgb += hue(fi / 7.0 * 0.82) * band * uSweep.z * 0.75;
    }
    rgb += vec3(1.0) * exp(-sq((p.x - x) / (w * 0.02))) * uSweep.z * 0.3;
  }

  rgb = vec3(1.0) - exp(-rgb * 1.25);
  float alpha = clamp(max(rgb.r, max(rgb.g, rgb.b)), 0.0, 1.0);
  fragColor = vec4(rgb, alpha);
}
