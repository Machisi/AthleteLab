"""Production entrypoint. TLS is terminated by the managed hosting provider."""
import os
from pathlib import Path
from waitress import serve

if __name__ == '__main__':
    database = os.environ.get('DATABASE', '/data/athletelab.sqlite3')
    Path(database).parent.mkdir(parents=True, exist_ok=True)
    os.environ['DATABASE'] = database
    from server import app
    serve(app, host='0.0.0.0', port=int(os.environ.get('PORT', '8080')), threads=8)
