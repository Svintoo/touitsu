//! Stronger glass response using Knots' public material API.
const ui = @import("ui");

pub fn enhance(base: ui.Material, response: f32) ui.Material {
    var material = base;
    material.saturation += response * 0.6;
    material.refraction += response * 4;
    if (response > 0) material.bezel = @max(material.bezel, 12);
    material.specular += response * 0.35;
    material.dispersion += response * 0.04;
    return material;
}
