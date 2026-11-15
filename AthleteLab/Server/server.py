"""Athlete Lab managed backend. Per-account sessions and provider credentials."""
import os, json, time, secrets, sqlite3, threading
import jwt
from account_store import AccountStore
from datetime import datetime, timezone
from contextlib import contextmanager
from werkzeug.exceptions import HTTPException
from urllib.parse import urlencode, parse_qsl
import requests
from requests_oauthlib import OAuth1Session
from cryptography.fernet import Fernet
from flask import Flask, request, jsonify, abort, redirect, g

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 65536
DB = os.environ.get('DATABASE', 'athletelab.sqlite3')
ACCOUNTS = AccountStore(DB)
APPLE_KEYS = jwt.PyJWKClient('https://appleid.apple.com/auth/keys', timeout=10)
BOX = Fernet(os.environ['ENCRYPTION_KEY'].encode())
BASE = os.environ.get('PUBLIC_URL', '').rstrip('/')
LOCK = threading.Lock()

@contextmanager
def db():
    c = sqlite3.connect(DB, timeout=20)
    c.execute('create table if not exists account_secrets (owner text, name text, value blob, primary key(owner,name))')
    c.execute('create table if not exists oauth_pending (state text primary key, provider text, owner text, value blob, expires real)')
    try:
        with c: yield c
    finally: c.close()

def put(name, value):
    with db() as c: c.execute('insert or replace into account_secrets values (?,?,?)', (g.owner, name, BOX.encrypt(json.dumps(value).encode())))
def get(name):
    with db() as c: row = c.execute('select value from account_secrets where owner=? and name=?', (g.owner,name)).fetchone()
    return json.loads(BOX.decrypt(row[0])) if row else None

def pending(state, provider, value):
    with db() as c:
        c.execute('delete from oauth_pending where expires<?', (time.time(),))
        c.execute('insert into oauth_pending values (?,?,?,?,?)', (state, provider, g.owner, BOX.encrypt(json.dumps(value).encode()), time.time()+600))
def consume(state, provider):
    with db() as c:
        c.execute('begin immediate')
        row = c.execute('select owner,value from oauth_pending where state=? and provider=? and expires>?', (state, provider, time.time())).fetchone()
        c.execute('delete from oauth_pending where state=?', (state,))
    if not row: abort(400, 'Invalid or expired authorization')
    g.owner = row[0]
    return json.loads(BOX.decrypt(row[1]))

def checked(response):
    response.raise_for_status(); return response.json()
def required(name):
    value = os.environ.get(name)
    if not value: abort(503, name + ' is not configured on the server')
    return value

def object_payload():
    value = request.get_json(silent=True)
    if not isinstance(value, dict): abort(400)
    return value

@app.after_request
def private_response(response):
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    return response

@app.before_request
def authorize():
    if request.path.startswith('/api/'):
        header = request.headers.get('Authorization', '')
        if not header.startswith('Bearer '): abort(401)
        g.owner = ACCOUNTS.owner(header[7:])
        if not g.owner: abort(401)

@app.post('/auth/device')
def device_session():
    payload = object_payload()
    try: return jsonify(token=ACCOUNTS.issue_device(payload.get('installation_key')))
    except ValueError: abort(400)

@app.post('/auth/challenge')
def login_challenge():
    try: return jsonify(ACCOUNTS.challenge())
    except ValueError: abort(429)

@app.post('/auth/apple')
def apple_login():
    payload = object_payload()
    try:
        nonce = ACCOUNTS.consume_challenge(payload.get('challenge',''))
        token = payload.get('identity_token','')
        key = APPLE_KEYS.get_signing_key_from_jwt(token)
        claims = jwt.decode(token, key.key, algorithms=['RS256'], audience=required('APPLE_CLIENT_ID'), issuer='https://appleid.apple.com', options={'require':['exp','iat','sub','nonce']})
        if not secrets.compare_digest(claims['nonce'],nonce): abort(401)
        return jsonify(token=ACCOUNTS.issue(claims['sub']))
    except (ValueError, jwt.PyJWTError): abort(401)

@app.post('/api/logout')
def logout():
    ACCOUNTS.logout(request.headers['Authorization'][7:])
    return jsonify(ok=True)

@app.errorhandler(HTTPException)
def http_error(error):
    if request.path.startswith('/auth/') or request.path.startswith('/api/'):
        descriptions = {401:'La conexión ha caducado. Vuelve a conectar el servicio.', 503:'El servicio de conexiones todavía no está disponible.', 429:'Demasiados intentos. Inténtalo más tarde.'}
        return jsonify(error=descriptions.get(error.code, 'No se ha podido completar la operación.')), error.code
    return error

@app.errorhandler(requests.RequestException)
def provider_error(error):
    # No provider response body or token is sent to the client/logs.
    return jsonify(error='El proveedor rechazó la consulta. Revisa autorización y cuotas.'), 502

@app.post('/api/connect/<provider>')
def connect(provider):
    if not BASE.startswith('https://'): abort(503, 'PUBLIC_URL must be HTTPS')
    if provider == 'strava':
        state = secrets.token_urlsafe(32); pending(state, provider, {})
        url = 'https://www.strava.com/oauth/mobile/authorize?' + urlencode(dict(client_id=required('STRAVA_CLIENT_ID'), redirect_uri=BASE+'/callback/strava', response_type='code', approval_prompt='auto', scope='read,activity:read_all', state=state))
    elif provider == 'fatsecret':
        oauth = OAuth1Session(required('FATSECRET_KEY'), client_secret=required('FATSECRET_SECRET'), callback_uri=BASE+'/callback/fatsecret')
        token = oauth.fetch_request_token('https://authentication.fatsecret.com/oauth/request_token', timeout=20)
        pending(token['oauth_token'], provider, token)
        url = oauth.authorization_url('https://authentication.fatsecret.com/oauth/authorize')
    else: abort(404)
    return jsonify(url=url)

@app.get('/callback/strava')
def strava_callback():
    consume(request.args.get('state', ''), 'strava')
    if request.args.get('error'): return redirect('athletelab://oauth?success=0')
    scopes = set(request.args.get('scope', '').split(','))
    if not ({'activity:read', 'activity:read_all'} & scopes): abort(400, 'Activity permission required')
    token = checked(requests.post('https://www.strava.com/oauth/token', data=dict(client_id=required('STRAVA_CLIENT_ID'), client_secret=required('STRAVA_CLIENT_SECRET'), code=request.args.get('code', ''), grant_type='authorization_code'), timeout=20))
    put('strava', token); return redirect('athletelab://oauth?success=1')

@app.get('/callback/fatsecret')
def fatsecret_callback():
    if request.args.get('denied'):
        consume(request.args['denied'], 'fatsecret')
        return redirect('athletelab://oauth?success=0')
    if not request.args.get('oauth_verifier'): abort(400)
    saved = consume(request.args.get('oauth_token', ''), 'fatsecret')
    oauth = OAuth1Session(required('FATSECRET_KEY'), client_secret=required('FATSECRET_SECRET'), resource_owner_key=saved['oauth_token'], resource_owner_secret=saved['oauth_token_secret'], verifier=request.args.get('oauth_verifier', ''))
    # requests-oauthlib fetch_access_token always POSTs; FatSecret requires GET.
    response = oauth.get('https://authentication.fatsecret.com/oauth/access_token', timeout=20)
    response.raise_for_status()
    token = dict(parse_qsl(response.text))
    if not token.get('oauth_token') or not token.get('oauth_token_secret'): abort(502)
    put('fatsecret', token); return redirect('athletelab://oauth?success=1')

@app.post('/api/hevy')
def hevy_connect():
    key = (request.get_json(silent=True) or {}).get('key', '')
    if not key or len(key) > 1024: abort(400)
    checked(requests.get('https://api.hevyapp.com/v1/workouts', headers={'api-key': key}, params={'page':1,'pageSize':1}, timeout=20))
    put('hevy', {'key':key}); return jsonify(ok=True)

def iso(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')
def sport(value):
    return {'Run':'Carrera','TrailRun':'Carrera','VirtualRun':'Carrera','Ride':'Ciclismo','VirtualRide':'Ciclismo','Swim':'Natación','WeightTraining':'Fuerza'}.get(value,'Actividad')
def strava_token():
    token = get('strava')
    if not token: return None
    if token['expires_at'] < time.time()+60:
        refreshed = checked(requests.post('https://www.strava.com/oauth/token', data=dict(client_id=required('STRAVA_CLIENT_ID'), client_secret=required('STRAVA_CLIENT_SECRET'), refresh_token=token['refresh_token'], grant_type='refresh_token'), timeout=20)); token.update(refreshed); put('strava',token)
    return token

def strava_sessions():
    token = strava_token()
    if not token: return []
    result = []
    for page in range(1, 11):
        activities = checked(requests.get('https://www.strava.com/api/v3/athlete/activities', headers={'Authorization':'Bearer '+token['access_token']}, params={'after':int(time.time()-30*86400),'per_page':100,'page':page}, timeout=20))
        for a in activities:
            result.append(dict(id='strava-'+str(a['id']),title=a['name'],sport=sport(a.get('sport_type',a.get('type'))),date=a['start_date'],minutes=a['elapsed_time']/60,distance=a.get('distance'),source='Strava',averageHR=a.get('average_heartrate'),maximumHR=a.get('max_heartrate'),detail='Tiempo en movimiento: '+str(round(a['moving_time']/60,1))+' min.'))
        if len(activities)<100: break
    return result

@app.get('/api/activities/strava/<int:activity_id>')
def strava_detail(activity_id):
    token = strava_token()
    if not token: abort(401)
    headers = {'Authorization':'Bearer '+token['access_token']}
    activity = checked(requests.get(f'https://www.strava.com/api/v3/activities/{activity_id}', headers=headers, timeout=20))
    if str(activity.get('athlete',{}).get('id')) != str(token.get('athlete',{}).get('id')): abort(403)
    streams = checked(requests.get(f'https://www.strava.com/api/v3/activities/{activity_id}/streams', headers=headers, params={'keys':'time,heartrate,latlng','key_by_type':'true'}, timeout=20))
    seconds = streams.get('time',{}).get('data',[])
    bpm = streams.get('heartrate',{}).get('data',[])
    coords = streams.get('latlng',{}).get('data',[])
    return jsonify(calories=activity.get('calories'),averageHR=activity.get('average_heartrate'),maximumHR=activity.get('max_heartrate'),heart=[{'seconds':t,'bpm':v} for t,v in zip(seconds,bpm)],route=[{'latitude':v[0],'longitude':v[1]} for v in coords])

def hevy_sessions():
    saved = get('hevy')
    if not saved: return []
    result=[]; cutoff=time.time()-30*86400
    for page in range(1, 101):
        payload=checked(requests.get('https://api.hevyapp.com/v1/workouts',headers={'api-key':saved['key']},params={'page':page,'pageSize':10},timeout=20))
        older=False
        for w in payload.get('workouts',[]):
            start=datetime.fromisoformat(w['start_time'].replace('Z','+00:00')); end=datetime.fromisoformat(w['end_time'].replace('Z','+00:00'))
            if start.timestamp()<cutoff: older=True; continue
            details=[]
            for exercise in w.get('exercises',[]):
                details.append(exercise.get('title','Ejercicio'))
                for s in exercise.get('sets',[]): details.append(f"  {s.get('reps') or 0} reps · {s.get('weight_kg') or 0} kg")
            result.append(dict(id='hevy-'+w['id'],title=w['title'],sport='Fuerza',date=iso(start.timestamp()),minutes=(end-start).total_seconds()/60,distance=None,source='Hevy',detail='\n'.join(details)))
        if older or page>=payload.get('page_count',page): break
    return result

def fatsecret_meals():
    token=get('fatsecret')
    if not token: return []
    oauth=OAuth1Session(required('FATSECRET_KEY'),client_secret=required('FATSECRET_SECRET'),resource_owner_key=token['oauth_token'],resource_owner_secret=token['oauth_token_secret'])
    # The iPhone sends its local calendar date, so a late-night meal stays on the correct day.
    date=(request.get_json(silent=True) or {}).get('date') or datetime.now(timezone.utc).date().isoformat()
    day=(datetime.strptime(date,'%Y-%m-%d').date()-datetime(1970,1,1).date()).days
    payload=checked(oauth.get('https://platform.fatsecret.com/rest/server.api',params={'method':'food_entries.get.v2','date':day,'format':'json'},timeout=20))
    if not isinstance(payload, dict) or 'error' in payload or 'food_entries' not in payload: raise ValueError('FatSecret diary response invalid')
    entries=(payload.get('food_entries') or {}).get('food_entry',[])
    if isinstance(entries,dict): entries=[entries]
    if entries is None: entries=[]
    if not isinstance(entries,list) or any(not isinstance(x,dict) for x in entries): raise ValueError('Invalid food entries')
    return [dict(id=str(x['food_entry_id']),title=x.get('food_entry_name',x.get('food_entry_description','Comida')),calories=float(x.get('calories',0)),protein=float(x.get('protein',0)),carbs=float(x.get('carbohydrate',0)),fat=float(x.get('fat',0))) for x in entries]

@app.post('/api/sync')
def sync():
    payload = object_payload()
    date = payload.get('date')
    if not isinstance(date, str): abort(400)
    try:
        if datetime.strptime(date, '%Y-%m-%d').strftime('%Y-%m-%d') != date: abort(400)
    except ValueError: abort(400)
    # Live reads: no persistent caching of food diary or activity data.
    meal_status = 'unconnected'
    with LOCK:
        sessions=[]; meals=[]; warnings=[]
        for name, fetch in [('Strava',strava_sessions),('Hevy',hevy_sessions),('FatSecret',fatsecret_meals)]:
            try:
                values=fetch()
                if name=='FatSecret':
                    meals=values; meal_status='complete' if get('fatsecret') else 'unconnected'
                else: sessions.extend(values)
            except (requests.RequestException, ValueError, KeyError):
                if name=='FatSecret': meal_status='error'
                warnings.append(name+': no se pudo actualizar. Revisa permisos y cuotas.')
    return jsonify(sessions=sessions,meals=meals,mealStatus=meal_status,warnings=warnings,connections={x:bool(get(x)) for x in ['strava','hevy','fatsecret']})

@app.delete('/api/connections/<provider>')
def disconnect(provider):
    if provider not in ('strava','hevy','fatsecret'): abort(404)
    with db() as c:
        c.execute('delete from account_secrets where owner=? and name=?',(g.owner,provider))
        c.execute('delete from oauth_pending where owner=? and provider=?',(g.owner,provider))
    return jsonify(ok=True)

@app.get('/webhooks/strava')
def webhook_verify():
    if not secrets.compare_digest(request.args.get('hub.verify_token',''),required('STRAVA_VERIFY_TOKEN')): abort(403)
    return jsonify({'hub.challenge':request.args.get('hub.challenge')})

@app.post('/webhooks/strava')
def webhook():
    # Strava does not sign payloads: require the secret URL query and subscription id.
    if not secrets.compare_digest(request.args.get('key',''),required('STRAVA_WEBHOOK_KEY')): abort(403)
    payload=request.get_json(silent=True) or {}
    if str(payload.get('subscription_id')) != required('STRAVA_SUBSCRIPTION_ID'): abort(403)
    with db() as c:
        rows = c.execute("select owner,value from account_secrets where name='strava'").fetchall()
    for owner, encrypted in rows:
        token = json.loads(BOX.decrypt(encrypted))
        if str(payload.get('owner_id')) == str(token.get('athlete',{}).get('id')):
            if payload.get('updates',{}).get('authorized') == 'false':
                with db() as c: c.execute("delete from account_secrets where owner=? and name='strava'",(owner,))
    return '',200

if __name__=='__main__': app.run(host='127.0.0.1',port=8080,debug=False)
