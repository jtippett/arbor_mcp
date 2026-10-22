# ExMCP 1.7 maintenance release

This release retains `{:ex_mcp, "~> 1.0"}`, the `:ex_mcp` application and
`ExMCP.*` namespaces. It does not require the Arbor package split, a native
compiler or the v2 scheduler. No end-of-support date has been set for
ExMCP 1.x.

1.7.0 is a minor release because it adds options as well as fixes. Every
outbound HTTPS connection now follows the same trust-store rules, and the
connections that had no way to choose CA certificates now have one:
- `ExMCP.Authorization.MetadataFetcher` takes `:cacerts`;
- remote JSON Schema references take `network_refs: [cacerts: ...]`;
- the legacy HTTP+SSE transport takes `security: %{tls: ...}`.

## Behavior changes

Nothing changes for applications whose OS trust store loads, beyond the new
options and the first item below. Review the 1.7.0 changelog before
upgrading:
- `security: %{tls: %{verify: :verify_none}}` no longer loads the trust store,
  so those connections keep working while the store is unavailable.
- **When the OS trust store cannot be loaded**, for example in a minimal
  container without `ca-certificates`, these connections now fail like other
  HTTPS requests instead of silently trusting the `castore` bundle: the legacy
  HTTP+SSE transport, OAuth metadata, OIDC discovery and JWKS fetches, and
  remote JSON Schema fetches. Set `config :ex_mcp, :cacerts, fallback: :castore`
  to keep the old behavior for all HTTPS connections.
- **The legacy HTTP+SSE transport (`transport: :sse`) now reads `:security`.**
  It used to ignore it. A `security:` map passed to it is validated like the
  HTTP transport's, and its `:tls` settings apply. Over HTTPS it uses the HTTP
  transport's TLS defaults: peer verification, TLS 1.2/1.3 and HTTPS hostname
  matching.

## Backport provenance

The fixes were made on ArborMCP master first (#94) and applied to 1.x by hand
because the namespace differs (#95). The touched files otherwise match.

| Fix | Origin | 1.x commit |
| --- | --- | --- |
| Fail closed when Mint would pick CA certificates itself | arbor_mcp `295db2d` | `c1168a6` |
| CA certificate options for metadata, schema and legacy HTTP+SSE fetches | arbor_mcp `977b66a` | `dd6868a` |
| TLS test certificates signed with SHA-256 (tests only) | arbor_mcp `c0912a0` | `235d48d` |
| No trust store load for `verify: :verify_none` | arbor_mcp `3cb62d9` | `821b4f1` |

Still left out of 1.x, as noted for 1.6:
- JSON Schema 2020-12 dialect support. It needs a new dependency and changes
  how schemas validate.
- The ZCode `session/list` error path
  ([arbor_acp#7](https://github.com/trust-arbor/arbor_acp/issues/7)). It will
  be fixed on the ArborACP line first and then backported.

## Qualification and publication

Run maintenance CI and adapter/protocol/security regressions on this source.
Check documentation and package contents; install the built archive into a
clean consumer and assemble a release against the unchanged application name.
Only after review and passing CI should the maintenance PR be merged and a
fresh `v1.7.x` tag/package published. Publishing needs a user-owned terminal
for any Hex 2FA prompt. Keep the v2 RC and stable-release gates independent.
