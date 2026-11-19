// Portions derived from Phosphene, Copyright (c) 2026 kageroumado, MIT License.
// See THIRD_PARTY_LICENSES/phosphene-LICENSE.
//
// Reject XPC peers we can positively identify as non-Apple. Fails open only when
// the peer identity cannot be obtained (audit-token SPI gone), as Phosphene does.
// Deliberate: a same-user attacker gains nothing, while failing closed would blank the
// Lock Screen after an OS change.

import Foundation
import Security

enum CallerValidation {
    static func isAcceptable(_ connection: NSXPCConnection) -> Bool {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else {
            wallpaperLog("[Caller] auditToken SPI unavailable, accepting (fail-open)")
            return true
        }
        var token = connection.auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard status == errSecSuccess, let code else {
            wallpaperLog("[Caller] no peer SecCode, accepting (fail-open)", privateDetail: "status \(status)")
            return true
        }
        var appleReq: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &appleReq) == errSecSuccess,
              let appleReq else {
            wallpaperLog("[Caller] could not build requirement, accepting (fail-open)")
            return true
        }
        let check = SecCodeCheckValidity(code, [], appleReq)
        guard check == errSecSuccess else {
            wallpaperLog("[Caller] not Apple-signed", privateDetail: "pid=\(connection.processIdentifier) status \(check)")
            return false
        }
        wallpaperLog("[Caller] Apple-signed caller verified")
        return true
    }
}
