# pump

A local proxy that exposes **standard AI APIs** (OpenAI chat/responses,
Anthropic messages) and forwards them to **proprietary endpoints defined in
its config file**. The code is endpoint-agnostic: URLs, auth, model routing —
everything lives in configuration. Credentials are acquired **automatically at
runtime** when a request needs them.

```
OpenAI / Anthropic / Google SDK, pi, curl, ...
   │  standard API, any api key
   ▼
pump (127.0.0.1:8787)
   │  injects the endpoint's auth headers
   ▼
https://your-gateway.example.com/...   (whatever you configure)
```

## Build

```sh
swift build -c release     # Swift 6.x toolchain; developed against 6.4.1 on Ubuntu 24.04
```

## Run

```sh
.build/release/pump serve
```

pump is **fully config-driven and ships no endpoints**. Without a config file
it refuses to start and points you at the expected path
(`~/.pump/config.json`, override with `--config` / `PUMP_CONFIG`). Endpoint
definitions hold credentials — keep them out of source control.

```sh
OPENAI_BASE_URL=http://127.0.0.1:8787/v1  OPENAI_API_KEY=x  <openai client>
ANTHROPIC_BASE_URL=http://127.0.0.1:8787  ANTHROPIC_API_KEY=x  <anthropic client>
```

Smoke test:

```sh
curl -s localhost:8787/health
curl -s localhost:8787/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"some-model","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}'
```

## Config

`~/.pump/config.json` (override with `--config` / `PUMP_CONFIG`):

```jsonc
{
  "host": "127.0.0.1",
  "port": 8787,
  "endpoints": [
    {
      "name": "my-gateway",
      "baseUrl": "https://gateway.example.com/inference",
      "apiPaths": {                          // local API flavor → upstream path
        "openai-chat": "/chat/completions",
        "openai-completions": "/completions",
        "anthropic-messages": "/v1/messages",
        "openai-responses": "/responses",
        "embeddings": "/embeddings"
      },
      "passthrough": true,                   // forward unknown POST paths to baseUrl+path
      "modelHeader": "x-upstream-model",    // optional model-routing header
      "auth": {
        "type": "command",                   // none | command
        "command": "uv run /path/to/your-auth-script.py",
        "commandTimeout": 600,               // seconds before the script is killed
        "envTokens": ["PUMP_AUTH_TOKEN"],    // checked before running the command
        "cacheTTL": 518400                   // fallback cache when output has no expiration
      }
    }
  ]
}
```

Anything provider-specific is data: URLs, header names and the auth command
are all in this file, so a new proprietary endpoint is a new config block —
no code changes.

## Auth at runtime

pump ships no auth logic of its own — how a credential is obtained is entirely
up to you, configured per endpoint. On the first request that needs one, pump
acquires it automatically (single-flight; concurrent requests share one
acquisition):

1. **env tokens** named in `auth.envTokens` — used as-is;
2. **`auth.command`** — your script, run via `/bin/sh -c`. It can do anything
   and simply prints the credential: either as a JSON document —
   `{"expiration": <unix-s>, "headers": {…}}`, whose headers pump injects and
   caches until `expiration` — or as a bare token. stderr streams through, so
   progress messages reach the user live.

The credential is reused across requests; it is refreshed only at boot or
after an upstream `401/403`, which re-runs the script once.

There is **no login subcommand** — auth is purely config + runtime. Your
script decides what it needs and how to get it; pump only runs it and
consumes its output.

## Routes (local → endpoint)

| local                        | upstream (apiPaths key)     |
|------------------------------|-----------------------------|
| `POST /v1/chat/completions`  | `openai-chat`               |
| `POST /v1/completions`       | `openai-completions`        |
| `POST /v1/messages`          | `anthropic-messages`        |
| `POST /v1/responses`         | `openai-responses`          |
| `POST /v1/embeddings`        | `embeddings`                |
| `POST <anything else>`       | raw passthrough (endpoint `passthrough: true`) |

`/v1/...` and bare paths are equivalent. Streaming (`stream: true` SSE)
passes through chunk-by-chunk; upstream response headers — including any
provider-specific ones — are forwarded (framing/hop-by-hop headers are
reframed, `content-encoding` is dropped since bodies are forwarded decoded).
Request logs carry the endpoint and model:
`[my-gateway] POST /v1/responses (some-model) -> 200 (2331ms, 3019B)`.

## Subcommands

```sh
pump serve [--config PATH] [--host H] [--port P]
pump version | help
```
