// The Backend that talks to the real device (device.rs, over usbmuxd) and Apple (account.rs, provision.rs),
// for flow.rs. It holds what one run makes between the steps: the kit in a scratch folder, the developer
// session (dropped as soon as the profiles are made), the signing identity and profiles, and the app's
// container on the device.

use std::path::Path;

use idevice::afc::AfcClient;
use isideload::dev::{developer_session::DeveloperSession, teams::DeveloperTeam};
use rootcause::prelude::*;
use zeroize::Zeroizing;

use crate::{
    account, ddi, device,
    flow::{Backend, DeviceInfo, Frontend},
    kit, provision, secret, sign,
};

pub struct Live {
    scratch: secret::Scratch,
    kit: Option<kit::Kit>,
    /// The devices of the last list, for their usbmuxd handles.
    devices: Vec<device::Device>,
    session: Option<DeveloperSession>,
    /// What the device keeps of the sign-in (account::device_token). A credential.
    device_token: Option<Zeroizing<Vec<u8>>>,
    signing: Option<(provision::Identity, Vec<u8>, Vec<u8>)>,
    afc: Option<AfcClient>,
}

impl Live {
    pub fn new() -> Result<Self, Report> {
        Ok(Self {
            scratch: secret::Scratch::new("companion")?,
            kit: None,
            devices: Vec::new(),
            session: None,
            device_token: None,
            signing: None,
            afc: None,
        })
    }

    fn device(&self, d: &DeviceInfo) -> Result<&device::Device, Report> {
        self.devices
            .iter()
            .find(|x| x.usb.udid == d.udid)
            .ok_or_else(|| report!("{} isn't on USB any more: plug it in again and unlock it", d.name))
    }

    fn afc(&mut self) -> Result<&mut AfcClient, Report> {
        self.afc.as_mut().ok_or_else(|| report!("the app's container isn't open"))
    }
}

impl Backend for Live {
    async fn kit(&mut self, path: Option<&Path>) -> Result<(String, String), Report> {
        let (bytes, from) = kit::fetch(path).await?;
        let kit = kit::extract(&bytes, self.scratch.path())?;
        drop(bytes);
        let version = kit.version.clone();
        self.kit = Some(kit);
        Ok((version, from))
    }

    async fn devices(&mut self) -> Result<Vec<DeviceInfo>, Report> {
        self.devices = device::list().await?;
        Ok(self.devices.iter().map(device::Device::info).collect())
    }

    async fn trust(&mut self, d: &DeviceInfo, ui: &dyn Frontend) -> Result<(), Report> {
        device::ensure_trusted(self.device(d)?, ui).await
    }

    async fn developer_mode(&mut self, d: &DeviceInfo, ui: &dyn Frontend) -> Result<bool, Report> {
        device::developer_mode(self.device(d)?, ui).await
    }

    async fn sign_in(&mut self, apple_id: &str, anisette: &str, server_client_info: bool, ui: &dyn Frontend) -> Result<(), Report> {
        let (session, token) = account::sign_in(apple_id, anisette, server_client_info, ui).await?;
        self.session = Some(session);
        self.device_token = token;
        Ok(())
    }

    async fn teams(&mut self) -> Result<Vec<DeveloperTeam>, Report> {
        use isideload::dev::teams::TeamsApi;
        let session = self.session.as_mut().ok_or_else(|| report!("not signed in"))?;
        session.list_teams().await
    }

    async fn provision(
        &mut self,
        team: &DeveloperTeam,
        d: &DeviceInfo,
        bundle_id: &str,
        apple_id: &str,
        ui: &dyn Frontend,
    ) -> Result<bool, Report> {
        let usb = self.device(d)?.usb.clone();
        // Taken: the session goes away with this step, once the profiles are made.
        let mut session = self.session.take().ok_or_else(|| report!("not signed in"))?;
        provision::register_device(&mut session, team, &usb, &d.name, ui).await?;
        let (app_id, helper_id) = provision::app_ids(&mut session, team, bundle_id, ui).await?;
        let eva = provision::capabilities(&mut session, team, &app_id, ui).await?;
        let id = provision::identity(&mut session, team, apple_id, ui).await?;
        let (app_profile, helper_profile, free) =
            provision::profiles(&mut session, team, &app_id, &helper_id, &usb.udid, &id, eva, ui).await?;
        drop(session);
        self.signing = Some((id, app_profile, helper_profile));
        Ok(free)
    }

    async fn sign_and_install(&mut self, d: &DeviceInfo, team: &DeveloperTeam, bundle_id: &str, free: bool, ui: &dyn Frontend) -> Result<(), Report> {
        let (id, app_profile, helper_profile) = self.signing.take().ok_or_else(|| report!("no signing identity"))?;
        let kit = self.kit.as_ref().ok_or_else(|| report!("no device kit"))?;
        kit::set_bundle_id(&kit.app, bundle_id)?;
        let dropped: &[&str] = if free { kit::FREE_TEAM_DROPPED } else { &[] };
        let app_ents = kit::entitlements(&kit.entitlements, &team.team_id, bundle_id, dropped)?;
        let helper_ents = kit::entitlements(&kit.helper_entitlements, &team.team_id, &kit::helper_id(bundle_id), &[])?;
        let key_pem = Zeroizing::new(
            rsa::pkcs8::EncodePrivateKey::to_pkcs8_pem(&id.key, rsa::pkcs8::LineEnding::LF)
                .map_err(|_| report!("couldn't encode the key"))?
                .to_string(),
        );
        sign::sign_app(
            &kit.app,
            &sign::Inputs {
                key_pem: &key_pem,
                cert_der: &id.cert_der,
                app_profile: &app_profile,
                app_entitlements: &app_ents,
                helper_profile: &helper_profile,
                helper_entitlements: &helper_ents,
            },
        )?;
        drop(key_pem);
        drop(id);
        ui.say("signed");
        let ipa = self.scratch.path().join("Slashplayed.ipa");
        kit::ipa(&kit.app, &ipa)?;
        ui.say(&format!("installing on {} ({} MB)", d.name, std::fs::metadata(&ipa)?.len() / 1_000_000));
        device::install(self.device(d)?, &ipa, ui).await?;
        ui.say("installed");
        Ok(())
    }

    async fn has_pairing(&mut self, d: &DeviceInfo, bundle_id: &str) -> Result<bool, Report> {
        let mut afc = device::container(self.device(d)?, bundle_id).await?;
        let has = device::size(&mut afc, device::PAIRING_PATH).await.unwrap_or(0) > 0;
        self.afc = Some(afc);
        Ok(has)
    }

    async fn send_pairing(&mut self, d: &DeviceInfo) -> Result<usize, Report> {
        let dev = self.device(d)?.clone();
        device::send_pairing(&dev, self.afc()?).await
    }

    async fn send_ddi(&mut self, ui: &dyn Frontend) -> Result<bool, Report> {
        ddi::send_if_needed(self.afc()?, ui).await
    }

    async fn send_token(&mut self) -> Result<bool, Report> {
        // The launcher imports it into its keychain and deletes the file.
        let Some(t) = self.device_token.take() else { return Ok(false) };
        device::put(self.afc()?, "Library/spappletoken.json", &t).await?;
        drop(t);
        Ok(true)
    }
}
