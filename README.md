# pump

A local proxy that exposes **standard AI APIs** (OpenAI chat/responses,
Anthropic messages) and forwards them to proprietary endpoints.

## Build

```sh
swift build -c release     # Swift 6.x toolchain
```

## Run

```sh
.build/release/pump serve
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

The credential is reused across requests; it is refreshed at boot or
after an upstream `401/403`, which re-runs the script once.

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

## License

MIT — see [LICENSE](LICENSE).
