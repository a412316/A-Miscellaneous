#!/usr/bin/env bash
#
# update-altstore.sh — 跟踪上游 GitHub Release,自动更新 AltStore 侧载源
#
# 流程:
#   1. 调 GitHub API 查询各应用最新 Release,与 altstore.json 中已记录的版本对比;
#   2. 有更新时下载 Release 中的 ipa,从 Payload/*.app/Info.plist 提取
#      bundleIdentifier / marketingVersion / buildVersion / minOSVersion;
#   3. 新版本写入对应文件夹的 altstore.json(替换 versions 数组,仅保留最新一条,
#      不写入 localizedDescription),最后统一 commit + push。
#
# 依赖: bash curl jq python3 git (Debian 13: apt-get install -y curl jq git)
# 注意: git 需已配置 user.name / user.email,且对远端有推送权限。
# GitHub API 匿名限流 60 次/小时,每次运行仅需「应用数」次请求,日常足够;
# 如需提升限流,可在 crontab 中导出 GITHUB_TOKEN。
#
# crontab 示例(每天 08:00 运行,0 8 */1 * * 与 0 8 * * * 等价):
#   GITHUB_TOKEN=ghp_xxxx
#   0 8 * * * /opt/A-Miscellaneous/update-altstore.sh >> /var/log/altstore-update.log 2>&1

set -euo pipefail

# ---------------------- 配置 ----------------------
# 应用列表,每行: 文件夹名|GitHub仓库(owner/repo),新增应用在此追加一行即可
APPS=(
    "PiliPlus|bggRGjQaUbCoE/PiliPlus"
    "1PanelClient|xy2026yi/1PanelClient"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_API="https://api.github.com"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
tmpdir="$(mktemp -d)"
# --------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

for c in curl jq python3 git; do
    command -v "$c" >/dev/null 2>&1 || { log "错误: 缺少依赖 $c"; exit 1; }
done

# GitHub API 请求(配置了 GITHUB_TOKEN 时自动带上)
gh_api() {
    local -a auth=()
    [[ -n "$GITHUB_TOKEN" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL --connect-timeout 15 --max-time 60 ${auth[@]+"${auth[@]}"} "$1"
}

# 从 ipa 提取 Info.plist 关键字段(输出 JSON)
ipa_info() {
    python3 - "$1" <<'PY'
import json, plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    path = next(p for p in zf.namelist()
                if p.startswith("Payload/") and p.endswith(".app/Info.plist"))
    with zf.open(path) as fp:
        info = plistlib.load(fp)
print(json.dumps({
    "bundleIdentifier":  str(info.get("CFBundleIdentifier", "")),
    "version":           str(info.get("CFBundleShortVersionString", "")),
    "buildVersion":      str(info.get("CFBundleVersion", "")),
    "minOSVersion":      str(info.get("MinimumOSVersion", "")),
}))
PY
}

main() {
    trap 'rm -rf "$tmpdir"' EXIT   # tmpdir 为全局变量,确保 EXIT trap 能引用到

    local -a updated=()   # 本次更新的「应用 旧版本 -> 新版本」列表
    local failed=0

    local entry
    for entry in "${APPS[@]}"; do
        local folder="${entry%%|*}" repo="${entry##*|}"
        local json_file="$REPO_ROOT/$folder/altstore.json"
        if [[ ! -f "$json_file" ]]; then
            log "错误: $folder 缺少 $json_file,跳过"
            failed=1
            continue
        fi

        # ---------- 1. 获取最新 Release 并与本地对比 ----------
        local release
        if ! release="$(gh_api "$GITHUB_API/repos/$repo/releases/latest")"; then
            log "错误: 获取 $repo 最新 Release 失败,跳过"
            failed=1
            continue
        fi

        local tag latest
        tag="$(jq -r '.tag_name // ""' <<<"$release")"
        latest="${tag#v}"   # 去掉 v 前缀,如 v0.2.1 -> 0.2.1
        if [[ -z "$latest" ]]; then
            log "错误: $repo Release 响应中没有 tag_name,跳过"
            failed=1
            continue
        fi

        # 最新 Release 的 ipa 资产(取第一个 .ipa)
        local ipa_url ipa_size
        ipa_url="$(jq -r '[.assets[] | select(.name | endswith(".ipa"))][0].browser_download_url // ""' <<<"$release")"
        ipa_size="$(jq -r '[.assets[] | select(.name | endswith(".ipa"))][0].size // 0' <<<"$release")"
        if [[ -z "$ipa_url" ]]; then
            log "错误: $repo Release $tag 中没有 ipa 资产,跳过"
            failed=1
            continue
        fi

        # 本地已记录的版本(altstore.json versions 数组首项)
        local local_version local_url
        local_version="$(jq -r '.apps[0].versions[0].version // ""' "$json_file")"
        local_url="$(jq -r '.apps[0].versions[0].downloadURL // ""' "$json_file")"

        # 版本号相同,或该 Release 的 ipa 已记录过 → 无更新
        if [[ "$latest" == "$local_version" || "$ipa_url" == "$local_url" ]]; then
            log "$folder: 已是最新版本 $local_version"
            continue
        fi

        # ---------- 2. 下载 ipa 并提取信息 ----------
        local ipa="$tmpdir/${folder}.ipa"
        log "$folder: 发现新版本 $local_version -> $latest,开始下载 ipa ..."
        if ! curl -fsSL --connect-timeout 15 -o "$ipa" "$ipa_url"; then
            log "错误: 下载 ipa 失败($ipa_url),跳过"
            failed=1
            continue
        fi

        local info
        if ! info="$(ipa_info "$ipa")"; then
            log "错误: 解析 $repo 的 ipa 失败,跳过"
            failed=1
            continue
        fi
        local new_ver new_build min_os bundle_id
        new_ver="$(jq -r '.version' <<<"$info")"
        new_build="$(jq -r '.buildVersion' <<<"$info")"
        min_os="$(jq -r '.minOSVersion' <<<"$info")"
        bundle_id="$(jq -r '.bundleIdentifier' <<<"$info")"

        if [[ -n "$bundle_id" && "$bundle_id" != "$(jq -r '.apps[0].bundleIdentifier // ""' "$json_file")" ]]; then
            log "警告: $folder 的 bundleIdentifier 与 ipa 不一致(ipa=$bundle_id),请人工确认"
        fi

        # ipa 文件大小: 优先使用 API 返回的资产大小
        local size="$ipa_size"
        [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || size="$(wc -c < "$ipa" | tr -d ' ')"

        # Release 日期(UTC)
        local release_date
        release_date="$(jq -r '(.published_at // .created_at // "") | split("T")[0]' <<<"$release")"
        release_date="${release_date:-$(date '+%Y-%m-%d')}"

        # ---------- 3. 更新 altstore.json ----------
        local tmp_json="$tmpdir/altstore.json"
        if ! jq --arg version "$new_ver" \
                --arg build "$new_build" \
                --arg date "$release_date" \
                --arg url "$ipa_url" \
                --argjson size "$size" \
                --arg minos "$min_os" '
                .apps[0].versions = [{
                    version:          $version,
                    buildVersion:     $build,
                    marketingVersion: $version,
                    date:             $date,
                    downloadURL:      $url,
                    size:             $size,
                    minOSVersion:     $minos
                }]
            ' "$json_file" > "$tmp_json"; then
            log "错误: 生成 $folder 新 altstore.json 失败,跳过"
            failed=1
            continue
        fi
        mv "$tmp_json" "$json_file"
        git -C "$REPO_ROOT" add "$json_file"
        updated+=("$folder $local_version → $new_ver")
        log "$folder: altstore.json 已更新 $local_version -> $new_ver (build $new_build, minOS $min_os)"
    done

    # ---------- commit + push ----------
    if [[ ${#updated[@]} -gt 0 ]]; then
        local msg="自动更新侧载源: ${updated[*]}"
        if ! git -C "$REPO_ROOT" commit -m "$msg"; then
            log "错误: git commit 失败(检查 user.name/user.email 是否已配置)"
            exit 1
        fi
        git -C "$REPO_ROOT" pull --rebase --quiet || log "警告: pull --rebase 失败,直接尝试 push"
        if git -C "$REPO_ROOT" push; then
            log "已提交并推送: $msg"
        else
            log "错误: push 失败,请检查远端权限或网络(提交已保留在本地)"
            exit 1
        fi
    else
        log "所有应用均无更新,未产生提交"
    fi

    [[ $failed -eq 0 ]] || exit 1
}

main "$@"
