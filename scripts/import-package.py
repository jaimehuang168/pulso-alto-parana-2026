"""驗證指定 SHA-256 的完整 ZIP，再新增尚未存在的原始碼；不覆蓋差異檔。"""
from __future__ import annotations
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile

ROOT_NAME = 'Pulso_Alto_Parana_v2'
ALLOWED_DIRS = {'web', 'supabase', 'scripts', 'tests', 'docs', '.github'}
ALLOWED_ROOT = {'.env.example', '.gitignore', 'AGENTS.md', 'README.md', 'THIRD_PARTY.md', 'DEMO_ABRIR_EN_NAVEGADOR.html'}
REQUIRED = {'web/app.js', 'web/core.js', 'web/index.html', 'web/config.js', 'web/styles.css', 'web/manual-es.html', 'web/guia-encuestador-es.html', 'supabase/00_INSTALL_NEW_PROJECT.sql', 'supabase/functions/provision-team/index.ts', 'tests/core.test.cjs'}


def apply_package(package: Path, destination: Path, expected_sha: str) -> int:
    if not package.is_file() or package.stat().st_size > 20_000_000:
        raise ValueError('ZIP 不存在或超過允許大小。')
    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    if len(expected_sha) != 64 or digest != expected_sha.lower():
        raise ValueError('SHA-256 不符。未匯入任何檔案；請使用此工作流程指定版本的完整 ZIP。')
    destination = destination.resolve()
    planned: dict[str, bytes] = {}
    seen: set[str] = set()
    total = 0
    with zipfile.ZipFile(package) as archive:
        if len(archive.infolist()) > 250:
            raise ValueError('ZIP 項目數超過預期。')
        for entry in archive.infolist():
            name = entry.filename
            if '\\' in name:
                raise ValueError('不接受反斜線 ZIP 路徑。')
            parts = PurePosixPath(name).parts
            if not parts or parts[0] != ROOT_NAME or '..' in parts or '.' in parts:
                raise ValueError('ZIP 路徑不正確。')
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('ZIP 不得包含符號連結。')
            if entry.is_dir():
                continue
            relative = PurePosixPath(*parts[1:]).as_posix()
            if relative in seen:
                raise ValueError('ZIP 有重複檔案路徑。')
            seen.add(relative)
            first = parts[1] if len(parts) > 1 else ''
            if first not in ALLOWED_DIRS and relative not in ALLOWED_ROOT:
                raise ValueError('ZIP 有未預期的頂層項目。')
            total += entry.file_size
            if total > 25_000_000 or entry.file_size > 5_000_000:
                raise ValueError('解壓後檔案大小超過預期。')
            if first == '.github':
                # GitHub 工作流程由已授權的工具直接提交，不讓 ZIP 覆蓋工作流程。
                continue
            if relative == 'DEMO_ABRIR_EN_NAVEGADOR.html' or relative.startswith('tests/artifacts/'):
                continue
            target = destination / relative
            if not target.resolve().is_relative_to(destination):
                raise ValueError('目標路徑離開 repository。')
            if target.is_symlink():
                raise ValueError('不寫入符號連結。')
            data = archive.read(entry)
            if target.exists() and (not target.is_file() or target.read_bytes() != data):
                raise ValueError(f'既有檔案內容不同：{relative}。已停止，不覆蓋；請先核對版本。')
            planned[relative] = data
    if not REQUIRED.issubset(planned):
        raise ValueError('缺少必要程式檔；可能不是完整專案 ZIP。')
    config = planned['web/config.js'].decode('utf-8')
    if "supabaseUrl: ''" not in config or "supabasePublishableKey: ''" not in config:
        raise ValueError('匯入套件的公開設定必須保持空白，部署時再由 repository variables 產生。')
    # 先完成全部驗證，再逐檔新增；無任何刪除或覆蓋動作。
    added = 0
    for relative, data in planned.items():
        target = destination / relative
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as output:
            output.write(data)
        added += 1
    return added


if __name__ == '__main__':
    try:
        count = apply_package(Path(os.environ['PACKAGE_PATH']), Path.cwd(), os.environ['PACKAGE_SHA256'])
        print(f'ZIP 雜湊與安全檢查通過；新增 {count} 個原始碼／文件檔案。尚未宣告網站或後端已上線。')
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        print(f'停止：{error}', file=sys.stderr)
        sys.exit(1)
