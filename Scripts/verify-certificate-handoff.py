#!/usr/bin/env python3
"""Structural guards for the handoff integration; not a Swift runtime test."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def violations(load):
    coordinator = load('Seal/Core/Signing/SigningCoordinator.swift')
    portal = load('Seal/Infrastructure/Signing/ApplePortalSigningService.swift')
    certificate_service = load('Seal/Infrastructure/Signing/ApplePortalCertificateService.swift')
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
