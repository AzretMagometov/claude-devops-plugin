import base64
import importlib.util
import json
import struct
import unittest
import zlib
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / 'scripts' / 'awg-link.py'

class AwgLinkTest(unittest.TestCase):
    def test_amnezia_link_contains_all_protocol_parameters(self):
        spec = importlib.util.spec_from_file_location('awg_link', MODULE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        config = '''[Interface]\nPrivateKey = private\nAddress = 10.77.0.2/32\nDNS = 1.1.1.1\nMTU = 1280\nJc = 6\nJmin = 50\nJmax = 1000\nS1 = 76\nS2 = 47\nS3 = 33\nS4 = 12\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nHeaderProtectionKey = secret\nContentPaddingAddition = 10-100\n[Peer]\nPublicKey = public\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n'''
        encoded = mod.make_link(config).removeprefix('vpn://')
        compressed = base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4))
        raw = zlib.decompress(compressed[4:])
        self.assertEqual(struct.unpack('>I', compressed[:4])[0], len(raw))
        data = json.loads(raw)
        self.assertEqual(data['defaultContainer'], 'amnezia-awg2')
        awg = data['containers'][0]['awg']
        client = json.loads(awg['last_config'])
        self.assertEqual(client['HeaderProtectionKey'], 'secret')
        self.assertEqual(client['S3'], '33')
        self.assertEqual(client['S4'], '12')
        self.assertEqual(client['ContentPaddingAddition'], '10-100')
        self.assertEqual(client['server_pub_key'], 'public')
        self.assertEqual(data['hostName'], '192.0.2.1')

    def test_rejects_missing_header_key(self):
        spec = importlib.util.spec_from_file_location('awg_link', MODULE)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with self.assertRaises(ValueError):
            mod.make_link('[Interface]\nPrivateKey=x\n[Peer]\nPublicKey=y\n')

if __name__ == '__main__':
    unittest.main()
