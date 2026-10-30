#!/usr/bin/env python3
"""Create matching Xray and AmneziaWG clients on an initialized server."""
import argparse
import configparser
import fcntl
import importlib.util
import io
import ipaddress
import os
import re
import secrets
import signal
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path

AWG_CONFIG = Path('/etc/amnezia/amneziawg/awg0.conf')
AWG_CLIENTS = Path('/var/lib/awg-clients')
XRAY_CLIENTS = Path('/var/lib/xray-clients')
EXPORTS = Path('/var/lib/vpn-users/exports')


def allocate_names(existing, count):
    names, number = [], 1
    while len(names) < count:
        name = f'user-{number:02d}'
        if name not in existing:
            names.append(name)
        number += 1
    return names


def allocate_addresses(server_address, occupied, count):
    interface = ipaddress.ip_interface(server_address)
    if interface.version != 4 or interface.network.prefixlen < 16:
        raise ValueError('Expected a bounded IPv4 AWG subnet')
    used = [ipaddress.ip_network(item, strict=False) for item in occupied]
    result = [str(ip) for ip in interface.network.hosts() if ip != interface.ip
              and not any(ip in network for network in used)][:count]
    if len(result) < count:
        raise ValueError('Not enough free AmneziaWG addresses')
    return result


def client_config(template, private_key, address):
    lines = template.splitlines(keepends=True)
    in_interface, replaced = False, set()
    for index, line in enumerate(lines):
        if line.strip().startswith('['):
            in_interface = line.strip().lower() == '[interface]'
        if in_interface:
            match = re.match(r'^\s*(PrivateKey|Address)\s*=', line, re.IGNORECASE)
            if match:
                key = match.group(1).lower()
                if key in replaced:
                    raise ValueError('Duplicate client configuration field')
                replaced.add(key)
                value = private_key if key == 'privatekey' else f'{address}/32'
                lines[index] = f'{match.group(1)} = {value}\n'
    if replaced != {'privatekey', 'address'}:
        raise ValueError('Incomplete client template')
    return ''.join(lines)


def build_archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        for name, data in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), 0o600, int(datetime.now().timestamp())
            archive.addfile(info, io.BytesIO(data))
    return output.getvalue()


def run(args, *, data=None):
    result = subprocess.run(args, input=data, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip()[:300]}')
    return result.stdout.strip()


def atomic_write(path, content, mode):
    fd, name = tempfile.mkstemp(prefix='.vpn-users-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def config_values(text):
    interface_text = text.split('[Peer]', 1)[0]
    parser = configparser.ConfigParser()
    parser.read_string(interface_text)
    return parser['Interface']


def make_users(count, link_module):
    if os.geteuid() != 0:
        raise RuntimeError('Run as root')
    if not (1 <= count <= 250):
        raise ValueError('Count must be between 1 and 250')
    for service in ('xray', 'awg-quick@awg0'):
        run(['systemctl', 'is-active', '--quiet', service])
    original = AWG_CONFIG.read_text(encoding='utf-8')
    template = (AWG_CLIENTS / 'user-01.conf').read_text(encoding='utf-8')
    interface = config_values(original)
    occupied = set(re.findall(r'^\s*AllowedIPs\s*=\s*([^\n#]+)', original, re.MULTILINE))
    occupied = {item.strip() for value in occupied for item in value.split(',')}
    live = run(['awg', 'show', 'awg0', 'allowed-ips'])
    for line in live.splitlines():
        _, _, values = line.partition('\t')
        occupied.update(v.strip() for v in values.split(',') if v.strip() and v.strip() != '(none)')
    existing = set(run(['xray-clients', 'list']).splitlines())
    existing.update(p.stem for p in AWG_CLIENTS.glob('*.conf'))
    existing.update(p.stem for p in XRAY_CLIENTS.glob('*.txt'))
    existing.update(p.stem for p in XRAY_CLIENTS.glob('*.png'))
    existing.update(re.findall(r'(?m)^# (user-[0-9]+)\s*$', original))
    names = allocate_names(existing, count)
    addresses = allocate_addresses(interface['Address'].split(',')[0].strip(), occupied, count)
    # Validate conversion before changing either service.
    link_module.make_link(template)
    created_xray, created_peers, created_files = [], [], []
    archive_path = None
    try:
        contents = {}
        for name, address in zip(names, addresses):
            private = run(['awg', 'genkey'])
            public = run(['awg', 'pubkey'], data=private + '\n')
            profile = client_config(template, private, address)
            link = link_module.make_link(profile)
            created_xray.append(name)
            run(['xray-clients', 'add', name])
            run(['awg', 'set', 'awg0', 'peer', public, 'allowed-ips', address + '/32'])
            created_peers.append(public)
            current = AWG_CONFIG.read_text(encoding='utf-8')
            atomic_write(AWG_CONFIG, current.rstrip() + f'\n\n[Peer]\n# {name}\nPublicKey = {public}\nAllowedIPs = {address}/32\n', 0o600)
            path = AWG_CLIENTS / f'{name}.conf'
            if path.exists():
                raise RuntimeError(f'Client file already exists: {name}')
            atomic_write(path, profile, 0o600)
            created_files.append(path)
            contents[f'{name}/vless.txt'] = (XRAY_CLIENTS / f'{name}.txt').read_bytes()
            contents[f'{name}/vless.png'] = (XRAY_CLIENTS / f'{name}.png').read_bytes()
            contents[f'{name}/amneziawg.conf'] = profile.encode()
            contents[f'{name}/amneziawg.vpn'] = (link + '\n').encode()
        EXPORTS.mkdir(parents=True, mode=0o700, exist_ok=True)
        os.chmod(EXPORTS.parent, 0o700)
        os.chmod(EXPORTS, 0o700)
        archive_path = EXPORTS / ('vpn-users-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(4) + '.tar.gz')
        fd = os.open(archive_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(build_archive(contents))
        return names, archive_path
    except BaseException:
        failures = []
        for public in reversed(created_peers):
            try:
                run(['awg', 'set', 'awg0', 'peer', public, 'remove'])
            except Exception:
                failures.append('AWG live peer')
        try:
            atomic_write(AWG_CONFIG, original, 0o600)
        except Exception:
            failures.append('AWG configuration')
        for path in created_files:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                failures.append('AWG client file ' + path.name)
        for name in reversed(created_xray):
            try:
                if name in set(run(['xray-clients', 'list']).splitlines()):
                    run(['xray-clients', 'remove', name])
                else:
                    subprocess.run(['xray', 'api', 'rmu', '-s', '127.0.0.1:10085', '-tag', 'vless-in', name], capture_output=True)
            except Exception:
                failures.append('Xray client ' + name)
        if archive_path:
            archive_path.unlink(missing_ok=True)
        if failures:
            print('Rollback incomplete: ' + ', '.join(failures), file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('count', type=int)
    args = parser.parse_args()
    os.umask(0o077)
    spec = importlib.util.spec_from_file_location('awg_link', Path(__file__).with_name('awg-link.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    def interrupted(signum, frame):
        raise InterruptedError('Interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        with open('/run/lock/vpn-users.lock', 'w', encoding='utf-8') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            names, archive = make_users(args.count, module)
        print('Created: ' + ', '.join(names))
        print('ARCHIVE=' + str(archive))
    except Exception as exc:
        print('Error: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
