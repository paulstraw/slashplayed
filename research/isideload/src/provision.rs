// What Xcode does for Slashplayed (apps/client/signing/, Signing.swift), done through isideload's
// developer-services calls: device, App IDs for the app and its .helper appex, capabilities, the
// development certificate, both profiles, and the identity as a .p12 for the push path.
//
// Two rules from the owner, enforced here rather than trusted to flags elsewhere:
// - App IDs are found and reused; one is made only with --create-app-ids, and never when the team
//   hasn't the room (free teams: 10 a week). Nothing is ever deleted.
// - No certificate is ever revoked, ours or anyone's. isideload's high-level Sideloader revokes on the
//   team's certificate limit (MaxCertsBehavior::Revoke/Prompt), so this calls the low-level API instead
//   and stops at the limit.

use std::{fs, io::Write, os::unix::fs::OpenOptionsExt, path::Path};

use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use isideload::{
    SideloadError,
    dev::{
        app_ids::{AppId, AppIdsApi},
        certificates::CertificatesApi,
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::cert_identity::CertificateIdentity,
};
use rand::RngCore;
use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair, PKCS_RSA_SHA256};
use http::HeaderValue;
use rootcause::prelude::*;
use rsa::{
    RsaPrivateKey,
    pkcs1::EncodeRsaPublicKey,
    pkcs8::{DecodePrivateKey, EncodePrivateKey, LineEnding},
};
use serde_json::{Value as Json, json};
use x509_cert::{
    Certificate,
    der::{Decode, Encode, EncodePem},
};
use zeroize::{Zeroize, Zeroizing};

use crate::{Log, profile, session::Restored, store::Stored};

/// The name Apple shows for the spike's certificate (Xcode's Manage Certificates, the portal): plain, so
/// the owner can tell it from Xcode's own.
pub const MACHINE_NAME: &str = "Slashplayed spike";
const IML: &str = "com.apple.developer.kernel.increased-memory-limit";
const EVA: &str = "com.apple.developer.kernel.extended-virtual-addressing";
// submitDevelopmentCSR's result code when the team has all the development certificates it may.
const MAX_CERTS: i64 = 7460;

pub struct Options {
    pub team: String,
    pub udid: Option<String>,
    pub free: Option<bool>,
    pub create_app_ids: bool,
    pub create_cert: bool,
    pub out: std::path::PathBuf,
    pub identity: Option<std::path::PathBuf>,
}

pub fn developer_code(e: &Report) -> Option<i64> {
    e.iter_reports().find_map(|n| match n.downcast_current_context::<SideloadError>() {
        Some(SideloadError::DeveloperError(code, _)) => Some(*code),
        _ => None,
    })
}

/// Teams, with what the API says of each and the spike's free/paid call.
pub async fn teams(session: &mut DeveloperSession) -> Result<(Vec<DeveloperTeam>, Json), Report> {
    let teams = session.list_teams().await?;
    let json = teams
        .iter()
        .map(|t| {
            json!({
                "team_id": t.team_id, "name": t.name, "type": t.r#type, "status": t.status,
                "free_guess": free_guess(t),
            })
        })
        .collect();
    Ok((teams, Json::Array(json)))
}

/// listTeams has no "free" flag. A free Personal Team's type is checked for the words Apple uses; the
/// profile's lifetime (7 days, not a year) and its IsFreeProvisioningProfile confirm it afterwards.
fn free_guess(t: &DeveloperTeam) -> bool {
    let s = format!("{:?} {:?}", t.r#type, t.name).to_lowercase();
    s.contains("personal") || s.contains("free")
}

async fn usb_device(udid: Option<&str>) -> Result<(String, Option<String>, String), Report> {
    let mut mux = UsbmuxdConnection::default()
        .await
        .map_err(|e| report!("couldn't reach usbmuxd: {e}"))?;
    let devices = mux
        .get_devices()
        .await
        .map_err(|e| report!("usbmuxd wouldn't list devices: {e}"))?;
    let usb: Vec<_> = devices
        .iter()
        .filter(|d| format!("{:?}", d.connection_type).to_lowercase().contains("usb"))
        .collect();
    let device = match udid {
        Some(u) => usb.iter().find(|d| d.udid == u).copied(),
        None if usb.len() == 1 => Some(usb[0]),
        None => bail!(
            "{} devices on USB: name one with --udid",
            usb.len()
        ),
    }
    .ok_or_else(|| report!("that device isn't connected over USB"))?;
    // DeviceName is readable before a lockdown session, so the Mac's pair record is never asked for.
    let provider = device.to_provider(
        UsbmuxdAddr::from_env_var().map_err(|e| report!("bad USBMUXD_SOCKET_ADDRESS: {e}"))?,
        "spisideload",
    );
    let name = match LockdownClient::connect(&provider).await {
        Ok(mut l) => l
            .get_value(Some("DeviceName"), None)
            .await
            .ok()
            .and_then(|v| v.as_string().map(str::to_string)),
        Err(_) => None,
    };
    Ok((device.udid.clone(), name, format!("{:?}", device.connection_type)))
}

/// Enables capabilities on an App ID with the v1 bundleIds PATCH Xcode uses (isideload's
/// add_increased_memory_limit, generalized: it can send only INCREASED_MEMORY_LIMIT). All of them in one
/// request, so whether a PATCH replaces or adds to the list doesn't matter.
async fn enable_capabilities(
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
        .patch(&format!(
            "https://developerservices2.apple.com/services/v1/bundleIds/{}",
            app_id.app_id_id
        ))?
        .headers(headers)
        .body(body.to_string())
        .send()
        .await
        .context("the capability request didn't go through")?
        .error_for_status()
        .context("Apple refused the capability")?;
    Ok(())
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

/// The certificate whose key is ours, among the team's iOS development certificates.
async fn find_ours(
    session: &mut DeveloperSession,
    team: &DeveloperTeam,
    key: &RsaPrivateKey,
    log: &mut Log,
) -> Result<Option<(Certificate, Vec<u8>, String)>, Report> {
    let ours = key.to_public_key().to_pkcs1_der()?.as_bytes().to_vec();
    let certs = session.list_ios_certs(team).await?;
    let mut listed = Vec::new();
    let mut found = None;
    for c in &certs {
        let x509 = c
            .cert_content
            .as_ref()
            .and_then(|d| Certificate::from_der(d.as_ref()).ok());
        let mine = x509.as_ref().is_some_and(|x| {
            x.tbs_certificate.subject_public_key_info.subject_public_key.as_bytes() == Some(&ours[..])
        });
        listed.push(json!({
            "name": c.name, "machine_name": c.machine_name, "status": c.status,
            "expires": c.expiration_date.map(|d| d.to_xml_format()), "ours": mine,
        }));
        if mine && found.is_none() {
            let x = x509.unwrap();
            let der = x.to_der()?;
            found = Some((x, der, c.machine_id.clone().unwrap_or_default()));
        }
    }
    log.step("certificates", json!({ "count": certs.len(), "list": listed }));
    Ok(found)
}

/// Writes a credential file 0600 (and no one else's to begin with: create_new).
fn write_secret(path: &Path, data: &[u8]) -> Result<(), Report> {
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| report!("couldn't create {}: {e}", path.display()))?;
    f.write_all(data)?;
    Ok(())
}

pub async fn provision(
    restored: &mut Restored,
    apple_id: &str,
    opts: &Options,
    log: &mut Log,
) -> Result<(), Report> {
    // A new xcode token from the stored GS token, as a host would mint one each run. About 1.2 h after
    // login that started failing with GrandSlam -22411 on both Apple IDs, while the token login stored
    // still worked (README, Token lifetime): then the stored one, so the spike can still provision.
    let mut session = match restored.minted_session().await {
        Ok((session, token)) => {
            log.step("session", json!({ "minted_xcode_token_expiry": token.expiry, "duration": token.duration }));
            session
        }
        Err(e) => {
            log.step("session", json!({
                "mint_from_gs_token": crate::safe_error(&e),
                "using": "the xcode token login stored",
                "stored_xcode_token_expiry": restored.stored.xcode_token_expiry,
            }));
            restored.stored_session()
        }
    };

    // 2. The team.
    let (teams, teams_json) = teams(&mut session).await?;
    log.step("teams", teams_json);
    let team = teams
        .into_iter()
        .find(|t| t.team_id == opts.team)
        .ok_or_else(|| report!("this Apple ID has no team {}", opts.team))?;
    let free = opts.free.unwrap_or_else(|| free_guess(&team));
    log.step("team", json!({ "team_id": team.team_id, "free": free, "from_flag": opts.free.is_some() }));

    // 3. The device.
    let (udid, name, connection) = usb_device(opts.udid.as_deref()).await?;
    let before = session.list_devices(&team, None).await?;
    let registered = before.iter().any(|d| d.device_number == udid);
    if !registered {
        session
            .ensure_device_registered(&team, name.as_deref().unwrap_or("Slashplayed spike device"), &udid, None)
            .await?;
    }
    let after = session.list_devices(&team, None).await?;
    log.step("device", json!({
        "udid": udid, "name": name, "connection": connection,
        "was_registered": registered, "registered_now": after.iter().any(|d| d.device_number == udid),
        "team_devices": after.len(),
    }));

    // 4. App IDs: <team>.slashplayed.spike and its .helper, found or (only when allowed) made.
    let app_bundle = format!("{}.slashplayed.spike", team.team_id);
    let helper_bundle = format!("{app_bundle}.helper");
    let list = session.list_app_ids(&team, None).await?;
    let missing: Vec<&String> = [&app_bundle, &helper_bundle]
        .into_iter()
        .filter(|b| !list.app_ids.iter().any(|a| &a.identifier == *b))
        .collect();
    log.step("app_ids_before", json!({
        "max": list.max_quantity, "available": list.available_quantity,
        "team_app_ids": list.app_ids.len(), "missing": missing,
    }));
    if !missing.is_empty() {
        if !opts.create_app_ids {
            bail!("{} App ID(s) to make ({:?}); rerun with --create-app-ids to allow it", missing.len(), missing);
        }
        if let Some(avail) = list.available_quantity
            && avail < missing.len() as i64
        {
            bail!("the team can make {avail} more App ID(s) now and {} are needed: wait, nothing made", missing.len());
        }
        for b in &missing {
            let name = if b.ends_with(".helper") { "Slashplayed spike helper" } else { "Slashplayed spike" };
            session.add_app_id(&team, name, b, None).await?;
        }
    }
    let list = session.list_app_ids(&team, None).await?;
    let find = |b: &str| list.app_ids.iter().find(|a| a.identifier == b).cloned();
    let app_id = find(&app_bundle).ok_or_else(|| report!("App ID {app_bundle} not there after making it"))?;
    let helper_id = find(&helper_bundle).ok_or_else(|| report!("App ID {helper_bundle} not there after making it"))?;
    log.step("app_ids", json!({
        "created": missing, "available_after": list.available_quantity,
        "app": { "identifier": app_id.identifier, "expires": app_id.expiration_date.map(|d| d.to_xml_format()),
                 "features": profile::to_json(&plist::Value::Dictionary(app_id.features.clone())) },
        "helper": { "identifier": helper_id.identifier, "expires": helper_id.expiration_date.map(|d| d.to_xml_format()),
                    "features": profile::to_json(&plist::Value::Dictionary(helper_id.features.clone())) },
    }));

    // 5. Capabilities: increased-memory-limit always (isideload's own call); extended-virtual-addressing on a
    // paid team only (Signing.freeTeamDropped), both in one request. The helper gets none (helperDropped).
    let caps = if free {
        session.add_increased_memory_limit(&team, &app_id).await.map(|_| vec!["INCREASED_MEMORY_LIMIT"])
    } else {
        let c = ["INCREASED_MEMORY_LIMIT", "EXTENDED_VIRTUAL_ADDRESSING"];
        enable_capabilities(&mut session, &team, &app_id, &c).await.map(|_| c.to_vec())
    };
    match caps {
        Ok(c) => log.step("capabilities", json!({ "enabled": c, "via": if free { "isideload add_increased_memory_limit" } else { "v1 PATCH (spike)" } })),
        Err(e) => {
            log.step("capabilities", json!({ "error": crate::safe_error(&e) }));
            return Err(e);
        }
    }

    // 6. The certificate: ours if the team has it, else (only when allowed) a new one. Never a revoke.
    let mut fresh_key = false;
    if restored.stored.signing_key.is_empty() {
        let key = RsaPrivateKey::new(&mut rand::thread_rng(), 2048)?;
        let der = key.to_pkcs8_der()?;
        restored.stored.signing_key = Stored::encode(der.as_bytes());
        // Kept before Apple sees a request for it: a certificate whose key was lost is a wasted slot.
        restored.save(apple_id)?;
        fresh_key = true;
    }
    let key = {
        let mut der = Stored::bytes(&restored.stored.signing_key)?;
        let k = RsaPrivateKey::from_pkcs8_der(&der).map_err(|_| report!("the stored key is damaged"))?;
        der.zeroize();
        k
    };
    let mut created_cert = false;
    let (cert, cert_der, machine_id) = match find_ours(&mut session, &team, &key, log).await? {
        Some(found) => found,
        None => {
            if !opts.create_cert {
                bail!("the team has no certificate for the spike's key (new key: {fresh_key}); rerun with --create-cert to request one");
            }
            let request = match session
                .submit_development_csr(&team, csr(&key)?, MACHINE_NAME.into(), None)
                .await
            {
                Ok(r) => r,
                Err(e) if developer_code(&e) == Some(MAX_CERTS) => bail!(
                    "the team has all the development certificates Apple allows. Nothing was revoked, and \
                     the spike never revokes: free a slot yourself (Xcode > Settings > Apple Accounts > \
                     Manage Certificates) if you choose, then run this again"
                ),
                Err(e) => return Err(e),
            };
            created_cert = true;
            log.step("certificate_request", json!({ "request_id_present": !request.cert_request_id.is_empty() }));
            find_ours(&mut session, &team, &key, log)
                .await?
                .ok_or_else(|| report!("Apple took the request but lists no certificate with our key"))?
        }
    };
    let not_after = cert.tbs_certificate.validity.not_after.to_string();
    log.step("certificate", json!({ "created": created_cert, "not_after": not_after,
        "subject": cert.tbs_certificate.subject.to_string() }));

    // 7. Profiles.
    fs::create_dir_all(&opts.out)?;
    let mut summaries = serde_json::Map::new();
    for (label, id, want, refuse) in [
        ("app", &app_id, if free { vec![IML] } else { vec![IML, EVA] }, if free { vec![EVA] } else { vec![] }),
        ("helper", &helper_id, vec![], vec![IML, EVA]),
    ] {
        let p = session.download_team_provisioning_profile(&team, id, None).await?;
        let bytes: &[u8] = p.encoded_profile.as_ref();
        fs::write(opts.out.join(format!("{label}.mobileprovision")), bytes)?;
        let mut s = profile::summarize(bytes, &udid, &cert_der, &want, &refuse)?;
        s["is_free_provisioning_profile"] = json!(p.is_free_provisioning_profile);
        s["is_team_profile"] = json!(p.is_team_profile);
        s["status"] = json!(p.status);
        s["type"] = json!(p.r#type);
        summaries.insert(label.into(), s);
    }
    log.step("profiles", Json::Object(summaries));
    // The certificate alone (public) for sign-quick and the report's readers.
    fs::write(opts.out.join("cert.der"), &cert_der)?;

    // 8. The identity, if asked for: spidentity.p12 and .pass (push-identity.sh's pair) and key.pem and
    // cert.pem (zsign's -k/-c, so no password goes on its command line). The caller zeroes and deletes them.
    if let Some(dir) = &opts.identity {
        let mut pw_bytes = [0u8; 24];
        rand::thread_rng().fill_bytes(&mut pw_bytes);
        let password = Zeroizing::new(hex::encode(pw_bytes));
        pw_bytes.zeroize();
        let identity = CertificateIdentity {
            machine_id,
            machine_name: MACHINE_NAME.into(),
            private_key: key.clone(),
            certificate: cert.clone(),
        };
        let mut p12 = identity.as_p12(&password).await?;
        write_secret(&dir.join("spidentity.p12"), &p12)?;
        p12.zeroize();
        write_secret(&dir.join("spidentity.pass"), password.as_bytes())?;
        let pem = Zeroizing::new(key.to_pkcs8_pem(LineEnding::LF)?.to_string());
        write_secret(&dir.join("key.pem"), pem.as_bytes())?;
        write_secret(&dir.join("cert.pem"), cert.to_pem(LineEnding::LF)?.as_bytes())?;
        log.step("identity", json!({ "written": ["spidentity.p12", "spidentity.pass", "key.pem", "cert.pem"] }));
    }
    restored.save(apple_id)?;
    Ok(())
}
