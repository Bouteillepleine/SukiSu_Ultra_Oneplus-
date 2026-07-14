#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SUSFS patches"

required_env=(
  KERNEL_PLATFORM_FOLDER
  COMMON_KERNEL_FOLDER
  SUSFS_FOLDER
  ARTIFACTS_FOLDER
  OP_MODEL
  OP_OS_VERSION
  KSU_FOLDER
  ANDROID_VER_LOCAL
  KERNEL_VER_LOCAL
)

for v in "${required_env[@]}"; do
  if [ -z "${!v:-}" ]; then
echo "::error::Required environment variable '$v' is not set"
exit 1
  fi
done

cd "$KERNEL_PLATFORM_FOLDER"

cp "$SUSFS_FOLDER/kernel_patches/fs/"* "$COMMON_KERNEL_FOLDER/fs/"
cp "$SUSFS_FOLDER/kernel_patches/include/linux/"* "$COMMON_KERNEL_FOLDER/include/linux/"

susfs_version="$(grep '#define SUSFS_VERSION' "$COMMON_KERNEL_FOLDER/include/linux/susfs.h" | awk -F'"' '{print $2}')"

{
  echo "SUSVER=$susfs_version"
} >> "$GITHUB_ENV"

echo "$susfs_version" >> "${ARTIFACTS_FOLDER}/${OP_MODEL}_${OP_OS_VERSION}.txt"

echo "SusFS Version: $susfs_version"

case "$susfs_version" in
  v2.1.0|v2.2.0)
    echo "Supported SUSFS version detected: $susfs_version"
    ;;
  *)
    echo "::error::This workflow step supports SUSFS v2.1.0 and v2.2.0 only. Detected: $susfs_version"
    exit 1
    ;;
esac

echo "NEED_HOOKS=false" >> "$GITHUB_ENV"

# =============================================================================
# Generic helpers
# =============================================================================

ensure_include_after_or_top() {
  local file="$1"
  local include="$2"
  local anchor="${3:-}"

  [ -f "$file" ] || return 0

  if grep -qxF "$include" "$file"; then
return 0
  fi

  if [ -n "$anchor" ] && grep -qF "$anchor" "$file"; then
sed -i "/$(printf '%s' "$anchor" | sed 's/[.[\*^$()+?{}|]/\\&/g')/a $include" "$file"
  else
sed -i "1i$include" "$file"
  fi
}

# =============================================================================
# SukiSU compatibility helpers
# =============================================================================

# SukiSU's ksu_late_loaded (LKM "late load" mode) has no meaning for these built-in,
# kprobe-hooked SUSFS builds. The susfs enable-patch strips it tree-wide (it removes
# the definition, the extern, the assignments and every branch), but those hunks reject
# against current SukiSU, so we replicate the removal by hand. Delete the definition and
# assignments (a bare `0 = ...;` would not compile), then force every remaining read to
# the built-in-always value: !ksu_late_loaded -> 1, ksu_late_loaded -> 0. Idempotent, so
# it is a no-op wherever the patch hunks happened to apply.
neutralize_ksu_late_loaded() {
  local target="$1"
  [ -f "$target" ] || return 0

  sed -i \
-e '/^[[:space:]]*bool[[:space:]]\+ksu_late_loaded[[:space:]]*;/d' \
-e '/^[[:space:]]*ksu_late_loaded[[:space:]]*=/d' \
"$target" || true

  sed -i \
-e 's/![[:space:]]*ksu_late_loaded/1/g' \
-e 's/\bksu_late_loaded\b/0/g' \
"$target" || true
}

fix_sukisu_init_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU init compatibility in: $target"

  sed -i '/ksu_lsm_hook_init[[:space:]]*();/d' "$target" || true

  sed -i \
-e 's/\bksu_syscall_hook_manager_init[[:space:]]*(/ksu_syscall_hook_init(/g' \
-e 's/\bksu_syscall_hook_manager_exit[[:space:]]*(/ksu_syscall_hook_exit(/g' \
"$target" || true

  neutralize_ksu_late_loaded "$target"

  local root_dir
  root_dir="$(dirname "$(dirname "$target")")"

  # The definition is gone, so drop the now-dangling extern in the tree's ksu.h too
  # (covers the KSU tree kernel/include/ksu.h and the mirror drivers/kernelsu/include/ksu.h).
  if [ -f "$root_dir/include/ksu.h" ]; then
sed -i '/extern[[:space:]]\+bool[[:space:]]\+ksu_late_loaded[[:space:]]*;/d' "$root_dir/include/ksu.h" || true
  fi

  if ! grep -Rqs '^[[:space:]]*\(void\|int\)[[:space:]]\+ksu_syscall_hook_init[[:space:]]*(' "$root_dir" --include='*.c' 2>/dev/null; then
sed -i '/ksu_syscall_hook_init[[:space:]]*();/d' "$target" || true
  fi

  if ! grep -Rqs '^[[:space:]]*\(void\|int\)[[:space:]]\+ksu_syscall_hook_exit[[:space:]]*(' "$root_dir" --include='*.c' 2>/dev/null; then
sed -i '/ksu_syscall_hook_exit[[:space:]]*();/d' "$target" || true
  fi

  if grep -nE 'ksu_lsm_hook_init|ksu_late_loaded|ksu_syscall_hook_manager_init|ksu_syscall_hook_manager_exit' "$target"; then
echo "::error::Legacy SukiSU-incompatible symbols remain in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

ensure_susfs_init_call() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Ensuring susfs_init() is wired in: $target"

  if ! grep -q '#include <linux/susfs.h>' "$target"; then
if grep -q '#include "ksu.h"' "$target"; then
  sed -i '/#include "ksu.h"/a #include <linux/susfs.h>' "$target"
else
  sed -i '1i#include <linux/susfs.h>' "$target"
fi
  fi

  if ! grep -q 'susfs_init[[:space:]]*();' "$target"; then
if grep -q 'ksu_feature_init[[:space:]]*();' "$target"; then
  sed -i '/ksu_feature_init[[:space:]]*();/a #ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif' "$target"
elif grep -q 'ksu_supercalls_init[[:space:]]*();' "$target"; then
  sed -i '/ksu_supercalls_init[[:space:]]*();/i #ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif' "$target"
elif grep -q 'ksu_allowlist_init[[:space:]]*();' "$target"; then
  sed -i '/ksu_allowlist_init[[:space:]]*();/i #ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif' "$target"
else
  echo "::error::Could not find safe anchor for susfs_init() in $target"
  sed -n '1,180p' "$target"
  exit 1
fi
  fi

  if ! grep -q 'susfs_init[[:space:]]*();' "$target"; then
echo "::error::susfs_init() was not inserted into $target"
exit 1
  fi

  echo "✅ susfs_init() is present in $target"
}

# SUSFS v2.2.0: the SUSFS KernelSU-enable patch switches setuid/sucompat handling
# to the standalone inline entry points ksu_sucompat_init() and ksu_setuid_hook_init()
# (the latter only wires ksu_kernel_umount_init(); it does NOT install a second setuid
# hook, so there is no double-hook with SukiSU's syscall-redirect path). The enable
# patch's init.c hunk rejects against SukiSU, so kernelsu_init() is left without these
# calls. Wire them in after ksu_supercalls_init(), matching the patch's intended order.
#
# Every insert is guarded on the callee actually being DEFINED in the tree, so this is a
# no-op on SUSFS v2.1.0 (where these symbols may be absent) and only activates on v2.2.0.
ensure_sukisu_inline_hook_init() {
  local target="$1"
  [ -f "$target" ] || return 0

  local root_dir
  root_dir="$(dirname "$(dirname "$target")")"

  echo "Ensuring v2.2.0 inline hook init calls in: $target"

  _fn_defined() {
    # matches "void ksu_x_init(", "void __init ksu_x_init(", "int __init ksu_x_init(" ...
    grep -RqsE "\b(void|int)([[:space:]]+__[a-z_]+)*[[:space:]]+$1[[:space:]]*\(" \
      "$root_dir" --include='*.c'
  }

  _ensure_after_supercalls() {
    local fn="$1"
    grep -qE "\b${fn}[[:space:]]*\(" "$target" && return 0            # already called
    _fn_defined "$fn" || { echo "  (skip $fn: not defined in tree)"; return 0; }
    grep -q 'ksu_supercalls_init[[:space:]]*();' "$target" || {
      echo "::error::No ksu_supercalls_init() anchor for $fn in $target"; exit 1; }
    sed -i "/ksu_supercalls_init[[:space:]]*();/a\\    ${fn}();" "$target"
    echo "  (inserted $fn after ksu_supercalls_init)"
  }

  # Insert setuid_hook first, then sucompat, so the resulting order is:
  #   ksu_supercalls_init(); ksu_sucompat_init(); ksu_setuid_hook_init();
  _ensure_after_supercalls ksu_setuid_hook_init
  _ensure_after_supercalls ksu_sucompat_init

  echo "✅ inline hook init calls ensured in $target"
}

fix_sukisu_boot_event_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU boot_event compatibility in: $target"

  if grep -q 'ksu_stop_input_hook_runtime[[:space:]]*();' "$target"; then
awk '
  {
    if ($0 ~ /^[[:space:]]*ksu_stop_input_hook_runtime[[:space:]]*\(\);/) {
      indent = $0
      sub(/ksu_stop_input_hook_runtime.*/, "", indent)
      print indent "if (static_key_enabled(&ksu_is_input_hook_enabled)) {"
      print indent "    static_branch_disable(&ksu_is_input_hook_enabled);"
      print indent "    pr_info(\"ksu_input_hook is disabled\\n\");"
      print indent "}"
      next
    }
    print
  }
' "$target" > "$target.tmp"
mv "$target.tmp" "$target"
  fi

  grep -q '#include <linux/jump_label.h>' "$target" || sed -i '1i#include <linux/jump_label.h>' "$target"

  if grep -q 'ksu_is_input_hook_enabled' "$target" && \
 ! grep -q 'extern struct static_key_true ksu_is_input_hook_enabled' "$target" && \
 ! grep -q 'extern struct static_key_false ksu_is_input_hook_enabled' "$target"; then
sed -i '/#include <linux\/jump_label.h>/a extern struct static_key_true ksu_is_input_hook_enabled;' "$target"
  fi

  if grep -n 'ksu_stop_input_hook_runtime' "$target"; then
echo "::error::ksu_stop_input_hook_runtime still remains in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_ksud_integration_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU ksud_integration compatibility in: $target"

  neutralize_ksu_late_loaded "$target"

  if ! grep -q 'ksu_no_custom_rc' "$target"; then
echo "ℹ️ ksu_no_custom_rc not referenced in $target"
return 0
  fi

  if grep -qE '^[[:space:]]*(extern[[:space:]]+)?bool[[:space:]]+ksu_no_custom_rc\b|^[[:space:]]*static[[:space:]]+bool[[:space:]]+ksu_no_custom_rc\b' "$target"; then
echo "✅ ksu_no_custom_rc already declared in $target"
return 0
  fi

  local root_dir
  root_dir="$(dirname "$(dirname "$target")")"

  grep -q '#include <linux/types.h>' "$target" || sed -i '1i#include <linux/types.h>' "$target"

  if grep -RqsE '^[[:space:]]*bool[[:space:]]+ksu_no_custom_rc\b|^[[:space:]]*static[[:space:]]+bool[[:space:]]+ksu_no_custom_rc\b' "$root_dir" --include='*.c' --include='*.h' 2>/dev/null; then
sed -i '/#include <linux\/types.h>/a extern bool ksu_no_custom_rc;' "$target"
echo "✅ Added extern bool ksu_no_custom_rc to $target"
  else
sed -i '/#include <linux\/types.h>/a static bool ksu_no_custom_rc = false;' "$target"
echo "✅ Added local static bool ksu_no_custom_rc = false to $target"
  fi
}

fix_sukisu_selinux_hide_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU selinux_hide compatibility in: $target"

  sed -i \
-e 's/^static int security_context_to_sid_with_policy(/int security_context_to_sid_with_policy(/' \
-e 's/^static int security_sid_to_context_with_policy(/int security_sid_to_context_with_policy(/' \
-e 's/^static void security_compute_av_user_with_policy(/void security_compute_av_user_with_policy(/' \
-e 's/^static bool ksu_selinux_hide_running/bool ksu_selinux_hide_running/' \
"$target" || true

  perl -0pi -e 's/^[ \t]*static[ \t]+(const[ \t]+)?struct[ \t]+selinux_state[ \t]+fake_state([ \t]*[=;])/${1}struct selinux_state fake_state$2/mg' "$target" || true
  perl -0pi -e 's/^[ \t]*static[ \t]+(const[ \t]+)?struct[ \t]+selinux_state[ \t]+\*fake_state([ \t]*[=;])/${1}struct selinux_state *fake_state$2/mg' "$target" || true

  if grep -q "backup_sepolicy" "$target" && ! grep -q "struct selinux_policy \*backup_sepolicy" "$target"; then
awk '
  /^#include/ { print; last_include = NR; next }
  last_include && !inserted {
    print ""
    print "static struct selinux_policy *backup_sepolicy;"
    print ""
    inserted = 1
  }
  { print }
  END {
    if (!inserted) {
      print ""
      print "static struct selinux_policy *backup_sepolicy;"
    }
  }
' "$target" > "$target.tmp"
mv "$target.tmp" "$target"
  fi

  sed -i \
-e 's/![[:space:]]*ksu_late_loaded/1/g' \
-e 's/\bksu_late_loaded\b/0/g' \
"$target" || true

  perl -0pi -e 's/if[ \t]*\([ \t]*security_dump_masked_av_fn[ \t]*\)/if (\&security_dump_masked_av_fn)/g' "$target" || true
  perl -0pi -e 's/if[ \t]*\([ \t]*context_struct_compute_av_fn[ \t]*\)/if (\&context_struct_compute_av_fn)/g' "$target" || true

  if grep -n 'ksu_late_loaded' "$target"; then
echo "::error::ksu_late_loaded still remains in $target"
exit 1
  fi

  if grep -nE 'if[[:space:]]*\([[:space:]]*(security_dump_masked_av_fn|context_struct_compute_av_fn)[[:space:]]*\)' "$target"; then
echo "::error::Pointer-bool warning patterns still remain in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_app_profile_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU app_profile compatibility in: $target"

  python3 - "$target" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

patterns = [
    r'\n[ \t]*if[ \t]*\([ \t]*cred->euid\.val[ \t]*==[ \t]*0[ \t]*\)[ \t]*\{\n[ \t]*pr_warn\("Already root, don\'t escape!\\n"\);\n[ \t]*goto out_abort_creds;\n[ \t]*\}\n',
    r'\n[ \t]*if[ \t]*\([ \t]*uid_eq\([ \t]*cred->euid[ \t]*,[ \t]*GLOBAL_ROOT_UID[ \t]*\)[ \t]*\)[ \t]*\{\n[ \t]*pr_warn\("Already root, don\'t escape!\\n"\);\n[ \t]*goto out_abort_creds;\n[ \t]*\}\n',
]

for pattern in patterns:
    text = re.sub(pattern, "\n", text, flags=re.S)

lines = text.splitlines()
new_lines = []

for line in lines:
    if re.match(r"^[ \t]*disable_seccomp[ \t]*\(\);[ \t]*$", line):
        prev1 = new_lines[-1] if len(new_lines) >= 1 else ""
        prev2 = new_lines[-2] if len(new_lines) >= 2 else ""

        if "TIF_SECCOMP" in prev1 or "TIF_SECCOMP" in prev2:
            new_lines.append(line)
        else:
            indent = re.match(r"^([ \t]*)", line).group(1)
            new_lines.append(indent + "if (likely(test_thread_flag(TIF_SECCOMP)))")
            new_lines.append(indent + "    disable_seccomp();")
    else:
        new_lines.append(line)

text = "\n".join(new_lines) + ("\n" if text.endswith("\n") else "")

text = re.sub(
    r'\n[ \t]*for_each_thread[ \t]*\([ \t]*p[ \t]*,[ \t]*t[ \t]*\)[ \t]*\{\n[ \t]*ksu_set_task_tracepoint_flag[ \t]*\([ \t]*t[ \t]*\);[ \t]*\n[ \t]*\}\n',
    "\n",
    text,
    flags=re.S,
)

path.write_text(text)

PY

  if grep -n "Already root, don't escape" "$target"; then
echo "::error::Already-root early abort still remains in $target"
exit 1
  fi

  if awk '
/^[[:space:]]*disable_seccomp[[:space:]]*\(\);/ {
  if (prev !~ /TIF_SECCOMP/ && prev2 !~ /TIF_SECCOMP/) {
    print FNR ":" $0
    bad = 1
  }
}
{ prev2 = prev; prev = $0 }
END { exit bad ? 1 : 0 }
  ' "$target"; then
:
  else
echo "::error::Unguarded disable_seccomp() still remains in $target"
exit 1
  fi

  if grep -nE 'ksu_set_task_tracepoint_flag[[:space:]]*\(' "$target"; then
echo "::error::ksu_set_task_tracepoint_flag() still remains in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_dispatch_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU dispatch SUSFS compatibility in: $target"

  neutralize_ksu_late_loaded "$target"

  if ! grep -q '#include <linux/namei.h>' "$target"; then
if grep -q '#include <linux/thread_info.h>' "$target"; then
  sed -i '/#include <linux\/thread_info.h>/a #include <linux/namei.h>' "$target"
elif grep -q '^#include <linux/' "$target"; then
  sed -i '0,/^#include <linux\//s//#include <linux\/namei.h>\n&/' "$target"
else
  sed -i '1i#include <linux/namei.h>' "$target"
fi
  fi

  if ! grep -q '#include <linux/susfs.h>' "$target"; then
if grep -q '#include <linux/namei.h>' "$target"; then
  sed -i '/#include <linux\/namei.h>/a #include <linux/susfs.h>' "$target"
elif grep -q '#include <linux/thread_info.h>' "$target"; then
  sed -i '/#include <linux\/thread_info.h>/a #include <linux/susfs.h>' "$target"
elif grep -q '^#include <linux/' "$target"; then
  sed -i '0,/^#include <linux\//s//#include <linux\/susfs.h>\n&/' "$target"
else
  sed -i '1i#include <linux/susfs.h>' "$target"
fi
  fi

  if grep -qE 'SUSFS_MAGIC|CMD_SUSFS_|susfs_' "$target"; then
if ! grep -q '#include <linux/susfs.h>' "$target"; then
  echo "::error::SUSFS symbols are used but <linux/susfs.h> is missing in $target"
  exit 1
fi
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_sucompat_api() {
  local base="$1"
  [ -d "$base" ] || return 0

  local c="$base/feature/sucompat.c"
  local h="$base/feature/sucompat.h"

  echo "Fixing SukiSU sucompat API in: $base"

  [ -f "$c" ] || { echo "ℹ️ sucompat.c not found in $base, skipping"; return 0; }
  [ -f "$h" ] || { echo "ℹ️ sucompat.h not found in $base, skipping"; return 0; }

  grep -q '#include <linux/jump_label.h>' "$c" || sed -i '1i#include <linux/jump_label.h>' "$c"
  grep -q '#include <linux/version.h>' "$c" || sed -i '1i#include <linux/version.h>' "$c"
  grep -q '#include <linux/namei.h>' "$c" || sed -i '1i#include <linux/namei.h>' "$c"

  if grep -qE 'CONFIG_KSU_SUSFS|susfs_|SUSFS_' "$c"; then
grep -q '#include <linux/susfs_def.h>' "$c" || sed -i '1i#include <linux/susfs_def.h>' "$c"
  fi

  if ! grep -qE '#include "sucompat.h"|#include "feature/sucompat.h"' "$c"; then
sed -i '1i#include "sucompat.h"' "$c"
  fi

  if grep -qE '^[[:space:]]*bool[[:space:]]+ksu_su_compat_enabled[[:space:]]+__read_mostly[[:space:]]*=[[:space:]]*true[[:space:]]*;' "$c"; then
sed -i 's/^[[:space:]]*bool[[:space:]]\+ksu_su_compat_enabled[[:space:]]\+__read_mostly[[:space:]]*=[[:space:]]*true[[:space:]]*;/DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);/' "$c"
  elif grep -qE '^[[:space:]]*bool[[:space:]]+ksu_su_compat_enabled[[:space:]]*=[[:space:]]*true[[:space:]]*;' "$c"; then
sed -i 's/^[[:space:]]*bool[[:space:]]\+ksu_su_compat_enabled[[:space:]]*=[[:space:]]*true[[:space:]]*;/DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);/' "$c"
  fi

  if ! grep -qE 'DEFINE_STATIC_KEY_(TRUE|FALSE)\(ksu_su_compat_enabled\)' "$c"; then
if grep -q '#define SU_PATH' "$c"; then
  sed -i '/#define SU_PATH/i DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);' "$c"
else
  sed -i '1a DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);' "$c"
fi
  fi

  perl -0pi -e 's/\*value\s*=\s*ksu_su_compat_enabled\s*\?\s*1\s*:\s*0\s*;/if (static_key_enabled(\&ksu_su_compat_enabled))\n        *value = 1;\n    else\n        *value = 0;/g' "$c" || true
  perl -0pi -e 's/(?<![_a-zA-Z])ksu_su_compat_enabled\s*=\s*enable\s*;/if (enable)\n        static_branch_enable(\&ksu_su_compat_enabled);\n    else\n        static_branch_disable(\&ksu_su_compat_enabled);/g' "$c" || true
  perl -0pi -e 's/(if\s*\(\s*enable\s*\)\s*static_branch_enable\(\&ksu_su_compat_enabled\);\s*else\s*static_branch_disable\(\&ksu_su_compat_enabled\);\s*){2,}/$1/gs' "$c" || true

  grep -q '#include <linux/version.h>' "$h" || sed -i '1i#include <linux/version.h>' "$h"
  grep -q '#include <linux/fs.h>' "$h" || sed -i '1i#include <linux/fs.h>' "$h"
  grep -q '#include <linux/jump_label.h>' "$h" || sed -i '1i#include <linux/jump_label.h>' "$h"

  sed -i 's/^extern bool ksu_su_compat_enabled;/extern struct static_key_true ksu_su_compat_enabled;/' "$h" || true

  if ! grep -qE 'extern[[:space:]]+struct[[:space:]]+static_key_(true|false)[[:space:]]+ksu_su_compat_enabled[[:space:]]*;' "$h"; then
if grep -q 'void ksu_sucompat_init' "$h"; then
  sed -i '/void ksu_sucompat_init/i extern struct static_key_true ksu_su_compat_enabled;' "$h"
else
  sed -i '1a extern struct static_key_true ksu_su_compat_enabled;' "$h"
fi
  fi

  if grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_faccessat_sucompat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_faccessat_sucompat' "$h"; then
echo 'long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs);' >> "$h"
  fi

  if grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_stat_sucompat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_stat_sucompat' "$h"; then
echo 'long ksu_handle_stat_sucompat(int orig_nr, struct pt_regs *regs);' >> "$h"
  fi

  if grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_faccessat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_faccessat(int \*dfd' "$h"; then
echo 'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);' >> "$h"
  fi

  if grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_stat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_stat(int \*dfd' "$h"; then
if grep -qE 'ksu_handle_stat[[:space:]]*\([[:space:]]*int[[:space:]]+\*dfd,[[:space:]]*struct filename[[:space:]]+\*\*' "$c"; then
  cat >> "$h" <<'HEOF'

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) && defined(CONFIG_KSU_SUSFS)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#endif
HEOF
else
  echo 'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);' >> "$h"
fi
  fi

  sed -i 's/long ksu_handle_execve_sucompat(const char __user \*\*filename_user, int orig_nr, struct pt_regs \*regs);/long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs);/' "$h" || true

  # ---------------------------------------------------------------------------
  # Fix SukiSU v4.1.x sulog API mismatch.
  #
  # Newer SukiSU declares:
  #   ksu_sulog_capture_sucompat(..., struct user_arg_ptr *argv_user, ...)
  #
  # Some SUSFS/SukiSU compatibility patches leave older code like:
  #   const char __user *const __user *argv_user = ...
  #   ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL);
  #
  # That fails with:
  #   incompatible pointer types passing 'const char __user *const __user *'
  #   to parameter of type 'struct user_arg_ptr *'
  #
  # Wrap the raw native argv pointer into struct user_arg_ptr.
  # ---------------------------------------------------------------------------

  # Hard fallback before sucompat argv_user fixer.
  perl -0pi -e 's/ksu_sulog_capture_sucompat\s*\(\s*\*filename_user\s*,\s*argv_user\s*,\s*GFP_KERNEL\s*\)/ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL)/g' "$c"

  if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user, GFP_KERNEL)' "$c"; then
echo "  Fixing ksu_sulog_capture_sucompat argv_user type in: $c"

python3 - "$c" <<'PY'
from pathlib import Path
import re
import sys

if len(sys.argv) < 2:
    print("::error::Missing target file argument")
    sys.exit(1)

p = Path(sys.argv[1])

if not p.exists():
    print(f"::error::Target file does not exist: {p}")
    sys.exit(1)

s = p.read_text()

if "#include <linux/errno.h>" not in s:
    s = "#include <linux/errno.h>\n" + s

if "#include <linux/fs.h>" not in s:
    s = "#include <linux/fs.h>\n" + s

if "#include <linux/binfmts.h>" not in s:
    s = "#include <linux/binfmts.h>\n" + s

s = re.sub(
    r"return\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;",
    "return -ENOSYS;",
    s,
    flags=re.S,
)

p.write_text(s)

PY
  fi

  if ! grep -qE 'DEFINE_STATIC_KEY_(TRUE|FALSE)\(ksu_su_compat_enabled\)' "$c"; then
echo "::error::ksu_su_compat_enabled static_key definition missing in $c"
exit 1
  fi

  if grep -q 'extern bool ksu_su_compat_enabled' "$h"; then
echo "::error::Old bool declaration remains in $h"
exit 1
  fi

  # Hard fallback for older SukiSU execve sucompat handler shape.
  # This handles:
  #   ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL)
  perl -0pi -e 's/ksu_sulog_capture_sucompat\s*\(\s*\*filename_user\s*,\s*argv_user\s*,\s*GFP_KERNEL\s*\)/ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL)/g' "$c"

  if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user, GFP_KERNEL)' "$c"; then
echo "::error::Old incompatible ksu_sulog_capture_sucompat argv_user call remains in $c"
grep -n 'ksu_sulog_capture_sucompat' "$c" || true
exit 1
  fi

  if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, &argv_arg_ptr, GFP_KERNEL)' "$c"; then
if ! grep -q 'struct user_arg_ptr argv_arg_ptr;' "$c"; then
  echo "::error::argv_arg_ptr is used but not declared in $c"
  grep -nE 'argv_arg_ptr|ksu_sulog_capture_sucompat' "$c" || true
  exit 1
fi

if ! grep -q '#include <linux/binfmts.h>' "$c"; then
  echo "::error::struct user_arg_ptr compatibility include is missing in $c"
  grep -nE 'linux/binfmts.h|argv_arg_ptr|ksu_sulog_capture_sucompat' "$c" || true
  exit 1
fi

if grep -q 'argv_arg_ptr.is_compat = false;' "$c" && \
   ! grep -q '#ifdef CONFIG_COMPAT' "$c"; then
  echo "::error::argv_arg_ptr.is_compat is unguarded by CONFIG_COMPAT in $c"
  grep -nE 'CONFIG_COMPAT|argv_arg_ptr|ksu_sulog_capture_sucompat' "$c" || true
  exit 1
fi
  fi

  if ! grep -qE 'ksu_handle_faccessat_sucompat|ksu_handle_faccessat[[:space:]]*\(' "$c"; then
echo "::error::No faccessat sucompat handler found in $c"
exit 1
  fi

  if ! grep -qE 'ksu_handle_stat_sucompat|ksu_handle_stat[[:space:]]*\(' "$c"; then
echo "::error::No stat sucompat handler found in $c"
exit 1
  fi

  # Cleanup: silence harmless unused argv_user warning in sucompat.c.
  # Some SukiSU/SUSFS compatibility paths keep argv_user for ABI/logging compatibility.
  # Use a guarded path because this function may run with set -u before sucompat_c exists.
  local _sucompat_cleanup_c="${sucompat_c:-$base/feature/sucompat.c}"
  if [ -f "$_sucompat_cleanup_c" ]; then
    perl -0pi -e 's/(const\s+char\s+__user\s+\*const\s+__user\s+\*argv_user\s*=\s*\(const\s+char\s+__user\s+\*const\s+__user\s+\*\)PT_REGS_PARM2\(regs\);\n)(?!\s*\(void\)argv_user;)/$1    (void)argv_user;\n/g' "$_sucompat_cleanup_c" 2>/dev/null || true
  fi

  echo "✅ sucompat API fixed in: $base"
}


fix_sukisu_forced_execveat_link_symbols() {
  local base="$1"
  [ -d "$base" ] || return 0

  local sucompat_c="$base/feature/sucompat.c"
  local sucompat_h="$base/feature/sucompat.h"
  local ksud_integration_c="$base/runtime/ksud_integration.c"

  echo "Force-fixing SukiSU execveat/link symbols in: $base"
  # Hard fallback: fix wrong ksu_handle_execveat_init stub signature in ksud_integration.c.
  # Some compatibility paths accidentally create:
  #   void ksu_handle_execveat_init(void)
  # but the SukiSU execveat flow expects:
  #   int ksu_handle_execveat_init(struct filename *, struct user_arg_ptr *, struct user_arg_ptr *)
  python3 - "$ksud_integration_c" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

good_sig = "int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)"

good_body = """int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    /*
     * Compatibility stub for SukiSU/SUSFS execveat integration.
     * Real sucompat handling may live in kernel/feature/sucompat.c on some trees.
     */
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
"""

# Replace the known bad stub:
#   void ksu_handle_execveat_init(void) { ... }
s = re.sub(
    r'void\s+ksu_handle_execveat_init\s*\(\s*void\s*\)\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}',
    good_body,
    s,
    flags=re.S,
)

# If no compatible body exists, append one.
if good_sig not in s:
    s = s.rstrip() + "\n\n" + good_body + "\n"

p.write_text(s)
PY


  if [ -f "$sucompat_c" ]; then
grep -q '#include <linux/errno.h>' "$sucompat_c" || sed -i '1i#include <linux/errno.h>' "$sucompat_c"
grep -q '#include <linux/fs.h>' "$sucompat_c" || sed -i '1i#include <linux/fs.h>' "$sucompat_c"
grep -q '#include <linux/binfmts.h>' "$sucompat_c" || sed -i '1i#include <linux/binfmts.h>' "$sucompat_c"

# Hard fallback: remove old direct ksu_syscall_table calls from sucompat.c.
perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c"

if grep -q 'ksu_syscall_table' "$sucompat_c"; then
  python3 - "$sucompat_c" <<'PY2'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = re.sub(
r'\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;',
'ret = 0;',
s,
flags=re.S,
)

s = re.sub(
r'return\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;',
'return -ENOSYS;',
s,
flags=re.S,
)

p.write_text(s)
PY2
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_c" <<'CEOF'

/*
 * SukiSU/SUSFS compatibility shim.
 *
 * Some SUSFS patchsets expect KernelSU-style execveat hooks, while newer
 * SukiSU Ultra trees may not expose these exact symbols. Returning 0 keeps
 * the normal kernel execveat path unchanged.
 */
int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                    struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                    int *flags)
{
return 0;
}
CEOF
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_c" <<'CEOF'

int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                             struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                             int *flags)
{
return 0;
}
CEOF
fi
  fi

  if [ -f "$sucompat_h" ]; then
grep -q '#include <linux/binfmts.h>' "$sucompat_h" || sed -i '1i#include <linux/binfmts.h>' "$sucompat_h"
grep -q '#include <linux/fs.h>' "$sucompat_h" || sed -i '1i#include <linux/fs.h>' "$sucompat_h"

# Only add the shim prototype when sucompat.c does NOT already define the function.
# SUSFS v2.2.0 defines ksu_handle_execveat*() in sucompat.c with `void *argv, void *envp`,
# and these are called only internally (no external caller needs a header prototype).
# Adding our `struct user_arg_ptr *` prototype here would conflict with that definition.
if ! grep -q 'ksu_handle_execveat(int \*fd' "$sucompat_h" \
   && ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_h" <<'HEOF'

int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                    struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                    int *flags);
HEOF
fi

if ! grep -q 'ksu_handle_execveat_sucompat(int \*fd' "$sucompat_h" \
   && ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_h" <<'HEOF'

int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                             struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                             int *flags);
HEOF
fi
  fi

  if [ -f "$ksud_integration_c" ]; then
if grep -q 'ksu_handle_execveat_init[[:space:]]*(' "$ksud_integration_c"; then
  # Skip the stub if ksu_handle_execveat_init() is already DEFINED anywhere in the tree.
  # SUSFS v2.2.0 defines it in feature/sucompat.c, so a second body here would be a
  # duplicate-symbol link error. (ksud_integration.c only carries an extern decl on v2.2.0.)
  if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' "$ksud_integration_c" \
     && ! grep -RqsE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' "$base" --include='*.c'; then
    cat >> "$ksud_integration_c" <<'CEOF'

/*
 * SukiSU/SUSFS compatibility shim.
 *
 * Some SUSFS patchsets expect ksu_handle_execveat_init(), while this SukiSU
 * Ultra tree may only declare or call it. Provide the missing body.
 */
int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
CEOF
  fi
fi
  fi

  # Final local cleanup after Python rewrite.
  perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c" 2>/dev/null || true

  if [ -f "$sucompat_c" ]; then
  # Hard fallback before validation: remove old direct ksu_syscall_table calls from sucompat.c.
  perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c"

if grep -q 'ksu_syscall_table' "$sucompat_c"; then
  echo "::error::ksu_syscall_table reference still remains in $sucompat_c"
  grep -n 'ksu_syscall_table' "$sucompat_c" || true
  exit 1
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
  echo "::error::ksu_handle_execveat implementation missing in $sucompat_c"
  exit 1
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
  echo "::error::ksu_handle_execveat_sucompat implementation missing in $sucompat_c"
  exit 1
fi
  fi

  # Hard fallback before execveat_init validation: normalize bad void stub to int stub.
  if [ -f "$ksud_integration_c" ]; then
    python3 - "$ksud_integration_c" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

good_sig = "int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)"
good_body = """int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
"""

s = re.sub(
    r'void\s+ksu_handle_execveat_init\s*\(\s*void\s*\)\s*\{[^{}]*\}',
    good_body,
    s,
    flags=re.S,
)

if "ksu_handle_execveat_init(" in s and good_sig not in s:
    s = s.rstrip() + "\n\n" + good_body + "\n"

p.write_text(s)
PY
  fi

  if [ -f "$ksud_integration_c" ] && grep -q 'ksu_handle_execveat_init[[:space:]]*(' "$ksud_integration_c"; then
# The definition may live in ksud_integration.c (older trees) OR feature/sucompat.c
# (SUSFS v2.2.0). Accept either — only fail if it's defined nowhere in the tree.
if ! grep -RqsE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' "$base" --include='*.c'; then
  echo "::error::ksu_handle_execveat_init referenced but no definition found under $base"
  grep -rn 'ksu_handle_execveat_init' "$base" --include='*.c' || true
  exit 1
fi
  fi

  echo "✅ forced execveat/link symbol compatibility fixed in: $base"
}


fix_sukisu_syscall_event_bridge() {
  local target="$1"
  [ -f "$target" ] || return 0

  local base
  base="$(dirname "$(dirname "$target")")"
  local sucompat_c="$base/feature/sucompat.c"

  echo "Fixing syscall_event_bridge sucompat API in: $target"

  grep -q '#include <linux/jump_label.h>' "$target" || sed -i '1i#include <linux/jump_label.h>' "$target"

  sed -i \
-e 's/if[[:space:]]*([[:space:]]*!ksu_su_compat_enabled[[:space:]]*)/if (!static_key_enabled(\&ksu_su_compat_enabled))/g' \
-e 's/else[[:space:]]*if[[:space:]]*([[:space:]]*ksu_su_compat_enabled[[:space:]]*)/else if (static_key_enabled(\&ksu_su_compat_enabled))/g' \
"$target" || true

  perl -0pi -e 's/ksu_handle_execve_sucompat\(([^,]+),\s*orig_nr,\s*\(struct\s+pt_regs\s*\*\)\s*regs\)/ksu_handle_execve_sucompat($1, orig_nr, regs)/g' "$target" || true

  # SUSFS v2.2.0: the enable patch changes the setuid handler definition from the old
  # 2-arg  ksu_handle_setresuid(old_uid, new_uid)
  # to the 3-arg ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)
  # (only the first arg, ruid, is actually consumed; the handler gates on the zygote SID).
  # SukiSU's tracepoint bridge still emits the OLD 2-arg call, which no longer compiles.
  # Rewrite the bridge call to the 3-arg form using the post-syscall creds. Guarded on the
  # 3-arg definition actually being present, so this stays a no-op on SUSFS v2.1.0.
  if grep -RqsE 'int[[:space:]]+ksu_handle_setresuid[[:space:]]*\([^)]*\beuid\b[^)]*\bsuid\b' \
       "$(dirname "$(dirname "$target")")" --include='*.c'; then
    echo "  setresuid: migrating bridge call to 3-arg v2.2.0 signature"
    perl -0pi -e 's/ksu_handle_setresuid\s*\(\s*old_uid\s*,\s*current_uid\(\)\.val\s*\)/ksu_handle_setresuid(current_uid().val, current_euid().val, current_uid().val)/g' "$target" || true
    # The pre-syscall old_uid local is now unused; keep it but silence -Wunused.
    perl -0pi -e 's/\buid_t\s+old_uid\s*=\s*current_uid\(\)\.val;/uid_t old_uid __maybe_unused = current_uid().val;/g' "$target" || true

    if grep -qE 'ksu_handle_setresuid\s*\(\s*old_uid\s*,' "$target"; then
      echo "::error::Old 2-arg ksu_handle_setresuid bridge call remains in $target"
      grep -n 'ksu_handle_setresuid' "$target" || true
      exit 1
    fi
  fi

  [ -f "$sucompat_c" ] || {
echo "ℹ️ sucompat.c not found for bridge base $base, skipping API migration"
return 0
  }

  local has_old_stat=false
  local has_old_faccess=false
  local has_new_stat_user=false
  local has_new_stat_filename=false
  local has_new_faccess=false

  grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_stat_sucompat[[:space:]]*\(' "$sucompat_c" && has_old_stat=true
  grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_faccessat_sucompat[[:space:]]*\(' "$sucompat_c" && has_old_faccess=true
  grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_faccessat[[:space:]]*\(' "$sucompat_c" && has_new_faccess=true

  if grep -qE 'ksu_handle_stat[[:space:]]*\([[:space:]]*int[[:space:]]+\*dfd,[[:space:]]*struct filename[[:space:]]+\*\*' "$sucompat_c"; then
has_new_stat_filename=true
  elif grep -qE 'ksu_handle_stat[[:space:]]*\([[:space:]]*int[[:space:]]+\*dfd,[[:space:]]*const char __user[[:space:]]+\*\*' "$sucompat_c"; then
has_new_stat_user=true
  fi

  if grep -q 'ksu_handle_stat_sucompat' "$target"; then
if [ "$has_old_stat" = true ]; then
  echo "  stat: keeping old ksu_handle_stat_sucompat bridge call"
elif [ "$has_new_stat_user" = true ]; then
  perl -0pi -e 's{return\s+ksu_handle_stat_sucompat\s*\(\s*orig_nr\s*,\s*\(struct\s+pt_regs\s*\*\)\s*regs\s*\)\s*;}{dfd = (int *)\&PT_REGS_PARM1(regs);\n    filename_user = (const char __user **)\&PT_REGS_PARM2(regs);\n    flags = (int *)\&PT_REGS_SYSCALL_PARM4(regs);\n    ksu_handle_stat(dfd, filename_user, flags);\n    return ksu_syscall_table[orig_nr](regs);}gx' "$target" || true
elif [ "$has_new_stat_filename" = true ]; then
  echo "::warning::  stat: only struct filename** ksu_handle_stat exists; preserving bridge"
fi
  fi

  if grep -q 'ksu_handle_faccessat_sucompat' "$target"; then
if [ "$has_old_faccess" = true ]; then
  echo "  faccessat: keeping old ksu_handle_faccessat_sucompat bridge call"
elif [ "$has_new_faccess" = true ]; then
  perl -0pi -e 's{return\s+ksu_handle_faccessat_sucompat\s*\(\s*orig_nr\s*,\s*\(struct\s+pt_regs\s*\*\)\s*regs\s*\)\s*;}{dfd = (int *)\&PT_REGS_PARM1(regs);\n    filename_user = (const char __user **)\&PT_REGS_PARM2(regs);\n    mode = (int *)\&PT_REGS_PARM3(regs);\n    ksu_handle_faccessat(dfd, filename_user, mode, NULL);\n    return ksu_syscall_table[orig_nr](regs);}gx' "$target" || true
fi
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_linker_symbols() {
  echo "Applying SukiSU linker-symbol compatibility cleanup..."

  for kbuild in \
"$KSU_FOLDER/kernel/Kbuild" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild"; do
if [ -f "$kbuild" ]; then
  if [ -f "$(dirname "$kbuild")/infra/symbol_resolver.c" ] && ! grep -q 'infra/symbol_resolver\.o' "$kbuild"; then
    echo 'kernelsu-objs += infra/symbol_resolver.o' >> "$kbuild"
  fi
  if [ -f "$(dirname "$kbuild")/hook/arm64/patch_memory.c" ] && ! grep -q 'hook/arm64/patch_memory\.o' "$kbuild"; then
    echo 'kernelsu-objs += hook/arm64/patch_memory.o' >> "$kbuild"
  fi
fi
  done

  for target in \
"$KSU_FOLDER/kernel/core/init.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/core/init.c"; do
if [ -f "$target" ]; then
  perl -0pi -e 's/^[ \t]*ksu_init_symbol_resolver[ \t]*\([^;]*\);[ \t]*\n//mg' "$target" || true
  sed -i '/ksu_init_symbol_resolver[[:space:]]*(/d' "$target" || true
  perl -0pi -e 's/^[ \t]*ksu_spoof_version[ \t]*\([^;]*\);[ \t]*\n//mg' "$target" || true
  sed -i '/ksu_spoof_version[[:space:]]*(/d' "$target" || true
fi
  done

  for kbuild in \
"$KSU_FOLDER/kernel/Makefile" \
"$KSU_FOLDER/kernel/Kbuild" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/Makefile" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild"; do
[ -f "$kbuild" ] && sed -i -e '/uts_spoof\.o/d' -e '/feature\/uts_spoof\.o/d' "$kbuild" || true
  done

  for target in \
"$KSU_FOLDER/kernel/supercall/dispatch.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/supercall/dispatch.c"; do
if [ -f "$target" ]; then
  perl -0pi -e 's/return[ \t]+ksu_set_spoof_version[ \t]*\([^;]*\);/return -EINVAL;/g' "$target" || true
  perl -0pi -e 's/^[ \t]*ksu_set_spoof_version[ \t]*\([^;]*\);[ \t]*$/return -EINVAL;/mg' "$target" || true
fi
  done

  for target in \
"$KSU_FOLDER/kernel/feature/selinux_hide.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"; do
if [ -f "$target" ]; then
  perl -0pi -e 's/\bret[ \t]*=[ \t]*ksu_patch_text[ \t]*\([^;]*\);/ret = 0;/g' "$target" || true
  perl -0pi -e 's/^[ \t]*ksu_patch_text[ \t]*\([^;]*\);[ \t]*\n//mg' "$target" || true
  sed -i '/^[[:space:]]*ksu_patch_text[[:space:]]*(.*);[[:space:]]*$/d' "$target" || true
  sed -i '/new_fn[[:space:]]*=[[:space:]]*my_sel_open_handle_status/d' "$target" || true
  sed -i '/^[[:space:]]*struct[[:space:]]\+selinux_policy[[:space:]]\+\*new_policy[[:space:]]*=/d' "$target" || true
  sed -i '/^[[:space:]]*struct[[:space:]]\+selinux_state[[:space:]]\+\*new_state[[:space:]]*=/d' "$target" || true
fi
  done

  for target in \
"$KSU_FOLDER/kernel/feature/uts_spoof.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/uts_spoof.c"; do
[ -f "$target" ] && mv "$target" "$target.disabled" || true
  done

  echo "✅ SukiSU linker-symbol compatibility cleanup completed"
}

# =============================================================================
# Patch KernelSU tree
# =============================================================================

cd "$KSU_FOLDER"

patch -p1 --forward < "$SUSFS_FOLDER/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true

EXPECTED_SUKISU_REJECTS=(
  "kernel/core/init.c.rej"
  "kernel/feature/selinux_hide.c.rej"
  "kernel/runtime/boot_event.c.rej"
  "kernel/supercall/dispatch.c.rej"
  "kernel/policy/app_profile.c.rej"
  "kernel/hook/syscall_event_bridge.c.rej"
  "kernel/feature/sucompat.c.rej"
  "kernel/feature/sucompat.h.rej"
)

if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
  echo "KernelSU patch produced reject files:"
  find . -name '*.rej' -exec echo "=== {} ===" \; -exec cat {} \;

  for rej in "${EXPECTED_SUKISU_REJECTS[@]}"; do
if [ -f "$rej" ]; then
  echo "Removing expected SukiSU/SUSFS reject: $rej"
  rm -f "$rej"
fi
  done
fi

# ---------------------------------------------------------------------------
# SukiSU commit skew (Kconfig/Kbuild).
#
# The susfs4ksu enable-patch (10_enable_susfs_for_ksu.patch) is regenerated
# against a newer SukiSU tree that already carries CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER.
# Its Kconfig/Kbuild hunks use that config's stanza as their anchor, so they
# REJECT on SukiSU commits that predate it (e.g. the current pinned KSU driver):
#   - kernel/Kbuild.rej  : hunk only DELETES the X86-dispatcher ccflags block,
#                          which is absent here -> nothing to apply, drop it.
#   - kernel/Kconfig.rej : hunk ADDS the whole 'menu "KernelSU - SUSFS"' block.
#                          If we don't re-inject it, none of the CONFIG_KSU_SUSFS*
#                          symbols exist and SUSFS is SILENTLY COMPILED OUT.
# Recover both idempotently (same philosophy as the mm/memory.c reject below).
# ---------------------------------------------------------------------------
if [ -f kernel/Kconfig.rej ]; then
  if ! grep -q 'menu "KernelSU - SUSFS"' kernel/Kconfig; then
    echo "Re-injecting SUSFS Kconfig menu (enable-patch hunk rejected on this SukiSU commit)"
    # Reconstruct the added block from the reject: keep '+' (added) and ' ' (context)
    # lines between '+menu "KernelSU - SUSFS"' and the closing '+endmenu', drop '-' lines.
    awk '
      /^\+menu "KernelSU - SUSFS"/ { f = 1 }
      f {
        if (/^-/) next
        line = $0
        sub(/^[+ ]/, "", line)
        print line
        if ($0 ~ /^\+endmenu/) exit
      }
    ' kernel/Kconfig.rej > kernel/.susfs_menu.kconfig

    if ! grep -q 'config KSU_SUSFS' kernel/.susfs_menu.kconfig; then
      echo "::error::Could not extract SUSFS menu block from kernel/Kconfig.rej"
      cat kernel/Kconfig.rej
      exit 1
    fi

    # Splice the block in immediately before the KernelSU menu's closing endmenu.
    awk '
      FNR == NR { blk = blk $0 ORS; next }
      /^endmenu[[:space:]]*$/ && !done { printf "%s", blk; done = 1 }
      { print }
    ' kernel/.susfs_menu.kconfig kernel/Kconfig > kernel/Kconfig.tmp
    mv kernel/Kconfig.tmp kernel/Kconfig
    rm -f kernel/.susfs_menu.kconfig

    if ! grep -q 'config KSU_SUSFS' kernel/Kconfig; then
      echo "::error::Failed to inject SUSFS menu into kernel/Kconfig"
      exit 1
    fi
  fi
  rm -f kernel/Kconfig.rej
fi

if [ -f kernel/Kbuild.rej ]; then
  # Only rejected hunk deletes the CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER ccflags
  # block; apply that deletion if the block happens to be present, else it's a no-op.
  if grep -q 'CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER' kernel/Kbuild; then
    sed -i '/ifeq (\$(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER),y)/,/^endif/d' kernel/Kbuild
  fi
  rm -f kernel/Kbuild.rej
fi

if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
  echo "::error::Unexpected KernelSU-side .rej files remain:"
  find . -name '*.rej' -exec echo "=== {} ===" \; -exec cat {} \;
  exit 1
fi

fix_sukisu_init_c               "kernel/core/init.c"
ensure_susfs_init_call          "kernel/core/init.c"
ensure_sukisu_inline_hook_init  "kernel/core/init.c"
fix_sukisu_boot_event_c         "kernel/runtime/boot_event.c"
fix_sukisu_ksud_integration_c   "kernel/runtime/ksud_integration.c"
fix_sukisu_selinux_hide_c       "kernel/feature/selinux_hide.c"
fix_sukisu_app_profile_c        "kernel/policy/app_profile.c"
fix_sukisu_dispatch_c           "kernel/supercall/dispatch.c"
fix_sukisu_sucompat_api         "kernel"
fix_sukisu_forced_execveat_link_symbols "kernel"
fix_sukisu_syscall_event_bridge "kernel/hook/syscall_event_bridge.c"
fix_sukisu_linker_symbols

# =============================================================================
# Patch common/drivers/kernelsu mirror
# =============================================================================

cd "$COMMON_KERNEL_FOLDER"

echo "Applying SukiSU compatibility fixes..."

sed -i '/DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex)/d' drivers/kernelsu/kpm/super_access.c 2>/dev/null || true

if [ -f drivers/kernelsu/hook/lsm_hook.c ]; then
  sed -i \
's/security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");/security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), \&ksu_lsmid);/' \
drivers/kernelsu/hook/lsm_hook.c || true

  grep -q "static struct lsm_id ksu_lsmid" drivers/kernelsu/hook/lsm_hook.c || \
sed -i '/security_add_hooks.*ksu_lsmid/i\    static struct lsm_id ksu_lsmid = { .name = "ksu", .id = LSM_ID_UNDEF };' \
drivers/kernelsu/hook/lsm_hook.c || true
fi

sed -i 's/is_zygote_normal_app_uid(new_uid)/is_appuid(new_uid)/' drivers/kernelsu/hook/setuid_hook.c 2>/dev/null || true
# Only stub out ksu_handle_extra_susfs_work() when susfs_extra_works is NOT provided by the
# SUSFS source (SUSFS v2.1.0). On v2.2.0 the symbol exists in fs/susfs.c and drives the
# deferred umount/hide work, so it MUST stay enabled.
if ! grep -RqsE '\bsusfs_extra_works\b' "$COMMON_KERNEL_FOLDER/fs/susfs.c" 2>/dev/null; then
  sed -i 's/ksu_handle_extra_susfs_work();/\/\/ ksu_handle_extra_susfs_work();/' drivers/kernelsu/hook/setuid_hook.c 2>/dev/null || true
else
  echo "SUSFS v2.2.0: keeping ksu_handle_extra_susfs_work() enabled (susfs_extra_works present)"
fi

if [ -f drivers/kernelsu/core/init.c ]; then
  grep -q "feature/sucompat.h" drivers/kernelsu/core/init.c 2>/dev/null || \
sed -i '/#include "ksu.h"/a #include "feature/sucompat.h"' drivers/kernelsu/core/init.c 2>/dev/null || true

  grep -q "hook/setuid_hook.h" drivers/kernelsu/core/init.c 2>/dev/null || \
sed -i '/#include "ksu.h"/a #include "hook/setuid_hook.h"' drivers/kernelsu/core/init.c 2>/dev/null || true
fi

fix_sukisu_init_c               "drivers/kernelsu/core/init.c"
ensure_susfs_init_call          "drivers/kernelsu/core/init.c"
ensure_sukisu_inline_hook_init  "drivers/kernelsu/core/init.c"
fix_sukisu_boot_event_c         "drivers/kernelsu/runtime/boot_event.c"
fix_sukisu_ksud_integration_c   "drivers/kernelsu/runtime/ksud_integration.c"
fix_sukisu_selinux_hide_c       "drivers/kernelsu/feature/selinux_hide.c"
fix_sukisu_app_profile_c        "drivers/kernelsu/policy/app_profile.c"
fix_sukisu_dispatch_c           "drivers/kernelsu/supercall/dispatch.c"
fix_sukisu_sucompat_api         "drivers/kernelsu"
fix_sukisu_forced_execveat_link_symbols "drivers/kernelsu"
fix_sukisu_syscall_event_bridge "drivers/kernelsu/hook/syscall_event_bridge.c"
fix_sukisu_linker_symbols

mkdir -p drivers/kernelsu/kpm/uapi include/uapi

cp "$KERNEL_PLATFORM_FOLDER/KernelSU/uapi/"*.h drivers/kernelsu/kpm/uapi/ 2>/dev/null || true
cp "$KERNEL_PLATFORM_FOLDER/KernelSU/uapi/"*.h include/uapi/ 2>/dev/null || true

KLOG_SRC="$(find "$KERNEL_PLATFORM_FOLDER/KernelSU" -name "klog.h" -type f 2>/dev/null | head -n 1 || true)"

if [ -n "$KLOG_SRC" ]; then
  for dest in drivers/kernelsu drivers/kernelsu/core drivers/kernelsu/feature drivers/kernelsu/hook drivers/kernelsu/selinux drivers/kernelsu/sulog; do
mkdir -p "$dest"
cp "$KLOG_SRC" "$dest/" 2>/dev/null || true
  done
fi

if [ -f drivers/kernelsu/Kbuild ]; then
  grep -q 'srctree)/$(src)' drivers/kernelsu/Kbuild || \
sed -i '1i\ccflags-y += -I$(srctree)/$(src)' drivers/kernelsu/Kbuild

  grep -q "kpm/uapi" drivers/kernelsu/Kbuild || \
sed -i '/^obj-\$(CONFIG_KPM) += kpm\/compact.o/i\ccflags-\$(CONFIG_KPM) += -I$(srctree)/$(src)/kpm/uapi -I$(srctree)/include/uapi' drivers/kernelsu/Kbuild

  # --- android16-6.12 / 6.13 GKI include fix ---
  # Kbuild changed $(src) semantics on 6.12/6.13, so the manager's own
  # -I$(KSU_KERNEL_DIR)/include (KSU_KERNEL_DIR = $(srctree)/$(src)) fails to resolve
  # for the symlinked drivers/kernelsu → 'util.h' (drivers/kernelsu/include/util.h) not
  # found compiling su_mount_ns.c / sucompat.c / supercall.c. Anchor an include on the
  # Kbuild's own absolute directory ($(MDIR) = $(dir $(abspath $(lastword ...)))), which
  # is immune to the $(src) breakage. Builds fine on older kernels too (additive -I).
  if ! grep -q 'susfs-fix-abs-include' drivers/kernelsu/Kbuild; then
if grep -qE '^MDIR := \$\(dir \$\(abspath' drivers/kernelsu/Kbuild; then
  sed -i '/^MDIR := \$(dir \$(abspath/a ccflags-y += -I$(MDIR) -I$(MDIR)include # susfs-fix-abs-include' drivers/kernelsu/Kbuild
else
  printf '\nKSU_ABS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))\nccflags-y += -I$(KSU_ABS_DIR) -I$(KSU_ABS_DIR)include # susfs-fix-abs-include\n' >> drivers/kernelsu/Kbuild
fi
echo "Applied MDIR-based KSU include-path fix (6.12+) to drivers/kernelsu/Kbuild"
  fi
fi

ARCH_H="$(find "$KERNEL_PLATFORM_FOLDER/KernelSU" -name "arch.h" -type f 2>/dev/null | head -n 1 || true)"

if [ -n "$ARCH_H" ]; then
  for dest in feature hook infra selinux supercall core runtime; do
if [ -d "drivers/kernelsu/$dest" ]; then
  cp "$ARCH_H" "drivers/kernelsu/$dest/" 2>/dev/null || true
fi
  done
fi

KSU_CRED_DEF='extern struct cred *ksu_cred;'

while IFS= read -r f; do
  grep -qF "$KSU_CRED_DEF" "$f" || sed -i "1i\\$KSU_CRED_DEF" "$f"
done < <(grep -rl "ksu_cred" drivers/kernelsu/ --include="*.c" 2>/dev/null || true)

if grep -q "allow_shell" drivers/kernelsu/policy/allowlist.c 2>/dev/null; then
  if ! grep -q "extern bool allow_shell" drivers/kernelsu/policy/allowlist.c; then
sed -i '1i\#include <linux/types.h>\nextern bool allow_shell;' drivers/kernelsu/policy/allowlist.c
  fi
fi

if grep -q "KERNEL_SU_VERSION" drivers/kernelsu/supercall/dispatch.c 2>/dev/null; then
  grep -q "#define KERNEL_SU_VERSION" drivers/kernelsu/supercall/dispatch.c || \
sed -i "1i\\#ifndef KERNEL_SU_VERSION\n#define KERNEL_SU_VERSION ${KSUVER:-40787}\n#endif" drivers/kernelsu/supercall/dispatch.c
fi

if [ -f drivers/kernelsu/runtime/ksud.c ]; then
  grep -q "ksu_init_rc_hook_key_false" drivers/kernelsu/runtime/ksud.c || \
sed -i '1i\#include <linux/jump_label.h>\nDEFINE_STATIC_KEY_FALSE(ksu_init_rc_hook_key_false);\nDEFINE_STATIC_KEY_FALSE(ksu_input_hook_key_false);' drivers/kernelsu/runtime/ksud.c
fi

sed -i 's/extern struct static_key_true ksu_is_init_rc_hook_enabled;/DEFINE_STATIC_KEY_FALSE(ksu_is_init_rc_hook_enabled);/' fs/stat.c 2>/dev/null || true
sed -i 's/extern struct static_key_true ksu_is_input_hook_enabled;/DEFINE_STATIC_KEY_FALSE(ksu_is_input_hook_enabled);/' drivers/input/input.c 2>/dev/null || true

if [ -f fs/read_write.c ]; then
  grep -q "DEFINE_STATIC_KEY_FALSE.*ksu_is_init_rc_hook_enabled" fs/read_write.c || \
sed -i 's/DEFINE_STATIC_KEY_FALSE(ksu_is_init_rc_hook_enabled);/extern struct static_key_true ksu_is_init_rc_hook_enabled;/' fs/read_write.c 2>/dev/null || true
fi

if [ "$ANDROID_VER_LOCAL" = "android15" ] && [ "$KERNEL_VER_LOCAL" = "6.6" ]; then
  if ! grep -qxF '#include <trace/hooks/fs.h>' ./fs/namespace.c; then
sed -i '/#include <trace\/hooks\/blk.h>/a #include <trace/hooks/fs.h>' ./fs/namespace.c
  fi
fi

fake_patched=0

if [ "$ANDROID_VER_LOCAL" = "android15" ] && [ "$KERNEL_VER_LOCAL" = "6.6" ]; then
  if ! grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' ./fs/proc/task_mmu.c; then
sed -i \
  -e '/int ret = 0, copied = 0;/a \\tunsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;' \
  -e '/int ret = 0, copied = 0;/a \\tpagemap_entry_t \*res = NULL;' \
  ./fs/proc/task_mmu.c
fake_patched=1
  fi

  if ! grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c; then
sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
  fi
fi

if [ "$ANDROID_VER_LOCAL" = "android12" ] && [ "$KERNEL_VER_LOCAL" = "5.10" ]; then
  grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1
fi

if [ "$ANDROID_VER_LOCAL" = "android13" ] && [ "$KERNEL_VER_LOCAL" = "5.15" ]; then
  grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1
fi

if [ "$ANDROID_VER_LOCAL" = "android14" ] && [ "$KERNEL_VER_LOCAL" = "6.1" ]; then
  grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1

  if ! grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c; then
sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
  fi
fi

SELINUXFS_REL="security/selinux/selinuxfs.c"
SELINUXFS_PATH="$COMMON_KERNEL_FOLDER/$SELINUXFS_REL"
SELINUXFS_BACKUP=""

if [ -f "$SELINUXFS_PATH" ]; then
  SELINUXFS_BACKUP="${RUNNER_TEMP:-/tmp}/selinuxfs.c.before_susfs.$$"
  cp -a "$SELINUXFS_PATH" "$SELINUXFS_BACKUP"
fi

SUSFS_BRANCH_LOCAL="${SUSFS_KERNEL_BRANCH_LOCAL:-${SUSFS_KERNEL_BRANCH:-gki-${ANDROID_VER_LOCAL}-${KERNEL_VER_LOCAL}}}"
SUSFS_PATCH="$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH_LOCAL}.patch"

echo "Using SUSFS kernel patch branch: $SUSFS_BRANCH_LOCAL"
echo "Using SUSFS kernel patch file: $SUSFS_PATCH"

if [ ! -f "$SUSFS_PATCH" ]; then
  echo "::error::SUSFS patch not found: $SUSFS_PATCH"
  echo "Available SUSFS patches:"
  find "$SUSFS_FOLDER/kernel_patches" -maxdepth 1 -type f -name '50_add_susfs_in_*.patch' -print | sort
  exit 1
fi

if ! patch -p1 --forward < "$SUSFS_PATCH"; then
  handled_rejects=0

  if [ -f mm/memory.c.rej ] && grep -q 'CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c.rej; then
echo "Handling known SUSFS mm/memory.c include reject..."

if grep -q '#include <linux/susfs_def.h>' mm/memory.c; then
  echo "SUSFS header already present in mm/memory.c"
elif grep -q '#include <linux/vmalloc.h>' mm/memory.c; then
  sed -i '/#include <linux\/vmalloc.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c
elif grep -q '#include <linux/mm.h>' mm/memory.c; then
  sed -i '/#include <linux\/mm.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c
else
  echo "::error::Could not find a safe include anchor in mm/memory.c"
  cat mm/memory.c.rej
  exit 1
fi

rm -f mm/memory.c.rej
handled_rejects=1
  fi

  if [ -f fs/proc/task_mmu.c.rej ] && grep -q 'CONFIG_KSU_SUSFS_SUS_MAP' fs/proc/task_mmu.c.rej; then
echo "Handling known SUSFS fs/proc/task_mmu.c show_smaps_rollup reject..."

if grep -q 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))' fs/proc/task_mmu.c; then
  echo "SUSFS show_smaps_rollup logic already present in task_mmu.c"
  rm -f fs/proc/task_mmu.c.rej
  handled_rejects=1
else
  python3 <<'PY'
from pathlib import Path
import re
import sys

path = Path("fs/proc/task_mmu.c")

if not path.exists():
    print("::error::fs/proc/task_mmu.c does not exist")
    sys.exit(1)

text = path.read_text()

function_match = re.search(
    r"static\s+int\s+show_smaps_rollup\s*\([^)]*\)\s*\{",
    text,
)

if not function_match:
    print("::error::Could not find show_smaps_rollup() in fs/proc/task_mmu.c")
    sys.exit(1)

start = function_match.start()
tail = text[start:]

target_pattern = re.compile(
    r"(?P<indent>[ \t]+)smap_gather_stats\(vma,\s*&mss,\s*last_vma_end\);\n"
    r"(?P=indent)last_vma_end\s*=\s*vma->vm_end;",
)

match = target_pattern.search(tail)

if not match:
    print("::error::Could not find target smap_gather_stats block inside show_smaps_rollup()")
    sys.exit(1)

indent = match.group("indent")

replacement = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    + indent + "if (!vma->vm_file || !(SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))) {\n"
    + indent + "\tsmap_gather_stats(vma, &mss, last_vma_end);\n"
    + indent + "\tlast_vma_end = vma->vm_end;\n"
    + indent + "}\n"
    + "#else\n"
    + indent + "smap_gather_stats(vma, &mss, last_vma_end);\n"
    + indent + "last_vma_end = vma->vm_end;\n"
    + "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP"
)

absolute_start = start + match.start()
absolute_end = start + match.end()

new_text = text[:absolute_start] + replacement + text[absolute_end:]

path.write_text(new_text)

print("Applied SUSFS show_smaps_rollup fallback patch")

PY

  if ! grep -q 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))' fs/proc/task_mmu.c; then
    echo "::error::Fallback patch did not modify fs/proc/task_mmu.c correctly"
    cat fs/proc/task_mmu.c.rej
    exit 1
  fi

  rm -f fs/proc/task_mmu.c.rej
  handled_rejects=1
fi
  fi

  if [ -n "$(find . -name "*.rej" -print -quit)" ]; then
echo "::error::SUSFS patch failed. Remaining reject files:"
find . -name "*.rej" -exec echo "=== {} ===" \; -exec cat {} \;
exit 1
  fi

  if [ "$handled_rejects" != "1" ]; then
echo "::error::SUSFS patch failed and no known fallback matched."
exit 1
  fi
fi

if [ "$fake_patched" = "1" ]; then
  if [ "$ANDROID_VER_LOCAL" = "android15" ] && [ "$KERNEL_VER_LOCAL" = "6.6" ]; then
sed -i \
  -e '/unsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;/d' \
  -e '/pagemap_entry_t \*res = NULL;/d' \
  ./fs/proc/task_mmu.c || true
  fi

  if [ "$ANDROID_VER_LOCAL" = "android12" ] && [ "$KERNEL_VER_LOCAL" = "5.10" ]; then
sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
  fi

  if [ "$ANDROID_VER_LOCAL" = "android13" ] && [ "$KERNEL_VER_LOCAL" = "5.15" ]; then
sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
  fi

  if [ "$ANDROID_VER_LOCAL" = "android14" ] && [ "$KERNEL_VER_LOCAL" = "6.1" ]; then
sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
  fi
fi

if [ "$ANDROID_VER_LOCAL" = "android16" ] && [ "$KERNEL_VER_LOCAL" = "6.12" ]; then
  SELINUXFS="$COMMON_KERNEL_FOLDER/security/selinux/selinuxfs.c"

  if [ -f "$SELINUXFS" ] && [ -n "${SELINUXFS_BACKUP:-}" ] && [ -f "$SELINUXFS_BACKUP" ]; then
cp -a "$SELINUXFS_BACKUP" "$SELINUXFS"
  elif [ -f "$SELINUXFS" ]; then
sed -i \
  -e '/ksu_selinux_hide_enabled/d' \
  -e '/fake_status/d' \
  -e '/initialize_fake_status/d' \
  -e '/fake_status_initialize_key/d' \
  -e 's/my_sel_open_handle_status/sel_open_handle_status/g' \
  "$SELINUXFS" || true
  fi
fi

fix_sukisu_dispatch_c           "drivers/kernelsu/supercall/dispatch.c"
fix_sukisu_sucompat_api         "drivers/kernelsu"
fix_sukisu_syscall_event_bridge "drivers/kernelsu/hook/syscall_event_bridge.c"
fix_sukisu_linker_symbols

# =============================================================================
# Final safety sweep
# =============================================================================

echo "Running final SukiSU targeted safety sweep..."

if [ -f drivers/kernelsu/core/init.c ]; then
  if grep -nE 'ksu_init_symbol_resolver[[:space:]]*\(|ksu_spoof_version[[:space:]]*\(' drivers/kernelsu/core/init.c; then
echo "::error::Unsupported SukiSU call still exists in drivers/kernelsu/core/init.c"
exit 1
  fi

  if ! grep -q 'susfs_init[[:space:]]*();' drivers/kernelsu/core/init.c; then
echo "::error::susfs_init() was not inserted into drivers/kernelsu/core/init.c"
exit 1
  fi

  # SUSFS v2.2.0: assert the inline hook init calls are wired whenever their definitions
  # exist in the tree. If a future SukiSU refactor keeps the functions but our anchor stops
  # matching (so ensure_sukisu_inline_hook_init silently no-ops), fail loud here rather than
  # ship a kernel whose SUSFS umount/sucompat never initialises. Stays a no-op on v2.1.0,
  # where these symbols are absent.
  for _fn in ksu_sucompat_init ksu_setuid_hook_init; do
if grep -RqsE "\b(void|int)([[:space:]]+__[a-z_]+)*[[:space:]]+${_fn}[[:space:]]*\(" \
     drivers/kernelsu --include='*.c' 2>/dev/null; then
  if ! grep -qE "\b${_fn}[[:space:]]*\(" drivers/kernelsu/core/init.c; then
    echo "::error::${_fn}() is defined but never called from drivers/kernelsu/core/init.c (v2.2.0 inline hook wiring missing)"
    exit 1
  fi
  echo "✅ ${_fn}() call present in drivers/kernelsu/core/init.c"
fi
  done
fi

if [ -f drivers/kernelsu/feature/selinux_hide.c ]; then
  if grep -nE 'ksu_late_loaded|ksu_patch_text[[:space:]]*\(' drivers/kernelsu/feature/selinux_hide.c; then
echo "::error::Unsupported SukiSU/SUSFS call still exists in drivers/kernelsu/feature/selinux_hide.c"
exit 1
  fi

  if grep -nE 'new_fn[[:space:]]*=[[:space:]]*my_sel_open_handle_status' drivers/kernelsu/feature/selinux_hide.c; then
echo "::error::Unused new_fn still exists in drivers/kernelsu/feature/selinux_hide.c"
exit 1
  fi

  if grep -nE 'if[[:space:]]*\([[:space:]]*(security_dump_masked_av_fn|context_struct_compute_av_fn)[[:space:]]*\)' drivers/kernelsu/feature/selinux_hide.c; then
echo "::error::Pointer-bool warning patterns still remain in drivers/kernelsu/feature/selinux_hide.c"
exit 1
  fi
fi

if [ -f drivers/kernelsu/policy/app_profile.c ]; then
  if grep -n "Already root, don't escape" drivers/kernelsu/policy/app_profile.c; then
echo "::error::Already-root early abort still exists in drivers/kernelsu/policy/app_profile.c"
exit 1
  fi

  if awk '
/^[[:space:]]*disable_seccomp[[:space:]]*\(\);/ {
  if (prev !~ /TIF_SECCOMP/ && prev2 !~ /TIF_SECCOMP/) {
    print FNR ":" $0
    bad = 1
  }
}
{ prev2 = prev; prev = $0 }
END { exit bad ? 1 : 0 }
  ' drivers/kernelsu/policy/app_profile.c; then
:
  else
echo "::error::Unguarded disable_seccomp() still exists in drivers/kernelsu/policy/app_profile.c"
exit 1
  fi

  if grep -nE 'ksu_set_task_tracepoint_flag[[:space:]]*\(' drivers/kernelsu/policy/app_profile.c; then
echo "::error::ksu_set_task_tracepoint_flag() still exists in drivers/kernelsu/policy/app_profile.c"
exit 1
  fi
fi

if [ -f drivers/kernelsu/supercall/dispatch.c ]; then
  if grep -nE 'ksu_set_spoof_version[[:space:]]*\(' drivers/kernelsu/supercall/dispatch.c; then
echo "::error::ksu_set_spoof_version call still exists in drivers/kernelsu/supercall/dispatch.c"
exit 1
  fi

  if grep -qE 'SUSFS_MAGIC|CMD_SUSFS_|susfs_' drivers/kernelsu/supercall/dispatch.c; then
if ! grep -q '#include <linux/susfs.h>' drivers/kernelsu/supercall/dispatch.c; then
  echo "::error::drivers/kernelsu/supercall/dispatch.c uses SUSFS symbols but is missing #include <linux/susfs.h>"
  exit 1
fi
  fi
fi

if [ -f drivers/kernelsu/runtime/ksud_integration.c ]; then
  if grep -q 'ksu_no_custom_rc' drivers/kernelsu/runtime/ksud_integration.c && \
 ! grep -qE '^[[:space:]]*(extern[[:space:]]+)?bool[[:space:]]+ksu_no_custom_rc\b|^[[:space:]]*static[[:space:]]+bool[[:space:]]+ksu_no_custom_rc\b' drivers/kernelsu/runtime/ksud_integration.c; then
echo "::error::ksu_no_custom_rc is referenced but not declared in drivers/kernelsu/runtime/ksud_integration.c"
exit 1
  fi

  if [ -f drivers/kernelsu/runtime/ksud_integration.c ]; then
python3 - drivers/kernelsu/runtime/ksud_integration.c <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

good_sig = "int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)"
good_body = """int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
"""

s = re.sub(
    r'void\s+ksu_handle_execveat_init\s*\(\s*void\s*\)\s*\{[^{}]*\}',
    good_body,
    s,
    flags=re.S,
)

if "ksu_handle_execveat_init(" in s and good_sig not in s:
    s = s.rstrip() + "\n\n" + good_body + "\n"

p.write_text(s)
PY
  fi

  if grep -q 'ksu_handle_execveat_init[[:space:]]*(' drivers/kernelsu/runtime/ksud_integration.c && \
 ! grep -RqsE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' drivers/kernelsu --include='*.c'; then
echo "::error::ksu_handle_execveat_init is referenced but no function body exists anywhere under drivers/kernelsu"
grep -n 'ksu_handle_execveat_init' drivers/kernelsu/runtime/ksud_integration.c || true
exit 1
  fi
fi

for kbuild in drivers/kernelsu/Kbuild drivers/kernelsu/Makefile; do
  if [ -f "$kbuild" ]; then
if grep -nE 'uts_spoof\.o|feature/uts_spoof\.o' "$kbuild"; then
  echo "::error::uts_spoof.o is still enabled in $kbuild"
  exit 1
fi
  fi
done

for bridge in \
  "$KSU_FOLDER/kernel/hook/syscall_event_bridge.c" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/syscall_event_bridge.c"; do
  if [ -f "$bridge" ]; then
bridge_base="$(dirname "$(dirname "$bridge")")"
bridge_sucompat_c="$bridge_base/feature/sucompat.c"

if grep -q 'ksu_handle_stat_sucompat' "$bridge"; then
  if ! grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_stat_sucompat[[:space:]]*\(' "$bridge_sucompat_c" 2>/dev/null; then
    echo "::error::Bridge calls ksu_handle_stat_sucompat but implementation is missing: $bridge"
    exit 1
  fi
fi

if grep -q 'ksu_handle_faccessat_sucompat' "$bridge"; then
  if ! grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_faccessat_sucompat[[:space:]]*\(' "$bridge_sucompat_c" 2>/dev/null; then
    echo "::error::Bridge calls ksu_handle_faccessat_sucompat but implementation is missing: $bridge"
    exit 1
  fi
fi

echo "✅ syscall_event_bridge API validated: $bridge"
  fi
done

for sucompat_h in \
  "$KSU_FOLDER/kernel/feature/sucompat.h" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/sucompat.h"; do
  if [ -f "$sucompat_h" ]; then
if grep -qE 'ksu_handle_faccessat_sucompat|ksu_handle_stat_sucompat' "$sucompat_h"; then
  echo "ℹ️ Old sucompat declarations present in $sucompat_h; allowed when matching implementations exist"
fi

if ! grep -qE 'ksu_handle_faccessat|ksu_handle_stat|ksu_handle_execve' "$sucompat_h"; then
  echo "::error::No sucompat API declarations found in $sucompat_h"
  exit 1
fi

echo "✅ sucompat.h API validated: $sucompat_h"
  fi
done

for sucompat_c in \
  "$KSU_FOLDER/kernel/feature/sucompat.c" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/sucompat.c"; do
  if [ -f "$sucompat_c" ]; then
if ! grep -qE 'DEFINE_STATIC_KEY_(TRUE|FALSE)\(ksu_su_compat_enabled\)' "$sucompat_c"; then
  echo "::error::ksu_su_compat_enabled static_key definition missing in $sucompat_c"
  exit 1
fi

# Hard fallback for older SukiSU execve sucompat handler shape.
# This handles:
#   ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL)
perl -0pi -e 's/ksu_sulog_capture_sucompat\s*\(\s*\*filename_user\s*,\s*argv_user\s*,\s*GFP_KERNEL\s*\)/ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL)/g' "$sucompat_c"

if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user, GFP_KERNEL)' "$sucompat_c"; then
  echo "::error::Old incompatible ksu_sulog_capture_sucompat argv_user call remains in $sucompat_c"
  grep -n 'ksu_sulog_capture_sucompat' "$sucompat_c" || true
  exit 1
fi

if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, &argv_arg_ptr, GFP_KERNEL)' "$sucompat_c"; then
  if ! grep -q 'struct user_arg_ptr argv_arg_ptr;' "$sucompat_c"; then
    echo "::error::argv_arg_ptr is used but not declared in $sucompat_c"
    grep -nE 'argv_arg_ptr|ksu_sulog_capture_sucompat' "$sucompat_c" || true
    exit 1
  fi

  if ! grep -q '#include <linux/binfmts.h>' "$sucompat_c"; then
    echo "::error::struct user_arg_ptr compatibility include is missing in $sucompat_c"
    grep -nE 'linux/binfmts.h|argv_arg_ptr|ksu_sulog_capture_sucompat' "$sucompat_c" || true
    exit 1
  fi

  if grep -q 'argv_arg_ptr.is_compat = false;' "$sucompat_c" && \
     ! grep -q '#ifdef CONFIG_COMPAT' "$sucompat_c"; then
    echo "::error::argv_arg_ptr.is_compat is unguarded by CONFIG_COMPAT in $sucompat_c"
    grep -nE 'CONFIG_COMPAT|argv_arg_ptr|ksu_sulog_capture_sucompat' "$sucompat_c" || true
    exit 1
  fi
fi

# Hard fallback before validation: remove old direct ksu_syscall_table calls from sucompat.c.
perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c"

if grep -q 'ksu_syscall_table' "$sucompat_c"; then
  echo "::error::ksu_syscall_table reference remains in $sucompat_c"
  grep -n 'ksu_syscall_table' "$sucompat_c" || true
  exit 1
fi

if grep -q 'ksu_handle_execveat[[:space:]]*(' "$COMMON_KERNEL_FOLDER/fs/exec.c" 2>/dev/null; then
  if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
    echo "::error::fs/exec.c calls ksu_handle_execveat but implementation is missing in $sucompat_c"
    grep -nE 'ksu_handle_execveat|ksu_handle_execveat_sucompat' "$sucompat_c" || true
    exit 1
  fi
fi

if grep -q 'ksu_handle_execveat_sucompat[[:space:]]*(' "$COMMON_KERNEL_FOLDER/fs/exec.c" 2>/dev/null; then
  if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
    echo "::error::fs/exec.c calls ksu_handle_execveat_sucompat but implementation is missing in $sucompat_c"
    grep -nE 'ksu_handle_execveat|ksu_handle_execveat_sucompat' "$sucompat_c" || true
    exit 1
  fi
fi

echo "✅ sucompat.c API/static_key validated: $sucompat_c"
  fi
done

{
  cat <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=n
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_SU=n
EOF
} >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"

sed -i '/^CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=/d' \
  "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig" || true

echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=n" \
  >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"

echo "✅ SUSFS patches applied successfully"
echo "::endgroup::"
