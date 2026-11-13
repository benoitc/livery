#!/usr/bin/env bash
# Mechanical checks for Livery's founding rules.
#
# Usage, from the repository root:
#   .agents/skills/livery-foundations/scripts/check.sh          # whole tree
#   .agents/skills/livery-foundations/scripts/check.sh main     # files changed since main
#
# Prints one line per hit as "RULE  file:line  what". A hit is a lead to
# read, not a verdict: the skill decides whether it is a drift, an allowed
# exception, or a question for the maintainer. Exits 0 unless the
# arguments are wrong.

set -u

base="${1:-}"
cd "$(git rev-parse --show-toplevel)" || exit 2

if [ -n "$base" ]; then
    git rev-parse --verify --quiet "$base" >/dev/null || {
        echo "unknown base: $base" >&2
        exit 2
    }
    files=$( { git diff --name-only "$base"...HEAD; git diff --name-only; git ls-files --others --exclude-standard; } | sort -u)
else
    files=$(git ls-files; git ls-files --others --exclude-standard)
fi

erl=$(printf '%s\n' "$files" | grep -E '^src/.*\.erl$' | while read -r f; do [ -f "$f" ] && echo "$f"; done)
text=$(printf '%s\n' "$files" | grep -E '^(src/.*\.erl|docs/.*\.md|README\.md|CONTRIBUTING\.md|AGENTS\.md|CHANGELOG\.md)$' |
    grep -v -E '^docs/.*-prompt\.md$' | while read -r f; do [ -f "$f" ] && echo "$f"; done)

adapters='src/livery_h(1|2|3|1h2)\.erl$'
hits=0

report() {
    # $1 rule, $2 message, stdin: grep -n output "file:line:text"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        loc=$(printf '%s' "$line" | cut -d: -f1,2)
        printf '%-4s %s  %s\n' "$1" "$loc" "$2"
        hits=$((hits + 1))
    done
}

scan() {
    # $1 regex, rest: files
    local re="$1"
    shift
    [ "$#" -eq 0 ] && return 0
    grep -n -E "$re" "$@" /dev/null 2>/dev/null
}

erl_list() { printf '%s\n' "$erl" | grep -v '^$'; }

# R5: outbound HTTP goes through livery_client.
mapfile_r5=$(erl_list | grep -v '^src/client/')
report R5 "calls hackney directly; outbound HTTP belongs to livery_client" \
    < <(scan '(^|[^a-z_])hackney:' $mapfile_r5)

# R3: protocol differences go through capabilities or optional callbacks,
# never through a list of known adapters.
report R3 "per-adapter clause outside the adapters; use a capability or an optional callback" \
    < <(scan '\(livery_h(1|2|3|1h2)\) *-> *(true|false|h1|h2|h3|undefined)' \
        $(erl_list | grep -v -E "$adapters"))
report R3 "branches on the protocol above the adapter boundary" \
    < <(scan 'protocol\([^)]*\) *(=:=|==|=/=)|(=:=|==|=/=) *h[123]([^0-9a-z_]|$)' \
        $(erl_list | grep -v -E "$adapters"))

# R4: the wire libraries own flow control. A request stream registered
# without manual flow control never returns credit, so a slow handler
# cannot hold the client back.
for f in $(erl_list | grep -E 'src/livery_h(2|3)\.erl$'); do
    if grep -q 'set_stream_handler' "$f" && ! grep -q 'flow_control *=> *manual' "$f"; then
        report R4 "request stream registered with auto flow control; return credit with consume/3" \
            < <(grep -n 'set_stream_handler(' "$f" | sed "s|^|$f:|" | head -1)
    fi
done

# R2: a middleware that runs Next in another process loses the pipeline's
# context unless it carries it across.
report R2 "spawns in a middleware; check that Next keeps the pipeline's context" \
    < <(scan '(^|[^a-z_])(spawn|spawn_link|spawn_monitor|proc_lib:spawn[a-z_]*)\(' \
        $(erl_list | grep '^src/middleware/'))

# R1: the process dictionary is a hidden channel. Two modules own the
# documented ones (emit hooks, the disconnect notifier).
report R1 "uses the process dictionary outside the documented hooks" \
    < <(scan '^[[:space:]]+[^%]*(^|[^:a-z_])(put|get|erase)\(' \
        $(erl_list | grep -v -E 'src/(middleware/livery_middleware|livery_disconnect)\.erl$') |
        grep -v -E '(maps|proplists|lists|ets|persistent_term|application|livery_[a-z_]+|[A-Z][A-Za-z0-9_]*):(put|get|erase)\(')

# Policy: no em-dash in code, docs or messages (AGENTS.md).
report POL "contains an em-dash" < <(scan $'\xe2\x80\x94' $(printf '%s\n' "$text" | grep -v '^$'))

echo "--"
echo "$hits lead(s). Read each one against SKILL.md before calling it a drift."
