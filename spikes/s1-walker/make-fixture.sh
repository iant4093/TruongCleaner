#!/bin/bash
# Builds the S1 smoke-test tree at spikes/s1-walker/out/fixture (always that path).
# Contents: ~5,000 files in nested folders, hard links, a symlink to a folder outside
# the fixture, a mode-000 folder, a sparse file, empty files, a FIFO.
# Remove it with: bash spikes/s1-walker/make-fixture.sh --remove
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$here/out/fixture"

remove_fixture() {
    if [ -e "$fixture" ] || [ -L "$fixture" ]; then
        # The mode-000 folder must be readable again before it can be removed.
        chmod -R u+rwx "$fixture" 2>/dev/null || true
        # Fixed path inside spikes/s1-walker/out/ only.
        rm -rf "$fixture"
    fi
}

if [ "${1:-}" = "--remove" ]; then
    remove_fixture
    echo "removed $fixture"
    exit 0
fi

remove_fixture
mkdir -p "$fixture"

# 10 x 5 x 4 = 200 leaf folders, 25 files each = 5,000 files of varied size.
for top in 0 1 2 3 4 5 6 7 8 9; do
    for mid in 0 1 2 3 4; do
        for leaf in 0 1 2 3; do
            mkdir -p "$fixture/top$top/mid$mid/leaf$leaf"
        done
    done
done

i=0
while [ "$i" -lt 5000 ]; do
    top=$((i % 10))
    mid=$(((i / 10) % 5))
    leaf=$(((i / 50) % 4))
    size=$(((i % 13) * 700))
    printf "%${size}s" "" >"$fixture/top$top/mid$mid/leaf$leaf/f$i"
    i=$((i + 1))
done

# Hard links: three links to each of five files, some in other folders.
mkdir -p "$fixture/links"
for n in 1 2 3 4 5; do
    src="$fixture/top0/mid0/leaf0/f$(((n - 1) * 10 * 5 * 4 + 0))"
    [ -f "$src" ] || src="$fixture/top0/mid0/leaf0/f0"
    ln "$src" "$fixture/links/hl${n}_a"
    ln "$src" "$fixture/links/hl${n}_b"
    ln "$src" "$fixture/top9/hl${n}_c"
done

# Symlinks: to a folder outside the fixture (following it would add Sources/), to a file, dangling.
ln -s "$here/Sources" "$fixture/symlink-to-outside-folder"
ln -s "$fixture/top1/mid1/leaf1/f1" "$fixture/symlink-to-file"
ln -s "$fixture/does-not-exist" "$fixture/symlink-dangling"

# Sparse (100 MB logical, almost nothing allocated), empty files, a FIFO.
mkdir -p "$fixture/special"
dd if=/dev/null of="$fixture/special/sparse" bs=1 count=0 seek=104857600 2>/dev/null
for n in 1 2 3 4 5 6 7 8 9 10; do
    : >"$fixture/special/empty$n"
done
mkfifo "$fixture/special/fifo"

# Unreadable folder: contents created first, then mode 000.
mkdir -p "$fixture/denied"
printf "%5000s" "" >"$fixture/denied/secret"
chmod 000 "$fixture/denied"

echo "fixture ready at $fixture"
