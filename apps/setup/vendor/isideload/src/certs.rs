// Slashplayed: Apple's root and WWDR G3 certificates, moved here from sideload::cert_identity (which still
// re-exports them) so the GrandSlam client, which pins APPLE_ROOT, builds without the sideload feature.
pub const APPLE_ROOT: &[u8] = include_bytes!("assets/apple_root.cer");
pub const APPLE_WWDR_G3_CERTIFICATE_DER: &[u8] = include_bytes!("assets/AppleWWDRCAG3.cer");
