import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('guard', Path(__file__).with_name('check-publication.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PublicationTests(unittest.TestCase):
    def test_private_files_and_paths_are_blocked(self):
        for name in ['finance.sqlite', 'receipt.pdf', 'backup.mfin', 'key.jks',
                     '.env.production', 'cloud.json', '../private.txt', 'C:/private.txt']:
            with self.subTest(name=name), self.assertRaises(SystemExit):
                guard.check(name, b'fictional fixture')

    def test_public_config_and_fictional_test_values_are_allowed(self):
        guard.check('lib/config.dart', b'sb_publishable_fictional_key')
        guard.check('test/config.dart', b'sb_secret_fictional_key')

    def test_credential_values_are_blocked_without_echoing_them(self):
        cases = [b'sb_' + b'secret_' + b'generated_for_test_only_1234',
                 b'eyJ' + b'a' * 24 + b'.' + b'b' * 24 + b'.' + b'c' * 24,
                 b'{"session":{"refreshToken":"fictional-private-value"}}']
        for content in cases:
            with self.subTest(length=len(content)), self.assertRaises(SystemExit) as context:
                guard.check('unexpected.json', content)
            self.assertNotIn('fictional-private-value', str(context.exception))


if __name__ == '__main__':
    unittest.main()
