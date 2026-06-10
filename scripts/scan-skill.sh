#!/usr/bin/env bash
# 🛡️ Guard - 技能静态扫描脚本
# 对技能文件进行快速静态模式扫描，输出 JSON 格式结果

set -euo pipefail

# ============================================================
# 配置
# ============================================================

SKILL_DIR="${1:-.}"

# 排除列表：这些文件是安全参考库，包含恶意代码示例用于教育目的
EXCLUDE_FILES=(
  "scan-patterns.md"
  "README.md"
  "scan-skill.sh"
)

# ============================================================
# 恶意模式定义
# 格式: "PATTERN_NAME§REGEX§DESCRIPTION"  (使用 § 作为分隔符，避免与正则 | 冲突)
# ============================================================

# CRITICAL 级别模式
CRITICAL_PATTERNS=(
  "remote_download_exec§curl.*\| *(bash|sh|zsh)§远程下载执行"
  "wget_download_exec§wget.*\| *(bash|sh|zsh)§远程下载执行(wget)"
  "eval_remote_exec§eval.*\$\(\s*(curl|wget)§eval远程执行"
  "data_exfil_upload§curl.*--upload-file§数据外泄-上传文件"
  "data_exfil_post§curl.*-(X|d|data).*@~§数据外泄-POST发送"
  "ssh_key_theft§\.ssh/id_(rsa|ed25519|ecdsa|dsa)§SSH密钥窃取"
  "aws_cred_theft§\.aws/(credentials|config)§AWS凭证窃取"
  "env_key_theft§\$(API_KEY|SECRET_KEY|SECRET|TOKEN|PASSWORD|PRIVATE_KEY|ACCESS_KEY)§环境变量密钥窃取"
  "recursive_delete§rm\s+-rf\s+/§递归删除关键目录"
  "reverse_shell_tcp§bash\s+-i\s+>&\s*/dev/tcp§反向Shell(TCP)"
  "reverse_shell_nc§nc\s+-e\s+/bin/(bash|sh)§反向Shell(nc)"
  "reverse_shell_ncat§ncat.*--sh-exec§反向Shell(ncat)"
  "network_listen§nc\s+-l\s+-p\s+[0-9]+§网络监听"
  "sudo_dangerous§sudo\s+(rm|chmod|chown|dd|mkfs)§sudo危险命令"
  "modify_system_file§>>\s*/etc/(passwd|shadow|sudoers|ssh|hosts)§修改系统关键文件"
  "ssh_tunnel§ssh\s+-[RLD]\s+[0-9]+§SSH隧道"
)

# HIGH 级别模式
HIGH_PATTERNS=(
  "chmod_world_writable§chmod\s+(777|666)§全局可写权限"
  "suid_escalation§chmod\s+u\+s§SUID提权"
  "dd_write_device§dd\s+if=.*of=/dev/§dd写入设备"
  "modify_ssh_config§>>\s*/etc/ssh/sshd_config§修改SSH配置"
  "bash_wildcard_perm§Bash\(\*\)§Bash通配符权限"
  "sudo_wildcard_perm§Bash\(sudo.*\*\)§sudo通配符权限"
)

# MEDIUM 级别模式
MEDIUM_PATTERNS=(
  "base64_exec§base64\s+-d\s*\|\s*(bash|sh|eval)§Base64解码执行"
  "eval_obfuscation§eval\s+\$\{|eval\s+\$[A-Z_]+§代码混淆-eval"
  "xxd_exec§xxd\s+-r\s*\|\s*(bash|sh)§xxd解码执行"
  "python_exec§python\s+-c\s+exec\(§Python exec执行"
  "path_hijack§export\s+PATH=.*:/tmp§修改PATH"
  "inject_shell_rc§>>\s*~/\.(bashrc|zshrc|profile|bash_profile|zprofile)§注入Shell配置"
  "unverified_package§pip\s+install\s+--trusted-host§安装未验证包"
  "git_config_hijack§git\s+config\s+--global\s+(credential|url\.)§Git配置篡改"
  "suppress_errors§2>\s*/dev/null§隐藏错误输出"
)

# LOW 级别模式
LOW_PATTERNS=(
  "insecure_http§http://(?!localhost|127\.0\.0\.1|0\.0\.0\.0)§不安全HTTP连接"
  "hardcoded_path§/Users/[^/]+/Desktop§硬编码路径"
)

# ============================================================
# 扫描函数
# ============================================================

scan_file() {
  local file="$1"
  local severity="$2"
  shift 2
  local patterns=("$@")

  if [[ ! -f "$file" ]]; then
    return
  fi

  # 跳过排除列表中的文件
  local basename
  basename=$(basename "$file")
  for exclude in "${EXCLUDE_FILES[@]}"; do
    if [[ "$basename" == "$exclude" ]]; then
      return
    fi
  done

  local findings=()

  for pattern_entry in "${patterns[@]}"; do
    # 解析: NAME§REGEX§DESCRIPTION (使用 § 分隔)
    local name regex description
    IFS='§' read -r name regex description <<< "$pattern_entry"

    # 跳过空正则
    [[ -z "$regex" ]] && continue

    local matches
    matches=$(grep -n -E "$regex" "$file" 2>/dev/null || true)

    if [[ -n "$matches" ]]; then
      while IFS= read -r match_line; do
        if [[ -n "$match_line" ]]; then
          local line_num
          line_num=$(echo "$match_line" | cut -d':' -f1)
          local line_content
          line_content=$(echo "$match_line" | cut -d':' -f2- | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
          local suggestion
          case "$severity" in
            CRITICAL) suggestion="立即删除该技能或移除此恶意代码" ;;
            HIGH) suggestion="强烈建议删除该技能或移除此代码" ;;
            MEDIUM) suggestion="审查此代码，确认是否为必要功能" ;;
            LOW) suggestion="了解风险后可保留，建议改用更安全的替代方案" ;;
          esac
          findings+=("{\"severity\":\"${severity}\",\"category\":\"${name}\",\"description\":\"${description}\",\"file\":\"${file}\",\"line_number\":${line_num},\"line_content\":\"${line_content}\",\"suggestion\":\"${suggestion}\"}")
        fi
      done <<< "$matches"
    fi
  done

  for finding in "${findings[@]+"${findings[@]}"}"; do
    echo "$finding"
  done
}

scan_skill_directory() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "{\"error\":\"目录不存在: ${dir}\"}"
    return 1
  fi

  local all_findings=()

  # 扫描 SKILL.md
  if [[ -f "${dir}/SKILL.md" ]]; then
    while IFS= read -r finding; do
      [[ -n "$finding" ]] && all_findings+=("$finding")
    done < <(
      scan_file "${dir}/SKILL.md" "CRITICAL" "${CRITICAL_PATTERNS[@]}"
      scan_file "${dir}/SKILL.md" "HIGH" "${HIGH_PATTERNS[@]}"
      scan_file "${dir}/SKILL.md" "MEDIUM" "${MEDIUM_PATTERNS[@]}"
      scan_file "${dir}/SKILL.md" "LOW" "${LOW_PATTERNS[@]}"
    )
  fi

  # 扫描所有脚本文件
  while IFS= read -r script_file; do
    [[ -z "$script_file" ]] && continue
    while IFS= read -r finding; do
      [[ -n "$finding" ]] && all_findings+=("$finding")
    done < <(
      scan_file "$script_file" "CRITICAL" "${CRITICAL_PATTERNS[@]}"
      scan_file "$script_file" "HIGH" "${HIGH_PATTERNS[@]}"
      scan_file "$script_file" "MEDIUM" "${MEDIUM_PATTERNS[@]}"
      scan_file "$script_file" "LOW" "${LOW_PATTERNS[@]}"
    )
  done < <(find "$dir" -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.py" -o -name "*.js" -o -name "*.rb" -o -name "*.pl" \) 2>/dev/null)

  # 扫描其他 markdown 文件
  while IFS= read -r md_file; do
    [[ -z "$md_file" || "$md_file" == "${dir}/SKILL.md" ]] && continue
    while IFS= read -r finding; do
      [[ -n "$finding" ]] && all_findings+=("$finding")
    done < <(
      scan_file "$md_file" "CRITICAL" "${CRITICAL_PATTERNS[@]}"
      scan_file "$md_file" "HIGH" "${HIGH_PATTERNS[@]}"
      scan_file "$md_file" "MEDIUM" "${MEDIUM_PATTERNS[@]}"
      scan_file "$md_file" "LOW" "${LOW_PATTERNS[@]}"
    )
  done < <(find "$dir" -type f -name "*.md" 2>/dev/null)

  # 统计
  local total=${#all_findings[@]}
  local critical=0 high=0 medium=0 low=0

  for finding in "${all_findings[@]+"${all_findings[@]}"}"; do
    local sev
    sev=$(echo "$finding" | grep -o '"severity":"[^"]*"' | head -1 | cut -d'"' -f4)
    case "$sev" in
      CRITICAL) ((++critical)) ;;
      HIGH) ((++high)) ;;
      MEDIUM) ((++medium)) ;;
      LOW) ((++low)) ;;
    esac
  done

  # 确定总体评级
  local rating="SAFE"
  if [[ $critical -gt 0 ]]; then
    rating="CRITICAL"
  elif [[ $high -gt 0 ]]; then
    rating="HIGH"
  elif [[ $medium -gt 0 ]]; then
    rating="MEDIUM"
  elif [[ $low -gt 0 ]]; then
    rating="LOW"
  fi

  # 输出 JSON 结果
  echo "{"
  echo "  \"target\": \"${dir}\","
  echo "  \"scan_time\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")\","
  echo "  \"rating\": \"${rating}\","
  echo "  \"total_findings\": ${total},"
  echo "  \"summary\": {"
  echo "    \"critical\": ${critical},"
  echo "    \"high\": ${high},"
  echo "    \"medium\": ${medium},"
  echo "    \"low\": ${low}"
  echo "  },"
  echo "  \"findings\": ["
  local i=0
  for finding in "${all_findings[@]+"${all_findings[@]}"}"; do
    if [[ $i -eq $((total - 1)) ]]; then
      echo "    ${finding}"
    else
      echo "    ${finding},"
    fi
    ((++i))
  done
  echo "  ]"
  echo "}"
}

# ============================================================
# 主入口
# ============================================================

if [[ -z "$1" ]]; then
  echo "用法: scan-skill.sh <技能目录路径> [严重级别过滤]"
  echo ""
  echo "示例:"
  echo "  scan-skill.sh ~/.claude/skills/my-skill"
  echo "  scan-skill.sh . CRITICAL"
  exit 1
fi

scan_skill_directory "$SKILL_DIR"
