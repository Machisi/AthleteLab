import os
import sqlite3
import tempfile
import unittest
from account_store import AccountStore

class AccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = AccountStore(os.path.join(self.temp.name,'test.db'))
    def tearDown(self): self.temp.cleanup()
    def test_challenge_is_single_use(self):
        c = self.store.challenge()
        self.assertEqual(self.store.consume_challenge(c['id']), c['nonce'])
        with self.assertRaises(ValueError): self.store.consume_challenge(c['id'])
    def test_accounts_have_distinct_sessions(self):
        a,b = self.store.issue('alice'),self.store.issue('bob')
        self.assertEqual(self.store.owner(a),'alice')
        self.assertEqual(self.store.owner(b),'bob')
        self.store.logout(a)
        self.assertIsNone(self.store.owner(a))
        self.assertEqual(self.store.owner(b),'bob')
    def test_raw_session_is_not_stored(self):
        token = self.store.issue('alice')
        with sqlite3.connect(self.store.path) as c:
            digest = c.execute('select digest from account_sessions').fetchone()[0]
        self.assertNotEqual(token,digest)
    def test_expired_session_and_challenge_rejected(self):
        c = self.store.challenge(); token = self.store.issue('alice')
        with sqlite3.connect(self.store.path) as db:
            db.execute('update login_challenges set expires=0')
            db.execute('update account_sessions set expires=0')
        self.assertIsNone(self.store.owner(token))
        with self.assertRaises(ValueError): self.store.consume_challenge(c['id'])
    def test_unknown_session_rejected(self): self.assertIsNone(self.store.owner('unknown'))

class DeviceAccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = AccountStore(os.path.join(self.temp.name,'device.db'))
    def tearDown(self): self.temp.cleanup()
    def test_same_installation_keeps_owner_without_login(self):
        a = self.store.issue_device('a'*64)
        b = self.store.issue_device('a'*64)
        c = self.store.issue_device('b'*64)
        self.assertEqual(self.store.owner(a), self.store.owner(b))
        self.assertNotEqual(self.store.owner(a), self.store.owner(c))
        self.assertNotEqual(a, b)
    def test_invalid_installation_credentials_rejected(self):
        for value in [None, '', 'short', 'A'*64, 'x'*64]:
            with self.assertRaises(ValueError): self.store.issue_device(value)
    def test_installation_key_not_persisted(self):
        key = 'a'*64
        self.store.issue_device(key)
        with open(self.store.path,'rb') as file: self.assertNotIn(key.encode(), file.read())

if __name__=='__main__': unittest.main()
