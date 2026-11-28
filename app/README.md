# Demos

Django projects built on django-ai-sdk. Each folder is a standalone project with its
own settings, URLs, database and tests. They run against the SDK checked out next to
this repository (`../../sdk` from `app/`).

| Demo | What it shows |
|---|---|
| [studio](studio/) | Chat agents, swarms, deep research, memories/RAG, workflows, MCP integrations, Ninja + DRF APIs |

[`base/`](base/) is not a demo: it holds the settings every demo shares (`demo_base.settings`).

## Run a demo

From the repository root, with [uv](https://docs.astral.sh/uv/) and [just](https://just.systems/):

```bash
# create app/studio/.env with OPENAI_API_KEY / OPENAI_API_URL (and DEBUG=True for dev)
just app::reset            # installs the SDK and demo_base (both editable), fresh SQLite db + demo data
just app::run              # http://localhost:8000; just app::run 8001 for a second demo
just app::test
```

Workflow runs need the worker next to the web server: `just app::worker`.

### In Docker

```bash
just app::up               # web on :8000 and the worker, SDK from ../../sdk (relative to app/)
just app::up ~/code/sdk    # another local SDK checkout
just app::up pypi          # the latest django-ai-sdk release from PyPI
just app::down
```

`web` installs the dependencies into a shared volume, migrates and starts the server; `worker`
starts once `web` is healthy and uses the same volume. The local SDK is mounted at `/sdk` and installed editable,
so changes in it reload the web server. `PORT=8001 just app::up` maps another host port.

Every demo keeps its own `db.sqlite3`, uploads and vector stores in its folder, so
several can run side by side on different ports.

## Add a demo

```
app/<name>/
  manage.py          DJANGO_SETTINGS_MODULE=<name>.settings
  <name>/            settings.py, urls.py, asgi.py, wsgi.py
  apps/              the demo's own Django apps
  tests/
  pytest.ini         DJANGO_SETTINGS_MODULE = <name>.settings
  justfile           reset / run / test recipes (copy studio's)
```

Its `settings.py` loads its own `.env`, then builds on the shared settings:

```python
BASE_DIR = Path(__file__).resolve().parent.parent
environ.Env.read_env(BASE_DIR / ".env")  # before the import: DEBUG etc. come from it

from demo_base.settings import *

ROOT_URLCONF = "<name>.urls"
INSTALLED_APPS = [*INSTALLED_APPS, "apps.<yours>"]
DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": BASE_DIR / "db.sqlite3"}}
```

Demos import the SDK and `demo_base` as installed packages, never via `sys.path`.
