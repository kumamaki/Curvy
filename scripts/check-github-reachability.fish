#!/usr/bin/env fish
# check-github-reachability.fish
#
# Verifies whether the hosts Curvy needs are reachable from THIS machine
# RIGHT NOW. Run before committing to the v3 image plan — the v3 design
# assumes the GitHub Releases asset CDN responds, and that's the host
# Iranian ISPs most commonly block independently of github.com.
#
#   fish scripts/check-github-reachability.fish
#
# Reads the result like this:
#   - api.github.com FAIL          → v1 chat is broken too. You're not
#                                    running Curvy on this machine.
#   - uploads.github.com FAIL      → v3 SEND breaks. Image upload
#                                    impossible.
#   - objects.githubusercontent.com FAIL → v3 RECEIVE breaks. The
#                                          dangerous one — bytes can be
#                                          uploaded but never fetched.
#   - End-to-end probe lands on objects.githubusercontent.com with
#     final_code 200 → v3 is green-lit on this network.

set hosts \
    api.github.com \
    uploads.github.com \
    objects.githubusercontent.com \
    raw.githubusercontent.com \
    codeload.github.com

# ─── 1. DNS resolution ────────────────────────────────────────────────
echo "─── DNS ───"
for h in $hosts
    set ips (dig +short +time=3 +tries=1 $h | head -3)
    if test -z "$ips"
        echo "  FAIL  <$h> — no DNS answer (resolver-level block?)"
    else
        echo "  OK    <$h> → "(string join ', ' $ips)
    end
end

# ─── 2. HTTPS reachability ────────────────────────────────────────────
# Any HTTP response (including 4xx) means the connection completed.
# We're hunting for: connection refused, timeout, TLS handshake fail.
echo
echo "─── HTTPS reachability (any HTTP code = reachable) ───"
for h in $hosts
    set output (curl -sS -o /dev/null \
        -w "%{http_code} in %{time_total}s" \
        --max-time 10 \
        https://$h/ 2>&1)
    set rc $status
    if test $rc -eq 0
        echo "  OK    <$h> — got <$output>"
    else
        echo "  FAIL  <$h> — curl exit <$rc>: $output"
    end
end

# ─── 3. End-to-end 302 chain ──────────────────────────────────────────
# This is the v3-critical test. Hits api.github.com with the magic
# Accept header that triggers a 302 redirect to the CDN, then follows
# it. We use a public asset on `cli/cli` (the GitHub CLI repo) — it's
# stable, popular, and won't disappear. We resolve "latest asset" at
# probe time so this script doesn't bitrot.
echo
echo "─── End-to-end asset 302 chain (the v3-critical probe) ───"
set release_json (curl -sS --max-time 10 \
    https://api.github.com/repos/cli/cli/releases/latest 2>/dev/null)

if test -z "$release_json"
    echo "  SKIP  couldn't fetch cli/cli release metadata — api.github.com is the bottleneck."
else if not type -q jq
    echo "  SKIP  jq not installed — install with 'brew install jq' to enable this probe."
    echo "        Or set Curvy aside; you'll want jq for v3 dev anyway."
else
    set asset_url (echo $release_json | jq -r '.assets[0].url' 2>/dev/null)
    if test -z "$asset_url" -o "$asset_url" = "null"
        echo "  SKIP  no asset[0].url in cli/cli release"
    else
        echo "  Probing <$asset_url>"
        set chain (curl -sSL -o /dev/null \
            -w "    final_url=%{url_effective}\n    final_code=%{http_code}\n    redirects=%{num_redirects}\n    total_time=%{time_total}s\n" \
            --max-time 30 \
            -H "Accept: application/octet-stream" \
            $asset_url 2>&1)
        set rc $status
        if test $rc -eq 0
            echo $chain
        else
            echo "  FAIL  curl exit <$rc>: $chain"
        end
    end
end

echo
echo "─── verdict ───"
echo "If 'final_url' contains objects.githubusercontent.com AND final_code is 200,"
echo "v3 image downloads work on this network. Anything else means we need a"
echo "fallback (Cloudflare Worker proxy or a non-GitHub blob host)."
