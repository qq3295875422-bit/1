#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
import webbrowser
from pathlib import Path

DEFAULT_REPO = "qq3295875422-bit/1"
DEFAULT_WORKFLOW = "cinnamon-novnc.yml"
ARTIFACT_NAME = "cinnamon-novnc-connection"
STATE_DIR = Path.home() / ".qifu-cloud-pc"
STATE_FILE = STATE_DIR / "session.json"


class QifuError(RuntimeError):
    pass


def run(cmd, *, check=True):
    return subprocess.run(cmd, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def require_gh():
    if shutil.which("gh") is None:
        raise QifuError(
            "未找到 GitHub CLI (gh)。请先安装：https://cli.github.com/\n"
            "Windows 可执行：winget install --id GitHub.cli"
        )
    auth = run(["gh", "auth", "status"], check=False)
    if auth.returncode != 0:
        raise QifuError("GitHub CLI 尚未登录。请先执行：gh auth login")


def gh_json(args):
    cp = run(["gh", *args])
    try:
        return json.loads(cp.stdout)
    except json.JSONDecodeError as e:
        raise QifuError(f"无法解析 GitHub 返回结果：{e}\n{cp.stdout}")


def list_runs(repo, workflow, limit=20):
    return gh_json([
        "run", "list",
        "--repo", repo,
        "--workflow", workflow,
        "--limit", str(limit),
        "--json", "databaseId,status,conclusion,createdAt,displayTitle,event,headSha",
    ])


def active_runs(repo, workflow):
    return [r for r in list_runs(repo, workflow) if r.get("status") in {"queued", "in_progress", "waiting", "requested"}]


def download_connection(repo, run_id, *, quiet=False):
    with tempfile.TemporaryDirectory(prefix="qifu-cloud-pc-") as td:
        cp = run([
            "gh", "run", "download", str(run_id),
            "--repo", repo,
            "--name", ARTIFACT_NAME,
            "--dir", td,
        ], check=False)
        if cp.returncode != 0:
            if not quiet:
                msg = (cp.stderr or cp.stdout or "").strip()
                if msg:
                    print(f"连接信息尚未生成：{msg}")
            return None

        path = Path(td) / "connection.txt"
        if not path.exists():
            candidates = list(Path(td).rglob("connection.txt"))
            if not candidates:
                return None
            path = candidates[0]

        data = {}
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
        if not data.get("URL") or not data.get("PASSWORD"):
            return None
        data["RUN_ID"] = str(run_id)
        return data


def save_state(repo, workflow, info):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "repo": repo,
        "workflow": workflow,
        "run_id": int(info["RUN_ID"]),
        "url": info["URL"],
        "password": info["PASSWORD"],
        "saved_at": time.time(),
    }
    STATE_FILE.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def load_state():
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return None


def print_connection(info, *, open_browser=True):
    print("\n" + "=" * 62)
    print("启赋未来 · GitHub 云电脑已就绪")
    print(f"云桌面链接：{info['URL']}")
    print(f"VNC 密码： {info['PASSWORD']}")
    if info.get("DESKTOP"):
        print(f"桌面：      {info['DESKTOP']}")
    if info.get("LOCALE"):
        print(f"语言：      {info['LOCALE']}")
    if info.get("INPUT_METHOD"):
        print(f"输入法：    {info['INPUT_METHOD']}")
    print(f"Run ID：    {info['RUN_ID']}")
    print("=" * 62)
    print("提示：这台 GitHub Actions 云电脑是临时环境；重要代码请 commit/push 到仓库。")
    if open_browser:
        try:
            webbrowser.open(info["URL"])
        except Exception:
            pass


def wait_for_connection(repo, workflow, run_id, timeout=1200, open_browser=True):
    started = time.time()
    last_status = None
    while time.time() - started < timeout:
        info = download_connection(repo, run_id, quiet=True)
        if info:
            save_state(repo, workflow, info)
            print_connection(info, open_browser=open_browser)
            return info

        runs = list_runs(repo, workflow, limit=20)
        match = next((r for r in runs if int(r["databaseId"]) == int(run_id)), None)
        if match:
            status = match.get("status")
            conclusion = match.get("conclusion")
            if status != last_status:
                print(f"当前状态：{status}" + (f" / {conclusion}" if conclusion else ""))
                last_status = status
            if status == "completed" and conclusion != "success":
                raise QifuError(f"云电脑启动失败：run {run_id} / {conclusion}")
            if status == "completed" and conclusion == "success":
                info = download_connection(repo, run_id, quiet=True)
                if info:
                    save_state(repo, workflow, info)
                    print_connection(info, open_browser=open_browser)
                    return info
                raise QifuError("工作流已结束，但没有找到连接信息 Artifact。")

        time.sleep(5)
    raise QifuError(f"等待云电脑连接信息超时。Run ID: {run_id}")


def start(repo, workflow, *, force_new=False, open_browser=True):
    require_gh()

    if not force_new:
        for r in active_runs(repo, workflow):
            info = download_connection(repo, r["databaseId"], quiet=True)
            if info:
                print("发现已经在线的云电脑，直接复用。")
                save_state(repo, workflow, info)
                print_connection(info, open_browser=open_browser)
                return

    before = {int(r["databaseId"]) for r in list_runs(repo, workflow)}
    print("正在创建 GitHub 云电脑……")
    cp = run([
        "gh", "workflow", "run", workflow,
        "--repo", repo,
        "--ref", "main",
    ], check=False)
    if cp.returncode != 0:
        raise QifuError((cp.stderr or cp.stdout or "触发 workflow 失败").strip())

    run_id = None
    for _ in range(60):
        for r in list_runs(repo, workflow, limit=20):
            rid = int(r["databaseId"])
            if rid not in before and r.get("event") == "workflow_dispatch":
                run_id = rid
                break
        if run_id:
            break
        time.sleep(2)

    if not run_id:
        for r in list_runs(repo, workflow, limit=20):
            rid = int(r["databaseId"])
            if rid not in before:
                run_id = rid
                break
    if not run_id:
        raise QifuError("工作流已经触发，但没有识别到新的 Run ID。")

    print(f"已创建 Run #{run_id}，正在等待 Cinnamon/noVNC/公网隧道就绪……")
    wait_for_connection(repo, workflow, run_id, open_browser=open_browser)


def status(repo, workflow, *, open_browser=False):
    require_gh()
    runs = active_runs(repo, workflow)
    if not runs:
        print("当前没有运行中的启赋云电脑。")
        return 1

    for r in runs:
        rid = int(r["databaseId"])
        info = download_connection(repo, rid, quiet=True)
        if info:
            save_state(repo, workflow, info)
            print_connection(info, open_browser=open_browser)
            return 0
        print(f"Run #{rid} 正在启动，状态：{r.get('status')}")
    return 0


def stop(repo, workflow):
    require_gh()
    runs = active_runs(repo, workflow)
    state = load_state()
    ordered = []
    if state and state.get("repo") == repo:
        sid = int(state.get("run_id", 0) or 0)
        if sid:
            ordered.append(sid)
    ordered.extend(int(r["databaseId"]) for r in runs if int(r["databaseId"]) not in ordered)

    if not ordered:
        print("当前没有运行中的启赋云电脑。")
        return

    cancelled = 0
    for rid in ordered:
        cp = run(["gh", "run", "cancel", str(rid), "--repo", repo], check=False)
        if cp.returncode == 0:
            print(f"已发送关机请求：Run #{rid}")
            cancelled += 1
    if cancelled and STATE_FILE.exists():
        try:
            STATE_FILE.unlink()
        except OSError:
            pass


def restart(repo, workflow, *, open_browser=True):
    stop(repo, workflow)
    time.sleep(2)
    start(repo, workflow, force_new=True, open_browser=open_browser)


def interactive(repo, workflow):
    print("\n启赋未来 · GitHub 云电脑")
    print("1. 启动 / 打开云电脑")
    print("2. 查看当前云电脑")
    print("3. 重启云电脑")
    print("4. 关闭云电脑")
    choice = input("请选择 [1-4]：").strip() or "1"
    if choice == "1":
        start(repo, workflow)
    elif choice == "2":
        status(repo, workflow, open_browser=True)
    elif choice == "3":
        restart(repo, workflow)
    elif choice == "4":
        stop(repo, workflow)
    else:
        raise QifuError("无效选项。")


def main():
    parser = argparse.ArgumentParser(description="一键创建/管理启赋未来 GitHub Cinnamon 云电脑")
    parser.add_argument("action", nargs="?", choices=["start", "status", "stop", "restart"], help="操作；省略则进入菜单")
    parser.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub 仓库，默认 {DEFAULT_REPO}")
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW, help=f"Workflow 文件，默认 {DEFAULT_WORKFLOW}")
    parser.add_argument("--new", action="store_true", help="start 时强制新建，不复用已有云电脑")
    parser.add_argument("--no-open", action="store_true", help="就绪后不自动打开浏览器")
    args = parser.parse_args()

    try:
        if args.action == "start":
            start(args.repo, args.workflow, force_new=args.new, open_browser=not args.no_open)
        elif args.action == "status":
            status(args.repo, args.workflow, open_browser=not args.no_open)
        elif args.action == "stop":
            stop(args.repo, args.workflow)
        elif args.action == "restart":
            restart(args.repo, args.workflow, open_browser=not args.no_open)
        else:
            interactive(args.repo, args.workflow)
    except KeyboardInterrupt:
        print("\n已取消。")
        return 130
    except QifuError as e:
        print(f"\n错误：{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
