// The iPad or iPhone, over USB through usbmuxd (Apple Mobile Device Support on Windows, the usbmuxd service
// on Linux, macOS's own on a Mac), with idevice at the repo's pinned commit: the device, trusting this
// computer, Developer Mode, the install, files into the app's data container, and the RemotePairing record.
//
// The two records here are credentials (CLAUDE.md): this computer's lockdown pair record, which usbmuxd
// keeps and idevice holds in memory, and the RemotePairing record made for the app. Neither is ever read
// out, printed, or logged; the RemotePairing record goes from idevice's memory straight to the device over
// AFC (house_arrest), so it never touches this computer's disk, and only its size is said.

use std::path::Path;

use idevice::{
    IdeviceError, IdeviceService,
    afc::{AfcClient, opcode::AfcFopenMode},
    amfi::AmfiClient,
    house_arrest::HouseArrestClient,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};
use rootcause::prelude::*;
use zeroize::Zeroizing;

use crate::flow::{DeviceInfo, Event, Frontend, Wait};

/// The name this computer's pairings go by on the device (Settings > Developer lists the RemotePairing one).
pub const HOST_NAME: &str = "Slashplayed";
/// Where the launcher finds its RemotePairing record (Pairing.devicePath).
pub const PAIRING_PATH: &str = "Library/sppairing.plist";

#[derive(Clone)]
pub struct Device {
    pub usb: UsbmuxdDevice,
    pub name: String,
    pub class: String,
    pub os: String,
}

impl Device {
    pub fn info(&self) -> DeviceInfo {
        DeviceInfo { udid: self.usb.udid.clone(), name: self.name.clone(), class: self.class.clone(), os: self.os.clone() }
    }

    pub fn provider(&self) -> UsbmuxdProvider {
        self.usb.to_provider(UsbmuxdAddr::default(), HOST_NAME)
    }
}

fn no_usbmuxd(e: IdeviceError) -> Report {
    let how = if cfg!(windows) {
        "Install Apple Devices from the Microsoft Store (or iTunes from apple.com), which brings the driver it needs"
    } else if cfg!(target_os = "linux") {
        "Install and start usbmuxd (on most distributions: the usbmuxd package, then plug the device in)"
    } else {
        "macOS runs it itself; restart this computer if it isn't answering"
    };
    report!("couldn't reach usbmuxd, the service that talks to iPhones and iPads over USB ({e}). {how}")
}

/// The iPhones and iPads usbmuxd sees on USB, with their names (read before any session, so no pairing is
/// needed to list them).
pub async fn list() -> Result<Vec<Device>, Report> {
    let mut mux = UsbmuxdConnection::default().await.map_err(no_usbmuxd)?;
    let all = mux.get_devices().await.map_err(no_usbmuxd)?;
    let mut out = Vec::new();
    for usb in all.into_iter().filter(|d| d.connection_type == Connection::Usb) {
        let provider = usb.to_provider(UsbmuxdAddr::default(), HOST_NAME);
        let mut l = match LockdownClient::connect(&provider).await {
            Ok(l) => l,
            Err(_) => continue,
        };
        let get = async |l: &mut LockdownClient, k: &str| {
            l.get_value(Some(k), None).await.ok().and_then(|v| v.as_string().map(str::to_string)).unwrap_or_default()
        };
        let name = get(&mut l, "DeviceName").await;
        let class = get(&mut l, "DeviceClass").await;
        let os = get(&mut l, "ProductVersion").await;
        out.push(Device { usb, name, class, os });
    }
    Ok(out)
}

/// What a failed StartSession with usbmuxd's existing record means for that record.
#[derive(Debug, PartialEq, Eq)]
enum SessionRefusal {
    /// The device doesn't know the record's HostID (it was never paired with this computer, or the pairing
    /// was reset or removed in Settings): only a new pairing helps.
    NotAccepted,
    /// The device knows the record but is locked (notably after a restart, Developer Mode's included,
    /// before its first unlock): the record is fine, and the session works once it's unlocked.
    Locked,
    /// Anything else (the connection dropping, the TLS handshake failing, an answer idevice doesn't map):
    /// nothing says the record is bad, so it isn't replaced.
    Other,
}

/// Re-pairing is only for a record the device really refuses: a new pairing overwrites usbmuxd's record,
/// which on a Mac is the system's own one that Finder and Xcode use, and asks the person to tap Trust again.
/// So a locked device or a passing failure must never land there. lockdownd answers StartSession with
/// "InvalidHostID" for an unknown HostID and "PasswordProtected" (or "DeviceLocked") while locked; idevice
/// maps those names in `IdeviceError::from_device_error_type`.
fn classify_refusal(e: &IdeviceError) -> SessionRefusal {
    match e {
        IdeviceError::InvalidHostID => SessionRefusal::NotAccepted,
        IdeviceError::PasswordProtected | IdeviceError::DeviceLocked => SessionRefusal::Locked,
        _ => SessionRefusal::Other,
    }
}

/// Makes sure this computer is trusted by the device (a lockdown pair record usbmuxd keeps), asking the
/// person to tap Trust when it isn't. On a Mac that already syncs with the device, nothing happens.
pub async fn ensure_trusted(d: &Device, ui: &dyn Frontend) -> Result<(), Report> {
    let mut mux = UsbmuxdConnection::default().await.map_err(no_usbmuxd)?;
    // No record at all (usbmuxd answers with an error for an unknown UDID) means pairing from scratch. If
    // usbmuxd itself is unreachable, get_buid below says so.
    if let Ok(record) = mux.get_pair_record(&d.usb.udid).await {
        let mut said = false;
        loop {
            // A fresh connection each try: a refused StartSession leaves the lockdown connection unusable.
            let mut l = LockdownClient::connect(&d.provider()).await?;
            let e = match l.start_session(&record).await {
                Ok(_) => return Ok(()),
                Err(e) => e,
            };
            match classify_refusal(&e) {
                SessionRefusal::NotAccepted => break,
                SessionRefusal::Locked => {
                    if !said {
                        ui.report(Event::Wait(Wait::UnlockTrusted { device: d.name.clone() }));
                        said = true;
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
                SessionRefusal::Other => {
                    return Err(report!(
                        "couldn't start a session with {} ({e}). Unplug it, plug it in again, unlock it, and run this again",
                        d.name
                    ));
                }
            }
        }
    }
    let buid = mux.get_buid().await.map_err(no_usbmuxd)?;
    let mut said = false;
    loop {
        let mut l = LockdownClient::connect(&d.provider()).await?;
        let host_id = uuid_upper();
        // A locked device refuses at once; an unlocked one asks, and the request waits for the answer. So the
        // person is asked to tap Trust only once the request is waiting, which also replaces the Unlock words.
        let answer = {
            let pair = l.pair(host_id, buid.clone(), Some(HOST_NAME));
            tokio::pin!(pair);
            tokio::select! {
                r = &mut pair => r,
                _ = tokio::time::sleep(std::time::Duration::from_millis(750)) => {
                    ui.report(Event::Wait(Wait::Trust { device: d.name.clone() }));
                    pair.await
                }
            }
        };
        match answer {
            Ok(mut record) => {
                l.start_session(&record).await.context("the device accepted the pairing, but a session with it failed")?;
                record.udid = Some(d.usb.udid.clone());
                let bytes = Zeroizing::new(record.serialize()?);
                mux.save_pair_record(&d.usb.udid, bytes.to_vec()).await.map_err(no_usbmuxd)?;
                ui.say(&format!("{} trusts this computer", d.name));
                return Ok(());
            }
            Err(IdeviceError::PasswordProtected) => {
                if !said {
                    ui.report(Event::Wait(Wait::UnlockToTrust { device: d.name.clone() }));
                    said = true;
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
            Err(IdeviceError::UserDeniedPairing) => {
                bail!("{} didn't trust this computer. Unplug it, plug it in again, and tap Trust", d.name)
            }
            Err(e) => return Err(report!("couldn't pair with {}: {e}", d.name)),
        }
    }
}

fn uuid_upper() -> String {
    let mut b = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex::encode_upper(b);
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

/// Whether Developer Mode is on, which a development-signed app needs. If it's off, the option is revealed
/// in Settings (iOS hides it until a developer tool asks) and the person turns it on there, which restarts
/// the device (flow.rs says what then).
///
/// This is the run's first lockdown service, and where a device still locked since its restart says so:
/// StartSession works before the first unlock (ensure_trusted gets through), but StartService answers
/// "PasswordProtected" until then (checked on an iPhone, iOS 27.0.1, after Developer Mode's own restart). So
/// a locked answer waits here for the unlock, as ensure_trusted's does; once unlocked, the later services
/// (installation_proxy, house_arrest) work even if it locks again.
pub async fn developer_mode(d: &Device, ui: &dyn Frontend) -> Result<bool, Report> {
    let mut said = false;
    let mut amfi = loop {
        match AmfiClient::connect(&d.provider()).await {
            Ok(a) => break a,
            Err(e) if classify_refusal(&e) == SessionRefusal::Locked => {
                if !said {
                    ui.report(Event::Wait(Wait::Unlock { device: d.name.clone() }));
                    said = true;
                }
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
            Err(e) => return Err(report!("couldn't ask the device about Developer Mode ({e})")),
        }
    };
    if amfi.get_developer_mode_status().await? {
        return Ok(true);
    }
    let _ = amfi.reveal_developer_mode_option_in_ui().await;
    Ok(false)
}

/// Installs (or updates, keeping its data) the signed app from its IPA, saying how far along it is.
pub async fn install(d: &Device, ipa: &Path, ui: &dyn Frontend) -> Result<(), Report> {
    // Said at once, so the future it returns holds no borrow.
    let progress = |(percent, ui): (u64, &dyn Frontend)| {
        ui.report(Event::Progress(percent));
        std::future::ready(())
    };
    idevice::utils::installation::install_package_with_callback(&d.provider(), ipa, None, progress, ui)
        .await
        .map_err(|e| report!("the install failed: {e}"))?;
    Ok(())
}

/// The app's data container over AFC.
pub async fn container(d: &Device, bundle_id: &str) -> Result<AfcClient, Report> {
    let ha = HouseArrestClient::connect(&d.provider()).await?;
    ha.vend_container(bundle_id)
        .await
        .map_err(|e| report!("couldn't open Slashplayed's data on the device ({e}): is it installed?"))
}

/// Writes `data` to `path` in the container, making its folders. A file is replaced whole.
pub async fn put(afc: &mut AfcClient, path: &str, data: &[u8]) -> Result<(), Report> {
    let mut dir = String::new();
    let parts: Vec<&str> = path.split('/').collect();
    for p in &parts[..parts.len() - 1] {
        if !dir.is_empty() {
            dir.push('/');
        }
        dir.push_str(p);
        let _ = afc.mk_dir(dir.clone()).await;
    }
    let mut f = afc.open(path.to_string(), AfcFopenMode::WrOnly).await?;
    f.write_entire(data).await?;
    f.close().await?;
    Ok(())
}

/// A file's contents, or None when it isn't there.
pub async fn get(afc: &mut AfcClient, path: &str) -> Option<Vec<u8>> {
    let mut f = afc.open(path.to_string(), AfcFopenMode::RdOnly).await.ok()?;
    let data = f.read_entire().await.ok();
    let _ = f.close().await;
    data
}

/// A file's size, or None when it isn't there.
pub async fn size(afc: &mut AfcClient, path: &str) -> Option<u64> {
    afc.get_file_info(path.to_string()).await.ok().map(|i| i.size as u64)
}

/// Makes a RemotePairing record for the device over USB (lockdown's remotepairingdeviced; no prompt over
/// USB) and puts it in the app's container, as the Mac's Pairing.send does. Returns its size.
pub async fn send_pairing(d: &Device, afc: &mut AfcClient) -> Result<usize, Report> {
    let service = RemotePairingLockdownService::connect(&d.provider())
        .await
        .context("couldn't reach the device's pairing service")?;
    let mut client = service.into_client(HOST_NAME)?;
    let mut record = RpPairingFile::generate(HOST_NAME);
    // Pair-verify, then pair-setup when the device doesn't know the record (a fresh one never is).
    client
        .connect(&mut record, || async { "000000".to_string() })
        .await
        .map_err(|e| report!("the device refused the pairing ({e})"))?;
    let bytes = Zeroizing::new(record.to_bytes());
    if bytes.is_empty() {
        bail!("idevice made an empty pairing record");
    }
    put(afc, PAIRING_PATH, &bytes).await?;
    Ok(bytes.len())
}

#[cfg(test)]
mod tests {
    #[test]
    fn host_ids_are_uuids() {
        let u = super::uuid_upper();
        assert_eq!(u.len(), 36);
        assert_eq!(u.matches('-').count(), 4);
        assert_eq!(&u[14..15], "4");
        assert_eq!(u, u.to_uppercase());
    }

    #[test]
    fn only_an_unknown_host_id_repairs() {
        use super::{SessionRefusal::*, classify_refusal};
        use idevice::IdeviceError as E;
        assert_eq!(classify_refusal(&E::InvalidHostID), NotAccepted);
        assert_eq!(classify_refusal(&E::PasswordProtected), Locked);
        assert_eq!(classify_refusal(&E::DeviceLocked), Locked);
        for e in [
            E::SessionInactive,
            E::NoEstablishedConnection,
            E::UnexpectedResponse("missing EnableSessionSSL in StartSession response".into()),
            E::UnknownErrorType("SomethingNew".into()),
            E::InternalError("No context".into()),
            E::UserDeniedPairing,
        ] {
            assert_eq!(classify_refusal(&e), Other, "{e:?}");
        }
    }
}
