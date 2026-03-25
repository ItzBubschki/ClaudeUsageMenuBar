# Security TODO

## High Priority

- [x] **Enable App Sandbox**
  The app has no entitlements file and no sandbox configuration. It runs with full user-level access to the filesystem, network, and all user processes. Enable App Sandbox and request only the specific entitlements needed (`com.apple.security.network.client` and keychain access). This is industry standard for macOS apps handling credentials.

- [x] **Enable Hardened Runtime**
  `ENABLE_HARDENED_RUNTIME` is not set. Hardened Runtime protects against code injection, DYLIB hijacking, and debugging attacks. Without it, a malicious actor could inject a dylib into the process and exfiltrate the OAuth token from memory.

## Medium Priority

- [x] **Replace `security` CLI with Security.framework (`SecItemCopyMatching`)**
  The app shells out to `/usr/bin/security` via `Process()` to read the OAuth token from the Keychain. This is unconventional. Downsides:
  - The token passes through a pipe (another process boundary), briefly visible in memory of both processes.
  - The command and its arguments are visible via `ps` to other user-level processes during execution.
  - The `security` CLI may prompt the user or behave differently across macOS versions.
  Using the native `Security.framework` API (`SecItemCopyMatching`) would be more secure and idiomatic.

- [x] **Minimize OAuth token lifetime in memory**
  The token is fetched as a plain `String`, passed into a `URLRequest`, and then falls out of scope with no explicit zeroing. Swift strings are immutable and can be copied by the runtime, so the token may linger in memory. Consider using `Data` instead of `String` where possible (easier to zero out) and minimizing how long the token is held.

- [ ] **Add certificate pinning for the Anthropic API** *(skipped — overkill for this app)*
  The app trusts any TLS certificate the system trust store accepts for `api.anthropic.com`. If a user is on a corporate network with a MITM proxy (or has a compromised CA in their trust store), the OAuth token would be sent to the proxy. Certificate pinning or public key pinning would mitigate this.

## Low Priority

- [x] **Add a redirect policy to prevent token leakage**
  `URLSession` follows redirects by default and forwards the `Authorization` header to the redirect target. A DNS hijack causing a `301` could silently send the bearer token to a different host. Implement a `URLSessionTaskDelegate` to intercept redirects and strip or block auth headers on redirect.

- [x] **Validate HTTP response status codes**
  The app only checks for `429`. It doesn't validate that the response is `200` before parsing. Add a check that the status code is `2xx` before processing the response body.

- [ ] **Implement rate limit backoff**
  On a `429`, the app shows "Rate limited, will retry" and waits for the next 120s timer tick. It doesn't read `Retry-After` headers or implement exponential backoff, which could lead to repeated rate limiting.

- [ ] **Remove force-unwrapped URL**
  `URL(string: "https://api.anthropic.com/api/oauth/usage")!` is safe since it's a hardcoded valid URL, but replacing the force-unwrap with a guard is better code hygiene.
