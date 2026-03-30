#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="config/images.txt"

if [[ -z "${DOCKERHUB_USERNAME:-}" ]]; then
  echo "ERROR: DOCKERHUB_USERNAME is not set."
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

echo "Using Docker Hub namespace: ${DOCKERHUB_USERNAME}"
echo "Reading config from: ${CONFIG_FILE}"
echo

copy_image() {
  local src_image="$1"
  local dst_repo="$2"
  local tag="$3"

  local src="docker://${src_image}:${tag}"
  local dst="docker://docker.io/${DOCKERHUB_USERNAME}/${dst_repo}:${tag}"

  echo "=================================================="
  echo "Syncing:"
  echo "  FROM: ${src}"
  echo "  TO  : ${dst}"
  echo "=================================================="

  # 先尝试保留多架构镜像
  if skopeo copy --all "$src" "$dst"; then
    echo "SUCCESS: ${src_image}:${tag} -> ${DOCKERHUB_USERNAME}/${dst_repo}:${tag}"
    return 0
  fi

  echo "WARN: copy with --all failed, retrying without --all ..."
  if skopeo copy "$src" "$dst"; then
    echo "SUCCESS (single-arch fallback): ${src_image}:${tag} -> ${DOCKERHUB_USERNAME}/${dst_repo}:${tag}"
    return 0
  fi

  echo "ERROR: Failed to sync ${src_image}:${tag}"
  return 1
}

failed=0
line_number=0

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  ((line_number+=1))

  # 去掉首尾空白
  line="$(echo "$raw_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # 跳过空行和注释
  if [[ -z "$line" || "$line" =~ ^# ]]; then
    continue
  fi

  # 格式: source_image|target_repo|tag1,tag2,tag3
  IFS='|' read -r source_image target_repo tags <<< "$line"

  if [[ -z "${source_image:-}" || -z "${target_repo:-}" || -z "${tags:-}" ]]; then
    echo "ERROR: Invalid config at line ${line_number}: ${raw_line}"
    failed=1
    continue
  fi

  IFS=',' read -ra tag_array <<< "$tags"

  for tag in "${tag_array[@]}"; do
    tag="$(echo "$tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$tag" ]]; then
      continue
    fi

    if ! copy_image "$source_image" "$target_repo" "$tag"; then
      failed=1
    fi
    echo
  done
done < "$CONFIG_FILE"

if [[ "$failed" -ne 0 ]]; then
  echo "One or more image sync tasks failed."
  exit 1
fi

echo "All image sync tasks completed successfully."