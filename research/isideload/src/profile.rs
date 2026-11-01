// A downloaded provisioning profile, summarized for the report: what Apple put in it (entitlements, team,
// dates, devices, certificates), checked against what the spike asked for. The profile is the CMS-signed
// plist Apple serves; apple-codesign-quick's parser (isideload's signer) reads its content.

use apple_codesign_quick::ProvisioningProfile;
use plist::Value;
use rootcause::prelude::*;
use serde_json::{Value as Json, json};

/// plist to JSON for the report: dates as RFC 3339, data as its length (a profile's data fields are
/// certificates, which the report names by count and match instead).
pub fn to_json(v: &Value) -> Json {
    match v {
        Value::Array(a) => Json::Array(a.iter().map(to_json).collect()),
        Value::Dictionary(d) => Json::Object(d.iter().map(|(k, v)| (k.clone(), to_json(v))).collect()),
        Value::Boolean(b) => json!(b),
        Value::Data(d) => json!(format!("<{} bytes>", d.len())),
        Value::Date(d) => json!(d.to_xml_format()),
        Value::Real(r) => json!(r),
        Value::Integer(i) => i
            .as_signed()
            .map(|i| json!(i))
            .unwrap_or_else(|| json!(i.as_unsigned())),
        Value::String(s) => json!(s),
        Value::Uid(u) => json!(u.get()),
        _ => Json::Null,
    }
}

fn date_secs(v: Option<&Value>) -> Option<f64> {
    let d = v?.as_date()?;
    let t: std::time::SystemTime = d.into();
    Some(t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64())
}

/// `udid` and `cert_der` are what the profile should list; `want` the entitlement keys it should carry,
/// `refuse` the ones it shouldn't.
pub fn summarize(
    bytes: &[u8],
    udid: &str,
    cert_der: &[u8],
    want: &[&str],
    refuse: &[&str],
) -> Result<Json, Report> {
    let profile = ProvisioningProfile::parse(bytes)
        .map_err(|e| report!("couldn't read the profile: {e}"))?;
    let p = profile.plist();
    let ents = profile.entitlements();
    let devices: Vec<&str> = p
        .get("ProvisionedDevices")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_string).collect())
        .unwrap_or_default();
    // DeveloperCertificates: the certificates this profile lets sign (not the CMS signer's chain).
    let certs: Vec<&[u8]> = p
        .get("DeveloperCertificates")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_data).collect())
        .unwrap_or_default();
    let created = date_secs(p.get("CreationDate"));
    let expires = date_secs(p.get("ExpirationDate"));
    let lifetime_days = match (created, expires) {
        (Some(c), Some(e)) => Some(((e - c) / 86400.0 * 10.0).round() / 10.0),
        _ => None,
    };
    let get = |k: &str| p.get(k).map(to_json).unwrap_or(Json::Null);
    Ok(json!({
        "name": get("Name"),
        "app_id_name": get("AppIDName"),
        "team_identifier": get("TeamIdentifier"),
        "team_name": get("TeamName"),
        "platform": get("Platform"),
        "created": get("CreationDate"),
        "expires": get("ExpirationDate"),
        "lifetime_days": lifetime_days,
        "entitlements": to_json(&Value::Dictionary(ents.clone())),
        "has_wanted_entitlements": want.iter().all(|k| ents.contains_key(*k)),
        "missing_entitlements": want.iter().filter(|k| !ents.contains_key(**k)).collect::<Vec<_>>(),
        "unwanted_entitlements_present": refuse.iter().filter(|k| ents.contains_key(**k)).collect::<Vec<_>>(),
        "provisioned_devices": devices.len(),
        "lists_device": devices.contains(&udid),
        "provisions_all_devices": get("ProvisionsAllDevices"),
        "developer_certificates": certs.len(),
        "lists_our_certificate": certs.iter().any(|c| *c == cert_der),
    }))
}
