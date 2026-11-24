# Spec: passkeys kept inside Cairn

Apple's system passkeys need an entitlement only the paid program grants, so
Cairn keeps its own: a software authenticator. New passkeys made in Cairn live
in its keychain items, signed only after Touch ID. Existing iCloud passkeys
can't be moved (Apple offers no export Cairn can receive).

The page plumbing already exists in `Passkeys.swift` (upstream): it takes a
page's `navigator.credentials.create/get`, checks the frame, and answers with
`registrationReply` / `assertionReply`. This adds a second answerer for a build
without the entitlement (`Preferences.entitledToPasskeys == false`).

## Pieces and who owns them

1. `SoftAuthenticator.swift` (pure, no keychain, no UI): CBOR writer, authenticator
   data, `makeCredential` (attestation `none`, ES256 / P-256, COSE key), and
   `assertion` (sign authData || SHA256(clientDataJSON)). Flags: UP always,
   UV when proven, AT on create, BE/BS 0 (device-bound). Sign counter 0.
2. `PasskeyStore.swift` (keychain only): the records and private keys.
3. Integration in `Passkeys.perform` + conditional list (`offered`, `sign`):
   Touch ID (`Vault.prove`), save/choose sheets, excludeCredentials, errors
   as the spec's DOMExceptions (NotAllowedError, InvalidStateError).
4. A Passkeys tab on the Passwords page: list, show details, remove.

## Shared type (PasskeyRecord.swift)

`PasskeyRecord`: rp, credentialID, userHandle, userName, displayName, created,
lastUsed, with `id`. The private key is never in it.

## PasskeyStore API (contract)

    enum PasskeyStore {
        static func save(_ record: PasskeyRecord, key: P256.Signing.PrivateKey) -> Bool   // replaces same rp+userHandle
        static func all() -> [PasskeyRecord]                                              // no keys read
        static func records(rp: String, allowed: [Data]) -> [PasskeyRecord]               // allowed empty = every one for rp
        static func key(for record: PasskeyRecord) -> P256.Signing.PrivateKey?
        static func touch(_ record: PasskeyRecord)                                        // lastUsed = now
        @discardableResult static func remove(_ record: PasskeyRecord) -> Bool
    }

## SoftAuthenticator API (contract)

    enum SoftAuthenticator {
        struct Made { let record: PasskeyRecord; let key: P256.Signing.PrivateKey; let attestationObject: Data }
        static func makeCredential(rp: String, clientDataJSON: Data, userHandle: Data, userName: String, displayName: String, userVerified: Bool, now: Date) -> Made
        static func assertion(rp: String, clientDataJSON: Data, key: P256.Signing.PrivateKey, userVerified: Bool) -> (authenticatorData: Data, signature: Data)
        static func authenticatorData(rp: String, flags: UInt8, counter: UInt32, attested: (credentialID: Data, coseKey: Data)?) -> Data
        static func cbor(_ value: CBORValue) -> Data   // minimal writer: uint, negative int, bytes, text, array, map (canonical key order)
    }

## Status

Built on branch `passkeys-1`: SoftAuthenticator (7 tests, CBOR vectors from RFC 8949, signatures verified), PasskeyStore (5 tests, in the test world), the hooks in `Passkeys.perform` / `wait` / `sign` through `SoftPasskeys`, a Passkeys tab on the Passwords page, and the Settings line. Not tried against a real site yet.
