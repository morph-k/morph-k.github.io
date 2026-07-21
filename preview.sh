#!/usr/bin/env bash
# Preview Jekyll site locally
set -euo pipefail
cd "$(dirname "$0")"

# macOS ships Ruby 2.6 with a bundler at /usr/local/bin/bundle. If that one
# wins the PATH it tries to build native extensions against 2.6 headers and
# dies with a C compiler error naming whatever gem compiled first, which reads
# like a broken dependency rather than the PATH problem it is. Fail early and
# say so instead.
ruby_major_minor=$(ruby -e 'print RUBY_VERSION[/\d+\.\d+/]')
if [[ $ruby_major_minor == 2.* ]]; then
  echo "preview.sh: found Ruby $ruby_major_minor ($(command -v ruby))." >&2
  echo "That's the macOS system Ruby; gems won't build. Run 'nix develop' first." >&2
  exit 1
fi

bundle exec jekyll serve
