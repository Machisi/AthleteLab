"""Storage primitives independent of Flask; raw login tokens are never persisted."""
import hashlib
import secrets
import sqlite3
import time
from contextlib import contextmanager

class AccountStore:
    def __init__(self, path):
        self.path = path
        with self.connection() as c:
            c.execute('CREATE TABLE IF NOT EXISTS login_challenges(id TEXT PRIMARY KEY, nonce TEXT, expires REAL)')
            c.execute('CREATE TABLE IF NOT EXISTS account_sessions(digest TEXT PRIMARY KEY, owner TEXT, expires REAL)')
    @contextmanager
    def connection(self):
        c = sqlite3.connect(self.path, timeout=20)
        try:
            with c: yield c
        finally: c.close()
    def challenge(self):
        ident, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with self.connection() as c:
            c.execute('DELETE FROM login_challenges WHERE expires < ?', (time.time(),))
            if c.execute('SELECT count(*) FROM login_challenges').fetchone()[0] >= 10000:
                raise ValueError('Too many pending attempts')
            c.execute('INSERT INTO login_challenges VALUES (?,?,?)', (ident, nonce, time.time()+300))
        return {'id': ident, 'nonce': nonce}
    def consume_challenge(self, ident):
        with self.connection() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT nonce FROM login_challenges WHERE id=? AND expires>?', (ident,time.time())).fetchone()
            c.execute('DELETE FROM login_challenges WHERE id=?',(ident,))
        if not row: raise ValueError('Expired or used challenge')
        return row[0]
    def issue(self, owner):
        token = secrets.token_urlsafe(48)
        with self.connection() as c:
            c.execute('DELETE FROM account_sessions WHERE expires<?', (time.time(),))
            c.execute('INSERT INTO account_sessions VALUES (?,?,?)', (self.digest(token), owner, time.time()+7*86400))
        return token
    @staticmethod
    def digest(token): return hashlib.sha256(token.encode()).hexdigest()
    def owner(self, token):
        with self.connection() as c:
            row = c.execute('SELECT owner FROM account_sessions WHERE digest=? AND expires>?', (self.digest(token), time.time())).fetchone()
        return row[0] if row else None
    def logout(self, token):
        with self.connection() as c: c.execute('DELETE FROM account_sessions WHERE digest=?',(self.digest(token),))
    def issue_device(self, installation_key):
        import re
        if not isinstance(installation_key, str) or not re.fullmatch(r'[0-9a-f]{64}', installation_key):
            raise ValueError('Invalid installation credential')
        # An unguessable per-installation secret replaces an app account.
        # Its hash namespaces provider credentials; the raw secret is not stored.
        return self.issue('device:' + self.digest(installation_key))
