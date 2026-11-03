// The host tool's one call into zsign (src/sign.rs): sign an unsigned Slashplayed.app folder in place, the
// app and its JIT helper extension (PlugIns/SPJitHelper.appex) each with its own profile and entitlements,
// as the Mac signs them (ClientBuild.swift: the helper with helper-entitlements.plist, the app with
// entitlements.plist). zsign picks each bundle's asset by its profile's application-identifier, which ends
// in that bundle's ID. The shim dylibs in Frameworks/ go with the app's asset; zsign.patch keeps any
// entitlements out of a non-executable's signature, as iOS requires.
//
// Everything comes in memory (zsign.patch's InitData): the key, certificate, profiles, and entitlements are
// never written to a file. No cache (zsign's .zsign_cache in the working folder) and no log output: the
// error, if any, comes back in `err`.
#include <list>
#include <string>
#include <vector>

#include "bundle.h"
#include "common/log.h"
#include "openssl.h"

extern "C" int spz_sign_app(const char *app_dir,
                            const char *key, size_t key_len,
                            const char *cert, size_t cert_len,
                            const char *app_prov, size_t app_prov_len,
                            const char *app_ents, size_t app_ents_len,
                            const char *helper_prov, size_t helper_prov_len,
                            const char *helper_ents, size_t helper_ents_len,
                            char *err, size_t err_len) {
	auto fail = [&](const char *msg) {
		if (err && err_len) {
			snprintf(err, err_len, "%s", msg);
		}
		return 1;
	};
	ZLog::SetLogLever(ZLog::E_NONE);
	std::string k(key, key_len), c(cert, cert_len);
	std::list<ZSignAsset> assets;
	// The app's first: the root bundle's own files (the dylibs) are signed with the first asset, before
	// zsign has matched one to the bundle.
	assets.emplace_back();
	if (!assets.back().InitData(c, k, std::string(app_prov, app_prov_len), std::string(app_ents, app_ents_len), "",
	                            false, false, false)) {
		return fail("zsign couldn't use the app's profile with this certificate and key");
	}
	assets.emplace_back();
	if (!assets.back().InitData(c, k, std::string(helper_prov, helper_prov_len),
	                            std::string(helper_ents, helper_ents_len), "", false, false, false)) {
		return fail("zsign couldn't use the helper's profile with this certificate and key");
	}
	k.assign(k.size(), '\0');
	ZBundle bundle;
	std::vector<std::string> none;
	// Force: every file is signed afresh. No cache, keep the profile zsign writes (bRemoveProvision false).
	if (!bundle.SignFolder(&assets, app_dir, "", "", "", none, none, true, false, false, false)) {
		return fail("zsign couldn't sign the app");
	}
	return 0;
}
