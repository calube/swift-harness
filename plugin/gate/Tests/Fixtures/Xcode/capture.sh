#!/bin/sh
# Rebuilds every fixture under this directory from public repositories pinned at a commit. Run from
# the repository root, with network access, Xcode, XcodeGen and mise on PATH:
#   plugin/gate/Tests/Fixtures/Xcode/capture.sh
# Each case holds 1 project.pbxproj per inclusion kind and the tool output read from it. Tracked
# files are copied byte for byte into `<case>/tree/<tracked path>`; Swift manifests get a `.txt`
# suffix so no Swift tool lints or builds them. Machine paths in tool output become `/REPO` (the
# clone root, or the scratch directory holding a damaged project) and `/TMP` (the temp dir).
set -eu

OUT=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$(mktemp -d)" && pwd)
trap '/bin/rm -rf "$W"' EXIT
TMP=$(cd "${TMPDIR:-/tmp}" && pwd)

XCODEGEN_VERSION=2.45.3
TUIST_VERSION=4.210.0

# The clone directory carries the repository's name: XcodeGen names a local package's folder
# reference after the directory it points at, so another name changes the generated project.
clone() { # <owner/repo> <dir> <sha> [sparse path]
  git clone -q --filter=blob:none --no-checkout ${4:+--sparse} "https://github.com/$1.git" "$W/$2"
  if [ -n "${4:-}" ]; then git -C "$W/$2" sparse-checkout set "$4"; fi
  git -C "$W/$2" checkout -q "$3"
}

source_file() { # <case> <owner/repo> <dir> <what>
  {
    echo "url: https://github.com/$2"
    echo "commit: $(git -C "$W/$3" rev-parse HEAD)"
    echo "commit-date: $(git -C "$W/$3" log -1 --format=%cI)"
    echo "license: $(gh api "repos/$2" --jq .license.spdx_id)"
    echo "languages: $(gh api "repos/$2/languages" --jq 'keys | join(", ")')"
    echo "captured-utc: $(date -u +%Y-%m-%d)"
    echo "command: git clone --filter=blob:none --no-checkout https://github.com/$2.git && git checkout $(git -C "$W/$3" rev-parse HEAD)"
    echo "kind: $4"
  } > "$OUT/$1/SOURCE"
}

keep() { # <case> <dir> <tracked path> [suffix]
  mkdir -p "$OUT/$1/tree/$(dirname "$3")"
  /bin/cp -f "$W/$2/$3" "$OUT/$1/tree/$3${4:-}"
}

scrub() { # <root> — reads stdin
  sed -e "s#$1#/REPO#g" -e "s#$TMP#/TMP#g" -e "s#/private/TMP#/TMP#g"
}

run() { # <case> <name> <root> <cmd...> — records stdout, stderr and exit status
  c=$1 n=$2 r=$3
  shift 3
  set +e
  "$@" > "$W/out" 2> "$W/err"
  echo $? > "$OUT/$c/$n.status"
  set -e
  scrub "$r" < "$W/out" > "$OUT/$c/$n.stdout"
  scrub "$r" < "$W/err" > "$OUT/$c/$n.stderr"
}

/bin/rm -rf "$OUT/synchronized" "$OUT/explicit" "$OUT/xcodegen" "$OUT/tuist"
mkdir -p "$OUT/synchronized" "$OUT/explicit" "$OUT/xcodegen" "$OUT/tuist"

# Synchronized folders: the first public result of
# `gh search code PBXFileSystemSynchronizedRootGroup --filename project.pbxproj` with a second language.
clone Shopify/mobile-buy-sdk-ios mobile-buy-sdk-ios 350c914d8beea856026807cbd3effc73aaf8b7cd
source_file synchronized Shopify/mobile-buy-sdk-ios mobile-buy-sdk-ios "synchronized folders (PBXFileSystemSynchronizedRootGroup)"
git -C "$W/mobile-buy-sdk-ios" ls-files > "$OUT/synchronized/ls-files.txt"
keep synchronized mobile-buy-sdk-ios Buy.xcodeproj/project.pbxproj
(cd "$W/mobile-buy-sdk-ios" && run synchronized xcodebuild-list "$W/mobile-buy-sdk-ios" xcodebuild -list -json -project Buy.xcodeproj)

# Explicit lists: every source file has a file reference, a build file and a Sources phase entry.
clone touchlab/KaMPKit KaMPKit 4af02006be4be589e6848f097a92d97539300821
source_file explicit touchlab/KaMPKit KaMPKit "explicit file lists"
git -C "$W/KaMPKit" ls-files > "$OUT/explicit/ls-files.txt"
keep explicit KaMPKit ios/KaMPKitiOS.xcodeproj/project.pbxproj
(cd "$W/KaMPKit" && run explicit xcodebuild-list "$W/KaMPKit" xcodebuild -list -json -project ios/KaMPKitiOS.xcodeproj)
(cd "$W/KaMPKit" && run explicit plutil-lint-valid "$W/KaMPKit" plutil -lint ios/KaMPKitiOS.xcodeproj/project.pbxproj)
# A damaged project: the first half of the same file's bytes.
D=$W/damaged
mkdir -p "$D/KaMPKitiOS.xcodeproj"
P=$W/KaMPKit/ios/KaMPKitiOS.xcodeproj/project.pbxproj
head -c $(($(wc -c < "$P") / 2)) "$P" > "$D/KaMPKitiOS.xcodeproj/project.pbxproj"
mkdir -p "$OUT/explicit/damaged/KaMPKitiOS.xcodeproj"
/bin/cp -f "$D/KaMPKitiOS.xcodeproj/project.pbxproj" "$OUT/explicit/damaged/KaMPKitiOS.xcodeproj/project.pbxproj"
(cd "$D" && run explicit plutil-lint-damaged "$D" plutil -lint KaMPKitiOS.xcodeproj/project.pbxproj)
(cd "$D" && run explicit xcodebuild-list-damaged "$D" xcodebuild -list -json -project KaMPKitiOS.xcodeproj)
# xcodebuild writes a result bundle for the failed -list into the user temp dir, whatever TMPDIR says.
sed -n 's/.*Writing error result bundle to //p' "$W/err" | while read -r b; do /bin/rm -rf "$b"; done

# XcodeGen: the tool's own SPM fixture at the tag matching the installed XcodeGen.
clone yonaskolb/XcodeGen XcodeGen 90dfa9da31eeb3b95153e22f46dce676d9ebaba7
source_file xcodegen yonaskolb/XcodeGen XcodeGen "XcodeGen project.yml with its generated project tracked"
X=Tests/Fixtures/SPM
git -C "$W/XcodeGen" ls-files "$X" > "$OUT/xcodegen/ls-files.txt"
keep xcodegen XcodeGen "$X/project.yml"
keep xcodegen XcodeGen "$X/SPM.xcodeproj/project.pbxproj"
run xcodegen xcodegen-version "$W/XcodeGen" xcodegen --version
grep -qx "Version: $XCODEGEN_VERSION" "$OUT/xcodegen/xcodegen-version.stdout"
(cd "$W/XcodeGen/$X" && run xcodegen xcodegen-generate "$W/XcodeGen" xcodegen generate)
git -C "$W/XcodeGen" status --porcelain > "$OUT/xcodegen/git-status-after-generate.txt"
mkdir -p "$OUT/xcodegen/generated/SPM.xcodeproj"
/bin/cp -f "$W/XcodeGen/$X/SPM.xcodeproj/project.pbxproj" "$OUT/xcodegen/generated/SPM.xcodeproj/project.pbxproj"
run xcodegen not-installed "$W/XcodeGen" /usr/bin/env PATH=/usr/bin:/bin xcodegen generate

# Tuist: an example at the tag of the release installed into scratch with mise.
clone tuist/tuist tuist 7e114b65d7b4fd5eaa9409d6ddbf697ce42d9d8e examples/xcode/generated_app_with_framework_and_tests
source_file tuist tuist/tuist tuist "Tuist Project.swift with its generated project ignored"
echo "license-note: LICENSE.md licenses everything MIT except server/, kura/ and atlas/ (MPL-2.0)" >> "$OUT/tuist/SOURCE"
T=examples/xcode/generated_app_with_framework_and_tests
git -C "$W/tuist" ls-files "$T" > "$OUT/tuist/ls-files.txt"
keep tuist tuist "$T/Project.swift" .txt
keep tuist tuist "$T/Tuist.swift" .txt
keep tuist tuist "$T/.gitignore"
(cd "$W" && MISE_DATA_DIR=$W/mise MISE_CACHE_DIR=$W/mise-cache MISE_STATE_DIR=$W/mise-state MISE_CONFIG_DIR=$W/mise-config \
  mise install "tuist@$TUIST_VERSION")
TB=$W/mise/installs/tuist/$TUIST_VERSION/bin
run tuist tuist-version "$W/tuist" "$TB/tuist" version
(cd "$W/tuist/$T" && run tuist tuist-generate "$W/tuist" env PATH="$TB:$PATH" tuist generate --no-open)
git -C "$W/tuist" status --porcelain --ignored > "$OUT/tuist/git-status-after-generate.txt"
mkdir -p "$OUT/tuist/generated/App.xcodeproj"
/bin/cp -f "$W/tuist/$T/App.xcodeproj/project.pbxproj" "$OUT/tuist/generated/App.xcodeproj/project.pbxproj"
run tuist not-installed "$W/tuist" /usr/bin/env PATH=/usr/bin:/bin tuist generate --no-open
