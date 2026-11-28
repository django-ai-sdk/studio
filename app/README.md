# Studio app

A Django project built on [django-ai-sdk](https://github.com/django-ai-sdk/django-ai-sdk): chat agents,
swarms, deep research, memories/RAG, workflows, oversight, MCP integrations, Ninja and DRF APIs.

```
config/     settings, URLs, ASGI/WSGI
studio/     the app: agents, tools, views, permissions, management commands, Linear integration
users/      the email-only User model
tests/
```

## Run

From the repository root, with [uv](https://docs.astral.sh/uv/) and [just](https://just.systems/).
Create `app/.env` with `OPENAI_API_KEY` / `OPENAI_API_URL` (and `DEBUG=True` for dev).

```bash
just app::reset            # installs the SDK from ../../sdk (editable), fresh SQLite db + demo data
just app::run              # http://localhost:8000; just app::run 8001 for another port
just app::worker           # workflow runs need the worker next to the web server
just app::test
```

### In Docker

```bash
just app::up               # web on :8000 and the worker, SDK from ../../sdk (relative to app/)
just app::up ~/code/sdk    # another local SDK checkout
just app::up pypi          # the latest django-ai-sdk release from PyPI
just app::down
```

`web` installs the dependencies into a shared volume, migrates and starts the server; `worker`
starts once `web` is healthy and uses the same volume. The local SDK is mounted at `/sdk` and
installed editable, so changes in it reload the web server. `PORT=8001 just app::up` maps another
host port.
