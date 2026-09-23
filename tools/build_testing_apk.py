#!/usr/bin/env python3
"""Build a separately signed, optimized ARM64 APK for private testing, never production."""
import argparse
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import subprocess
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--defines', type=Path, required=True)
    parser.add_argument('--flutter', default=os.environ.get('FLUTTER', str(Path.home()/'.local/share/vaachak/flutter/bin/flutter')))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    config = json.loads(args.defines.read_text())
    if config.get('VAACHAK_ENV') != 'dev':
        raise SystemExit('The shared testing APK must target the dev environment.')
    if any(config.get(k) for k in ('LOCAL_TEST_ACCESS_TOKEN','PHASE3_TEST_CONFIG','SUPABASE_SERVICE_ROLE_KEY')):
        raise SystemExit('Do not embed test sessions or privileged backend credentials.')
    key = config.get('SUPABASE_ANON_KEY','')
    if not key.startswith('sb_publishable_'):
        try:
            claims=key.split('.')[1]
            if json.loads(base64.urlsafe_b64decode(claims+'='*(-len(claims)%4))).get('role')!='anon':
                raise ValueError()
        except (ValueError,IndexError):
            raise SystemExit('A public Supabase key is required.')
    if not config.get('SUPABASE_URL','').startswith('https://'):
        raise SystemExit('Testing server must use HTTPS.')
    state=Path.home()/'.local/share/vaachak/testing-signing';state.mkdir(parents=True,exist_ok=True);state.chmod(0o700)
    signing=state/'key.properties';keystore=state/'testing.p12'
    if not signing.exists():
        if keystore.exists(): raise SystemExit('Existing test key needs its original signing configuration; refusing to replace it.')
        candidates=[Path(os.environ.get('JAVA_HOME','/nonexistent'))/'bin/keytool',Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool'),Path('/opt/homebrew/opt/openjdk@21/bin/keytool')]
        keytool=next((str(p) for p in candidates if p.is_file()),shutil.which('keytool'))
        if not keytool: raise SystemExit('Install a JDK before building.')
        password=secrets.token_urlsafe(32)
        subprocess.run([keytool,'-genkeypair','-keystore',str(keystore),'-storetype','PKCS12',
                        '-alias','vaachak-testing','-keyalg','RSA','-keysize','3072','-validity','10000',
                        '-storepass:env','VAACHAK_TEMP_KEY_PASS','-keypass:env','VAACHAK_TEMP_KEY_PASS',
                        '-dname','CN=VaachakAI Private Testing, O=VaachakAI, C=IN','-noprompt'],
                       env={**os.environ,'VAACHAK_TEMP_KEY_PASS':password},check=True)
        keystore.chmod(0o600)
        with signing.open('x') as file:
            os.chmod(signing,0o600)
            file.write(f'storeFile={keystore}\nstorePassword={password}\nkeyAlias=vaachak-testing\nkeyPassword={password}\n')
    counter=state/'last-build-code'
    number=max(int(time.time()),int(counter.read_text())+1 if counter.exists() else 1)
    if number>=2100000000: raise SystemExit('Choose a new version-code policy before the Play integer limit.')
    counter.write_text(str(number));counter.chmod(0o600)
    env={**os.environ,'VAACHAK_TEST_BUILD':'1','VAACHAK_TEST_SIGNING_FILE':str(signing)}
    subprocess.run([args.flutter,'build','apk','--release','--target-platform','android-arm64','--split-per-abi',
                    '--build-number',str(number),f'--dart-define-from-file={args.defines.resolve()}'],
                   cwd=root/'apps/vaachak_app',env=env,check=True)
    source=root/'apps/vaachak_app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
    with zipfile.ZipFile(source) as apk:
        names=apk.namelist()
        if any(n.startswith(('lib/x86/','lib/x86_64/','lib/armeabi-v7a/')) for n in names):
            raise SystemExit('Unexpected architectures in ARM64 test APK.')
        if 'assets/flutter_assets/kernel_blob.bin' in names:
            raise SystemExit('A debug kernel must not be included in the shared APK.')
    sdk=Path(os.environ.get('ANDROID_HOME', os.environ.get('ANDROID_SDK_ROOT', str(Path.home()/'Library/Android/sdk'))))
    aapt=next(iter(sorted((sdk/'build-tools').glob('*/aapt'), reverse=True)),None)
    if aapt is None: raise SystemExit('Android SDK aapt is required to verify the packaged version.')
    badging=subprocess.check_output([str(aapt),'dump','badging',str(source)],text=True)
    version_code=int(re.search(r"versionCode='(\d+)'",badging).group(1))
    if "name='ai.vaachak.vaachak_app.testing'" not in badging or 'application-debuggable' in badging:
        raise SystemExit('Unexpected application identity or debuggable APK.')
    output=root/'build/share';output.mkdir(parents=True,exist_ok=True)
    target=output/f'VaachakAI-testing-arm64-{number}.apk';shutil.copy2(source,target)
    checksum=hashlib.sha256(target.read_bytes()).hexdigest()
    (target.with_suffix('.apk.sha256')).write_text(f'{checksum}  {target.name}\n')
    result={'apk':str(target),'bytes':target.stat().st_size,'sha256':checksum,'applicationId':'ai.vaachak.vaachak_app.testing',
            'environment':'dev','buildNumber':number,'androidVersionCode':version_code,'signing':'separate persistent private-testing key'}
    (output/'latest-testing-build.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()
