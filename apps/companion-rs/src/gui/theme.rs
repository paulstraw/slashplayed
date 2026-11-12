// The window's look: egui's dark theme in the launcher's colors (apps/client/spstyle.swift: its ground,
// gold, and well), and Goodmountain for the titles and the main button only, the default face for the rest
// (easier to read, and with more characters).
//
// Goodmountain's license allows shipping the file unchanged and forbids modifying or renaming it
// (scripts/fetch-font.sh), so the archive carries Goodmountain-Regular.otf as its own file beside the
// program, and it's read from there at run time, never compiled in. Missing, the default face takes its
// place.

use eframe::egui;
use std::path::{Path, PathBuf};

use egui::{Color32, FontData, FontDefinitions, FontFamily, RichText, Stroke, Visuals};

pub const GROUND: Color32 = Color32::from_rgb(0x10, 0x19, 0x16);
pub const GOLD: Color32 = Color32::from_rgb(0xAC, 0x9D, 0x79);
/// A field's face: the ground lifted a little toward the medallion's green.
pub const WELL: Color32 = Color32::from_rgb(0x17, 0x24, 0x20);
/// Body text: a warm off-white that sits on the ground and the well.
pub const TEXT: Color32 = Color32::from_rgb(0xE4, 0xDF, 0xD2);
pub const DIM: Color32 = Color32::from_rgb(0x9A, 0xA3, 0x9E);
pub const ERROR: Color32 = Color32::from_rgb(0xE0, 0x8A, 0x7A);

pub const FONT_FILE: &str = "Goodmountain-Regular.otf";
const FACE: &str = "goodmountain";

/// Where the face is looked for: beside the program, and in a development build also in work/fonts
/// (scripts/fetch-font.sh), so a cargo run from the repo has it.
fn font_paths() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) {
        out.push(dir.join(FONT_FILE));
    }
    if cfg!(debug_assertions) {
        out.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../work/fonts").join(FONT_FILE));
    }
    out
}

/// Applies the colors and, when its file is there, Goodmountain. Says whether it was.
pub fn apply(ctx: &egui::Context) -> bool {
    ctx.set_theme(egui::ThemePreference::Dark);
    let mut v = Visuals::dark();
    v.panel_fill = GROUND;
    v.window_fill = WELL;
    v.extreme_bg_color = WELL;
    v.faint_bg_color = WELL;
    v.code_bg_color = WELL;
    v.hyperlink_color = GOLD;
    v.override_text_color = Some(TEXT);
    v.selection.bg_fill = GOLD.linear_multiply(0.45);
    v.selection.stroke = Stroke::new(1.0, GOLD);
    v.window_stroke = Stroke::new(1.0, GOLD.linear_multiply(0.5));
    let lifted = Color32::from_rgb(0x1F, 0x30, 0x2A);
    let hover = Color32::from_rgb(0x28, 0x3D, 0x36);
    for (w, fill) in [
        (&mut v.widgets.noninteractive, GROUND),
        (&mut v.widgets.inactive, lifted),
        (&mut v.widgets.hovered, hover),
        (&mut v.widgets.active, hover),
        (&mut v.widgets.open, lifted),
    ] {
        w.bg_fill = fill;
        w.weak_bg_fill = fill;
    }
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, lifted);
    v.widgets.inactive.bg_stroke = Stroke::new(1.0, GOLD.linear_multiply(0.35));
    v.widgets.hovered.bg_stroke = Stroke::new(1.0, GOLD);
    v.widgets.active.bg_stroke = Stroke::new(1.0, GOLD);
    ctx.set_visuals_of(egui::Theme::Dark, v);
    ctx.style_mut_of(egui::Theme::Dark, |s| {
        s.spacing.item_spacing = egui::vec2(8.0, 8.0);
        s.spacing.button_padding = egui::vec2(10.0, 5.0);
        for (style, size) in [(egui::TextStyle::Body, 15.0), (egui::TextStyle::Button, 15.0), (egui::TextStyle::Small, 12.0)] {
            if let Some(f) = s.text_styles.get_mut(&style) {
                f.size = size;
            }
        }
    });

    let Some(bytes) = font_paths().into_iter().find_map(|p| std::fs::read(p).ok()) else { return false };
    let mut fonts = FontDefinitions::default();
    fonts.font_data.insert(FACE.into(), FontData::from_owned(bytes).into());
    // Goodmountain first, the default faces behind it for any character it lacks.
    let mut family = vec![FACE.to_string()];
    family.extend(fonts.families[&FontFamily::Proportional].iter().cloned());
    fonts.families.insert(FontFamily::Name(FACE.into()), family);
    ctx.set_fonts(fonts);
    true
}

/// The display face, when it's loaded (App::face).
pub fn family(loaded: bool) -> FontFamily {
    if loaded { FontFamily::Name(FACE.into()) } else { FontFamily::Proportional }
}

pub fn title(text: &str, loaded: bool) -> RichText {
    RichText::new(text).family(family(loaded)).size(30.0).color(GOLD)
}
