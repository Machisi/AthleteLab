"""Integration simulations: real Flask/SQLite/crypto; only provider HTTP is mocked."""
import os, tempfile, unittest, importlib, sys
from unittest.mock import patch, MagicMock
from urllib.parse import urlparse, parse_qs
from cryptography.fernet import Fernet

class IntegrationTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory()
  self.env=patch.dict(os.environ,{'DATABASE':self.tmp.name+'/data.sqlite','ENCRYPTION_KEY':Fernet.generate_key().decode(),'PUBLIC_URL':'https://api.example.test','FATSECRET_KEY':'test-app','FATSECRET_SECRET':'test-secret','STRAVA_CLIENT_ID':'123','STRAVA_CLIENT_SECRET':'test-strava'})
  self.env.start()
  if 'server' in sys.modules: self.s=importlib.reload(sys.modules['server'])
  else: self.s=importlib.import_module('server')
  self.s.app.testing=True;self.c=self.s.app.test_client()
  self.a=self.login('a');self.b=self.login('b')
 def tearDown(self):self.env.stop();self.tmp.cleanup()
 def login(self,k):return {'Authorization':'Bearer '+self.c.post('/auth/device',json={'installation_key':k*64}).json['token']}
 def save(self,headers,provider,value):
  with self.s.app.test_request_context():
   self.s.g.owner=self.s.ACCOUNTS.owner(headers['Authorization'][7:]);self.s.put(provider,value)
 def start(self):
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.fetch_request_token.return_value={'oauth_token':'request','oauth_token_secret':'request-secret'}
   cls.return_value.authorization_url.return_value='https://authentication.fatsecret.com/oauth/authorize?oauth_token=request'
   response=self.c.post('/api/connect/fatsecret',headers=self.a)
   self.assertEqual(response.status_code,200);return response
 def test_private_sync(self):self.assertEqual(self.c.post('/api/sync',json={}).status_code,401)
 def test_invalid_device(self):self.assertEqual(self.c.post('/auth/device',json={'installation_key':'x'}).status_code,400)
 def test_payload_not_object(self):self.assertEqual(self.c.post('/auth/device',json=['wrong']).status_code,400)
 def test_authorization_url(self):self.assertEqual(urlparse(self.start().json['url']).hostname,'authentication.fatsecret.com')
 def test_fatsecret_authorize_then_sync_and_isolation(self):
  self.start()
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.return_value.text='oauth_token=private-token&oauth_token_secret=private-secret'
   result=self.c.get('/callback/fatsecret?oauth_token=request&oauth_verifier=valid')
   self.assertIn('success=1',result.location)
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.return_value.json.return_value={'food_entries':{'food_entry':{'food_entry_id':'one','food_entry_name':'Food','calories':'250','protein':'12','carbohydrate':'30','fat':'8'}}}
   result=self.c.post('/api/sync',headers=self.a,json={'date':'2026-11-14'})
   self.assertEqual(result.json['meals'][0]['calories'],250)
   self.assertEqual(self.c.post('/api/sync',headers=self.b,json={'date':'2026-11-14'}).json['meals'],[])
   params=cls.return_value.get.call_args.kwargs['params'];self.assertEqual(params['date'],20771)
 def test_real_oauth_transport_get_and_signature(self):
  self.start()
  response=self.s.requests.Response();response.status_code=200;response._content=b'oauth_token=verified&oauth_token_secret=secret'
  with patch.object(self.s.requests.sessions.Session,'send',return_value=response) as send:
   r=self.c.get('/callback/fatsecret?oauth_token=request&oauth_verifier=valid')
   self.assertIn('success=1',r.location)
   prepared=send.call_args.args[0]
   self.assertEqual(prepared.method,'GET')
   authorization=prepared.headers['Authorization']
   if isinstance(authorization,bytes):authorization=authorization.decode()
   self.assertIn('oauth_verifier="valid"',authorization)
   self.assertIn('oauth_signature=',authorization)
 def test_callback_replay(self):
  self.start()
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.return_value.text='oauth_token=ok&oauth_token_secret=secret'
   self.c.get('/callback/fatsecret?oauth_token=request&oauth_verifier=ok')
   self.assertEqual(self.c.get('/callback/fatsecret?oauth_token=request&oauth_verifier=ok').status_code,400)
 def test_cancel_fatsecret(self):
  self.start();response=self.c.get('/callback/fatsecret?denied=request');self.assertIn('success=0',response.location or '')
 def test_missing_verifier_not_exchanged(self):
  self.start()
  with patch.object(self.s,'OAuth1Session') as cls:
   response=self.c.get('/callback/fatsecret?oauth_token=request');self.assertEqual(response.status_code,400);cls.assert_not_called()
 def test_timeout_is_reported(self):
  self.save(self.a,'fatsecret',{'oauth_token':'x','oauth_token_secret':'s'})
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.side_effect=self.s.requests.Timeout()
   r=self.c.post('/api/sync',headers=self.a,json={'date':'2026-11-14'})
   self.assertEqual(r.status_code,200);self.assertTrue(r.json['warnings']);self.assertEqual(r.json['mealStatus'],'error')
 def test_provider_api_error_isolated(self):
  self.save(self.a,'fatsecret',{'oauth_token':'x','oauth_token_secret':'s'})
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.return_value.json.return_value={'error':{'code':5}}
   r=self.c.post('/api/sync',headers=self.a,json={'date':'2026-11-14'})
   self.assertEqual(r.status_code,200);self.assertEqual(r.json['mealStatus'],'error')
 def test_empty_day_success(self):
  self.save(self.a,'fatsecret',{'oauth_token':'x','oauth_token_secret':'s'})
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.return_value.json.return_value={'food_entries':{}}
   r=self.c.post('/api/sync',headers=self.a,json={'date':'2026-11-14'})
   self.assertEqual(r.json['meals'],[]);self.assertEqual(r.json['mealStatus'],'complete')
 def test_wrong_day_rejected(self):self.assertEqual(self.c.post('/api/sync',headers=self.a,json={'date':'2026-02-31'}).status_code,400)
 def test_bad_shape_not_empty_success(self):
  self.save(self.a,'fatsecret',{'oauth_token':'x','oauth_token_secret':'s'})
  with patch.object(self.s,'OAuth1Session') as cls:
   cls.return_value.get.return_value.json.return_value={'unexpected':True}
   r=self.c.post('/api/sync',headers=self.a,json={'date':'2026-11-14'});self.assertEqual(r.json['mealStatus'],'error')
 def test_secret_encrypted(self):
  self.save(self.a,'fatsecret',{'oauth_token':'private-token','oauth_token_secret':'private-secret'})
  with self.s.db() as db:
   raw=db.execute('select value from account_secrets').fetchone()[0];self.assertNotIn(b'private-token',raw)
 def test_disconnect_invalidates_pending(self):
  self.start();self.c.delete('/api/connections/fatsecret',headers=self.a)
  self.assertEqual(self.c.get('/callback/fatsecret?oauth_token=request&oauth_verifier=ok').status_code,400)
 def test_cannot_disconnect_other_phone(self):
  self.save(self.a,'fatsecret',{'oauth_token':'x','oauth_token_secret':'s'})
  self.c.delete('/api/connections/fatsecret',headers=self.b)
  with self.s.app.test_request_context():
   self.s.g.owner=self.s.ACCOUNTS.owner(self.a['Authorization'][7:]);self.assertIsNotNone(self.s.get('fatsecret'))
 def test_no_cache(self):self.assertIn('no-store',self.c.post('/api/sync',headers=self.a,json={'date':'2026-11-14'}).headers.get('Cache-Control',''))
if __name__=='__main__':unittest.main()
