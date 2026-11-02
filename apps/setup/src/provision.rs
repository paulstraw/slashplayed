// What Xcode does for Slashplayed on the Mac (Signing.swift's stub build), done through isideload's
// developer-services calls, as research/isideload proved on a free and a paid team: the device, the App IDs
// for the app and its .helper extension, their capabilities, the development certificate, and both profiles.
// isideload's high-level Sideloader isn't used: it turns on app groups, can revoke any certificate, and
// installs its own way.
//
// The owner's rules, enforced here:
// - App IDs are found and reused. One is made only when it's missing (the first run for a bundle ID) and the
//   team has room (a free team gets 10 a week); nothing else is ever made, and nothing is deleted.
// - No certificate this tool didn't make is ever revoked. Ours are found by our key; failing that, at the
//   team's certificate limit, the one we may revoke is one named MACHINE_NAME, which only this tool makes.
// - The key is stored before Apple sees a request for it (keystore.rs): a certificate whose key is lost is a
//   wasted slot.
// - Free or paid is a profile question (listTeams has no flag): a free team's profile lasts 7 days and is
//   marked IsFreeProvisioningProfile, and Apple refuses it extended-virtual-addressing.

use idevice::usbmuxd::UsbmuxdDevice;
use isideload::{
    SideloadError,
    dev::{
        app_ids::{AppId, AppIdsApi},
        certificates::{CertificatesApi, DevelopmentCertificate},
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
};
use http::HeaderValue;
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, PKCS_RSA_SHA256};
use rootcause::prelude::*;
use rsa::{
    RsaPrivateKey,
    pkcs1::EncodeRsaPublicKey,
    pkcs8::{EncodePrivateKey, LineEnding},
};
use serde_json::{Value as Json, json};
use sha1::{Digest, Sha1};
use x509_cert::{
    Certificate,
    der::{Decode, Encode},
};
use zeroize::Zeroizing;

use crate::{keystore, profile, say};

/// The name Apple shows for this tool's certificate (the developer site, Xcode's Manage Certificates): how
/// a person, and this tool at the certificate limit, tells it from Xcode's and other tools'.
pub const MACHINE_NAME: &str = "Slashplayed setup";
/// Every name this project's tools give their certificates: MACHINE_NAME, and research/isideload's spike
/// ("Slashplayed spike"). Only these may be revoked at the limit. Xcode can't help free a slot taken by one:
/// they're the older "iOS Development" kind, which Xcode's Manage Certificates doesn't list.
pub const OUR_NAMES: &[&str] = &[MACHINE_NAME, "Slashplayed spike"];
pub const IML: &str = "com.apple.developer.kernel.increased-memory-limit";
pub const EVA: &str = "com.apple.developer.kernel.extended-virtual-addressing";
/// submitDevelopmentCSR's result code when the team has all the development certificates it may.
const MAX_CERTS: i64 = 7460;

pub fn developer_code(e: &Report) -> Option<i64> {
    e.iter_reports().find_map(|n| match n.downcast_current_context::<SideloadError>() {
        Some(SideloadError::DeveloperError(code, _)) => Some(*code),
        _ => None,
    })
}

/// Picks the team: the one named, else the only one, else the person chooses.
pub async fn pick_team(session: &mut DeveloperSession, wanted: Option<&str>) -> Result<DeveloperTeam, Report> {
    let mut teams = session.list_teams().await?;
    if let Some(id) = wanted {
        return teams
            .into_iter()
            .find(|t| t.team_id == id)
            .ok_or_else(|| report!("this Apple ID has no team {id}"));
    }
    match teams.len() {
        0 => bail!("this Apple ID has no developer team. Sign in once at developer.apple.com to make its free Personal Team, then try again"),
        1 => Ok(teams.remove(0)),
        _ => {
            eprintln!("This Apple ID has {} teams:", teams.len());
            for (i, t) in teams.iter().enumerate() {
                eprintln!("  {}: {} ({})", i + 1, t.name.as_deref().unwrap_or("?"), t.team_id);
            }
            let n: usize = crate::account::ask("Which one should sign Slashplayed? ")?
                .parse()
                .map_err(|_| report!("not a number from the list"))?;
            if n == 0 || n > teams.len() {
                bail!("not a number from the list");
            }
            Ok(teams.remove(n - 1))
        }
    }
}

/// The device, registered on the team (once; a free team's limit is Apple's to say).
pub async fn register_device(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    device: &UsbmuxdDevice,
    name: &str,
) -> Result<(), Report> {
    let devices = session.list_devices(team, None).await?;
    if devices.iter().any(|d| d.device_number == device.udid) {
        say(&format!("{name} is already registered on the team"));
        return Ok(());
    }
    session.add_device(team, name, &device.udid, None).await?;
    say(&format!("registered {name} on the team"));
    Ok(())
}

/// The app's and the helper's App IDs, found or (only when missing) made.
pub async fn app_ids(session: &mut DeveloperSession, team: &DeveloperTeam, bundle_id: &str) -> Result<(AppId, AppId), Report> {
    let helper = crate::kit::helper_id(bundle_id);
    let list = session.list_app_ids(team, None).await?;
    let missing: Vec<String> = [bundle_id.to_string(), helper.clone()]
        .into_iter()
        .filter(|b| !list.app_ids.iter().any(|a| &a.identifier == b))
        .collect();
    if !missing.is_empty() {
        if let Some(avail) = list.available_quantity
            && avail < missing.len() as i64
        {
            bail!(
                "the team can make {avail} more App ID(s) right now and Slashplayed needs {}. A free team can make 10 a week: wait a few days and try again. Nothing was made",
                missing.len()
            );
        }
        for b in &missing {
            let name = if b.ends_with(".helper") { "Slashplayed helper" } else { "Slashplayed" };
            session.add_app_id(team, name, b, None).await?;
            say(&format!("made the App ID {b}"));
        }
    }
    let list = session.list_app_ids(team, None).await?;
    let find = |b: &str| {
        list.app_ids
            .iter()
            .find(|a| a.identifier == b)
            .cloned()
            .ok_or_else(|| report!("Apple doesn't list the App ID {b} after making it"))
    };
    Ok((find(bundle_id)?, find(&helper)?))
}

/// Capabilities, in one v1 bundleIds PATCH as Xcode sends them (isideload's own call can send only
/// increased-memory-limit). Returns whether extended-virtual-addressing was granted: Apple refuses it for a
/// free team, which is then signed with increased-memory-limit alone (Signing.freeTeamDropped).
pub async fn capabilities(session: &mut DeveloperSession, team: &DeveloperTeam, app_id: &AppId) -> Result<bool, Report> {
    if patch_capabilities(session, team, app_id, &["INCREASED_MEMORY_LIMIT", "EXTENDED_VIRTUAL_ADDRESSING"])
        .await
        .is_ok()
    {
        return Ok(true);
    }
    session
        .add_increased_memory_limit(team, app_id)
        .await
        .context("Apple refused the increased-memory-limit capability")?;
    Ok(false)
}

async fn patch_capabilities(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    app_id: &AppId,
    caps: &[&str],
) -> Result<(), Report> {
    let mut headers = session.get_headers().await?;
    headers.insert("Content-Type", HeaderValue::from_static("application/vnd.api+json"));
    headers.insert("Accept", HeaderValue::from_static("application/vnd.api+json"));
    let data: Vec<Json> = caps
        .iter()
        .map(|c| {
            json!({
                "type": "bundleIdCapabilities",
                "attributes": { "settings": [], "enabled": true },
                "relationships": { "capability": { "data": { "id": c, "type": "capabilities" } } },
            })
        })
        .collect();
    let body = json!({ "data": {
        "id": app_id.app_id_id,
        "type": "bundleIds",
        "attributes": {
            "hasExclusiveManagedCapabilities": false, "teamId": team.team_id, "bundleType": "bundle",
            "identifier": app_id.identifier, "seedId": team.team_id, "name": app_id.name,
        },
        "relationships": { "bundleIdCapabilities": { "data": data } },
    }});
    session
        .get_grandslam_client()
        .patch(&format!("https://developerservices2.apple.com/services/v1/bundleIds/{}", app_id.app_id_id))?
        .headers(headers)
        .body(body.to_string())
        .send()
        .await
        .context("the capability request didn't go through")?
        .error_for_status()
        .context("Apple refused the capabilities")?;
    Ok(())
}

/// The signing identity: our key and its certificate on the team.
pub struct Identity {
    pub key: RsaPrivateKey,
    pub cert_der: Vec<u8>,
}

fn csr(key: &RsaPrivateKey) -> Result<String, Report> {
    let mut params = CertificateParams::new(vec![])?;
    let mut dn = DistinguishedName::new();
    // Apple replaces the subject with its own; this is only what the request carries.
    dn.push(DnType::CommonName, MACHINE_NAME);
    params.distinguished_name = dn;
    let pem = Zeroizing::new(key.to_pkcs8_pem(LineEnding::LF)?.to_string());
    let pair = KeyPair::from_pkcs8_pem_and_sign_algo(&pem, &PKCS_RSA_SHA256)?;
    Ok(params.serialize_request(&pair)?.pem()?)
}

/// Whether a listed certificate's public key is `key`'s.
pub fn is_ours(c: &DevelopmentCertificate, key: &RsaPrivateKey) -> Option<Certificate> {
    let ours = key.to_public_key().to_pkcs1_der().ok()?;
    let x = Certificate::from_der(c.cert_content.as_ref()?.as_ref()).ok()?;
    (x.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes() == Some(ours.as_bytes())).then_some(x)
}

/// The certificates at the limit that this tool may revoke: only ones this project made (OUR_NAMES), oldest
/// first.
pub fn revocable(certs: &[DevelopmentCertificate]) -> Vec<&DevelopmentCertificate> {
    let mut v: Vec<_> = certs
        .iter()
        .filter(|c| c.machine_name.as_deref().is_some_and(|n| OUR_NAMES.contains(&n)) && c.serial_number.is_some())
        .collect();
    v.sort_by_key(|c| c.expiration_date.map(std::time::SystemTime::from));
    v
}

/// The team's certificates as Apple names them (the machine each was made for) and when each runs out, for
/// the person freeing a slot. Names only: nothing here identifies a key.
pub fn describe(certs: &[DevelopmentCertificate]) -> String {
    certs
        .iter()
        .map(|c| {
            let name = c.machine_name.as_deref().or(c.name.as_deref()).unwrap_or("unnamed");
            match c.expiration_date {
                Some(d) => format!("\"{name}\", until {}", &d.to_xml_format()[..10]),
                None => format!("\"{name}\""),
            }
        })
        .collect::<Vec<_>>()
        .join("; ")
}

pub async fn identity(session: &mut DeveloperSession, team: &DeveloperTeam, apple_id: &str) -> Result<Identity, Report> {
    let (key, stored) = match keystore::load(apple_id) {
        keystore::Loaded::Key(k) => (k, true),
        loaded => {
            let k = RsaPrivateKey::new(&mut rand::thread_rng(), 2048)?;
            let stored = match (&loaded, keystore::save(apple_id, &k)) {
                (_, Ok(())) => true,
                (keystore::Loaded::Unavailable(why), Err(_)) => {
                    say(&format!(
                        "no credential store to keep the signing key in ({why}): this run makes a new certificate"
                    ));
                    false
                }
                (_, Err(e)) => {
                    say(&format!("{}: this run makes a new certificate", crate::secret::safe_error(&e)));
                    false
                }
            };
            (k, stored)
        }
    };
    let certs = session.list_ios_certs(team).await?;
    if let Some(cert) = certs.iter().find_map(|c| is_ours(c, &key)) {
        say("reusing this computer's Slashplayed certificate");
        let cert_der = cert.to_der()?;
        return Ok(Identity { key, cert_der });
    }
    let request = csr(&key)?;
    match session.submit_development_csr(team, request.clone(), MACHINE_NAME.into(), None).await {
        Ok(r) => r,
        Err(e) if developer_code(&e) == Some(MAX_CERTS) => {
            let Some(old) = revocable(&certs).into_iter().next() else {
                bail!(
                    "the team has all the development certificates Apple allows ({}), and none of them is Slashplayed's. Nothing was revoked: this tool never revokes a certificate it didn't make. Free a slot yourself, then run this again: in Xcode on a Mac (Settings > Apple Accounts > Manage Certificates, which lists only Apple Development ones), on developer.apple.com (paid teams), or in the sideloading app that made an iOS Development one",
                    describe(&certs)
                );
            };
            say(&format!(
                "the team has all the certificates it may: revoking \"{}\" (made by Slashplayed's tools, on this or another computer)",
                old.machine_name.as_deref().unwrap_or_default()
            ));
            session.revoke_development_cert(team, old.serial_number.as_deref().unwrap_or_default(), None).await?;
            session.submit_development_csr(team, request, MACHINE_NAME.into(), None).await?
        }
        Err(e) => return Err(e),
    };
    say(if stored { "made a Slashplayed certificate for this computer" } else { "made a Slashplayed certificate for this run" });
    let certs = session.list_ios_certs(team).await?;
    let cert = certs
        .iter()
        .find_map(|c| is_ours(c, &key))
        .ok_or_else(|| report!("Apple took the certificate request but lists no certificate with its key"))?;
    let cert_der = cert.to_der()?;
    Ok(Identity { key, cert_der })
}

/// The identity as a .p12 the launcher imports (spsign.m): our key and certificate only, opened with
/// `password`. Built in memory; the caller pushes it and drops it (zeroed).
pub fn p12(id: &Identity, password: &str) -> Result<Zeroizing<Vec<u8>>, Report> {
    let key_der = Zeroizing::new(id.key.to_pkcs8_der()?.as_bytes().to_vec());
    let cert = p12_keystore::Certificate::from_der(&id.cert_der).map_err(|e| report!("the certificate didn't parse: {e:?}"))?;
    let local_key_id = Sha1::digest(key_der.as_slice())[..8].to_vec();
    let chain = p12_keystore::PrivateKeyChain::new(
        local_key_id,
        p12_keystore::PrivateKey::from_der(&key_der).map_err(|e| report!("the key didn't encode: {e:?}"))?,
        vec![cert],
    );
    let mut store = p12_keystore::KeyStore::new();
    store.add_entry("Slashplayed", p12_keystore::KeyStoreEntry::PrivateKeyChain(chain));
    let out = store.writer(password).write().map_err(|e| report!("couldn't make the .p12: {e:?}"))?;
    Ok(Zeroizing::new(out))
}

/// Both profiles, checked: the app's with increased-memory-limit (and extended-virtual-addressing on a paid
/// team), the helper's with neither (Signing.helperDropped). Returns them and whether the team is free.
pub async fn profiles(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    app_id: &AppId,
    helper_id: &AppId,
    udid: &str,
    id: &Identity,
    eva_granted: bool,
) -> Result<(Vec<u8>, Vec<u8>, bool), Report> {
    let app = session.download_team_provisioning_profile(team, app_id, None).await?;
    let app_bytes: Vec<u8> = app.encoded_profile.as_ref().to_vec();
    let parsed = profile::Profile::parse(&app_bytes)?;
    let free = parsed.is_free() || app.is_free_provisioning_profile == Some(true);
    if !free && !eva_granted {
        bail!("Apple refused extended-virtual-addressing on {}, which isn't a free team", team.team_id);
    }
    let want: &[&str] = if free { &[IML] } else { &[IML, EVA] };
    profile::check(&parsed, &team.team_id, &app_id.identifier, udid, &id.cert_der, want, &[])?;
    let helper = session.download_team_provisioning_profile(team, helper_id, None).await?;
    let helper_bytes: Vec<u8> = helper.encoded_profile.as_ref().to_vec();
    profile::check(&profile::Profile::parse(&helper_bytes)?, &team.team_id, &helper_id.identifier, udid, &id.cert_der, &[], &[IML, EVA])?;
    if let Some(exp) = parsed.expires() {
        let days = exp.duration_since(std::time::SystemTime::now()).map(|d| d.as_secs() / 86400).unwrap_or(0);
        say(&format!(
            "profiles made: {} team, good for {days} more days{}",
            if free { "a free" } else { "a paid" },
            if free { " (run this again within a week to keep Slashplayed opening)" } else { "" }
        ));
    }
    Ok((app_bytes, helper_bytes, free))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cert(name: Option<&str>, serial: Option<&str>, days: u64) -> DevelopmentCertificate {
        let exp = std::time::SystemTime::now() + std::time::Duration::from_secs(days * 86400);
        DevelopmentCertificate {
            name: None,
            certificate_id: None,
            serial_number: serial.map(str::to_string),
            machine_id: None,
            machine_name: name.map(str::to_string),
            cert_content: None,
            certificate_platform: None,
            certificate_type: None,
            status: None,
            status_code: None,
            expiration_date: Some(exp.into()),
        }
    }

    #[test]
    fn only_our_certificates_are_revocable() {
        let certs = vec![
            cert(Some("Paul's MacBook Pro"), Some("1"), 10),
            cert(Some(MACHINE_NAME), Some("2"), 300),
            cert(Some("AltStore"), Some("3"), 5),
            cert(Some(MACHINE_NAME), Some("4"), 100),
            cert(None, Some("5"), 1),
            cert(Some(MACHINE_NAME), None, 1),
            cert(Some("Slashplayed setup "), Some("6"), 1),
            cert(Some("Slashplayed spike"), Some("7"), 50),
        ];
        let r: Vec<_> = revocable(&certs).iter().map(|c| c.serial_number.clone().unwrap()).collect();
        assert_eq!(r, vec!["7", "4", "2"]);
    }

    #[test]
    fn certificates_are_described_by_name() {
        let d = describe(&[cert(Some("Paul's MacBook Pro"), Some("1"), 10), cert(None, None, 1)]);
        assert!(d.starts_with("\"Paul's MacBook Pro\", until 20"), "{d}");
        assert!(d.contains("; \"unnamed\", until "), "{d}");
    }

    #[test]
    fn our_certificate_is_found_by_key() {
        let key = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let other = RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let pem = Zeroizing::new(key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string());
        let pair = KeyPair::from_pkcs8_pem_and_sign_algo(&pem, &PKCS_RSA_SHA256).unwrap();
        let der = CertificateParams::new(vec![]).unwrap().self_signed(&pair).unwrap().der().to_vec();
        let mut c = cert(Some(MACHINE_NAME), Some("1"), 1);
        c.cert_content = Some(plist::Data::new(der));
        assert!(is_ours(&c, &key).is_some());
        assert!(is_ours(&c, &other).is_none());
        // And the .p12 made from it opens with its password.
        let x = is_ours(&c, &key).unwrap();
        let id = Identity { cert_der: x.to_der().unwrap(), key };
        let p12 = p12(&id, "pw").unwrap();
        assert!(p12_keystore::KeyStore::from_pkcs12(&p12, "pw", p12_keystore::Pkcs12ImportPolicy::Strict).is_ok());
        assert!(p12_keystore::KeyStore::from_pkcs12(&p12, "wrong", p12_keystore::Pkcs12ImportPolicy::Strict).is_err());
    }
}
