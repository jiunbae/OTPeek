#!/usr/bin/env python3
"""Disposable OTPeek AOSP35 UI QA only. Public fixtures; never select a physical device.
The debug app must already be installed with no active vault. This script creates and
uninstalls its fixture app data, and temporarily sets/clears a public PIN in credential flows.
"""
import argparse
import os
import re
import subprocess
import time
import xml.etree.ElementTree as E
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
ADB = ['bash', 'android/scripts/adb-fixture.sh']
PKG = 'com.otpeek.app.debug'

def adb(*args, check=True):
    r = subprocess.run(ADB + list(args), capture_output=True, text=True, timeout=35)
    if check and r.returncode:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return r

def nodes():
    adb('shell', 'uiautomator', 'dump', '/data/local/tmp/otpeek-fixture-qa.xml')
    return list(E.fromstring(adb('exec-out', 'cat', '/data/local/tmp/otpeek-fixture-qa.xml').stdout).iter('node'))

def tap(n):
    a = list(map(int, re.findall('\\d+', n.get('bounds', ''))))
    assert len(a) == 4 and a[2] > a[0] and (a[3] > a[1])
    adb('shell', 'input', 'tap', str((a[0] + a[2]) // 2), str((a[1] + a[3]) // 2))

def click(text):
    for _ in range(8):
        matches = [n for n in nodes() if n.get('text') == text or n.get('content-desc') == text]
        if matches:
            tap(matches[-1])
            return
        time.sleep(0.5)
    raise RuntimeError('Missing UI action: ' + text)

def click_id(identifier):
    for _ in range(8):
        matches = [n for n in nodes() if n.get('resource-id') == identifier]
        if matches:
            tap(matches[-1])
            return
        time.sleep(0.5)
    raise RuntimeError('Missing UI identifier: ' + identifier)

def fill(index, value):
    ns = [n for n in nodes() if n.get('class') == 'android.widget.EditText']
    tap(ns[index])
    adb('shell', 'input', 'text', value)
    adb('shell', 'input', 'keyevent', 'BACK')

def wait_text(text):
    for _ in range(12):
        if any((n.get('text') == text for n in nodes())):
            return
        time.sleep(0.3)
    print('Final fixture UI:', [(n.get('text'), n.get('resource-id')) for n in nodes() if n.get('text')], flush=True)
    raise RuntimeError('Missing UI state: ' + text)

def start():
    adb('shell', 'am', 'start', '-W', '-n', PKG + '/com.otpeek.app.MainActivity')

def create():
    start()
    wait_text('Create your encrypted vault')
    fill(0, 'fixture-master')
    fill(1, 'fixture-master')
    click('Create vault')
    wait_text('Add account')

def authenticate_pin():
    time.sleep(1)
    ns = nodes()
    print('Authentication UI:', [(n.get('class'), n.get('text'), n.get('resource-id')) for n in ns if n.get('text') or n.get('class') == 'android.widget.EditText'], flush=True)
    fields = [n for n in ns if n.get('class') == 'android.widget.EditText']
    if fields:
        tap(fields[0])
        adb('shell', 'input', 'text', '246810')
    else:
        for digit in '246810':
            click(digit)
    adb('shell', 'input', 'keyevent', 'ENTER')
    time.sleep(1)
    print('After PIN UI:', [(n.get('text'), n.get('resource-id')) for n in nodes() if n.get('text')], flush=True)
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['credential', 'credential-recovery', 'process', 'saf', 'legacy', 'camera'])
    phase = parser.parse_args().phase
    name = adb('shell', 'getprop', 'ro.boot.qemu.avd_name').stdout.strip()
    if name != 'otpeek-fixture-aosp35':
        raise RuntimeError('Only owned disposable AOSP35 AVD allowed')
    if adb('shell', 'run-as', PKG, 'test', '-d', '.', check=False).returncode != 0:
        raise RuntimeError('Install the debug app first')
    if adb('shell', 'run-as', PKG, 'test', '-f', 'no_backup/otpeek/active', check=False).returncode == 0:
        raise RuntimeError('Existing vault: refuse')
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    adb('shell', 'wm', 'dismiss-keyguard')
    adb('shell', 'am', 'force-stop', PKG)
    pin = False
    owned = False
    remote = None
    if phase == 'camera':
        adb('shell', 'pm', 'revoke', PKG, 'android.permission.CAMERA', check=False)
        adb('shell', 'pm', 'clear-permission-flags', PKG, 'android.permission.CAMERA', 'user-set', 'user-fixed', check=False)
    try:
        if phase in ['credential', 'credential-recovery']:
            adb('shell', 'locksettings', 'set-pin', '246810')
            pin = True
        owned = True
        if phase == 'legacy':
            start()
        else:
            create()
            print('CREATE PASS', flush=True)
        if phase in ['credential', 'credential-recovery']:
            click('Enable device authentication')
            authenticate_pin()
            wait_text('Device authentication enabled. Keep your vault password for recovery.')
            print('AUTH WRAP PASS', flush=True)
            click('Lock')
            click('Use device authentication')
            authenticate_pin()
            wait_text('Add account')
            print('AUTH UNWRAP PASS', flush=True)
            click('Lock')
            click('Use device authentication')
            time.sleep(1)
            adb('shell', 'input', 'keyevent', 'BACK')
            wait_text('Unlock OTPeek')
            print('AUTH CANCEL LOCKED PASS', flush=True)
            if phase == 'credential-recovery':
                previous_boot = adb('shell', 'cat', '/proc/sys/kernel/random/boot_id').stdout.strip()
                adb('reboot')
                for _ in range(90):
                    try:
                        boot = adb('shell', 'cat', '/proc/sys/kernel/random/boot_id', check=False).stdout.strip()
                        if boot and boot != previous_boot and adb('shell', 'getprop', 'sys.boot_completed', check=False).stdout.strip() == '1':
                            break
                    except subprocess.TimeoutExpired:
                        pass
                    time.sleep(2)
                else:
                    raise RuntimeError('Fixture reboot timeout')
                adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
                for _ in range(3):
                    adb('shell', 'input', 'swipe', '540', '2000', '540', '600', '600')
                    time.sleep(1)
                    if any(n.get('text') == 'Enter PIN' for n in nodes()):
                        break
                wait_text('Enter PIN')
                authenticate_pin()
                for _ in range(20):
                    if 'RUNNING_UNLOCKED' in adb('shell', 'dumpsys', 'user').stdout:
                        break
                    time.sleep(1)
                else:
                    raise RuntimeError('Fixture user is still locked')
                start()
                wait_text('Unlock OTPeek')
                click('Use device authentication')
                authenticate_pin()
                wait_text('Add account')
                print('REBOOT AUTH KEY REOPEN PASS', flush=True)
                click('Lock')
                adb('shell', 'locksettings', 'clear', '--old', '246810')
                pin = False
                click('Use device authentication')
                wait_text('Device key unavailable. Use the vault password.')
                fill(0, 'fixture-master')
                click('Unlock')
                wait_text('Add account')
                print('KEY INVALIDATION + MASTER FALLBACK PASS', flush=True)
        elif phase == 'process':
            click('Add account')
            fill(0, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ')
            fill(1, 'RFC-fixture')
            click('HOTP')
            click('Add account')
            click('Generate / consume')
            wait_text('755224')
            adb('shell', 'am', 'force-stop', PKG)
            start()
            wait_text('Unlock OTPeek')
            assert all((n.get('text') != '755224' for n in nodes()))
            fill(0, 'fixture-master')
            click('Unlock')
            wait_text('HOTP · 1')
            print('PROCESS DEATH + COUNTER PERSISTENCE PASS', flush=True)
        elif phase == 'saf':
            import uuid
            filename = 'otpeek-fixture-' + str(uuid.uuid4()) + '.otpvault'
            remote = '/sdcard/Download/' + filename
            click('Add account')
            fill(0, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ')
            fill(1, 'RFC-fixture')
            click('HOTP')
            click('Add account')
            wait_text('HOTP · 0')
            click('Back up')
            time.sleep(1)
            adb('shell', 'input', 'keyevent', 'BACK')
            wait_text('Unlock OTPeek')
            fill(0, 'fixture-master')
            click('Unlock')
            wait_text('Add account')
            print('PICKER CANCEL LOCKED PASS', flush=True)
            click('Back up')
            time.sleep(1)
            ns = [n for n in nodes() if n.get('class') == 'android.widget.EditText']
            tap(ns[0])
            adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
            adb('shell', 'input', 'text', filename)
            adb('shell', 'input', 'keyevent', 'BACK')
            click('SAVE')
            wait_text('Backup password')
            fill(0, 'fixture-master')
            fill(1, 'fixture-backup')
            fill(2, 'fixture-backup')
            click('Back up')
            wait_text('Encrypted backup saved.')
            saved = Path('.tools/verification') / filename
            adb('pull', remote, str(saved))
            data = saved.read_bytes()
            assert data[:8] == b'OTPVAULT' and b'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' not in data
            print('SAF EXPORT ENCRYPTED PASS', flush=True)
            adb('shell', 'am', 'force-stop', PKG)
            adb('uninstall', PKG)
            adb('install', '-r', 'android/app/build/outputs/apk/debug/app-debug.apk')
            start()
            click('Restore backup')
            click(filename)
            wait_text('Backup password')
            fill(0, 'fixture-backup')
            click('Restore backup')
            wait_text('HOTP · 0')
            click('Generate / consume')
            wait_text('755224')
            print('FRESH SAF RESTORE + HOTP PASS', flush=True)
            adb('shell', 'am', 'force-stop', PKG)
            start()
            wait_text('Unlock OTPeek')
            fill(0, 'fixture-backup')
            click('Unlock')
            wait_text('HOTP · 1')
            print('PROCESS DEATH + MASTER + COUNTER PASS', flush=True)
            adb('shell', 'rm', remote)
        elif phase == 'legacy':
            import uuid
            filename = 'otpeek-fixture-' + str(uuid.uuid4()) + '.otpbackup'
            remote = '/sdcard/Download/' + filename
            adb('push', '.tools/verification/legacy-fixture.otpbackup', remote)
            click('Restore backup')
            click(filename)
            wait_text('Backup password')
            fill(0, 'fixture-legacy')
            fill(1, 'fixture-new-master')
            click('Restore backup')
            wait_text('HOTP · 0')
            click('Generate / consume')
            wait_text('755224')
            print('SAF LEGACY V1 RESTORE PASS', flush=True)
            adb('shell', 'am', 'force-stop', PKG)
            start()
            wait_text('Unlock OTPeek')
            fill(0, 'fixture-new-master')
            click('Unlock')
            wait_text('HOTP · 1')
            print('LEGACY NEW MASTER + PERSISTENCE PASS', flush=True)
            adb('shell', 'rm', remote)
        elif phase == 'camera':
            click('Scan QR')
            click_id('com.android.permissioncontroller:id/permission_deny_button')
            wait_text('Camera unavailable. You can add an account manually.')
            click('OK')
            print('CAMERA DENIAL PASS', flush=True)
            click('Scan QR')
            click_id('com.android.permissioncontroller:id/permission_allow_foreground_only_button')
            wait_text('Camera-fixture')
            click('Generate / consume')
            wait_text('755224')
            print('CAMERAX IMAGE -> ZXING -> RUST -> HOTP PASS', flush=True)
        else:
            raise RuntimeError('Unknown phase')
    finally:
        if remote is not None:
            adb('shell', 'rm', '-f', remote, check=False)
        if pin:
            adb('shell', 'locksettings', 'clear', '--old', '246810', check=False)
        if owned:
            adb('shell', 'am', 'force-stop', PKG)
            adb('uninstall', PKG, check=False)
            adb('install', '-r', 'android/app/build/outputs/apk/debug/app-debug.apk')
