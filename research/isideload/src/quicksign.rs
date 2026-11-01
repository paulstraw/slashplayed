// The signer comparison: signs a built Slashplayed.app with apple-codesign-quick (isideload's own signer,
// what its Sideloader::sign_app calls) instead of zsign, the way isideload does: each bundle gets its own
// profile embedded and its profile's entitlements. The key never leaves this process.

use std::{collections::BTreeMap, fs, path::Path};

use apple_codesign_quick::{BundleSigningSettings, ProvisioningProfile, RustCryptoCmsSigner, sign_bundle};
use isideload::sideload::cert_identity::{APPLE_ROOT, APPLE_WWDR_G3_CERTIFICATE_DER};
use rootcause::prelude::*;
use rsa::{RsaPrivateKey, pkcs8::DecodePrivateKey};
use serde_json::{Value as Json, json};
use x509_cert::{Certificate, der::Decode};
use zeroize::Zeroize;

use crate::store::Stored;

pub fn sign(app: &Path, profiles: &Path, stored: &Stored) -> Result<Json, Report> {
    let mut der = Stored::bytes(&stored.signing_key)?;
    let key = RsaPrivateKey::from_pkcs8_der(&der).map_err(|_| report!("the stored key is damaged"))?;
    der.zeroize();
    let cert = Certificate::from_der(&fs::read(profiles.join("cert.der"))?)
        .map_err(|e| report!("cert.der: {e}"))?;
    // The chain up from an Apple Development certificate: WWDR G3, then Apple's root (both bundled by
    // isideload, which builds the same chain in CertificateIdentity::profile_to_certificate_chain).
    let chain = vec![
        Certificate::from_der(APPLE_WWDR_G3_CERTIFICATE_DER).map_err(|e| report!("{e}"))?,
        Certificate::from_der(APPLE_ROOT).map_err(|e| report!("{e}"))?,
    ];
    let signer = RustCryptoCmsSigner::new(key, cert, chain);
    let app_profile = fs::read(profiles.join("app.mobileprovision"))?;
    let helper_profile = fs::read(profiles.join("helper.mobileprovision"))?;
    let parse = |b: &[u8]| ProvisioningProfile::parse(b).map_err(|e| report!("profile: {e}"));
    let (app_p, helper_p) = (parse(&app_profile)?, parse(&helper_profile)?);
    let app_id = info_id(app)?;
    let helper_id = info_id(&app.join("PlugIns/SPJitHelper.appex"))?;
    let mut settings = BundleSigningSettings::new(app_p.team_id(), app_p.entitlements().clone(), Some(&signer));
    settings.embedded_mobileprovision = Some(&app_profile);
    settings.embedded_mobileprovisions_by_bundle_id =
        BTreeMap::from([(app_id.clone(), &app_profile[..]), (helper_id.clone(), &helper_profile[..])]);
    settings.entitlements_by_bundle_id = BTreeMap::from([
        (app_id.clone(), app_p.entitlements().clone()),
        (helper_id.clone(), helper_p.entitlements().clone()),
    ]);
    let start = std::time::Instant::now();
    sign_bundle(app, &settings).map_err(|e| report!("apple-codesign-quick: {e}"))?;
    Ok(json!({ "app": app_id, "helper": helper_id, "seconds": start.elapsed().as_secs_f64() }))
}

fn info_id(bundle: &Path) -> Result<String, Report> {
    let info: plist::Dictionary = plist::from_file(bundle.join("Info.plist"))
        .map_err(|e| report!("{}: {e}", bundle.display()))?;
    Ok(info
        .get("CFBundleIdentifier")
        .and_then(|v| v.as_string())
        .ok_or_else(|| report!("{} has no CFBundleIdentifier", bundle.display()))?
        .to_string())
}
