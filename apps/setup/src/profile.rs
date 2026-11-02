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
}
