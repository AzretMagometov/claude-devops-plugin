#!/usr/bin/env python3
"""Convert an AmneziaWG 3.1 client configuration to an AmneziaVPN key."""
import argparse
import base64
import configparser
import json
import struct
import sys
import zlib


def make_link(text):
    parser = configparser.ConfigParser()
    try:
        parser.read_string(text)
        interface, peer = parser['Interface'], parser['Peer']
        host, port = peer['Endpoint'].rsplit(':', 1)
        fields = {'config': text, 'hostName': host, 'port': int(port),
                  'client_priv_key': interface['PrivateKey'], 'client_ip': interface['Address'],
                  'server_pub_key': peer['PublicKey'], 'allowed_ips': [s.strip() for s in peer['AllowedIPs'].split(',')],
                  'persistent_keep_alive': peer.get('PersistentKeepalive', '25'), 'mtu': interface.get('MTU', '1280')}
        names = ('Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4', 'H1', 'H2', 'H3', 'H4',
                 'HeaderProtectionKey', 'ContentPaddingAddition')
        awg = {name: interface[name] for name in names}
        if not all(awg.values()) or not all(fields[key] for key in ('client_priv_key', 'client_ip', 'server_pub_key', 'hostName')):
            raise ValueError('Missing required configuration value')
        fields.update(awg)
        awg.update({'last_config': json.dumps(fields, separators=(',', ':')), 'port': port,
                    'transport_proto': 'udp', 'protocol_version': '3.1', 'isThirdPartyConfig': True})
        data = {'description': 'AmneziaWG 3.1', 'hostName': host, 'dns1': interface.get('DNS', '1.1.1.1').split(',')[0].strip(),
                'dns2': '1.0.0.1', 'defaultContainer': 'amnezia-awg2',
                'containers': [{'container': 'amnezia-awg2', 'awg': awg}]}
    except (KeyError, ValueError, configparser.Error) as exc:
        raise ValueError('Invalid or incomplete AmneziaWG 3.1 configuration') from exc
    raw = json.dumps(data, separators=(',', ':')).encode()
    return 'vpn://' + base64.urlsafe_b64encode(struct.pack('>I', len(raw)) + zlib.compress(raw, 8)).decode().rstrip('=')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', help='client configuration file')
    args = parser.parse_args()
    try:
        with open(args.config, encoding='utf-8') as file:
            print(make_link(file.read()))
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
