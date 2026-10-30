import importlib.util
import io
import tarfile
import unittest
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'scripts' / 'vpn-users-server.py'
spec = importlib.util.spec_from_file_location('vpn_users', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class VPNUsersTest(unittest.TestCase):
    def test_names_and_addresses_skip_all_existing(self):
        names = module.allocate_names({'user-01', 'user-03'}, 3)
        self.assertEqual(names, ['user-02', 'user-04', 'user-05'])
        addresses = module.allocate_addresses('10.77.0.1/29', {'10.77.0.2/32', '10.77.0.4/32'}, 3)
        self.assertEqual(addresses, ['10.77.0.3', '10.77.0.5', '10.77.0.6'])

    def test_insufficient_addresses_fails_before_changes(self):
        with self.assertRaises(ValueError):
            module.allocate_addresses('10.77.0.1/30', {'10.77.0.2/32'}, 1)

    def test_template_preserves_protocol_parameters_and_replaces_only_client(self):
        config = '[Interface]\nPrivateKey = OLD\nAddress = 10.77.0.2/32\nS3 = 33\nHeaderProtectionKey = COMMON\n[Peer]\nPublicKey = SERVER\nEndpoint = 192.0.2.1:51820\n'
        result = module.client_config(config, 'NEW', '10.77.0.3')
        self.assertIn('PrivateKey = NEW\n', result)
        self.assertIn('Address = 10.77.0.3/32\n', result)
        self.assertIn('HeaderProtectionKey = COMMON\n', result)
        self.assertNotIn('PrivateKey = OLD', result)

    def test_archive_has_only_requested_files_and_secure_modes(self):
        data = module.build_archive({'user-02/vless.txt': b'vless', 'user-02/amnezia.vpn': b'vpn'})
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
            self.assertEqual(sorted(tar.getnames()), ['user-02/amnezia.vpn', 'user-02/vless.txt'])
            self.assertTrue(all(item.mode == 0o600 for item in tar.getmembers()))
            self.assertEqual(tar.extractfile('user-02/vless.txt').read(), b'vless')


class VPNUsersTransactionTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        from unittest.mock import patch
        from types import SimpleNamespace
        self.patch = patch
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.awg = root / 'awg.conf'
        self.awg.write_text('[Interface]\nAddress = 10.77.0.1/29\n[Peer]\nPublicKey = existing\nAllowedIPs = 10.77.0.2/32\n')
        self.original = self.awg.read_text()
        self.clients = root / 'awg-clients'; self.clients.mkdir()
        self.xray = root / 'xray-clients'; self.xray.mkdir()
        (self.clients / 'user-01.conf').write_text('[Interface]\nPrivateKey = old\nAddress = 10.77.0.2/32\n[Peer]\nPublicKey = server\n')
        (self.xray / 'user-01.txt').write_text('existing')
        self.exports = root / 'exports'
        self.users = {'user-01'}
        self.peers = set()
        self.calls = []
        self.fail_peer = False
        self.link = SimpleNamespace(make_link=lambda _: 'vpn://test')
        self.addCleanup(patch.stopall)
        patch.multiple(module, AWG_CONFIG=self.awg, AWG_CLIENTS=self.clients,
                       XRAY_CLIENTS=self.xray, EXPORTS=self.exports).start()
        patch.object(module.os, 'geteuid', return_value=0).start()
        patch.object(module, 'run', side_effect=self.fake_run).start()

    def fake_run(self, args, *, data=None):
        self.calls.append(args)
        if args[:2] == ['systemctl', 'is-active']:
            return ''
        if args[:3] == ['awg', 'show', 'awg0']:
            return 'existing\t10.77.0.2/32'
        if args == ['xray-clients', 'list']:
            return '\n'.join(sorted(self.users))
        if args[:2] == ['awg', 'genkey']:
            return 'private' + str(len(self.calls))
        if args[:2] == ['awg', 'pubkey']:
            return 'public' + str(len(self.calls))
        if args[:2] == ['xray-clients', 'add']:
            name = args[2]; self.users.add(name)
            (self.xray / (name + '.txt')).write_text('vless')
            (self.xray / (name + '.png')).write_bytes(b'png')
            return ''
        if args[:2] == ['xray-clients', 'remove']:
            name = args[2]; self.users.remove(name)
            for extension in ('.txt', '.png'):
                (self.xray / (name + extension)).unlink(missing_ok=True)
            return ''
        if args[:3] == ['awg', 'set', 'awg0']:
            if args[-1] == 'remove':
                self.peers.remove(args[4]); return ''
            if self.fail_peer and self.peers:
                raise RuntimeError('simulated peer error')
            self.peers.add(args[4]); return ''
        raise AssertionError(args)

    def test_two_users_generate_distinct_peers_and_archive(self):
        names, archive = module.make_users(2, self.link)
        self.assertEqual(names, ['user-02', 'user-03'])
        self.assertEqual(len(self.peers), 2)
        self.assertIn('10.77.0.3/32', self.awg.read_text())
        self.assertIn('10.77.0.4/32', self.awg.read_text())
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        with tarfile.open(archive) as tar:
            self.assertEqual(len(tar.getnames()), 8)
        self.assertTrue((self.clients / 'user-01.conf').exists())

    def test_partial_failure_rolls_back_new_peers_and_preserves_existing(self):
        self.fail_peer = True
        with self.assertRaises(RuntimeError):
            module.make_users(2, self.link)
        self.assertEqual(self.awg.read_text(), self.original)
        self.assertEqual(self.users, {'user-01'})
        self.assertEqual(self.peers, set())
        self.assertFalse((self.clients / 'user-02.conf').exists())

if __name__ == '__main__':
    unittest.main()
