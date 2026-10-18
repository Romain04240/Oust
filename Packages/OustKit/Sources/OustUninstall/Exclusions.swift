import Foundation

/// Les applications qu'Oust! ne désinstalle jamais (voir `AppExclusion`).
///
/// Deux signaux, dans cet ordre : la structure du paquet (une extension de
/// remplissage des mots de passe, une extension réseau ne mentent pas), puis
/// l'identifiant et le nom, pour les éditeurs qui n'en embarquent pas. La liste
/// de noms penche du côté prudent : protéger à tort une application, c'est
/// l'obliger à passer par le Finder ; la désinstaller à tort, c'est perdre un
/// coffre de mots de passe.
enum Exclusions {

    static func reason(bundleID: String?, name: String, fileName: String,
                       embedded: [AppCatalog.EmbeddedBundle]) -> AppExclusion? {
        guard let bundleID, !bundleID.isEmpty else { return .unidentified }
        let id = bundleID.lowercased()
        if id.hasPrefix("com.apple.") { return .apple }

        // La structure d'abord.
        let points = embedded.compactMap(\.extensionPoint)
        if points.contains(where: { $0.hasPrefix("com.apple.authentication-services-credential-provider") }) {
            return .passwordManager
        }
        if points.contains(where: { $0.hasPrefix("com.apple.networkextension") })
            || embedded.contains(where: \.isNetworkExtension) {
            return .vpn
        }

        let names = [name, fileName].map { $0.lowercased() }
        if passwordManagerIDs.contains(where: { id.hasPrefix($0) })
            || names.contains(where: { candidate in passwordManagerNames.contains { candidate.contains($0) } }) {
            return .passwordManager
        }
        if id.contains("vpn") || vpnIDs.contains(where: { id.hasPrefix($0) })
            || names.contains(where: { candidate in
                containsWord("vpn", in: candidate) || vpnNames.contains { containsWord($0, in: candidate) }
            }) {
            return .vpn
        }
        if embedded.contains(where: \.isSystemExtension) { return .systemExtension }
        return nil
    }

    /// Un nom de VPN comme mot entier, ou « vpn » en fin de mot (« NordVPN ») :
    /// « Outline » est un VPN, « OmniOutliner » n'en est pas un.
    static func containsWord(_ word: String, in text: String) -> Bool {
        if text == word || text.hasPrefix(word + " ") || text.contains(" " + word + " ") { return true }
        return word == "vpn" ? text.hasSuffix(word) || text.contains(word + " ") : text.hasSuffix(" " + word)
    }

    static let passwordManagerIDs = [
        "com.1password.", "com.agilebits.", "com.bitwarden.", "com.lastpass.", "com.dashlane.",
        "org.keepassxc.", "com.keepassium.", "in.sinew.enpass", "com.enpass.", "com.nordpass.",
        "me.proton.pass", "ch.protonmail.pass", "com.callpod.keeper", "com.keepersecurity.", "com.siber.roboform",
        "com.markmcguill.strongbox", "com.mikey.macpass", "com.outercorner.secrets", "com.passwarden.",
    ]

    static let passwordManagerNames = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "nordpass", "proton pass",
        "keeper password", "roboform", "strongbox", "macpass", "passwarden", "password manager",
        "gestionnaire de mots de passe",
    ]

    static let vpnIDs = [
        "com.wireguard.", "net.tunnelblick.", "com.viscosityvpn.", "com.sparklabs.viscosity", "io.tailscale.",
        "com.zerotier.", "com.cloudflare.1dot1dot1dot1", "com.paloaltonetworks.globalprotect", "com.fortinet.",
        "com.cisco.anyconnect", "com.cisco.secureclient", "net.pulsesecure.", "com.ivanti.", "net.mullvad.",
        "org.openvpn.", "net.openvpn.", "org.outline.", "com.windscribe.", "com.surfshark.", "com.cyberghost.",
        "com.tunnelbear.", "com.privateinternetaccess.", "com.expressvpn.", "com.nordvpn.", "ch.protonvpn.",
        "me.proton.vpn", "com.adguard.vpn", "net.ivpn.", "com.hideme.",
    ]

    static let vpnNames = [
        "tunnelblick", "viscosity", "wireguard", "tailscale", "zerotier", "cloudflare warp", "globalprotect",
        "forticlient", "anyconnect", "secure client", "pulse secure", "ivanti secure", "mullvad", "openvpn",
        "outline", "windscribe", "surfshark", "cyberghost", "tunnelbear", "private internet access",
    ]
}
