import Foundation

/// Ghostty's custom shaders a theme can name. Shadertoy's dialect: `iChannel0` is the terminal as drawn. Alpha goes through
/// untouched, so they work over a see-through background. Nothing here moves or bends: a shader that warps the screen puts
/// text away from where the mouse selects it.
enum TerminalShader {
    private static let sources = [
        // A phosphor screen: rows of light with dark between them, a glow round the text, the corners falling off.
        "crt": """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            vec4 color = texture(iChannel0, uv);
            vec3 glow = vec3(0.0);
            for (int x = -2; x <= 2; x++) for (int y = -2; y <= 2; y++) {
                vec2 offset = vec2(float(x), float(y)) * 2.5 / iResolution.xy;
                glow += texture(iChannel0, uv + offset).rgb;
            }
            vec3 rgb = color.rgb + glow / 25.0 * 0.45;
            rgb *= 0.86 + 0.14 * sin(fragCoord.y * 3.14159 / 2.0);
            vec2 edge = uv * (1.0 - uv);
            rgb *= clamp(pow(edge.x * edge.y * 40.0, 0.18), 0.0, 1.0);
            fragColor = vec4(rgb, color.a);
        }
        """,
        // Neon tubes: what's bright bleeds into the dark round it.
        "bloom": """
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy;
            vec4 color = texture(iChannel0, uv);
            vec3 glow = vec3(0.0);
            float total = 0.0;
            for (int x = -4; x <= 4; x++) for (int y = -4; y <= 4; y++) {
                float weight = exp(-float(x * x + y * y) / 8.0);
                vec3 near = texture(iChannel0, uv + vec2(float(x), float(y)) * 2.0 / iResolution.xy).rgb;
                glow += near * smoothstep(0.35, 0.9, max(near.r, max(near.g, near.b))) * weight;
                total += weight;
            }
            fragColor = vec4(color.rgb + glow / total * 1.1, color.a);
        }
        """
    ]

    /// The shader as a file, for Ghostty's config: nil for a name there's no shader of.
    static func file(_ name: String) -> String? {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-shader-\(name)-\(getpid()).glsl")
        guard let source = sources[name], FileManager.default.createFile(atPath: f.path, contents: Data(source.utf8)) else { return nil }
        return f.path
    }
}
