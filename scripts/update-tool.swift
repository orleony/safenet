// Release signing tool for SafeNet updates (Ed25519, CryptoKit). Built and run by scripts/release.sh.
//   update-tool keygen <keyfile>        new private key (refuses to overwrite), prints the public key
//   update-tool pubkey <keyfile>        prints the public key of an existing private key
//   update-tool sign <keyfile> <file>   prints the base64 signature of the file's exact bytes
//   update-tool verify <pubkey> <file> <sigfile>   exit 0 when the signature is valid
// The private key file holds the base64 raw key, mode 0600. Keep it out of the repository.
import Foundation
import CryptoKit

func die(_ m: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8)); exit(code)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { die("cannot read private key \(path)") }
    return key
}

let a = Array(CommandLine.arguments.dropFirst())
switch (a.first, a.count) {
case ("keygen", 2):
    let path = a[1]
    if FileManager.default.fileExists(atPath: path) { die("\(path) already exists: not overwritten") }
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    let key = Curve25519.Signing.PrivateKey()
    let old = umask(0o077)
    let ok = FileManager.default.createFile(atPath: path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                            attributes: [.posixPermissions: 0o600])
    umask(old)
    guard ok else { die("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("pubkey", 2):
    print(loadKey(a[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    guard let data = FileManager.default.contents(atPath: a[2]) else { die("cannot read \(a[2])") }
    guard let sig = try? loadKey(a[1]).signature(for: data) else { die("signing failed") }
    print(sig.base64EncodedString())
case ("verify", 4):
    guard let raw = Data(base64Encoded: a[1]), let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let data = FileManager.default.contents(atPath: a[2]),
          let sigText = try? String(contentsOfFile: a[3], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { die("bad input") }
    exit(pk.isValidSignature(sig, for: data) ? 0 : 1)
default:
    die("usage: update-tool keygen <keyfile> | pubkey <keyfile> | sign <keyfile> <file> | verify <pubkey> <file> <sigfile>", 2)
}
