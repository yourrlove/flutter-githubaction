#!/usr/bin/env bash
# Publish a signed mobile build to the App Distribution Portal over its REST API.
#
# The portal's `adp` CLI is not published to npm, so this script performs the
# same flow directly with curl + jq (both preinstalled on GitHub's ubuntu
# runners):
#   1. POST /api/v1/projects/{project}/builds   -> presigned upload slot
#   2. PUT  <presigned url>                     -> upload the artifact to storage
#   3. POST /api/v1/builds/{id}/complete        -> verify + mark READY
#   4. POST /api/v1/builds/{id}/publish         -> assign channel + notify testers
#
# Required environment:
#   ADP_API_URL       e.g. https://portal.example.com/api/v1
#   ADP_TOKEN         project-scoped API token (builds:write)
#   ADP_PROJECT       project slug or UUID
#   ADP_FILE          path to the .apk/.ipa
#   ADP_VERSION       version string, e.g. 1.4.0 (a leading "v" is stripped)
#   ADP_BUILD_NUMBER  build number string (unique per version)
# Optional:
#   ADP_PLATFORM      android | ios (default: inferred from the file extension)
#   ADP_CHANNEL       channel to publish to (default: staging)
#   ADP_CHANGELOG     release notes (default: "Automated build")
#   ADP_PUBLISH       "true" to publish after upload (default: false)
#   ADP_NOTIFY        "true" to email channel subscribers on publish (default: true)
set -euo pipefail

need() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "error: missing required environment variable $name" >&2
    exit 2
  fi
}

need ADP_API_URL
need ADP_TOKEN
need ADP_PROJECT
need ADP_FILE
need ADP_VERSION
need ADP_BUILD_NUMBER

if [ ! -f "$ADP_FILE" ]; then
  echo "error: artifact not found: $ADP_FILE" >&2
  exit 2
fi

API_URL="${ADP_API_URL%/}"
ADP_VERSION="${ADP_VERSION#v}"
PLATFORM="${ADP_PLATFORM:-}"
CHANNEL="${ADP_CHANNEL:-staging}"
CHANGELOG="${ADP_CHANGELOG:-Automated build}"
PUBLISH="${ADP_PUBLISH:-false}"
NOTIFY="${ADP_NOTIFY:-true}"

# Infer platform + content type from the extension when not given.
lower_file="$(printf '%s' "$ADP_FILE" | tr '[:upper:]' '[:lower:]')"
if [ -z "$PLATFORM" ]; then
  case "$lower_file" in
    *.apk) PLATFORM="android" ;;
    *.ipa) PLATFORM="ios" ;;
    *)
      echo "error: cannot infer platform from '$ADP_FILE'; set ADP_PLATFORM" >&2
      exit 2
      ;;
  esac
fi

case "$PLATFORM" in
  android | ANDROID)
    PLATFORM_ENUM="ANDROID"
    CONTENT_TYPE="application/vnd.android.package-archive"
    ;;
  ios | IOS)
    PLATFORM_ENUM="IOS"
    CONTENT_TYPE="application/octet-stream"
    ;;
  *)
    echo "error: unsupported platform '$PLATFORM'" >&2
    exit 2
    ;;
esac

FILE_NAME="$(basename "$ADP_FILE")"
FILE_SIZE="$(stat -c%s "$ADP_FILE")"
AUTH_HEADER="authorization: Bearer $ADP_TOKEN"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

api_call() {
  # api_call <method> <path> <json-body|-> <out-file>
  local method="$1" path="$2" body="$3" out="$4"
  local -a args=(-sS -X "$method" "$API_URL$path" -H "$AUTH_HEADER" -H 'accept: application/json' -o "$out" -w '%{http_code}')
  if [ "$body" != "-" ]; then
    args+=(-H 'content-type: application/json' --data "$body")
  fi
  local code
  code="$(curl "${args[@]}")"
  if [ "$code" -ge 300 ]; then
    echo "error: $method $path returned HTTP $code" >&2
    cat "$out" >&2 || true
    echo >&2
    exit 1
  fi
}

echo "==> Creating upload slot for $ADP_PROJECT ($FILE_NAME, $FILE_SIZE bytes)"
slot_payload="$(jq -n \
  --arg platform "$PLATFORM_ENUM" \
  --arg version "$ADP_VERSION" \
  --arg buildNumber "$ADP_BUILD_NUMBER" \
  --arg changelog "$CHANGELOG" \
  --arg fileName "$FILE_NAME" \
  --argjson fileSize "$FILE_SIZE" \
  --arg contentType "$CONTENT_TYPE" \
  '{
     platform: $platform,
     version: $version,
     buildNumber: $buildNumber,
     changelog: $changelog,
     fileName: $fileName,
     fileSize: $fileSize,
     contentType: $contentType
   }')"
api_call POST "/projects/$ADP_PROJECT/builds" "$slot_payload" "$tmp_dir/slot.json"

BUILD_ID="$(jq -r '.build.id' "$tmp_dir/slot.json")"
UPLOAD_URL="$(jq -r '.upload.url' "$tmp_dir/slot.json")"
if [ -z "$BUILD_ID" ] || [ "$BUILD_ID" = "null" ] || [ -z "$UPLOAD_URL" ] || [ "$UPLOAD_URL" = "null" ]; then
  echo "error: unexpected create-slot response:" >&2
  cat "$tmp_dir/slot.json" >&2
  exit 1
fi

# Replay exactly the headers the presigned URL was signed with (content-type).
upload_headers=()
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] && upload_headers+=(-H "$key: $value")
done < <(jq -r '.upload.headers // {} | to_entries[] | "\(.key)\t\(.value)"' "$tmp_dir/slot.json")

echo "==> Uploading artifact to storage"
put_code="$(curl -sS -X PUT -T "$ADP_FILE" "${upload_headers[@]}" "$UPLOAD_URL" -o "$tmp_dir/put.out" -w '%{http_code}')"
if [ "$put_code" -ge 300 ]; then
  echo "error: presigned upload returned HTTP $put_code" >&2
  cat "$tmp_dir/put.out" >&2 || true
  exit 1
fi

CHECKSUM="$(sha256sum "$ADP_FILE" | cut -d' ' -f1)"
echo "==> Completing upload (sha256=$CHECKSUM)"
api_call POST "/builds/$BUILD_ID/complete" "$(jq -n --arg c "$CHECKSUM" '{checksumSha256: $c}')" "$tmp_dir/complete.json"

echo "build $BUILD_ID $(jq -r '.status' "$tmp_dir/complete.json")"

if [ "$PUBLISH" = "true" ]; then
  echo "==> Publishing to channel '$CHANNEL' (notify=$NOTIFY)"
  api_call POST "/builds/$BUILD_ID/publish" \
    "$(jq -n --arg channel "$CHANNEL" --argjson notify "$NOTIFY" '{channel: $channel, notify: $notify}')" \
    "$tmp_dir/publish.json"
fi

INSTALL_URL="$(jq -r '.installUrl // empty' "$tmp_dir/complete.json")"
if [ -n "$INSTALL_URL" ]; then
  echo "install: $INSTALL_URL"
fi
echo "::notice title=App Distribution Portal::uploaded $FILE_NAME as build $BUILD_ID"
