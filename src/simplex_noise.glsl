// Simplex Noise Implementation for Infinite Terrain
// Samples from infinite global noise field using world-space coordinates
// Guarantees seamless tiling across infinite world

// === Hash Functions ===

// Hash an integer 2D grid position with seed for deterministic randomness
uint hash_uint(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

uint hash_int2(ivec2 p, int seed) {
    uint h = uint(seed);
    h = hash_uint(h ^ uint(p.x));
    h = hash_uint(h ^ uint(p.y));
    return h;
}

// Generate a deterministic 2D gradient vector for a grid corner
vec2 gradient_2d(ivec2 corner, int seed) {
    uint h = hash_int2(corner, seed);

    // Use hash to pick from 8 gradient directions
    uint index = h & 7u;
    float angle = float(index) * 0.78539816339; // 2*PI/8

    return vec2(cos(angle), sin(angle));
}

// === Simplex Noise ===

// 2D Simplex noise - returns value in range [-1, 1]
// world_pos: Global world coordinates (e.g., 2847.3, -1024.7)
// seed: Random seed for variation
float simplex_noise_2d(vec2 world_pos, int seed) {
    // Skew constants for 2D simplex
    const float F2 = 0.366025403784; // (sqrt(3) - 1) / 2
    const float G2 = 0.211324865405; // (3 - sqrt(3)) / 6

    // Skew input space to determine which simplex cell we're in
    float s = (world_pos.x + world_pos.y) * F2;
    vec2 skewed = world_pos + s;
    ivec2 i = ivec2(floor(skewed));

    // Unskew back to (x,y) space
    float t = float(i.x + i.y) * G2;
    vec2 unskewed = vec2(i) - t;
    vec2 d0 = world_pos - unskewed; // Distance from first corner

    // Determine which simplex we're in (lower or upper triangle)
    ivec2 i1 = (d0.x > d0.y) ? ivec2(1, 0) : ivec2(0, 1);

    // Offsets for other two corners
    vec2 d1 = d0 - vec2(i1) + G2;
    vec2 d2 = d0 - 1.0 + 2.0 * G2;

    // Calculate contribution from three corners
    float n0 = 0.0, n1 = 0.0, n2 = 0.0;

    // First corner
    float t0 = 0.5 - dot(d0, d0);
    if (t0 > 0.0) {
        t0 *= t0;
        vec2 g0 = gradient_2d(i, seed);
        n0 = t0 * t0 * dot(g0, d0);
    }

    // Second corner
    float t1 = 0.5 - dot(d1, d1);
    if (t1 > 0.0) {
        t1 *= t1;
        vec2 g1 = gradient_2d(i + i1, seed);
        n1 = t1 * t1 * dot(g1, d1);
    }

    // Third corner
    float t2 = 0.5 - dot(d2, d2);
    if (t2 > 0.0) {
        t2 *= t2;
        vec2 g2 = gradient_2d(i + ivec2(1, 1), seed);
        n2 = t2 * t2 * dot(g2, d2);
    }

    // Sum contributions and scale to [-1, 1]
    return 70.0 * (n0 + n1 + n2);
}

// === Fractal Brownian Motion ===

// Multi-octave noise for rich detail
// world_pos: Global world coordinates
// seed: Random seed
// frequency: Base frequency (e.g., 0.015 for large features)
// octaves: Number of octaves to sum (typically 2-4)
// lacunarity: Frequency multiplier per octave (typically 2.0)
// persistence: Amplitude multiplier per octave (typically 0.5)
float octave_noise(vec2 world_pos, int seed, float frequency, int octaves, float lacunarity, float persistence) {
    float value = 0.0;
    float amplitude = 1.0;
    float max_value = 0.0;
    float freq = frequency;

    for (int i = 0; i < octaves; i++) {
        // Sample noise at current frequency
        value += simplex_noise_2d(world_pos * freq, seed + i) * amplitude;

        // Track max for normalization
        max_value += amplitude;

        // Update for next octave
        amplitude *= persistence;
        freq *= lacunarity;
    }

    // Normalize to [-1, 1]
    return value / max_value;
}
