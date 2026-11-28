// A provisioning profile's plist, cut out of its CMS envelope as the Mac's Signing.profilePlist does: the
// signature is zsign's and the device's business; this only reads what Apple put in it, to tell a free team
// from a paid one and to check the profile is the one this run needs.

use plist::{Dictionary, Value};
use rootcause::prelude::*;

pub struct Profile {
    pub plist: Dictionary,
}

impl Profile {
    pub fn parse(bytes: &[u8]) -> Result<Self, Report> {
        let start = find(bytes, b"<?xml").ok_or_else(|| report!("a profile has no plist"))?;
        let end = find(&bytes[start..], b"</plist>").ok_or_else(|| report!("a profile's plist has no end"))?;
        let plist = plist::from_bytes(&bytes[start..start + end + 8]).map_err(|_| report!("a profile's plist doesn't parse"))?;
        Ok(Self { plist })
    }

    fn secs(&self, key: &str) -> Option<f64> {
        let d = self.plist.get(key)?.as_date()?;
        let t: std::time::SystemTime = d.into();
        Some(t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64())
    }

    pub fn expires(&self) -> Option<std::time::SystemTime> {
        self.plist.get("ExpirationDate").and_then(Value::as_date).map(Into::into)
    }

    /// A free Personal Team's profile: Apple marks it, and it lasts 7 days, not a year
    /// (Signing.isFreeProfile).
    pub fn is_free(&self) -> bool {
        if self.plist.get("IsFreeProvisioningProfile").and_then(Value::as_boolean) == Some(true) {
            return true;
        }
        match (self.secs("CreationDate"), self.secs("ExpirationDate")) {
            (Some(c), Some(e)) => e - c <= 8.0 * 86400.0,
            _ => false,
        }
    }

    pub fn entitlements(&self) -> Option<&Dictionary> {
        self.plist.get("Entitlements").and_then(Value::as_dictionary)
    }

    pub fn application_identifier(&self) -> Option<&str> {
        self.entitlements()?.get("application-identifier")?.as_string()
    }

    pub fn lists_device(&self, udid: &str) -> bool {
        self.plist
            .get("ProvisionedDevices")
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(|d| d.as_string() == Some(udid)))
    }

    pub fn lists_certificate(&self, der: &[u8]) -> bool {
        self.plist
            .get("DeveloperCertificates")
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(|c| c.as_data() == Some(der)))
    }

    /// The latest notAfter of the profile's certificates whose common name is `name`. None when it has none.
    fn certificate_named(&self, name: &str) -> Option<std::time::SystemTime> {
        use x509_cert::der::{Decode, oid::ObjectIdentifier};
        const CN: ObjectIdentifier = ObjectIdentifier::new_unwrap("2.5.4.3");
        let certs = self.plist.get("DeveloperCertificates")?.as_array()?;
        certs
            .iter()
            .filter_map(|c| x509_cert::Certificate::from_der(c.as_data()?).ok())
            .filter(|x| {
                // UTF8String or PrintableString: either way the value's bytes are the name.
                x.tbs_certificate.subject.0.iter().flat_map(|rdn| rdn.0.iter()).any(|a| a.oid == CN && a.value.value() == name.as_bytes())
            })
            .map(|x| x.tbs_certificate.validity.not_after.to_system_time())
            .max()
    }
}

/// What the device's profiles say about the installed app's signing (signing_expiry).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Signing {
    /// No profile for its App ID lists this device.
    #[default]
    NoProfile,
    /// Some do, but none lists a certificate named as its signer: the profile it was installed with, which
    /// lists that certificate, is gone, so it has lapsed (or the app's helper's has, and no game loads).
    NoneForSigner,
    /// It opens until then.
    Until(std::time::SystemTime),
}

/// When the installed app stops opening, as far as the device's profiles (misagent's list, `profiles`) say:
/// iOS opens it on any installed profile for its App ID, not only the one it embeds (docs/internals/loading.md),
/// so a newer one the Mac companion or Xcode installed keeps it opening. But only one that lists the device
/// and the certificate the app is signed with, and only while that certificate lasts. The host can't read the
/// app's bundle, so the certificate is known by its name alone (installation_proxy's SignerIdentity, `signer`):
/// a profile counts with the latest of its certificates of that name. A person's certificates share one, so
/// this can come out late, never early (docs/internals/host-tool.md). Then the earlier of the app's (`app_id`)
/// and its helper's (<app_id>.helper), since without the helper no game loads, as the launcher's
/// sp_profile_expiry takes it; the app's alone when the helper has none for this device.
pub fn signing_expiry(profiles: &[Vec<u8>], app_id: &str, signer: Option<&str>, udid: &str) -> Signing {
    let parsed: Vec<Profile> = profiles.iter().filter_map(|b| Profile::parse(b).ok()).collect();
    // None: no dated profile for `id` lists the device; Some(None): none of those is for the signer.
    let last = |id: &str| {
        let mine: Vec<_> = parsed.iter().filter(|p| p.application_identifier() == Some(id) && p.lists_device(udid)).collect();
        let dates = mine.iter().filter_map(|p| {
            let until = p.expires()?;
            // No SignerIdentity (installation_proxy left it out): the profile's own date.
            let Some(signer) = signer else { return Some(until) };
            Some(until.min(p.certificate_named(signer)?))
        });
        (!mine.is_empty()).then(|| dates.max())
    };
    match (last(app_id), last(&format!("{app_id}.helper"))) {
        (None, _) => Signing::NoProfile,
        (Some(None), _) | (_, Some(None)) => Signing::NoneForSigner,
        (Some(Some(app)), helper) => Signing::Until(helper.flatten().map_or(app, |h| app.min(h))),
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Checks a downloaded profile is for `bundle_id` on `team`, lists the device and our certificate, and has
/// `want` and none of `refuse`: what would otherwise fail later on the device, said now.
pub fn check(p: &Profile, team: &str, bundle_id: &str, udid: &str, cert: &[u8], want: &[&str], refuse: &[&str]) -> Result<(), Report> {
    let app_id = format!("{team}.{bundle_id}");
    if p.application_identifier() != Some(app_id.as_str()) {
        bail!("Apple sent a profile for {:?}, not {app_id}", p.application_identifier());
    }
    if !p.lists_device(udid) {
        bail!("{bundle_id}'s profile doesn't list this device yet: run this again in a minute");
    }
    if !p.lists_certificate(cert) {
        bail!("{bundle_id}'s profile doesn't list this tool's certificate yet: run this again in a minute");
    }
    let ents = p.entitlements().cloned().unwrap_or_default();
    let missing: Vec<_> = want.iter().filter(|k| !ents.contains_key(**k)).collect();
    if !missing.is_empty() {
        bail!("{bundle_id}'s profile doesn't grant {missing:?}");
    }
    let extra: Vec<_> = refuse.iter().filter(|k| ents.contains_key(**k)).collect();
    if !extra.is_empty() {
        bail!("{bundle_id}'s profile grants {extra:?}, which it shouldn't");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(days: u64, free_flag: bool) -> Vec<u8> {
        let now = std::time::SystemTime::now();
        let mut d = Dictionary::new();
        d.insert("CreationDate".into(), Value::Date(now.into()));
        d.insert("ExpirationDate".into(), Value::Date((now + std::time::Duration::from_secs(days * 86400)).into()));
        if free_flag {
            d.insert("IsFreeProvisioningProfile".into(), Value::Boolean(true));
        }
        let mut e = Dictionary::new();
        e.insert("application-identifier".into(), Value::String("T.T.slashplayed".into()));
        e.insert("com.apple.developer.kernel.increased-memory-limit".into(), Value::Boolean(true));
        d.insert("Entitlements".into(), Value::Dictionary(e));
        d.insert("ProvisionedDevices".into(), Value::Array(vec![Value::String("U1".into())]));
        d.insert("DeveloperCertificates".into(), Value::Array(vec![Value::Data(vec![1, 2, 3])]));
        let mut xml = Vec::new();
        plist::to_writer_xml(&mut xml, &d).unwrap();
        // The CMS envelope's bytes around it don't matter: only the plist is read.
        let mut out = b"\x30\x80junk".to_vec();
        out.extend(xml);
        out.extend(b"\x00\x00trailer");
        out
    }

    #[test]
    fn free_and_paid() {
        assert!(Profile::parse(&profile(7, false)).unwrap().is_free());
        assert!(Profile::parse(&profile(365, true)).unwrap().is_free());
        assert!(!Profile::parse(&profile(365, false)).unwrap().is_free());
    }

    #[test]
    fn checks() {
        let p = Profile::parse(&profile(365, false)).unwrap();
        let iml = "com.apple.developer.kernel.increased-memory-limit";
        let eva = "com.apple.developer.kernel.extended-virtual-addressing";
        check(&p, "T", "T.slashplayed", "U1", &[1, 2, 3], &[iml], &[eva]).unwrap();
        assert!(check(&p, "T", "T.other", "U1", &[1, 2, 3], &[], &[]).is_err());
        assert!(check(&p, "T", "T.slashplayed", "U2", &[1, 2, 3], &[], &[]).is_err());
        assert!(check(&p, "T", "T.slashplayed", "U1", &[9], &[], &[]).is_err());
        assert!(check(&p, "T", "T.slashplayed", "U1", &[1, 2, 3], &[eva], &[]).is_err());
        assert!(check(&p, "T", "T.slashplayed", "U1", &[1, 2, 3], &[], &[iml]).is_err());
    }

    /// A certificate named `cn` that lasts until the start of `until` (year, month, day).
    fn cert(cn: &str, until: (i32, u8, u8)) -> Vec<u8> {
        let mut params = rcgen::CertificateParams::new(vec![]).unwrap();
        params.distinguished_name.push(rcgen::DnType::CommonName, cn);
        params.not_after = rcgen::date_time_ymd(until.0, until.1, until.2);
        params.self_signed(&rcgen::KeyPair::generate().unwrap()).unwrap().der().to_vec()
    }

    fn day(y: i32, m: u8, d: u8) -> Signing {
        Signing::Until(rcgen::date_time_ymd(y, m, d).into())
    }

    /// A profile for `app_id` that lists `device` and `certs`, until `until`, in a CMS-like envelope.
    fn installed(app_id: &str, until: (i32, u8, u8), device: &str, certs: &[&Vec<u8>]) -> Vec<u8> {
        let mut d = Dictionary::new();
        let t: std::time::SystemTime = rcgen::date_time_ymd(until.0, until.1, until.2).into();
        d.insert("ExpirationDate".into(), Value::Date(t.into()));
        let mut e = Dictionary::new();
        e.insert("application-identifier".into(), Value::String(app_id.into()));
        d.insert("Entitlements".into(), Value::Dictionary(e));
        d.insert("ProvisionedDevices".into(), Value::Array(vec![Value::String(device.into())]));
        d.insert("DeveloperCertificates".into(), Value::Array(certs.iter().map(|c| Value::Data(c.to_vec())).collect()));
        let mut out = b"\x30\x80junk".to_vec();
        plist::to_writer_xml(&mut out, &d).unwrap();
        out
    }

    #[test]
    fn signing_lasts_as_long_as_what_the_app_can_open_on() {
        const ME: &str = "Apple Development: Pat Doe (ABC123)";
        let (app, helper) = ("T.T.slashplayed", "T.T.slashplayed.helper");
        let mine = cert(ME, (2028, 6, 1));
        let other = cert("Apple Development: Someone Else (XYZ789)", (2028, 6, 1));
        let others = vec![
            // Later, but for a certificate the app isn't signed with, or for another device: no help to it.
            installed(app, (2027, 11, 12), "U1", &[&other]),
            installed(app, (2027, 12, 1), "U2", &[&mine]),
            // Another app whose ID merely starts the same.
            installed("T.T.slashplayed.spike", (2028, 1, 1), "U1", &[&mine]),
        ];
        let at = |device: &[Vec<u8>], signer| signing_expiry(device, app, signer, "U1");
        let with = |extra: Vec<Vec<u8>>| [others.clone(), extra].concat();

        let device = with(vec![installed(app, (2027, 10, 28), "U1", &[&mine]), installed(helper, (2027, 11, 8), "U1", &[&mine])]);
        assert_eq!(at(&device, Some(ME)), day(2027, 10, 28));
        // Without a signer to go by, any profile for the app on this device counts (the helper's still caps it).
        assert_eq!(at(&device, None), day(2027, 11, 8));
        // No helper profile for this device: the app's alone.
        assert_eq!(at(&with(vec![installed(app, (2027, 10, 28), "U1", &[&mine])]), Some(ME)), day(2027, 10, 28));
        // A helper's that runs out first is when games stop loading.
        let device = with(vec![installed(app, (2027, 10, 28), "U1", &[&mine]), installed(helper, (2027, 10, 22), "U1", &[&mine])]);
        assert_eq!(at(&device, Some(ME)), day(2027, 10, 22));

        // Profiles for the app on this device, but none for its signer: lapsed, not "no profile".
        assert_eq!(at(&device, Some("Apple Development: Nobody (000000)")), Signing::NoneForSigner);
        let device = with(vec![installed(app, (2027, 10, 28), "U1", &[&mine]), installed(helper, (2027, 11, 8), "U1", &[&other])]);
        assert_eq!(at(&device, Some(ME)), Signing::NoneForSigner, "the helper's for another certificate doesn't count");
        assert_eq!(signing_expiry(&device, "T.T.other", Some(ME), "U1"), Signing::NoProfile);
        assert_eq!(signing_expiry(&device, app, Some(ME), "U3"), Signing::NoProfile);
    }

    #[test]
    fn signing_ends_with_the_certificate() {
        const ME: &str = "Apple Development: Pat Doe (ABC123)";
        let (old, new) = (cert(ME, (2027, 6, 14)), cert(ME, (2027, 11, 3)));
        let app = "T.T.slashplayed";
        // One profile with only the certificate that lapses first: it lasts as long as that certificate.
        let device = vec![installed(app, (2027, 10, 28), "U1", &[&old])];
        assert_eq!(signing_expiry(&device, app, Some(ME), "U1"), day(2027, 6, 14));
        // One that also lists a later certificate of the same name: that one may be the app's, so it counts.
        let device = vec![installed(app, (2027, 11, 12), "U1", &[&old, &new])];
        assert_eq!(signing_expiry(&device, app, Some(ME), "U1"), day(2027, 11, 3));
    }
}
