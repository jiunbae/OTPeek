#!/usr/bin/env python3
import os, subprocess, time, runpy
from pathlib import Path
root = Path(__file__).resolve().parents[2]
os.chdir(root)
env = os.environ.copy()
env.update(ANDROID_USER_HOME=str(root / '.tools/android-user'), ANDROID_EMULATOR_HOME=str(root / '.tools/android-user'), ANDROID_AVD_HOME=str(root / '.tools/avd'), ANDROID_ADB_SERVER_PORT='5045', ADB_SERVER_SOCKET='tcp:127.0.0.1:5045', OTPEEK_EMULATOR_SERIAL='emulator-5662', ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL='5')
os.environ.update(env)
with Path('.tools/logs/emulator-bundle-16k.log').open('w') as log:
    emu = subprocess.Popen(['.tools/sdk/emulator/emulator', '-avd', 'otpeek-fixture-36-16k', '-port', '5662', '-memory', '3072', '-cores', '4', '-gpu', 'host', '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot', '-no-metrics'], env=env, stdout=log, stderr=subprocess.STDOUT)
    owned = False
    try:
        for _ in range(90):
            if emu.poll() is not None:
                raise RuntimeError('Fixture AVD could not start; stop it before this QA run')
            try:
                r = subprocess.run(['bash', 'android/scripts/adb-fixture.sh', 'shell', 'getprop', 'sys.boot_completed'], capture_output=True, text=True, timeout=10)
                if r.stdout.strip() == '1':
                    break
            except subprocess.TimeoutExpired:
                pass
            time.sleep(2)
        else:
            raise RuntimeError('16KB AVD boot timeout')
        h = runpy.run_path('android/qa/fixture-ui.py')
        g = h['adb'].__globals__
        g['PKG'] = 'com.otpeek.app'
        adb = h['adb']
        if adb('shell', 'getprop', 'ro.boot.qemu.avd_name').stdout.strip() != 'otpeek-fixture-36-16k':
            raise RuntimeError('Wrong fixture AVD')
        if adb('shell', 'getconf', 'PAGE_SIZE').stdout.strip() != '16384':
            raise RuntimeError('Not a 16KB runtime')
        if adb('shell', 'pm', 'path', 'com.otpeek.app', check=False).stdout.strip():
            raise RuntimeError('Existing release package: refuse')
        adb('install', '-r', '.tools/verification/release-universal.apk')
        owned = True
        adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
        adb('shell', 'wm', 'dismiss-keyguard')
        h['create']()
        print('AAB -> locally fixture-signed R8 universal APK: 16KB native vault-create PASS', flush=True)
        h['click']('Add account')
        h['fill'](0, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ')
        h['fill'](1, 'RFC-fixture')
        h['click']('HOTP')
        h['click']('Add account')
        h['click']('Generate / consume')
        h['wait_text']('755224')
        adb('shell', 'am', 'force-stop', 'com.otpeek.app')
        h['start']()
        h['wait_text']('Unlock OTPeek')
        h['fill'](0, 'fixture-master')
        h['click']('Unlock')
        h['wait_text']('HOTP · 1')
        print('16KB R8 manual HOTP + process death + password reopen + persisted counter PASS', flush=True)
    finally:
        if owned:
            subprocess.run(['bash', 'android/scripts/adb-fixture.sh', 'uninstall', 'com.otpeek.app'], capture_output=True, timeout=30)
        emu.terminate()
        try:
            emu.wait(timeout=15)
        except subprocess.TimeoutExpired:
            emu.kill()
            emu.wait()
