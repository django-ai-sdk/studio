<div align="center">
  <img src=".github/banner.svg" alt="Studio" width="100%">
  <br />
  <a href="https://github.com/django-ai-sdk/django-ai-sdk">SDK</a> ·
  <a href="https://pypi.org/project/django-ai-sdk/">PyPI</a> ·
  <a href="https://django-ai-sdk.github.io/django-ai-sdk/docs/">Docs</a> ·
  <a href="https://github.com/django-ai-sdk/studio/releases">Releases</a>
</div>

## What's inside

- [`app/`](app/): Django projects built on [django-ai-sdk](https://github.com/django-ai-sdk/django-ai-sdk), with a web server and a workflow worker
- [`mac/`](mac/): native macOS and iOS apps for those projects

## Quick start

Needs [uv](https://docs.astral.sh/uv/), [just](https://just.systems/) and Docker.

```sh
just app::up pypi   # web on :8000 + worker, SDK from PyPI (or a path to a local SDK checkout)
just mac::run       # the Mac app, in a second terminal
```

`just` lists every recipe.

## Is it any good?

[Yes.](http://news.ycombinator.com/item?id=3067434)

## License

[BSD-3-Clause](LICENSE)
