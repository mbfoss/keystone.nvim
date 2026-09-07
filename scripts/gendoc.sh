#!/usr/bin/env sh
# Generate doc/*.txt from README.md and docs/*.md with panvimdoc.
#
#   scripts/gendoc.sh           # rewrite doc/*.txt and doc/tags
#   scripts/gendoc.sh --check   # exit 1 when a help file is out of date
#
# README.md becomes doc/keystone.txt; each docs/<module>.md becomes
# doc/keystone-<module>.txt. Every page is rendered under its own project name,
# so the tags panvimdoc derives from headings are namespaced per module --
# seventeen pages share a "## Configuration" heading, and one file per page is
# what keeps those from colliding on a single *keystone-configuration*.
#
# Markdown that has no place in a help file (badges, screenshots, links to
# files on the forge) goes between panvimdoc-ignore markers:
#
#   <!-- panvimdoc-ignore-start -->
#   ![A screenshot](https://...)
#   <!-- panvimdoc-ignore-end -->
#
# and its help-file counterpart, invisible where markdown is rendered, goes in a
# vimdoc-only comment, uncommented here on the way to panvimdoc:
#
#   <!-- vimdoc-only
#   Each module has its own page: |keystone-filetree|, |keystone-clue|, ...
#   -->
#
# Needs pandoc (brew install pandoc). panvimdoc itself is fetched on first run
# and cached, pinned to the commit in PANVIMDOC_COMMIT below -- a tag can be
# moved, a commit cannot -- so the help files are reproducible. Point
# PANVIMDOC_DIR at a checkout of your own to use that instead. nvim is only
# used to refresh doc/tags, and is optional.

set -eu

PANVIMDOC_COMMIT=662fb20304d20c539fb48a0bda628f5165507de7 # v4.0.1
PANVIMDOC_URL=https://github.com/kdheepak/panvimdoc.git

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project=keystone
description="Quality-of-life editor modules for Neovim"
vimversion="Neovim >= 0.11"

work="${TMPDIR:-/tmp}/$project-doc.$$"
trap 'rm -rf "$work"' EXIT INT TERM

die() {
    echo "gendoc: $*" >&2
    exit 1
}

command -v pandoc >/dev/null || die "pandoc not found (brew install pandoc)"

# Resolve panvimdoc: either a caller-supplied checkout, or the pinned commit in
# the user's cache. A plain clone cannot name a commit, so fetch that object and
# check it out directly, then confirm a reused cache is still at that commit.
if [ -n "${PANVIMDOC_DIR:-}" ]; then
    panvimdoc=$PANVIMDOC_DIR
    [ -f "$panvimdoc/panvimdoc.sh" ] || die "no panvimdoc.sh in PANVIMDOC_DIR=$panvimdoc"
else
    panvimdoc="${XDG_CACHE_HOME:-$HOME/.cache}/panvimdoc-$PANVIMDOC_COMMIT"
    if [ ! -f "$panvimdoc/panvimdoc.sh" ]; then
        echo "fetching panvimdoc $PANVIMDOC_COMMIT into $panvimdoc"
        rm -rf "$panvimdoc"
        mkdir -p "$panvimdoc"
        git -C "$panvimdoc" init --quiet
        git -C "$panvimdoc" fetch --quiet --depth 1 "$PANVIMDOC_URL" "$PANVIMDOC_COMMIT"
        git -c advice.detachedHead=false -C "$panvimdoc" checkout --quiet FETCH_HEAD
    fi
    have=$(git -C "$panvimdoc" rev-parse HEAD)
    [ "$have" = "$PANVIMDOC_COMMIT" ] ||
        die "$panvimdoc is at $have, expected $PANVIMDOC_COMMIT; remove it and re-run"
fi

# A module page's one-line description, for its help file header. The README's
# module table is the source: those summaries are already written to fit on one
# line, and keeping them there is what stops the two drifting apart. A page with
# no row falls back to its own first sentence.
describe() {
    module=$1
    awk -v module="$module" '
        $0 ~ "^\\| \\[" module "\\]\\(docs/" module "\\.md\\)" {
            i = index(substr($0, 3), "|")
            desc = substr($0, i + 3)
            sub(/[ \t]*\|[ \t]*$/, "", desc)
            gsub(/[`*_]/, "", desc)
            print desc
            exit
        }
    ' "$root/README.md"
}

# Fallback: the line under the page's `# heading`, trimmed to a label.
first_line() {
    awk '
        /^#[ \t]/ { seen = 1; next }
        seen && NF {
            gsub(/[`*_]/, "")
            sub(/\..*$/, "")
            print
            exit
        }
    ' "$1"
}

# Render one markdown file to $work/out/<name>.txt.
#
# Help tags come from a hidden comment at the end of a section heading. The
# project name is prefixed automatically, so in docs/filetree.md this yields
# *keystone-filetree-keys*:
#
#   ## Keymaps <!-- tag: keys -->
#
# Without one, panvimdoc derives the tag from the heading text. Collect
# "derived-tag<TAB>wanted-tag" pairs and strip the comments from the copy
# panvimdoc reads; the derived tags are rewritten in the output below.
generate() {
    md=$1
    name=$2
    desc=$3
    dir="$work/$name"

    mkdir -p "$dir/doc"
    awk -v project="$name" -v out="$dir/input.md" '
        # Help-file-only text, invisible to a markdown renderer.
        /^[ \t]*<!--[ \t]*vimdoc-only[ \t]*$/ { vimdoc = 1; next }
        vimdoc && /^[ \t]*-->[ \t]*$/         { vimdoc = 0; next }

        /^##+[ \t].*<!--[ \t]*tag:[^>]*-->[ \t]*$/ {
            tag = $0
            sub(/^.*<!--[ \t]*tag:[ \t]*/, "", tag)
            sub(/[ \t]*-->[ \t]*$/, "", tag)
            sub(/[ \t]*<!--[ \t]*tag:[^>]*-->[ \t]*$/, "")
            if (tag !~ /^[A-Za-z0-9_-]+$/) {
                print "gendoc: bad help tag \"" tag "\" on " $0 > "/dev/stderr"
                exit 1
            }
            heading = $0
            sub(/^#+[ \t]*/, "", heading)
            # panvimdoc derives the tag from the rendered heading, so drop the
            # inline markers pandoc consumes on the way there.
            gsub(/[`*_]/, "", heading)
            gsub(/[ \t]+/, "-", heading)
            print project "-" tolower(heading) "\t" project "-" tag
        }
        { print > out }
    ' "$md" > "$dir/tagmap"

    # panvimdoc writes to doc/<project>.txt relative to the working directory,
    # so run it in a scratch tree and collect the result from there.
    (
        cd "$dir"
        sh "$panvimdoc/panvimdoc.sh" \
            --project-name "$name" \
            --input-file "$dir/input.md" \
            --vim-version "$vimversion" \
            --description "$desc" \
            --toc true \
            --dedup-subheadings false \
            --shift-heading-level-by -1 \
            --treesitter true
    ) >/dev/null

    # Swap in the tags declared in the markdown, keeping the trailing tag
    # right-aligned and the |links| to it in sync.
    awk '
        FILENAME == ARGV[1] {   # NR == FNR would swallow file 2 on an empty tagmap
            i = index($0, "\t")
            map[substr($0, 1, i - 1)] = substr($0, i + 1)
            next
        }
        {
            line = $0
            for (k in map) {
                gsub("\\*" k "\\*", "*" map[k] "*", line)
                gsub("\\|" k "\\|", "|" map[k] "|", line)
            }
            if (line != $0 && match(line, /[*|][^ *|]+[*|]$/)) {
                token = substr(line, RSTART)
                head = substr(line, 1, RSTART - 1)
                sub(/[ \t]+$/, "", head)
                # Realign to where the derived tag sat, but never past the 78
                # columns a help file is written to: a heading whose derived tag
                # overflowed is exactly why a shorter one was declared.
                width = length($0)
                if (width > 78) width = 78
                pad = width - length(head) - length(token)
                if (pad < 1) pad = 1
                line = head sprintf("%" pad "s", "") token
            }
            print line
        }
    ' "$dir/tagmap" "$dir/doc/$name.txt" > "$dir/tagged.txt"

    # panvimdoc heads the file with a *<name>.txt* tag. Nothing links to a help
    # file by its filename, so make it the plain *<name>* the rest of the tags
    # are named after, keeping the description right-aligned where it was.
    awk -v name="$name" '
        NR == 1 && index($0, "*" name ".txt*") == 1 {
            tag  = "*" name "*"
            desc = substr($0, length(name) + 7)
            sub(/^[ \t]+/, "", desc)
            width = length($0)
            if (width > 78) width = 78
            pad = width - length(tag) - length(desc)
            if (pad < 1) pad = 1
            $0 = tag sprintf("%" pad "s", "") desc
        }
        { print }
    ' "$dir/tagged.txt" > "$work/out/$name.txt"

    # The header line carries the file's tag and its description; over 78
    # columns it wraps in the help viewer and the description is what to cut.
    header=$(head -1 "$work/out/$name.txt")
    [ "${#header}" -le 78 ] ||
        die "$name: header is ${#header} columns; shorten its summary in README.md"
}

mkdir -p "$work/out"
generate "$root/README.md" "$project" "$description"
for md in "$root"/docs/*.md; do
    module=$(basename "$md" .md)
    desc=$(describe "$module")
    [ -n "$desc" ] || desc=$(first_line "$md")
    generate "$md" "$project-$module" "$desc"
done

# An out-of-date file, a missing one, and a stale one left behind by a renamed
# page are all "regenerate": report them the same way.
stale=""
for txt in "$work/out"/*.txt; do
    cmp -s "$txt" "$root/doc/$(basename "$txt")" || stale="$stale $(basename "$txt")"
done
for txt in "$root"/doc/*.txt; do
    [ -e "$txt" ] || continue
    [ -f "$work/out/$(basename "$txt")" ] || stale="$stale $(basename "$txt") (no longer generated)"
done

if [ "${1:-}" = "--check" ]; then
    [ -n "$stale" ] || {
        echo "doc/ is up to date"
        exit 0
    }
    echo "doc/ is out of date ($(echo "$stale" | sed 's/^ //')); run: scripts/gendoc.sh" >&2
    if [ "${2:-}" = "--diff" ]; then
        for txt in "$work/out"/*.txt; do
            diff -u "$root/doc/$(basename "$txt")" "$txt" || true
        done
    fi
    exit 1
fi

mkdir -p "$root/doc"
for txt in "$root"/doc/*.txt; do
    [ -e "$txt" ] || continue
    [ -f "$work/out/$(basename "$txt")" ] || {
        rm "$txt"
        echo "removed $txt"
    }
done
count=0
for txt in "$work/out"/*.txt; do
    cp "$txt" "$root/doc/$(basename "$txt")"
    count=$((count + 1))
done
echo "wrote $count files in $root/doc"

command -v nvim >/dev/null || {
    echo "nvim not found; run :helptags doc to refresh tags" >&2
    exit 0
}
nvim --headless -c "helptags $root/doc" -c qa >/dev/null 2>&1 && [ -f "$root/doc/tags" ] ||
    die "helptags failed; run :helptags doc by hand"
echo "wrote $root/doc/tags"

# helptags only indexes a *tag* that starts a line or follows whitespace, so a
# heading long enough to leave no gap before its tag yields a |link| that goes
# nowhere. Declaring a shorter tag on that heading is the fix.
missing=$(
    awk -v project="$project" '
        FILENAME ~ /tags$/ { known[$1] = 1; next }
        {
            line = $0
            while (match(line, "\\|" project "[a-zA-Z0-9_-]*\\|")) {
                tag = substr(line, RSTART + 1, RLENGTH - 2)
                if (!(tag in known)) print tag
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$root/doc/tags" "$root"/doc/*.txt | sort -u
)
[ -z "$missing" ] || die "help tags referenced but not defined:
$(echo "$missing" | sed 's/^/  /')
  a heading whose tag leaves no gap before it is not indexed; declare a shorter
  one with <!-- tag: short-name --> at the end of that heading"
