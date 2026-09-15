#!/usr/bin/env python3
"""Structural guards for the handoff integration; not a Swift runtime test."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def violations(load):
    coordinator = load('Seal/Core/Signing/SigningCoordinator.swift')
    install_body = coordinator.split('private func installSignedIPA(', 1)[1].split('private func removeStaleProfiles(', 1)[0]
    self_install = install_body.split('if app.isSeal {', 1)[1].split('\n        do {', 1)[0]
    portal = load('Seal/Infrastructure/Signing/ApplePortalSigningService.swift')
    certificate_service = load('Seal/Infrastructure/Signing/ApplePortalCertificateService.swift')
    profile_binding = load('Seal/Core/Signing/ProvisioningProfileBinding.swift')
    settings = load('Seal/Features/Settings/SettingsViewModel.swift')
    checks = [
        ('本机均有私钥' not in coordinator, 'cleanup must not infer private keys from no revocable certificates'),
        ('revokeReplacedSealCertificate(' not in coordinator, 'self-update must not revoke old identity after install callback'),
        (portal.count('CertificateRequestFailurePolicy.requestFailure') == 2 and 'CertificateRequestFailurePolicy.requestFailure' in certificate_service,
         'both certificate creation paths must use the shared error policy'),
        ('SigningCertificateMaterialPolicy.availableCertificate' in portal and 'SigningCertificateMaterialPolicy.availableCertificate' in coordinator,
         'signing and cleanup must share actual local private-key validation'),
        ('preservingSigningMaterial(from:' in settings, 'reauthentication must retain historical P12 material'),
        ('selfSigningHandoffStore.prepare(' in coordinator
         and coordinator.index('selfSigningHandoffStore.prepare(') < coordinator.index('try await installChannel.install('),
         'handoff must persist before installation'),
        (load('Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift').count('forceUpgrade: true') == 2,
         'Seal self-replacement must explicitly issue an Upgrade even if revoked apps disappear from lookup'),
        ('force_upgrade: u8' in load('Vendor/Minimuxer/RustBridge/src/bridge_idevice.rs')
         and 'should_upgrade(force_upgrade, discovered_as_installed)' in load('Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs'),
         'the explicit self-upgrade flag must cross the Swift/Rust FFI and control installation_proxy mode'),
        ('DeviceProfileInspector.containsProfile(' in coordinator
         and 'verifyInstalled(bundleID: effectiveBundleID)' in coordinator
         and 'SEAL-INSTALL-731' in coordinator
         and self_install.index('guard verifiedReplacement else') < self_install.index('updated.state = .installed'),
         'self-replacement must verify the installed bundle and exact new profile identity before reporting success'),
        ('removeAllProfiles(' not in load('Seal/Infrastructure/Installation/DeviceProfileCleaner.swift')
         and 'status == .confirmed' in load('Seal/Core/Renewal/SelfAppRegistrar.swift')
         and 'DeviceProfileCleaner.removeStaleProfiles(' in load('Seal/Core/Renewal/SelfAppRegistrar.swift'),
         'old Seal profiles may only be cleaned after the replacement process confirms its running identity'),
        ('rotationCandidates(' in portal and 'failure.code == "SEAL-CERT-204b"' in portal
         and 'removeStoredCertificateMaterial' in portal and 'revokeCertificate(' in portal,
         '3022 must rotate an unusable certificate and retry certificate creation in the same portal transaction'),
        (portal.index('let prepared = try signingWorkspace.prepare(') < portal.index('let identity = try await signingIdentity('),
         'IPA and disk preflight must complete before a certificate can be rotated'),
        ('证书决策：' in portal and '证书轮换：' in portal and '描述文件核验：' in portal,
         'certificate, rotation, and fresh profile evidence must be present in exported diagnostics'),
        (coordinator.index('beginBackgroundTask') < coordinator.index('portal.sign(')
         and coordinator.rindex('endBackgroundTask') > coordinator.index('portal.sign('),
         'Seal self-renewal must hold an iOS background execution assertion across signing and installation'),
        ('requestedAfter:' in profile_binding and 'minimumRemainingLifetime:' in profile_binding,
         'embedded profile validation must prove this request produced a fresh full-window profile'),
        ('guard Self.certificateReusable(fullCert)' in portal,
         'a newly created certificate must itself cover the complete seven-day profile window'),
        ('let rollbackSecret = (try? await keychain.load(accountID: accountID))' in coordinator
         and 'let currentAccounts = try? await accountRepository.fetchAll()' in coordinator
         and 'keychain.save(rollbackSecret' in coordinator,
         'post-rotation persistence failure must not restore an Apple-revoked certificate'),
        ('resignAppsAffectedByCertificateRotation(' in coordinator
         and 'if lhs.isSeal != rhs.isSeal { return lhs.isSeal == false }' in coordinator,
         'apps affected by rotation must be restored automatically with Seal installed last'),
    ]
    return [message for valid, message in checks if not valid]

def read(path):
    return (ROOT / path).read_text(encoding='utf-8-sig')

if __name__ == '__main__':
    failures = violations(read)
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    print('PASS: certificate handoff structural checks; Swift CI/device verification still required.')
